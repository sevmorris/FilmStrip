import Testing
@testable import FilmStrip

// MARK: - Filter graph

@Suite("FilterGraphBuilder")
struct FilterGraphBuilderTests {

    private func params(
        channels: Int = 6,
        layout: String? = "5.1",
        dialogGuard: Bool = true,
        levelRiding: Bool = true,
        stereoDialogAssist: Bool = false,
        duration: Double? = 120
    ) -> FilterGraphParams {
        FilterGraphParams(
            audioStreamLabel: "0:a:0",
            channels: channels,
            channelLayout: layout,
            highPassFilter: true,
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
        let pan = FilterGraphBuilder.downmixFilter(channels: 6)!
        #expect(pan.contains("1.000*FC"))
        #expect(pan.contains("0.707*FL"))
        #expect(pan.contains("0.707*BL"))
    }

    @Test("7.1 downmix includes side channels at 0.5")
    func downmix71IncludesSides() {
        let pan = FilterGraphBuilder.downmixFilter(channels: 8)!
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
