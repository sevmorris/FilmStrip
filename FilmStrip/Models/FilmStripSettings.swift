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

@Observable
final class FilmStripSettings {
    var outputMode: OutputMode = .wav
    var m4aBitrate: M4ABitrate = .medium
    var levelRiding: Bool = false
    var levelAggressiveness: Int = 5   // 1 (gentle) – 10 (heavy), maps to dynaudnorm p
    var loudnormEnabled: Bool = false
    var loudnormTarget: Double = -18.0 // LUFS, range -23 to -14
    var outputDir: URL? = nil

    var resolvedOutputDir: URL {
        outputDir ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }
}
