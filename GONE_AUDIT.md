# GONE Player — Code Audit Fixes

Apply the following fixes in order. Do NOT add new features. Do NOT change the audio graph node order. Do NOT modify WindowSnapManager state machine sequence.

---

## FIX 1 — Spectrum FFT hardcoded sample rate
**File:** `GONE/AudioEngine.next.swift`  
**Problem:** `let binWidth: Float = 44100.0 / Float(fftSize)` — incorrect for 48kHz hardware output  
**Fix:** Capture actual sample rate from the tap buffer format

In `setupGraph()`, inside `installTap` closure, replace the `spectrumQueue.async` call with:
```swift
engine.mainMixerNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(fftSize), format: nil) { [weak self] buffer, _ in
    guard let self, self.playerNode.isPlaying else { return }
    guard let channelData = buffer.floatChannelData?[0] else { return }
    let frameCount = Int(buffer.frameLength)
    guard frameCount >= self.fftSize else { return }
    let samples = Array(UnsafeBufferPointer(start: channelData, count: self.fftSize))
    let sampleRate = buffer.format.sampleRate  // ← actual hardware rate
    self.spectrumQueue.async { [weak self] in
        self?.processSpectrum(samples: samples, sampleRate: Float(sampleRate))
    }
}
```

Change `processSpectrum` signature to `private func processSpectrum(samples: [Float], sampleRate: Float)` and replace:
```swift
let binWidth: Float = 44100.0 / Float(fftSize)
```
with:
```swift
let binWidth: Float = sampleRate / Float(fftSize)
```

---

## FIX 2 — selectNextTrack / selectPreviousTrack loads missing file when all tracks are missing
**File:** `PlayerState+Playback.swift`  
**Problem:** while-loop terminates at `i == idx` when all tracks are missing, then calls `AudioEngineNext.shared.load(current.url)` on a missing track  
**Fix:** Add isMissing guard before load in both `selectNextTrack` and `selectPreviousTrack`

In both methods, after `currentId = list[nextIdx].id`, before the load call:
```swift
guard let current, !current.isMissing else {
    isPlaying = false
    return
}
```

---

## FIX 3 — Drag-to-reorder silently no-ops in sorted modes
**File:** `PlayerState+Playlists.swift`  
**Problem:** `reorderTrack` mutates `trackIds` (canonical order), but if tab's `sortKey != .number`, `sortedTracks()` recomputes order from field values — the reorder has zero visible effect  
**Fix:** When user drags to reorder, switch the tab's sortKey to `.number` first

In `reorderTrack(_:before:inTabId:)`, after the guard block, before mutating `ids`:
```swift
if playlistTabs[tabIndex].sortKey != .number {
    playlistTabs[tabIndex].sortKey = .number
    playlistTabs[tabIndex].sortDir = .asc
}
```

Same in `reorderTrackToEnd(_:inTabId:)`.

---

## FIX 4 — SnapTimerBtn hardcodes inactivity delay
**File:** `TransportView.swift`  
**Problem:** `private let delay: Double = 5.0` must stay manually in sync with `WindowSnapManager.inactivityDelay`  
**Fix:** Expose `inactivityDelay` on `WindowSnapManager` and read it from there

In `WindowSnapManager.swift`, change:
```swift
private let inactivityDelay: Double = 5.0
```
to:
```swift
let inactivityDelay: Double = 5.0
```

In `TransportView.swift`, `SnapTimerBtn`, replace:
```swift
private let delay: Double = 5.0   // matches WindowSnapManager.inactivityDelay
```
with:
```swift
private var delay: Double { WindowSnapManager.shared.inactivityDelay }
```

---

## FIX 5 — fmtTime vs Track.formattedDuration inconsistent minute padding
**File:** `Track.swift`  
**Problem:** `formattedDuration` outputs `"4:05"` (no minute padding); `fmtTime` in `DesignTokens.swift` outputs `"04:05"`. Different visual output across the UI  
**Fix:** Align `formattedDuration` to match `fmtTime`

In `Track.swift`, replace:
```swift
var formattedDuration: String {
    let s = Int(duration)
    return "\(s / 60):\(String(format: "%02d", s % 60))"
}
```
with:
```swift
var formattedDuration: String { fmtTime(duration) }
```

---

## FIX 6 — ArtworkCache: replace manual dict with NSCache for automatic memory pressure eviction
**File:** `ArtworkCache.swift`  
**Problem:** `private var mem: [UUID: NSImage] = [:]` grows unbounded. 500 tracks ≈ 128MB never freed during session  
**Fix:** Replace with `NSCache` (handles memory pressure automatically, thread-safe)

Replace the class body:
```swift
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("GONE/artwork")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() {
        DispatchQueue.global(qos: .background).async { [weak self] in self?.prune() }
    }

    func image(for id: UUID) -> NSImage? {
        let key = id.uuidString as NSString
        if let img = cache.object(forKey: key) { return img }
        let url = dir.appendingPathComponent(id.uuidString + ".jpg")
        guard let data = try? Data(contentsOf: url), let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    func store(_ native: NSImage, for id: UUID) {
        let key = id.uuidString as NSString
        cache.setObject(native, forKey: key)
        let url = dir.appendingPathComponent(id.uuidString + ".jpg")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        writeToDisk(native, to: url)
    }

    private func writeToDisk(_ image: NSImage, to url: URL) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return }
        let scale = min(1.0, min(256.0 / Double(w), 256.0 / Double(h)))
        let tw = max(1, Int((Double(w) * scale).rounded()))
        let th = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: tw, height: th,
                                  bitsPerComponent: 8, bytesPerRow: tw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let thumb = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: thumb)
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try? jpg.write(to: url)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for url in files {
            guard let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  date < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
```

---

## FIX 7 — Remove dead nodes from AudioEngine
**File:** `GONE/AudioEngine.next.swift`  
**Problem:** `distortionNode` and `delayNode` are declared but never attached to the graph or used  
**Fix:** Remove both declarations

Delete these two lines from the private properties block:
```swift
private let distortionNode = AVAudioUnitDistortion()
private let delayNode      = AVAudioUnitDelay()
```

---

## FIX 8 — EQ "Custom" preset item behaves as enabled but does nothing
**File:** `EQPanelView.swift`  
**Problem:** `EQPresetPicker` shows "Custom" as a clickable menu item, but `applyPreset("Custom")` returns early because `eqPresets["Custom"]` doesn't exist. Misleading UX  
**Fix:** Disable the "Custom" item in the menu

In `EQPresetPicker.body`, inside `ForEach`, change:
```swift
Button {
    preset = option
} label: {
    HStack {
        Text(option)
        if option == preset { Spacer(); Image(systemName: "checkmark") }
    }
}
```
to:
```swift
if option == "Custom" {
    Button { } label: {
        HStack {
            Text(option).foregroundStyle(.secondary)
            if option == preset { Spacer(); Image(systemName: "checkmark") }
        }
    }
    .disabled(true)
} else {
    Button {
        preset = option
    } label: {
        HStack {
            Text(option)
            if option == preset { Spacer(); Image(systemName: "checkmark") }
        }
    }
}
```

---

## FIX 9 — BPM octave correction: single pass instead of loop
**File:** `LibraryScanner.swift`  
**Problem:** `if bpm < 90 { bpm *= 2 }` — single pass. Track at 44 BPM becomes 88 (still wrong, should be 176)  
**Fix:** Use while loops

Replace:
```swift
if bpm < 90  { bpm *= 2 }
if bpm > 180 { bpm /= 2 }
```
with:
```swift
while bpm > 0 && bpm < 90  { bpm *= 2 }
while bpm > 180 { bpm /= 2 }
```

---

## FIX 10 — Remove dead state: xyPresets
**File:** `PlayerState.swift`  
**Problem:** `@Published var xyPresets: [CGPoint?] = [nil, nil, nil, nil]` — declared, never read or written by any UI or logic  
**Fix:** Delete the line

```swift
// DELETE:
@Published var xyPresets: [CGPoint?] = [nil, nil, nil, nil]
```

---

## NOTES — Do not fix now, track as debt

- **`Track.artworkData: Data?`** — should move out of the struct to eliminate array copy overhead during import batches. Significant refactor, coordinate separately.
- **Dual SnapState enums** — `WindowSnapManager.SnapState` and `PlayerState.SnapMode` are identical. Consolidate when touching snap system next.
- **`presentImportPanel` uses `NSApp.keyWindow`** — should use `AppDelegate.resolvedMainWindow()`. Low risk, fix opportunistically.
- **`Task.sleep(nanoseconds:)` deprecation** — replace with `Task.sleep(for: .milliseconds(N))` across all files on next pass.
- **LFO does not update `state.lpfCutoff`** — EQ curve doesn't animate during LFO sweep. Known pending item.
