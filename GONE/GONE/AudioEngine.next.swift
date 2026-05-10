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
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var pausedFrameOffset: AVAudioFramePosition = 0
    private var progressTimer: Timer?
    private var playbackToken: UInt64 = 0
    private var isScheduled = false
    private var configChangeObserver: NSObjectProtocol?

    private var pitchPercent: Double = 0
    private var masterTempo = true
    private var currentRate: Double = 1.0
    private var isUserPlaying = false   // tracks user intent, not hardware node state

    // Pre-decoded PCM prefetch — keeps 15s of audio in RAM so the render
    // thread never blocks on disk I/O or a compressed-format decoder.
    private let bufferQueue = DispatchQueue(label: "gone.audio.prefetch", qos: .userInteractive)
    private let prefetchChunkSeconds: Double = 5.0
    private let prefetchDepth: Int = 3  // chunks queued ahead (3 × 5s = 15s)

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

    private let spectrumQueue = DispatchQueue(label: "gone.spectrum", qos: .utility)
    private var audioActivity: NSObjectProtocol?

    init() {
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        hannWindow = window
        fftWindowed = Array(repeating: 0, count: fftSize)
        fftReal = Array(repeating: 0, count: fftSize / 2)
        fftImag = Array(repeating: 0, count: fftSize / 2)
        fftMagnitudes = Array(repeating: 0, count: fftSize / 2)
        fftBars = Array(repeating: 0, count: spectrumBars)
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(FFT_RADIX2))

        setupGraph()
        setupEQBands()
        setupFilterNodes()
        applyPitchState()
    }

    deinit {
        progressTimer?.invalidate()
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
            playbackToken &+= 1
            scheduleFrom(frame: 0, token: playbackToken)
            emitProgress(currentFrame: 0)

            if autoplay {
                play()
            }
        } catch {
            audioFile = nil
            currentURL = nil
            print("[AudioEngineNext] load failed: \(error)")
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
            playbackToken &+= 1
            scheduleFrom(frame: pausedFrameOffset, token: playbackToken)
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

    func stop(resetProgress: Bool = true) {
        isUserPlaying = false
        playbackToken &+= 1             // cancel pending scheduling before flush
        bufferQueue.sync {              // drain any in-flight schedulePCMChunk
            self.playerNode.stop()      // flush all queued buffers only after drain
        }
        progressTimer?.invalidate()
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
            emitProgress(currentFrame: 0)
        } else {
            pausedFrameOffset = currentPlaybackFrame()
            emitProgress(currentFrame: pausedFrameOffset)
        }
    }

    func seek(ratio: Double, autoplay: Bool? = nil) {
        guard let file = audioFile else { return }

        let clampedRatio = max(0, min(1, ratio))
        let targetFrame = AVAudioFramePosition(Double(file.length) * clampedRatio)
        let shouldResume = autoplay ?? playerNode.isPlaying

        progressTimer?.invalidate()
        playbackToken &+= 1             // cancel pending scheduling before flush
        bufferQueue.sync {              // drain any in-flight schedulePCMChunk
            self.playerNode.stop()      // flush all queued buffers only after drain
        }

        scheduledStartFrame = targetFrame
        pausedFrameOffset = targetFrame
        scheduleFrom(frame: targetFrame, token: playbackToken)
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
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
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
            guard let self, self.isUserPlaying else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount >= self.fftSize else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: self.fftSize))
            let sampleRate = Float(buffer.format.sampleRate)
            self.spectrumQueue.async { [weak self] in
                self?.processSpectrum(samples: samples, sampleRate: sampleRate)
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
        let wasPlaying = isUserPlaying   // use intent flag — playerNode.isPlaying may already be false
        let frame = currentPlaybackFrame()

        progressTimer?.invalidate()
        progressTimer = nil
        isScheduled = false
        playbackToken &+= 1              // cancel pending scheduling before flush
        bufferQueue.sync {               // drain any in-flight schedulePCMChunk
            self.playerNode.stop()       // flush all queued buffers only after drain
        }
        let token = playbackToken

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
            print("[AudioEngineNext] engine start failed: \(error)")
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
