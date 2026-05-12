import AVFoundation
import Accelerate
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class LibraryScanner {

    static let supportedExtensions: Set<String> = ["mp3", "flac", "wav", "aiff", "aif", "m4a", "aac"]

    func audioURLs(in folderURL: URL) -> [URL] {
        collectAudioURLs(in: folderURL)
    }

    func expandImportURLs(_ urls: [URL]) -> [URL] {
        var expanded: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                expanded.append(contentsOf: collectAudioURLs(in: url))
            } else if Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
                expanded.append(url)
            }
        }

        return expanded
    }

    func placeholderTrack(url: URL, id: UUID = UUID()) -> Track {
        Track(
            id: id,
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            artist: "",
            album: "",
            duration: 0,
            bpm: 0,
            key: "—",
            format: formatName(ext: url.pathExtension.lowercased()),
            bitrate: 0,
            sampleRate: 0,
            rating: 0,
            hasArtwork: false,
            waveform: [],
            isMissing: !FileManager.default.fileExists(atPath: url.path),
            bpmAnalysisState: .pending
        )
    }

    func readMetadata(url: URL, id: UUID? = nil) async -> Track? {
        let trackId = id ?? UUID()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Track(
                id: trackId, url: url,
                title: url.deletingPathExtension().lastPathComponent,
                artist: "—", album: "—",
                duration: 0, bpm: 0, key: "—",
                format: url.pathExtension.uppercased(),
                bitrate: 0, sampleRate: 0,
                rating: 0, hasArtwork: false, waveform: [],
                isMissing: true,
                bpmAnalysisState: .failed
            )
        }

        let asset = AVURLAsset(url: url)

        // Duration
        let duration: Double
        let cmDuration = try? await asset.load(.duration)
        duration = cmDuration.map { CMTimeGetSeconds($0) } ?? 0

        // Format & bitrate
        let ext = url.pathExtension.lowercased()
        let format = formatName(ext: ext)

        var bitrate = 0
        var sampleRate: Double = 0
        if let tracks = try? await asset.loadTracks(withMediaType: .audio),
           let audioTrack = tracks.first,
           let desc = try? await audioTrack.load(.formatDescriptions).first {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
            let sr = asbd?.pointee.mSampleRate ?? 0
            sampleRate = sr
            let bitsPerChannel = asbd?.pointee.mBitsPerChannel ?? 0
            let channelsPerFrame = asbd?.pointee.mChannelsPerFrame ?? 0
            if bitsPerChannel > 0 {
                bitrate = Int(sr * Double(bitsPerChannel) * Double(channelsPerFrame) / 1000)
            }
        }

        // Metadata
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        var bpm: Double = 0
        var key = ""
        var artworkData: Data?

        let metadata = try? await asset.load(.commonMetadata)
        for item in metadata ?? [] {
            guard let commonKey = item.commonKey else { continue }
            switch commonKey {
            case .commonKeyTitle:
                title = (try? await item.load(.stringValue)) ?? title
            case .commonKeyArtist:
                artist = (try? await item.load(.stringValue)) ?? ""
            case .commonKeyAlbumName:
                album = (try? await item.load(.stringValue)) ?? ""
            case .commonKeyArtwork:
                artworkData = await loadArtworkData(from: item)
            default: break
            }
        }

        // BPM from ID3 "TBPM" frame
        let id3Meta = try? await asset.loadMetadata(for: .id3Metadata)
        let bpmItems = AVMetadataItem.metadataItems(
            from: id3Meta ?? [], withKey: "TBPM", keySpace: .id3)
        if let val = try? await bpmItems.first?.load(.stringValue),
           let bpmVal = Double(val.trimmingCharacters(in: .whitespaces)),
           bpmVal.isFinite && bpmVal > 0 && bpmVal < 1000 {
            bpm = bpmVal
        }

        // Camelot key from ID3 "TKEY"
        let keyItems = AVMetadataItem.metadataItems(
            from: id3Meta ?? [], withKey: "TKEY", keySpace: .id3)
        if let val = try? await keyItems.first?.load(.stringValue) {
            key = val
        }

        // iTunes BPM fallback (tmpo atom)
        let itunesMeta = try? await asset.loadMetadata(for: .iTunesMetadata)
        if bpm == 0 {
            let tmpoItems = AVMetadataItem.metadataItems(
                from: itunesMeta ?? [], withKey: "tmpo", keySpace: .iTunes)
            if let val = try? await tmpoItems.first?.load(.numberValue) {
                bpm = val.doubleValue
            }
        }

        // Artwork fallbacks: ID3 APIC frame (AIFF/MP3), then iTunes covr
        if artworkData == nil {
            let apicItems = AVMetadataItem.metadataItems(
                from: id3Meta ?? [], withKey: "APIC", keySpace: .id3)
            if let item = apicItems.first {
                artworkData = await loadArtworkData(from: item)
            }
        }
        if artworkData == nil {
            let coverItems = AVMetadataItem.metadataItems(
                from: itunesMeta ?? [], withKey: "covr", keySpace: .iTunes)
            if let item = coverItems.first {
                artworkData = await loadArtworkData(from: item)
            }
        }
        if artworkData == nil {
            let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
            for format in formats {
                let items = (try? await asset.loadMetadata(for: format)) ?? []
                for item in items {
                    let identifier = item.identifier?.rawValue.lowercased() ?? ""
                    let isArtworkItem =
                        item.commonKey == .commonKeyArtwork ||
                        identifier.contains("artwork") ||
                        identifier.contains("coverart") ||
                        identifier.contains("attachedpicture") ||
                        identifier.contains("covr") ||
                        identifier.contains("apic")

                    guard isArtworkItem else { continue }
                    if let data = await loadArtworkData(from: item) {
                        artworkData = data
                        break
                    }
                }
                if artworkData != nil { break }
            }
        }
        if artworkData == nil {
            artworkData = fallbackArtworkData(
                near: url,
                title: title,
                artist: artist,
                album: album
            )
        }
        // Move artwork bytes into ArtworkCache immediately — eliminates multi-MB Data in Track array.
        let hasArtwork: Bool
        if let data = artworkData, let img = NSImage(data: data) {
            ArtworkCache.shared.store(img, for: trackId)
            hasArtwork = true
        } else {
            hasArtwork = false
        }
        return Track(
            id: trackId, url: url,
            title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
            artist: artist, album: album,
            duration: duration, bpm: bpm,
            key: key.isEmpty ? "—" : key,
            format: format,
            bitrate: isLossless(ext: ext) ? 0 : bitrate,
            sampleRate: sampleRate,
            rating: 0,
            hasArtwork: hasArtwork,
            waveform: [],
            isMissing: false,
            bpmAnalysisState: bpm > 0 ? .analyzed : .pending
        )
    }

    // ── Waveform (called after track is shown in UI) ──────────────────────────

    func computeWaveform(url: URL, bars: Int = 200) async -> [Float] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let assetDuration = (try? await asset.load(.duration)) ?? .zero

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 11025.0,
        ]

        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        let decodedSampleRate: Double = 11025
        let expectedFrames = max(1, Int(CMTimeGetSeconds(assetDuration) * decodedSampleRate))
        let bucketSize = max(1, expectedFrames / max(1, bars))
        var envelope = [Float](repeating: 0, count: bars)
        var bucketIndex = 0
        var bucketCount = 0
        var bucketPeak: Float = 0
        var bucketSumSquares: Float = 0

        @inline(__always)
        func commitBucket() {
            guard bucketIndex < bars, bucketCount > 0 else { return }
            let rms = sqrt(bucketSumSquares / Float(bucketCount))
            envelope[bucketIndex] = bucketPeak * 0.62 + rms * 0.38
        }

        while let buf = output.copyNextSampleBuffer(),
              let blockBuf = CMSampleBufferGetDataBuffer(buf) {
            let length = CMBlockBufferGetDataLength(blockBuf)
            var data = [Int16](repeating: 0, count: length / 2)
            CMBlockBufferCopyDataBytes(blockBuf, atOffset: 0, dataLength: length, destination: &data)

            for sample in data {
                let value = abs(Float(sample) / 32768.0)
                bucketPeak = max(bucketPeak, value)
                bucketSumSquares += value * value
                bucketCount += 1

                if bucketCount >= bucketSize {
                    commitBucket()
                    bucketIndex += 1
                    if bucketIndex >= bars { break }
                    bucketCount = 0
                    bucketPeak = 0
                    bucketSumSquares = 0
                }
            }

            if bucketIndex >= bars { break }
        }
        reader.cancelReading()

        if bucketIndex < bars, bucketCount > 0 {
            commitBucket()
        }
        guard envelope.contains(where: { $0 > 0 }) else { return [] }

        let trend = movingAverage(envelope, radius: 3)
        var relief = envelope
        for i in relief.indices {
            let contour = max(0, envelope[i] - trend[i] * 0.78)
            relief[i] = envelope[i] * 0.54 + contour * 1.38
        }

        let normalizedBy = max(0.0001, percentile(relief, q: 0.97))
        var normalized = relief.map { min(1.85, max(0, $0 / normalizedBy)) }
        normalized = movingAverage(normalized, radius: 1)

        return normalized.map { value in
            let compressed = log1pf(value * 3.3) / log1pf(3.3)
            let shaped = pow(compressed, 0.74)
            return min(0.90, max(0.04, shaped))
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func formatName(ext: String) -> String {
        switch ext {
        case "mp3":         return "MP3"
        case "flac":        return "FLAC"
        case "wav":         return "WAV"
        case "aiff", "aif": return "AIFF"
        case "m4a", "aac":  return "AAC"
        default:            return ext.uppercased()
        }
    }

    private func isLossless(ext: String) -> Bool {
        ["flac", "wav", "aiff", "aif"].contains(ext)
    }

    private func collectAudioURLs(in folderURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            if let vals = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
               vals.isSymbolicLink == true { continue }
            if Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                urls.append(fileURL)
            }
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func percentile(_ values: [Float], q: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clampedQ = min(max(q, 0), 1)
        let index = Int(roundf(clampedQ * Float(sorted.count - 1)))
        return sorted[index]
    }

    private func movingAverage(_ values: [Float], radius: Int) -> [Float] {
        guard !values.isEmpty, radius > 0 else { return values }

        var result = values
        for index in values.indices {
            let lower = max(values.startIndex, index - radius)
            let upper = min(values.endIndex - 1, index + radius)
            let slice = values[lower...upper]
            let sum = slice.reduce(Float.zero, +)
            result[index] = sum / Float(slice.count)
        }
        return result
    }

    private func loadArtworkData(from item: AVMetadataItem) async -> Data? {
        if let data = try? await item.load(.dataValue), !data.isEmpty {
            return normalizedArtworkData(from: data)
        }

        if let value = try? await item.load(.value) {
            if let data = value as? Data, !data.isEmpty {
                return normalizedArtworkData(from: data)
            }

            if let image = value as? NSImage {
                return normalizedArtworkData(from: image)
            }

            if let dict = value as? NSDictionary {
                if let data = dict["data"] as? Data, !data.isEmpty {
                    return normalizedArtworkData(from: data)
                }
                if let image = dict["image"] as? NSImage {
                    return normalizedArtworkData(from: image)
                }
            }
        }

        return nil
    }

    private func fallbackArtworkData(near audioURL: URL, title: String, artist: String, album: String) -> Data? {
        let folderURL = audioURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        let candidateNames = [
            "cover", "folder", "front", "artwork", "album", "thumb",
            sanitizedArtworkKey(album),
            sanitizedArtworkKey(artist),
            sanitizedArtworkKey(title),
            audioURL.deletingPathExtension().lastPathComponent
        ].filter { !$0.isEmpty }
        let candidateExtensions = ["png", "jpg", "jpeg", "webp", "gif", "tiff"]

        for baseName in candidateNames {
            for ext in candidateExtensions {
                let candidateURL = folderURL.appendingPathComponent("\(baseName).\(ext)")
                guard fileManager.fileExists(atPath: candidateURL.path),
                      let data = try? Data(contentsOf: candidateURL),
                      let normalized = normalizedArtworkData(from: data)
                else { continue }
                return normalized
            }
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let fallbackImage = contents.first { url in
            candidateExtensions.contains(url.pathExtension.lowercased())
        }

        guard let fallbackImage,
              let data = try? Data(contentsOf: fallbackImage)
        else {
            return nil
        }

        return normalizedArtworkData(from: data)
    }

    private func sanitizedArtworkKey(_ value: String) -> String {
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitized.contains("..") else { return "" }
        return sanitized
    }

    private func normalizedArtworkData(from data: Data, maxPixelSize: CGFloat = 256) -> Data? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let type = CGImageSourceGetType(source),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
           ] as CFDictionary) {
            let destinationData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(destinationData, type, 1, nil) ??
                    CGImageDestinationCreateWithData(destinationData, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return destinationData as Data
        }

        if NSImage(data: data) != nil {
            return data
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return normalizedArtworkData(from: NSImage(cgImage: cgImage, size: .zero))
    }

    private func readBPMSamples(asset: AVURLAsset, assetTrack: AVAssetTrack,
                                settings: [String: Any],
                                startSec: Double, windowSec: Double,
                                onProgress: ((Double) -> Void)? = nil) async -> [Float] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start:    CMTime(seconds: startSec,  preferredTimescale: 44100),
            duration: CMTime(seconds: windowSec, preferredTimescale: 44100)
        )
        reader.startReading()

        let targetSamples = 11025 * 20
        var samples: [Float] = []
        var lastReportedPct = 0.0
        samples.reserveCapacity(targetSamples)
        while let buf = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buf) {
            let len = CMBlockBufferGetDataLength(block)
            var raw = [Int16](repeating: 0, count: len / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: &raw)
            samples.append(contentsOf: raw.map { Float($0) / 32768.0 })
            if let onProgress {
                let pct = Double(min(samples.count, targetSamples)) / Double(targetSamples)
                if pct - lastReportedPct >= 0.08 {
                    lastReportedPct = pct
                    onProgress(pct)
                }
            }
            if samples.count >= targetSamples { break }
        }
        reader.cancelReading()
        return samples
    }

    private func normalizedArtworkData(from image: NSImage) -> Data? {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    // ── Combined decode: BPM + waveform in one AVAssetReader pass ────────────

    // Full-track decode at 11025 Hz mono → waveform from all samples, BPM from 30s window.
    // Eliminates the second AVAssetReader open that computeWaveform would otherwise require.
    func analyzeBPMWithWaveform(url: URL, floor: Double = 60, ceiling: Double = 200,
                                waveformBars: Int = 84,
                                onProgress: ((Double) -> Void)? = nil) async -> (bpm: Double, waveform: [Float], beatGridOffset: Double, gridConfidence: Double) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first else { return (0, [], 0, 0) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 11025.0,
        ]

        let totalSec = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        guard let reader = try? AVAssetReader(asset: asset) else { return (0, [], 0, 0) }
        let output = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        let decodedSR: Double = 11025
        let expectedSamples = max(1, Int(totalSec * decodedSR))
        var allSamples: [Float] = []
        allSamples.reserveCapacity(min(expectedSamples, Int(decodedSR * 1200)))
        var lastReportedPct = 0.0

        var scale: Float = 1.0 / 32768.0
        while let buf = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buf) {
            let len   = CMBlockBufferGetDataLength(block)
            let count = len / 2
            var raw   = [Int16](repeating: 0, count: count)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: &raw)
            var converted = [Float](repeating: 0, count: count)
            raw.withUnsafeBufferPointer { src in
                converted.withUnsafeMutableBufferPointer { dst in
                    guard let sp = src.baseAddress, let dp = dst.baseAddress else { return }
                    vDSP_vflt16(sp, 1, dp, 1, vDSP_Length(count))
                    vDSP_vsmul(dp, 1, &scale, dp, 1, vDSP_Length(count))
                }
            }
            allSamples.append(contentsOf: converted)
            if let onProgress {
                let pct = min(0.88, Double(allSamples.count) / Double(max(1, expectedSamples)))
                if pct - lastReportedPct >= 0.08 { lastReportedPct = pct; onProgress(pct) }
            }
        }
        reader.cancelReading()
        guard allSamples.count > 11025 else { return (0, [], 0, 0) }

        let effectiveSec = totalSec > 0 ? totalSec : Double(allSamples.count) / decodedSR
        let waveform = computeWaveformFromSamples(allSamples, totalSec: effectiveSec, bars: waveformBars)

        let windowSec = min(30.0, effectiveSec)
        let startSec  = effectiveSec > 50 ? 15.0 : 0.0
        let startIdx  = Int(startSec * decodedSR)
        let endIdx    = min(allSamples.count, startIdx + Int(windowSec * decodedSR))
        let bpmSlice  = startIdx < endIdx ? Array(allSamples[startIdx..<endIdx]) : allSamples
        let bpm = computeBPMFromSamples(bpmSlice, floor: floor, ceiling: ceiling)

        var beatGridOffset: Double = 0
        var gridConfidence: Double = 0
        if bpm > 0 {
            // Use the same 30-sec slice as BPM detection, not allSamples.
            // Over a full 4-min track even 0.1 BPM error accumulates ~10 frames of phase drift —
            // the ±2-frame Hann window stops catching kicks, all 256 candidates score equally,
            // z → 0, confidence → 0, no beat grid shown.
            // Within 30 sec the drift stays < 2 frames, z-score stays high.
            let onset = computeOnset(from: bpmSlice, hopSize: 128)
            let fps   = 11025.0 / 128.0
            var rawOffset: Double = 0
            (rawOffset, gridConfidence) = estimateBeatGridOffset(bpm: bpm, onset: onset, fps: fps)
            // rawOffset is relative to the start of bpmSlice; make it absolute (track-start-relative)
            // by adding startSec and wrapping to [0, beatDur).
            let beatDur = 60.0 / bpm
            beatGridOffset = (startSec + rawOffset).truncatingRemainder(dividingBy: beatDur)
        }

        onProgress?(1.0)
        return (bpm, waveform, beatGridOffset, gridConfidence)
    }

    private func computeBPMFromSamples(_ samples: [Float], floor: Double, ceiling: Double) -> Double {
        let hopSize = 128
        let frameCount = samples.count / hopSize
        var energy = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let start = i * hopSize
            let end   = min(start + hopSize, samples.count)
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                vDSP_svesq(base.advanced(by: start), 1, &rms, vDSP_Length(end - start))
            }
            energy[i] = rms / Float(end - start)
        }
        var onset = [Float](repeating: 0, count: frameCount)
        for i in 1..<frameCount { onset[i] = max(0, energy[i] - energy[i-1]) }

        let fps    = 11025.0 / Double(hopSize)
        let minLag = max(1, Int(fps * 60.0 / max(ceiling, floor + 1)))
        let maxLag = Int(fps * 60.0 / max(floor, 1))
        guard minLag < maxLag, maxLag < frameCount else { return 0 }

        let analysisLen   = min(frameCount - maxLag, 4096)
        let referenceOnset = onset[0..<analysisLen]
        var corrValues = [Float](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            var corr: Float = 0
            referenceOnset.withUnsafeBufferPointer { refBuf in
                onset.withUnsafeBufferPointer { onsBuf in
                    guard let rb = refBuf.baseAddress, let ob = onsBuf.baseAddress else { return }
                    vDSP_dotpr(rb, 1, ob.advanced(by: lag), 1, &corr, vDSP_Length(analysisLen))
                }
            }
            corrValues[lag] = corr / Float(analysisLen)
        }

        var bestLag = minLag; var bestScore: Float = 0
        for lag in minLag...maxLag {
            let c = corrValues[lag]
            let h2: Float = lag * 2 <= maxLag ? corrValues[lag * 2] * 0.35 : 0
            let h3: Float = lag * 3 <= maxLag ? corrValues[lag * 3] * 0.15 : 0
            let score = c + h2 + h3
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        guard bestScore > 0 else { return 0 }

        let halfLag = bestLag / 2
        if halfLag >= minLag, halfLag <= maxLag, corrValues[halfLag] >= bestScore * 0.82 {
            bestLag = halfLag
        }

        var bpm = 60.0 * fps / Double(bestLag)
        let lo = max(floor, 1); let hi = max(ceiling, lo + 1)
        while bpm > 0 && bpm < lo { bpm *= 2 }
        while bpm > hi { bpm /= 2 }
        return (bpm * 10).rounded() / 10
    }

    private func computeWaveformFromSamples(_ samples: [Float], totalSec: Double, bars: Int) -> [Float] {
        // One-pole HPF — de-emphasizes sustained bass so kick/sub doesn't wall the waveform.
        // alpha = 0.85 → cutoff ≈ 600 Hz at 11 025 Hz. y[n] = α·(y[n−1] + x[n] − x[n−1])
        var src = samples
        var hpfY: Float = 0; var prevX: Float = 0
        for i in 0..<src.count {
            let x = src[i]
            hpfY   = 0.85 * (hpfY + x - prevX)
            src[i] = hpfY
            prevX  = x
        }

        let expectedFrames = max(1, Int(totalSec * 11025))
        let bucketSize     = max(1, expectedFrames / max(1, bars))
        var envelope       = [Float](repeating: 0, count: bars)
        var bucketIndex = 0, bucketCount = 0
        var bucketPeak: Float = 0, bucketSumSquares: Float = 0

        for sample in src {
            let value = abs(sample)
            bucketPeak = max(bucketPeak, value)
            bucketSumSquares += value * value
            bucketCount += 1
            if bucketCount >= bucketSize {
                if bucketIndex < bars {
                    let rms = sqrt(bucketSumSquares / Float(bucketCount))
                    envelope[bucketIndex] = bucketPeak * 0.62 + rms * 0.38
                }
                bucketIndex += 1
                if bucketIndex >= bars { break }
                bucketCount = 0; bucketPeak = 0; bucketSumSquares = 0
            }
        }
        if bucketIndex < bars, bucketCount > 0 {
            let rms = sqrt(bucketSumSquares / Float(bucketCount))
            envelope[bucketIndex] = bucketPeak * 0.62 + rms * 0.38
        }
        guard envelope.contains(where: { $0 > 0 }) else { return [] }

        let trend = movingAverage(envelope, radius: 3)
        var relief = envelope
        for i in relief.indices {
            relief[i] = envelope[i] * 0.54 + max(0, envelope[i] - trend[i] * 0.78) * 1.38
        }
        let normalizedBy = max(0.0001, percentile(relief, q: 0.97))
        let normalized   = movingAverage(relief.map { min(1.85, max(0, $0 / normalizedBy)) }, radius: 1)
        // gamma > 1 → more contrast: quiet bars collapse, transient peaks stay tall.
        // floor 0.01 (was 0.04) lets genuinely silent sections go near-zero.
        return normalized.map { v in min(0.90, max(0.01, pow(log1pf(v * 3.3) / log1pf(3.3), 1.1))) }
    }

    // ── BPM analysis — native Accelerate, no external libs ───────────────────
    // Algorithm: energy envelope → onset strength → autocorrelation → tempo

    func analyzeBPM(url: URL, floor: Double = 60, ceiling: Double = 200, onProgress: ((Double) -> Void)? = nil) async -> Double {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first
        else { return 0 }

        // 11025 Hz mono + hopSize 128 → same fps (≈86.1) as 22050/256, half the data to decode
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 11025.0,
        ]

        let totalSec = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        let windowSec = totalSec > 0 ? min(30.0, totalSec) : 30.0
        // Fixed offset — avoids slow seeks in MP3/AAC (no random access support)
        let startSec = totalSec > 50 ? 15.0 : 0.0

        var samples = await readBPMSamples(asset: asset, assetTrack: assetTrack,
                                           settings: settings,
                                           startSec: startSec,
                                           windowSec: windowSec,
                                           onProgress: onProgress.map { cb in { p in cb(p * 0.90) } })
        if samples.count <= 11025 {
            samples = await readBPMSamples(asset: asset, assetTrack: assetTrack,
                                           settings: settings,
                                           startSec: 0,
                                           windowSec: windowSec,
                                           onProgress: onProgress.map { cb in { p in cb(p * 0.90) } })
        }

        guard samples.count > 11025 else { return 0 }

        // Energy per 128-sample hop (~11.6 ms at 11025 Hz — same resolution as 256 @ 22050)
        let hopSize = 128
        let frameCount = samples.count / hopSize
        var energy = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let start = i * hopSize
            let end   = min(start + hopSize, samples.count)
            var rms: Float = 0
            samples.withUnsafeBufferPointer { sampleBuffer in
                guard let base = sampleBuffer.baseAddress else { return }
                vDSP_svesq(base.advanced(by: start), 1, &rms, vDSP_Length(end - start))
            }
            energy[i] = rms / Float(end - start)
        }

        // Onset strength: half-wave rectified energy differential
        var onset = [Float](repeating: 0, count: frameCount)
        for i in 1..<frameCount { onset[i] = max(0, energy[i] - energy[i-1]) }

        // Autocorrelation in user-defined BPM range
        let fps     = 11025.0 / Double(hopSize)   // ≈86.1 frames/s
        let minLag  = max(1, Int(fps * 60.0 / max(ceiling, floor + 1)))
        let maxLag  = Int(fps * 60.0 / max(floor, 1))
        guard minLag < maxLag, maxLag < frameCount else { return 0 }

        let analysisLen = min(frameCount - maxLag, 4096)
        let referenceOnset = onset[0..<analysisLen]

        // Compute and store all correlations so harmonic weighting can reference them
        var corrValues = [Float](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            var corr: Float = 0
            referenceOnset.withUnsafeBufferPointer { referenceBuffer in
                onset.withUnsafeBufferPointer { onsetBuffer in
                    guard
                        let referenceBase = referenceBuffer.baseAddress,
                        let onsetBase = onsetBuffer.baseAddress
                    else { return }
                    vDSP_dotpr(
                        referenceBase, 1,
                        onsetBase.advanced(by: lag), 1,
                        &corr, vDSP_Length(analysisLen)
                    )
                }
            }
            corrValues[lag] = corr / Float(analysisLen)
        }

        // Harmonic-weighted scoring: true beat period reinforces at 2× and 3× lag
        var bestLag = minLag
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            let c = corrValues[lag]
            let h2: Float = lag * 2 <= maxLag ? corrValues[lag * 2] * 0.35 : 0
            let h3: Float = lag * 3 <= maxLag ? corrValues[lag * 3] * 0.15 : 0
            let score = c + h2 + h3
            if score > bestScore { bestScore = score; bestLag = lag }
        }

        guard bestScore > 0 else { return 0 }

        // Half-tempo correction: if double-tempo (bestLag/2) scores ≥82% of best, prefer it.
        // Fixes 62→124 BPM misdetection common in house/electronic tracks.
        let halfLag = bestLag / 2
        if halfLag >= minLag, halfLag <= maxLag, corrValues[halfLag] >= bestScore * 0.82 {
            bestLag = halfLag
        }

        var bpm = 60.0 * fps / Double(bestLag)
        let lo = max(floor, 1); let hi = max(ceiling, lo + 1)
        while bpm > 0 && bpm < lo { bpm *= 2 }
        while bpm > hi { bpm /= 2 }
        onProgress?(1.0)
        return (bpm * 10).rounded() / 10
    }

    // ── Beat phase detection helpers ──────────────────────────────────────────

    // Half-wave rectified energy differential — same formula used in BPM autocorrelation.
    // Extracted here so BPM analysis and phase detection share one computation.
    private func computeOnset(from samples: [Float], hopSize: Int) -> [Float] {
        let frameCount = samples.count / hopSize
        var energy = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let start = i * hopSize
            let end   = min(start + hopSize, samples.count)
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                vDSP_svesq(base.advanced(by: start), 1, &rms, vDSP_Length(end - start))
            }
            energy[i] = rms / Float(end - start)
        }
        var onset = [Float](repeating: 0, count: frameCount)
        for i in 1..<frameCount { onset[i] = max(0, energy[i] - energy[i-1]) }
        return onset
    }

    // Scans 256 phase candidates in [0, beatDuration) and picks the offset where
    // predicted beat positions land on the strongest onset peaks.
    // Sub-frame refinement via parabolic interpolation with circular boundary wrap.
    // Confidence via z-score: threshold 0.60 (z ≈ 3) to avoid accepting noise.
    // Logic mirrors Pioneer/Traktor: bestOffset is the phase in [0, beatDur).
    private func estimateBeatGridOffset(bpm: Double, onset: [Float], fps: Double) -> (offset: Double, confidence: Double) {
        guard bpm > 0, onset.count > 0 else { return (0, 0) }

        // Normalize onset to peak=1 so confidence is amplitude-independent.
        // Without this, quiet tracks produce all-near-zero scores for every candidate
        // → σ ≈ 0 → z ≈ 0 → confidence ≈ 0, even with a perfectly clear kick pattern.
        var onsetPeak: Float = 0
        vDSP_maxv(onset, 1, &onsetPeak, vDSP_Length(onset.count))
        guard onsetPeak > 0 else { return (0, 0) }
        var invPeak = 1.0 / onsetPeak
        var normOnset = [Float](repeating: 0, count: onset.count)
        vDSP_vsmul(onset, 1, &invPeak, &normOnset, 1, vDSP_Length(onset.count))

        let beatFrames = fps * 60.0 / bpm           // frames per beat (fractional)
        let candidateN = 256
        var scores     = [Double](repeating: 0, count: candidateN)

        // Score each candidate offset by summing onset energy at predicted beat positions.
        // Hann window ±2 frames to tolerate BPM-rounding drift over long tracks.
        // Weights: [0.25, 0.5, 1.0, 0.5, 0.25]
        for ci in 0..<candidateN {
            let offsetFrac = Double(ci) / Double(candidateN)
            var score: Double = 0
            var beatPos = offsetFrac * beatFrames
            while beatPos < Double(normOnset.count) {
                let center = Int(beatPos.rounded())
                for delta in -2...2 {
                    let idx = center + delta
                    guard idx >= 0, idx < normOnset.count else { continue }
                    let weight: Double
                    switch abs(delta) {
                    case 0: weight = 1.00
                    case 1: weight = 0.50
                    default: weight = 0.25
                    }
                    score += Double(normOnset[idx]) * weight
                }
                beatPos += beatFrames
            }
            scores[ci] = score
        }

        // Best candidate
        var bestCI = 0
        var bestScore = scores[0]
        for i in 1..<candidateN {
            if scores[i] > bestScore { bestScore = scores[i]; bestCI = i }
        }

        // Parabolic sub-sample interpolation — circular wrap at phase boundaries.
        // Without wrap, bestCI=0 uses scores[255] as prev; fractionalShift can produce
        // refinedCI < 0, which must wrap back to [0, candidateN) not be clamped to 0.
        let prev = scores[(bestCI - 1 + candidateN) % candidateN]
        let next = scores[(bestCI + 1) % candidateN]
        let denom = 2.0 * (2.0 * bestScore - prev - next)
        let fractionalShift = denom > 0 ? (prev - next) / denom : 0.0
        var refinedCI = Double(bestCI) + fractionalShift
        if refinedCI < 0 { refinedCI += Double(candidateN) }
        if refinedCI >= Double(candidateN) { refinedCI -= Double(candidateN) }

        let bestOffset = refinedCI / Double(candidateN) * (60.0 / bpm)

        // Z-score confidence. Threshold of 0.60 corresponds to z ≈ 3σ above the mean —
        // rejects noise (which produces z ≈ 1.5–2.5 by extreme-value statistics for 256 candidates)
        // while accepting clean 4/4 kick tracks (z ≈ 6–12).
        let mean     = scores.reduce(0, +) / Double(candidateN)
        let variance = scores.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(candidateN)
        let sigma    = variance > 0 ? variance.squareRoot() : 1.0
        let zScore   = sigma > 0 ? (bestScore - mean) / sigma : 0.0
        // Map z to [0, 1): z=3 → 0.60, z=6 → 0.75, z=12 → 0.86
        let confidence = 1.0 - 1.0 / (1.0 + max(0, zScore) * 0.5)

        return (bestOffset, confidence)
    }

    // Deep BPM re-analysis — called on explicit user request (refresh button).
    // Differences from standard analyzeBPM:
    //  • Wide search range 30–280 so half/double-tempo candidates are scored directly
    //  • Longer analysis window (up to 60 s) for better signal quality
    //  • Explicit half-tempo correction: if bestLag/2 scores ≥60% of best, prefer it
    //    (fixes 62→124 BPM misdetection common in electronic/house tracks)
    //  • Final result resolved back into the user's configured floor/ceiling
    func analyzeBPMDeep(url: URL, floor: Double = 60, ceiling: Double = 200, onProgress: ((Double) -> Void)? = nil) async -> Double {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first
        else { return 0 }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 11025.0,
        ]

        let totalSec = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        // Longer window than standard analysis for better autocorrelation quality
        let windowSec = totalSec > 0 ? min(60.0, totalSec) : 60.0
        let startSec  = totalSec > 70 ? 10.0 : 0.0

        var samples = await readBPMSamples(asset: asset, assetTrack: assetTrack,
                                           settings: settings,
                                           startSec: startSec,
                                           windowSec: windowSec,
                                           onProgress: onProgress.map { cb in { p in cb(p * 0.90) } })
        if samples.count <= 11025 {
            samples = await readBPMSamples(asset: asset, assetTrack: assetTrack,
                                           settings: settings,
                                           startSec: 0,
                                           windowSec: windowSec,
                                           onProgress: onProgress.map { cb in { p in cb(p * 0.90) } })
        }
        guard samples.count > 11025 else { return 0 }

        let hopSize   = 128
        let frameCount = samples.count / hopSize
        var energy = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let start = i * hopSize
            let end   = min(start + hopSize, samples.count)
            var rms: Float = 0
            samples.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                vDSP_svesq(base.advanced(by: start), 1, &rms, vDSP_Length(end - start))
            }
            energy[i] = rms / Float(end - start)
        }
        var onset = [Float](repeating: 0, count: frameCount)
        for i in 1..<frameCount { onset[i] = max(0, energy[i] - energy[i-1]) }

        // Wide search: 30–280 BPM — both 62 BPM and 124 BPM are scored directly
        let fps     = 11025.0 / Double(hopSize)
        let wideMin = max(1, Int(fps * 60.0 / 280.0))
        let wideMax = Int(fps * 60.0 / 30.0)
        guard wideMin < wideMax, wideMax < frameCount else { return 0 }

        // Use more of the signal than standard analysis
        let analysisLen = min(frameCount - wideMax, 8192)
        let referenceOnset = onset[0..<analysisLen]

        var corrValues = [Float](repeating: 0, count: wideMax + 1)
        for lag in wideMin...wideMax {
            var corr: Float = 0
            referenceOnset.withUnsafeBufferPointer { refBuf in
                onset.withUnsafeBufferPointer { onsBuf in
                    guard let rb = refBuf.baseAddress, let ob = onsBuf.baseAddress else { return }
                    vDSP_dotpr(rb, 1, ob.advanced(by: lag), 1, &corr, vDSP_Length(analysisLen))
                }
            }
            corrValues[lag] = corr / Float(analysisLen)
        }

        // Harmonic scoring (same as standard)
        var bestLag  = wideMin
        var bestScore: Float = 0
        for lag in wideMin...wideMax {
            let c  = corrValues[lag]
            let h2: Float = lag * 2 <= wideMax ? corrValues[lag * 2] * 0.35 : 0
            let h3: Float = lag * 3 <= wideMax ? corrValues[lag * 3] * 0.15 : 0
            let score = c + h2 + h3
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        guard bestScore > 0 else { return 0 }

        // Half-tempo correction: if bestLag/2 (double tempo) scores ≥60% of best,
        // the double-tempo is a strong candidate — prefer it to avoid half-tempo output.
        let halfLag = bestLag / 2
        if halfLag >= wideMin,
           corrValues[halfLag] >= bestScore * 0.60 {
            bestLag = halfLag
        }

        var bpm = 60.0 * fps / Double(bestLag)
        // Resolve into user's configured range
        let lo = max(floor, 1); let hi = max(ceiling, lo + 1)
        while bpm > 0 && bpm < lo  { bpm *= 2 }
        while bpm > hi { bpm /= 2 }
        onProgress?(1.0)
        return (bpm * 10).rounded() / 10
    }
}
