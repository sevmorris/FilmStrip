import Foundation

// Value-type snapshot of settings passed to the actor
struct ExtractionSettings: Sendable {
    let outputMode: OutputMode
    let m4aBitrate: Int
    let levelRiding: Bool
    let levelAggressiveness: Int   // 1–10
    let loudnormEnabled: Bool
    let loudnormTarget: Double     // LUFS

    /// Maps aggressiveness (1–10) to dynaudnorm p (peak target) value (0.95–0.55).
    var dynaudnormP: Double {
        let t = Double(levelAggressiveness - 1) / 9.0
        return 0.95 - t * 0.40
    }

    /// Maps aggressiveness (1–10) to dynaudnorm m (max gain) value (2.0–10.0).
    /// Values above 1.0 allow quiet passages to be boosted, which is what actually
    /// closes dynamic range — without this, the filter only attenuates loud peaks.
    var dynaudnormM: Double {
        let t = Double(levelAggressiveness - 1) / 9.0
        return 2.0 + t * 8.0
    }
}

private struct LoudnormStats {
    let inputI: String
    let inputTP: String
    let inputLRA: String
    let inputThresh: String
    let targetOffset: String
}

actor AudioExtractor {

    // Kill any ffmpeg process that runs longer than this (handles corrupt/hung files)
    private static let processTimeout: TimeInterval = 300

    // MARK: - Public API

    /// Extract selected tracks from `sourceURL` and write output files to `outputDir`.
    /// Returns list of produced output URLs. Calls `logLine` for progress messages.
    func extract(
        sourceURL: URL,
        tracks: [AudioTrack],
        settings: ExtractionSettings,
        outputDir: URL,
        logLine: @Sendable @escaping (String) -> Void
    ) async throws -> [URL] {
        guard !tracks.isEmpty else {
            throw ProcessingError.noTracksSelected
        }

        let paths = try await FFmpegManager.shared.ensureTools()
        let fm = FileManager.default
        var outputURLs: [URL] = []

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let omitTrackNumber = tracks.count == 1

        for track in tracks {
            try Task.checkCancellation()

            let langSlug = track.displayLanguage
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
            let trackSuffix = omitTrackNumber ? "" : "-track\(track.id)"
            let baseName = "\(stem)-\(langSlug)\(trackSuffix)"

            logLine("--- Track \(track.id): \(track.displayLanguage) (\(track.displayCodec) \(track.displayChannels)) ---")

            // Work in a per-track temp dir; always cleaned up on exit
            let tempDir = try makeTempDir(baseName: baseName)
            defer {
                do {
                    try fm.removeItem(at: tempDir)
                } catch {
                    let nsErr = error as NSError
                    if !(nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileNoSuchFileError) {
                        logLine("Warning: could not remove temp dir \(tempDir.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }

            // Step 1: Extract to raw WAV
            let rawWAV = tempDir.appendingPathComponent("raw.wav")
            try await extractToWAV(
                ffmpegPath: paths.ffmpeg,
                inputURL: sourceURL,
                audioIndex: track.audioIndex,
                levelRiding: settings.levelRiding,
                levelP: settings.dynaudnormP,
                levelM: settings.dynaudnormM,
                outputURL: rawWAV,
                logLine: logLine
            )

            // Step 2: Optional loudness normalization
            try Task.checkCancellation()
            let processedWAV: URL
            if settings.loudnormEnabled {
                let normWAV = tempDir.appendingPathComponent("norm.wav")
                try await normalizeLoudness(
                    ffmpegPath: paths.ffmpeg,
                    inputURL: rawWAV,
                    outputURL: normWAV,
                    target: settings.loudnormTarget,
                    logLine: logLine
                )
                processedWAV = normWAV
            } else {
                processedWAV = rawWAV
            }

            // Step 3: Deliver final output(s)
            try Task.checkCancellation()
            switch settings.outputMode {
            case .wav:
                let finalURL = outputDir.appendingPathComponent("\(baseName).wav")
                try? fm.removeItem(at: finalURL)
                try fm.copyItem(at: processedWAV, to: finalURL)
                outputURLs.append(finalURL)

            case .m4a:
                let finalURL = outputDir.appendingPathComponent("\(baseName).m4a")
                try await encodeToM4A(
                    ffmpegPath: paths.ffmpeg,
                    inputURL: processedWAV,
                    bitrate: settings.m4aBitrate,
                    outputURL: finalURL,
                    logLine: logLine
                )
                if !fm.fileExists(atPath: finalURL.path) { throw ProcessingError.outputMissing }
                outputURLs.append(finalURL)

            case .both:
                let wavFinal = outputDir.appendingPathComponent("\(baseName).wav")
                try? fm.removeItem(at: wavFinal)
                try fm.copyItem(at: processedWAV, to: wavFinal)
                outputURLs.append(wavFinal)

                let m4aFinal = outputDir.appendingPathComponent("\(baseName).m4a")
                try await encodeToM4A(
                    ffmpegPath: paths.ffmpeg,
                    inputURL: wavFinal,
                    bitrate: settings.m4aBitrate,
                    outputURL: m4aFinal,
                    logLine: logLine
                )
                if !fm.fileExists(atPath: m4aFinal.path) { throw ProcessingError.outputMissing }
                outputURLs.append(m4aFinal)
            }

            logLine("Done: \(baseName)")
        }

        return outputURLs
    }

    // MARK: - Private helpers

    private func makeTempDir(baseName: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("FilmStrip_\(baseName)_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ProcessingError.tempDirectoryFailed
        }
        return dir
    }

    private func extractToWAV(
        ffmpegPath: String,
        inputURL: URL,
        audioIndex: Int,
        levelRiding: Bool,
        levelP: Double,
        levelM: Double,
        outputURL: URL,
        logLine: @Sendable @escaping (String) -> Void
    ) async throws {
        // Remove existing output if present
        try? FileManager.default.removeItem(at: outputURL)

        // Build audio filter chain
        var filters: [String] = []
        if levelRiding {
            let pStr = String(format: "%.2f", levelP)
            let mStr = String(format: "%.1f", levelM)
            filters.append("dynaudnorm=p=\(pStr):m=\(mStr):g=31")
        }
        filters.append("aresample=44100")
        filters.append("aformat=channel_layouts=stereo")
        let afValue = filters.joined(separator: ",")

        let args: [String] = [
            "-y",
            "-i", inputURL.path,
            "-map", "0:a:\(audioIndex)",
            "-af", afValue,
            "-ac", "2",
            "-c:a", "pcm_s24le",
            outputURL.path
        ]

        logLine("ffmpeg \(args.joined(separator: " "))")
        try await runFFmpeg(ffmpegPath: ffmpegPath, arguments: args, logLine: logLine)
    }

    private func normalizeLoudness(
        ffmpegPath: String,
        inputURL: URL,
        outputURL: URL,
        target: Double,
        logLine: @Sendable @escaping (String) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        // Pass 1: analysis
        logLine("  loudnorm: analyzing…")
        let analyzeAf = "loudnorm=I=\(target):TP=-1.0:LRA=20:print_format=json"
        let analysisOutput = try await runFFmpegCapture(
            ffmpegPath: ffmpegPath,
            arguments: ["-y", "-i", inputURL.path, "-af", analyzeAf, "-f", "null", "/dev/null"]
        )

        let stats = try parseLoudnormStats(analysisOutput)
        logLine("  measured: \(stats.inputI) LUFS  |  TP \(stats.inputTP) dBTP  |  LRA \(stats.inputLRA) LU")
        logLine("  target: \(target) LUFS")

        // Pass 2: normalize with measured values
        logLine("  loudnorm: normalizing…")
        let normAf = "loudnorm=I=\(target):TP=-1.0:LRA=20:measured_I=\(stats.inputI):measured_TP=\(stats.inputTP):measured_LRA=\(stats.inputLRA):measured_thresh=\(stats.inputThresh):offset=\(stats.targetOffset):linear=true"
        let args: [String] = [
            "-y",
            "-i", inputURL.path,
            "-af", normAf,
            "-ac", "2",
            "-ar", "44100",
            "-c:a", "pcm_s24le",
            outputURL.path
        ]

        logLine("ffmpeg \(args.joined(separator: " "))")
        try await runFFmpeg(ffmpegPath: ffmpegPath, arguments: args, logLine: logLine)
    }

    private func encodeToM4A(
        ffmpegPath: String,
        inputURL: URL,
        bitrate: Int,
        outputURL: URL,
        logLine: @Sendable @escaping (String) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let args: [String] = [
            "-y",
            "-i", inputURL.path,
            "-c:a", "aac",
            "-b:a", "\(bitrate)k",
            "-ar", "44100",
            outputURL.path
        ]

        logLine("ffmpeg \(args.joined(separator: " "))")
        try await runFFmpeg(ffmpegPath: ffmpegPath, arguments: args, logLine: logLine)
    }

    private func runFFmpeg(
        ffmpegPath: String,
        arguments: [String],
        logLine: @Sendable @escaping (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        let handle = errPipe.fileHandleForReading
        let lock = NSLock()
        var partial = ""
        var lastErrorLine = ""

        // Drain stderr in real-time — without this, the 64 KB pipe buffer fills
        // on long files and ffmpeg blocks, truncating output.
        handle.readabilityHandler = { fh in
            guard let text = String(data: fh.availableData, encoding: .utf8),
                  !text.isEmpty else { return }
            let lines = lock.withLock { () -> [String] in
                let combined = partial + text
                var parts = combined.components(separatedBy: "\n")
                partial = parts.removeLast()
                return parts
            }
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty {
                    logLine(t)
                    // Track the last ffmpeg error line for the failure alert
                    if t.hasPrefix("Error") || t.hasPrefix("error") || t.contains(": No such") {
                        lock.withLock { lastErrorLine = t }
                    }
                }
            }
        }

        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }

                process.terminationHandler = { proc in
                    timeoutItem.cancel()
                    handle.readabilityHandler = nil
                    // Drain any bytes that arrived between the last handler call and process exit
                    let trailing = handle.availableData
                    let leftover: String = lock.withLock {
                        if !trailing.isEmpty, let s = String(data: trailing, encoding: .utf8) {
                            return partial + s
                        }
                        return partial
                    }
                    let t = leftover.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { logLine(t) }

                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let msg = lock.withLock {
                            lastErrorLine.isEmpty
                                ? "Exit \(proc.terminationStatus) — check log for details"
                                : lastErrorLine
                        }
                        continuation.resume(throwing: ProcessingError.ffmpegFailed(
                            code: proc.terminationStatus,
                            message: msg
                        ))
                    }
                }

                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.processTimeout, execute: timeoutItem)
                } catch {
                    timeoutItem.cancel()
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: ProcessingError.ffmpegFailed(
                        code: -1,
                        message: error.localizedDescription
                    ))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private func runFFmpegCapture(
        ffmpegPath: String,
        arguments: [String]
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        let handle = errPipe.fileHandleForReading
        let lock = NSLock()
        var accumulated = Data()

        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            lock.withLock { accumulated.append(data) }
        }

        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }

                process.terminationHandler = { proc in
                    timeoutItem.cancel()
                    handle.readabilityHandler = nil
                    // Drain any bytes that arrived between the last handler call and process exit
                    let trailing = handle.availableData
                    let text: String = lock.withLock {
                        if !trailing.isEmpty { accumulated.append(trailing) }
                        return String(data: accumulated, encoding: .utf8) ?? ""
                    }

                    if proc.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: ProcessingError.ffmpegFailed(
                            code: proc.terminationStatus,
                            message: text.isEmpty ? "Exit code \(proc.terminationStatus)" : text
                        ))
                    }
                }

                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.processTimeout, execute: timeoutItem)
                } catch {
                    timeoutItem.cancel()
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: ProcessingError.ffmpegFailed(
                        code: -1,
                        message: error.localizedDescription
                    ))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private func parseLoudnormStats(_ output: String) throws -> LoudnormStats {
        // Find the last '{' (start of the JSON block), then scan forward to its matching '}'
        guard let braceRange = output.range(of: "{", options: .backwards) else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Could not parse loudnorm analysis output")
        }

        var depth = 0
        var jsonEnd: String.Index?
        outer: for idx in output[braceRange.lowerBound...].indices {
            switch output[idx] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { jsonEnd = idx; break outer }
            default: break
            }
        }

        guard let jsonEnd else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Could not parse loudnorm analysis output")
        }

        let jsonStr = String(output[braceRange.lowerBound...jsonEnd])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: String] else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Invalid loudnorm JSON output")
        }

        guard let inputI = dict["input_i"],
              let inputTP = dict["input_tp"],
              let inputLRA = dict["input_lra"],
              let inputThresh = dict["input_thresh"],
              let targetOffset = dict["target_offset"] else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Missing loudnorm measurement fields")
        }

        return LoudnormStats(
            inputI: inputI,
            inputTP: inputTP,
            inputLRA: inputLRA,
            inputThresh: inputThresh,
            targetOffset: targetOffset
        )
    }
}
