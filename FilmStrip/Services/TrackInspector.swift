import Foundation

actor TrackInspector {

    private static let probeTimeout: TimeInterval = 30

    // MARK: - ffprobe JSON structures

    private struct ProbeOutput: Decodable {
        let streams: [ProbeStream]
    }

    private struct ProbeStream: Decodable {
        let index: Int
        let codecType: String?
        let codecName: String?
        let channels: Int?
        let sampleRate: String?
        let bitRate: String?
        let tags: [String: String]?

        enum CodingKeys: String, CodingKey {
            case index
            case codecType   = "codec_type"
            case codecName   = "codec_name"
            case channels
            case sampleRate  = "sample_rate"
            case bitRate     = "bit_rate"
            case tags
        }
    }

    // MARK: - Public API

    func inspect(url: URL) async throws -> [AudioTrack] {
        let paths = try await FFmpegManager.shared.ensureTools()
        let jsonData = try await runFFprobe(ffprobePath: paths.ffprobe, inputPath: url.path)
        return try parse(jsonData: jsonData)
    }

    // MARK: - Private helpers

    private func runFFprobe(ffprobePath: String, inputPath: String) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_streams",
            inputPath
        ]

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ProcessingError.ffprobeFailed("Could not launch ffprobe: \(error.localizedDescription)")
        }

        let timeoutItem = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.probeTimeout, execute: timeoutItem)
        process.waitUntilExit()
        timeoutItem.cancel()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw ProcessingError.ffprobeFailed("Exit \(process.terminationStatus): \(errMsg)")
        }

        return data
    }

    private func parse(jsonData: Data) throws -> [AudioTrack] {
        let decoder = JSONDecoder()
        let probe: ProbeOutput
        do {
            probe = try decoder.decode(ProbeOutput.self, from: jsonData)
        } catch {
            throw ProcessingError.ffprobeFailed("JSON parse error: \(error.localizedDescription)")
        }

        var audioIndex = 0
        var tracks: [AudioTrack] = []

        for stream in probe.streams {
            guard stream.codecType?.lowercased() == "audio" else { continue }

            let bitRate: Int?
            if let brStr = stream.bitRate, let brVal = Int(brStr) {
                bitRate = brVal
            } else {
                bitRate = nil
            }

            let sampleRate: Int
            if let srStr = stream.sampleRate, let srVal = Int(srStr) {
                sampleRate = srVal
            } else {
                sampleRate = 0
            }

            // Language: check tags for "language" key
            let langCode = stream.tags?["language"]

            // Title: check tags for "title" key; skip if it just repeats the language name
            let rawTitle = stream.tags?["title"]
            let titleValue: String?
            if let t = rawTitle, !t.isEmpty {
                titleValue = t
            } else {
                titleValue = nil
            }

            let track = AudioTrack(
                id: stream.index,
                audioIndex: audioIndex,
                codecName: stream.codecName ?? "unknown",
                channels: stream.channels ?? 0,
                sampleRate: sampleRate,
                bitRate: bitRate,
                languageCode: langCode,
                title: titleValue
            )
            tracks.append(track)
            audioIndex += 1
        }

        return tracks
    }
}
