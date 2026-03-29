import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class ContentViewModel {

    // MARK: - State

    var sourceURL: URL?
    var movieTitle: String = ""
    var tracks: [AudioTrack] = []
    var selectedIDs: Set<Int> = []

    var settings = FilmStripSettings()

    var isInspecting: Bool = false
    var isProcessing: Bool = false

    var outputURLs: [URL] = []
    var errorMessage: String?
    var log: [String] = []
    var statusLines: [String] = []

    var showHelp: Bool = false
    var showSettings: Bool = true

    // MARK: - Services

    private let inspector = TrackInspector()
    private let extractor = AudioExtractor()
    private var processingTask: Task<Void, Never>?
    private static let maxLogLines = 2_000

    // MARK: - Computed

    var canProcess: Bool {
        sourceURL != nil && !selectedIDs.isEmpty && !isProcessing && !isInspecting
    }

    var selectedTracks: [AudioTrack] {
        tracks.filter { selectedIDs.contains($0.id) }
    }

    var hasOutput: Bool {
        !outputURLs.isEmpty
    }

    // MARK: - Drag & Drop

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        let supportedTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .data]

        for type in supportedTypes {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                    Task { @MainActor in
                        if let url = item as? URL {
                            await self.loadFile(url: url)
                        } else if let data = item as? Data,
                                  let url = URL(dataRepresentation: data, relativeTo: nil) {
                            await self.loadFile(url: url)
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    func loadFile(url: URL) async {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            errorMessage = "Cannot read \"\(url.lastPathComponent)\". Check file permissions."
            return
        }

        // Reset state
        reset()
        sourceURL = url
        movieTitle = url.deletingPathExtension().lastPathComponent
        isInspecting = true
        log = ["Inspecting \(url.lastPathComponent)…"]

        do {
            let foundTracks = try await inspector.inspect(url: url)
            tracks = foundTracks
            // Default: select English tracks; if none, select all
            let englishIDs = Set(foundTracks.filter { $0.isEnglish }.map { $0.id })
            selectedIDs = englishIDs.isEmpty ? Set(foundTracks.map { $0.id }) : englishIDs
            log.append("Found \(foundTracks.count) audio track(s).")
        } catch {
            errorMessage = error.localizedDescription
            log.append("Error: \(error.localizedDescription)")
        }

        isInspecting = false
    }

    // MARK: - Processing

    func startProcessing() {
        guard canProcess else { return }
        processingTask = Task { await process() }
    }

    func cancelProcessing() {
        processingTask?.cancel()
    }

    private func process() async {
        guard let url = sourceURL, !selectedTracks.isEmpty else { return }

        isProcessing = true
        outputURLs = []
        statusLines = []
        log.append("")
        log.append("Starting export…")
        statusLines.append("Starting export…")

        let selected = selectedTracks
        let extractSettings = ExtractionSettings(
            outputMode: settings.outputMode,
            m4aBitrate: settings.m4aBitrate.rawValue,
            levelRiding: settings.levelRiding,
            levelAggressiveness: settings.levelAggressiveness,
            loudnormEnabled: settings.loudnormEnabled,
            loudnormTarget: settings.loudnormTarget
        )
        let outputDir = settings.resolvedOutputDir

        do {
            let urls = try await extractor.extract(
                sourceURL: url,
                tracks: selected,
                settings: extractSettings,
                outputDir: outputDir,
                logLine: { [weak self] line in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.log.count >= Self.maxLogLines { self.log.removeFirst() }
                        self.log.append(line)
                        let t = line.trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("---") || t.hasPrefix("Done:")
                            || t.contains("loudnorm: analyzing")
                            || t.contains("loudnorm: normalizing")
                            || t.hasPrefix("measured:")
                            || t.hasPrefix("Warning:")
                            || t.hasPrefix("Error:") {
                            self.statusLines.append(t)
                        }
                    }
                }
            )
            outputURLs = urls
            log.append("")
            log.append("Export complete. \(urls.count) file(s) written.")
            statusLines.append("Export complete — \(urls.count) file(s) written.")
        } catch is CancellationError {
            log.append("Processing cancelled.")
            statusLines.append("Cancelled.")
        } catch {
            if Task.isCancelled {
                log.append("Processing cancelled.")
                statusLines.append("Cancelled.")
            } else {
                errorMessage = error.localizedDescription
                log.append("Error: \(error.localizedDescription)")
                statusLines.append("Error: \(error.localizedDescription)")
            }
        }

        isProcessing = false
        processingTask = nil
    }

    // MARK: - Actions

    func clear() {
        reset()
    }

    func revealInFinder() {
        guard !outputURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputURLs)
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.supportedTypes
        panel.message = "Choose a video file"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await loadFile(url: url)
            }
        }
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Select output folder"

        if panel.runModal() == .OK {
            settings.outputDir = panel.url
        }
    }

    // MARK: - Helpers

    private func reset() {
        sourceURL = nil
        movieTitle = ""
        tracks = []
        selectedIDs = []
        isInspecting = false
        isProcessing = false
        outputURLs = []
        errorMessage = nil
        log = []
        statusLines = []
    }

    static let supportedTypes: [UTType] = {
        var types: [UTType] = [
            .movie, .video, .mpeg4Movie, .quickTimeMovie,
        ]
        // Add by extension for less-common containers
        let extensions = ["mkv", "avi", "ts", "m2ts", "mts", "wmv", "webm", "m4v"]
        for ext in extensions {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        return types
    }()

    static let supportedExtensions: [String] = [
        "mkv", "mp4", "mov", "avi", "m4v", "ts", "m2ts", "wmv", "webm", "mts"
    ]
}
