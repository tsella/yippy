import SwiftUI

struct ContentView: View {
    @StateObject private var client: YiCameraClient
    @StateObject private var fileManager: YiFileManager
    @AppStorage("showDebugScanner") private var showDebugScanner = false

    init() {
        // Build once and share, so the file manager and the views observe the
        // same client instance.
        let client = YiCameraClient()
        _client = StateObject(wrappedValue: client)
        _fileManager = StateObject(wrappedValue: YiFileManager(client: client))
        // Wire the thumbnail cache to this camera up front, so every screen —
        // not just the gallery — reads and writes the right partition.
        ThumbnailLoader.shared.attach(to: client)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if client.isConnected {
                TabView {
                    NavigationStack {
                        DashboardView(client: client)
                    }
                    .tabItem { Label("Camera", systemImage: "camera") }

                    NavigationStack {
                        MediaGalleryView(fileManager: fileManager, client: client)
                    }
                    .tabItem { Label("Gallery", systemImage: "photo.on.rectangle") }

                    if showDebugScanner {
                        NavigationStack {
                            DebugScannerView(client: client)
                        }
                        .tabItem { Label("Scanner", systemImage: "terminal") }
                    }

                    NavigationStack {
                        SettingsView(client: client)
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                }
                .transition(.opacity)
            } else {
                ConnectionWizardView(client: client)
                    .transition(.opacity)
            }

            if let banner = client.activeBanner {
                BannerView(banner: banner)
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }

            // Blocks interaction while the camera is occupied (e.g. formatting),
            // so the user isn't left tapping a seemingly frozen UI.
            if client.isBusy {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text(client.busyMessage ?? "Working…")
                            .font(.subheadline.weight(.medium))
                        Text("This can take up to a minute.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                }
                .transition(.opacity)
                .zIndex(200)
            }
        }
        .animation(.spring(duration: 0.3), value: client.isConnected)
        .animation(.spring(duration: 0.3), value: client.activeBanner)
        .animation(.easeInOut(duration: 0.2), value: client.isBusy)
    }
}

/// Transient status banner. Colour and icon follow the severity of the event,
/// so a saved photo does not look like a failure.
struct BannerView: View {
    let banner: YiBanner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(banner.message)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(banner.isError ? Color.red.opacity(0.92) : Color.green.opacity(0.92))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(banner.isError ? "Error: \(banner.message)" : banner.message)
    }
}

#Preview {
    ContentView()
}
