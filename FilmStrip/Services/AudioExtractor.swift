import Foundation

// Value-type snapshot of settings passed to the actor
struct ExtractionSettings: Sendable {
    let outputMode: OutputMode
    let m4aBitrate: Int
    let highPassFilter: Bool
    let levelRiding: Bool
    let levelAggressiveness: Int   // 1–10
    let dialogGuard: Bool
    let dialogLevel: DialogLevel
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

    // Kill any ffmpeg process that runs longer than this (handles corrupt/hung files).
    // 30 minutes — a 50 GB MKV with two-pass loudnorm + M4A encoding takes 10–20 min on fast hardware.
    private static let processTimeout: TimeInterval = 1800

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
                ffprobePath: paths.ffprobe,
                inputURL: sourceURL,
                audioIndex: track.audioIndex,
                channels: track.channels,
                highPassFilter: settings.highPassFilter,
                levelRiding: settings.levelRiding,
                levelP: settings.dynaudnormP,
                levelM: settings.dynaudnormM,
                dialogGuard: settings.dialogGuard,
                dialogLevel: settings.dialogLevel,
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
            try checkDiskSpace(outputDir: outputDir, processedWAV: processedWAV, mode: settings.outputMode, m4aBitrate: settings.m4aBitrate)
            switch settings.outputMode {
            case .wav:
                let finalURL = uniqueOutputURL(outputDir.appendingPathComponent("\(baseName).wav"), fm: fm)
                do {
                    try fm.copyItem(at: processedWAV, to: finalURL)
                } catch {
                    try? fm.removeItem(at: finalURL)
                    throw error
                }
                outputURLs.append(finalURL)

            case .m4a:
                let finalURL = uniqueOutputURL(outputDir.appendingPathComponent("\(baseName).m4a"), fm: fm)
                do {
                    try await encodeToM4A(
                        ffmpegPath: paths.ffmpeg,
                        inputURL: processedWAV,
                        bitrate: settings.m4aBitrate,
                        outputURL: finalURL,
                        logLine: logLine
                    )
                } catch {
                    try? fm.removeItem(at: finalURL)
                    throw error
                }
                if !fm.fileExists(atPath: finalURL.path) { throw ProcessingError.outputMissing }
                outputURLs.append(finalURL)

            case .both:
                let wavFinal = uniqueOutputURL(outputDir.appendingPathComponent("\(baseName).wav"), fm: fm)
                do {
                    try fm.copyItem(at: processedWAV, to: wavFinal)
                } catch {
                    try? fm.removeItem(at: wavFinal)
                    throw error
                }

                let m4aFinal = uniqueOutputURL(outputDir.appendingPathComponent("\(baseName).m4a"), fm: fm)
                do {
                    try await encodeToM4A(
                        ffmpegPath: paths.ffmpeg,
                        inputURL: wavFinal,
                        bitrate: settings.m4aBitrate,
                        outputURL: m4aFinal,
                        logLine: logLine
                    )
                } catch {
                    // WAV was not yet added to outputURLs, clean up both
                    try? fm.removeItem(at: wavFinal)
                    try? fm.removeItem(at: m4aFinal)
                    throw error
                }
                if !fm.fileExists(atPath: m4aFinal.path) { throw ProcessingError.outputMissing }
                // Both files succeeded — append together
                outputURLs.append(wavFinal)
                outputURLs.append(m4aFinal)
            }

            logLine("Done: \(baseName)")
        }

        return outputURLs
    }

    // MARK: - Private helpers

    /// Removes any FilmStrip temp directories left behind by previous crashes.
    /// Called once at app launch before any processing begins.
    func cleanStaleTempDirs() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("FilmStrip_") {
            try? fm.removeItem(at: url)
        }
    }

    private func checkDiskSpace(outputDir: URL, processedWAV: URL, mode: OutputMode, m4aBitrate: Int) throws {
        let wavSize = (try? FileManager.default.attributesOfItem(atPath: processedWAV.path)[.size] as? Int64) ?? 0
        // For M4A-only, estimate from bitrate and WAV duration (WAV is 24-bit 44.1 kHz stereo = 264,600 bytes/sec)
        let estimatedM4ASize: Int64 = wavSize > 0 ? max(Int64(Double(wavSize) / 264_600 * Double(m4aBitrate) * 125), 1_048_576) : 10_485_760
        let needed: Int64 = switch mode {
        case .wav:  wavSize
        case .m4a:  estimatedM4ASize
        case .both: wavSize + estimatedM4ASize
        }

        let available = (try? outputDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        // Add 10% headroom
        if Int64(available) < needed + needed / 10 {
            throw ProcessingError.insufficientDiskSpace(needed: needed, available: Int64(available))
        }
    }

    /// Returns `url` unchanged if no file exists there; otherwise appends ` (1)`, ` (2)`, …
    /// until a non-colliding path is found. Never silently deletes existing output.
    private func uniqueOutputURL(_ url: URL, fm: FileManager = .default) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension
        let dir  = url.deletingLastPathComponent()
        var counter = 1
        while true {
            let candidate = dir.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

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
        ffprobePath: String,
        inputURL: URL,
        audioIndex: Int,
        channels: Int,
        highPassFilter: Bool,
        levelRiding: Bool,
        levelP: Double,
        levelM: Double,
        dialogGuard: Bool,
        dialogLevel: DialogLevel,
        outputURL: URL,
        logLine: @Sendable @escaping (String) -> Void
    ) async throws {
        // Remove existing output if present
        try? FileManager.default.removeItem(at: outputURL)

        // Dialog Guard: for standard 5.1/7.1 sources, split out the center channel
        // (FC, always index 2), apply a fast-reacting dynaudnorm specifically to it,
        // then reassemble before the normal downmix.
        let useDialogGuard = dialogGuard && (channels == 6 || channels == 8)

        // Probe duration up front — required for mirror padding around any dynaudnorm
        // step. dynaudnorm's Gaussian smoothing window extends past the file boundary,
        // and silence-padding it doesn't help (silent frames get gain=1.0 which still
        // skews the smoothed average). Mirror padding (reversed copies of the first/
        // last 16s) gives the smoothing window real audio with matching gain values.
        let duration: Double? = (levelRiding || useDialogGuard)
            ? (try? await probeAudioDuration(ffprobePath: ffprobePath, inputURL: inputURL))
            : nil
        if (levelRiding || useDialogGuard) && duration == nil {
            logLine("Warning: could not determine duration; dynaudnorm boundary fix skipped (start/end may have ramp artifacts)")
        }

        // Pre-dynaudnorm filters (run on the merged signal, before level riding).
        // 80 Hz / 4-pole HPF (two cascaded 2-pole biquads = 24 dB/oct) — removes
        // cinema LFE fold-in and low-frequency rumble. Steeper slope kills 40 Hz
        // by −24 dB while leaving 100 Hz nearly untouched, so dialogue and music
        // body stay intact while the sub-bass that crowds the host voice is gone.
        // Applied before level riding so the compressor operates on the filtered
        // signal rather than chasing sub-bass energy.
        let highPassChain = highPassFilter ? "highpass=f=80,highpass=f=80" : nil

        // Level riding dynaudnorm filter (applied to the merged signal after highpass).
        let lrFilter: String? = levelRiding
            ? "dynaudnorm=p=\(String(format: "%.2f", levelP)):m=\(String(format: "%.1f", levelM)):g=31"
            : nil

        // Post-dynaudnorm filters (downmix, resample, format, limit).
        // Explicit downmix for surround sources — preserves center-channel dialog.
        // FFmpeg's default Lo-Ro matrix (used by bare -ac 2) attenuates the center
        // channel by −3 dB before summing into L/R. The pan filter below folds FC at
        // unity and surrounds at 0.707 (5.1) / 0.5 (7.1 sides) so dialog sits at the
        // same level as the original mix. For Boost/Strong, all coefficients are
        // divided by centerWeight: FC stays at 1.0 (no peak escalation into the
        // alimiter) while surrounds are attenuated proportionally, shifting the
        // FC-vs-surround ratio. Loudnorm restores absolute level afterwards.
        let inv = 1.0 / dialogLevel.centerWeight
        let fc = String(format: "%.3f", 1.0)
        let lr = String(format: "%.3f", 0.707 * inv)
        let sd = String(format: "%.3f", 0.5 * inv)
        var postFilters: [String] = []
        if channels == 6 {
            postFilters.append("pan=stereo|FL=\(fc)*FC+\(lr)*FL+\(lr)*BL|FR=\(fc)*FC+\(lr)*FR+\(lr)*BR")
        } else if channels >= 8 {
            postFilters.append("pan=stereo|FL=\(fc)*FC+\(lr)*FL+\(lr)*BL+\(sd)*SL|FR=\(fc)*FC+\(lr)*FR+\(lr)*BR+\(sd)*SR")
        }
        // SoX resampler: measurably better alias rejection than the default for 48→44.1 kHz.
        postFilters.append("aresample=44100")
        postFilters.append("aformat=channel_layouts=stereo")
        // Brick-wall limiter after downmix — prevents clipping on hot multichannel
        // sources (DTS, E-AC3) where the downmix matrix can sum above 0 dBFS.
        // level=false: no makeup gain. attack=5ms catches transients.
        postFilters.append("alimiter=limit=0.99:attack=5:release=50:level=false")
        let postChain = postFilters.joined(separator: ",")

        let args: [String]
        if !useDialogGuard && lrFilter == nil {
            // Simplest path: no dynaudnorm anywhere, just preprocess + downmix + limit.
            // No filter_complex needed; no mirror padding needed.
            let chain = [highPassChain, postChain].compactMap { $0 }.joined(separator: ",")
            args = [
                "-y",
                "-i", inputURL.path,
                "-map", "0:a:\(audioIndex)",
                "-af", chain,
                "-c:a", "pcm_s24le",
                outputURL.path
            ]
        } else {
            // Build a filter_complex that wraps each dynaudnorm in mirror padding
            // (when duration is known). Stages: optional channelsplit → DG dynaudnorm
            // on FC → amerge → highpass → LR dynaudnorm → downmix → limit.
            var chains: [String] = []
            var lastLabel = "0:a:\(audioIndex)"

            if useDialogGuard {
                let layout = channels == 8 ? "7.1" : "5.1"
                let n = channels
                let splitLabels = (0..<n).map { "[dgc\($0)]" }.joined()
                chains.append("[\(lastLabel)]channelsplit=channel_layout=\(layout)\(splitLabels)")

                let dgM = String(format: "%.0f", dialogLevel.dialogGuardM)
                let dgFilter = "dynaudnorm=p=0.88:m=\(dgM):g=15"
                // ffmpeg 8.0: channelsplit outputs lose channel layout metadata; aformat=mono
                // restores it so amerge can identify each stream's channel assignment.
                if let d = duration {
                    chains.append(contentsOf: mirrorPaddedDynaudnormChains(
                        inputLabel: "dgc2", outputLabel: "dgcraw", prefix: "dg",
                        duration: d, dynaudnormFilter: dgFilter
                    ))
                    chains.append("[dgcraw]aformat=channel_layouts=mono[dgcn]")
                } else {
                    chains.append("[dgc2]\(dgFilter),aformat=channel_layouts=mono[dgcn]")
                }
                for i in 0..<n where i != 2 {
                    chains.append("[dgc\(i)]aformat=channel_layouts=mono[dgcm\(i)]")
                }
                let mergeInputs = (0..<n).map { $0 == 2 ? "[dgcn]" : "[dgcm\($0)]" }.joined()
                chains.append("\(mergeInputs)amerge=inputs=\(n)[merged]")
                lastLabel = "merged"
            }

            if let hp = highPassChain {
                chains.append("[\(lastLabel)]\(hp)[posthp]")
                lastLabel = "posthp"
            }

            if let lf = lrFilter {
                if let d = duration {
                    chains.append(contentsOf: mirrorPaddedDynaudnormChains(
                        inputLabel: lastLabel, outputLabel: "postlr", prefix: "lr",
                        duration: d, dynaudnormFilter: lf
                    ))
                } else {
                    chains.append("[\(lastLabel)]\(lf)[postlr]")
                }
                lastLabel = "postlr"
            }

            chains.append("[\(lastLabel)]\(postChain)[aout]")
            let filterComplex = chains.joined(separator: ";")

            args = [
                "-y",
                "-i", inputURL.path,
                "-filter_complex", filterComplex,
                "-map", "[aout]",
                "-c:a", "pcm_s24le",
                outputURL.path
            ]
        }

        logLine("ffmpeg " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        try await runFFmpeg(ffmpegPath: ffmpegPath, arguments: args, logLine: logLine)
    }

    /// Returns the chain segments that wrap a dynaudnorm filter in mirror padding.
    /// Caller must join with ";" — each element is one chain in the filter_complex graph.
    private func mirrorPaddedDynaudnormChains(
        inputLabel: String,
        outputLabel: String,
        prefix p: String,
        duration: Double,
        dynaudnormFilter: String
    ) -> [String] {
        let padDur = min(16.0, duration)
        let tStart = max(0.0, duration - padDur)
        let pad = String(format: "%.6f", padDur)
        let ts = String(format: "%.6f", tStart)
        let dur = String(format: "%.6f", duration)
        return [
            "[\(inputLabel)]asplit=3[\(p)h][\(p)m][\(p)t]",
            "[\(p)h]atrim=duration=\(pad),areverse,asetpts=PTS-STARTPTS[\(p)head]",
            "[\(p)m]asetpts=PTS-STARTPTS[\(p)body]",
            "[\(p)t]atrim=start=\(ts),areverse,asetpts=PTS-STARTPTS[\(p)tail]",
            "[\(p)head][\(p)body][\(p)tail]concat=n=3:v=0:a=1,\(dynaudnormFilter)," +
                "atrim=start=\(pad):duration=\(dur),asetpts=PTS-STARTPTS[\(outputLabel)]"
        ]
    }

    /// Probes the container's reported duration in seconds. Returns nil on any failure;
    /// callers should fall back gracefully (mirror padding will be skipped).
    private func probeAudioDuration(ffprobePath: String, inputURL: URL) async throws -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            inputURL.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessingError.ffprobeFailed("Could not launch ffprobe for duration probe: \(error.localizedDescription)")
        }

        let timeoutItem = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        // 60s is plenty — duration probe reads only container headers.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeoutItem)
        process.waitUntilExit()
        timeoutItem.cancel()

        guard process.terminationStatus == 0 else {
            throw ProcessingError.ffprobeFailed("Duration probe exited \(process.terminationStatus)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let d = Double(str), d > 0 else {
            throw ProcessingError.ffprobeFailed("Duration probe returned invalid value: \(str.isEmpty ? "<empty>" : str)")
        }
        return d
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

        logLine("ffmpeg " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
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

        logLine("ffmpeg " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
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

        // Wrapped in a class so closures on different dispatch queues can mutate
        // them safely — the NSLock above guards all accesses.
        final class _State: @unchecked Sendable { var partial = ""; var lastErrorLine = "" }
        let state = _State()

        // Drain stderr in real-time — without this, the 64 KB pipe buffer fills
        // on long files and ffmpeg blocks, truncating output.
        handle.readabilityHandler = { fh in
            guard let text = String(data: fh.availableData, encoding: .utf8),
                  !text.isEmpty else { return }
            let lines = lock.withLock { () -> [String] in
                let combined = state.partial + text
                var parts = combined.components(separatedBy: "\n")
                state.partial = parts.removeLast()
                return parts
            }
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty {
                    logLine(t)
                    // Accumulate the last 3 error lines so the failure alert has context.
                    if t.hasPrefix("Error") || t.hasPrefix("error") || t.contains(": No such") {
                        lock.withLock {
                            let lines = state.lastErrorLine.isEmpty
                                ? []
                                : state.lastErrorLine.components(separatedBy: "\n")
                            state.lastErrorLine = (lines.suffix(2) + [t]).joined(separator: "\n")
                        }
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
                            return state.partial + s
                        }
                        return state.partial
                    }
                    let t = leftover.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { logLine(t) }

                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let msg = lock.withLock {
                            state.lastErrorLine.isEmpty
                                ? "Exit \(proc.terminationStatus) — check log for details"
                                : state.lastErrorLine
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
            handle.readabilityHandler = nil
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

        final class _CaptureState: @unchecked Sendable { var accumulated = Data() }
        let state = _CaptureState()

        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            lock.withLock { state.accumulated.append(data) }
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
                        if !trailing.isEmpty { state.accumulated.append(trailing) }
                        return String(data: state.accumulated, encoding: .utf8) ?? ""
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
            handle.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
    }

    private func parseLoudnormStats(_ output: String) throws -> LoudnormStats {
        // ffmpeg appends a JSON block at the end of loudnorm analysis output.
        // Find the last '{' and scan forward to its matching '}'.
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
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProcessingError.ffmpegFailed(code: -1, message: "Invalid loudnorm JSON encoding")
        }

        func field(_ key: String) throws -> String {
            guard let v = obj[key] as? String else {
                throw ProcessingError.ffmpegFailed(code: -1, message: "Missing loudnorm field: \(key)")
            }
            return v
        }

        return LoudnormStats(
            inputI:       try field("input_i"),
            inputTP:      try field("input_tp"),
            inputLRA:     try field("input_lra"),
            inputThresh:  try field("input_thresh"),
            targetOffset: try field("target_offset")
        )
    }
}
