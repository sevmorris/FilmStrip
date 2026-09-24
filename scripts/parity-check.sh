#!/usr/bin/env bash
# parity-check.sh — Old-binary vs new-binary parity over FilmStrip's corpus.
#
# Runs FilmStrip's ACTUAL extraction pipeline (AudioExtractor.swift) through both
# binaries and compares every stage. Report is per-file, per-gate, with MEASURED
# values — margins, not verdicts.
#
# The pass-1 graph is not retyped. FilterGraphBuilder.swift and AudioTrack.swift
# are compiled from the app's own source with a small main.swift, so each side
# runs the graph the app would build for that file, from what that side's
# ffprobe reported. The later stages are inline in a private actor method with
# nothing to call, so they are retyped — and SOURCE_LINES below fences them: if
# any line they were copied from stops appearing verbatim in the app, the run is
# INCOMPLETE rather than a PASS for a pipeline the app no longer has.
#
# Each side uses its own ffmpeg AND ffprobe for every stage, as the app would:
#   probe     TrackInspector's call (-show_streams JSON) -> channels, layout
#   duration  AudioExtractor's duration probe -> mirror padding
#   graph     FilterGraphBuilder.build with the defaults: high-pass, level riding,
#             Dialog Guard and Stereo Dialog Assist all on
#   pass 1    -filter_complex G -map [aout], or -map 0:a:0 -af G -> pcm_s24le
#   analysis  loudnorm=I=-18.0:TP=-1.0:LRA=20:print_format=json
#   pass 2    linear loudnorm from the measured values, -ac 2 -ar 44100 pcm_s24le
#   m4a       -c:a aac -b:a 192k -ar 44100
#
# Policy (frozen — do not edit a threshold after seeing results; take the failing
# data to the owner instead):
#   * Three states: PASS / FAIL / INCOMPLETE. INCOMPLETE never counts as PASS.
#   * Runs EVERY fixture in the corpus; never aborts early; exits non-zero on any
#     FAIL or INCOMPLETE.
#   * Trust a result only from a harness validated on this machine: OLD against
#     itself must pass everything, and OLD against a build known to differ
#     (Homebrew's FFmpeg) must fail. See Vendor/README.md.
#
# Gates (frozen):
#   null      One meter (the OLD binary) inverts one side and sums. Must be -inf.
#             Every stage writes pcm_s24le or runs FFmpeg's native AAC encoder,
#             all deterministic for a given binary, so an unchanged pipeline is
#             bit-identical: the -90 dBFS the siblings allow is not granted here.
NULL_REQUIRED="-inf"
#   loudness  Integrated loudness and true peak, ebur128 on the same meter.
LUFS_TOL="0.1"
TP_TOL="0.1"
#   exact     The loudnorm analysis JSON, the output format and sample count, the
#             probed duration, the graph, and every ffprobe field TrackInspector
#             reads.
#
# Pre-registered divergences: NONE. If an update is expected to change AAC
# encoding, declare it here BEFORE running, the way WaxOnWaxOff declares LAME's.
#
# Reported, not gated: ffprobe fields TrackInspector does not read ([NOTE]).
# 8.0 → 8.0.3 dropped the all-zero vendor_id tag from an MP4's AAC stream (a
# QuickTime file keeps it); nothing in the app reads it. A field the app starts
# reading belongs in PROBE_READ, where it becomes a gate.
#
# bash 3.2-safe. Needs xcrun (swiftc) and jq.
# Env: FILMSTRIP_PARITY_CORPUS, FILMSTRIP_OLD_FFMPEG, FILMSTRIP_NEW_FFMPEG,
#      FILMSTRIP_OLD_FFPROBE / FILMSTRIP_NEW_FFPROBE (default: beside each ffmpeg).

set -uo pipefail
CORPUS="${FILMSTRIP_PARITY_CORPUS:?}"; OLD="${FILMSTRIP_OLD_FFMPEG:?}"; NEW="${FILMSTRIP_NEW_FFMPEG:?}"
OLDPROBE="${FILMSTRIP_OLD_FFPROBE:-$(dirname "$OLD")/ffprobe}"
NEWPROBE="${FILMSTRIP_NEW_FFPROBE:-$(dirname "$NEW")/ffprobe}"
METER="$OLD"; METERPROBE="$OLDPROBE"   # ONE fixed meter for both sides, so we measure output diffs not meter diffs
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/FilmStrip"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; incomplete=0; notes=0

# The settings being exercised are FilmStripSettings' defaults.
TARGET="-18.0"   # loudnormTarget, interpolated by Swift as "-18.0"
BITRATE="192"    # m4aBitrate .medium

# TrackInspector's fields: the stream list itself, then each one it decodes.
PROBE_READ='^streams\.[0-9]+\.(index|codec_type|codec_name|channels|channel_layout|sample_rate|bit_rate|tags\.(language|title)|disposition\.(default|forced|hearing_impaired|visual_impaired|comment|descriptions))='

# The lines the retyped stages were copied from: file, then the exact text.
SOURCE_LINES='Services/AudioExtractor.swift|audioStreamLabel: "0:a:\(audioIndex)",
Services/AudioExtractor.swift|"-filter_complex", graphResult.graph,
Services/AudioExtractor.swift|"-map", graphResult.mapLabel,
Services/AudioExtractor.swift|"-af", graphResult.graph,
Services/AudioExtractor.swift|"-c:a", "pcm_s24le",
Services/AudioExtractor.swift|"-show_entries", "format=duration",
Services/AudioExtractor.swift|"-of", "default=noprint_wrappers=1:nokey=1",
Services/AudioExtractor.swift|let analyzeAf = "loudnorm=I=\(target):TP=-1.0:LRA=20:print_format=json"
Services/AudioExtractor.swift|let normAf = "loudnorm=I=\(target):TP=-1.0:LRA=20:measured_I=\(stats.inputI):measured_TP=\(stats.inputTP):measured_LRA=\(stats.inputLRA):measured_thresh=\(stats.inputThresh):offset=\(stats.targetOffset):linear=true"
Services/AudioExtractor.swift|"-ac", "2",
Services/AudioExtractor.swift|"-ar", "44100",
Services/AudioExtractor.swift|"-c:a", "aac",
Services/AudioExtractor.swift|"-b:a", "\(bitrate)k",
Services/TrackInspector.swift|"-v", "quiet",
Services/TrackInspector.swift|"-print_format", "json",
Services/TrackInspector.swift|"-show_streams",
Services/TrackInspector.swift|"-select_streams", "a",
Models/FilmStripSettings.swift|var highPassFilter: Bool = true
Models/FilmStripSettings.swift|var levelRiding: Bool = true
Models/FilmStripSettings.swift|var dialogGuard: Bool = true
Models/FilmStripSettings.swift|var stereoDialogAssist: Bool = true
Models/FilmStripSettings.swift|var loudnormEnabled: Bool = true
Models/FilmStripSettings.swift|var loudnormTarget: Double = -18.0
Models/FilmStripSettings.swift|var m4aBitrate: M4ABitrate = .medium
Models/FilmStripSettings.swift|case medium = 192'

state() {
    printf '  %-11s %s\n' "[$1]" "$2"
    case "$1" in
        PASS) pass=$((pass+1));;
        FAIL) fail=$((fail+1));;
        INCOMPLETE) incomplete=$((incomplete+1));;
        NOTE) notes=$((notes+1));;
    esac
}

# --- Meters: all on the OLD binary --------------------------------------------
# Null residual, CHANNEL-SAFE: invert one side and sum, which works at any channel
# count. (Subtracting one channel of an amerge from another compares a file
# against ITSELF on dual-mono input and reports a false -inf.)
null_db() {
    "$METER" -nostdin -hide_banner -nostats -i "$1" -i "$2" \
        -filter_complex "[1:a]volume=-1[n];[0:a][n]amix=inputs=2:normalize=0,astats=measure_perchannel=none:measure_overall=Peak_level" \
        -f null - 2>&1 | awk -F': ' '/Peak level dB/{v=$2} END{print v}'
}
measure() {  # -> "I TP", from ebur128's summary only (its per-frame lines also carry "I:")
    "$METER" -nostdin -hide_banner -nostats -i "$1" -af ebur128=peak=true -f null - 2>&1 \
        | awk '/Summary:/{s=1} s&&$1=="I:"{i=$2} s&&$1=="Peak:"{t=$2} END{if(i!="") print i, t}'
}
fmt() { "$METERPROBE" -v error -select_streams a:0 -show_entries stream=codec_name,sample_fmt,sample_rate,channels,channel_layout -of csv=p=0 "$1" 2>/dev/null | head -1; }
samples() { "$METERPROBE" -v error -select_streams a:0 -show_entries stream=duration_ts -of csv=p=0 "$1" 2>/dev/null | head -1; }
abs_le() { awk -v a="$1" -v b="$2" 'BEGIN{a=(a<0?-a:a); exit !(a<=b)}'; }
flat() { jq -r 'paths(scalars) as $p | "\($p | map(tostring) | join("."))=\(getpath($p))"' "$1" 2>/dev/null | LC_ALL=C sort; }

compare() {  # label old new   — empty is INCOMPLETE, never a false PASS
    if [ -z "$2" ] || [ -z "$3" ]; then state INCOMPLETE "$1 unmeasurable"
    elif [ "$2" = "$3" ]; then state PASS "$1 = $3"
    else state FAIL "$1: old=$2 new=$3"; fi
}
gate_null() {  # label oldfile newfile
    local nd
    nd="$(null_db "$2" "$3")"
    if [ -z "$nd" ]; then state INCOMPLETE "$1 null unmeasurable"
    elif [ "$nd" = "$NULL_REQUIRED" ]; then state PASS "$1 null = -inf (bit-identical)"
    else state FAIL "$1 null = ${nd} dBFS (want ${NULL_REQUIRED})"; fi
}
gate_loud() {  # label oldfile newfile
    local om nm oI oT nI nT dI dT
    om="$(measure "$2")"; nm="$(measure "$3")"
    oI="${om%% *}"; oT="${om##* }"; nI="${nm%% *}"; nT="${nm##* }"
    if [ -z "$oI" ] || [ -z "$nI" ]; then state INCOMPLETE "$1 LUFS/TP unmeasurable"; return; fi
    dI="$(awk -v a="$oI" -v b="$nI" 'BEGIN{printf "%.4f", a-b}')"
    dT="$(awk -v a="$oT" -v b="$nT" 'BEGIN{printf "%.4f", a-b}')"
    if abs_le "$dI" "$LUFS_TOL"; then state PASS "$1 LUFS Δ=${dI} (old ${oI} new ${nI})"
    else state FAIL "$1 LUFS Δ=${dI} > ${LUFS_TOL} (old ${oI} new ${nI})"; fi
    if abs_le "$dT" "$TP_TOL"; then state PASS "$1 TP   Δ=${dT} (old ${oT} new ${nT})"
    else state FAIL "$1 TP Δ=${dT} > ${TP_TOL} (old ${oT} new ${nT})"; fi
}
gate_audio() {  # label oldfile newfile   — the four gates every stage's output gets
    if [ ! -s "$2" ] || [ ! -s "$3" ]; then state INCOMPLETE "$1 produced no output"; return; fi
    gate_null "$1" "$2" "$3"
    compare   "$1 format"  "$(fmt "$2")"     "$(fmt "$3")"
    compare   "$1 samples" "$(samples "$2")" "$(samples "$3")"
    gate_loud "$1" "$2" "$3"
}
gate_probe() {  # oldjson newjson
    local o n
    if [ ! -s "$1" ] || [ ! -s "$2" ]; then state INCOMPLETE "probe produced no JSON"; return; fi
    flat "$1" > "$TMP/po"; flat "$2" > "$TMP/pn"
    if [ ! -s "$TMP/po" ] || [ ! -s "$TMP/pn" ]; then state INCOMPLETE "probe JSON unreadable"; return; fi
    o="$(grep -E "$PROBE_READ" "$TMP/po")"; n="$(grep -E "$PROBE_READ" "$TMP/pn")"
    if [ -z "$o" ] || [ -z "$n" ]; then state INCOMPLETE "probe has no fields TrackInspector reads"
    elif [ "$o" = "$n" ]; then state PASS "probe: $(printf '%s\n' "$o" | wc -l | tr -d ' ') fields TrackInspector reads, identical"
    else state FAIL "probe fields TrackInspector reads differ: $(diff <(printf '%s\n' "$o") <(printf '%s\n' "$n") | grep '^[<>]' | tr '\n' ' ')"; fi
    # Everything else, by path, old value against new.
    grep -vE "$PROBE_READ" "$TMP/po" > "$TMP/qo"; grep -vE "$PROBE_READ" "$TMP/pn" > "$TMP/qn"
    if ! cmp -s "$TMP/qo" "$TMP/qn"; then
        state NOTE "probe fields TrackInspector does not read differ: $(awk -F= '
            FNR==NR { k=$1; sub(/^[^=]*=/, ""); o[k]=$0; next }
            { k=$1; sub(/^[^=]*=/, ""); n[k]=$0 }
            END {
                for (k in o) if (!(k in n) || n[k] != o[k]) printf "%s old=%s new=%s; ", k, o[k], ((k in n) ? n[k] : "absent")
                for (k in n) if (!(k in o)) printf "%s old=absent new=%s; ", k, n[k]
            }' "$TMP/qo" "$TMP/qn")"
    fi
}

# --- The app's pipeline, stage for stage (AudioExtractor.swift) ---------------
# run_side <ffmpeg> <ffprobe> <input> <dir>. Stops at the first failed stage;
# whatever it has written is gated, and whatever is missing is INCOMPLETE.
run_side() {
    local bin="$1" probe="$2" in="$3" d="$4" ch layout dur g kind rest map graph I T L H O
    rm -rf "$d"; mkdir -p "$d"

    "$probe" -v quiet -print_format json -show_streams -select_streams a "$in" > "$d/probe.json" || return 1
    ch="$(jq -r '.streams[0].channels // 0' "$d/probe.json")"
    layout="$(jq -r '.streams[0].channel_layout // ""' "$d/probe.json")"

    # A failed duration probe is not an error in the app: it builds the graph
    # without mirror padding. Same here.
    "$probe" -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$in" \
        > "$d/duration.txt" 2>/dev/null || : > "$d/duration.txt"
    dur="$(tr -d '[:space:]' < "$d/duration.txt")"

    g="$("$GRAPH" "$ch" "$layout" "$dur")" || return 1
    printf '%s\n' "$g" > "$d/graph.txt"
    kind="${g%%|*}"; rest="${g#*|}"; map="${rest%%|*}"; graph="${rest#*|}"   # the graph itself contains '|'

    if [ "$kind" = "complex" ]; then
        "$bin" -nostdin -hide_banner -loglevel error -y -i "$in" -filter_complex "$graph" -map "$map" \
            -c:a pcm_s24le "$d/raw.wav" || return 1
    else
        "$bin" -nostdin -hide_banner -loglevel error -y -i "$in" -map "$map" -af "$graph" \
            -c:a pcm_s24le "$d/raw.wav" || return 1
    fi

    # loudnorm prints its JSON at info level, so no -loglevel here. The app takes
    # the last {...} block from stderr; so does this.
    "$bin" -nostdin -hide_banner -nostats -y -i "$d/raw.wav" \
        -af "loudnorm=I=${TARGET}:TP=-1.0:LRA=20:print_format=json" -f null /dev/null 2> "$d/analysis.log" || return 1
    awk '/^\{/{buf=""; on=1} on{buf=buf $0 "\n"} /^\}/{if(on) last=buf; on=0} END{printf "%s", last}' \
        "$d/analysis.log" > "$d/analysis.json"
    I="$(jq -r '.input_i // empty' "$d/analysis.json" 2>/dev/null)"
    T="$(jq -r '.input_tp // empty' "$d/analysis.json" 2>/dev/null)"
    L="$(jq -r '.input_lra // empty' "$d/analysis.json" 2>/dev/null)"
    H="$(jq -r '.input_thresh // empty' "$d/analysis.json" 2>/dev/null)"
    O="$(jq -r '.target_offset // empty' "$d/analysis.json" 2>/dev/null)"
    [ -n "$I" ] && [ -n "$T" ] && [ -n "$L" ] && [ -n "$H" ] && [ -n "$O" ] || return 1

    "$bin" -nostdin -hide_banner -loglevel error -y -i "$d/raw.wav" \
        -af "loudnorm=I=${TARGET}:TP=-1.0:LRA=20:measured_I=${I}:measured_TP=${T}:measured_LRA=${L}:measured_thresh=${H}:offset=${O}:linear=true" \
        -ac 2 -ar 44100 -c:a pcm_s24le "$d/norm.wav" || return 1

    "$bin" -nostdin -hide_banner -loglevel error -y -i "$d/norm.wav" \
        -c:a aac -b:a "${BITRATE}k" -ar 44100 "$d/out.m4a" || return 1
}

echo "=== PARITY  old=$("$OLD" -version 2>/dev/null | awk 'NR==1{print $3}') ($(shasum -a 256 "$OLD" | cut -c1-12))  new=$("$NEW" -version 2>/dev/null | awk 'NR==1{print $3}') ($(shasum -a 256 "$NEW" | cut -c1-12)) ==="
echo "=== app source: $(git -C "$REPO" --no-pager log -1 --no-color --format='%h %s' 2>/dev/null)$( [ -n "$(git -C "$REPO" status --porcelain -- FilmStrip 2>/dev/null)" ] && echo ' (+ uncommitted changes)') ==="
echo "=== defaults: HPF, level riding, Dialog Guard, Stereo Dialog Assist on; loudnorm ${TARGET} LUFS; AAC ${BITRATE}k ==="
echo "=== no pre-registered divergences — every stage must null to -inf ==="
echo

# --- Before any fixture: the tools, and the app source this reproduces ---------
echo "setup"
for tool in xcrun jq; do
    command -v "$tool" >/dev/null 2>&1 || { state INCOMPLETE "$tool not found"; }
done
drift=""
while IFS= read -r line; do
    f="${line%%|*}"; text="${line#*|}"
    grep -qF -- "$text" "$SRC/$f" 2>/dev/null || drift="${drift}
      $f: $text"
done <<EOF
$SOURCE_LINES
EOF
if [ -z "$drift" ]; then state PASS "pipeline source: $(printf '%s\n' "$SOURCE_LINES" | wc -l | tr -d ' ') copied lines still in the app, verbatim"
else state INCOMPLETE "pipeline source changed — the harness no longer reproduces the app. Missing:${drift}"; fi

# The graph printer: the app's own FilterGraphBuilder, called with the arguments
# AudioExtractor passes. Its duration handling mirrors probeAudioDuration: an
# unparsable or non-positive value is nil, which drops the mirror padding.
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let channels = Int(args[1]) else {
    FileHandle.standardError.write(Data("usage: graph <channels> <layout|\"\"> <duration|\"\">\n".utf8))
    exit(2)
}
let probed = Double(args[3].trimmingCharacters(in: .whitespacesAndNewlines))
let result = FilterGraphBuilder.build(FilterGraphParams(
    audioStreamLabel: "0:a:0",
    channels: channels,
    channelLayout: args[2].isEmpty ? nil : args[2],
    highPassFilter: true,
    levelRiding: true,
    dialogGuard: true,
    stereoDialogAssist: true,
    duration: (probed ?? 0) > 0 ? probed : nil
))
print("\(result.usesFilterComplex ? "complex" : "af")|\(result.mapLabel)|\(result.graph)")
SWIFT
GRAPH="$TMP/graph"
# -target: the app's deployment target, so the SDK's newer symbols cannot be
# weak-linked into a helper this macOS then lacks.
if xcrun swiftc -O -target "$(uname -m)-apple-macos14.0" -o "$GRAPH" \
        "$TMP/main.swift" "$SRC/Services/FilterGraphBuilder.swift" "$SRC/Models/AudioTrack.swift" \
        > "$TMP/swiftc.log" 2>&1; then
    state PASS "graph printer compiled from FilterGraphBuilder.swift and AudioTrack.swift"
else
    state INCOMPLETE "graph printer did not compile: $(head -3 "$TMP/swiftc.log" | tr '\n' ' ')"
fi
echo

# EVERY fixture in the corpus — no hand-picked subset.
nfix=0
for f in "$CORPUS"/*; do
    case "$f" in *.mp4|*.m4v|*.mov|*.mkv|*.webm|*.avi|*.ts) ;; *) continue;; esac
    nfix=$((nfix+1))
    b="$(basename "$f")"; echo "$b"
    run_side "$OLD" "$OLDPROBE" "$f" "$TMP/o"
    run_side "$NEW" "$NEWPROBE" "$f" "$TMP/n"

    gate_probe "$TMP/o/probe.json" "$TMP/n/probe.json"
    compare "duration" "$(cat "$TMP/o/duration.txt" 2>/dev/null)" "$(cat "$TMP/n/duration.txt" 2>/dev/null)"
    og="$(cat "$TMP/o/graph.txt" 2>/dev/null)"; ng="$(cat "$TMP/n/graph.txt" 2>/dev/null)"
    if [ -z "$og" ] || [ -z "$ng" ]; then state INCOMPLETE "graph not built"
    elif [ "$og" = "$ng" ]; then state PASS "graph identical (${og%%|*}, ${#og} chars)"
    else state FAIL "graph differs: old=${og} new=${ng}"; fi

    gate_audio "pass 1" "$TMP/o/raw.wav" "$TMP/n/raw.wav"
    if [ ! -s "$TMP/o/analysis.json" ] || [ ! -s "$TMP/n/analysis.json" ]; then state INCOMPLETE "loudnorm analysis produced no JSON"
    elif cmp -s "$TMP/o/analysis.json" "$TMP/n/analysis.json"; then
        state PASS "loudnorm analysis JSON identical (input_i $(jq -r .input_i "$TMP/o/analysis.json"), input_tp $(jq -r .input_tp "$TMP/o/analysis.json"), offset $(jq -r .target_offset "$TMP/o/analysis.json"))"
    else state FAIL "loudnorm analysis JSON differs: $(diff "$TMP/o/analysis.json" "$TMP/n/analysis.json" | grep '^[<>]' | tr -s ' ' | tr '\n' ' ')"; fi
    gate_audio "pass 2" "$TMP/o/norm.wav" "$TMP/n/norm.wav"
    gate_audio "m4a"    "$TMP/o/out.m4a"  "$TMP/n/out.m4a"
done
[ "$nfix" -gt 0 ] || state INCOMPLETE "no video fixtures in $CORPUS — run scripts/parity-corpus-gen.sh"

echo
echo "=== PASS=$pass  FAIL=$fail  INCOMPLETE=$incomplete  (NOTE=$notes, not gated) ==="
[ "$fail" -eq 0 ] && [ "$incomplete" -eq 0 ]
