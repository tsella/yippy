import Foundation
import Network

enum YiCameraError: Error {
    case connectionFailed
    case sendFailed
    case receiveFailed
    case invalidResponse
    case notConnected
    case timeout
}

@MainActor
class YiCameraClient: ObservableObject {
    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var continuations: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var dataBuffer = Data()
    
    @Published var isConnected = false
    @Published var batteryLevel: Int = 100 // Default to 100% until updated
    @Published var isScanning = false
    @Published var scanLogs: [String] = []
    var token: Int = 0
    
    // ... (rest of connect, disconnect, startListening, receiveData, processBuffer remain unchanged) ...
    
    func connect() {
        let host = NWEndpoint.Host("192.168.42.1")
        let port = NWEndpoint.Port(integerLiteral: 7878)
        
        connection = NWConnection(host: host, port: port, using: .tcp)
        connection?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.startListening()
                    Task { await self.authenticate() }
                case .failed(let error), .waiting(let error):
                    print("Connection failed: \(error)")
                    self.disconnect()
                case .cancelled:
                    self.disconnect()
                default:
                    break
                }
            }
        }
        connection?.start(queue: .global())
    }
    
    func disconnect() {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        connection?.cancel()
        connection = nil
        isConnected = false
        token = 0
        batteryLevel = 100
        
        // Fail all pending continuations
        for (_, continuation) in continuations {
            continuation.resume(throwing: YiCameraError.connectionFailed)
        }
        continuations.removeAll()
    }
    
    private func startListening() {
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let data = try await receiveData()
                    self.dataBuffer.append(data)
                    self.processBuffer()
                } catch {
                    print("Receive loop ended: \(error)")
                    disconnect()
                    break
                }
            }
        }
    }
    
    private func receiveData() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = content, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: YiCameraError.connectionFailed)
                }
            }
        }
    }
    
    private func processBuffer() {
        guard let bufferString = String(data: dataBuffer, encoding: .utf8) else { return }
        
        let components = bufferString.components(separatedBy: CharacterSet.newlines)
        var unparsedData = Data()
        
        for i in 0..<components.count {
            let component = components[i]
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            if let data = trimmed.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
               let dict = jsonObject as? [String: Any] {
                
                handleIncomingDictionary(dict)
                
            } else {
                if i == components.count - 1 {
                    unparsedData.append(trimmed.data(using: .utf8) ?? Data())
                }
            }
        }
        
        self.dataBuffer = unparsedData
    }
    
    private func handleIncomingDictionary(_ dict: [String: Any]) {
        print("Received: \(dict)")
        
        if let msgId = dict["msg_id"] as? Int {
            // Resume any task waiting for this specific response
            if let continuation = continuations.removeValue(forKey: msgId) {
                continuation.resume(returning: dict)
            }
            
            // Handle specific messages globally
            switch msgId {
            case 257: // Auth token
                if let param = dict["param"] as? Int {
                    self.token = param
                    startHeartbeat()
                }
            case 7: // Async Event
                if let type = dict["type"] as? String {
                    handleAsyncEvent(type: type, param: dict["param"])
                }
            default:
                break
            }
        }
    }
    
    private func handleAsyncEvent(type: String, param: Any?) {
        switch type {
        case "battery":
            if let levelString = param as? String, let level = Int(levelString) {
                self.batteryLevel = level
            } else if let level = param as? Int {
                self.batteryLevel = level
            }
        case "start_video_record":
            print("Event: Video recording started")
        case "stop_video_record":
            print("Event: Video recording stopped")
        case "photo_taken":
            print("Event: Photo saved to SD card")
        default:
            print("Unhandled async event: \(type)")
        }
    }
    
    func sendCommand(msgId: Int, param: String? = nil, type: String? = nil, expectResponse: Bool = false) async throws -> [String: Any]? {
        guard isConnected else { throw YiCameraError.notConnected }
        
        var command: [String: Any] = [
            "msg_id": msgId,
            "token": token
        ]
        if let param = param { command["param"] = param }
        if let type = type { command["type"] = type }
        
        let data = try JSONSerialization.data(withJSONObject: command, options: [])
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection?.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }))
        }
        
        if expectResponse {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuations[msgId] = continuation
            }
        }
        return nil
    }
    
    private func authenticate() async {
        do {
            // First auth command needs token 0
            _ = try await sendCommand(msgId: 257, expectResponse: true)
            // Immediately request initial battery status
            if let response = try await sendCommand(msgId: 13, expectResponse: true) {
                if let levelStr = response["param"] as? String, let level = Int(levelStr) {
                    self.batteryLevel = level
                } else if let level = response["param"] as? Int {
                    self.batteryLevel = level
                }
            }
        } catch {
            print("Auth failed: \(error)")
        }
    }
    
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    _ = try? await sendCommand(msgId: 259)
                } catch {
                    break
                }
            }
        }
    }
    
    func takePhoto() {
        Task { _ = try? await sendCommand(msgId: 769) }
    }
    
    func startRecording() {
        Task { _ = try? await sendCommand(msgId: 513) }
    }
    
    func stopRecording() {
        Task { _ = try? await sendCommand(msgId: 514) }
    }
    
    // MARK: - API Discovery
    
    /// Scans a range of msg_ids to discover undocumented API commands.
    /// Warning: Flooding the camera with invalid commands may cause the camera's TCP server to crash or reboot.
    func scanUndocumentedCommands(range: ClosedRange<Int> = 1...2000) {
        guard !isScanning else { return }
        isScanning = true
        scanLogs = ["Starting API scan for msg_ids in range \(range)..."]
        
        Task {
            var discovered: [Int: Any] = [:]
            let knownIds = [2, 3, 7, 13, 257, 258, 259, 261, 513, 514, 769, 1281, 1282, 1283]
            
            for id in range {
                guard isConnected else {
                    let msg = "Scan aborted: Camera disconnected."
                    print(msg)
                    self.scanLogs.append(msg)
                    self.isScanning = false
                    break
                }
                
                if knownIds.contains(id) { continue }
                
                do {
                    let response = try await withTimeout(seconds: 0.5) {
                        return try await self.sendCommand(msgId: id, expectResponse: true)
                    }
                    
                    // rval: -9 usually indicates "Invalid Command", -21 and -23 indicate cmd error/nothing.
                    if let response = response, let rval = response["rval"] as? Int, rval != -9, rval != -21, rval != -23 {
                        let logMsg = "✅ Found undocumented msg_id: \(id) -> \(response)"
                        print(logMsg)
                        self.scanLogs.insert(logMsg, at: 1) // Insert at top (below the starting message)
                        discovered[id] = response
                    }
                } catch {
                    // Timeout or error; silently continue
                }
                
                // Small delay to prevent overwhelming the camera's processor
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
            
            let summary = "Scan complete. Discovered undocumented IDs: \(discovered.keys.sorted())"
            print(summary)
            self.scanLogs.append(summary)
            self.isScanning = false
        }
    }
    
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw YiCameraError.timeout
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
