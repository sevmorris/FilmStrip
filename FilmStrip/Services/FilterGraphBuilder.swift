import Foundation

/// Parameters for building the Pass-1 extraction filter graph.
nonisolated struct FilterGraphParams: Sendable {
    let audioStreamLabel: String
    let channels: Int
    let channelLayout: String?
    let highPassFilter: Bool
    let levelRiding: Bool
    let dialogGuard: Bool
    let stereoDialogAssist: Bool
    /// When set, dynaudnorm steps are wrapped in mirror padding.
    let duration: Double?

    var useDialogGuard: Bool {
        dialogGuard && AudioTrack.supportsDialogGuard(channels: channels, layout: channelLayout)
    }

    var useStereoDialogAssist: Bool {
        stereoDialogAssist && AudioTrack.supportsStereoDialogAssist(channels: channels)
    }

    var isSurround: Bool {
        AudioTrack.supportsDialogGuard(channels: channels, layout: channelLayout)
    }
}

struct FilterGraphResult: Sendable {
    let usesFilterComplex: Bool
    /// Full `-filter_complex` graph, or `-af` chain when `usesFilterComplex` is false.
    let graph: String
    /// `-map` argument: stream label or `[aout]`.
    let mapLabel: String
}

nonisolated enum FilterGraphBuilder {

    // Gentle, headphone-tuned dynamics. Effectively downward-only — m=1.5 caps
    // upward gain at ~+3.5 dB, so silent/quiet sections aren't lifted into the
    // mix the way a higher m would do.
    private static let levelRidingFilter = "dynaudnorm=p=0.90:m=1.5:g=31"

    // Dialog-only side-chain (center channel in surround, mid in stereo).
    // Lower m than the historic 5/7/9 — still meaningfully lifts quiet dialog
    // without dragging center-channel room tone up with it.
    private static let dialogGuardFilter = "dynaudnorm=p=0.88:m=3:g=15"

    private static let limiter = "alimiter=limit=0.99:attack=5:release=50:level=false"
    private static let resampleStereo = "aresample=44100,aformat=channel_layouts=stereo"

    static func build(_ params: FilterGraphParams) -> FilterGraphResult {
        if needsFilterComplex(params) {
            let graph = buildFilterComplex(params)
            return FilterGraphResult(usesFilterComplex: true, graph: graph, mapLabel: "[aout]")
        }
        let graph = buildAudioFilter(params)
        return FilterGraphResult(usesFilterComplex: false, graph: graph, mapLabel: params.audioStreamLabel)
    }

    private static func needsFilterComplex(_ params: FilterGraphParams) -> Bool {
        if params.useDialogGuard { return true }
        if params.isSurround && params.levelRiding { return true }
        if params.useStereoDialogAssist && params.channels == 2 { return true }
        if params.useStereoDialogAssist && params.channels == 1 && params.duration != nil { return true }
        if params.levelRiding && params.duration != nil && !params.isSurround { return true }
        return false
    }

    // MARK: - Simple -af path

    private static func buildAudioFilter(_ params: FilterGraphParams) -> String {
        var parts: [String] = []

        if params.useStereoDialogAssist && params.channels == 1 {
            parts.append(dialogGuardFilter)
        }

        if params.highPassFilter {
            parts.append("highpass=f=80,highpass=f=80")
        }

        if params.levelRiding {
            parts.append(levelRidingFilter)
        }

        if let pan = stereoDownmix(params) {
            parts.append(pan)
        }

        parts.append(resampleStereo)
        parts.append(limiter)
        return parts.joined(separator: ",")
    }

    // MARK: - filter_complex path

    private static func buildFilterComplex(_ params: FilterGraphParams) -> String {
        var chains: [String] = []
        var lastLabel = params.audioStreamLabel

        if params.useDialogGuard {
            chains.append(contentsOf: dialogGuardChains(
                inputLabel: lastLabel,
                channels: params.channels,
                duration: params.duration
            ))
            lastLabel = "merged"
        }

        if params.useStereoDialogAssist && params.channels == 2 {
            chains.append(contentsOf: stereoDialogAssistChains(
                inputLabel: lastLabel,
                duration: params.duration
            ))
            lastLabel = "sdac"
        } else if params.useStereoDialogAssist && params.channels == 1, let d = params.duration {
            chains.append(contentsOf: mirrorPaddedDynaudnormChains(
                inputLabel: lastLabel, outputLabel: "sdac", prefix: "sda",
                duration: d, dynaudnormFilter: dialogGuardFilter
            ))
            lastLabel = "sdac"
        }

        if params.highPassFilter {
            chains.append("[\(lastLabel)]highpass=f=80,highpass=f=80[posthp]")
            lastLabel = "posthp"
        }

        // Every source reaches level riding as 44.1 kHz stereo, as on the -af
        // path: surround and the other layouts with a center through our own
        // downmix, anything else (mono, stereo, SDA's output, quad, a layout
        // ffprobe didn't name) through ffmpeg's.
        if let downmix = stereoDownmix(params) {
            chains.append("[\(lastLabel)]\(downmix),\(resampleStereo)[stereo]")
        } else {
            chains.append("[\(lastLabel)]\(resampleStereo)[stereo]")
        }
        lastLabel = "stereo"

        if params.levelRiding {
            if let d = params.duration {
                chains.append(contentsOf: mirrorPaddedDynaudnormChains(
                    inputLabel: lastLabel, outputLabel: "postlr", prefix: "lr",
                    duration: d, dynaudnormFilter: levelRidingFilter
                ))
            } else {
                chains.append("[\(lastLabel)]\(levelRidingFilter)[postlr]")
            }
            lastLabel = "postlr"
        }

        chains.append("[\(lastLabel)]\(limiter)[aout]")
        return chains.joined(separator: ";")
    }

    // MARK: - Dialog Guard

    private static func dialogGuardChains(
        inputLabel: String,
        channels: Int,
        duration: Double?
    ) -> [String] {
        let layout = channels == 8 ? "7.1" : "5.1"
        let n = channels
        var chains: [String] = []
        let splitLabels = (0..<n).map { "[dgc\($0)]" }.joined()
        chains.append("[\(inputLabel)]channelsplit=channel_layout=\(layout)\(splitLabels)")

        if let d = duration {
            chains.append(contentsOf: mirrorPaddedDynaudnormChains(
                inputLabel: "dgc2", outputLabel: "dgcraw", prefix: "dg",
                duration: d, dynaudnormFilter: dialogGuardFilter
            ))
            chains.append("[dgcraw]aformat=channel_layouts=mono[dgcn]")
        } else {
            chains.append("[dgc2]\(dialogGuardFilter),aformat=channel_layouts=mono[dgcn]")
        }

        for i in 0..<n where i != 2 {
            chains.append("[dgc\(i)]aformat=channel_layouts=mono[dgcm\(i)]")
        }
        let mergeInputs = (0..<n).map { $0 == 2 ? "[dgcn]" : "[dgcm\($0)]" }.joined()
        chains.append("\(mergeInputs)amerge=inputs=\(n)[merged]")
        return chains
    }

    // MARK: - Stereo Dialog Assist (mid/side)

    private static func stereoDialogAssistChains(
        inputLabel: String,
        duration: Double?
    ) -> [String] {
        var chains: [String] = []
        chains.append("[\(inputLabel)]pan=mono|c0=0.5*c0+0.5*c1[sdamid]")
        chains.append("[\(inputLabel)]pan=mono|c0=0.5*c0+-0.5*c1[sdaside]")

        if let d = duration {
            chains.append(contentsOf: mirrorPaddedDynaudnormChains(
                inputLabel: "sdamid", outputLabel: "sdamidn", prefix: "sdam",
                duration: d, dynaudnormFilter: dialogGuardFilter
            ))
        } else {
            chains.append("[sdamid]\(dialogGuardFilter)[sdamidn]")
        }

        chains.append("[sdamidn][sdaside]amerge=inputs=2,pan=stereo|FL=c0+c1|FR=c0-c1[sdac]")
        return chains
    }

    // MARK: - Downmix

    /// The pan that takes this source to stereo, or nil to leave it to
    /// aformat, i.e. ffmpeg's default downmix.
    private static func stereoDownmix(_ params: FilterGraphParams) -> String? {
        params.isSurround
            ? downmixFilter(channels: params.channels)
            : centerDownmixFilter(layout: params.channelLayout)
    }

    static func downmixFilter(channels: Int) -> String? {
        // Standard ITU 5.1/7.1 → stereo coefficients (unity FC, -3 dB on surrounds).
        if channels == 6 {
            return "pan=stereo|FL=1.000*FC+0.707*FL+0.707*BL|FR=1.000*FC+0.707*FR+0.707*BR"
        }
        if channels >= 8 {
            return "pan=stereo|FL=1.000*FC+0.707*FL+0.707*BL+0.500*SL|FR=1.000*FC+0.707*FR+0.707*BR+0.500*SR"
        }
        return nil
    }

    // The same balance for the smaller layouts that carry a center, which aren't
    // surround here. ffmpeg's default would put FC 3 dB under the fronts, not
    // over. A back center feeds both sides at 0.500; LFE is dropped, as above.
    // Keyed by ffmpeg's layout name, since pan silently drops any channel the
    // input lacks, and the channel count alone can't tell 5.0 from 5.0(side).
    // Layouts without a center (quad, 2.1) keep ffmpeg's default.
    static func centerDownmixFilter(layout: String?) -> String? {
        switch layout?.lowercased() {
        case "3.0", "3.1":
            return "pan=stereo|FL=1.000*FC+0.707*FL|FR=1.000*FC+0.707*FR"
        case "4.0", "4.1":
            return "pan=stereo|FL=1.000*FC+0.707*FL+0.500*BC|FR=1.000*FC+0.707*FR+0.500*BC"
        case "5.0":
            return "pan=stereo|FL=1.000*FC+0.707*FL+0.707*BL|FR=1.000*FC+0.707*FR+0.707*BR"
        case "5.0(side)":
            return "pan=stereo|FL=1.000*FC+0.707*FL+0.707*SL|FR=1.000*FC+0.707*FR+0.707*SR"
        case "6.1":
            return "pan=stereo|FL=1.000*FC+0.707*FL+0.707*SL+0.500*BC|FR=1.000*FC+0.707*FR+0.707*SR+0.500*BC"
        case "6.1(back)":
            return "pan=stereo|FL=1.000*FC+0.707*FL+0.707*BL+0.500*BC|FR=1.000*FC+0.707*FR+0.707*BR+0.500*BC"
        case "7.0": // 7.1 without the LFE
            return downmixFilter(channels: 8)
        default:
            return nil
        }
    }

    // MARK: - Mirror padding

    static func mirrorPaddedDynaudnormChains(
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
}
