import SwiftUI

struct DebugScannerView: View {
    @ObservedObject var client: YiCameraClient
    
    var body: some View {
        VStack {
            HStack {
                Text("API Scanner")
                    .font(.title2.bold())
                Spacer()
                
                if client.isScanning {
                    ProgressView()
                        .padding(.trailing, 8)
                }
                
                Button(action: {
                    if client.isScanning {
                        // For a real app, you might want to add a cancel mechanism.
                        // For now, it will just run to completion or disconnect.
                    } else {
                        client.scanUndocumentedCommands(range: 1...500)
                    }
                }) {
                    Text(client.isScanning ? "Scanning..." : "Start Scan")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(client.isScanning || !client.isConnected)
            }
            .padding()
            
            if !client.isConnected {
                Text("Camera must be connected to run the scanner.")
                    .foregroundColor(.orange)
                    .font(.caption)
                    .padding(.bottom)
            }
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if client.scanLogs.isEmpty {
                            Text("No logs yet. Tap Start Scan to search for undocumented JSON commands.")
                                .foregroundColor(.secondary)
                                .italic()
                        } else {
                            ForEach(client.scanLogs.indices, id: \.self) { index in
                                Text(client.scanLogs[index])
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(8)
                                    .id(index)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: client.scanLogs.count) { _ in
                    if !client.scanLogs.isEmpty {
                        withAnimation {
                            // Auto-scroll to the latest log (which is at the top usually except the summary, or bottom depending on how we insert)
                            // We insert discoveries at index 1, so top is fine.
                        }
                    }
                }
            }
        }
        .navigationTitle("Debug Scanner")
    }
}
