import AVKit
import SwiftUI

struct PhotoVideoView: View {
    let photo: IndexedPhoto
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if FileManager.default.fileExists(atPath: photo.filePath) {
                PhotoNativeVideoPlayer(player: player)
                    .task(id: photo.filePath) {
                        player?.pause()
                        player = AVPlayer(url: URL(fileURLWithPath: photo.filePath))
                        PhotoViewHistory.record(photo.id)
                    }
                    .onDisappear { player?.pause() }
            } else {
                ContentUnavailableView(String(localized: "Video unavailable", bundle: .module), systemImage: "video.slash")
            }
        }
    }
}

// The SwiftUI VideoPlayer bridge aborts while initializing its class metadata
// on the current macOS runtime. Use AVKit's native player view directly.
private struct PhotoNativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
