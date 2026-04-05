import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("FilmStrip Help")
                    .font(.largeTitle.bold())

                Group {
                    helpSection(
                        title: "Getting Started",
                        body: "Drag a video file onto the drop zone, or click \"Open File…\" to browse. FilmStrip will inspect all audio streams using ffprobe."
                    )

                    helpSection(
                        title: "Supported Formats",
                        body: "MKV, MP4, MOV, AVI, M4V, TS, M2TS, MTS, WMV, WebM — any container that ffprobe can read."
                    )

                    helpSection(
                        title: "Track Selection",
                        body: "All detected audio streams are listed with language, codec, channel layout, and bitrate. English tracks are selected by default. Click any row to toggle selection."
                    )

                    helpSection(
                        title: "Output Mode",
                        body: "WAV — exports 44.1 kHz 24-bit stereo PCM.\nM4A — exports 44.1 kHz AAC at the chosen bitrate.\nBoth — exports WAV first, then encodes M4A from the WAV (no quality loss from re-decoding source)."
                    )

                    helpSection(
                        title: "Level Riding",
                        body: "Applies dynaudnorm to reduce dynamic range. Loud sections are attenuated and quiet passages are boosted, closing the gap between the loudest and quietest moments. Higher aggressiveness applies more gain in both directions. Useful for film audio with wide dynamic range."
                    )

                    helpSection(
                        title: "Output Naming",
                        body: "Files are named: {movie-stem}-{language}-track{N}.wav/.m4a\nIf only one track is selected, the track number is omitted.\nExample: film-english-track2.wav"
                    )

                    helpSection(
                        title: "Output Folder",
                        body: "Output defaults to the Desktop. Choose a custom folder in the Settings panel."
                    )

                    helpSection(
                        title: "Bundled ffmpeg",
                        body: "FilmStrip ships with its own ffmpeg and ffprobe — no external installation required."
                    )

                    helpSection(
                        title: "Best Source Codec",
                        body: "When choosing which file to download, prefer source tracks in this order:\n\n1. AAC — best choice. It's the same codec FilmStrip produces for M4A output, so you skip a transcode generation entirely.\n2. E-AC3 (Dolby Digital Plus) — high bitrate, high quality, one generation of conversion.\n3. AC3 (Dolby Digital) — older format with a lower bitrate ceiling, otherwise similar.\n4. DTS — no practical quality advantage over E-AC3.\n\nIf a file carries both AAC and E-AC3 tracks, select the AAC track."
                    )
                }

                Spacer()
            }
            .padding(28)
        }
        .frame(width: 480, height: 560)
    }

    private func helpSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    HelpView()
}
