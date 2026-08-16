import Foundation
import Network

/// Watches whether the camera is reachable, to gate the Connect button.
///
/// The obvious approach — read the Wi-Fi SSID and look for the `YDXJ_` prefix —
/// needs `NEHotspotNetwork.fetchCurrent`, which requires either a special
/// entitlement or **precise location permission**. Asking a camera app for
/// location access to read a network name is a poor trade.
///
/// Probing instead answers the question that actually matters. The camera lives
/// at a fixed address, so a short connection attempt to its control port
/// distinguishes all three states a user can be in: on another network, on the
/// camera's network with the camera asleep, or genuinely ready. An SSID check
/// would call that middle case "ready" and let the user tap into a hang.
@MainActor
final class CameraReachability: ObservableObject {

    enum Status: Equatable {
        /// Probing, or not yet started. No consumer distinguishes those.
        case checking
        /// The control port answered — the camera is there.
        case reachable
        /// Wi-Fi is up but the camera did not answer: wrong network, or the
        /// camera is off or asleep.
        case unreachable
        /// The device has no Wi-Fi connection at all.
        case noWiFi
    }

    @Published private(set) var status: Status = .checking

    private var monitor: NWPathMonitor?
    private var probeTask: Task<Void, Never>?
    /// Set by `stop()`. A path update already queued when stop was called can
    /// still arrive afterwards, and without this it would restart the probe
    /// loop with no view on screen — reopening a socket to the camera's
    /// single-connection control port every few seconds.
    private var isStopped = false
    /// How long to wait for the control port before calling it unreachable.
    private static let probeTimeout: Duration = .seconds(2)
    /// Re-probe while the user is looking at the connect screen, so plugging in
    /// or waking the camera updates the button without a manual retry.
    private static let repeatInterval: Duration = .seconds(4)

    var isReachable: Bool { status == .reachable }

    /// Starts watching. Safe to call repeatedly.
    func start() {
        isStopped = false
        guard monitor == nil else { return }

        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                if path.status == .satisfied {
                    self.beginProbing()
                } else {
                    // No Wi-Fi at all: the camera cannot be reachable, and
                    // probing would just wait out the timeout.
                    self.probeTask?.cancel()
                    self.probeTask = nil
                    self.status = .noWiFi
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    func stop() {
        isStopped = true
        probeTask?.cancel()
        probeTask = nil
        monitor?.cancel()
        monitor = nil
        status = .checking
    }

    private func beginProbing() {
        guard !isStopped, probeTask == nil else { return }
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.status != .reachable { self.status = .checking }
                let reachable = await Self.probe()
                guard !Task.isCancelled else { return }
                self.status = reachable ? .reachable : .unreachable
                try? await Task.sleep(for: Self.repeatInterval)
            }
        }
    }

    /// Opens a short-lived connection to the camera's control port.
    ///
    /// Pinned to Wi-Fi for the same reason every other connection is: the
    /// camera's network has no internet, so iOS would otherwise route this over
    /// cellular and fail with EADDRNOTAVAIL.
    private nonisolated static func probe() async -> Bool {
        // Same endpoint and Wi-Fi pinning as the real session, from the one
        // place that owns them.
        let parameters = YiCameraClient.controlParameters()
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 2
        }
        let endpoint = YiCameraClient.controlEndpoint()
        let connection = NWConnection(host: endpoint.host, port: endpoint.port, using: parameters)

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    connection.stateUpdateHandler = { [weak connection] state in
                        // Clearing the handler on the first terminal state is
                        // enough to resume exactly once: it runs on the
                        // connection's own serial queue, so there is no race.
                        switch state {
                        case .ready:
                            connection?.stateUpdateHandler = nil
                            continuation.resume(returning: true)
                        case .failed, .cancelled:
                            connection?.stateUpdateHandler = nil
                            continuation.resume(returning: false)
                        default:
                            break
                        }
                    }
                    connection.start(queue: .global(qos: .utility))
                }
            }
            group.addTask {
                try? await Task.sleep(for: probeTimeout)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            connection.cancel()
            return result
        }
    }
}
