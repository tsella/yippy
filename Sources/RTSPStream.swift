import Foundation
import Network
import CoreMedia

/// A self-contained RTSP/UDP client for the camera's viewfinder.
///
/// Exists because VLC cannot play this stream: the camera refuses interleaved
/// TCP (`461 Unsupported Transport`), and on the UDP path live555 determines
/// its local address with a multicast trick that returns `0.0.0.0` on iOS.
/// `NWConnection` has no such problem, and the stream itself is simple —
/// one H.264 baseline track, no audio, no auth, no encryption — so speaking it
/// directly is less work than carrying a media framework to work around a bug
/// in another one.
@MainActor
final class RTSPStream: ObservableObject {

    enum State: Equatable {
        case idle
        case connecting
        case playing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var framesDecoded = 0

    /// Whether a stream is currently held open. The camera serves one RTSP
    /// session at a time, so the debug probe must not run concurrently.
    var isActive: Bool { task != nil }

    /// Every handshake step is logged. A failure before the first frame is
    /// otherwise invisible — the only previous output was on success, which
    /// made a silent failure indistinguishable from never having started.
    private func log(_ message: String) {
        print("[rtsp-stream] \(message)")
    }

    private var control: NWConnection?
    private var rtp: NWConnection?
    private var rtpListener: NWListener?
    private var session: String?
    private var task: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var depacketizer = H264Depacketizer()
    private weak var view: H264StreamLayerView?

    /// What the layer is currently configured with, so repeated in-band
    /// parameter sets only rebuild the format description when they change.
    private var activeParameterSets: (sps: Data, pps: Data)?

    /// Frames carry a 90 kHz RTP timestamp; the layer wants seconds.
    private static let clockRate: Int32 = 90_000

    func attach(_ view: H264StreamLayerView) {
        self.view = view
    }

    func start(url: URL) {
        guard task == nil else {
            log("start ignored — already running")
            return
        }
        log("start \(url.absoluteString)")
        state = .connecting
        framesDecoded = 0
        depacketizer = H264Depacketizer()
        activeParameterSets = nil
        task = Task { await run(url: url) }
    }

    func stop() {
        guard task != nil || control != nil else { return }
        log("stop")
        keepAlive?.cancel(); keepAlive = nil
        task?.cancel(); task = nil
        if let session, let control {
            // Best-effort TEARDOWN so the camera frees the session promptly.
            let message = "TEARDOWN \(controlURL ?? "") RTSP/1.0\r\nCSeq: 99\r\nSession: \(session)\r\n\r\n"
            control.send(content: Data(message.utf8), completion: .idempotent)
        }
        session = nil
        control?.cancel(); control = nil
        rtp?.cancel(); rtp = nil
        rtpListener?.newConnectionHandler = nil
        rtpListener?.cancel(); rtpListener = nil
        activeParameterSets = nil
        view?.reset()
        state = .idle
    }

    private var controlURL: String?
    private var cseq = 1

    private func run(url: URL) async {
        let host = url.host ?? YiCameraClient.host
        let port = UInt16(url.port ?? 554)

        // 1. RTSP control connection, pinned to Wi-Fi like every other socket
        //    — the camera's network has no route otherwise.
        log("connecting to \(host):\(port)…")
        let control = NWConnection(host: NWEndpoint.Host(host),
                                   port: NWEndpoint.Port(rawValue: port)!,
                                   using: YiCameraClient.controlParameters())
        self.control = control
        do {
            try await Self.start(control)
        } catch {
            log("✗ TCP connect failed: \(error.localizedDescription)")
            state = .failed("Could not reach the camera on port \(port).")
            return
        }
        log("✓ TCP connected")

        // 2. DESCRIBE for the SDP.
        log("→ DESCRIBE \(url.absoluteString)")
        guard let describe = await request("DESCRIBE", target: url.absoluteString,
                                           headers: ["Accept: application/sdp"]),
              case let sdp = Self.body(of: describe), !sdp.isEmpty else {
            log("✗ DESCRIBE returned no SDP")
            state = .failed("The camera did not describe a stream.")
            return
        }
        log("← \(Self.status(of: describe))")

        // 3. Configure the decoder from sprop-parameter-sets before any frame
        //    arrives, so the first IDR can be displayed rather than dropped.
        if let sets = H264Depacketizer.parameterSets(fromSDP: sdp) {
            log("SDP parameter sets: SPS \(sets.sps.count)B, PPS \(sets.pps.count)B")
            configure(sps: sets.sps, pps: sets.pps)
        } else {
            log("⚠︎ no sprop-parameter-sets in SDP — waiting for in-band SPS/PPS")
        }

        let track = Self.trackURL(sdp: sdp, describe: describe, base: url)
        controlURL = track
        log("track: \(track)")

        // 4. Bind a local RTP port and SETUP. The camera only supports UDP:
        //    it answers 461 for interleaved TCP, so there is no fallback to try.
        //
        //    This must *listen*, not connect. The camera sends RTP from its own
        //    server_port, which is not the port we send to, and a connected UDP
        //    socket silently drops datagrams from any other source — the cause
        //    of a handshake that completed cleanly and then delivered 0 frames.
        let rtpPort = UInt16.random(in: 20000...40000) & ~1
        guard let listener = try? Self.listen(on: rtpPort) else {
            log("✗ could not bind local UDP port \(rtpPort)")
            state = .failed("Could not open a port to receive video.")
            return
        }
        self.rtpListener = listener
        log("listening on local UDP port \(rtpPort) for RTP")

        log("→ SETUP (client_port=\(rtpPort)-\(rtpPort + 1))")
        guard let setup = await request(
            "SETUP", target: track,
            headers: ["Transport: RTP/AVP;unicast;client_port=\(rtpPort)-\(rtpPort + 1)"]
        ) else {
            log("✗ SETUP got no response")
            state = .failed("The camera refused to set up the stream.")
            return
        }
        log("← \(Self.status(of: setup))")
        guard let id = Self.header("Session", in: setup)?
            .split(separator: ";").first.map(String.init) else {
            log("✗ SETUP carried no Session header")
            state = .failed("The camera refused to set up the stream.")
            return
        }
        session = id
        // Worth logging: RTP arrives *from* this port, not the one we send to.
        // Assuming otherwise is what made the first implementation deaf.
        if let transport = Self.header("Transport", in: setup) {
            log("transport: \(transport)")
        }
        log("session \(id)")

        // 5. PLAY, then read RTP until cancelled.
        log("→ PLAY")
        guard let play = await request("PLAY", target: track,
                                       headers: ["Session: \(id)"]) else {
            log("✗ PLAY got no response")
            state = .failed("The camera refused to start the stream.")
            return
        }
        log("← \(Self.status(of: play))")
        state = .playing
        startKeepAlive(track: track, session: id)
        await readRTP(from: listener)
    }

    /// Binds a UDP listener that accepts RTP from whatever source port the
    /// camera chooses, and hands back the first flow it sees.
    private static func listen(on port: UInt16) throws -> NWListener {
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters,
                                      on: .init(rawValue: port)!)
        listener.start(queue: .global(qos: .userInitiated))
        return listener
    }

    /// Applies parameter sets to the layer, remembering them so an identical
    /// in-band repeat does not rebuild the format description on every IDR.
    private func configure(sps: Data, pps: Data) {
        guard activeParameterSets?.sps != sps || activeParameterSets?.pps != pps else { return }
        activeParameterSets = (sps, pps)
        view?.configure(sps: sps, pps: pps)
    }

    private static func status(of message: String) -> String {
        message.unicodeScalars
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first.map { String(String.UnicodeScalarView($0)) } ?? "(no status)"
    }

    /// The camera drops an idle RTSP session, so poke it periodically. Uses
    /// the control connection, not the app's 7878 channel.
    private func startKeepAlive(track: String, session: String) {
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                _ = await self?.request("GET_PARAMETER", target: track,
                                        headers: ["Session: \(session)"])
            }
        }
    }

    private func readRTP(from listener: NWListener) async {
        // The camera opens the flow by sending its first datagram; take that
        // as the RTP connection and read the rest from it.
        guard let connection = await Self.firstInboundFlow(on: listener) else {
            log("✗ no RTP arrived — the camera never sent to our port")
            state = .failed("The camera accepted the stream but sent no video.")
            return
        }
        self.rtp = connection
        log("✓ RTP flow from \(connection.endpoint)")

        var firstPacketLogged = false
        var firstFrameLogged = false

        while !Task.isCancelled {
            guard let datagram = try? await Self.receive(connection, max: 65536),
                  !datagram.isEmpty else { continue }

            if !firstPacketLogged {
                firstPacketLogged = true
                log("✓ first RTP packet (\(datagram.count) bytes)")
            }

            let units = depacketizer.handle(rtpPacket: datagram)
            guard !units.isEmpty else { continue }

            // Parameter sets also arrive in-band, and they change: the camera
            // reconfigures its encoder when recording starts, so the SDP's
            // sets go stale mid-session. Honour whatever the stream carries.
            depacketizer.noteParameterSets(from: units)
            if let sets = depacketizer.parameterSets {
                configure(sps: sets.sps, pps: sets.pps)
            }

            let timestamp = Self.timestamp(of: datagram)
            let time = CMTime(value: CMTimeValue(timestamp), timescale: Self.clockRate)
            view?.enqueue(H264Depacketizer.avcc(units), presentationTime: time)

            framesDecoded += 1
            if !firstFrameLogged {
                firstFrameLogged = true
                log("✓ first frame decoded")
            }
        }
        log("RTP reader stopped after \(framesDecoded) frames")
    }

    /// Guards a one-shot continuation against a second inbound flow. A plain
    /// captured `var` would be a data race — the handler runs off-actor.
    private final class FlowGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        /// True for the first caller only.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// Waits for the camera's first RTP datagram, which is what establishes the
    /// inbound flow. Times out so a camera that accepts PLAY and then sends
    /// nothing reports a failure rather than hanging silently.
    ///
    /// One continuation, resumed by whichever of the flow or the timeout gets
    /// there first — a task group would abandon the loser's continuation, which
    /// `withCheckedContinuation` requires be resumed exactly once.
    private static func firstInboundFlow(on listener: NWListener,
                                         timeout: Duration = .seconds(10)) async -> NWConnection? {
        let gate = FlowGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<NWConnection?, Never>) in
            listener.newConnectionHandler = { connection in
                guard gate.claim() else {
                    connection.cancel()
                    return
                }
                connection.start(queue: .global(qos: .userInitiated))
                continuation.resume(returning: connection)
            }
            Task {
                try? await Task.sleep(for: timeout)
                guard gate.claim() else { return }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func timestamp(of packet: Data) -> UInt32 {
        guard packet.count >= 8 else { return 0 }
        let base = packet.index(packet.startIndex, offsetBy: 4)
        return packet[base...].prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    // MARK: - RTSP plumbing

    private func request(_ method: String, target: String,
                         headers: [String] = []) async -> String? {
        guard let control else { return nil }
        var lines = ["\(method) \(target) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: Yippy"]
        lines.append(contentsOf: headers)
        cseq += 1

        do {
            try await Self.send(control, Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
            return try await Self.receiveText(control)
        } catch {
            return nil
        }
    }

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

    private static func receiveText(_ connection: NWConnection) async throws -> String {
        var data = Data()
        while true {
            let chunk = try await receive(connection, max: 8192)
            if chunk.isEmpty { break }
            data.append(chunk)
            guard let text = String(data: data, encoding: .utf8),
                  let headerEnd = text.range(of: "\r\n\r\n") else { continue }
            if let lengthText = header("Content-Length", in: text), let expected = Int(lengthText) {
                if text[headerEnd.upperBound...].utf8.count < expected { continue }
            }
            return text
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

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

    private static func trackURL(sdp: String, describe: String, base: URL) -> String {
        let contentBase = header("Content-Base", in: describe)
            ?? (base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/")
        // "\r\n" is one Character in Swift, so split on scalars.
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
}
