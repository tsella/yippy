import SwiftUI

struct DashboardView: View {
    @ObservedObject var client: YiCameraClient
    @State private var isRecording = false
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Top Status Bar
                HStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Text("\(client.batteryLevel)%")
                            .font(.caption2)
                            .foregroundColor(.white)
                        
                        Image(systemName: batteryIcon(for: client.batteryLevel))
                            .foregroundColor(client.batteryLevel <= 20 ? .red : .white)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 20)
                
                // Live Stream Viewfinder
                GeometryReader { geometry in
                    ZStack {
                        if let url = URL(string: "rtsp://192.168.42.1/live") {
                            RTSPPlayerView(url: url)
                                .aspectRatio(16/9, contentMode: .fit)
                                .frame(width: geometry.size.width)
                                .cornerRadius(16)
                                .clipped()
                        } else {
                            ZStack {
                                Color(UIColor.darkGray)
                                VStack {
                                    Image(systemName: "video.slash")
                                        .font(.largeTitle)
                                        .foregroundColor(.gray)
                                    Text("Stream Unavailable")
                                        .foregroundColor(.gray)
                                        .padding(.top, 8)
                                }
                            }
                            .aspectRatio(16/9, contentMode: .fit)
                            .cornerRadius(16)
                        }
                        
                        // Recording Indicator Overlay
                        if isRecording {
                            VStack {
                                HStack {
                                    HStack {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 10, height: 10)
                                        Text("REC")
                                            .font(.caption.bold())
                                            .foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(8)
                                    
                                    Spacer()
                                }
                                Spacer()
                            }
                            .padding(12)
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                Spacer()
                
                // Bottom Controls
                HStack(spacing: 50) {
                    // Photo Button
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        client.takePhoto()
                    }) {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .stroke(Color.white, lineWidth: 3)
                                    .frame(width: 60, height: 60)
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 50, height: 50)
                            }
                            Text("PHOTO")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                        }
                    }
                    
                    // Record Button
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .heavy)
                        impact.impactOccurred()
                        if isRecording {
                            client.stopRecording()
                        } else {
                            client.startRecording()
                        }
                        withAnimation {
                            isRecording.toggle()
                        }
                    }) {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .stroke(Color.white, lineWidth: 3)
                                    .frame(width: 80, height: 80)
                                
                                if isRecording {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.red)
                                        .frame(width: 32, height: 32)
                                } else {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 66, height: 66)
                                }
                            }
                            Text("VIDEO")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
    
    private func batteryIcon(for level: Int) -> String {
        switch level {
        case 0...10: return "battery.0"
        case 11...35: return "battery.25"
        case 36...65: return "battery.50"
        case 66...85: return "battery.75"
        default: return "battery.100"
        }
    }
}
