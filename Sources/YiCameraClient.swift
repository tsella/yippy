import Foundation
import Network

enum YiCameraError: LocalizedError {
    case connectionFailed
    case notConnected
    case timeout
    /// The camera answered, but with a non-zero `rval`.
    case commandFailed(msgId: Int, rval: Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Connection to the camera failed."
        case .notConnected:     return "Not connected to the camera."
        case .timeout:          return "The camera did not respond in time."
        case .commandFailed(let msgId, let rval):
            return "\(YiCommand.describe(msgId)) failed: \(YiReturnCode.message(for: rval, msgId: msgId))"
        }
    }
}

/// A user-facing banner message.
struct YiBanner: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

@MainActor
class YiCameraClient: ObservableObject {

    // MARK: Configuration

    /// The camera's fixed address. Shared so nothing dials a second copy of it.
    nonisolated static let host = "192.168.42.1"
    nonisolated static let controlPort: UInt16 = 7878

    /// Parameters for any connection to the camera.
    ///
    /// The Wi-Fi pin is mandatory: the camera's network has no internet, so
    /// iOS would otherwise route over cellular and fail with EADDRNOTAVAIL.
    /// Shared so that rule is enforced in one place.
    nonisolated static func controlParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        return parameters
    }

    nonisolated static func controlEndpoint() -> (host: NWEndpoint.Host, port: NWEndpoint.Port) {
        (NWEndpoint.Host(host), NWEndpoint.Port(rawValue: controlPort)!)
    }

    /// The camera drops idle sessions after ~20 minutes. Poll well inside that.
    private nonisolated static let heartbeatInterval: Duration = .seconds(5)
    /// How long to wait for a response before giving up on a request.
    /// `nonisolated` so it can be used as a default argument, which is
    /// evaluated at the call site outside the actor.
    nonisolated static let requestTimeout: Duration = .seconds(5)

    // MARK: Published state

    @Published private(set) var isConnected = false
    @Published private(set) var batteryLevel: Int = 100
    @Published private(set) var isCharging = false
    /// Driven by camera notifications, not by optimistic UI toggles, so it stays
    /// truthful when recording is started from the physical shutter button.
    @Published private(set) var isRecording = false
    @Published private(set) var isScanning = false
    /// Set while a long-running operation (e.g. FORMAT) occupies the camera.
    /// The card reports busy for several seconds after FORMAT returns rval 0.
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage: String?
    /// True once the camera's RTSP server has been started (msg_id 259).
    /// The player should not attempt to connect before this.
    @Published private(set) var isViewfinderActive = false
    /// Whether this app has asked for the stream. Distinguishes "the camera
    /// never started it" from "the camera stopped it", which `vf_stop` alone
    /// cannot — the camera sends one spontaneously on connect.
    private var viewfinderRequested = false

    /// True between `start_photo_capture` and the capture finishing.
    ///
    /// The camera is single-threaded while it writes a photo: sending another
    /// command in that window wedges its TCP server, after which *every*
    /// request times out until the camera is power-cycled. Observed on real
    /// hardware — a RECORD_START issued during a capture killed the session.
    @Published private(set) var isCapturing = false
    /// Fails the capture open if the camera never reports completion, so a
    /// missed notification cannot lock the UI out permanently.
    private var captureWatchdog: Task<Void, Never>?
    /// Requests parked until the capture completes.
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []
    /// Advertised by the START_SESSION response; falls back to the documented
    /// default if the firmware does not report one.
    @Published private(set) var streamURL = URL(string: "rtsp://192.168.42.1/live")!

    /// Identifies *which* camera this is, so caches can be kept per device.
    ///
    /// Prefers the serial number and falls back to model+firmware. Filenames
    /// restart at YDXJ0001 on every card, so a cache keyed by filename alone
    /// would serve one camera's thumbnails for another's files.
    @Published private(set) var cameraID: String = "unknown-camera"

    /// Incremented whenever the camera reports that new media was written.
    /// Views observe this to refresh without polling — the camera pushes
    /// `photo_taken` / `video_record_complete` notifications on capture.
    @Published private(set) var mediaChangeCount = 0
    /// Path reported alongside the most recent `photo_taken`, when the firmware
    /// includes one.
    @Published private(set) var lastCapturedPath: String?
    @Published private(set) var scanLogs: [String] = []
    @Published var activeBanner: YiBanner?

    private(set) var token: Int = 0

    // MARK: Private state

    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    /// Outstanding requests. Keyed by a unique sequence number rather than by
    /// `msg_id`, so two concurrent commands sharing an id cannot displace each
    /// other. Responses carry only `msg_id`, so requests are matched to the
    /// oldest pending waiter for that id (the camera answers in order).
    private var pending: [Int: PendingRequest] = [:]
    private var nextRequestID = 0
    private var dataBuffer = Data()

    private struct PendingRequest {
        let msgId: Int
        let continuation: CheckedContinuation<[String: Any], Error>
    }

    // MARK: - Connection lifecycle

    func connect() {
        guard connection == nil else { return }

        let parameters = Self.controlParameters()
        // Control messages are small and latency-sensitive.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let endpoint = Self.controlEndpoint()
        let connection = NWConnection(host: endpoint.host, port: endpoint.port, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.startListening()
                    await self.authenticate()
                case .failed(let error):
                    self.teardown(reason: "Connection failed: \(error.localizedDescription)")
                case .cancelled:
                    self.teardown(reason: nil)
                case .waiting(let error):
                    // Transient (e.g. Wi-Fi still associating). NWConnection
                    // retries on its own, so don't tear the session down here.
                    print("Connection waiting: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    func disconnect() {
        guard isConnected, token != 0 else {
            teardown(reason: nil)
            return
        }
        // Shut the stream and session down politely before dropping the socket,
        // so the camera releases the token and stops the RTSP server. Tearing
        // down first would cancel the connection before these could be written.
        Task {
            await stopViewfinder()
            _ = try? await send(.stopSession)
            teardown(reason: nil)
        }
    }

    private func teardown(reason: String?) {
        receiveTask?.cancel();   receiveTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        scanTask?.cancel();      scanTask = nil

        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        isConnected = false
        isRecording = false
        isScanning = false
        isViewfinderActive = false
        viewfinderRequested = false
        // Release the capture gate, or requests parked behind it would hang
        // forever after a disconnect instead of failing with notConnected.
        endCapture()
        token = 0
        dataBuffer.removeAll()

        failAllPending(with: YiCameraError.connectionFailed)

        if let reason {
            print(reason)
            showBanner(reason, isError: true)
        }
    }

    private func failAllPending(with error: Error) {
        let waiters = pending.values
        pending.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    // MARK: - Receive path

    private func startListening() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let data = try await self.receiveChunk()
                    self.dataBuffer.append(data)
                    self.processBuffer()
                } catch {
                    if !Task.isCancelled {
                        self.teardown(reason: "Connection lost: \(error.localizedDescription)")
                    }
                    return
                }
            }
        }
    }

    private func receiveChunk() async throws -> Data {
        guard let connection else { throw YiCameraError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(throwing: YiCameraError.connectionFailed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Splits the buffer on newlines and decodes each complete JSON object.
    ///
    /// Some firmwares omit the trailing newline, so a trailing fragment that
    /// parses as complete JSON is consumed too; anything else is retained until
    /// more bytes arrive.
    private func processBuffer() {
        while let newlineIndex = dataBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = dataBuffer[dataBuffer.startIndex..<newlineIndex]
            dataBuffer = dataBuffer[dataBuffer.index(after: newlineIndex)...]
            decode(line)
        }

        // No newline arrived: the camera may have omitted it. Accept the
        // remainder only if it is already valid JSON.
        if !dataBuffer.isEmpty, decode(dataBuffer) {
            dataBuffer.removeAll()
        }

        // Guard against a desynchronised stream growing without bound.
        if dataBuffer.count > 1 << 20 {
            print("Discarding oversized receive buffer (\(dataBuffer.count) bytes)")
            dataBuffer.removeAll()
        }
    }

    @discardableResult
    private func decode<D: DataProtocol>(_ bytes: D) -> Bool {
        let data = Data(bytes)
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return false }
        handle(dict)
        return true
    }

    private func handle(_ dict: [String: Any]) {
        guard let msgId = dict["msg_id"] as? Int else { return }

        // Notifications are camera-initiated and have no waiting request. They
        // must never be matched against `pending`, or they will resolve an
        // unrelated command with the wrong payload.
        if msgId == YiCommand.notification.rawValue {
            if let type = dict["type"] as? String {
                handleNotification(type: type, param: dict["param"])
            }
            return
        }

        if let rval = dict["rval"] as? Int, rval != YiReturnCode.success {
            print("← \(YiCommand.describe(msgId)) \(YiReturnCode.describe(rval, msgId: msgId))")
        } else {
            print("← \(YiCommand.describe(msgId)) ok")
        }

        // Resolve the oldest waiter for this msg_id.
        if let key = pending
            .filter({ $0.value.msgId == msgId })
            .min(by: { $0.key < $1.key })?.key,
           let waiter = pending.removeValue(forKey: key) {
            waiter.continuation.resume(returning: dict)
        }

        // Session token arrives on the START_SESSION reply.
        if msgId == YiCommand.startSession.rawValue, let param = dict["param"] as? Int {
            token = param
            startHeartbeat()
        }
    }

    private func handleNotification(type: String, param: Any?) {
        guard let event = YiNotification(rawValue: type) else {
            print("← NOTIFICATION (unhandled): \(type)")
            return
        }
        print("← NOTIFICATION: \(type)")

        switch event {
        case .battery, .batteryStatus:
            if let level = Self.intValue(param) { batteryLevel = level }
        case .adapterStatus:
            if let state = param as? String { isCharging = (state == "1" || state == "connect") }
        case .startVideoRecord, .switchToRecMode:
            isRecording = true
        case .stopVideoRecord:
            isRecording = false
        case .videoRecordComplete:
            isRecording = false
            // The file is only on the card once recording completes.
            mediaChangeCount += 1
        case .startPhotoCapture:
            // The camera is busy writing until it reports completion.
            beginCapture()
        case .preciseCaptureDataReady:
            // NOT a completion signal — the data exists but the camera is
            // still writing it. Observed on hardware: treating this as "done"
            // let the next command through and wedged the TCP server. Hold the
            // gate and let photo_taken, or the watchdog, release it.
            break
        case .photoTaken:
            // `param` carries the path of the saved file on most firmwares.
            if let path = param as? String { lastCapturedPath = path }
            endCapture()
            mediaChangeCount += 1
        case .viewfinderStart:
            isViewfinderActive = true
        case .viewfinderStop:
            // Only honour vf_stop if we actually asked for the stream. The
            // camera emits vf_stop spontaneously right after connect, before
            // 259 is ever sent; treating that as authoritative would race with
            // startViewfinder() and leave the player permanently unmounted.
            if !viewfinderRequested {
                print("Ignoring vf_stop — no viewfinder requested yet")
                return
            }
            isViewfinderActive = false
        default:
            break
        }

        if let message = event.userFacingMessage {
            showBanner(message, isError: event.isError)
        }
    }

    /// Firmware builds disagree on whether numbers arrive as `Int` or `String`.
    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    // MARK: - Banners

    func showBanner(_ message: String, isError: Bool) {
        bannerDismissTask?.cancel()
        activeBanner = YiBanner(message: message, isError: isError)
        let shown = activeBanner
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.activeBanner == shown else { return }
            self.activeBanner = nil
        }
    }

    // MARK: - Send path

    /// Sends a command and waits for the matching response.
    /// - Throws: `YiCameraError.commandFailed` when the camera reports a non-zero `rval`.
    @discardableResult
    func send(_ command: YiCommand, param: String? = nil, type: String? = nil) async throws -> [String: Any] {
        try await send(msgId: command.rawValue, param: param, type: type)
    }

    @discardableResult
    func send(msgId: Int, param: String? = nil, type: String? = nil,
              timeout: Duration = YiCameraClient.requestTimeout) async throws -> [String: Any] {
        let response = try await sendRaw(msgId: msgId, param: param, type: type, timeout: timeout)
        let rval = response.rval
        guard rval == YiReturnCode.success else {
            throw YiCameraError.commandFailed(msgId: msgId, rval: rval)
        }
        return response
    }

    /// Sends a command and returns the raw response without validating `rval`.
    /// Used where a non-zero `rval` is expected and meaningful (listing an empty
    /// SD card, probing unknown ids).
    func sendRaw(msgId: Int, param: String? = nil, type: String? = nil,
                 timeout: Duration = YiCameraClient.requestTimeout) async throws -> [String: Any] {
        // Wait out an in-flight capture rather than relying on every caller to
        // check `isCapturing`. The camera is single-threaded while writing a
        // photo, and one command sent in that window wedges its TCP server for
        // the rest of the session — so this has to hold for the gallery
        // refresh and the heartbeat too, not just the shutter.
        await awaitCaptureCompletion()

        guard isConnected, let connection else { throw YiCameraError.notConnected }

        var message: [String: Any] = ["msg_id": msgId]
        // START_SESSION is the one command that must carry token 0.
        message["token"] = (msgId == YiCommand.startSession.rawValue) ? 0 : token
        if let param { message["param"] = param }
        if let type { message["type"] = type }

        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A) // Ambarella requires a newline terminator.

        let requestID = nextRequestID
        nextRequestID += 1

        print("→ \(YiCommand.describe(msgId))\(param.map { " param=\($0)" } ?? "")")

        // Write first. `connection.send` hands off to the transport queue, and
        // the reply can only be observed by the receive loop, which is also
        // MainActor-isolated — so it cannot be processed until this method
        // suspends below. That makes registering after the write race-free.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }

        // Fail the request if the camera never answers, rather than leaking a
        // continuation that is never resumed.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resumePending(requestID, throwing: YiCameraError.timeout)
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = PendingRequest(msgId: msgId, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumePending(requestID, throwing: CancellationError())
            }
        }
    }

    private func resumePending(_ requestID: Int, throwing error: Error) {
        guard let waiter = pending.removeValue(forKey: requestID) else { return }
        waiter.continuation.resume(throwing: error)
    }

    // MARK: - Session

    private func authenticate() async {
        do {
            let session = try await send(.startSession)
            // The session response advertises the stream URL; prefer it over a
            // hardcoded guess in case the firmware serves a different path.
            if let advertised = session["rtsp"] as? String, let url = URL(string: advertised) {
                streamURL = url
            }
            try await refreshBatteryLevel()
            await identifyCamera()
            // Must be granted before the viewfinder starts, or live555 cannot
            // resolve a source address for the RTP stream.
            requestLocalNetworkPermission()

            // The camera has no battery-backed RTC, so its clock drifts or
            // resets entirely. Sync it before anything is captured this
            // session, so filenames and timestamps are correct.
            if Self.syncClockOnConnect {
                await syncClock()
            }

            // The RTSP server is not running until the viewfinder is started.
            await startViewfinder()
        } catch {
            print("Authentication failed: \(error.localizedDescription)")
            showBanner("Camera handshake failed", isError: true)
        }
    }

    /// Resolves the `logo` field of a GET_DEVICE_INFO response to a fetchable
    /// URL, if the firmware reports one.
    ///
    /// The field is undocumented and its shape varies, so all three plausible
    /// forms are accepted: an absolute http(s) URL, a camera-side absolute
    /// path under the SD card mount, or a bare filename served from the
    /// camera's HTTP root.
    nonisolated static func logoURLCandidates(from info: [String: Any]) -> [URL] {
        guard let raw = info["logo"].map({ "\($0)" })?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "0", raw.lowercased() != "null" else { return [] }

        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw).map { [$0] } ?? []
        }

        // The logo lives on the camera's internal flash (`/tmp/fuse_z/`), not
        // the SD card mount that media is served from — and how the HTTP server
        // exposes it is undocumented. Try the plausible mappings in order:
        // stripped of any `/tmp/fuse_X/` mount prefix (matching how media
        // paths are served from the root), then the bare filename, then the
        // full path verbatim.
        var paths: [String] = []
        if let range = raw.range(of: #"^/tmp/fuse_[a-z]/"#, options: [.regularExpression, .caseInsensitive]) {
            paths.append(String(raw[range.upperBound...]))
        }
        paths.append((raw as NSString).lastPathComponent)
        paths.append(String(raw.drop { $0 == "/" }))

        var seen = Set<String>()
        return paths.compactMap { path in
            guard !path.isEmpty, seen.insert(path).inserted else { return nil }
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return URL(string: "http://\(host)/\(escaped)")
        }
    }

    /// Derives a stable per-device identifier from GET_DEVICE_INFO.
    ///
    /// Best-effort: a camera that reports nothing usable keeps the default, so
    /// caching still works — it just cannot be told apart from another
    /// equally anonymous camera.
    private func identifyCamera() async {
        guard let info = try? await send(.getDeviceInfo) else { return }

        // Serial number first; it is the only genuinely unique field.
        for key in ["sn", "serial_number", "serialno"] {
            if let value = info[key].map({ "\($0)" }),
               !value.isEmpty, value != "0" {
                cameraID = sanitised(value)
                return
            }
        }

        // Otherwise model + firmware. Not unique across two identical cameras,
        // but better than lumping different models together.
        let fallback = ["brand", "model", "fw_ver"]
            .compactMap { info[$0].map { "\($0)" } }
            .filter { !$0.isEmpty }
        if !fallback.isEmpty {
            cameraID = sanitised(fallback.joined(separator: "-"))
        }
    }

    /// Keeps the id safe for use as a filename component.
    private func sanitised(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).prefix(64).description
    }

    /// Provokes iOS's Local Network permission prompt.
    ///
    /// A plain `NWConnection` to a literal IP does not reliably trigger it, but
    /// VLC's live555 needs the permission *granted* to enumerate local
    /// interfaces and choose an RTP source address — without it the stream
    /// fails with "invalid IP address: 0.0.0.0" while the control socket to the
    /// same host works. Browsing for a Bonjour service is the documented way to
    /// raise the prompt; the browser is discarded immediately, since only the
    /// permission matters, not the result.
    private func requestLocalNetworkPermission() {
        let browser = NWBrowser(
            for: .bonjour(type: "_rtsp._tcp", domain: nil),
            using: .init()
        )
        browser.start(queue: .global(qos: .utility))
        Task {
            try? await Task.sleep(for: .seconds(2))
            browser.cancel()
        }
    }

    /// Starts the camera's RTSP server (AMBA_BOSS_RESETVF).
    ///
    /// The stream at `rtsp://192.168.42.1/live` does not exist until this is
    /// sent — without it the camera emits `vf_stop` and VLC fails to bind,
    /// reporting "invalid IP address: 0.0.0.0".
    ///
    /// The wire format is exactly `{"msg_id":259,"param":"none_force","token":N}`.
    /// A packet capture of the official app carries **no `type` field**, and the
    /// one working reference implementation omits it too — sending
    /// `type:"app_status"` is rejected by some firmwares.
    func startViewfinder() async {
        do {
            viewfinderRequested = true
            _ = try await send(.startViewfinder, param: "none_force")
            isViewfinderActive = true
        } catch {
            print("Could not start viewfinder: \(error.localizedDescription)")
            isViewfinderActive = false
            showBanner("Could not start the video stream", isError: true)
        }
    }

    /// Stops and restarts the stream. `260` then `259` resets the camera's RTSP
    /// server, which is the documented recovery when the viewfinder wedges.
    func restartViewfinder() async {
        isViewfinderActive = false
        _ = try? await send(.stopViewfinder)
        try? await Task.sleep(for: .milliseconds(500))
        await startViewfinder()
    }

    /// Stops the RTSP server. Also re-enables the physical shutter button on
    /// some firmwares, which `startViewfinder` disables.
    func stopViewfinder() async {
        _ = try? await send(.stopViewfinder)
        viewfinderRequested = false
        isViewfinderActive = false
    }

    // MARK: - Camera settings

    /// All current settings (AMBA_GET_ALL_CURRENT_SETTINGS, 3).
    ///
    /// The reply nests each key/value in its own single-entry dictionary inside
    /// a `param` array, e.g. `{"param":[{"video_resolution":"1920x1080 60P 16:9"}]}`.
    func allSettings() async -> [String: String] {
        guard let response = try? await sendRaw(msgId: YiCommand.getAllSettings.rawValue,
                                                timeout: .seconds(10)) else { return [:] }
        guard response.succeeded else { return [:] }

        var result: [String: String] = [:]
        if let entries = response["param"] as? [[String: Any]] {
            for entry in entries {
                for (key, value) in entry { result[key] = "\(value)" }
            }
        } else if let flat = response["param"] as? [String: Any] {
            // Some firmwares return a plain dictionary instead.
            for (key, value) in flat { result[key] = "\(value)" }
        }
        return result
    }

    /// Valid values for a setting (AMBA_GET_SINGLE_SETTING_OPTIONS, 9).
    ///
    /// Asking the camera avoids hardcoding a table that differs per firmware.
    func settingOptions(for key: String) async -> [String] {
        guard let response = try? await sendRaw(msgId: YiCommand.getSettingOptions.rawValue,
                                                param: key, timeout: .seconds(10)) else { return [] }
        guard response.succeeded else { return [] }

        if let options = response["param"] as? [String] { return options }
        if let options = response["options"] as? [String] { return options }
        // Occasionally wrapped one-per-dictionary like the settings listing.
        if let entries = response["param"] as? [[String: Any]] {
            return entries.compactMap { $0.values.first.map { "\($0)" } }
        }
        return []
    }

    /// Changes a setting (AMBA_SET_SETTING, 2). Throws on a non-zero `rval`.
    func setSetting(_ key: String, to value: String) async throws {
        _ = try await send(.setSetting, param: value, type: key)
    }

    /// Reads one setting (AMBA_GET_SETTING, 1).
    ///
    /// Cheaper than `allSettings()` when verifying a single value — the camera
    /// otherwise returns its entire settings table over a slow link.
    func setting(_ key: String) async -> String? {
        guard let response = try? await sendRaw(msgId: YiCommand.getSetting.rawValue, type: key),
              response.rval == YiReturnCode.success,
              let value = response["param"] else { return nil }
        return "\(value)"
    }

    /// Whether to set the camera's clock on connect.
    ///
    /// The key and its default live here, with the behaviour they control,
    /// rather than being restated in both the view and `authenticate()`.
    nonisolated static let syncClockDefaultsKey = "syncClockOnConnect"

    nonisolated static var syncClockOnConnect: Bool {
        UserDefaults.standard.object(forKey: syncClockDefaultsKey) as? Bool ?? true
    }

    /// Formats a date the way the camera's `camera_clock` setting expects.
    /// The camera has no timezone concept, so this is local wall-clock time.
    nonisolated static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// Sets the camera's clock from the phone.
    ///
    /// The camera has no battery-backed RTC, so it loses the time whenever the
    /// battery is pulled — leaving every media timestamp wrong. Syncing on
    /// connect is what the official app does, and it is the only way listings
    /// and EXIF dates end up meaningful.
    @discardableResult
    func syncClock(to date: Date = Date()) async -> Bool {
        let value = Self.clockFormatter.string(from: date)
        do {
            try await setSetting("camera_clock", to: value)
            print("Camera clock set to \(value)")
            return true
        } catch {
            print("Could not set camera clock: \(error.localizedDescription)")
            return false
        }
    }

    /// Reads the camera's current clock, if it reports one.
    func cameraClock() async -> Date? {
        guard let response = try? await sendRaw(msgId: YiCommand.getSetting.rawValue,
                                                type: "camera_clock"),
              response.succeeded,
              let value = response["param"] as? String else { return nil }
        return Self.clockFormatter.date(from: value)
    }

    /// Reads total/free card space via AMBA_GET_SPACE (5).
    ///
    /// This distinguishes the two failure modes that both surface as `-26`:
    /// a card the camera can mount but which has no `DCIM` directory, versus a
    /// card it cannot mount at all. The latter reports zero (or errors) here,
    /// and no amount of on-camera formatting will fix it — `FORMAT` operates on
    /// the mounted volume `D:`, so an unmountable card leaves it nothing to act
    /// on. That needs repartitioning on a computer.
    func cardSpace() async -> (total: Int64, free: Int64)? {
        async let totalResponse = try? sendRaw(msgId: YiCommand.getSpace.rawValue, type: "total")
        async let freeResponse = try? sendRaw(msgId: YiCommand.getSpace.rawValue, type: "free")

        guard let total = await totalResponse, let free = await freeResponse else { return nil }
        guard total.succeeded, free.succeeded else { return nil }

        return (Int64(Self.intValue(total["param"]) ?? 0),
                Int64(Self.intValue(free["param"]) ?? 0))
    }

    func refreshBatteryLevel() async throws {
        let response = try await send(.getBatteryLevel)
        if let level = Self.intValue(response["param"]) { batteryLevel = level }
        if let type = response["type"] as? String { isCharging = (type == "adapter") }
    }

    /// Keeps the session alive. Uses GET_BATTERY_LEVEL (13), a cheap read.
    ///
    /// Note: msg_id 259 is AMBA_BOSS_RESETVF — it restarts the RTSP viewfinder
    /// and must not be used as a ping.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self, self.isConnected else { return }
                // Don't contend with an in-flight scan, a long operation like
                // FORMAT, or a capture. The camera is single-threaded while
                // writing a photo, and a command sent in that window wedges its
                // TCP server for the rest of the session.
                guard !self.isScanning, !self.isBusy, !self.isCapturing else { continue }
                do {
                    try await self.refreshBatteryLevel()
                } catch is CancellationError {
                    return
                } catch {
                    print("Heartbeat failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Capture gating

    private func beginCapture() {
        isCapturing = true
        captureWatchdog?.cancel()
        captureWatchdog = Task { [weak self] in
            // The camera does not always report completion. Without this the
            // shutter would stay disabled for the rest of the session.
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            // Release the gate and anything parked behind it, so a firmware
            // that never reports completion cannot stall the app.
            self?.endCapture()
        }
    }

    private func endCapture() {
        captureWatchdog?.cancel()
        captureWatchdog = nil
        isCapturing = false
        // Release anything that queued behind the capture.
        let waiting = captureWaiters
        captureWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    /// Suspends until any in-flight capture finishes.
    private func awaitCaptureCompletion() async {
        guard isCapturing else { return }
        await withCheckedContinuation { captureWaiters.append($0) }
    }

    // MARK: - Camera actions

    func takePhoto() {
        guard !isCapturing else { return }
        perform(.takePhoto, failureMessage: "Could not take photo")
    }

    func startRecording() {
        guard !isCapturing else { return }
        perform(.recordStart, failureMessage: "Could not start recording") { [weak self] in
            self?.isRecording = true
        }
    }

    func stopRecording() {
        perform(.recordStop, failureMessage: "Could not stop recording") { [weak self] in
            self?.isRecording = false
        }
    }

    func powerOff() {
        perform(.cameraOff, failureMessage: "Could not power off camera")
    }

    /// Formats the SD card.
    ///
    /// FORMAT returns `rval: 0` as soon as the request is accepted, not when the
    /// card is ready — it stays busy (`-27`) for several seconds afterwards. So
    /// this polls until the card responds again, then confirms the format
    /// actually took by checking that the media directory exists.
    func formatSDCard() {
        guard !isBusy else { return }
        Task {
            isBusy = true
            busyMessage = "Formatting SD card…"
            defer { isBusy = false; busyMessage = nil }

            // FORMAT acts on the mounted volume "D:". If the camera cannot see
            // any capacity, the card is not mounted and formatting cannot
            // possibly work — say so rather than issuing a command that will
            // report success and change nothing.
            if let space = await cardSpace(), space.total == 0 {
                showBanner("Camera reports 0 GB — the card is not mounted. It must be repartitioned on a computer; on-camera formatting cannot fix this.",
                           isError: true)
                return
            }

            do {
                _ = try await send(.formatCard, param: "D:")
            } catch {
                showBanner((error as? YiCameraError)?.errorDescription
                           ?? "Could not format SD card", isError: true)
                return
            }

            // Wait for the card to come back. Bounded so a dead card cannot
            // hang the UI indefinitely.
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(2))
                guard isConnected else { return }
                if (try? await send(.getBatteryLevel)) != nil { break }
            }

            // A successful format recreates DCIM/100MEDIA. If it is still
            // missing, the card is not writable and the format silently failed.
            let listing = try? await sendRaw(
                msgId: YiCommand.listDirectory.rawValue,
                param: "-D -S \(YiFileManager.mediaDirectory)",
                timeout: .seconds(15)
            )
            let rval = listing?["rval"] as? Int

            if rval == YiReturnCode.success {
                showBanner("SD card formatted", isError: false)
            } else {
                showBanner("Format did not complete — the card may be write-protected or faulty.",
                           isError: true)
            }
        }
    }

    /// Runs a command, surfacing any failure to the user instead of swallowing it.
    private func perform(_ command: YiCommand, param: String? = nil,
                         failureMessage: String, onSuccess: (() -> Void)? = nil) {
        Task {
            do {
                _ = try await send(command, param: param)
                onSuccess?()
            } catch {
                print("\(command.name) failed: \(error.localizedDescription)")
                showBanner(
                    (error as? YiCameraError)?.errorDescription ?? failureMessage,
                    isError: true
                )
            }
        }
    }

    // MARK: - API discovery

    /// Probes a range of `msg_id`s to find undocumented commands.
    ///
    /// - Warning: Unknown commands can hang or reboot the camera's TCP server.
    ///   This is a debug-only tool.
    func scanUndocumentedCommands(range: ClosedRange<Int>) {
        guard !isScanning else { return }
        isScanning = true
        scanLogs = ["Scanning msg_id \(range.lowerBound)–\(range.upperBound)…"]

        scanTask = Task { [weak self] in
            guard let self else { return }
            var discovered: [Int] = []
            let known = Set(YiCommand.allCases.map(\.rawValue))

            for id in range where !known.contains(id) {
                if Task.isCancelled { break }
                guard isConnected else {
                    scanLogs.append("Scan aborted: camera disconnected.")
                    break
                }

                do {
                    let response = try await sendRaw(msgId: id, timeout: .milliseconds(500))
                    let rval = response.rval
                    if !YiReturnCode.isUnsupportedCommand(rval) {
                        discovered.append(id)
                        scanLogs.insert("✅ \(id) → \(YiReturnCode.describe(rval, msgId: id)) \(response)", at: 1)
                    }
                } catch {
                    // Timeout or transport error: treat as not implemented.
                }

                try? await Task.sleep(for: .milliseconds(100)) // Don't flood the camera.
            }

            scanLogs.append(discovered.isEmpty
                ? "Scan complete. No undocumented ids responded."
                : "Scan complete. Found: \(discovered.sorted())")
            isScanning = false
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanLogs.append("Scan cancelled.")
    }
}
