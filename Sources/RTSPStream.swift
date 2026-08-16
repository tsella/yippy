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
    private var rtpListener: NWListener?
    private var rtpFlow: RTPFlow?
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
        // Finish the flow before cancelling the listener, so a reader parked
        // in next() is released rather than waiting on a dead socket.
        rtpFlow?.finish(); rtpFlow = nil
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
        //    The handler must be installed *before* the listener starts, and
        //    the listener before SETUP is sent: RTP can arrive the instant the
        //    camera processes PLAY, and a datagram that lands on a listener
        //    with no handler is dropped. ("Started without setting either new
        //    connection handler…" in the log was exactly that window.)
        let rtpPort = UInt16.random(in: 20000...40000) & ~1
        let inbound = RTPFlow()
        guard let listener = try? Self.listen(on: rtpPort, delivering: inbound) else {
            log("✗ could not bind local UDP port \(rtpPort)")
            state = .failed("Could not open a port to receive video.")
            return
        }
        self.rtpListener = listener
        self.rtpFlow = inbound
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
        await readRTP(from: inbound)
    }

    /// Runs `work`, returning nil if it does not finish within `timeout`.
    private static func withTimeout<T: Sendable>(_ timeout: Duration,
                                                 _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Binds a UDP listener that accepts RTP from whatever source port the
    /// camera chooses, delivering datagrams into `flow`.
    ///
    /// The handler is set before `start()`, because RTP can arrive as soon as
    /// the camera processes PLAY and anything landing on a handler-less
    /// listener is discarded.
    private static func listen(on port: UInt16, delivering flow: RTPFlow) throws -> NWListener {
        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .init(rawValue: port)!)
        // The framework synthesises a "connection" per inbound source and each
        // rejected one logs a NECP_CLIENT_ACTION_ADD_FLOW failure with errno 17
        // (EEXIST) — they all want this same local endpoint. It is noisy but
        // harmless: the first flow carries the stream and the rest are dropped.
        listener.newConnectionHandler = { connection in
            flow.accept(connection)
        }
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

    private func readRTP(from flow: RTPFlow) async {
        var firstPacketLogged = false
        var firstFrameLogged = false

        while !Task.isCancelled {
            // Only the *first* packet gets a deadline. Once video is flowing a
            // gap is a dropped datagram, not a dead stream.
            let datagram: Data?
            if firstPacketLogged {
                datagram = await flow.next()
            } else {
                datagram = await Self.withTimeout(.seconds(10)) { await flow.next() }
                guard datagram != nil else {
                    log("✗ no RTP arrived within 10s — the camera never sent to our port")
                    state = .failed("The camera accepted the stream but sent no video.")
                    return
                }
            }
            guard let datagram, !datagram.isEmpty else {
                if datagram == nil { break }   // flow closed
                continue
            }

            if !firstPacketLogged {
                firstPacketLogged = true
                log("✓ first RTP packet (\(datagram.count) bytes) from \(flow.endpointDescription)")
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

    /// Receives RTP datagrams from a UDP listener.
    ///
    /// `NWListener` is how Network.framework delivers UDP: the first datagram
    /// from a given host/port pair arrives as a "new connection", and the rest
    /// of that flow is read from it. Two things this gets right that the
    /// previous attempt did not:
    ///
    ///  - **It buffers from the moment the flow is accepted**, so packets that
    ///    arrive before anyone is awaiting them are queued rather than lost.
    ///  - **It uses `receiveMessage`**, which delivers one whole datagram.
    ///    `receive(minimumIncompleteLength:maximumLength:)` is a stream API and
    ///    does not reliably deliver datagrams.
    final class RTPFlow: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: NWConnection?
        private var queued: [Data] = []
        private var waiter: CheckedContinuation<Data?, Never>?
        private var finished = false

        /// Bounded so a stalled consumer cannot grow this without limit; RTP is
        /// realtime, and stale frames are worth less than the memory they cost.
        private static let maxQueued = 512

        var endpointDescription: String {
            lock.lock(); defer { lock.unlock() }
            return connection.map { "\($0.endpoint)" } ?? "unknown"
        }

        /// Takes the first flow and starts reading it. Later flows are dropped:
        /// RTP for one session comes from one source.
        func accept(_ connection: NWConnection) {
            lock.lock()
            guard self.connection == nil, !finished else {
                lock.unlock()
                connection.cancel()
                return
            }
            self.connection = connection
            lock.unlock()

            connection.start(queue: .global(qos: .userInitiated))
            read(from: connection)
        }

        private func read(from connection: NWConnection) {
            connection.receiveMessage { [weak self] content, _, _, error in
                guard let self else { return }
                if let content, !content.isEmpty {
                    self.deliver(content)
                }
                guard error == nil else {
                    self.finish()
                    return
                }
                self.read(from: connection)
            }
        }

        private func deliver(_ datagram: Data) {
            lock.lock()
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: datagram)
                return
            }
            if queued.count < Self.maxQueued { queued.append(datagram) }
            lock.unlock()
        }

        /// The next datagram, waiting if none has arrived yet.
        func next() async -> Data? {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                lock.lock()
                if !queued.isEmpty {
                    let datagram = queued.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: datagram)
                    return
                }
                if finished {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        }

        func finish() {
            lock.lock()
            guard !finished else { return lock.unlock() }
            finished = true
            let pending = waiter
            waiter = nil
            let connection = self.connection
            lock.unlock()
            pending?.resume(returning: nil)
            connection?.cancel()
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
