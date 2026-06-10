import SwiftUI
import AppKit
import Combine

struct TrackHeaderView: View {
    @EnvironmentObject var state: PlayerState
    @EnvironmentObject var analysisFeed: AnalysisProgressFeed

    @State private var feedCurrentTime: Double = 0
    @State private var timeLabelCache: String = "00:00 / 00:00"
    @State private var trackIndexCache: Int = 0

    var body: some View {
        let track = state.current

        HStack(alignment: .top, spacing: 10) {
            // Art swatch — deliberately excluded from gradient map
            ArtSwatchView(index: trackIndexCache, size: 48, cornerRadius: 7,
                          hasArtwork: state.current?.hasArtwork ?? false,
                          trackId: state.current?.id,
                          showsBrandPlaceholder: track == nil)

            // Center: title / artist / badges — gradient map applied here (artwork excluded above)
            VStack(alignment: .leading, spacing: 3) {
                Text(track?.title ?? "GONE PLAYER")
                    .font(G.sans(13, weight: .semibold))
                    .foregroundStyle(G.textPrimary)
                    .lineLimit(1)
                    .kerning(-0.12)

                Text(subtitleText)
                    .font(G.sans(11))
                    .foregroundStyle(G.textTertiary)
                    .lineLimit(1)

                // Badge row
                HStack(spacing: 5) {
                    if let t = track {
                        BadgeView(t.format, style: .filled)
                        if t.displayBitrate != "—" {
                            BadgeView(t.displayBitrate, style: .filled)
                        }
                        if t.bpm > 0 {
                            if t.bpmAnalysisState == .analyzing {
                                BPMAnalyzingBadge()
                            } else {
                                TapBPMBadge(trackId: t.id, currentBPM: t.bpm)
                            }
                        }
                        if state.pitch != 0, t.bpm > 0 {
                            BadgeView("\(Int((t.bpm * (1 + state.pitch / 100)).rounded())) BPM",
                                      style: state.pitchBypassed ? .filled : .highlight)
                                .opacity(state.pitchBypassed ? 0.45 : 1.0)
                                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                                .goneTooltip("BPM after your tempo shift")
                        }
                        Text(pitchLabel)
                            .font(G.mono(8, weight: .semibold))
                            .foregroundStyle(state.pitch == 0 ? G.textTertiary : G.textPrimary)
                            .monospacedDigit()
                            .goneTooltip("How far the speed has shifted from original. 0.0% = no change")

                        if t.bpm == 0 && t.bpmAnalysisState == .analyzing {
                            // first-time analysis: no BPM badge yet, show spinner separately
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.55)
                                    .tint(Color.white.opacity(0.72))
                                Text("ANALYZING")
                                    .font(G.mono(8.5, weight: .semibold))
                                    .foregroundStyle(G.textTertiary)
                            }
                        } else if t.bpmAnalysisState == .failed {
                            Text("ANALYSIS FAILED")
                                .font(G.mono(8.5, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.36))
                        }
                    }
                }
                .font(G.mono(8, weight: .semibold))
                .frame(height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            // Right column: spectrum + time pill full-width under it
            VStack(alignment: .center, spacing: 4) {
                SpectrumView(feed: state.spectrumFeed, isPlaying: state.isPlaying)
                    .frame(width: 96, height: 34)
                    .goneTooltip("Frequency energy of the audio as it plays. Display only — not an EQ")

                Text(timeLabelCache)
                    .font(G.mono(8, weight: .semibold))
                    .foregroundStyle(G.textSecondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: G.rBadge))
            }
            .frame(width: 96)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 0)
        .animation(.easeInOut(duration: 0.2), value: state.pitch)
        .animation(.easeInOut(duration: 0.2), value: state.pitchBypassed)
        .onReceive(state.progressFeed.objectWillChange) { _ in
            let t = state.progressFeed.currentTime
            feedCurrentTime = t
            updateTimeLabel(currentTime: t)
        }
        .onChange(of: state.pitch)     { _ in updateTimeLabel(currentTime: feedCurrentTime) }
        .onChange(of: state.currentId) { _ in
            trackIndexCache = state.tracks.firstIndex(where: { $0.id == state.currentId }) ?? 0
            updateTimeLabel(currentTime: feedCurrentTime)
        }
        .onAppear {
            trackIndexCache = state.tracks.firstIndex(where: { $0.id == state.currentId }) ?? 0
            updateTimeLabel(currentTime: feedCurrentTime)
        }
    }

    private var subtitleText: String {
        guard let t = state.current else { return "version: 1.0 beta" }
        let artist = t.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album  = t.album.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (artist.isEmpty, album.isEmpty) {
        case (false, false): return "\(artist) — \(album)"
        case (false, true):  return artist
        case (true,  false): return album
        case (true,  true):  return "—"
        }
    }

    private var pitchLabel: String {
        let p = state.pitch
        if p == 0 { return "±0.0%" }
        return String(format: "%+.1f%%", p)
    }

    private func updateTimeLabel(currentTime: Double) {
        guard let t = state.current else { timeLabelCache = "00:00 / 00:00"; return }
        let speed = 1.0 + state.pitch / 100.0
        timeLabelCache = "\(fmtTime(currentTime / speed)) / \(fmtTime(t.duration / speed))"
    }

}

// ── Art swatch ─────────────────────────────────────────────────────────────────
struct ArtSwatchView: View {
    let index: Int
    let size: CGFloat
    let cornerRadius: CGFloat
    var hasArtwork: Bool = false
    var trackId: UUID? = nil
    var showsBrandPlaceholder: Bool = false
    var isCurrent: Bool = false

    @State private var image: NSImage?
    @State private var loadGeneration: Int = 0

    private var artworkTaskId: String { "\(trackId?.uuidString ?? ""):\(hasArtwork)" }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if showsBrandPlaceholder {
                ZStack(alignment: .top) {
                    Color.black

                    Image("GoneLogo")
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .offset(y: -4)
                }
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.3, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.22))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear { loadArtwork() }
        .onChange(of: artworkTaskId) { _ in loadArtwork() }
    }

    private func loadArtwork() {
        guard hasArtwork, let id = trackId else { image = nil; return }
        loadGeneration += 1
        let generation = loadGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = ArtworkCache.shared.image(for: id)
            DispatchQueue.main.async {
                guard loadGeneration == generation else { return }
                image = resolved
            }
        }
    }
}

// ── Badge ─────────────────────────────────────────────────────────────────────
enum BadgeStyle { case filled, highlight, outline }

struct BadgeView: View {
    let text: String
    let style: BadgeStyle

    init(_ text: String, style: BadgeStyle) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(G.mono(8, weight: .semibold))
            .foregroundStyle(fgColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(bgColor)
            .animation(.easeInOut(duration: 0.2), value: text)
            .overlay(
                style == .outline
                    ? RoundedRectangle(cornerRadius: G.rBadge).stroke(Color.white.opacity(0.45), lineWidth: 1)
                    : nil
            )
            .clipShape(RoundedRectangle(cornerRadius: G.rBadge))
    }

    private var bgColor: Color {
        switch style {
        case .filled:    return Color.white.opacity(0.08)
        case .highlight: return Color.white.opacity(0.92)
        case .outline:   return Color.clear
        }
    }

    private var fgColor: Color {
        switch style {
        case .filled:    return G.textSecondary
        case .highlight: return G.textOnLight
        case .outline:   return G.textPrimary
        }
    }
}

// ── BPM badge — shows current BPM, hover reveals re-analyze trigger ───────────
private struct TapBPMBadge: View {
    let trackId: UUID
    let currentBPM: Double
    @EnvironmentObject var state: PlayerState

    @State private var hovered = false

    var body: some View {
        Button {
            state.reanalyzeBPMDeep(for: trackId)
        } label: {
            HStack(spacing: 3) {
                if hovered {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 7, weight: .semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                Text("\(Int(currentBPM.rounded())) BPM")
                    .font(G.mono(8, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(hovered ? G.textPrimary : G.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.white.opacity(hovered ? 0.14 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: G.rBadge))
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .cursor(.pointingHand)
        .goneTooltip("Re-analyze BPM")
    }
}

// ── BPM re-analysis sweep badge ───────────────────────────────────────────────
private struct BPMAnalyzingBadge: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        Text("ANALYZING")
            .font(G.mono(8, weight: .semibold))
            .foregroundStyle(G.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                GeometryReader { geo in
                    let w = geo.size.width
                    let stripW = w * 0.55
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.08)
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: Color.white.opacity(0.28), location: 0.35),
                                .init(color: Color.white.opacity(0.28), location: 0.65),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: stripW)
                        .offset(x: -stripW + (w + stripW) * phase)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: G.rBadge))
            .onAppear {
                withAnimation(.linear(duration: 0.65).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .allowsHitTesting(false)
            .fixedSize()
    }
}
