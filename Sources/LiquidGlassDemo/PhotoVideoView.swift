import AVKit
import Photos
import SwiftUI

struct PhotoVideoView: View {
    let photo: IndexedPhoto
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var requestID: PHImageRequestID?
    @State private var generation = 0

    var body: some View {
        Group {
            if let player {
                PhotoNativeVideoPlayer(player: player)
            } else if loading {
                ProgressView(String(localized: "Loading video from Photos…", bundle: .module))
            } else {
                ContentUnavailableView(String(localized: "Video unavailable in Photos", bundle: .module),
                                       systemImage: "video.slash",
                                       description: Text(String(localized: "Check Photos access and your connection, then try again.", bundle: .module)))
            }
        }
        .task(id: photo.id) { await loadVideo() }
        .onDisappear {
            generation += 1
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
            player?.pause()
        }
    }

    @MainActor
    private func loadVideo() async {
        generation += 1
        let current = generation
        loading = true
        player?.pause()
        player = nil
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard !Task.isCancelled, current == generation,
              status == .authorized || status == .limited,
              let identifier = try? PhotoOriginal.identifier(for: photo.id),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              asset.mediaType == .video else {
            loading = false
            return
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        requestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
            Task { @MainActor in
                guard current == generation else { return }
                loading = false
                if let item {
                    player = AVPlayer(playerItem: item)
                    PhotoViewHistory.record(photo.id)
                }
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
