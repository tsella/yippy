import Foundation

/// The app's version, read from the bundle rather than hardcoded.
///
/// `Info.plist` is the single source of truth — a string duplicated into a view
/// goes stale the first time the version is bumped and nobody greps for it.
enum AppVersion {

    /// `CFBundleShortVersionString`, e.g. "0.1.0".
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// `CFBundleVersion` — the build number.
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// "0.1.0 (1)" — version with build, for the settings row.
    static var full: String {
        build == short ? short : "\(short) (\(build))"
    }

    /// "v0.1.0" — the compact form for the onboarding screen.
    static var display: String { "v\(short)" }
}
