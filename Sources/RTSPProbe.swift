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
/// It requests **TCP interleaved** transport (`RTP/AVP/TCP;interleaved=0-1`),
/// where RTP packets arrive on the RTSP connection itself framed as
/// `$<channel><2-byte length><payload>`. That needs no UDP bind at all, so if
/// packets arrive here the camera is fine and the problem is on VLC's side.
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

        // 3a. SETUP over interleaved TCP. This camera answers 461, but try it
        //     first: when a firmware does support it, no UDP bind is needed.
        var session: String?
        var interleaved = false
        if let setup = await request(
            "SETUP", target: track,
            headers: ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1"]
        ), let id = Self.header("Session", in: setup)?
            .split(separator: ";").first.map(String.init) {
            session = id
            interleaved = Self.header("Transport", in: setup)?.contains("interleaved") ?? false
        } else {
            note("⚠︎ Interleaved TCP refused (461). This firmware is UDP-only,")
            note("  so --rtsp-tcp cannot help — VLC must bind a UDP socket.")
        }

        // 3b. Fall back to UDP, binding our own receive socket. live555 fails
        //     here because it derives the local address via a multicast trick
        //     that returns 0.0.0.0 on iOS. NWConnection has no such problem, so
        //     this establishes whether the *camera* will stream over UDP.
        var rtpConnection: NWConnection?
        if session == nil {
            do {
                let (rtp, port) = try Self.bindRTPPort(host: host)
                rtpConnection = rtp
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
        }

        guard let session else {
            note("✗ SETUP refused for both transports — no session.")
            return
        }
        note("  session: \(session)")

        // 4. PLAY.
        guard await request("PLAY", target: track, headers: ["Session: \(session)"]) != nil else { return }

        note("Listening for RTP packets (5s)…")
        if interleaved {
            await readInterleaved(connection, seconds: 5)
        } else if let rtp = rtpConnection {
            await readUDP(rtp, seconds: 5)
        }

        if packetsReceived > 0 {
            note("✓ Received \(packetsReceived) RTP packets (\(bytesReceived) bytes).")
            note("The camera streams fine over \(interleaved ? "TCP" : "UDP") —")
            note("the failure is inside VLC's live555, not the camera.")
        } else {
            note("✗ No RTP packets arrived after PLAY.")
            note("The camera accepted the handshake but sends nothing.")
        }

        _ = await request("TEARDOWN", target: track, headers: ["Session: \(session)"])
        rtpConnection?.cancel()
    }

    /// Reads `$<channel><length><payload>` frames until the deadline.
    private func readInterleaved(_ connection: NWConnection, seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = Data()

        while Date() < deadline, !Task.isCancelled {
            guard let chunk = try? await Self.receive(connection, max: 65536), !chunk.isEmpty else { break }
            buffer.append(chunk)
            bytesReceived += chunk.count

            // Frame as much as the buffer holds.
            while buffer.count >= 4 {
                guard buffer[buffer.startIndex] == UInt8(ascii: "$") else {
                    // Not a frame marker — drop a byte and resync.
                    buffer.removeFirst()
                    continue
                }
                let lengthIndex = buffer.index(buffer.startIndex, offsetBy: 2)
                let length = Int(buffer[lengthIndex]) << 8
                    | Int(buffer[buffer.index(after: lengthIndex)])
                guard buffer.count >= 4 + length else { break }
                buffer.removeFirst(4 + length)
                packetsReceived += 1
                if packetsReceived == 1 { note("  first RTP packet: \(length) bytes") }
            }
        }
    }

    /// Binds a local UDP port for RTP and reports which one.
    ///
    /// `NWListener` is the wrong shape here — it expects inbound *connections*
    /// and fails with error 22 for a bare unidirectional datagram flow. A
    /// `NWConnection` to the camera's RTSP port with a pinned local endpoint
    /// binds the port and can receive the datagrams the camera sends to it.
    private static func bindRTPPort(host: String) throws -> (NWConnection, UInt16) {
        // Pick a high even port, as RTP convention expects (RTCP takes port+1).
        let port = UInt16.random(in: 20000...40000) & ~1

        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any),
                                                     port: .init(rawValue: port)!)

        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: .init(rawValue: port)!,
                                      using: parameters)
        return (connection, port)
    }

    /// Counts RTP datagrams arriving on the bound UDP socket.
    private func readUDP(_ connection: NWConnection, seconds: TimeInterval) async {
        connection.start(queue: .global(qos: .userInitiated))
        let deadline = Date().addingTimeInterval(seconds)

        while Date() < deadline, !Task.isCancelled {
            guard let datagram = try? await Self.receive(connection, max: 65536),
                  !datagram.isEmpty else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            packetsReceived += 1
            bytesReceived += datagram.count
            if packetsReceived == 1 {
                note("  first RTP datagram: \(datagram.count) bytes")
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
