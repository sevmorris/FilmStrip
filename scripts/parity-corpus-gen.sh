#!/usr/bin/env bash
# parity-corpus-gen.sh — Generate FilmStrip's parity corpus OUTSIDE the repo tree.
#
# FilmStrip's input is video, so the corpus is three short videos, one per path
# through FilterGraphBuilder, each carrying real speech from macOS `say` in two
# distinct voices:
#
#   speech-stereo.mp4  AAC stereo in MP4, one voice per channel (verified to
#                      differ) — Stereo Dialog Assist's mid/side split
#   speech-51.mkv      AAC 5.1 in Matroska: dialog on FC, the second voice on
#                      FL/FR, ambience on the surrounds, rumble on LFE — Dialog
#                      Guard's channelsplit (FC alone is levelled) and the downmix
#   speech-mono.mov    PCM mono in QuickTime — the single-channel assist path
#
# Speech rather than tones because the DSP under test is data-dependent: a sine
# never trips loudnorm's relative gate and gives dynaudnorm nothing to ride. The
# texts carry `say` volume changes and silences for the same reason.
#
# Durations straddle the mirror-padding cap, padDur = min(16, duration): the
# stereo and 5.1 fixtures run past 16 s, the mono one stays under it.
#
# Unlike the siblings' generators, this one cannot use the OLD binary. The
# bundled FFmpeg is audio-only and has no video encoder, and a fixture without a
# video stream would skip the demuxing FilmStrip exists for. So the corpus comes
# from a full FFmpeg — Homebrew's by default. That binary takes no part in the
# comparison: it only writes the inputs, and both sides of parity-check.sh read
# the same files.
#
# Corpus lives at $FILMSTRIP_PARITY_CORPUS — no default inside the repo. Media is
# never committed; this script is.
#
# bash 3.2-safe. Env: FILMSTRIP_PARITY_CORPUS (out dir),
#   FILMSTRIP_CORPUS_FFMPEG (default /opt/homebrew/bin/ffmpeg),
#   FILMSTRIP_CORPUS_FFPROBE (default: the ffprobe beside it).

set -euo pipefail

CORPUS="${FILMSTRIP_PARITY_CORPUS:?set FILMSTRIP_PARITY_CORPUS to a path OUTSIDE the repo}"
GEN="${FILMSTRIP_CORPUS_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
GENPROBE="${FILMSTRIP_CORPUS_FFPROBE:-$(dirname "$GEN")/ffprobe}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$CORPUS" in
  "$REPO"|"$REPO"/*|*/FilmStrip/*) echo "refusing: corpus path is inside the repo tree" >&2; exit 1;;
esac
[ -x "$GEN" ] && [ -x "$GENPROBE" ] \
  || { echo "INCOMPLETE: need a full FFmpeg with a video encoder at $GEN (brew install ffmpeg), and ffprobe beside it" >&2; exit 3; }
mkdir -p "$CORPUS"

# H.264 when the generator has it, as most real video is; any video stream will
# do, since the app maps the audio and never decodes the picture.
if "$GEN" -hide_banner -encoders 2>/dev/null | grep -q ' libx264 '; then
    VIDEO=(-c:v libx264 -preset ultrafast -pix_fmt yuv420p)
else
    VIDEO=(-c:v mpeg4)
fi

# --- Voice selection: pick the first TWO *installed* voices from a preference
# list. Named voices are download-on-demand on current macOS, so hardcoding two
# risks `say` silently falling back to the system default and producing a
# "stereo" fixture that is really dual-mono — passing every gate while testing
# nothing. Fewer than two distinct installed voices => INCOMPLETE, never a fallback.
VOICE_PREFS="Alex Samantha Daniel Albert Fred Karen Moira Tessa Serena Allison"
avail() { say -v '?' 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
V1=""; V2=""
for v in $VOICE_PREFS; do
    if avail "$v"; then
        if [ -z "$V1" ]; then V1="$v"
        elif [ -z "$V2" ]; then V2="$v"; break
        fi
    fi
done
if [ -z "$V1" ] || [ -z "$V2" ]; then
    echo "INCOMPLETE: need two installed 'say' voices for decorrelated fixtures; found: ${V1:-none} ${V2:-}" >&2
    echo "  installed candidates: $(say -v '?' 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | cut -c1-200)" >&2
    exit 3
fi
echo "▶ voices: $V1 (dialog) / $V2 (second speaker)"
echo "▶ generator: $("$GEN" -version | awk 'NR==1{print $3}') at $GEN, video ${VIDEO[1]}"

say_wav() {  # voice  text  out.wav   (say's AIFF → 48 kHz mono 16-bit WAV)
    say -v "$1" -o "$CORPUS/_tmp.aiff" "$2"
    "$GEN" -nostdin -y -loglevel error -i "$CORPUS/_tmp.aiff" -ar 48000 -ac 1 -c:a pcm_s16le "$3"
    rm -f "$CORPUS/_tmp.aiff"
}
duration() { "$GENPROBE" -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | head -1; }

# Residual RMS of channel a minus channel b. Near-silent means the two channels
# carry the same signal and the fixture does not test what it claims to.
residual_db() {  # file  a  b
    "$GEN" -nostdin -hide_banner -nostats -i "$1" \
        -af "aeval=val($2)-val($3):c=1,astats=metadata=1:reset=0" -f null - 2>&1 \
        | awk -F': ' '/RMS level dB/{v=$2} END{print v}'
}
require_distinct() {  # file  a  b  label
    local r
    r="$(residual_db "$1" "$2" "$3")"
    case "$r" in
      ""|*inf*) echo "INCOMPLETE: $4 null to ${r:-nothing} — the voices did not differ" >&2; exit 3;;
    esac
    awk -v v="$r" 'BEGIN{exit !(v > -60)}' \
      || { echo "INCOMPLETE: $4 residual ${r} dB is near-silent — the channels are effectively identical" >&2; exit 3; }
    echo "   $4 verified distinct: residual RMS ${r} dB"
}

# Varied level and real pauses: loudnorm's gate and dynaudnorm need both.
TXT1="This is the dialog track of a parity sample. It speaks at a normal level, [[volm 0.35]] then drops to a murmur that a leveler should lift, [[volm 1.0]] and comes back up again. [[slnc 1500]] After a pause, it continues with numbers: three, fourteen, one hundred and fifty nine. [[volm 0.5]] A softer closing line, [[volm 1.0]] and a firm last word."
TXT2="A second speaker reads different words, at a different pace, [[slnc 800]] so that no two channels carry the same signal. [[volm 0.6]] Quieter now, as if across the room, [[volm 1.0]] then close to the microphone once more, with a long sentence that keeps going past the point where the first voice has already stopped talking."
TXT3="A mono clip, short enough to stay under the sixteen second padding cap. [[volm 0.4]] It dips quietly here, [[volm 1.0]] and ends."

say_wav "$V1" "$TXT1" "$CORPUS/_v1.wav"
say_wav "$V2" "$TXT2" "$CORPUS/_v2.wav"
say_wav "$V1" "$TXT3" "$CORPUS/_v3.wav"

echo "▶ speech-stereo.mp4 (AAC stereo in MP4: $V1 left, $V2 right)"
"$GEN" -nostdin -y -loglevel error -i "$CORPUS/_v1.wav" -i "$CORPUS/_v2.wav" \
    -f lavfi -i "testsrc2=s=320x180:r=24" \
    -filter_complex "[0:a][1:a]amerge=inputs=2,pan=stereo|c0=c0|c1=c1,apad=pad_dur=1[a]" \
    -map 2:v -map "[a]" -shortest "${VIDEO[@]}" -c:a aac -b:a 192k -ar 48000 \
    "$CORPUS/speech-stereo.mp4"
require_distinct "$CORPUS/speech-stereo.mp4" 0 1 "stereo L-R"

echo "▶ speech-51.mkv (AAC 5.1 in Matroska: $V1 on FC, $V2 on FL/FR)"
# FL/FR: the second voice, FR 20 ms later and 3 dB down, so the pair is not
# dual-mono. BL/BR: pink noise, different seeds. LFE: low-passed brown noise.
"$GEN" -nostdin -y -loglevel error -i "$CORPUS/_v1.wav" -i "$CORPUS/_v2.wav" \
    -f lavfi -i "anoisesrc=color=pink:amplitude=0.02:seed=11:r=48000" \
    -f lavfi -i "anoisesrc=color=pink:amplitude=0.02:seed=23:r=48000" \
    -f lavfi -i "anoisesrc=color=brown:amplitude=0.2:seed=37:r=48000" \
    -f lavfi -i "testsrc2=s=320x180:r=24" \
    -filter_complex "[0:a]apad=pad_dur=1[fc];[1:a]asplit=2[v2a][v2b];[v2b]adelay=20,volume=-3dB[fr];[4:a]lowpass=f=120[lfe];[v2a][fr][fc][lfe][2:a][3:a]amerge=inputs=6,pan=5.1|FL=c0|FR=c1|FC=c2|LFE=c3|BL=c4|BR=c5,atrim=end=24[a]" \
    -map 5:v -map "[a]" -shortest "${VIDEO[@]}" -c:a aac -b:a 384k -ar 48000 \
    "$CORPUS/speech-51.mkv"
require_distinct "$CORPUS/speech-51.mkv" 2 0 "5.1 FC-FL (dialog vs second voice)"
require_distinct "$CORPUS/speech-51.mkv" 0 1 "5.1 FL-FR"

echo "▶ speech-mono.mov (PCM mono in QuickTime: $V1)"
"$GEN" -nostdin -y -loglevel error -i "$CORPUS/_v3.wav" -f lavfi -i "testsrc2=s=320x180:r=24" \
    -map 1:v -map 0:a -shortest "${VIDEO[@]}" -c:a pcm_s16le \
    "$CORPUS/speech-mono.mov"

rm -f "$CORPUS/_v1.wav" "$CORPUS/_v2.wav" "$CORPUS/_v3.wav"

# Confirm each fixture is what it says: a video stream (so the app's audio
# mapping has something to skip), and the audio codec and channel count it was
# made for. -show_entries is an ffprobe option; ffmpeg silently ignores it.
check_fixture() {  # file  expected "codec,channels"  pad-branch
    local f="$CORPUS/$1" hasv a d
    hasv="$("$GENPROBE" -v error -show_entries stream=codec_type -of csv=p=0 "$f" 2>/dev/null | grep -c video || true)"
    a="$("$GENPROBE" -v error -select_streams a -show_entries stream=codec_name,channels -of csv=p=0 "$f" 2>/dev/null | head -1)"
    d="$(duration "$f")"
    if [ "${hasv:-0}" -lt 1 ]; then
        echo "INCOMPLETE: $1 has no video stream" >&2; exit 3
    fi
    if [ "$a" != "$2" ]; then
        echo "INCOMPLETE: $1 audio is '$a', expected '$2'" >&2; exit 3
    fi
    case "$3" in
        over)  awk -v d="$d" 'BEGIN{exit !(d > 16)}'  || { echo "INCOMPLETE: $1 is ${d}s, needs > 16 s to reach the padding cap" >&2; exit 3; };;
        under) awk -v d="$d" 'BEGIN{exit !(d < 16)}'  || { echo "INCOMPLETE: $1 is ${d}s, needs < 16 s to stay under the padding cap" >&2; exit 3; };;
    esac
    echo "   $1: video ✓, audio $a, ${d}s (padding: $3 16 s)"
}
echo "▶ checking fixtures"
check_fixture speech-stereo.mp4 "aac,2" over
check_fixture speech-51.mkv     "aac,6" over
check_fixture speech-mono.mov   "pcm_s16le,1" under

echo "✓ corpus at $CORPUS:"; ls -1 "$CORPUS"
