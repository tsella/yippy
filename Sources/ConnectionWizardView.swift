import SwiftUI

struct ConnectionWizardView: View {
    @ObservedObject var client: YiCameraClient
    @State private var isAnimating = false
    
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
            
            // Connect Button
            Button(action: {
                client.connect()
            }) {
                HStack {
                    if client.isConnected {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Connected")
                    } else {
                        Text("Tap to Connect")
                            .fontWeight(.semibold)
                    }
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    client.isConnected ? 
                    LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing) :
                    LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(16)
                .shadow(color: client.isConnected ? .green.opacity(0.3) : .blue.opacity(0.3), radius: 10, x: 0, y: 5)
            }
            .disabled(client.isConnected)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .onAppear {
            isAnimating = true
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
