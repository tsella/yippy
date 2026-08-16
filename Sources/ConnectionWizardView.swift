import SwiftUI

struct ConnectionWizardView: View {
    @ObservedObject var client: YiCameraClient
    @StateObject private var reachability = CameraReachability()
    @State private var isAnimating = false

    private var canConnect: Bool { reachability.isReachable }

    private var buttonBackground: some ShapeStyle {
        if client.isConnected {
            return AnyShapeStyle(LinearGradient(colors: [.green, .mint],
                                                startPoint: .leading, endPoint: .trailing))
        }
        if canConnect {
            return AnyShapeStyle(LinearGradient(colors: [.blue, .cyan],
                                                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(Color.gray.opacity(0.4))
    }

    /// Explains *why* the button is disabled, so a greyed-out control is never
    /// a dead end.
    private var statusText: String {
        switch reachability.status {
        case .reachable:   "Camera found at 192.168.42.1"
        case .unreachable: "Camera not found — check the YDXJ_ network and that the camera is awake"
        case .noWiFi:      "Wi-Fi is off — join the camera's YDXJ_ network in Settings"
        case .checking, .unknown: "Looking for the camera…"
        }
    }

    private var statusIcon: String {
        switch reachability.status {
        case .reachable:   "checkmark.circle.fill"
        case .unreachable: "wifi.exclamationmark"
        case .noWiFi:      "wifi.slash"
        case .checking, .unknown: "antenna.radiowaves.left.and.right"
        }
    }

    private var statusColor: Color {
        switch reachability.status {
        case .reachable:          .green
        case .unreachable, .noWiFi: .orange
        case .checking, .unknown: .secondary
        }
    }

    /// The messages range from one line to three at larger Dynamic Type sizes,
    /// so the row reserves three lines up front and pins its content to the
    /// top. Sizing to content instead would shift the Connect button every
    /// time the status changed.
    private var statusRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: statusIcon)
                .frame(width: 16)
            Text(statusText)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(statusColor)
        // Fixed box, content top-aligned: a one-line message sits at the top
        // rather than centring itself in the reserved space.
        .frame(maxWidth: .infinity, minHeight: reservedStatusHeight,
               alignment: .topLeading)
    }

    /// Three lines of `.caption`, scaled with the user's text size setting.
    @ScaledMetric(relativeTo: .caption) private var reservedStatusHeight: CGFloat = 48
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Hero Icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 160, height: 160)
                    .scaleEffect(isAnimating ? 1.1 : 1.0)
                    .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isAnimating)
                
                Image(systemName: "camera.aperture")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundColor(.blue)
            }
            .padding(.bottom, 40)
            
            Text("Yippy!")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .padding(.bottom, 8)
            
            Text("Action Camera Controller")
                .font(.title3)
                .foregroundColor(.secondary)
                .padding(.bottom, 40)
            
            // Instructions Card
            VStack(alignment: .leading, spacing: 16) {
                InstructionRow(icon: "power.circle.fill", text: "Turn on your camera and its Wi-Fi")
                InstructionRow(icon: "wifi", text: "Connect to the 'YDXJ_...' network in Settings")
                InstructionRow(icon: "lock.shield.fill", text: "Default password is '1234567890'")
            }
            .padding(24)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(20)
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Live reachability, so the button reflects whether the camera can
            // actually be reached rather than inviting a tap that will hang.
            statusRow
                .animation(.easeInOut(duration: 0.2), value: reachability.status)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            // Connect Button
            Button(action: {
                // Stop probing before connecting: both open a socket to the
                // camera's control port, and the camera's TCP server handles
                // one connection at a time.
                reachability.stop()
                client.connect()
            }) {
                HStack {
                    if client.isConnected {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Connected")
                    } else {
                        Text(canConnect ? "Tap to Connect" : "Waiting for Camera…")
                            .fontWeight(.semibold)
                    }
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(buttonBackground)
                .cornerRadius(16)
                .shadow(color: client.isConnected ? .green.opacity(0.3)
                                                  : (canConnect ? .blue.opacity(0.3) : .clear),
                        radius: 10, x: 0, y: 5)
            }
            .disabled(client.isConnected || !canConnect)
            .animation(.easeInOut(duration: 0.2), value: canConnect)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .onAppear {
            isAnimating = true
            reachability.start()
        }
        .onDisappear {
            // Stop probing once connected or off-screen; the probe opens a
            // socket to the same port the client uses.
            reachability.stop()
        }
    }
}

struct InstructionRow: View {
    var icon: String
    var text: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)
            Text(text)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
