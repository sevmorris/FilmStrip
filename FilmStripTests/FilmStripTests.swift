import Testing
import Foundation
@testable import FilmStrip

// MARK: - Filter graph

@Suite("FilterGraphBuilder")
struct FilterGraphBuilderTests {

    private func params(
        channels: Int = 6,
        layout: String? = "5.1",
        highPassFilter: Bool = true,
        dialogGuard: Bool = true,
        levelRiding: Bool = true,
        stereoDialogAssist: Bool = false,
        duration: Double? = 120
    ) -> FilterGraphParams {
        FilterGraphParams(
            audioStreamLabel: "0:a:0",
            channels: channels,
            channelLayout: layout,
            highPassFilter: highPassFilter,
            levelRiding: levelRiding,
            dialogGuard: dialogGuard,
            stereoDialogAssist: stereoDialogAssist,
            duration: duration
        )
    }

    @Test("Surround + LR uses filter_complex with pan before dynaudnorm")
    func surroundLRPostDownmix() {
        let result = FilterGraphBuilder.build(params())
        #expect(result.usesFilterComplex)
        let panRange = result.graph.range(of: "pan=stereo")!
        // Level-riding dynaudnorm uses p=0.90 specifically.
        let dynRange = result.graph.range(of: "dynaudnorm=p=0.90")!
        #expect(panRange.lowerBound < dynRange.lowerBound)
    }

    @Test("Surround LR-only (no DG) uses filter_complex")
    func surroundLROnly() {
        let result = FilterGraphBuilder.build(params(dialogGuard: false))
        #expect(result.usesFilterComplex)
        #expect(result.graph.contains("pan=stereo"))
        #expect(result.graph.contains("dynaudnorm"))
    }

    @Test("Stereo + LR uses simple -af")
    func stereoSimplePath() {
        let result = FilterGraphBuilder.build(params(channels: 2, layout: "stereo", dialogGuard: false, duration: nil))
        #expect(!result.usesFilterComplex)
        #expect(result.graph.contains("dynaudnorm"))
        #expect(result.graph.contains("alimiter"))
    }

    @Test("Stereo Dialog Assist uses mid/side split")
    func stereoDialogAssist() {
        let result = FilterGraphBuilder.build(params(channels: 2, layout: "stereo", dialogGuard: false, stereoDialogAssist: true))
        #expect(result.usesFilterComplex)
        #expect(result.graph.contains("sdamid"))
        #expect(result.graph.contains("sdaside"))
    }

    // The high-pass renames SDA's output label, which once hid it from the
    // resample branch and left pass 1 at the source rate and channel count.
    @Test("Stereo Dialog Assist resamples to 44.1 kHz stereo once, after the high-pass",
          arguments: [1, 2], [true, false])
    func stereoDialogAssistResamples(channels: Int, highPassFilter: Bool) {
        let resample = "aresample=44100,aformat=channel_layouts=stereo"
        for duration in [120, nil] as [Double?] {
            let result = FilterGraphBuilder.build(params(
                channels: channels, layout: channels == 1 ? "mono" : "stereo",
                highPassFilter: highPassFilter, dialogGuard: false,
                stereoDialogAssist: true, duration: duration
            ))
            let hits = result.graph.ranges(of: resample)
            #expect(hits.count == 1, "duration: \(String(describing: duration))")
            if highPassFilter, let hp = result.graph.range(of: "highpass"), let rs = hits.first {
                #expect(hp.lowerBound < rs.lowerBound, "duration: \(String(describing: duration))")
            }
        }
    }

    // Only 6- and 8-channel sources count as surround, and SDA takes only 1 or
    // 2, so these once fell through every resample branch of the filter_complex
    // path and kept the source rate and channel count through pass 1.
    @Test("Other multichannel sources resample to 44.1 kHz stereo once",
          arguments: [(3, "3.0"), (4, "quad"), (5, "5.0"), (7, "6.1")])
    func otherMultichannelResamples(channels: Int, layout: String) {
        let resample = "aresample=44100,aformat=channel_layouts=stereo"
        for duration in [120, nil] as [Double?] {
            let result = FilterGraphBuilder.build(params(
                channels: channels, layout: layout, duration: duration
            ))
            let hits = result.graph.ranges(of: resample)
            #expect(hits.count == 1, "duration: \(String(describing: duration))")
            // filter_complex keeps d6ead7c's order: high-pass, resample, level riding.
            if result.usesFilterComplex, let rs = hits.first,
               let hp = result.graph.range(of: "highpass"),
               let lr = result.graph.range(of: "dynaudnorm=p=0.90") {
                #expect(hp.lowerBound < rs.lowerBound && rs.lowerBound < lr.lowerBound)
            }
        }
    }

    // ffmpeg's channels for each layout, from `ffmpeg -layouts`.
    private static let layoutChannels: [String: Set<String>] = [
        "3.0": ["FL", "FR", "FC"],
        "3.1": ["FL", "FR", "FC", "LFE"],
        "4.0": ["FL", "FR", "FC", "BC"],
        "4.1": ["FL", "FR", "FC", "LFE", "BC"],
        "5.0": ["FL", "FR", "FC", "BL", "BR"],
        "5.0(side)": ["FL", "FR", "FC", "SL", "SR"],
        "5.1": ["FL", "FR", "FC", "LFE", "BL", "BR"],
        "5.1(side)": ["FL", "FR", "FC", "LFE", "SL", "SR"],
        "6.0": ["FL", "FR", "FC", "BC", "SL", "SR"],
        "hexagonal": ["FL", "FR", "FC", "BL", "BR", "BC"],
        "6.1": ["FL", "FR", "FC", "LFE", "BC", "SL", "SR"],
        "6.1(back)": ["FL", "FR", "FC", "LFE", "BL", "BR", "BC"],
        "7.0": ["FL", "FR", "FC", "BL", "BR", "SL", "SR"],
        "7.0(front)": ["FL", "FR", "FC", "FLC", "FRC", "SL", "SR"],
        "7.1": ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"],
        "7.1(wide)": ["FL", "FR", "FC", "LFE", "BL", "BR", "FLC", "FRC"],
        "7.1(wide-side)": ["FL", "FR", "FC", "LFE", "FLC", "FRC", "SL", "SR"],
        "octagonal": ["FL", "FR", "FC", "BL", "BR", "BC", "SL", "SR"],
    ]

    /// The stereo downmix in a graph, as each output side's gain per input channel.
    private static func stereoPan(in graph: String) -> (left: [String: Double], right: [String: Double])? {
        guard let match = graph.firstMatch(of: #/pan=stereo\|FL=([^|]+)\|FR=([^,;\[]+)/#) else { return nil }
        func gains(_ terms: Substring) -> [String: Double] {
            var gains: [String: Double] = [:]
            for term in terms.split(separator: "+") {
                let parts = term.split(separator: "*")
                if parts.count == 2, let gain = Double(parts[0]) { gains[String(parts[1]), default: 0] += gain }
            }
            return gains
        }
        return (gains(match.1), gains(match.2))
    }

    /// Gains with each channel renamed, e.g. FL to FR to mirror a side.
    private static func renamed(_ gains: [String: Double], _ names: [String: String]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: gains.map { (names[$0.key] ?? $0.key, $0.value) })
    }

    // pan drops a channel the input lacks without a word, so each matrix must
    // name exactly the layout's channels, LFE aside, as the 5.1 one does.
    @Test("Layouts with a center downmix with FC at unity, on both paths",
          arguments: [(3, "3.0"), (4, "3.1"), (4, "4.0"), (5, "4.1"), (5, "5.0"),
                      (5, "5.0(side)"), (7, "6.1"), (7, "6.1(back)"), (7, "7.0"), (7, "7.0(front)")])
    func centerLayoutsDownmix(channels: Int, layout: String) throws {
        let pan = try #require(FilterGraphBuilder.downmixFilter(layout: layout))
        let named = Set(pan.matches(of: #/\*([A-Z]+)/#).map { String($0.1) })
        #expect(named == Self.layoutChannels[layout]?.subtracting(["LFE"]))
        #expect(pan.hasPrefix("pan=stereo|FL=1.000*FC+0.707*FL"))
        #expect(pan.contains("|FR=1.000*FC+0.707*FR"))
        for duration in [120, nil] as [Double?] {
            let graph = FilterGraphBuilder.build(params(
                channels: channels, layout: layout, duration: duration
            )).graph
            #expect(graph.ranges(of: pan).count == 1, "duration: \(String(describing: duration))")
            if let p = graph.range(of: pan), let rs = graph.range(of: "aresample=44100") {
                #expect(p.lowerBound < rs.lowerBound, "duration: \(String(describing: duration))")
            }
        }
    }

    @Test("Layouts without a center keep ffmpeg's default downmix",
          arguments: [(3, "2.1"), (4, "quad")])
    func noCenterLayoutsKeepDefault(channels: Int, layout: String) {
        #expect(FilterGraphBuilder.downmixFilter(layout: layout) == nil)
        for duration in [120, nil] as [Double?] {
            let graph = FilterGraphBuilder.build(params(
                channels: channels, layout: layout, duration: duration
            )).graph
            #expect(!graph.contains("pan="), "duration: \(String(describing: duration))")
        }
    }

    // The surround matrix was once picked by channel count, and 5.1's names BL
    // and BR, so a 5.1(side) source (SL SR) lost its surrounds whenever Dialog
    // Guard was off, with no error from pan.
    @Test("Surround downmix follows the probed layout with Dialog Guard off, on both paths",
          arguments: [(6, "5.1"), (6, "5.1(side)"), (6, "6.0"), (6, "hexagonal"),
                      (8, "7.1"), (8, "7.1(wide)"), (8, "7.1(wide-side)"), (8, "octagonal")])
    func surroundDownmixFollowsLayout(channels: Int, layout: String) throws {
        for levelRiding in [true, false] {
            for duration in [120, nil] as [Double?] {
                let context: Comment = "levelRiding: \(levelRiding), duration: \(String(describing: duration))"
                let graph = FilterGraphBuilder.build(params(
                    channels: channels, layout: layout, dialogGuard: false,
                    levelRiding: levelRiding, duration: duration
                )).graph
                let pan = try #require(Self.stereoPan(in: graph), context)
                #expect(Set(pan.left.keys).union(pan.right.keys)
                        == Self.layoutChannels[layout]?.subtracting(["LFE"]), context)
                #expect(pan.left["FC"] == 1 && pan.right["FC"] == 1, context)
                let mirror = ["FL": "FR", "FLC": "FRC", "BL": "BR", "SL": "SR"]
                #expect(pan.right == Self.renamed(pan.left, mirror), context)
            }
        }
    }

    @Test("5.1(side) downmixes as 5.1 does, SL and SR in BL and BR's place")
    func sideSurroundsMatchBack() throws {
        let back = try #require(Self.stereoPan(in: FilterGraphBuilder.build(params(
            layout: "5.1", dialogGuard: false
        )).graph))
        let side = try #require(Self.stereoPan(in: FilterGraphBuilder.build(params(
            layout: "5.1(side)", dialogGuard: false
        )).graph))
        let toSide = ["BL": "SL", "BR": "SR"]
        #expect(side.left == Self.renamed(back.left, toSide))
        #expect(side.right == Self.renamed(back.right, toSide))
        #expect(side.left["SL"] == 0.707)
    }

    // Dialog Guard's amerge labels its output with ffmpeg's default layout for
    // the channel count, whatever the source's was, so the pan after it must
    // name 5.1's or 7.1's channels. ffmpeg gives a surround source ffprobe
    // reported no layout for the same default, Dialog Guard or not.
    @Test("The downmix reads 5.1 or 7.1 after Dialog Guard, and for a surround source with no layout",
          arguments: [(6, "5.1"), (6, "5.1(side)"), (6, "6.0"), (6, "6.0(front)"), (6, nil),
                      (8, "7.1"), (8, "7.1(wide)"), (8, "7.1(wide-side)"), (8, "cube"), (8, nil)]
                      as [(Int, String?)])
    func downmixReadsDefaultLayout(channels: Int, layout: String?) throws {
        let expected = Self.layoutChannels[channels == 8 ? "7.1" : "5.1"]?.subtracting(["LFE"])
        for dialogGuard in layout == nil ? [true, false] : [true] {
            for duration in [120, nil] as [Double?] {
                let context: Comment = "dialogGuard: \(dialogGuard), duration: \(String(describing: duration))"
                let graph = FilterGraphBuilder.build(params(
                    channels: channels, layout: layout, dialogGuard: dialogGuard, duration: duration
                )).graph
                let pan = try #require(Self.stereoPan(in: graph), context)
                #expect(Set(pan.left.keys).union(pan.right.keys) == expected, context)
            }
        }
    }

    // Surround by channel count, but no matrix here fits them. ffmpeg's own
    // downmix mixes whatever channels the stream has.
    @Test("Surround layouts without a matrix keep ffmpeg's default downmix with Dialog Guard off",
          arguments: [(6, "6.0(front)"), (6, "3.1.2"), (8, "cube"),
                      (6, "6 channels (FL+FR+FC+LFE+BL+SL)")])
    func unmatchedSurroundKeepsDefault(channels: Int, layout: String) {
        for levelRiding in [true, false] {
            for duration in [120, nil] as [Double?] {
                let context: Comment = "levelRiding: \(levelRiding), duration: \(String(describing: duration))"
                let graph = FilterGraphBuilder.build(params(
                    channels: channels, layout: layout, dialogGuard: false,
                    levelRiding: levelRiding, duration: duration
                )).graph
                #expect(!graph.contains("pan="), context)
                #expect(graph.ranges(of: "aresample=44100,aformat=channel_layouts=stereo").count == 1, context)
            }
        }
    }

    @Test("Level riding uses gentle m=1.5")
    func levelRidingGentle() {
        let result = FilterGraphBuilder.build(params())
        #expect(result.graph.contains("dynaudnorm=p=0.90:m=1.5:g=31"))
    }

    @Test("Dialog Guard uses gentle m=3")
    func dialogGuardGentle() {
        let result = FilterGraphBuilder.build(params())
        #expect(result.graph.contains("dynaudnorm=p=0.88:m=3:g=15"))
    }

    @Test("5.1 downmix uses unity FC + 0.707 surrounds")
    func downmix51UnityGain() {
        let pan = FilterGraphBuilder.downmixFilter(layout: "5.1")!
        #expect(pan.contains("1.000*FC"))
        #expect(pan.contains("0.707*FL"))
        #expect(pan.contains("0.707*BL"))
    }

    @Test("7.1 downmix includes side channels at 0.5")
    func downmix71IncludesSides() {
        let pan = FilterGraphBuilder.downmixFilter(layout: "7.1")!
        #expect(pan.contains("1.000*FC"))
        #expect(pan.contains("0.500*SL"))
        #expect(pan.contains("0.500*SR"))
    }
}

// MARK: - AudioTrack layout

@Suite("AudioTrack layout")
struct AudioTrackLayoutTests {

    @Test("5.1 layout supports Dialog Guard")
    func layout51() {
        let track = AudioTrack(
            id: 0, audioIndex: 0, codecName: "eac3", channels: 6,
            channelLayout: "5.1", sampleRate: 48000, bitRate: nil,
            languageCode: "eng", title: nil,
            isDefault: true, isForced: false, isHearingImpaired: false,
            isVisuallyImpaired: false, isCommentary: false, isDescriptive: false
        )
        #expect(track.supportsDialogGuard)
        #expect(!track.supportsStereoDialogAssist)
    }

    @Test("Stereo supports Dialog Assist")
    func stereoAssist() {
        let track = AudioTrack(
            id: 0, audioIndex: 0, codecName: "aac", channels: 2,
            channelLayout: "stereo", sampleRate: 48000, bitRate: nil,
            languageCode: "eng", title: nil,
            isDefault: true, isForced: false, isHearingImpaired: false,
            isVisuallyImpaired: false, isCommentary: false, isDescriptive: false
        )
        #expect(!track.supportsDialogGuard)
        #expect(track.supportsStereoDialogAssist)
    }
}

// MARK: - FilmStripSettings

@Suite("FilmStripSettings")
struct FilmStripSettingsTests {

    @Test("Default audio processing values")
    func audioDefaults() {
        let settings = FilmStripSettings()
        #expect(settings.highPassFilter == true)
        #expect(settings.levelRiding == true)
        #expect(settings.stereoDialogAssist == true)
        #expect(settings.dialogGuard == true)
        #expect(settings.loudnormEnabled == true)
        #expect(abs(settings.loudnormTarget - (-18.0)) < 0.001)
    }
}

// MARK: - FilmStripSettings defaults

/// Runs `body` with a defaults suite of its own, removed afterwards.
///
/// The tests run inside the app, so `UserDefaults.standard` here is the app's
/// own domain. The suite is named by a path inside a temporary folder. A suite
/// named like a bundle identifier lives in ~/Library/Preferences, and removing
/// its domain empties the file but leaves it there, matching the
/// io.github.sevmorris.* pattern the App Preferences source backs up; deleting
/// the file does not hold, because cfprefsd writes it back after the test has
/// finished. Deleting a folder of our own does.
private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("filmstrip-defaults-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let suiteName = folder.appendingPathComponent("defaults").path
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }
    try body(defaults)
}

@Suite("FilmStripSettings defaults")
struct FilmStripSettingsDefaultsTests {

    @Test("A test run does not get the real defaults")
    func testRunGetsScratchDefaults() {
        #expect(AppLauncher.isHostingTests)
        #expect(UserDefaults.app !== UserDefaults.standard)
    }

    @Test("Output choices come back from the same store")
    func outputChoicesRoundTrip() throws {
        try withScratchDefaults { defaults in
            let settings = FilmStripSettings(defaults: defaults)
            settings.outputMode = .both
            settings.m4aBitrate = .high

            let restored = FilmStripSettings(defaults: defaults)
            #expect(restored.outputMode == .both)
            #expect(restored.m4aBitrate == .high)
        }
    }

    /// The path that, at every test launch, could drop the developer's saved
    /// output folder: a bookmark that no longer resolves is removed.
    @Test("An unresolvable output folder bookmark is dropped from the store it was read from")
    func unresolvableBookmarkIsDropped() throws {
        try withScratchDefaults { defaults in
            defaults.set(Data("not a bookmark".utf8), forKey: "fs_outputDirBookmark")

            let settings = FilmStripSettings(defaults: defaults)
            #expect(settings.outputDirWasReset)
            #expect(settings.outputDir == nil)
            #expect(defaults.data(forKey: "fs_outputDirBookmark") == nil)
        }
    }

    @Test("A plain output path from an older build is discarded")
    func legacyOutputPathIsDiscarded() throws {
        try withScratchDefaults { defaults in
            defaults.set("/tmp/old-output", forKey: "fs_outputDir")

            let settings = FilmStripSettings(defaults: defaults)
            #expect(settings.outputDir == nil)
            #expect(defaults.object(forKey: "fs_outputDir") == nil)
        }
    }
}
