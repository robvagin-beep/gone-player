import SwiftUI
import AppKit
import CoreAudio

// MARK: - Audio Device Model

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String

    static let systemDefault = AudioOutputDevice(id: kAudioObjectUnknown, name: "System Default")
}

final class AudioDeviceHelper {

    static func outputDevices() -> [AudioOutputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(1), &addr, 0, nil, &dataSize) == noErr else {
            return [.systemDefault]
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(1), &addr, 0, nil, &dataSize, &ids) == noErr else {
            return [.systemDefault]
        }

        var devices: [AudioOutputDevice] = [.systemDefault]
        for id in ids {
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &outAddr, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            // Core Audio writes a retained CFStringRef into the buffer.
            // Use Unmanaged<CFString> so Swift knows this is a managed reference,
            // avoiding the UnsafeMutableRawPointer-to-CFString warning.
            var cfNameUnmanaged: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let nameStatus = withUnsafeMutablePointer(to: &cfNameUnmanaged) { ptr in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize,
                                           UnsafeMutableRawPointer(ptr))
            }
            guard nameStatus == noErr, let name = cfNameUnmanaged?.takeRetainedValue() else { continue }
            devices.append(AudioOutputDevice(id: id, name: name as String))
        }
        return devices
    }
}

// MARK: - Panel Manager

final class SettingsPanel {
    static let shared = SettingsPanel()
    private init() {}

    private var panel: NSPanel?
    private var hostController: NSHostingController<SettingsHostView>?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private weak var anchorWindow: NSWindow?
    private var anchorObservers: [NSObjectProtocol] = []

    var currentPanel: NSPanel? { panel }

    @MainActor
    func toggle(near window: NSWindow, state: PlayerState) {
        if panel?.isVisible == true { hide() } else { show(near: window, state: state) }
    }

    @MainActor
    func show(near window: NSWindow, state: PlayerState) {
        anchorWindow = window
        let root = SettingsHostView(state: state)
        if let hc = hostController { hc.rootView = root } else { hostController = NSHostingController(rootView: root) }
        guard let hc = hostController else { return }

        if panel == nil {
            let p = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: 360, height: 100),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque           = false
            p.backgroundColor    = .clear
            p.hasShadow          = true
            p.level              = GWindowLevel.floatingPanel
            p.collectionBehavior = [.canJoinAllSpaces,
                                     .fullScreenDisallowsTiling, .ignoresCycle]
            p.hidesOnDeactivate  = false
            p.ignoresMouseEvents = false
            hc.view.wantsLayer = true
            hc.view.layer?.backgroundColor = CGColor.clear
            p.contentView        = hc.view
            panel = p
        }

        hc.view.layoutSubtreeIfNeeded()
        updatePanelFrame(size: hc.view.fittingSize)
        panel!.orderFront(nil)

        installAnchorObservers(for: window)
        removeEventMonitors()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let p = self.panel, p.isVisible else { return event }
            // Don't dismiss while dragging the panel itself
            if (self.hostController?.rootView.state) != nil,
               SettingsView.isDraggingGlobal { return event }
            if !p.frame.contains(NSEvent.mouseLocation) {
                Task { @MainActor in self.hide() }
                return nil
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let p = self.panel, p.isVisible else { return }
            if SettingsView.isDraggingGlobal { return }
            Task { @MainActor in self.hide() }
        }
    }

    @MainActor
    func hide() {
        panel?.orderOut(nil)
        removeEventMonitors()
        removeAnchorObservers()
        anchorWindow = nil
    }

    @MainActor
    private func updatePanelFrame(size: CGSize? = nil) {
        guard let panel, let window = anchorWindow else { return }
        let panelSize = size ?? panel.frame.size
        let winF = window.frame
        let baseBottom = winF.maxY - FullPlayerView.baseHeight - 12
        var x = winF.minX + 8
        var y = baseBottom - panelSize.height - 4
        // The player can sit in any corner, and the panel may overlap it — clamp the origin to
        // the screen so the (now taller, no-constraint) settings always land fully visible.
        if let vf = (window.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, vf.minX + 8), max(vf.minX + 8, vf.maxX - panelSize.width - 8))
            y = min(max(y, vf.minY + 8), max(vf.minY + 8, vf.maxY - panelSize.height - 8))
        }
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: panelSize), display: true)
    }

    @MainActor
    private func installAnchorObservers(for window: NSWindow) {
        removeAnchorObservers()
        let center = NotificationCenter.default
        let repositionNames: [NSNotification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification
        ]
        for name in repositionNames {
            let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self, !SettingsView.isDraggingGlobal else { return }
                Task { @MainActor in
                    self.updatePanelFrame()
                }
            }
            anchorObservers.append(token)
        }
        let hideNames: [NSNotification.Name] = [
            NSWindow.willCloseNotification,
            NSWindow.willMiniaturizeNotification
        ]
        for name in hideNames {
            let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.hide()
                }
            }
            anchorObservers.append(token)
        }
    }

    private func removeAnchorObservers() {
        let center = NotificationCenter.default
        anchorObservers.forEach(center.removeObserver)
        anchorObservers.removeAll()
    }

    private func removeEventMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }
}

// MARK: - SwiftUI host

struct SettingsHostView: View {
    @ObservedObject var state: PlayerState
    var body: some View { SettingsView(state: state) }
}

// MARK: - Main SettingsView

struct SettingsView: View {
    @ObservedObject var state: PlayerState

    // Shared drag flag: prevents monitor from dismissing the panel mid-drag.
    // SettingsPanel.show closure reads this via the static so we don't need a binding.
    static var isDraggingGlobal = false

    enum Tab: String, CaseIterable {
        case audio   = "AUDIO"
        case bpm     = "BPM"
        case library = "LIBRARY"
        case view    = "VIEW"
        case info    = "INFO"
    }
    @State private var tab: Tab = .audio
    @State private var dragStartOrigin: NSPoint?
    @State private var dragStartMouse: NSPoint = .zero

    var body: some View {
        VStack(spacing: 0) {
            // Drag affordance dots — standard macOS borderless panel pattern
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 3, height: 3)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 4)

            // Tab bar — also the drag handle
            HStack(spacing: 0) {
                CloseTabBtn()
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 1, height: 18)
                ForEach(Tab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue)
                            .font(G.mono(8, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? Color.white.opacity(0.82) : Color.white.opacity(0.28))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) {
                                if tab == t {
                                    Rectangle().fill(Color.white.opacity(0.40)).frame(height: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .cursor(.pointingHand)
                }
            }
            .background(Color.white.opacity(0.025))
            .cursor(.openHand)
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { _ in
                        guard let p = SettingsPanel.shared.currentPanel else { return }
                        SettingsView.isDraggingGlobal = true
                        if dragStartOrigin == nil {
                            dragStartOrigin = p.frame.origin
                            dragStartMouse  = NSEvent.mouseLocation
                        }
                        let dx = NSEvent.mouseLocation.x - dragStartMouse.x
                        let dy = NSEvent.mouseLocation.y - dragStartMouse.y
                        p.setFrameOrigin(NSPoint(x: dragStartOrigin!.x + dx, y: dragStartOrigin!.y + dy))
                    }
                    .onEnded { _ in
                        dragStartOrigin = nil
                        SettingsView.isDraggingGlobal = false
                    }
            )

            Divider().overlay(Color.white.opacity(0.07))

            Group {
                switch tab {
                case .audio:   AudioSettingsTab(state: state)
                case .bpm:     BpmSettingsTab(state: state)
                case .library: LibrarySettingsTab(state: state)
                case .view:    ViewSettingsTab(state: state)
                case .info:    InfoSettingsTab(state: state)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 420)
        .background(G.bgFloatingPanel)
        .clipShape(RoundedRectangle(cornerRadius: G.rFloatingPanel))
        // Stronger, two-tone border so the panel edge reads clearly against the player /
        // desktop behind it — the user needs to see where the window's edges are.
        .overlay {
            RoundedRectangle(cornerRadius: G.rFloatingPanel)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: G.rFloatingPanel)
                .inset(by: 1)
                .stroke(Color.black.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.66), radius: 34, x: 0, y: 12)
        .fixedSize(horizontal: true, vertical: true)
    }
}

// MARK: - Shared primitives

private struct CloseTabBtn: View {
    @State private var hovered = false

    var body: some View {
        Button {
            Task { @MainActor in SettingsPanel.shared.hide() }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(Color.white.opacity(hovered ? 0.52 : 0.22))
                .frame(width: 36, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct SHead: View {
    let text: String
    var body: some View {
        Text(text)
            .font(G.mono(8, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.28))
            .kerning(1.0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 5)
    }
}

private struct SRow<C: View>: View {
    let label: String
    var sub: String? = nil
    @ViewBuilder let control: () -> C

    var body: some View {
        HStack(alignment: sub == nil ? .center : .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(G.mono(10))
                    .foregroundStyle(Color.white.opacity(0.68))
                if let s = sub {
                    Text(s)
                        .font(G.mono(8))
                        .foregroundStyle(Color.white.opacity(0.26))
                }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct SDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1).padding(.horizontal, 14)
    }
}

// Heavier separator between top-level sections (vs SDivider between rows).
private struct SSectionRule: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            .padding(.top, 4)
    }
}

// Row of equal-width segmented chips. `items` carry a (label, value); the value is passed
// back to isActive/action so one component drives scale, delay, side, animation, etc.
private struct ChipRow: View {
    let items: [(String, Double)]
    let isActive: (Double) -> Bool
    let action: (Double) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(items, id: \.0) { label, value in
                Button { action(value) } label: {
                    let active = isActive(value)
                    Text(label)
                        .font(G.mono(10, weight: active ? .semibold : .regular))
                        .foregroundStyle(Color.white.opacity(active ? 0.84 : 0.32))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(active ? 0.12 : 0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// Compact chip cluster for inline use inside an SRow (e.g. magnify Speed).
private struct SmallChipRow: View {
    let items: [(String, Double)]
    let isActive: (Double) -> Bool
    let action: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.0) { label, value in
                Button { action(value) } label: {
                    let active = isActive(value)
                    Text(label)
                        .font(G.mono(8, weight: active ? .semibold : .regular))
                        .foregroundStyle(Color.white.opacity(active ? 0.82 : 0.32))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(active ? 0.12 : 0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// Caption + live value + slider, the repeated "GHOST OPACITY 42 %" style block.
private struct InlineSlider: View {
    let caption: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(caption)
                    .font(G.mono(7, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .kerning(0.7)
                Spacer()
                Text("\(Int(value))\(unit.isEmpty ? "" : " \(unit)")")
                    .font(G.mono(10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .monospacedDigit()
            }
            SettingsSlider(label: "", value: $value, range: range)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

struct MiniToggle: View {
    @Binding var isOn: Bool
    @State private var hovered = false

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? Color.white.opacity(0.80) : Color.white.opacity(0.10))
                    .frame(width: 28, height: 15)
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(hovered ? 0.18 : 0), lineWidth: 1)
                    }
                Circle()
                    .fill(isOn ? G.bgFloatingPanel : Color.white.opacity(0.40))
                    .frame(width: 11, height: 11)
                    .offset(x: isOn ? 6.5 : -6.5)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.20, dampingFraction: 0.78), value: isOn)
        .onHover { hovered = $0 }
    }
}

private struct NumStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        HStack(spacing: 5) {
            Button {
                value = max(range.lowerBound, value - step)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("\(Int(value))")
                .font(G.mono(11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.78))
                .frame(width: 30, alignment: .center)
                .monospacedDigit()

            Button {
                value = min(range.upperBound, value + step)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// Unified slider used for both gradient-map (custom track) and fill-bar (magnify, scale) styles.
private struct SettingsSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var track: AnyView? = nil   // nil = fill-bar style

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty {
                Text(label)
                    .font(G.mono(7, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.30))
                    .kerning(0.6)
            }
            GeometryReader { geo in
                let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let thumbX   = fraction * max(0, geo.size.width - 13)

                ZStack(alignment: .leading) {
                    if let t = track {
                        RoundedRectangle(cornerRadius: 3)
                            .overlay { t.clipShape(RoundedRectangle(cornerRadius: 3)) }
                            .frame(height: 7)
                            .opacity(0.85)
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 7)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.28))
                            .frame(width: thumbX + 6.5, height: 7)
                    }
                    Circle()
                        .fill(Color.white)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                        .offset(x: thumbX)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let frac = max(0, min(1, g.location.x / geo.size.width))
                    value = range.lowerBound + frac * (range.upperBound - range.lowerBound)
                })
            }
            .frame(height: 14)
        }
    }
}

// MARK: - Tab: AUDIO

private struct AudioSettingsTab: View {
    @ObservedObject var state: PlayerState
    @State private var devices: [AudioOutputDevice] = []
    @State private var currentID: AudioDeviceID = kAudioObjectUnknown
    @State private var hoveredID: AudioDeviceID? = nil

    var body: some View {
        VStack(spacing: 0) {
            SHead(text: "OUTPUT DEVICE")

            if devices.isEmpty {
                Text("Loading...")
                    .font(G.mono(9))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(devices) { device in
                    let isSel = device.id == currentID
                    let isHov = hoveredID == device.id
                    Button {
                        currentID = device.id
                        state.audioEngine.setOutputDevice(device.id)
                        if SplitModeManager.shared.isActive {
                            AudioEngineNext.secondary.setOutputDevice(device.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSel ? "checkmark" : "circle")
                                .font(.system(size: isSel ? 9 : 7, weight: .semibold))
                                .foregroundStyle(isSel ? Color.white.opacity(0.80) : Color.white.opacity(0.18))
                                .frame(width: 12)
                            Text(device.name)
                                .font(G.mono(10))
                                .foregroundStyle(isSel ? Color.white.opacity(0.85) : Color.white.opacity(0.46))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(isHov && !isSel ? Color.white.opacity(0.04) : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredID = $0 ? device.id : nil }

                    if device.id != devices.last?.id {
                        SDivider()
                    }
                }
            }

            Spacer().frame(height: 14)
        }
        .onAppear {
            devices = AudioDeviceHelper.outputDevices()
            currentID = state.audioEngine.currentOutputDeviceID()
        }
    }
}

// MARK: - Tab: BPM (detection + range)

private struct BpmSettingsTab: View {
    @ObservedObject var state: PlayerState

    var body: some View {
        VStack(spacing: 0) {
            SHead(text: "DETECTION")
            SRow(label: "Auto-scan on import", sub: "detect tempo as tracks are added") {
                MiniToggle(isOn: $state.autoBPMOnImport)
            }

            SHead(text: "DETECTION RANGE")
            // Genre presets — the Rekordbox approach: octave/half-tempo ambiguity is
            // resolved by constraining the search range, not by the algorithm alone.
            // Bench: breaks tagged 133-136 detected at 2/3 tempo on 60-200, perfectly
            // within 110-160.
            HStack(spacing: 5) {
                ForEach([("OPEN", 60.0, 200.0), ("HIP-HOP", 70.0, 115.0), ("CLUB", 90.0, 180.0),
                         ("BREAKS", 110.0, 160.0), ("D&B", 160.0, 195.0)], id: \.0) { label, lo, hi in
                    Button {
                        state.bpmAnalysisFloor = lo
                        state.bpmAnalysisCeiling = hi
                    } label: {
                        let active = abs(state.bpmAnalysisFloor - lo) < 0.5 && abs(state.bpmAnalysisCeiling - hi) < 0.5
                        Text(label)
                            .font(G.mono(8, weight: active ? .semibold : .regular))
                            .foregroundStyle(Color.white.opacity(active ? 0.84 : 0.32))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(active ? 0.12 : 0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            SRow(label: "Min BPM") {
                NumStepper(value: $state.bpmAnalysisFloor, range: 30...190, step: 5)
            }
            SDivider()
            SRow(label: "Max BPM") {
                NumStepper(value: $state.bpmAnalysisCeiling, range: 100...240, step: 5)
            }
        }
        // Keep floor < ceiling with a minimum gap of one step (5 BPM)
        .onChange(of: state.bpmAnalysisFloor) { floor in
            if state.bpmAnalysisCeiling <= floor { state.bpmAnalysisCeiling = floor + 5 }
        }
        .onChange(of: state.bpmAnalysisCeiling) { ceiling in
            if state.bpmAnalysisFloor >= ceiling { state.bpmAnalysisFloor = ceiling - 5 }
        }
        .padding(.bottom, 16)
    }
}

// MARK: - Tab: LIBRARY (session + import + library behavior)

private struct LibrarySettingsTab: View {
    @ObservedObject var state: PlayerState

    var body: some View {
        VStack(spacing: 0) {
            SHead(text: "SESSION")
            SRow(label: "Restore on launch", sub: "reload last session's tracks on startup") {
                MiniToggle(isOn: $state.restoreLastSession)
            }

            SHead(text: "ON IMPORT")
            SRow(label: "Auto-play") { MiniToggle(isOn: $state.autoPlayOnImport) }
            SDivider()
            SRow(label: "Open playlist", sub: "show track list after drop") {
                MiniToggle(isOn: $state.autoOpenPlaylistOnImport)
            }

            SHead(text: "LIBRARY")
            SRow(label: "Confirm delete", sub: "ask before removing from library") {
                MiniToggle(isOn: $state.confirmBeforeDelete)
            }
            SDivider()
            SRow(label: "Hide missing tracks") { MiniToggle(isOn: $state.hideMissingTracks) }
            SDivider()
            SRow(label: "Follow current track", sub: "auto-scroll the list to the playing track") {
                MiniToggle(isOn: $state.followCurrentTrack)
            }
        }
        .padding(.bottom, 16)
    }
}

// MARK: - Tab: VIEW (merged LOOK + WINDOW — appearance + on-screen behavior)

private struct ViewSettingsTab: View {
    @ObservedObject var state: PlayerState

    private let scalePresets: [(String, Double)] = [
        ("50%", 0.50), ("60%", 0.60), ("70%", 0.70),
        ("80%", 0.80), ("90%", 0.90), ("100%", 1.00)
    ]
    private let delayOptions: [(String, Double)] = [
        ("2 s", 2), ("3 s", 3), ("5 s", 5), ("10 s", 10), ("20 s", 20)
    ]
    private let snapSpeedOptions: [(String, Double)] = [
        ("SLOW", 1.8), ("MED", 1.0), ("FAST", 0.5)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Appearance ───────────────────────────────────────────────
            SHead(text: "GRADIENT MAP")
            VStack(spacing: 16) {
                SettingsSlider(
                    label: "COLOR",
                    value: $state.gradientMapHue,
                    range: 0...360,
                    track: AnyView(LinearGradient(
                        colors: (0...12).map { Color(hue: Double($0) / 12.0, saturation: 0.85, brightness: 0.90) },
                        startPoint: .leading, endPoint: .trailing
                    ))
                )
                SettingsSlider(
                    label: "SATURATION",
                    value: $state.gradientMapSaturation,
                    range: 0...100,
                    track: AnyView(LinearGradient(
                        colors: [Color(white: 0.38),
                                 Color(hue: state.gradientMapHue / 360, saturation: 1.0, brightness: 0.88)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 18)

            SSectionRule()

            SHead(text: "DISPLAY SCALE")
            SettingsSlider(
                label: "",
                value: $state.windowScale,
                range: 0.50...1.00,
                track: AnyView(LinearGradient(
                    colors: [Color.white.opacity(0.08), Color.white.opacity(0.38)],
                    startPoint: .leading, endPoint: .trailing
                ))
            )
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 12)

            ChipRow(items: scalePresets,
                    isActive: { abs(state.windowScale - $0) < 0.01 },
                    action: { v in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.72)) { state.windowScale = v }
                    })
                .padding(.horizontal, 18)
                .padding(.bottom, 14)

            // Hover-to-zoom lives right under the scale — it's the way to read the player
            // at full size again after scaling it down, without leaving it large.
            SRow(label: "Hover to zoom 100%", sub: "snap back to full size when the cursor nears") {
                MiniToggle(isOn: $state.magnifyEnabled)
            }
            if state.magnifyEnabled {
                SDivider()
                InlineSlider(caption: "PROXIMITY", value: $state.magnifyProximity,
                             range: 20...200, unit: "px")
                SDivider()
                SRow(label: "Speed") {
                    SmallChipRow(items: [("SLOW", 0.45), ("MED", 0.25), ("FAST", 0.12)],
                                 isActive: { abs(state.magnifySpeed - $0) < 0.05 },
                                 action: { state.magnifySpeed = $0 })
                }
            }

            SSectionRule()

            // ── Window behaviour ─────────────────────────────────────────
            SHead(text: "INVISIBLE")
            SRow(label: "Invisible mode", sub: "fade to a ghost when idle · hover to reveal") {
                MiniToggle(isOn: $state.invisibleMode)
            }
            if state.invisibleMode {
                SDivider()
                InlineSlider(caption: "GHOST OPACITY", value: $state.invisibleOpacity,
                             range: 18...100, unit: "%")
            }

            SSectionRule()

            SHead(text: "SNAP DELAY")
            ChipRow(items: delayOptions,
                    isActive: { abs(state.snapInactivityDelay - $0) < 0.5 },
                    action: { state.snapInactivityDelay = $0 })
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

            SHead(text: "SNAP SIDE")
            ChipRow(items: [("LEFT", 1.0), ("RIGHT", 0.0)],
                    isActive: { state.snapDockLeft == ($0 > 0.5) },
                    action: { state.snapDockLeft = $0 > 0.5 })
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

            SHead(text: "SNAP ANIMATION")
            ChipRow(items: snapSpeedOptions,
                    isActive: { snapSpeedOptions.min(by: { abs($0.1 - state.snapAnimSpeed) < abs($1.1 - state.snapAnimSpeed) })?.1 == $0 },
                    action: { state.snapAnimSpeed = $0 })
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

            SHead(text: "PEEK TAB WIDTH")
            InlineSlider(caption: "VISIBLE", value: $state.snapTabWidth, range: 8...36, unit: "px")
        }
        .padding(.bottom, 18)
    }
}

// MARK: - Tab: INFO

private struct InfoSettingsTab: View {
    @ObservedObject var state: PlayerState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Debug mode row at the top
            SHead(text: "BETA TOOLS")
            SRow(label: "Debug mode", sub: "show error codes on failure") {
                MiniToggle(isOn: $state.debugMode)
            }
            if state.debugMode && !state.lastError.isEmpty {
                SDivider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAST ERROR")
                        .font(G.mono(7, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.20))
                        .kerning(0.8)
                    Text(state.lastError)
                        .font(G.mono(9))
                        .foregroundStyle(Color.white.opacity(0.50))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                SDivider()
                Button {
                    state.lastError = ""
                } label: {
                    Text("CLEAR")
                        .font(G.mono(9, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }

            SDivider()

            Image("GoneWordmark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(Color.white.opacity(0.80))
                .frame(maxWidth: 150)
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 12) {
                Text("Quick tracklist prep for DJs.\nDrop a folder, sort by BPM,\ncheck tempo before the set.\nNo Rekordbox. No database. Just prep.")
                    .font(G.mono(10))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .lineSpacing(3)

                VStack(alignment: .leading, spacing: 5) {
                    SInfoRow("VERSION", "1.1 BETA")
                    SInfoRow("BUILD",   "JUN 2026")
                    SInfoRow("BY",      "HEARTBEAT STUDIO")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 18)
        }
    }

    private func SInfoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(G.mono(8))
                .foregroundStyle(Color.white.opacity(0.20))
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(G.mono(8, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.46))
        }
    }
}
