import Foundation

enum QueueItemStatus: Equatable, Sendable {
    case pending
    case inspecting
    case ready
    case processing
    case done
    case failed(String)
}

struct QueueItem: Identifiable, Sendable {
    let id: UUID
    let url: URL
    var status: QueueItemStatus
    var tracks: [AudioTrack]
    var selectedIDs: Set<Int>
    var outputURLs: [URL]
    /// Human-readable summary set after inspection, e.g. "2 tracks · English"
    var trackSummary: String
    /// True when no language metadata was found and all tracks were selected as a fallback
    var languageUnknown: Bool

    init(url: URL) {
        id = UUID()
        self.url = url
        status = .pending
        tracks = []
        selectedIDs = []
        outputURLs = []
        trackSummary = ""
        languageUnknown = false
    }

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    var selectedTracks: [AudioTrack] {
        tracks.filter { selectedIDs.contains($0.id) }
    }
}
