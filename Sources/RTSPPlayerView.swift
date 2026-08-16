import SwiftUI
import MobileVLCKit

/// Live viewfinder backed by MobileVLCKit.
///
/// The camera's Wi-Fi has no internet and no gateway, so RTP over UDP frequently
/// fails to establish ("invalid IP address: 0.0.0.0"). Forcing RTSP interleaved
/// over TCP avoids the local UDP bind entirely.
struct RTSPPlayerView: UIViewRepresentable {
    let url: URL
    /// Reports playback state so the UI can distinguish "connecting" from
    /// "failed" instead of showing an indefinite black rectangle.
    var onStateChange: ((State) -> Void)?

    /// Only the states the UI distinguishes. A separate `.ended` case was
    /// indistinguishable from `.playing` at every call site, and was reported
    /// from teardown after the view had already gone away.
    enum State {
        case connecting
        case playing
        case failed
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.onStateChange = onStateChange
        context.coordinator.attach(to: view, url: url)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onStateChange = onStateChange
        context.coordinator.attach(to: uiView, url: url)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        private var player: VLCMediaPlayer?
        private var currentURL: URL?
        var onStateChange: ((State) -> Void)?

        func attach(to view: UIView, url: URL) {
            guard currentURL != url else { return }
            stop()
            currentURL = url

            let player = VLCMediaPlayer()
            player.drawable = view
            player.delegate = self

            let media = VLCMedia(url: url)
            // Media options take the ":name=value" form. Library-level options
            // use "--name", so "--rtsp-tcp" here is silently ignored — the TCP
            // transport must be requested as ":rtsp-tcp".
            media.addOption(":rtsp-tcp")
            // Belt-and-braces: also force RTP to be interleaved over the RTSP
            // control connection rather than a separate UDP socket, which is
            // what fails to bind on this gateway-less network.
            media.addOption(":rtsp-mcast=0")
            // Low latency for a live viewfinder; the default 1000ms is too slow
            // to be usable for framing a shot.
            media.addOption(":network-caching=300")
            media.addOption(":live-caching=300")
            media.addOption(":clock-jitter=0")
            media.addOption(":clock-synchro=0")
            // Don't retry forever against a server that isn't listening.
            media.addOption(":rtsp-timeout=10")

            player.media = media
            player.play()
            self.player = player
            onStateChange?(.connecting)
        }

        func mediaPlayerStateChanged(_ notification: Notification) {
            guard let player else { return }
            switch player.state {
            case .playing, .buffering:
                onStateChange?(.playing)
            case .error:
                print("[rtsp] player error for \(currentURL?.absoluteString ?? "-")")
                onStateChange?(.failed)
            default:
                break
            }
        }

        func stop() {
            player?.delegate = nil
            player?.stop()
            player?.drawable = nil
            player = nil
            currentURL = nil
        }

        deinit {
            // VLC teardown must happen on the main thread.
            guard let player else { return }
            if Thread.isMainThread {
                player.stop()
            } else {
                DispatchQueue.main.sync { player.stop() }
            }
        }
    }
}
