import Foundation
import Network

/// Minimal RTSP client used to test the stream *below* VLC.
///
/// VLC reports "invalid IP address: 0.0.0.0" from live555, which is a symptom
/// with several possible causes: the camera not serving, the handshake being
/// rejected, or live555 failing to bind an RTP socket. Those are
/// indistinguishable from the outside, so this speaks RTSP directly —
/// OPTIONS, DESCRIBE, SETUP, PLAY — over the same Wi-Fi-pinned socket the
/// control channel uses, and reports exactly how far it gets.
///
/// It uses **UDP**, mirroring `RTSPStream`. Interleaved TCP is not attempted:
/// this firmware answers `461` and then closes the control socket, so the UDP
/// SETUP that used to follow was written to an already-reset connection and
/// failed with "No message available on STREAM" — a probe bug that looked for
/// a long time like a camera limitation.
///
/// Now that `RTSPStream` exists and logs its own handshake, this is mostly
/// redundant; it stays for testing the transport without mounting a player.
@MainActor
final class RTSPProbe: ObservableObject {

    @Published private(set) var log: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var packetsReceived = 0
    @Published private(set) var bytesReceived = 0

    private var connection: NWConnection?
    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        connection?.cancel()
        connection = nil
        isRunning = false
        note("— cancelled —")
    }

    func run(url: URL) {
        guard !isRunning else { return }
        isRunning = true
        log = []
        packetsReceived = 0
        bytesReceived = 0

        task = Task {
            defer { isRunning = false; connection?.cancel(); connection = nil }
            await probe(url: url)
        }
    }

    private func probe(url: URL) async {
        let host = url.host ?? YiCameraClient.host
        let port = UInt16(url.port ?? 554)
        note("Connecting to \(host):\(port)…")

        let parameters = YiCameraClient.controlParameters()
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: parameters)
        self.connection = connection

        do {
            try await Self.start(connection)
            note("✓ TCP connected")
        } catch {
            note("✗ TCP failed: \(error.localizedDescription)")
            note("The camera is not accepting connections on \(port).")
            return
        }

        var cseq = 1
        func request(_ method: String, target: String? = nil, headers: [String] = []) async -> String? {
            var lines = ["\(method) \(target ?? url.absoluteString) RTSP/1.0",
                         "CSeq: \(cseq)",
                         "User-Agent: Yippy-Probe"]
            lines.append(contentsOf: headers)
            let message = lines.joined(separator: "\r\n") + "\r\n\r\n"
            cseq += 1

            note("→ \(method)")
            do {
                try await Self.send(connection, Data(message.utf8))
                let reply = try await Self.receiveText(connection)
                let status = reply.split(separator: "\r\n").first.map(String.init) ?? "(no status)"
                note("← \(status)")
                return reply
            } catch {
                note("✗ \(method) failed: \(error.localizedDescription)")
                return nil
            }
        }

        // 1. OPTIONS — does it speak RTSP at all?
        guard let options = await request("OPTIONS") else { return }
        if let publicLine = Self.header("Public", in: options) {
            note("  supports: \(publicLine)")
        }

        // 2. DESCRIBE — is there a stream, and what is in it?
        guard let describe = await request("DESCRIBE", headers: ["Accept: application/sdp"]) else { return }
        let sdp = Self.body(of: describe)
        if sdp.isEmpty {
            note("✗ No SDP returned — the camera is not publishing a stream.")
            return
        }
        for line in sdp.split(separator: "\n").prefix(12) {
            note("  sdp: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // The control URL for the first media track, resolved against
        // Content-Base — a relative "track1" against the request URL 404s.
        let track = Self.trackURL(sdp: sdp, describe: describe, base: url)
        note("  track: \(track)")

        // 3a. Interleaved TCP is not attempted. This camera answers 461 and
        //     then closes the control socket, so the UDP SETUP that followed
        //     was written to a connection the camera had already RST — the
        //     "error 96 - No message available on STREAM" in every probe log.
        //     The failure was the probe's, not the camera's: the viewfinder's
        //     UDP SETUP succeeds on a socket that never made the TCP attempt.
        note("⚠︎ Skipping interleaved TCP — this firmware answers 461 and then")
        note("  closes the control socket, which breaks the UDP SETUP after it.")

        // 3b. UDP, binding our own receive socket. live555 fails here because
        //     it derives the local address via a multicast trick that returns
        //     0.0.0.0 on iOS; Network.framework has no such problem.
        var rtpListener: NWListener?
        let rtpFlow = RTSPStream.RTPFlow()
        var session: String?
        do {
            let (rtp, port) = try Self.bindRTPPort(delivering: rtpFlow)
            rtpListener = rtp
            note("Bound local UDP port \(port) for RTP")

            if let setup = await request(
                "SETUP", target: track,
                headers: ["Transport: RTP/AVP;unicast;client_port=\(port)-\(port + 1)"]
            ), let id = Self.header("Session", in: setup)?
                .split(separator: ";").first.map(String.init) {
                session = id
                if let transport = Self.header("Transport", in: setup) {
                    note("  transport: \(transport)")
                }
            }
        } catch {
            note("✗ Could not bind a local UDP port: \(error.localizedDescription)")
        }

        guard let session else {
            note("✗ SETUP refused — no session.")
            return
        }
        note("  session: \(session)")

        // 4. PLAY.
        guard await request("PLAY", target: track, headers: ["Session: \(session)"]) != nil else { return }

        note("Listening for RTP packets (5s)…")
        if rtpListener != nil {
            await readUDP(rtpFlow, seconds: 5)
        }

        if packetsReceived > 0 {
            note("✓ Received \(packetsReceived) RTP packets (\(bytesReceived) bytes).")
            note("The camera streams fine over UDP.")
        } else {
            note("✗ No RTP packets arrived after PLAY.")
            note("The camera accepted the handshake but sends nothing.")
        }

        _ = await request("TEARDOWN", target: track, headers: ["Session: \(session)"])
        rtpFlow.finish()
        rtpListener?.newConnectionHandler = nil
        rtpListener?.cancel()
    }

    /// Binds a local UDP port for RTP and reports which one.
    ///
    /// This must **listen**, not connect. The camera sends RTP from its own
    /// `server_port`, which is not the port we send to, and a connected UDP
    /// socket drops datagrams from any other source — a handshake that
    /// completes cleanly and then delivers nothing.
    ///
    /// The handler is installed before `start()`: RTP can arrive as soon as the
    /// camera processes PLAY, and a datagram landing on a handler-less listener
    /// is discarded ("Started without setting either new connection handler…").
    ///
    /// (An earlier version blamed `NWListener` for an "error 22" here. That was
    /// the `requiredLocalEndpoint` in the parameters, not the listener: a
    /// listener takes its port in `NWListener(using:on:)` instead.)
    private static func bindRTPPort(delivering flow: RTSPStream.RTPFlow) throws -> (NWListener, UInt16) {
        // Pick a high even port, as RTP convention expects (RTCP takes port+1).
        let port = UInt16.random(in: 20000...40000) & ~1

        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .init(rawValue: port)!)
        listener.newConnectionHandler = { connection in flow.accept(connection) }
        listener.start(queue: .global(qos: .userInitiated))
        return (listener, port)
    }

    /// Counts RTP datagrams arriving on the bound UDP port.
    private func readUDP(_ flow: RTSPStream.RTPFlow, seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline, !Task.isCancelled {
            guard let datagram = await flow.next(), !datagram.isEmpty else { break }
            packetsReceived += 1
            bytesReceived += datagram.count
            if packetsReceived == 1 {
                note("  first RTP datagram: \(datagram.count) bytes from \(flow.endpointDescription)")
            }
        }
    }

    // MARK: - Socket helpers

    private static func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .ready:
                    connection?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection?.stateUpdateHandler = nil
                    continuation.resume(throwing: YiCameraError.connectionFailed)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private static func receive(_ connection: NWConnection, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { content, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: content ?? Data()) }
            }
        }
    }

    /// Reads until the end of the RTSP headers, plus any declared body.
    private static func receiveText(_ connection: NWConnection) async throws -> String {
        var data = Data()
        while true {
            let chunk = try await receive(connection, max: 8192)
            if chunk.isEmpty { break }
            data.append(chunk)
            guard let text = String(data: data, encoding: .utf8) else { continue }
            guard let headerEnd = text.range(of: "\r\n\r\n") else { continue }

            // Keep reading until the whole Content-Length body has arrived.
            if let lengthText = header("Content-Length", in: text), let expected = Int(lengthText) {
                let body = text[headerEnd.upperBound...]
                if body.utf8.count < expected { continue }
            }
            return text
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Parsing

    private static func header(_ name: String, in message: String) -> String? {
        for line in message.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(name) == .orderedSame else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func body(of message: String) -> String {
        guard let range = message.range(of: "\r\n\r\n") else { return "" }
        return String(message[range.upperBound...])
    }

    /// Resolves the track control URL from the SDP.
    ///
    /// The per-track `a=control:` value is relative (`track1`) and must be
    /// joined to `Content-Base`, not to the request URL — the camera reports
    /// `rtsp://192.168.42.1/live/` there, so the track is
    /// `rtsp://192.168.42.1/live/track1`. Ignoring Content-Base yields
    /// `.../live` and a 404.
    private static func trackURL(sdp: String, describe: String, base: URL) -> String {
        let contentBase = header("Content-Base", in: describe)
            ?? (base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/")

        // Split on unicodeScalars, not Characters: "\r\n" is a *single*
        // grapheme cluster in Swift, so a Character-level split on "\n" or
        // "\r" matches nothing and leaves the whole SDP as one line — which
        // made this return Content-Base and the camera answer 400.
        let lines = sdp.unicodeScalars
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String(String.UnicodeScalarView($0)) }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("a=control:") else { continue }
            let value = String(trimmed.dropFirst("a=control:".count))
            if value == "*" { continue }
            if value.hasPrefix("rtsp://") { return value }
            return contentBase.hasSuffix("/") ? contentBase + value : contentBase + "/" + value
        }
        return contentBase
    }

    private func note(_ message: String) {
        log.append(message)
        print("[rtsp-probe] \(message)")
    }
}
