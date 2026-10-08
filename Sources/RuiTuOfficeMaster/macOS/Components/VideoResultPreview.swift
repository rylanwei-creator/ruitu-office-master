#if os(macOS)
import SwiftUI
import AVKit
import Combine

struct VideoResultPreview: View {
    let url: URL
    @State private var player: AVPlayer
    @State private var playbackError: String?
    @Environment(\.dismiss) private var dismiss

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("预览处理结果").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            NativeVideoPlayer(player: player)
                .frame(minWidth: 560, minHeight: 420)
            Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            if let playbackError { Text(playbackError).foregroundStyle(.red).font(.caption) }
        }
        .padding(20)
        .onAppear { player.play() }
        .onDisappear { player.pause() }
        .onReceive(player.publisher(for: \.status)) { status in
            if status == .failed { playbackError = player.error?.localizedDescription ?? "无法播放该文件，请检查格式与系统支持" }
        }
    }
}
private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
#endif
