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
    static let outputMode          = "fs_outputMode"
    static let m4aBitrate          = "fs_m4aBitrate"
    static let levelRiding         = "fs_levelRiding"
    static let levelAggressiveness = "fs_levelAggressiveness"
    static let dialogGuard         = "fs_dialogGuard"
    static let loudnormEnabled     = "fs_loudnormEnabled"
    static let loudnormTarget      = "fs_loudnormTarget"
    static let outputDir           = "fs_outputDir"           // legacy plain-path key
    static let outputDirBookmark   = "fs_outputDirBookmark"
}

@Observable
final class FilmStripSettings {
    var outputMode: OutputMode = .wav {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: Keys.outputMode) }
    }
    var m4aBitrate: M4ABitrate = .medium {
        didSet { UserDefaults.standard.set(m4aBitrate.rawValue, forKey: Keys.m4aBitrate) }
    }
    var levelRiding: Bool = false {
        didSet { UserDefaults.standard.set(levelRiding, forKey: Keys.levelRiding) }
    }
    var levelAggressiveness: Int = 5 {
        didSet { UserDefaults.standard.set(levelAggressiveness, forKey: Keys.levelAggressiveness) }
    }
    var dialogGuard: Bool = false {
        didSet { UserDefaults.standard.set(dialogGuard, forKey: Keys.dialogGuard) }
    }
    var loudnormEnabled: Bool = false {
        didSet { UserDefaults.standard.set(loudnormEnabled, forKey: Keys.loudnormEnabled) }
    }
    var loudnormTarget: Double = -18.0 {
        didSet { UserDefaults.standard.set(loudnormTarget, forKey: Keys.loudnormTarget) }
    }
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
        if ud.object(forKey: Keys.levelRiding) != nil {
            levelRiding = ud.bool(forKey: Keys.levelRiding)
        }
        if ud.object(forKey: Keys.levelAggressiveness) != nil {
            let v = ud.integer(forKey: Keys.levelAggressiveness)
            if (1...10).contains(v) { levelAggressiveness = v }
        }
        if ud.object(forKey: Keys.dialogGuard) != nil {
            dialogGuard = ud.bool(forKey: Keys.dialogGuard)
        }
        if ud.object(forKey: Keys.loudnormEnabled) != nil {
            loudnormEnabled = ud.bool(forKey: Keys.loudnormEnabled)
        }
        if ud.object(forKey: Keys.loudnormTarget) != nil {
            let v = ud.double(forKey: Keys.loudnormTarget)
            if (-23.0 ... -14.0).contains(v) { loudnormTarget = v }
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
