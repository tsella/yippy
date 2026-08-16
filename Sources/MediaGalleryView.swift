import SwiftUI

struct MediaGalleryView: View {
    @ObservedObject var fileManager: YiFileManager
    @ObservedObject var client: YiCameraClient
    @State private var fileToDelete: YiFile?
    @State private var selectedFile: YiFile?

    /// Multi-select mode. `nil` means normal browsing; a non-nil set means the
    /// selection bar is up, even when the set is empty (the user can uncheck
    /// everything without leaving the mode).
    @State private var selection: Set<String>?
    @State private var confirmingBatchDelete = false

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 16)]

    private var isSelecting: Bool { selection != nil }

    private func toggle(_ file: YiFile) {
        guard var current = selection else { return }
        if current.contains(file.id) { current.remove(file.id) } else { current.insert(file.id) }
        selection = current
    }

    private var selectedFiles: [YiFile] {
        guard let selection else { return [] }
        return fileManager.files.filter { selection.contains($0.id) }
    }

    var body: some View {
        Group {
            if fileManager.isLoading && fileManager.files.isEmpty {
                ProgressView("Loading media…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fileManager.files.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle(isSelecting ? "\(selectedFiles.count) Selected" : "Gallery")
        .safeAreaInset(edge: .top) {
            if isSelecting { selectionBar }
        }
        .task {
            // Only load on first appearance; pull-to-refresh handles the rest.
            if fileManager.files.isEmpty { await fileManager.listFiles() }
        }
        // The camera pushes photo_taken / video_record_complete when new media
        // lands on the card, so the gallery refreshes itself instead of polling.
        .onChange(of: client.mediaChangeCount) { _ in
            // Capture-driven refresh: a new file can only have been added, so
            // skip the orphan sweep and keep this path light.
            Task { await fileManager.listFiles(fullRefresh: false) }
        }
        .overlay { downloadOverlay }
        .overlay {
            if fileManager.isDeleting {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView(value: fileManager.deleteProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 180)
                        Text("Deleting…")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .fullScreenCover(item: $selectedFile) { file in
            MediaDetailView(file: file) {
                Task { await fileManager.deleteFile(file) }
            } onSave: {
                fileManager.downloadFile(file)
            }
        }
        .confirmation(
            isPresented: .init(get: { fileToDelete != nil },
                               set: { if !$0 { fileToDelete = nil } }),
            title: "Delete \(fileToDelete?.name ?? "file")?",
            message: "This permanently removes the file from the camera's SD card.",
            confirmTitle: "Delete"
        ) {
            // Capture before the binding clears it.
            if let file = fileToDelete {
                Task { await fileManager.deleteFile(file) }
            }
        }
        .confirmation(
            isPresented: $confirmingBatchDelete,
            title: selectedFiles.count == 1
                ? "Delete \(selectedFiles.first?.name ?? "file")?"
                : "Delete \(selectedFiles.count) files?",
            message: "This permanently removes \(selectedFiles.count == 1 ? "it" : "them") from the camera's SD card.",
            confirmTitle: "Delete"
        ) {
            let targets = selectedFiles
            withAnimation { selection = nil }
            Task { await fileManager.deleteFiles(targets) }
        }
        .alert("Error", isPresented: .init(get: { fileManager.errorMessage != nil },
                                           set: { if !$0 { fileManager.errorMessage = nil } })) {
            Button("OK") { fileManager.errorMessage = nil }
        } message: {
            Text(fileManager.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let saved = fileManager.savedMessage {
                Label(saved, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        fileManager.savedMessage = nil
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: fileManager.savedMessage)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(.gray)
            Text("No Media Found")
                .font(.title2.bold())
            Text("Capture some photos or videos with your camera first.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Refresh") {
                Task { await fileManager.listFiles() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Delete / Cancel bar shown above the grid while selecting.
    private var selectionBar: some View {
        HStack {
            Button("Cancel") {
                withAnimation { selection = nil }
            }

            Spacer()

            Button {
                let targets = selectedFiles
                withAnimation { selection = nil }
                fileManager.downloadFiles(targets)
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
                    .fontWeight(.semibold)
            }
            .disabled(selectedFiles.isEmpty)

            Button(role: .destructive) {
                confirmingBatchDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .fontWeight(.semibold)
            }
            .disabled(selectedFiles.isEmpty)
            .padding(.leading, 16)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var grid: some View {
        ScrollView {
            // Photos are 4:3 and videos 16:9, so cells in a row differ in
            // height. Top-align them rather than letting each stretch to the
            // row height, which would detach the caption from its thumbnail.
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(fileManager.files) { file in
                    MediaCard(
                        file: file,
                        isSelecting: isSelecting,
                        isSelected: selection?.contains(file.id) ?? false
                    ) {
                        fileManager.downloadFile(file)
                    } onDelete: {
                        fileToDelete = file
                    } onOpen: {
                        if isSelecting {
                            toggle(file)
                        } else {
                            selectedFile = file
                        }
                    } onBeginSelection: {
                        // Long press starts selection with this file checked.
                        withAnimation { selection = [file.id] }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .contextMenu {
                        if !isSelecting {
                            Button {
                                withAnimation { selection = [file.id] }
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            Button {
                                fileManager.downloadFile(file)
                            } label: {
                                Label("Save to Photos", systemImage: "square.and.arrow.down")
                            }
                            Button(role: .destructive) {
                                fileToDelete = file
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .refreshable { await fileManager.listFiles() }
    }

    @ViewBuilder
    private var downloadOverlay: some View {
        if let file = fileManager.downloadingFile {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView(value: fileManager.downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                    if let batch = fileManager.batchProgress {
                        Text("Downloading \(batch.current) of \(batch.total)")
                            .font(.subheadline.weight(.medium))
                    }
                    Text(file.name)
                        .font(fileManager.batchProgress == nil ? .subheadline.weight(.medium) : .caption)
                        .foregroundStyle(fileManager.batchProgress == nil ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(Int(fileManager.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Cancel", role: .cancel) { fileManager.cancelDownload() }
                        .padding(.top, 4)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 10)
            }
        }
    }
}

struct MediaCard: View {
    let file: YiFile
    var isSelecting = false
    var isSelected = false
    let onDownload: () -> Void
    let onDelete: () -> Void
    var onOpen: (() -> Void)?
    var onBeginSelection: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThumbnailView(file: file)
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.9),
                                             isSelected ? Color.accentColor : .black.opacity(0.35))
                            .shadow(radius: 2)
                            .padding(6)
                    }
                }
                .overlay {
                    if isSelecting && isSelected {
                        Color.accentColor.opacity(0.25)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onOpen?() }
                .onLongPressGesture {
                    guard !isSelecting else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onBeginSelection?()
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.formattedSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let date = file.date {
                            Text(date, format: .dateTime.day().month().year())
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Menu {
                        Button(action: onDownload) {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .foregroundStyle(.gray)
                            .font(.system(size: 18))
                    }
                    .accessibilityLabel("Actions for \(file.name)")
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
    }
}
