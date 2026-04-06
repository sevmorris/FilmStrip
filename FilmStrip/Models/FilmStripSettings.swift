import Foundation

enum OutputMode: String, CaseIterable, Sendable {
    case wav  = "WAV"
    case m4a  = "M4A"
    case both = "Both"
}

enum M4ABitrate: Int, CaseIterable, Sendable {
    case low    = 128
    case medium = 192
    case high   = 256

    var label: String { "\(rawValue) kbps" }
}

private enum Keys {
    static let outputMode        = "fs_outputMode"
    static let m4aBitrate        = "fs_m4aBitrate"
    static let outputDir         = "fs_outputDir"           // legacy plain-path key
    static let outputDirBookmark = "fs_outputDirBookmark"
    // Audio processing settings are intentionally NOT persisted — they always
    // start at their defaults so the app is ready to use without configuration.
}

@Observable
final class FilmStripSettings {
    var outputMode: OutputMode = .wav {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: Keys.outputMode) }
    }
    var m4aBitrate: M4ABitrate = .medium {
        didSet { UserDefaults.standard.set(m4aBitrate.rawValue, forKey: Keys.m4aBitrate) }
    }
    var levelRiding: Bool = true
    var levelAggressiveness: Int = 7
    var dialogGuard: Bool = true
    var loudnormEnabled: Bool = true
    var loudnormTarget: Double = -16.0
    var outputDir: URL? = nil {
        didSet {
            // Stop access on any URL whose scope we previously started (bookmark-restored URLs).
            // URLs obtained from NSOpenPanel must NOT be stopped here — the sandbox grants
            // access automatically and we never called start on them.
            securedURL?.stopAccessingSecurityScopedResource()
            securedURL = nil

            if let url = outputDir,
               let bookmark = try? url.bookmarkData(
                   options: .withSecurityScope,
                   includingResourceValuesForKeys: nil,
                   relativeTo: nil) {
                UserDefaults.standard.set(bookmark, forKey: Keys.outputDirBookmark)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.outputDirBookmark)
            }
            // Remove legacy key if present
            UserDefaults.standard.removeObject(forKey: Keys.outputDir)
        }
    }

    /// Tracks the URL whose security scope we started (bookmark-restored only).
    /// Must be stopped when outputDir changes or the object is deallocated.
    private var securedURL: URL?

    /// Set to true during init if a saved output folder bookmark was stale or inaccessible.
    /// ContentViewModel checks this and surfaces a warning to the user.
    private(set) var outputDirWasReset = false

    init() {
        let ud = UserDefaults.standard

        if let raw = ud.string(forKey: Keys.outputMode),
           let v = OutputMode(rawValue: raw) {
            outputMode = v
        }
        if ud.object(forKey: Keys.m4aBitrate) != nil,
           let v = M4ABitrate(rawValue: ud.integer(forKey: Keys.m4aBitrate)) {
            m4aBitrate = v
        }
        if let bookmark = ud.data(forKey: Keys.outputDirBookmark) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale),
               !isStale {
                // Only proceed if the sandbox actually grants access.
                // Set outputDir first (securedURL is nil at this point so didSet won't stop anything),
                // then record the URL so deinit and future changes can stop it.
                if url.startAccessingSecurityScopedResource() {
                    outputDir = url
                    securedURL = url
                } else {
                    ud.removeObject(forKey: Keys.outputDirBookmark)
                    outputDirWasReset = true
                }
            } else {
                ud.removeObject(forKey: Keys.outputDirBookmark)
                outputDirWasReset = true
            }
        } else if ud.object(forKey: Keys.outputDir) != nil {
            // Legacy plain-path key has no sandbox access — discard it so the user is prompted
            ud.removeObject(forKey: Keys.outputDir)
        }
    }

    deinit {
        securedURL?.stopAccessingSecurityScopedResource()
    }

    func resolvedOutputDir(fallback: URL?) -> URL {
        outputDir ?? fallback ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }
}
