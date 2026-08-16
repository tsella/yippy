import Foundation
import Photos

/// Saves downloaded media into the user's photo library.
///
/// Camera media belongs in the camera roll, not in the app's private container
/// where it is invisible without file sharing.
enum PhotoLibrarySaver {

    enum SaveError: LocalizedError {
        case permissionDenied
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Photo library access denied. Enable it in Settings › Privacy › Photos › Yippy!."
            case .saveFailed(let reason):
                return "Could not save to Photos: \(reason)"
            }
        }
    }

    /// Requests add-only access, which does not grant the ability to read the
    /// user's existing library.
    static func requestAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            print("[photos] authorization result: \(describe(granted))")
            return granted == .authorized || granted == .limited
        default:
            print("[photos] access denied — status: \(describe(status))")
            return false
        }
    }

    private static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized"
        case .limited:       return "limited"
        @unknown default:    return "unknown(\(status.rawValue))"
        }
    }

    /// Saves a file into the camera roll.
    ///
    /// Deliberately **add-only**: the app never reads the user's library.
    ///
    /// An earlier version also filed each asset into a "Yippy!" album, but doing
    /// that requires `PHAsset.fetchAssets` / `PHAssetCollection.fetchAssetCollections`
    /// to resolve the placeholders — those are *read* APIs. They demand
    /// `NSPhotoLibraryUsageDescription` and full library access, and crash the
    /// app outright without it. Saving to the camera roll is the whole job here,
    /// so the album is not worth trading read access for.
    static func save(fileURL: URL, isVideo: Bool) async throws {
        guard await requestAccess() else { throw SaveError.permissionDenied }

        // Fail loudly here if the file is not where we think it is, rather than
        // letting Photos reject it with an opaque error.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SaveError.saveFailed("the downloaded file was missing")
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        print("[photos] saving \(fileURL.lastPathComponent) (\(size) bytes, isVideo=\(isVideo))")

        do {
            try await PHPhotoLibrary.shared().performChanges {
                if isVideo {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                }
            }
            print("[photos] saved \(fileURL.lastPathComponent)")
        } catch {
            print("[photos] save FAILED: \(error)")
            throw SaveError.saveFailed(error.localizedDescription)
        }
    }
}
