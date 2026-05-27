import Foundation

enum LevelRidingPreset: String, CaseIterable, Sendable {
    case cinematic
    case comfort
    case aggressive

    var label: String {
        switch self {
        case .cinematic:  "Cinematic"
        case .comfort:    "Comfort"
        case .aggressive: "Aggressive"
        }
    }

    var shortDescription: String {
        switch self {
        case .cinematic:
            "Light leveling — preserves more theatrical dynamics."
        case .comfort:
            "Balanced leveling for headphone listening (default)."
        case .aggressive:
            "Heavy leveling — quiet dialog and loud action approach similar level."
        }
    }

    var aggressiveness: Int {
        switch self {
        case .cinematic:  4
        case .comfort:    7
        case .aggressive: 9
        }
    }
}

enum ProcessingProfile: String, CaseIterable, Sendable {
    case headphone
    case cinematic
    case aggressive

    var label: String {
        switch self {
        case .headphone:   "Headphone"
        case .cinematic:   "Cinematic"
        case .aggressive:  "Aggressive"
        }
    }

    func apply(to settings: FilmStripSettings) {
        switch self {
        case .headphone:
            settings.processingProfile = .headphone
            settings.dialogGuard = true
            settings.stereoDialogAssist = true
            settings.dialogLevel = .normal
            settings.highPassFilter = true
            settings.levelRiding = true
            settings.levelRidingPreset = .comfort
            settings.levelAggressiveness = 7
            settings.loudnormEnabled = true
            settings.loudnormTarget = -18
        case .cinematic:
            settings.processingProfile = .cinematic
            settings.dialogGuard = true
            settings.stereoDialogAssist = false
            settings.dialogLevel = .normal
            settings.highPassFilter = true
            settings.levelRiding = true
            settings.levelRidingPreset = .cinematic
            settings.levelAggressiveness = 4
            settings.loudnormEnabled = true
            settings.loudnormTarget = -20
        case .aggressive:
            settings.processingProfile = .aggressive
            settings.dialogGuard = true
            settings.stereoDialogAssist = true
            settings.dialogLevel = .boost
            settings.highPassFilter = true
            settings.levelRiding = true
            settings.levelRidingPreset = .aggressive
            settings.levelAggressiveness = 9
            settings.loudnormEnabled = true
            settings.loudnormTarget = -16
        }
    }
}
