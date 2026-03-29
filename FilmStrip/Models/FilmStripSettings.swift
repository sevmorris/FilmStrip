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
    static let loudnormEnabled     = "fs_loudnormEnabled"
    static let loudnormTarget      = "fs_loudnormTarget"
    static let outputDir           = "fs_outputDir"
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
    var loudnormEnabled: Bool = false {
        didSet { UserDefaults.standard.set(loudnormEnabled, forKey: Keys.loudnormEnabled) }
    }
    var loudnormTarget: Double = -18.0 {
        didSet { UserDefaults.standard.set(loudnormTarget, forKey: Keys.loudnormTarget) }
    }
    var outputDir: URL? = nil {
        didSet {
            if let url = outputDir {
                UserDefaults.standard.set(url.path, forKey: Keys.outputDir)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.outputDir)
            }
        }
    }

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
        if ud.object(forKey: Keys.loudnormEnabled) != nil {
            loudnormEnabled = ud.bool(forKey: Keys.loudnormEnabled)
        }
        if ud.object(forKey: Keys.loudnormTarget) != nil {
            let v = ud.double(forKey: Keys.loudnormTarget)
            if (-23.0 ... -14.0).contains(v) { loudnormTarget = v }
        }
        if let path = ud.string(forKey: Keys.outputDir) {
            outputDir = URL(fileURLWithPath: path)
        }
    }

    var resolvedOutputDir: URL {
        outputDir ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }
}
