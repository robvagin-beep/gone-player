import SwiftUI
import AppKit

struct FullPlayerView: View {
    @EnvironmentObject var state: PlayerState

    static let baseHeight: CGFloat = 128
    static let eqPanelHeight: CGFloat = 154

    private var contentHeight: CGFloat {
        Self.baseHeight
            + (state.tracks.isEmpty ? 0 : (state.eqOpen ? Self.eqPanelHeight : 0))
            + (state.tracks.isEmpty ? 0 : (state.playlistOpen ? state.playlistPanelHeight : 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // Player base — always rendered, dimmed when no track loaded
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        TrackHeaderView()
                        ProgressRulerRow()
                        TransportView()
                    }
                    .padding(.top, 4)
                    PitchFaderView()
                }
                .opacity(state.tracks.isEmpty ? 0.15 : 1.0)
                .allowsHitTesting(!state.tracks.isEmpty)
                .overlay {
                    if state.tracks.isEmpty {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.025))
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 10)
                            .allowsHitTesting(false)
                    }
                }

                // Typewriter overlay — floats over ghost player when empty
                if state.tracks.isEmpty {
                    EmptyOverlayView()
                }
            }
            .frame(height: Self.baseHeight, alignment: .top)
            .transaction { transaction in
                transaction.animation = nil
            }

            // Panels expand the window below the base player
            if !state.tracks.isEmpty {
                if state.eqOpen {
                    EQPanelView()
                        .frame(height: Self.eqPanelHeight, alignment: .top)
                }
                if state.playlistOpen {
                    PlaylistView()
                        .frame(height: state.playlistPanelHeight, alignment: .top)
                }
            }
        }
        .frame(width: G.windowWidth, height: contentHeight, alignment: .top)
        .background(G.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: G.rWindowInner))
        .overlay {
            RoundedRectangle(cornerRadius: G.rWindowInner)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: G.rWindowInner)
                .stroke(Color.black.opacity(0.6), lineWidth: 1)
                .blur(radius: 0.2)
        }
    }
}

// ── Empty overlay — typewriter text over ghost player ─────────────────────────
struct EmptyOverlayView: View {
    @EnvironmentObject var state: PlayerState
    @State private var displayText = ""
    @State private var animTask: Task<Void, Never>?
    @State private var arrowOffset: CGFloat = 0

    private let messages = [
        "WELCOME TO GONE PLAYER",
        "NO TRACK LOADED",
        "DRAG AND DROP TRACK HERE",
        "OR JUST CLICK, IT'S UP TO YOU",
    ]

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .offset(y: arrowOffset)

                    Text(displayText.isEmpty ? " " : displayText)
                        .font(G.mono(11, weight: .medium))
                        .foregroundStyle(G.textMuted)
                        .monospacedDigit()
                        .tracking(0.4)
                        .animation(nil, value: displayText)
                }
            )
            .overlay(alignment: .bottom) {
                Text("GONE player  β04")
                    .font(G.mono(7, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.20))
                    .tracking(0.5)
                    .padding(.bottom, 14)
                    .allowsHitTesting(false)
            }
            .onTapGesture { openFilePicker() }
            .onAppear {
                startTypewriter()
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    arrowOffset = 5
                }
            }
            .onDisappear { animTask?.cancel() }
    }

    private func startTypewriter() {
        animTask?.cancel()
        animTask = Task { @MainActor in
            var idx = 0
            while !Task.isCancelled {
                let msg = messages[idx % messages.count]
                displayText = ""
                for char in msg {
                    guard !Task.isCancelled else { return }
                    displayText += String(char)
                    try? await Task.sleep(nanoseconds: 70_000_000)
                }
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                while !displayText.isEmpty && !Task.isCancelled {
                    displayText = String(displayText.dropLast())
                    try? await Task.sleep(nanoseconds: 38_000_000)
                }
                try? await Task.sleep(nanoseconds: 450_000_000)
                idx += 1
            }
        }
    }

    func openFilePicker() {
        state.presentImportPanel()
    }
}
