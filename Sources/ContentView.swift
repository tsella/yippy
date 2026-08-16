import SwiftUI

struct ContentView: View {
    @StateObject private var client = YiCameraClient()
    @StateObject private var fileManager: YiFileManager
    
    init() {
        let newClient = YiCameraClient()
        _client = StateObject(wrappedValue: newClient)
        _fileManager = StateObject(wrappedValue: YiFileManager(client: newClient))
    }
    
    var body: some View {
        NavigationView {
            if client.isConnected {
                TabView {
                    DashboardView(client: client)
                        .tabItem {
                            Label("Camera", systemImage: "camera")
                        }
                    
                    MediaGalleryView(fileManager: fileManager)
                        .tabItem {
                            Label("Gallery", systemImage: "photo.on.rectangle")
                        }
                        
                    DebugScannerView(client: client)
                        .tabItem {
                            Label("Scanner", systemImage: "terminal")
                        }
                        
                    SettingsView(client: client)
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                }
                .navigationTitle("Yippy!")
                .navigationBarTitleDisplayMode(.inline)
            } else {
                ConnectionWizardView(client: client)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
