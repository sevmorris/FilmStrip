# FilmStrip
### Film Audio Extraction Utility for macOS

<p align="center">
  <strong>Automated Audio Track Selection & Extraction</strong>
  <br />
  <strong>Version:</strong> 1.5.21
  <br />
  <a href="https://github.com/sevmorris/FilmStrip/releases/latest/download/FilmStrip-v1.5.21.dmg"><strong>Download</strong></a>
  ·
  <a href="https://sevmorris.github.io/FilmStrip/manual/">Manual</a>
  ·
  <a href="https://sevmorris.github.io/FilmStrip/theory.html">Theory of Operation</a>
</p>

**FilmStrip** is an internal utility designed to streamline the extraction of film audio for independent listening. It automates the technical overhead of container scanning and track selection, providing a standardized path from high-resolution video files to portable audio formats.

This tool was built to facilitate an "audio-only" film consumption workflow. While developed for personal use, it is made publicly available for those who require a precise, zero-fluff extraction pipeline.

---

> [!CAUTION]
> **Manual Authorization Required**
> macOS will block execution because this utility is not notarized. To authorize:
> 1. Move `FilmStrip.app` to your `/Applications` folder.
> 2. Run the following command in Terminal:
>    `xattr -cr /Applications/FilmStrip.app`

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
This utility is the result of a **Human-AI Collaboration**. 

I am an audio engineer, not a developer; these tools are built using AI-assisted coding to bridge that technical gap. I act as the **Architect and Executive Producer**, defining the audio signal chains and logic, while the code is generated through iterative stress-testing with Large Language Models. 

This is a personal toolset provided "as-is." It is designed for utility and precision, not as a commercial product.

---

### License
Copyright © 2026 Seven Morris.
Distributed under the [GNU General Public License v3.0](LICENSE).
