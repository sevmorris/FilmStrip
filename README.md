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

## A Note on AI

I'm a freelance audio engineer, not a software developer. These tools exist because AI made it possible for me to build things I couldn't build alone, and I think that's genuinely valuable.

But I hold that alongside some serious concerns. AI raises deep questions about labor displacement, resource consumption, surveillance, the concentration of power in a small number of corporations, and the increasingly close relationship between those corporations and governments. These aren't hypothetical risks; they're unfolding now, and the implications for ordinary people are significant. I don't have clean answers. I don't think anyone does.

What I can say is that I think it matters how these tools get used, and by whom, and toward what ends. I'd rather be honest about that tension than pretend it doesn't exist. A free audio utility that helps independent podcasters is one kind of use. But I have friends with advanced degrees who are struggling to find work in fields AI has hollowed out. I built something with these tools. They're living with what these tools displaced. I don't know how to fully square that, and I'm suspicious of anyone who says they can.

FilmStrip has been built carefully and iteratively, tested against real film files, refined based on actual use, and updated continuously as improvements reveal themselves. That process takes real time and attention, even when AI is writing the code. The app is free and will stay that way.
