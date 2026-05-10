import SwiftUI
import AppKit

struct TrackHeaderView: View {
    @EnvironmentObject var state: PlayerState

    @State private var isBPMHovered = false
    @State private var feedCurrentTime: Double = 0

    var body: some View {
        let track = state.current

        HStack(alignment: .top, spacing: 10) {
            // Art swatch — deliberately excluded from gradient map
            ArtSwatchView(index: trackIndex, size: 48, cornerRadius: 7,
                          artworkData: state.current?.artworkData,
                          trackId: state.current?.id,
                          showsBrandPlaceholder: track == nil)

            // Center: title / artist / badges — gradient map applied here (artwork excluded above)
            VStack(alignment: .leading, spacing: 3) {
                Text(track?.title ?? "GONE PLAYER")
                    .font(G.sans(13, weight: .semibold))
                    .foregroundStyle(G.textPrimary)
                    .lineLimit(1)
                    .tracking(-0.12)

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
                            let isAnalyzing = t.bpmAnalysisState == .analyzing
                            let bpmProgress = state.analysisProgress[t.id] ?? 0
                            Button { state.reanalyzeBPMDeep(for: t.id) } label: {
                                if isAnalyzing {
                                    Text("ANALYZING")
                                        .font(G.mono(8, weight: .semibold))
                                        .foregroundStyle(G.textSecondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(
                                            GeometryReader { geo in
                                                ZStack(alignment: .leading) {
                                                    Color.white.opacity(0.08)
                                                    Color.white.opacity(0.20)
                                                        .frame(width: max(0, geo.size.width * CGFloat(bpmProgress)))
                                                }
                                            }
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: G.rBadge))
                                        .allowsHitTesting(false)
                                } else {
                                    BadgeView(isBPMHovered ? "REFRESH" : "\(Int(t.bpm.rounded())) BPM", style: .filled)
                                        .allowsHitTesting(false)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isAnalyzing)
                            .onHover { isBPMHovered = isAnalyzing ? false : $0 }
                            .cursor(isAnalyzing ? .arrow : .pointingHand)
                            .goneTooltip(isAnalyzing ? "Analyzing…" : "Deep BPM re-analysis — wider range, half-tempo correction")
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

                Text(timeLabel)
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
        .onReceive(state.progressFeed.$currentTime) { feedCurrentTime = $0 }
    }

    private var subtitleText: String {
        guard let t = state.current else { return "version: 0.7 beta" }
        let artist = t.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album  = t.album.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (artist.isEmpty, album.isEmpty) {
        case (false, false): return "\(artist) — \(album)"
        case (false, true):  return artist
        case (true,  false): return album
        case (true,  true):  return "—"
        }
    }

    private var trackIndex: Int {
        state.tracks.firstIndex(where: { $0.id == state.currentId }) ?? 0
    }

    private var pitchLabel: String {
        let p = state.pitch
        if p == 0 { return "±0.0%" }
        return String(format: "%+.1f%%", p)
    }

    private var timeLabel: String {
        guard let t = state.current else { return "00:00 / 00:00" }
        let speed = 1.0 + state.pitch / 100.0
        return "\(fmtTime(feedCurrentTime / speed)) / \(fmtTime(t.duration / speed))"
    }
}

// ── Art swatch ─────────────────────────────────────────────────────────────────
struct ArtSwatchView: View {
    let index: Int
    let size: CGFloat
    let cornerRadius: CGFloat
    var artworkData: Data? = nil
    var trackId: UUID? = nil
    var showsBrandPlaceholder: Bool = false
    var isCurrent: Bool = false

    @State private var image: NSImage?
    @State private var loadGeneration: Int = 0

    // Cheap key: UUID string + artwork presence flag.
    // Avoids byte-level Data equality on every re-render (can be 256KB+ per track).
    private var artworkTaskId: String {
        "\(trackId?.uuidString ?? ""):\(artworkData != nil)"
    }

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
        .task(id: artworkTaskId) {
            guard let data = artworkData else { image = nil; return }
            loadGeneration += 1
            let generation = loadGeneration
            let requestedTrackId = trackId
            DispatchQueue.global(qos: .userInitiated).async {
                let cache = ArtworkCache.shared
                let resolvedImage: NSImage?
                if let id = requestedTrackId, let cached = cache.image(for: id) {
                    resolvedImage = cached
                } else if let decoded = NSImage(data: data) {
                    if let id = requestedTrackId { cache.store(decoded, for: id) }
                    resolvedImage = decoded
                } else {
                    resolvedImage = nil
                }

                DispatchQueue.main.async {
                    guard loadGeneration == generation else { return }
                    image = resolvedImage
                }
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
