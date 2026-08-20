# Vendor dependencies

## FFmpeg / ffprobe (bundled binaries)

FilmStrip bundles a **static, audio-only FFmpeg 8.0** for macOS **arm64 (Apple Silicon only)**, built from a committed recipe in this repository. The binaries are **not** stored in git (~44 MB combined). Instead:

| Artifact | Location |
|----------|----------|
| Build recipe (Corresponding Source) | `scripts/build-ffmpeg.sh` |
| Binary checksums & release tag | `Vendor/ffmpeg-manifest.env` |
| Download script | `scripts/fetch-ffmpeg.sh` |
| GitHub release assets | Tag from manifest |

Xcode runs `scripts/fetch-ffmpeg.sh` as a build phase, and `release.sh` runs it again *before* invoking `xcodebuild`.

That second call is not redundant. `FilmStrip/` is a synchronized group, so Xcode decides what to bundle when it plans the build — before the phase that downloads the binaries has run. On a fresh clone the first build therefore fetches them but ships without them; a second build picks them up. Running the fetch ahead of `xcodebuild` means the files already exist when planning starts, which is why releases are never affected. The sibling repos (WaxOnWaxOff, ClipHack) have the same arrangement and the same first-build quirk.

If you have just cloned and want a working app on the first try, run `./scripts/fetch-ffmpeg.sh` before opening Xcode.

**Do not delete** the release named by `FFMPEG_DEPS_TAG` in `Vendor/ffmpeg-manifest.env` — currently `ffmpeg-deps-8.0-audio-arm64`. Fresh clones fetch the binaries from it, and `scripts/fetch-ffmpeg.sh` has no other source.

### Why audio-only

FilmStrip extracts audio from video. It encodes **only** audio — `pcm_s16le`, `pcm_s24le`, `pcm_s32le`, `pcm_f32le`, `aac`, `opus`, `flac` — and its whole filter surface is audio too: `pan`, `loudnorm`, `dynaudnorm`, `alimiter`, `highpass`, `aformat`, `atrim`, `amerge`, `aresample`. Video is only ever *decoded*, to reach the audio inside the container, and FFmpeg's native decoders (h264, hevc, vp9, av1, prores, mpeg4) handle that without any external library.

So the video **encoders** are unreachable from every code path in the app. That matters because they are also the GPL ones: see *Historical builds*.

### The build

`scripts/build-ffmpeg.sh` builds FFmpeg 8.0 against LAME 3.100, both pinned and SHA-256 verified, with **no `--enable-gpl`**, **no `--enable-nonfree`**, **no `--enable-version3`**, and no video or image external libraries. The only external library is `libmp3lame`. The script asserts, fail-closed, that the resulting binaries execute, carry none of those three flags, link `libmp3lame`, target the project's deployment target, and have **no non-system dynamic dependencies**. Execution is asserted *before* the flag checks — a binary that cannot run emits no configuration string, and every "flag absent" assertion would otherwise pass vacuously.

The build is reproducible: two runs on the same toolchain produce byte-identical binaries, so anyone can rebuild and check the SHA-256 against the pin in `Vendor/ffmpeg-manifest.env`. Three things make that true — the fixed working directory (`configure` bakes `--prefix` into the binary), `-ffp-contract=off`, and `-Wl,-no_uuid`.

### License

| Field | Value |
|-------|--------|
| Upstream release | **FFmpeg 8.0** ("Huffman"), released 2025-08-22 |
| Source archive | https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz |
| PGP signature | https://ffmpeg.org/releases/ffmpeg-8.0.tar.xz.asc |
| FFmpeg license | **LGPL-2.1-or-later** (no `--enable-gpl`) |
| LAME 3.100 | **LGPL-2.0-or-later** — https://lame.sourceforge.io/ |

**No GPL components.** x264, x265 and libvidstab — the GPL-licensed encoders in the previous bundled build — are not compiled in. There is no GPL Corresponding Source obligation for this binary.

The LGPL §6 obligation that does apply is satisfied by this repository: `scripts/build-ffmpeg.sh` is the complete recipe, the pinned upstream source and its signature are named in `Vendor/ffmpeg-manifest.env`, and the app invokes `ffmpeg`/`ffprobe` as **separate executables** (via `Process()`), so they are aggregated with the app rather than linked into it.

## Historical builds

Through app **v1.8.3**, FilmStrip bundled a **GPL** FFmpeg build — `--enable-gpl` with x264, x265, libvidstab, libaom, libsvtav1, libvpx and more — and committed the two binaries directly to git (~98 MB). Both facts were problems, and they were the same problem seen from two sides.

Distributing a GPL binary obliges the distributor to supply its Corresponding Source: the exact configuration and build scripts used to produce it. That build came from elsewhere and this project has no recipe for it, so the obligation could not be met. Committing the binaries to a public repository *is* distribution, as is shipping them inside the signed app, which `release.sh` does.

None of it bought anything. Every GPL component in that build is a video **encoder**, and FilmStrip has never encoded video. The replacement drops them, which removes the obligation rather than trying to satisfy it, and takes the repository's payload with it.

**The v1.8.1, v1.8.2 and v1.8.3 DMG assets were deleted deliberately and must not be restored** — each contained that GPL binary, so re-uploading any of them resumes distributing it. The release pages and git tags are kept; only the downloads are gone. v1.9.0 is the first release carrying the LGPL build.

The old binaries also remain in git history for tags up to v1.8.3. That is a record, not a distribution channel, and nothing in any current build path references them.

## Refresh after clone

```bash
./scripts/fetch-ffmpeg.sh
```

Safe to run repeatedly — it skips the network when the local files already match the manifest checksums.
