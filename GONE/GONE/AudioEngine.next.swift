import AVFoundation
import Accelerate
import Foundation
import CoreAudio

/// A stricter playback core kept separate from the production AudioEngine while
/// the app is being refactored. The implementation stays intentionally simple:
/// one player node, one time-pitch unit, one EQ, lightweight progress polling,
/// and no heavy dependencies or modern-only UI/audio abstractions.
final class AudioEngineNext {
    static let shared = AudioEngineNext()
    static let secondary = AudioEngineNext()

    struct PlaybackSnapshot {
        let isLoaded: Bool
        let isPlaying: Bool
        let progress: Double
        let currentTime: Double
        let duration: Double
        let rate: Double
        let pitchPercent: Double
        let sampleRate: Double
    }

    static let bandFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let speedNode = AVAudioUnitVarispeed()
    private let pitchNode = AVAudioUnitTimePitch()
    private let hpfNode        = AVAudioUnitEQ(numberOfBands: 1)
    private let lpfNode        = AVAudioUnitEQ(numberOfBands: 1)
    private let eqNode         = AVAudioUnitEQ(numberOfBands: 10)
    private let distortionNode = AVAudioUnitDistortion()
    private let delayNode      = AVAudioUnitDelay()
    private let reverbNode     = AVAudioUnitReverb()
    private let gateNode       = AVAudioMixerNode()

    private var audioFile: AVAudioFile?
    private var currentURL: URL?
    private var scheduledStartFrame: AVAudioFramePosition = 0  // Main-thread only
    private var pausedFrameOffset: AVAudioFramePosition = 0    // Main-thread only
    private var progressTimer: Timer?                          // Main-thread only
    // playbackToken is read on bufferQueue and written on main — guard with lock
    private let tokenLock = NSLock()
    private var _playbackToken: UInt64 = 0
    private var playbackToken: UInt64 {
        tokenLock.withLock { _playbackToken }
    }
    @discardableResult
    private func bumpToken() -> UInt64 {
        tokenLock.withLock { _playbackToken &+= 1; return _playbackToken }
    }
    private var isScheduled = false
    private var configChangeObserver: NSObjectProtocol?
    var suppressConfigChange = false   // set by SplitModeManager during deactivate to prevent engine.start() racing with stop()

    private var pitchPercent: Double = 0       // Main-thread only
    private var masterTempo = true              // Main-thread only
    private var currentRate: Double = 1.0      // Main-thread only
    private var isUserPlaying = false           // Main-thread only; tracks user intent, not hardware node state

    // Pre-decoded PCM prefetch — keeps 3s of audio in RAM ahead of playhead.
    private let bufferQueue = DispatchQueue(label: "gone.audio.prefetch", qos: .userInteractive)
    private let prefetchChunkSeconds: Double = 1.0
    private let prefetchDepth: Int = 3  // chunks queued ahead (3 × 1s = 3s)

    private var fileSampleRate: Double {
        audioFile?.processingFormat.sampleRate ?? 44_100
    }

    private var durationSeconds: Double {
        guard let file = audioFile else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var onProgress: ((Double, Double) -> Void)?
    var onSpectrum: (([Float]) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((String) -> Void)?   // fires with human-readable error string; always set, debugMode gate is inside the closure

    private var baseVolume: Double = 72
    var crossfadeGain: Float = 1.0 {
        didSet {
            let g = min(1.0, max(0.0, crossfadeGain))
            engine.mainMixerNode.outputVolume = Float(baseVolume / 100.0) * g
        }
    }

    private let spectrumBars = 28
    private let fftLog2n: vDSP_Length = 10
    private let fftSize = 1 << 10
    private var fftSetup: FFTSetup?
    private var hannWindow: [Float]
    private var spectrumSmooth = [Float](repeating: 0, count: 28)
    private var lastSpectrumEmit: TimeInterval = 0
    private var fftWindowed: [Float]
    private var fftReal: [Float]
    private var fftImag: [Float]
    private var fftMagnitudes: [Float]
    private var fftBars: [Float]
    // Pre-allocated PCM staging buffer for the tap callback.
    // The tap runs on the CoreAudio render thread — no heap allocation is allowed there.
    // The tap memcpy's samples into this buffer; spectrumQueue then copies it off-thread.
    private var tapSampleBuffer: [Float]

    private let spectrumQueue = DispatchQueue(label: "gone.spectrum", qos: .utility)
    private var audioActivity: NSObjectProtocol?

    private init() {
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        hannWindow = window
        fftWindowed = Array(repeating: 0, count: fftSize)
        fftReal = Array(repeating: 0, count: fftSize / 2)
        fftImag = Array(repeating: 0, count: fftSize / 2)
        fftMagnitudes = Array(repeating: 0, count: fftSize / 2)
        fftBars = Array(repeating: 0, count: spectrumBars)
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(FFT_RADIX2))
        tapSampleBuffer = [Float](repeating: 0, count: 1 << 10)  // must match fftSize

        setupGraph()
        setupEQBands()
        setupFilterNodes()
        applyPitchState()
    }

    deinit {
        let pt = progressTimer; let ht = holdSeekTimer
        progressTimer = nil;   holdSeekTimer = nil
        if Thread.isMainThread { pt?.invalidate(); ht?.invalidate() }
        else { DispatchQueue.main.async { pt?.invalidate(); ht?.invalidate() } }
        engine.mainMixerNode.removeTap(onBus: 0)
        if let obs = configChangeObserver { NotificationCenter.default.removeObserver(obs) }
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    // MARK: - Public API

    func load(_ url: URL, autoplay: Bool = false) {
        stop(resetProgress: true)

        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            currentURL = url
            scheduledStartFrame = 0
            pausedFrameOffset = 0
            let token = bumpToken()
            scheduleFrom(frame: 0, token: token)
            emitProgress(currentFrame: 0)

            if autoplay {
                play()
            }
        } catch {
            audioFile = nil
            currentURL = nil
            let msg = "load failed: \(error)"
            print("[AudioEngineNext] \(msg)")
            onError?(msg)
        }
    }

    func reloadCurrent(autoplay: Bool) {
        guard let currentURL else { return }
        load(currentURL, autoplay: autoplay)
    }

    func play() {
        guard audioFile != nil else { return }

        isUserPlaying = true
        ensureEngineRunning()

        if playerNode.isPlaying {
            return
        }

        if !hasScheduledAudio {
            let token = bumpToken()
            scheduleFrom(frame: pausedFrameOffset, token: token)
        }

        playerNode.play()
        startProgressTimer()
        beginAudioActivity()
    }

    func pause() {
        guard audioFile != nil else { return }

        isUserPlaying = false
        pausedFrameOffset = currentPlaybackFrame()
        playerNode.pause()
        progressTimer?.invalidate()
        emitProgress(currentFrame: pausedFrameOffset)
        endAudioActivity()
    }

    // Called from SplitModeManager.deactivate() on the main thread.
    // Sets isUserPlaying=false so handleEngineConfigurationChange (fired by setOutputDevice
    // on audioOpQueue) won't restart playback after the window is torn down.
    // Does NOT call playerNode.pause() — that would contest Core Audio's IO lock
    // with the concurrent setOutputDevice on audioOpQueue, causing a deadlock.
    func markStopped() {
        isUserPlaying = false
        let t = progressTimer
        progressTimer = nil
        t?.invalidate()
        endAudioActivity()
    }

    func stop(resetProgress: Bool = true, drain: Bool = false) {
        isUserPlaying = false
        // Ensure any stuck hold-seek rate override is cleared before stopping.
        stopHoldSeek()
        bumpToken()             // cancels pending scheduling (checked in schedulePCMChunk)
        // drain=true: called from deactivation on audioOpQueue. Blocks until any in-flight
        // schedulePCMChunk (which calls playerNode.scheduleBuffer) exits bufferQueue.
        // Without this, concurrent scheduleBuffer + stop() inside AVAudioPlayerNode deadlock.
        if drain { bufferQueue.sync {} }
        playerNode.stop()               // safe: bufferQueue is drained when drain=true
        // Timer must be invalidated on the thread it was installed on (RunLoop.main).
        // Use async (not sync) — stop() may be called from Task.detached (Split Mode deactivate)
        // and sync to main while main awaits the task is a deadlock.
        let t = progressTimer
        progressTimer = nil
        if Thread.isMainThread {
            t?.invalidate()
        } else {
            DispatchQueue.main.async { t?.invalidate() }
        }
        isScheduled = false
        endAudioActivity()

        if resetProgress {
            scheduledStartFrame = 0
            pausedFrameOffset = 0
            lastSpectrumEmit = 0
            spectrumQueue.async { [weak self] in
                guard let self else { return }
                self.spectrumSmooth = Array(repeating: 0, count: self.spectrumBars)
            }
            // emitProgress → onProgress → @Published writes; must run on main thread.
            if Thread.isMainThread {
                emitProgress(currentFrame: 0)
            } else {
                DispatchQueue.main.async { [weak self] in self?.emitProgress(currentFrame: 0) }
            }
        } else {
            let frame = currentPlaybackFrame()
            if Thread.isMainThread {
                pausedFrameOffset = frame
                emitProgress(currentFrame: frame)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pausedFrameOffset = frame
                    self.emitProgress(currentFrame: frame)
                }
            }
        }
    }

    func seek(ratio: Double, autoplay: Bool? = nil) {
        guard let file = audioFile else { return }

        let clampedRatio = max(0, min(1, ratio))
        let targetFrame = AVAudioFramePosition(Double(file.length) * clampedRatio)
        let shouldResume = autoplay ?? playerNode.isPlaying

        progressTimer?.invalidate()
        progressTimer = nil
        let token = bumpToken()         // cancels pending scheduling (checked in schedulePCMChunk)
        playerNode.stop()               // flush queued buffers

        scheduledStartFrame = targetFrame
        pausedFrameOffset = targetFrame
        scheduleFrom(frame: targetFrame, token: token)
        emitProgress(currentFrame: targetFrame)

        if shouldResume {
            ensureEngineRunning()
            playerNode.play()
            startProgressTimer()
        }
    }

    func currentOutputDeviceID() -> AudioDeviceID {
        guard let unit = engine.outputNode.audioUnit else { return kAudioObjectUnknown }
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &size)
        return deviceID
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var id = deviceID == kAudioObjectUnknown ? systemDefaultOutputDeviceID() : deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            let msg = "setOutputDevice failed: OSStatus \(status)"
            print("[AudioEngineNext] \(msg)")
            onError?(msg)
        }
    }

    private func systemDefaultOutputDeviceID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(1), &addr, 0, nil, &size, &id)
        return id
    }

    func setVolume(_ value: Double) {
        let clamped = max(0, min(100, value))
        baseVolume = clamped
        engine.mainMixerNode.outputVolume = Float(clamped / 100.0) * crossfadeGain
    }

    func setPitch(_ percent: Double, masterTempo: Bool) {
        pitchPercent = percent
        self.masterTempo = masterTempo
        applyPitchState()
    }

    // MARK: - Hold-seek (transport button scrub)

    private var holdSeekTimer: Timer?
    private var holdSeekStep: Int = 0
    private var holdSeekBaseRate: Double = 1.0
    private var holdSeekForward: Bool = true

    // Called when the user holds a transport arrow.
    // masterTempo ON  → time-stretch scrub via pitchNode.rate; pitch stays constant.
    // masterTempo OFF → varispeed scrub via speedNode.rate; pitch follows speed (vinyl feel).
    func startHoldSeek(forward: Bool) {
        stopHoldSeek()
        holdSeekStep = 0
        holdSeekForward = forward
        holdSeekBaseRate = currentRate
        let baseOffset = forward ? 1.025 : 0.975   // +2.5% / -2.5%

        if masterTempo {
            speedNode.rate = 1.0
            pitchNode.bypass = false
            pitchNode.rate = Float(max(0.05, holdSeekBaseRate * baseOffset))
            pitchNode.pitch = 0
        } else {
            pitchNode.bypass = true
            pitchNode.rate = 1.0
            pitchNode.pitch = 0
            speedNode.rate = Float(max(0.05, holdSeekBaseRate * baseOffset))
        }

        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdSeekStep += 1
                if self.holdSeekStep > 250 { self.stopHoldSeek() }  // 20s safety cutoff
            }
        }
        RunLoop.main.add(t, forMode: .common)
        holdSeekTimer = t
    }

    // Linear percentage control: +5% per 30px drag.
    // Forward: +percent speeds up. Backward: +percent slows down further (reverse scrub).
    func setHoldSeekPercent(_ percent: Double) {
        guard holdSeekTimer != nil else { return }
        let factor = 1.0 + max(-95, min(700, percent)) / 100.0
        let rate = holdSeekForward
            ? holdSeekBaseRate * factor
            : holdSeekBaseRate / max(0.01, factor)
        if masterTempo {
            pitchNode.rate = Float(max(0.02, rate))
        } else {
            speedNode.rate = Float(max(0.02, rate))
        }
    }

    // Safe to call at any time — also called from stop() which may run off main.
    func stopHoldSeek() {
        let t = holdSeekTimer
        holdSeekTimer = nil
        holdSeekStep = 0
        if Thread.isMainThread {
            t?.invalidate()
        } else {
            DispatchQueue.main.async { t?.invalidate() }
        }
        applyPitchState()
    }

    func setEQ(preamp: Float, bands: [Float]) {
        eqNode.globalGain = preamp
        for (index, gain) in bands.prefix(Self.bandFrequencies.count).enumerated() {
            eqNode.bands[index].gain = gain
        }
    }

    func setEQEnabled(_ enabled: Bool) {
        eqNode.bypass = !enabled
    }

    func setHPF(cutoff: Float) {
        if cutoff < 0.015 {
            hpfNode.bands[0].bypass = true
            return
        }
        hpfNode.bands[0].bypass = false
        hpfNode.bands[0].frequency = max(20, min(20000, 20.0 * pow(100.0, cutoff)))
    }

    func setLPF(cutoff: Float) {
        if cutoff < 0.015 {
            lpfNode.bands[0].bypass = true
            return
        }
        lpfNode.bands[0].bypass = false
        lpfNode.bands[0].frequency = max(20, min(20000, 20000.0 * pow(0.01, cutoff)))
    }

    func setLPFResonance(_ bandwidth: Float) {
        lpfNode.bands[0].bandwidth = max(0.05, min(4.0, bandwidth))
    }

    func setReverb(amount: Float) {
        reverbNode.wetDryMix = max(0, min(100, amount * 100))
    }

    func setHPFResonance(_ bandwidth: Float) {
        hpfNode.bands[0].bandwidth = max(0.05, min(4.0, bandwidth))
    }

    func setDelay(time: Double, feedback: Float, wet: Float, lowPassCutoff: Float = 22050) {
        delayNode.delayTime = max(0, min(2.0, time))
        delayNode.feedback = max(-100, min(100, feedback * 100))
        delayNode.wetDryMix = max(0, min(100, wet * 100))
        delayNode.lowPassCutoff = max(10, min(22050, lowPassCutoff))
    }

    func setLoFi(wet: Float) {
        distortionNode.wetDryMix = max(0, min(100, wet * 100))
    }

    func setGateVolume(_ volume: Float) {
        gateNode.outputVolume = max(0, min(1, volume))
    }

    func resetFXNodes() {
        delayNode.wetDryMix = 0
        distortionNode.wetDryMix = 0
        gateNode.outputVolume = 1.0
    }

    func setReverbPreset(_ name: String) {
        switch name {
        case "Hall":     reverbNode.loadFactoryPreset(.largeHall)
        case "Plate":    reverbNode.loadFactoryPreset(.plate)
        case "Chamber":  reverbNode.loadFactoryPreset(.mediumChamber)
        default:         reverbNode.loadFactoryPreset(.smallRoom)
        }
    }

    func snapshot() -> PlaybackSnapshot {
        let currentFrame = currentPlaybackFrame()
        let duration = durationSeconds
        let currentTime = seconds(forFrame: currentFrame)
        let progress = duration > 0 ? currentTime / duration : 0

        return PlaybackSnapshot(
            isLoaded: audioFile != nil,
            isPlaying: playerNode.isPlaying,
            progress: min(max(progress, 0), 1),
            currentTime: currentTime,
            duration: duration,
            rate: currentRate,
            pitchPercent: pitchPercent,
            sampleRate: fileSampleRate
        )
    }

    // MARK: - Engine setup

    private func setupGraph() {
        engine.attach(playerNode)
        engine.attach(speedNode)
        engine.attach(pitchNode)
        engine.attach(hpfNode)
        engine.attach(lpfNode)
        engine.attach(eqNode)
        engine.attach(distortionNode)
        engine.attach(delayNode)
        engine.attach(reverbNode)
        engine.attach(gateNode)

        engine.connect(playerNode, to: speedNode, format: nil)
        engine.connect(speedNode, to: pitchNode, format: nil)
        engine.connect(pitchNode, to: hpfNode, format: nil)
        engine.connect(hpfNode, to: lpfNode, format: nil)
        engine.connect(lpfNode, to: eqNode, format: nil)
        engine.connect(eqNode, to: distortionNode, format: nil)
        engine.connect(distortionNode, to: delayNode, format: nil)
        engine.connect(delayNode, to: reverbNode, format: nil)
        engine.connect(reverbNode, to: gateNode, format: nil)
        engine.connect(gateNode, to: engine.mainMixerNode, format: nil)

        // drumsBitBrush: warm bit-reduction + soft saturation — musical lo-fi degradation
        // (multiDecimated2 was too harsh / produced random noise artefacts)
        distortionNode.loadFactoryPreset(.drumsBitBrush)
        distortionNode.wetDryMix = 0

        delayNode.wetDryMix = 0

        reverbNode.loadFactoryPreset(.smallRoom)
        reverbNode.wetDryMix = 0

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: nil) { [weak self] buffer, _ in
            // This closure runs on the CoreAudio render thread — minimal work only.
            guard let self, self.isUserPlaying else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount >= self.fftSize else { return }
            // Memcpy into pre-allocated staging buffer — no Array allocation on render thread.
            let n = self.fftSize
            self.tapSampleBuffer.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.initialize(from: channelData, count: n)
            }
            let sampleRate = Float(buffer.format.sampleRate)
            // The Array value-copy below happens inside the async closure, which executes
            // on spectrumQueue — NOT on the render thread. The render thread only pays for
            // the DispatchQueue.async enqueue (a single lock + pointer write).
            self.spectrumQueue.async { [weak self] in
                guard let self else { return }
                // Copy from staging buffer on spectrumQueue thread (not render thread).
                let samples = self.tapSampleBuffer
                self.processSpectrum(samples: samples, sampleRate: sampleRate)
            }
        }

        ensureEngineRunning()

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }
    }

    private func handleEngineConfigurationChange() {
        guard !suppressConfigChange else { return }
        let wasPlaying = isUserPlaying   // use intent flag — playerNode.isPlaying may already be false
        let frame = currentPlaybackFrame()

        progressTimer?.invalidate()
        progressTimer = nil
        isScheduled = false
        let token = bumpToken()          // cancels pending scheduling (checked in schedulePCMChunk)
        playerNode.stop()                // flush queued buffers

        ensureEngineRunning()

        guard audioFile != nil else { return }
        if frame < (audioFile?.length ?? 0) {
            scheduleFrom(frame: frame, token: token)
        }
        if wasPlaying {
            playerNode.play()
            startProgressTimer()
            beginAudioActivity()
        }
    }

    private func setupFilterNodes() {
        let hp = hpfNode.bands[0]
        hp.filterType = .resonantHighPass
        hp.frequency = 20
        hp.bandwidth = 1.0
        hp.gain = 0
        hp.bypass = true

        let lp = lpfNode.bands[0]
        lp.filterType = .resonantLowPass
        lp.frequency = 20000
        lp.bandwidth = 1.0
        lp.gain = 0
        lp.bypass = true
    }

    private func setupEQBands() {
        for (index, frequency) in Self.bandFrequencies.enumerated() {
            let band = eqNode.bands[index]
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
    }

    private func ensureEngineRunning() {
        guard !engine.isRunning else { return }

        do {
            try engine.start()
        } catch {
            let msg = "engine start failed: \(error)"
            print("[AudioEngineNext] \(msg)")
            onError?(msg)
        }
    }

    private func beginAudioActivity() {
        guard audioActivity == nil else { return }
        audioActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "GONE audio playback"
        )
    }

    private func endAudioActivity() {
        guard let activity = audioActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        audioActivity = nil
    }

    // Full engine shutdown — called during Clone Mode deactivation after playerNode.stop().
    // Stops the AVAudioEngine I/O unit entirely, releasing the shared hardware device slot
    // and preventing the secondary render thread from interfering with the primary engine.
    func stopEngine() {
        engine.stop()
    }

    // MARK: - Scheduling and progress

    private var hasScheduledAudio: Bool {
        isScheduled || playerNode.isPlaying
    }

    private func scheduleFrom(frame: AVAudioFramePosition, token: UInt64) {
        guard let url = currentURL, let file = audioFile else { return }

        let startFrame = max(0, min(frame, file.length))
        let totalFrames = file.length
        let remainingFrames = totalFrames - startFrame
        guard remainingFrames > 0 else {
            isScheduled = false
            pausedFrameOffset = file.length
            emitProgress(currentFrame: file.length)
            return
        }

        scheduledStartFrame = startFrame
        pausedFrameOffset = startFrame
        isScheduled = true

        let chunkFrames = AVAudioFrameCount(prefetchChunkSeconds * fileSampleRate)
        let fmt = file.processingFormat

        // First chunk synchronously — PCM must be in RAM before playerNode.play()
        bufferQueue.sync {
            schedulePCMChunk(url: url, format: fmt, startFrame: startFrame,
                             chunkFrames: chunkFrames, totalFrames: totalFrames, token: token)
        }

        // Pre-fill remaining prefetchDepth-1 chunks in the background
        for depth in 1..<prefetchDepth {
            let chunkStart = startFrame + AVAudioFramePosition(chunkFrames) * AVAudioFramePosition(depth)
            guard chunkStart < totalFrames else { break }
            bufferQueue.async { [weak self] in
                guard let self, token == self.playbackToken else { return }
                self.schedulePCMChunk(url: url, format: fmt, startFrame: chunkStart,
                                      chunkFrames: chunkFrames, totalFrames: totalFrames, token: token)
            }
        }
    }

    // Reads one PCM chunk from disk and hands it to playerNode.scheduleBuffer.
    // Called on bufferQueue — never on the render thread. Each call opens its
    // own AVAudioFile so framePosition cursors never collide.
    private func schedulePCMChunk(url: URL, format: AVAudioFormat,
                                   startFrame: AVAudioFramePosition,
                                   chunkFrames: AVAudioFrameCount,
                                   totalFrames: AVAudioFramePosition,
                                   token: UInt64) {
        guard token == playbackToken else { return }

        let remaining = totalFrames - startFrame
        guard remaining > 0 else { return }

        let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else { return }

        do {
            let chunkFile = try AVAudioFile(forReading: url)
            chunkFile.framePosition = startFrame
            try chunkFile.read(into: buffer, frameCount: framesToRead)
        } catch {
            return
        }

        // Second check after disk I/O: token may have changed while reading
        guard token == playbackToken else { return }

        let nextStart = startFrame + AVAudioFramePosition(framesToRead)
        let isLastChunk = nextStart >= totalFrames

        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }

            if isLastChunk {
                DispatchQueue.main.async {
                    guard token == self.playbackToken else { return }
                    self.progressTimer?.invalidate()
                    self.isScheduled = false
                    self.pausedFrameOffset = totalFrames
                    self.emitProgress(currentFrame: totalFrames)
                    self.onFinished?()
                }
            } else {
                // Keep prefetchDepth buffers ahead: as each chunk plays out,
                // schedule one more chunk prefetchDepth positions forward.
                let prefetchStart = nextStart + AVAudioFramePosition(chunkFrames) * AVAudioFramePosition(self.prefetchDepth - 1)
                guard prefetchStart < totalFrames else { return }
                self.bufferQueue.async { [weak self] in
                    guard let self, token == self.playbackToken else { return }
                    self.schedulePCMChunk(url: url, format: format, startFrame: prefetchStart,
                                          chunkFrames: chunkFrames, totalFrames: totalFrames, token: token)
                }
            }
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            self?.tickProgress()
        }
        RunLoop.main.add(progressTimer!, forMode: .common)
    }

    private func tickProgress() {
        emitProgress(currentFrame: currentPlaybackFrame())
    }

    private func emitProgress(currentFrame: AVAudioFramePosition) {
        guard audioFile != nil else {
            onProgress?(0, 0)
            return
        }

        let duration = durationSeconds
        let currentTime = min(seconds(forFrame: currentFrame), duration)
        let progress = duration > 0 ? currentTime / duration : 0
        onProgress?(min(max(progress, 0), 1), currentTime)
    }

    // Real-time playback position — sample-accurate, bypasses the 24fps progress timer.
    // Used by hot cue SET so the saved position is not stale.
    var currentPlaybackRatio: Double {
        guard let file = audioFile, file.length > 0 else { return 0 }
        return Double(currentPlaybackFrame()) / Double(file.length)
    }

    private func currentPlaybackFrame() -> AVAudioFramePosition {
        guard let file = audioFile else { return 0 }

        if playerNode.isPlaying,
           let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
           playerTime.sampleTime >= 0 {
            let elapsedSeconds = Double(playerTime.sampleTime) / playerTime.sampleRate
            let frame = scheduledStartFrame + AVAudioFramePosition(elapsedSeconds * fileSampleRate)
            let clamped = max(0, min(frame, file.length))
            pausedFrameOffset = clamped
            return clamped
        }

        return max(0, min(pausedFrameOffset, file.length))
    }

    private func seconds(forFrame frame: AVAudioFramePosition) -> Double {
        frame > 0 ? Double(frame) / fileSampleRate : 0
    }

    // MARK: - Pitch

    private func applyPitchState() {
        let clampedPercent = max(-99.0, pitchPercent)
        let rate = max(0.25, min(4.0, 1.0 + clampedPercent / 100.0))
        let atNeutral = abs(rate - 1.0) < 0.001
        currentRate = rate

        if masterTempo {
            speedNode.rate = 1.0
            if atNeutral {
                // Bypass TimePitch entirely at 1.0x — active algorithm introduces
                // phase/spectral artifacts even at neutral settings.
                pitchNode.bypass = true
            } else {
                pitchNode.bypass = false
                pitchNode.rate = Float(rate)
                pitchNode.pitch = 0
            }
        } else {
            // Varispeed changes both pitch and tempo; TimePitch not needed.
            pitchNode.bypass = true
            pitchNode.rate = 1.0
            pitchNode.pitch = 0
            speedNode.rate = Float(rate)
        }
    }

    // MARK: - Spectrum

    private func processSpectrum(samples: [Float], sampleRate: Float) {
        guard let fftSetup else { return }

        vDSP_vmul(samples, 1, hannWindow, 1, &fftWindowed, 1, vDSP_Length(fftSize))

        fftReal.withUnsafeMutableBufferPointer { realBuffer in
            fftImag.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                fftWindowed.withUnsafeBufferPointer { sourceBuffer in
                    sourceBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexBuffer in
                        vDSP_ctoz(complexBuffer, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))
                fftMagnitudes.withUnsafeMutableBufferPointer { magnitudeBuffer in
                    var copy = split
                    vDSP_zvmags(&copy, 1, magnitudeBuffer.baseAddress!, 1, vDSP_Length(fftSize / 2))
                }
            }
        }

        let binWidth: Float = sampleRate / Float(fftSize)
        let logMin = log10(Float(55))
        let logMax = log10(Float(18000))
        fftBars.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.initialize(repeating: 0, count: spectrumBars)
        }

        for barIndex in 0..<spectrumBars {
            let lowerFrequency = pow(10, logMin + (logMax - logMin) * Float(barIndex) / Float(spectrumBars))
            let upperFrequency = pow(10, logMin + (logMax - logMin) * Float(barIndex + 1) / Float(spectrumBars))
            let lowerIndex = max(0, Int(lowerFrequency / binWidth))
            let upperIndex = min(fftMagnitudes.count - 1, Int(upperFrequency / binWidth))
            guard lowerIndex <= upperIndex else { continue }
            var peak: Float = 0
            fftMagnitudes.withUnsafeBufferPointer { magnitudesBuffer in
                guard let base = magnitudesBuffer.baseAddress else { return }
                vDSP_maxv(base.advanced(by: lowerIndex), 1, &peak, vDSP_Length(upperIndex - lowerIndex + 1))
            }
            fftBars[barIndex] = peak
        }

        for index in 0..<fftBars.count {
            let db = 10 * log10(max(1e-10, fftBars[index]))
            let normalized: Float
            if index < 8 {
                normalized = max(0, min(1, (db - 20) / 30))   // bass  ~55–200 Hz
            } else if index < 19 {
                normalized = max(0, min(1, (db + 10) / 50))   // mids  ~200 Hz–2.5 kHz
            } else {
                normalized = max(0, min(1, (db + 10) / 40))   // highs ~2.5 kHz–18 kHz: +25% boost
            }
            let v = normalized * 0.24
            if v > spectrumSmooth[index] {
                spectrumSmooth[index] = spectrumSmooth[index] * 0.10 + v * 0.90
            } else {
                spectrumSmooth[index] = spectrumSmooth[index] * 0.28 + v * 0.72
            }
        }

        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastSpectrumEmit >= 1.0 / 30.0 else { return }
        lastSpectrumEmit = now
        let result = spectrumSmooth
        DispatchQueue.main.async { [weak self] in
            self?.onSpectrum?(result)
        }
    }
}
