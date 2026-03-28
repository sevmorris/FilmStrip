import Foundation

struct AudioTrack: Identifiable, Sendable {
    let id: Int               // stream index within the file (0-based overall stream index)
    let audioIndex: Int       // audio-only index (e.g. 0 = first audio stream)
    let codecName: String     // raw codec name from ffprobe
    let channels: Int
    let sampleRate: Int
    let bitRate: Int?         // bits per second, optional
    let languageCode: String? // ISO 639-2/B or 639-1
    let title: String?        // optional track title from metadata

    var displayLanguage: String {
        guard let code = languageCode, !code.isEmpty, code != "und" else {
            return "Unknown"
        }
        // Try system locale for 2-letter code
        if let name = Locale.current.localizedString(forLanguageCode: code), !name.isEmpty {
            return name
        }
        // Fallback map for common 3-letter codes
        let fallback: [String: String] = [
            "eng": "English",
            "fra": "French",
            "fre": "French",
            "deu": "German",
            "ger": "German",
            "spa": "Spanish",
            "jpn": "Japanese",
            "ita": "Italian",
            "por": "Portuguese",
            "zho": "Chinese",
            "chi": "Chinese",
            "rus": "Russian",
            "kor": "Korean",
            "ara": "Arabic",
            "nld": "Dutch",
            "pol": "Polish",
            "swe": "Swedish",
            "nor": "Norwegian",
            "dan": "Danish",
            "fin": "Finnish",
            "hun": "Hungarian",
            "ces": "Czech",
            "cze": "Czech",
            "tur": "Turkish",
            "heb": "Hebrew",
            "hin": "Hindi",
            "tha": "Thai",
            "vie": "Vietnamese",
            "ind": "Indonesian",
            "msa": "Malay",
            "ron": "Romanian",
            "rum": "Romanian",
            "ukr": "Ukrainian",
            "hrv": "Croatian",
            "srp": "Serbian",
            "bul": "Bulgarian",
            "slk": "Slovak",
            "slo": "Slovak",
            "slv": "Slovenian",
            "ell": "Greek",
            "gre": "Greek",
            "cat": "Catalan",
            "lat": "Latin",
        ]
        return fallback[code.lowercased()] ?? code.uppercased()
    }

    var displayCodec: String {
        switch codecName.lowercased() {
        case "ac3":             return "AC3"
        case "eac3":            return "E-AC3"
        case "dts":             return "DTS"
        case "dts-hd":          return "DTS-HD"
        case "truehd":          return "TrueHD"
        case "aac":             return "AAC"
        case "mp3":             return "MP3"
        case "mp2":             return "MP2"
        case "flac":            return "FLAC"
        case "opus":            return "Opus"
        case "vorbis":          return "Vorbis"
        case "pcm_s16le",
             "pcm_s24le",
             "pcm_s32le",
             "pcm_f32le":       return "PCM"
        case "wmav2":           return "WMA"
        default:                return codecName.uppercased()
        }
    }

    var displayChannels: String {
        switch channels {
        case 1:  return "Mono"
        case 2:  return "Stereo"
        case 6:  return "5.1"
        case 8:  return "7.1"
        default: return "\(channels)ch"
        }
    }

    var displayBitrate: String {
        guard let br = bitRate, br > 0 else { return "" }
        let kbps = br / 1000
        return "\(kbps) kbps"
    }

    var isEnglish: Bool {
        guard let code = languageCode else { return false }
        return code.lowercased() == "eng" || code.lowercased() == "en"
    }
}
