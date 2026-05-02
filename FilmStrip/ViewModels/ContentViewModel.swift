import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class ContentViewModel {

    // MARK: - State

    var items: [QueueItem] = []
    var settings = FilmStripSettings()
    var isProcessing: Bool = false
    var errorMessage: String?
    var log: [String] = []
    var statusLines: [String] = []
    var showHelp: Bool = false
    var showSettings: Bool = true

    // MARK: - Services

    private let inspector = TrackInspector()
    private let extractor = AudioExtractor()
    private var processingTask: Task<Void, Never>?
    private var processingCancelled = false
    private var inspectionTasks: [UUID: Task<Void, Never>] = [:]
    private static let maxLogLines = 2_000

    init() {
        Task {
            do {
                _ = try await FFmpegManager.shared.ensureTools()
            } catch {
                self.errorMessage = "FFmpeg tools not found — the app bundle may be corrupt. Please reinstall FilmStrip."
                return
            }
            if settings.outputDirWasReset {
                self.errorMessage = "Your saved output folder is no longer accessible. Please choose a new one before processing."
            }
            await extractor.cleanStaleTempDirs()
        }
    }

    // MARK: - Computed

    var canProcess: Bool {
        !isProcessing && items.contains { if case .ready = $0.status { return true }; return false }
    }

    var hasOutput: Bool {
        items.contains { !$0.outputURLs.isEmpty }
    }

    // MARK: - File Input

    func addFiles(_ urls: [URL]) {
        let valid = urls.filter {
            $0.isFileURL &&
            ContentViewModel.supportedExtensions.contains($0.pathExtension.lowercased())
        }

        var addedAny = false
        for url in valid {
            guard !items.contains(where: { $0.url == url }) else { continue }
            var item = QueueItem(url: url)
            item.status = .inspecting
            items.append(item)
            let id = item.id
            inspectionTasks[id] = Task { await self.inspect(itemID: id, url: url) }
            addedAny = true
        }

        let unsupported = urls.filter {
            $0.isFileURL &&
            !ContentViewModel.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        if !addedAny && !unsupported.isEmpty {
            let exts = Set(unsupported.map { ".\($0.pathExtension.lowercased())" }).sorted().joined(separator: ", ")
            errorMessage = "Unsupported file type\(unsupported.count == 1 ? "" : "s"): \(exts)"
        }
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        var url: URL?
                        if let u = item as? URL {
                            url = u
                        } else if let data = item as? Data {
                            if let u = URL(dataRepresentation: data, relativeTo: nil) {
                                url = u
                            } else if let str = String(data: data, encoding: .utf8),
                                      let u = URL(string: str) {
                                url = u
                            }
                        }
                        if let url { self.addFiles([url]) }
                    }
                }
            }
        }
        return true
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.supportedTypes
        panel.message = "Choose video files"

        if panel.runModal() == .OK {
            addFiles(panel.urls)
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

    // MARK: - Processing

    func startProcessing() {
        guard canProcess else { return }
        if settings.outputDir == nil {
            chooseOutputDir()
            guard settings.outputDir != nil else { return }
        }
        processingCancelled = false
        processingTask = Task { await processQueue() }
    }

    func cancelProcessing() {
        processingCancelled = true
        processingTask?.cancel()
    }

    private func processQueue() async {
        isProcessing = true
        log.append("")
        log.append("Starting export…")
        appendStatus("Starting export…")

        let readyIDs = items.compactMap { item -> UUID? in
            if case .ready = item.status { return item.id }
            return nil
        }

        for id in readyIDs {
            if Task.isCancelled { break }
            await processItem(id: id)
        }

        let doneCount = items.filter { $0.status == .done }.count
        if Task.isCancelled {
            log.append("")
            log.append("Processing cancelled.")
            appendStatus("Processing cancelled.")
        } else if doneCount > 0 {
            log.append("")
            log.append("Export complete. \(doneCount) file\(doneCount == 1 ? "" : "s") processed.")
            appendStatus("Export complete — \(doneCount) file\(doneCount == 1 ? "" : "s") processed.")
        }

        isProcessing = false
        processingTask = nil
    }

    private func processItem(id: UUID) async {
        guard let idx = items.firstIndex(where: { $0.id == id }),
              case .ready = items[idx].status else { return }

        let item = items[idx]
        let tracks = item.selectedTracks
        guard !tracks.isEmpty else { return }

        items[idx].status = .processing

        let url = item.url
        let extractSettings = ExtractionSettings(
            outputMode: settings.outputMode,
            m4aBitrate: settings.m4aBitrate.rawValue,
            highPassFilter: settings.highPassFilter,
            levelRiding: settings.levelRiding,
            levelAggressiveness: settings.levelAggressiveness,
            dialogGuard: settings.dialogGuard,
            dialogLevel: settings.dialogLevel,
            loudnormEnabled: settings.loudnormEnabled,
            loudnormTarget: settings.loudnormTarget
        )
        let outputDir = settings.resolvedOutputDir(fallback: url.deletingLastPathComponent())

        log.append("")
        log.append("── \(item.displayName) ──")
        appendStatus("── \(item.displayName) ──")

        do {
            let outputURLs = try await extractor.extract(
                sourceURL: url,
                tracks: tracks,
                settings: extractSettings,
                outputDir: outputDir,
                logLine: { [weak self] line in
                    guard let self else { return }
                    Task { @MainActor [self] in
                        guard !self.processingCancelled else { return }
                        if self.log.count >= Self.maxLogLines { self.log.removeFirst() }
                        self.log.append(line)
                        let t = line.trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("---") || t.hasPrefix("Done:")
                            || t.contains("loudnorm: analyzing")
                            || t.contains("loudnorm: normalizing")
                            || t.hasPrefix("measured:")
                            || t.hasPrefix("Warning:")
                            || t.hasPrefix("Error:") {
                            self.appendStatus(t)
                        }
                    }
                }
            )
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            items[idx].outputURLs = outputURLs
            items[idx].status = .done
            appendStatus("Done: \(item.displayName)")
        } catch is CancellationError {
            guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
            items[idx].status = .ready
            appendStatus("Cancelled.")
        } catch {
            if Task.isCancelled {
                guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
                items[idx].status = .ready
                appendStatus("Cancelled.")
            } else {
                guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
                let msg = error.localizedDescription
                items[idx].status = .failed(msg)
                log.append("Error: \(msg)")
                appendStatus("Error: \(msg)")
            }
        }
    }

    private func appendStatus(_ line: String) {
        if statusLines.count >= Self.maxLogLines { statusLines.removeFirst() }
        statusLines.append(line)
    }

    // MARK: - Inspection

    private func inspect(itemID: UUID, url: URL) async {
        defer { inspectionTasks.removeValue(forKey: itemID) }

        guard !Task.isCancelled else { return }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
            items[idx].status = .failed("Cannot read file. Check permissions.")
            return
        }

        do {
            let tracks = try await inspector.inspect(url: url)
            guard !Task.isCancelled,
                  let idx = items.firstIndex(where: { $0.id == itemID }) else { return }

            // Auto-select logic:
            // 1. Exclude commentary, AD, and impaired tracks from the default selection.
            // 2. Within the remaining English tracks, prefer whichever the container
            //    marks as default (disposition.default). This respects the muxer's intent.
            // 3. If no English tracks exist, fall back to all non-special tracks.
            // 4. If everything is a special type, select all to avoid an empty queue.
            let candidates = tracks.filter { !$0.isSpecialAudio }
            let englishCandidates = candidates.filter { $0.isEnglish }
            let defaultEnglish = englishCandidates.filter { $0.isDefault }

            let selectedIDs: Set<Int>
            let languageUnknown: Bool
            if !defaultEnglish.isEmpty {
                selectedIDs = Set(defaultEnglish.map { $0.id })
                languageUnknown = false
            } else if !englishCandidates.isEmpty {
                selectedIDs = Set(englishCandidates.map { $0.id })
                languageUnknown = false
            } else if !candidates.isEmpty {
                selectedIDs = Set(candidates.map { $0.id })
                languageUnknown = true
            } else {
                selectedIDs = Set(tracks.map { $0.id })
                languageUnknown = true
            }

            let count = selectedIDs.count
            let summary = "\(count) track\(count == 1 ? "" : "s") · \(languageUnknown ? "all selected · no language tag" : "English")"

            items[idx].tracks = tracks
            items[idx].selectedIDs = selectedIDs
            items[idx].trackSummary = summary
            items[idx].languageUnknown = languageUnknown
            items[idx].status = .ready
        } catch is CancellationError {
            // Item was removed before inspection completed; nothing to update.
        } catch {
            guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
            items[idx].status = .failed(error.localizedDescription)
        }
    }

    func toggleTrack(itemID: UUID, trackID: Int) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }),
              case .ready = items[idx].status else { return }
        var selected = items[idx].selectedIDs
        if selected.contains(trackID) {
            guard selected.count > 1 else { return } // keep at least one
            selected.remove(trackID)
        } else {
            selected.insert(trackID)
        }
        items[idx].selectedIDs = selected
        let count = selected.count
        let total = items[idx].tracks.count
        items[idx].trackSummary = "\(count) of \(total) track\(total == 1 ? "" : "s") selected"
    }

    // MARK: - Queue Management

    func removeItem(_ item: QueueItem) {
        guard item.status != .processing else { return }
        inspectionTasks[item.id]?.cancel()
        inspectionTasks.removeValue(forKey: item.id)
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        for task in inspectionTasks.values { task.cancel() }
        inspectionTasks.removeAll()
        items.removeAll()
        log.removeAll()
        statusLines.removeAll()
        errorMessage = nil
    }

    // MARK: - Output

    func revealInFinder(item: QueueItem) {
        guard !item.outputURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(item.outputURLs)
    }

    // MARK: - Supported Types

    static let supportedTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        for ext in ["mkv", "avi", "ts", "m2ts", "mts", "wmv", "webm", "m4v"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    static let supportedExtensions: [String] = [
        "mkv", "mp4", "mov", "avi", "m4v", "ts", "m2ts", "wmv", "webm", "mts"
    ]
}
