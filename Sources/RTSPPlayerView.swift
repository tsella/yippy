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

            // Library-level options, which media options cannot reach. VLC's
            // RTSP demuxer is chosen and configured at library init, so
            // "--rtsp-tcp" must be set here — as a media option it is silently
            // ignored, leaving live555 to attempt a UDP bind that fails with
            // "invalid IP address: 0.0.0.0" on this gateway-less network.
            // Boolean options use the --option / --no-option form; passing
            // "=0" to one makes VLC reject the whole argument list and abort
            // before the player exists. Every option here is verified against
            // the shipped MobileVLCKit build.
            var options = [
                "--rtsp-tcp",
                // Not HTTP tunnelling — that is a different transport.
                "--no-rtsp-http",
                // No multicast on a point-to-point camera link.
                "--no-rtsp-mcast",
                "--network-caching=300",
                "--live-caching=300",
                "--clock-jitter=0",
                "--clock-synchro=0",
            ]
            // Verbose logging, behind the debug toggle. "0.0.0.0" is only the
            // symptom; this shows which module fails and at what stage of the
            // RTSP handshake, which is the difference between a theory and a
            // diagnosis. Off by default — it is extremely noisy.
            if UserDefaults.standard.bool(forKey: "showDebugScanner") {
                options.append("--verbose=2")
            }

            let player = VLCMediaPlayer(options: options)
            player.drawable = view
            player.delegate = self

            let media = VLCMedia(url: url)
            // Repeated per-media so they survive a demuxer that reads them here.
            media.addOption(":rtsp-tcp")
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
            // VLC delivers state changes on its own thread. Reporting straight
            // from here would mutate SwiftUI state off the main actor, which is
            // most likely precisely when the network drops and VLC floods
            // error transitions.
            guard let player else { return }
            let state = player.state
            DispatchQueue.main.async { [weak self] in
                guard let self, self.player != nil else { return }
                switch state {
                case .playing, .buffering:
                    self.onStateChange?(.playing)
                case .error:
                    print("[rtsp] player error for \(self.currentURL?.absoluteString ?? "-")")
                    self.onStateChange?(.failed)
                default:
                    break
                }
            }
        }

        func stop() {
            // Clear the delegate before stopping: `stop()` itself drives state
            // transitions, and a callback into a coordinator that is being
            // torn down is the crash this guards against.
            player?.delegate = nil
            player?.stop()
            player?.drawable = nil
            player = nil
            currentURL = nil
        }

        deinit {
            // VLC teardown must happen on the main thread, but never with a
            // synchronous hop: `DispatchQueue.main.sync` from a deinit that is
            // already running on the main thread deadlocks outright, and that
            // is exactly what happens when the camera drops its Wi-Fi and the
            // player is released during SwiftUI's teardown.
            //
            // The delegate is cleared first so a state change cannot call back
            // into a half-released coordinator, then the player is handed to
            // the main queue to stop and release asynchronously.
            player?.delegate = nil
            guard let player else { return }
            DispatchQueue.main.async {
                player.stop()
            }
        }
    }
}
