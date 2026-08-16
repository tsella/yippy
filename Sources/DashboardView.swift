import SwiftUI

struct DashboardView: View {
    @ObservedObject var client: YiCameraClient
    @StateObject private var stream = RTSPStream()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                statusBar
                viewfinder
                Spacer(minLength: 0)
                controls
            }
        }
        .navigationTitle("Yippy!")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Connected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            HStack(spacing: 4) {
                if client.isCharging {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                }
                Text("\(client.batteryLevel)%")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Image(systemName: batteryIcon)
                    .foregroundStyle(client.batteryLevel <= 20 && !client.isCharging ? .red : .white)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Battery \(client.batteryLevel) percent\(client.isCharging ? ", charging" : "")")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var batteryIcon: String {
        switch client.batteryLevel {
        case ...10:  "battery.0"
        case ...35:  "battery.25"
        case ...65:  "battery.50"
        case ...85:  "battery.75"
        default:     "battery.100"
        }
    }

    // MARK: - Viewfinder

    private var viewfinder: some View {
        ZStack {
            // Only mount the player once the camera has actually started its
            // RTSP server (msg_id 259). Connecting earlier fails to bind and
            // VLC reports "invalid IP address: 0.0.0.0".
            if client.isViewfinderActive {
                ZStack {
                    // Native RTSP/UDP path. VLC cannot play this camera: it
                    // refuses interleaved TCP (461) and live555 cannot resolve
                    // a local address for the UDP path on iOS.
                    // One RTSP session exists on this firmware, so the
                    // viewfinder claims it and the debug probe is locked out
                    // while it is mounted.
                    H264StreamView(stream: stream)
                        // The camera stops the viewfinder while recording and
                        // on restart, so this remounts often. `start` is a
                        // no-op while a stream is already running.
                        .onAppear { stream.start(url: client.streamURL) }
                        .onDisappear { stream.stop() }

                    if case .failed(let reason) = stream.state {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title)
                                .foregroundStyle(.orange)
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                            Button("Retry") {
                                stream.stop()
                                stream.start(url: client.streamURL)
                            }
                            .accessibilityLabel("Retry stream")
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                        .padding()
                    } else if stream.state == .connecting {
                        VStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Connecting to stream…")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
            } else {
                ZStack {
                    Color(.darkGray)
                    VStack(spacing: 12) {
                        if client.isRecording {
                            // The camera stops the viewfinder while recording
                            // and restores it itself when the file is written.
                            Image(systemName: "record.circle")
                                .font(.largeTitle)
                            Text("Preview paused while recording")
                                .multilineTextAlignment(.center)
                        } else {
                            Image(systemName: "video.slash")
                                .font(.largeTitle)
                            Text("Stream Unavailable")
                            Button("Restart Stream") {
                                Task { await client.restartViewfinder() }
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                    }
                    .foregroundStyle(.gray)
                }
            }

            if client.isRecording {
                VStack {
                    HStack {
                        recordingBadge
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
            }

            // The photo_taken notification carries the saved file's path, so
            // the shot just captured can be previewed immediately.
            if let path = client.lastCapturedPath {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        CapturePreview(path: path)
                            .padding(12)
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        // Full-bleed: no horizontal inset, and square corners, since rounded
        // ones read as a mistake when the edges meet the screen. The ratio
        // comes from the stream's SPS, so the frame matches the video instead
        // of letterboxing it inside an assumed 16:9.
        .aspectRatio(stream.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
            Text("REC")
                .font(.caption.bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: Capsule())
        .accessibilityLabel("Recording")
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 50) {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                client.takePhoto()
            } label: {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 60, height: 60)
                        Circle().fill(.white).frame(width: 50, height: 50)
                    }
                    Text("PHOTO").font(.caption2.bold()).foregroundStyle(.white)
                }
            }
            // The camera wedges if a command arrives while it is writing a
            // photo, so the controls stay locked until the capture completes.
            .disabled(client.isRecording || client.isCapturing)
            .opacity(client.isRecording || client.isCapturing ? 0.4 : 1)
            .accessibilityLabel("Take photo")

            Button {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                // State is updated from the camera's own notification, not
                // optimistically, so the UI cannot drift out of sync.
                if client.isRecording {
                    client.stopRecording()
                } else {
                    client.startRecording()
                }
            } label: {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 80, height: 80)
                        if client.isRecording {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.red)
                                .frame(width: 32, height: 32)
                        } else {
                            Circle().fill(.red).frame(width: 66, height: 66)
                        }
                    }
                    Text("VIDEO").font(.caption2.bold()).foregroundStyle(.white)
                }
            }
            .disabled(client.isCapturing)
            .opacity(client.isCapturing ? 0.4 : 1)
            .accessibilityLabel(client.isRecording ? "Stop recording" : "Start recording")
        }
        .animation(.spring(duration: 0.25), value: client.isRecording)
        .padding(.bottom, 40)
        .padding(.top, 20)
    }
}
