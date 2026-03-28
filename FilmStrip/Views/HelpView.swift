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
                        body: "Applies dynaudnorm to attenuate loud sections. This is a downward-only process — it never boosts quiet passages. Useful for dialogue tracks with inconsistent levels."
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
