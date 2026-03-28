import Foundation

enum ProcessingError: LocalizedError {
    case invalidInput
    case tempDirectoryFailed
    case ffmpegNotFound
    case ffmpegFailed(code: Int32, message: String)
    case ffprobeFailed(String)
    case outputMissing
    case noTracksSelected

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid or unsupported input file."
        case .tempDirectoryFailed:
            return "Failed to create temporary directory."
        case .ffmpegNotFound:
            return "FFmpeg/FFprobe executable not found in app bundle."
        case .ffmpegFailed(let code, let message):
            return "FFmpeg failed (exit \(code)): \(message)"
        case .ffprobeFailed(let message):
            return "FFprobe failed: \(message)"
        case .outputMissing:
            return "Processing produced no output file."
        case .noTracksSelected:
            return "No audio tracks selected for export."
        }
    }
}
