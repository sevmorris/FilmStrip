# FilmStrip

<p align="center">
  <img src="docs/icon.png" width="128" height="128" />
  <br />
  <br />
  <strong>Extract film audio for listening</strong>
  <br />
  <strong>Version: </strong>1.5.8
  <br />
  <a href="https://github.com/sevmorris/FilmStrip/releases/latest/download/FilmStrip-v1.5.9.dmg"><strong>Download</strong></a>
  ·
  <a href="https://sevmorris.github.io/FilmStrip/manual/">Manual</a>
  ·
  <a href="https://sevmorris.github.io/FilmStrip/theory.html">Theory of Operation</a>
  <br />
  <br />
</p>

Drop a movie file — FilmStrip scans every audio track, auto-selects English, and exports it as WAV or M4A.

<img src="docs/images/filmstrip.png" width="100%" alt="FilmStrip">

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

I'm a freelance audio engineer, not a software developer. These tools exist because AI made it possible for me to build things I couldn't build alone. These aren't products. I made them for my own use and put them out there because they might be useful to others. 

At the same time I want to acknowledge that AI raises deep questions about labor displacement, resource consumption, surveillance, the concentration of power in a small number of corporations, and the increasingly close relationship between those corporations and governments. It's reshaping culture in ways that are harder to quantify too: authors replacing illustrators with generated images, fabricated photos designed to deceive, political misinformation at scale. These aren't hypothetical risks; they're unfolding now, and the implications for ordinary people are significant.
