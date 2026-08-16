import Foundation

// MARK: - Ambarella / Xiaomi Yi Protocol Reference
//
// The camera exposes an Ambarella-standard JSON-over-TCP control channel on
// 192.168.42.1:7878. Every request is a single JSON object terminated by a
// newline; every response carries `msg_id` echoing the request and `rval`
// (0 == success, negative == error).
//
// Sources (reverse-engineered; there is no vendor-published spec):
//   - https://gist.github.com/pbaja/f57e6cff7fa14601f6b256926aa33437
//   - https://www.rigacci.org/wiki/doku.php/doc/appunti/hardware/sjcam-8pro-ambarella-wifi-api
//   - https://gist.github.com/franga2000/1be2aa18cb3409e57af149883c06e34a
//
// Codes marked "unverified" appear in only one community source and have not
// been confirmed against this camera. Treat their text as a hint, not truth.

// MARK: - Commands

/// Known `msg_id` command codes. Raw values match the Ambarella `AMBA_*` constants.
enum YiCommand: Int, CaseIterable {
    case getSetting              = 1     // AMBA_GET_SETTING
    case setSetting              = 2     // AMBA_SET_SETTING
    case getAllSettings          = 3     // AMBA_GET_ALL_CURRENT_SETTINGS
    case formatCard              = 4     // AMBA_FORMAT
    case getSpace                = 5     // AMBA_GET_SPACE          (type: "free" | "total")
    case notification            = 7     // AMBA_NOTIFICATION       (camera -> app only)
    case getSettingOptions       = 9     // AMBA_GET_SINGLE_SETTING_OPTIONS
    case getDeviceInfo           = 11    // AMBA_GET_DEVICEINFO
    case cameraOff               = 12    // AMBA_CAMERA_OFF
    case getBatteryLevel         = 13    // AMBA_GET_BATTERY_LEVEL

    case startSession            = 257   // AMBA_START_SESSION      (send with token 0)
    case stopSession             = 258   // AMBA_STOP_SESSION
    case startViewfinder         = 259   // AMBA_BOSS_RESETVF       (starts RTSP, NOT a keepalive)
    case stopViewfinder          = 260   // AMBA_STOP_VF

    case recordStart             = 513   // AMBA_RECORD_START
    case recordStop              = 514   // AMBA_RECORD_STOP
    case getRecordTime           = 515   // AMBA_GET_RECORD_TIME

    case takePhoto               = 769   // AMBA_TAKE_PHOTO
    case stopTimelapse           = 770

    case getFileInfo             = 1026
    case deleteFile              = 1281  // AMBA_RM
    case listDirectory           = 1282  // AMBA_LS   (param: directory path)
    case changeDirectory         = 1283  // AMBA_CD
    case getFileSize             = 1285

    /// Human-readable name for logs.
    var name: String {
        switch self {
        case .getSetting:        return "GET_SETTING"
        case .setSetting:        return "SET_SETTING"
        case .getAllSettings:    return "GET_ALL_SETTINGS"
        case .formatCard:        return "FORMAT"
        case .getSpace:          return "GET_SPACE"
        case .notification:      return "NOTIFICATION"
        case .getSettingOptions: return "GET_SETTING_OPTIONS"
        case .getDeviceInfo:     return "GET_DEVICE_INFO"
        case .cameraOff:         return "CAMERA_OFF"
        case .getBatteryLevel:   return "GET_BATTERY_LEVEL"
        case .startSession:      return "START_SESSION"
        case .stopSession:       return "STOP_SESSION"
        case .startViewfinder:   return "START_VIEWFINDER"
        case .stopViewfinder:    return "STOP_VIEWFINDER"
        case .recordStart:       return "RECORD_START"
        case .recordStop:        return "RECORD_STOP"
        case .getRecordTime:     return "GET_RECORD_TIME"
        case .takePhoto:         return "TAKE_PHOTO"
        case .stopTimelapse:     return "STOP_TIMELAPSE"
        case .getFileInfo:       return "GET_FILE_INFO"
        case .deleteFile:        return "DELETE_FILE"
        case .listDirectory:     return "LIST_DIRECTORY"
        case .changeDirectory:   return "CHANGE_DIRECTORY"
        case .getFileSize:       return "GET_FILE_SIZE"
        }
    }

    static func describe(_ msgId: Int) -> String {
        YiCommand(rawValue: msgId).map { "\($0.name) (\(msgId))" } ?? "UNKNOWN (\(msgId))"
    }
}

// MARK: - Return values

/// Ambarella `rval` return codes.
///
/// `0` is success. Negative values are errors; the same numeric code can carry a
/// slightly different meaning per command, so `message(for:)` accepts an optional
/// `msg_id` to disambiguate the cases where community captures disagree.
enum YiReturnCode {
    static let success = 0

    /// Codes the API scanner should treat as "this msg_id is not implemented",
    /// rather than as a discovered command.
    static let unsupportedCommandCodes: Set<Int> = [-9, -4, -7]

    private static let table: [Int: String] = [
          0: "Success",
         -1: "Command failed / invalid state for this command",
         -3: "Invalid parameter value",
         -4: "Empty or malformed request object",
         -7: "Invalid or expired token — re-authenticate",
         -9: "Unsupported command (msg_id not implemented)",
        -13: "Permission denied",                      // unverified
        -14: "Setting rejected or unchanged",
        -15: "Unknown internal error",
        -16: "Operation not permitted in current mode", // unverified
        -17: "Resource busy",                           // unverified
        -21: "Operation failed (camera busy or wrong mode)",
        -23: "No data / nothing to return",
        -24: "File not found",                          // unverified
        -25: "File or directory access error",          // unverified
        -26: "Directory not found (SD card missing, empty or unformatted)",
        -27: "SD card missing, full, or busy",
        // Observed on this camera when capture is attempted with no usable
        // card: TAKE_PHOTO and RECORD_START both return -28 while the card is
        // unwritable, even though battery/device-info calls still succeed.
        -28: "No usable SD card — insert or reformat the card",
       -101: "Camera firmware crashed — reconnect required",
    ]

    /// Human-readable description of an `rval`, specialised per command where needed.
    static func message(for rval: Int, msgId: Int? = nil) -> String {
        if rval == success { return "Success" }

        // Command-specific overrides where the generic meaning is misleading.
        if let msgId {
            switch (msgId, rval) {
            case (YiCommand.getRecordTime.rawValue, -1):
                return "Camera is not currently recording"
            case (YiCommand.recordStart.rawValue, -27),
                 (YiCommand.takePhoto.rawValue, -27):
                return "SD card missing, full, or busy"
            case (YiCommand.listDirectory.rawValue, -26):
                return "Directory not found (SD card missing, empty or unformatted)"
            default:
                break
            }
        }

        return table[rval] ?? "Undocumented error code"
    }

    /// `true` when the code means the command itself does not exist on this firmware.
    static func isUnsupportedCommand(_ rval: Int) -> Bool {
        unsupportedCommandCodes.contains(rval)
    }

    /// Formatted for logging, e.g. `rval=-27 (SD card missing, full, or busy)`.
    static func describe(_ rval: Int, msgId: Int? = nil) -> String {
        "rval=\(rval) (\(message(for: rval, msgId: msgId)))"
    }
}

// MARK: - Response helpers

extension Dictionary where Key == String, Value == Any {
    /// The response's return code. A reply with no `rval` field is treated as
    /// success, which is the camera's convention for acknowledgements.
    var rval: Int {
        self["rval"] as? Int ?? YiReturnCode.success
    }

    var succeeded: Bool { rval == YiReturnCode.success }
}

// MARK: - Asynchronous notifications (msg_id 7)

/// `type` values delivered on unsolicited `msg_id: 7` notifications.
enum YiNotification: String {
    case battery                  = "battery"
    case adapterStatus            = "adapter_status"
    case batteryStatus            = "battery_status"
    case sdCardStatus             = "sd_card_status"
    case cardRemoved              = "CARD_REMOVED"
    case cardFormatError          = "CARD_FORMAT_ERROR"
    case storageIOError           = "STORAGE_IO_ERROR"
    case startPhotoCapture        = "start_photo_capture"
    case preciseCaptureDataReady  = "precise_capture_data_ready"
    case photoTaken               = "photo_taken"
    case startVideoRecord         = "start_video_record"
    case stopVideoRecord          = "stop_video_record"
    case videoRecordComplete      = "video_record_complete"
    case switchToRecMode          = "switch_to_rec_mode"
    case switchToCapMode          = "switch_to_cap_mode"
    case viewfinderStart          = "vf_start"
    case viewfinderStop           = "vf_stop"

    /// Message suitable for showing to the user, or `nil` for events that
    /// should be handled silently.
    var userFacingMessage: String? {
        switch self {
        case .photoTaken:         return "Photo saved"
        case .videoRecordComplete: return "Video saved"
        case .cardFormatError:    return "SD card format error"
        case .storageIOError:     return "Storage I/O error"
        case .cardRemoved:        return "SD card removed"
        default:                  return nil
        }
    }

    /// Whether the message should be presented as an error.
    var isError: Bool {
        switch self {
        case .cardFormatError, .storageIOError, .cardRemoved: return true
        default: return false
        }
    }
}
