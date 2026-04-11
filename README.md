# FilmStrip

**Extract film audio for listening.** Drop a movie file — FilmStrip scans every audio track, auto-selects English, and exports it as WAV or M4A.

[Download v1.5.4 (DMG)](https://github.com/sevmorris/FilmStrip/releases/latest/download/FilmStrip-v1.5.4.dmg) · [App Page](https://sevmorris.github.io/FilmStrip/) · [Theory of Operation](https://sevmorris.github.io/FilmStrip/theory.html)

---

## What It Does

- Scans MKV, MP4, MOV, AVI, and more via bundled ffprobe
- Displays every audio track: language, codec, channels, bitrate, and track title when available
- Auto-selects English tracks; falls back to selecting all if none found
- Exports any selection to 24-bit WAV, AAC M4A, or both
- Optional level riding — downward-only dynaudnorm with aggressiveness control
- Optional loudness normalization — two-pass EBU R128 to a configurable LUFS target
- Output goes to Desktop by default; configure any folder in Settings

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel
- Free

## Usage

Because FilmStrip is not notarized with Apple, macOS will block it on first launch. After dragging to Applications, run once in Terminal:

```bash
xattr -cr /Applications/FilmStrip.app
```

## Building

```bash
xcodebuild -project FilmStrip.xcodeproj -scheme FilmStrip -configuration Release
```

Or use the release script:

```bash
./release.sh 1.0.0
```
