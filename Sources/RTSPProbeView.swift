import SwiftUI

/// Runs the raw RTSP probe and shows its transcript.
struct RTSPProbeView: View {
    @ObservedObject var client: YiCameraClient
    @StateObject private var probe = RTSPProbe()

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            transcript
        }
        .navigationTitle("RTSP Probe")
        .navigationBarTitleDisplayMode(.inline)
        // The probe owns the camera's single RTSP session while it runs;
        // hand it back the moment it finishes, however it finished.
        .onChange(of: probe.isRunning) { running in
            if !running { client.releaseStreamSession() }
        }
        .onDisappear {
            probe.cancel()
            client.releaseStreamSession()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speaks RTSP directly — OPTIONS, DESCRIBE, SETUP, PLAY — over a Wi-Fi-pinned socket. The camera refuses interleaved TCP (461), so the probe falls back to a UDP bind, same as the viewfinder.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("The camera serves one RTSP session at a time, so this is unavailable while the viewfinder is live.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(client.streamURL.absoluteString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                if probe.isRunning {
                    Button("Stop", role: .destructive) { probe.cancel() }
                        .buttonStyle(.bordered)
                    ProgressView().padding(.leading, 8)
                } else {
                    Button("Run Probe") {
                        guard client.claimStreamSession() else { return }
                        probe.run(url: client.streamURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!client.isConnected || client.isStreamSessionHeld)
                }

                Spacer()

                if probe.packetsReceived > 0 {
                    Text("\(probe.packetsReceived) packets")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .monospacedDigit()
                }
            }

            if !client.isConnected {
                Text("Camera must be connected.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if client.isStreamSessionHeld && !probe.isRunning {
                Text("The viewfinder holds the stream session. Leave the dashboard first.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if probe.log.isEmpty {
                    Text("No output yet. Tap Run Probe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                        .padding(.top)
                } else {
                    ForEach(Array(probe.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(colour(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func colour(for line: String) -> Color {
        if line.hasPrefix("✗") { return .red }
        if line.hasPrefix("✓") { return .green }
        if line.hasPrefix("⚠︎") { return .orange }
        if line.hasPrefix("→") || line.hasPrefix("←") { return .primary }
        return .secondary
    }
}
