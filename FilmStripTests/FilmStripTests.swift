import Testing
@testable import FilmStrip

// MARK: - ExtractionSettings

@Suite("ExtractionSettings")
struct ExtractionSettingsTests {

    private func settings(aggressiveness: Int, dialogGuard: Bool = false) -> ExtractionSettings {
        ExtractionSettings(
            outputMode: .wav,
            m4aBitrate: 192,
            highPassFilter: false,
            levelRiding: true,
            levelAggressiveness: aggressiveness,
            dialogGuard: dialogGuard,
            stereoDialogAssist: false,
            dialogLevel: .normal,
            loudnormEnabled: false,
            loudnormTarget: -18.0
        )
    }

    @Test("Level 1 → p=0.95, m=2.0 (gentlest)")
    func level1() {
        let s = settings(aggressiveness: 1)
        #expect(abs(s.dynaudnormP - 0.95) < 0.001)
        #expect(abs(s.dynaudnormM - 2.0)  < 0.001)
    }

    @Test("Level 10 → p=0.55, m=10.0 (heaviest)")
    func level10() {
        let s = settings(aggressiveness: 10)
        #expect(abs(s.dynaudnormP - 0.55) < 0.001)
        #expect(abs(s.dynaudnormM - 10.0) < 0.001)
    }

    @Test("Dialog Guard compensation reduces m and raises p")
    func dialogGuardCompensation() {
        let s = settings(aggressiveness: 7, dialogGuard: true)
        let (p, m, log) = s.levelRidingParams(channels: 6, channelLayout: "5.1")
        #expect(m < s.dynaudnormM)
        #expect(p > s.dynaudnormP)
        #expect(log?.contains("Dialog Guard compensation") == true)
    }

    @Test("Dialog Guard compensation skipped for stereo")
    func noCompensationForStereo() {
        let s = settings(aggressiveness: 7, dialogGuard: true)
        let (p, m, log) = s.levelRidingParams(channels: 2, channelLayout: "stereo")
        #expect(abs(p - s.dynaudnormP) < 0.001)
        #expect(abs(m - s.dynaudnormM) < 0.001)
        #expect(log == nil)
    }
}

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
            levelP: 0.68,
            levelM: 7.3,
            dialogGuard: dialogGuard,
            dialogLevel: .normal,
            stereoDialogAssist: stereoDialogAssist,
            duration: duration
        )
    }

    @Test("Surround + LR uses filter_complex with pan before dynaudnorm")
    func surroundLRPostDownmix() {
        let result = FilterGraphBuilder.build(params())
        #expect(result.usesFilterComplex)
        let panRange = result.graph.range(of: "pan=stereo")!
        let dynRange = result.graph.range(of: "dynaudnorm=p=0.68")!
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

    @Test("Boost downmix attenuates surrounds")
    func boostDownmixCoeffs() {
        let pan = FilterGraphBuilder.downmixFilter(channels: 6, dialogLevel: .boost)!
        #expect(pan.contains("0.501"))
        #expect(pan.contains("1.000*FC"))
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

// MARK: - Presets

@Suite("LevelRidingPreset")
struct PresetTests {

    @Test("Comfort preset maps to level 7")
    func comfortLevel() {
        #expect(LevelRidingPreset.comfort.aggressiveness == 7)
    }

    @Test("Headphone profile sets comfort defaults")
    func headphoneProfile() {
        let settings = FilmStripSettings()
        ProcessingProfile.headphone.apply(to: settings)
        #expect(settings.levelRidingPreset == .comfort)
        #expect(settings.processingProfile == .headphone)
        #expect(settings.stereoDialogAssist)
        #expect(settings.dialogGuard)
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
        #expect(settings.levelRidingPreset == .comfort)
        #expect(settings.processingProfile == .headphone)
        #expect(settings.levelAggressiveness == 7)
        #expect(settings.dialogGuard == true)
        #expect(settings.loudnormEnabled == true)
        #expect(abs(settings.loudnormTarget - (-18.0)) < 0.001)
    }

    @Test("Preset sync updates aggressiveness")
    func presetSync() {
        let settings = FilmStripSettings()
        settings.levelRidingPreset = .cinematic
        settings.syncAggressivenessFromPreset()
        #expect(settings.levelAggressiveness == 4)
    }
}
