import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: YiCameraClient
    @State private var deviceInfo: [String: String] = [:]
    @State private var isLoading = false
    
    var body: some View {
        Form {
            Section(header: Text("Device Information")) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Fetching...")
                        Spacer()
                    }
                } else if deviceInfo.isEmpty {
                    Text("No device information available.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(deviceInfo.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack {
                            Text(key.capitalized)
                                .fontWeight(.medium)
                            Spacer()
                            Text(value)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            Section(header: Text("Advanced Controls")) {
                Toggle("HTTP Server", isOn: Binding(
                    get: {
                        deviceInfo["HTTP Server"]?.lowercased() == "enable"
                    },
                    set: { newValue in
                        let paramString = newValue ? "enable" : "disable"
                        // Optimistically update the UI
                        deviceInfo["HTTP Server"] = paramString
                        
                        Task {
                            do {
                                // msg_id: 2 is the standard Ambarella/Yi command to change a setting.
                                _ = try await client.sendCommand(msgId: 2, param: paramString, type: "http", expectResponse: true)
                                // Refresh to ensure it actually took effect
                                fetchDeviceInfo()
                            } catch {
                                print("Failed to toggle HTTP server: \(error)")
                            }
                        }
                    }
                ))
            }
            
            Section {
                Button(role: .destructive, action: {
                    client.disconnect()
                }) {
                    HStack {
                        Spacer()
                        Text("Disconnect Camera")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            fetchDeviceInfo()
        }
    }
    
    private func fetchDeviceInfo() {
        guard client.isConnected else { return }
        isLoading = true
        
        Task {
            do {
                if let response = try await client.sendCommand(msgId: 11, expectResponse: true) {
                    var parsedInfo: [String: String] = [:]
                    
                    let keyMapping: [String: String] = [
                        "fw_ver": "Firmware Version",
                        "api_ver": "API Version",
                        "app_type": "App Type",
                        "model": "Model",
                        "brand": "Brand",
                        "chip": "Chipset",
                        "http": "HTTP Server"
                    ]
                    
                    for (key, value) in response {
                        // Skip internal/boilerplate fields
                        if key == "msg_id" || key == "rval" || key == "logo" { continue }
                        
                        let friendlyKey = keyMapping[key] ?? key.capitalized.replacingOccurrences(of: "_", with: " ")
                        parsedInfo[friendlyKey] = "\(value)"
                    }
                    
                    self.deviceInfo = parsedInfo
                }
            } catch {
                print("Failed to fetch device info: \(error)")
            }
            self.isLoading = false
        }
    }
}
