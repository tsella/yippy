import SwiftUI

struct MediaGalleryView: View {
    @ObservedObject var fileManager: YiFileManager
    @State private var fileToDelete: YiFile?
    @State private var showingDeleteAlert = false
    
    let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 16)
    ]
    
    var body: some View {
        Group {
            if fileManager.files.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("No Media Found")
                        .font(.title2.bold())
                    Text("Capture some photos or videos with your camera first.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Refresh") {
                        fileManager.listFiles()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(fileManager.files) { file in
                            MediaCard(file: file) {
                                fileManager.downloadFile(file)
                            } onDelete: {
                                fileToDelete = file
                                showingDeleteAlert = true
                            }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    fileManager.listFiles()
                }
            }
        }
        .navigationTitle("Gallery")
        .onAppear {
            fileManager.listFiles()
        }
        .overlay(
            Group {
                if fileManager.isDownloading {
                    VStack(spacing: 16) {
                        ProgressView(value: fileManager.downloadProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 200)
                        
                        Text("Downloading: \(Int(fileManager.downloadProgress * 100))%")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .shadow(radius: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.3))
                }
            }
        )
        .alert(isPresented: $showingDeleteAlert) {
            Alert(
                title: Text("Delete File?"),
                message: Text("Are you sure you want to permanently delete this file from the camera?"),
                primaryButton: .destructive(Text("Delete")) {
                    if let file = fileToDelete {
                        fileManager.deleteFile(path: file.path)
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

struct MediaCard: View {
    let file: YiFile
    let onDownload: () -> Void
    let onDelete: () -> Void
    
    var isVideo: Bool {
        file.name.lowercased().hasSuffix(".mp4")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail placeholder
            ZStack {
                Rectangle()
                    .fill(Color(UIColor.tertiarySystemGroupedBackground))
                    .aspectRatio(1.0, contentMode: .fit)
                
                Image(systemName: isVideo ? "video.fill" : "photo.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.gray.opacity(0.5))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                
                HStack {
                    Text(String(format: "%.1f MB", Double(file.size) / 1024.0 / 1024.0))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    
                    Menu {
                        Button(action: onDownload) {
                            Label("Save to Device", systemImage: "arrow.down.circle")
                        }
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .foregroundColor(.gray)
                            .font(.system(size: 18))
                    }
                }
            }
            .padding(10)
            .background(Color(UIColor.secondarySystemGroupedBackground))
        }
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}
