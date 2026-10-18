import SwiftUI

/// Previous, play/pause and next for Apple Music or Spotify, on a translucent pill over a cover. Shown on hover,
/// and only when there's a player to control (`AppModel.controllablePlayer`).
struct PlaybackButtons: View {
    let model: AppModel
    /// Icon size; the pill grows with it.
    var size: CGFloat = 14

    var body: some View {
        let paused = !(model.controllablePlayer?.isPlaying ?? false)
        HStack(spacing: size * 0.9) {
            button("backward.fill", help: "Previous track") { model.playback(.previous) }
            button(paused ? "play.fill" : "pause.fill", help: paused ? "Play" : "Pause", scale: 1.25) { model.playback(.playPause) }
            button("forward.fill", help: "Next track") { model.playback(.next) }
        }
        .padding(.horizontal, size * 0.8)
        .padding(.vertical, size * 0.45)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func button(_ symbol: String, help: String, scale: CGFloat = 1, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * scale, weight: .semibold))
                .frame(width: size * 1.6, height: size * 1.6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
    }
}
