# FilmStrip
### Film Audio Extraction Utility for macOS

<p align="center">
  <strong>Automated Audio Track Selection & Extraction</strong>
  <br />
  <strong>Version:</strong> 1.8.3
  <br />
  <a href="https://github.com/sevmorris/FilmStrip/releases/latest/download/FilmStrip-v1.8.3.dmg"><strong>Download Latest (DMG)</strong></a>
  ·
  <a href="https://sevmorris.github.io/FilmStrip/manual/">Manual</a>
  ·
  <a href="https://sevmorris.github.io/FilmStrip/theory.html">Theory of Operation</a>
</p>

**FilmStrip** is an internal utility designed to streamline the extraction of film audio for independent listening. It automates the technical overhead of container scanning and track selection, providing a standardized path from high-resolution video files to portable audio formats.

This tool was built to facilitate an "audio-only" film consumption workflow. While developed for personal use, it is made publicly available for those who require a precise, zero-fluff extraction pipeline.

---

## Core Features
* **Automated Stream Analysis:** Scans MKV, MP4, MOV, and AVI containers via bundled `ffprobe` to identify language, codec, and bitrate metadata.
* **Intelligent Track Selection:** Automatically identifies and selects English language tracks with a global fallback protocol.
* **Dual-Format Export:** High-fidelity 24-bit WAV for archive/editing or AAC M4A for mobile listening.
* **Level Management:** Optional downward-only `dynaudnorm` level riding to manage cinematic dynamic range for consistent listening levels.
* **Loudness Compliance:** Optional two-pass EBU R128 normalization to a configurable LUFS target.

---

## Technical Specifications
* **Container Support:** Wide-spectrum support including MKV, MP4, MOV, and AVI.
* **Output Destination:** Desktop default with configurable custom directory mapping.
* **Environment:** macOS 14.0+ (Sonoma); Native Apple Silicon and Intel support.
* **Dependencies:** Bundled FFmpeg/ffprobe; no external installation required.

---

## Technical Origin
FilmStrip is an expert-driven signal chain built on FFmpeg. I designed the DSP logic and parameters based on professional podcasting standards, and used AI assistance to implement the Swift UI and process orchestration. 

This is a personal toolset provided "as-is." It is designed for utility and precision, not as a commercial product.

---

### Included Software

FilmStrip includes these programs. It does not change them.

* **FFmpeg 8.0 (arm64):** FilmStrip uses FFmpeg for all audio extraction and processing. This is an audio-only build. It does not use the `--enable-gpl`, `--enable-nonfree`, or `--enable-version3` options, and it includes no video or image libraries. The only external library is libmp3lame (LAME 3.100). The FFmpeg core is supplied under the GNU Lesser General Public License v2.1 or later. LAME is supplied under the LGPL v2.0 or later. No GPL components are included.
  * FFmpeg source code: [ffmpeg-8.0.tar.xz](https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz) ([signature](https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz.asc))
  * LAME source code: [lame-3.100.tar.gz](https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz)
  * Build recipe: `scripts/build-ffmpeg.sh` in this repository. It rebuilds the shipped binaries byte for byte, so the checksums in `Vendor/ffmpeg-manifest.env` are independently verifiable. To see the build configuration of the included binary, run `ffmpeg -version`.
  * Further detail: [`Vendor/README.md`](Vendor/README.md)

---

### License
Copyright © 2026 Seven Morris.
Distributed under the [GNU General Public License v3.0](LICENSE).
