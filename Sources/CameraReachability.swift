import Foundation
import Network
import os

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
        case unknown
        case checking
        /// The control port answered — the camera is there.
        case reachable
        /// Wi-Fi is up but the camera did not answer: wrong network, or the
        /// camera is off or asleep.
        case unreachable
        /// The device has no Wi-Fi connection at all.
        case noWiFi
    }

    @Published private(set) var status: Status = .unknown

    private var monitor: NWPathMonitor?
    private var probeTask: Task<Void, Never>?
    /// How long to wait for the control port before calling it unreachable.
    private static let probeTimeout: Duration = .seconds(2)
    /// Re-probe while the user is looking at the connect screen, so plugging in
    /// or waking the camera updates the button without a manual retry.
    private static let repeatInterval: Duration = .seconds(4)

    var isReachable: Bool { status == .reachable }

    /// Starts watching. Safe to call repeatedly.
    func start() {
        guard monitor == nil else { return }

        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
        probeTask?.cancel()
        probeTask = nil
        monitor?.cancel()
        monitor = nil
        status = .unknown
    }

    private func beginProbing() {
        guard probeTask == nil else { return }
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
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 2
        }

        let connection = NWConnection(
            host: NWEndpoint.Host("192.168.42.1"),
            port: NWEndpoint.Port(rawValue: 7878)!,
            using: parameters
        )

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    // `resumed` guards against the handler firing more than
                    // once, which NWConnection does on some transitions.
                    let resumed = OSAllocatedUnfairLock(initialState: false)
                    @Sendable func finish(_ value: Bool) {
                        let shouldResume = resumed.withLock { done -> Bool in
                            if done { return false }
                            done = true
                            return true
                        }
                        if shouldResume { continuation.resume(returning: value) }
                    }

                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:            finish(true)
                        case .failed, .cancelled: finish(false)
                        default:                break
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
