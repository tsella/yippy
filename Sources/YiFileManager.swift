import Foundation
import Combine

struct YiFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let date: Date?
    
    var downloadURL: URL? {
        let relativePath = path.replacingOccurrences(of: "/tmp/fuse_d/", with: "")
        return URL(string: "http://192.168.42.1/\(relativePath)")
    }
}

@MainActor
class YiFileManager: ObservableObject {
    @Published var files: [YiFile] = []
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    
    private let client: YiCameraClient
    private var downloadCancellable: AnyCancellable?
    
    init(client: YiCameraClient) {
        self.client = client
    }
    
    func listFiles() {
        Task {
            do {
                if let response = try await client.sendCommand(msgId: 1282, param: "-D -S /tmp/fuse_d/DCIM/100MEDIA", expectResponse: true) {
                    if let listing = response["listing"] as? [[String: Any]] {
                        var newFiles: [YiFile] = []
                        for item in listing {
                            if let items = item["files"] as? [[String: Any]] {
                                for file in items {
                                    if let name = file["name"] as? String,
                                       let size = file["size"] as? Int64 {
                                        let path = "/tmp/fuse_d/DCIM/100MEDIA/\(name)"
                                        newFiles.append(YiFile(name: name, path: path, size: size, date: nil))
                                    }
                                }
                            }
                        }
                        self.files = newFiles
                    }
                }
            } catch {
                print("Failed to list files: \(error)")
            }
        }
    }
    
    func deleteFile(path: String) {
        Task {
            do {
                _ = try await client.sendCommand(msgId: 1281, param: path, expectResponse: true)
                // Refresh list automatically after deletion
                self.listFiles()
            } catch {
                print("Failed to delete file: \(error)")
            }
        }
    }
    
    func downloadFile(_ file: YiFile) {
        guard let url = file.downloadURL else { return }
        
        isDownloading = true
        downloadProgress = 0.0
        
        let task = URLSession.shared.downloadTask(with: url) { [weak self] localURL, response, error in
            Task { @MainActor [weak self] in
                self?.isDownloading = false
                self?.downloadCancellable = nil
                
                if let error = error {
                    print("Download error: \(error)")
                    return
                }
                guard let localURL = localURL else { return }
                
                do {
                    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let destinationURL = documentsURL.appendingPathComponent(file.name)
                    
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: localURL, to: destinationURL)
                    print("File saved to \(destinationURL)")
                } catch {
                    print("File save error: \(error)")
                }
            }
        }
        
        // Observe progress
        downloadCancellable = task.progress.publisher(for: \.fractionCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.downloadProgress = progress
            }
        
        task.resume()
    }
}
