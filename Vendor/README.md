# Vendor dependencies

## FFmpeg / ffprobe (bundled binaries)

FilmStrip bundles a **static, audio-only FFmpeg 9.0.2** for macOS **arm64 (Apple Silicon only)**, built from a committed recipe in this repository. The binaries are **not** stored in git (~45 MB combined). Instead:

| Artifact | Location |
|----------|----------|
| Build recipe (Corresponding Source) | `scripts/build-ffmpeg.sh` |
| Binary checksums & release tag | `Vendor/ffmpeg-manifest.env` |
| Download script | `scripts/fetch-ffmpeg.sh` |
| GitHub release assets | Tag from manifest |

Xcode runs `scripts/fetch-ffmpeg.sh` as a build phase, and `release.sh` runs it again *before* invoking `xcodebuild`.

That second call is not redundant. `FilmStrip/` is a synchronized group, so Xcode decides what to bundle when it plans the build — before the phase that downloads the binaries has run. On a fresh clone the first build therefore fetches them but ships without them; a second build picks them up. Running the fetch ahead of `xcodebuild` means the files already exist when planning starts, which is why releases are never affected. The sibling repos (WaxOnWaxOff, ClipHack) have the same arrangement and the same first-build quirk.

If you have just cloned and want a working app on the first try, run `./scripts/fetch-ffmpeg.sh` before opening Xcode.

**Do not delete** the release named by `FFMPEG_DEPS_TAG` in `Vendor/ffmpeg-manifest.env` — currently `ffmpeg-deps-9.0.2-audio-arm64-r5`. Fresh clones fetch the binaries from it, and `scripts/fetch-ffmpeg.sh` has no other source.

The previous pins must also stay published, because older tags verify against their checksums and deleting one makes those tags unbuildable from a clean checkout:

| Pin | Hosted in | Tags |
|-----|-----------|------|
| `ffmpeg-deps-8.0-audio-arm64` | this repo | v1.9.0 – v1.9.1 |
| `ffmpeg-deps-8.0-audio-arm64-r3` | `sevmorris/ClipHack-releases` | v1.9.2 |
| `ffmpeg-deps-8.0-audio-arm64-r4` | this repo | v1.9.3 |
| `ffmpeg-deps-8.0.3-audio-arm64-r4` | this repo | v1.9.4 – v1.9.5 |

The first does not launch on macOS 26.7 (see *The build*). v1.9.2 borrowed ClipHack's r3 during the 2026-09-16 migration, before this repo had a build with LC_UUID of its own; r4 is that build. The suffix follows the recipe revision the sibling repos share, so there is no r2 or r3 here, and `ffmpeg-deps-8.0.3-audio-arm64-r4` is that same r4 recipe with its pins moved to FFmpeg 8.0.3. r5 moves them to FFmpeg 9.0.2 and LAME 4.0, and adds `--disable-decoder` to LAME's configure, which from LAME 3.101 otherwise links a Homebrew libmpg123 whenever one is installed.

### Why audio-only

FilmStrip extracts audio from video. It encodes **only** audio — `pcm_s16le`, `pcm_s24le`, `pcm_s32le`, `pcm_f32le`, `aac`, `opus`, `flac` — and its whole filter surface is audio too: `pan`, `loudnorm`, `dynaudnorm`, `alimiter`, `highpass`, `aformat`, `atrim`, `amerge`, `aresample`. Video is only ever *decoded*, to reach the audio inside the container, and FFmpeg's native decoders (h264, hevc, vp9, av1, prores, mpeg4) handle that without any external library.

So the video **encoders** are unreachable from every code path in the app. That matters because they are also the GPL ones: see *Historical builds*.

### The build

`scripts/build-ffmpeg.sh` builds FFmpeg 9.0.2 against LAME 4.0, both pinned and SHA-256 verified, with **no `--enable-gpl`**, **no `--enable-nonfree`**, **no `--enable-version3`**, and no video or image external libraries. The only external library is `libmp3lame`. The script asserts, fail-closed, that the resulting binaries execute, carry none of those three flags, link `libmp3lame`, target the project's deployment target, carry an `LC_UUID`, and have **no non-system dynamic dependencies**. Execution is asserted *before* the flag checks — a binary that cannot run emits no configuration string, and every "flag absent" assertion would otherwise pass vacuously.

The build is reproducible: two runs on the same toolchain produce byte-identical binaries, so anyone can rebuild and check the SHA-256 against the pin in `Vendor/ffmpeg-manifest.env`. Three things make that true — the fixed working directory (`configure` bakes `--prefix` into the binary), `-ffp-contract=off`, and `ZERO_AR_DATE=1`, which keeps object-file timestamps out of the linker's `LC_UUID`.

The first build here got the same result by dropping `LC_UUID` altogether (`-Wl,-no_uuid`). That stopped working: dyld on macOS 26.7 refuses to load an executable without one ("missing LC_UUID load command"), so those binaries abort on launch there. The script now asserts the load command is present.

### Parity

A new build is not bundled until it has been run against the one it replaces, through FilmStrip's own pipeline: `scripts/parity-corpus-gen.sh` makes the inputs and `scripts/parity-check.sh` compares the two binaries. ClipHack and WaxOnWaxOff have the same pair. FilmStrip's 8.0 → 8.0.3 move was checked by an ad-hoc script instead; this is that check, committed.

**What it runs.** The pass-1 filter graph is not retyped. The check compiles `Services/FilterGraphBuilder.swift` and `Models/AudioTrack.swift` from the app with a small `main.swift` (`xcrun swiftc`), so each side runs the graph the app would build for that file from what that side's ffprobe reported. The stages after it follow `AudioExtractor.swift`:
1. TrackInspector's probe, then the duration probe;
2. pass 1 to `pcm_s24le`;
3. loudnorm analysis at −18 LUFS;
4. the linear second pass to 44.1 kHz stereo;
5. AAC at 192 kbps.

Those later stages are inline in a private method, so they are retyped. The script therefore checks first that every source line they were copied from is still in the app, and reports INCOMPLETE if one is not. Each side uses its own `ffmpeg` and `ffprobe` for every stage.

**The gates are frozen.** Never edit one after seeing results; take failing data to the owner. The old binary is the one meter for both sides. Every stage's output must null to −inf: the pipeline writes only `pcm_s24le` and FFmpeg's native AAC, both deterministic, so the −90 dBFS the siblings allow is not granted. Integrated loudness and true peak (`ebur128`) must agree within 0.1. The loudnorm measurement JSON, the output format, the sample count, the probed duration, the graph, and every ffprobe field TrackInspector reads must be identical. ffprobe fields the app does not read are reported as NOTE, not gated.

**The corpus** is three videos with speech from `say` in two installed voices. It is generated outside the repo and never committed:
- stereo AAC in MP4, one voice per channel;
- 5.1 AAC in Matroska, with the dialog on FC;
- mono PCM in QuickTime.

The stereo and 5.1 clips run past the 16-second mirror-padding cap and the mono one stays under it. The bundled build has no video encoder, so the corpus comes from Homebrew's FFmpeg (`brew install ffmpeg`). That binary writes the inputs and takes no part in the comparison.

**Validate the harness before trusting it**, on the machine that will run it:

```bash
export FILMSTRIP_PARITY_CORPUS=~/parity/filmstrip        # anywhere outside the repo
./scripts/parity-corpus-gen.sh
# The old pin: what FilmStrip/ has before the manifest moves, or its deps release.
gh release download ffmpeg-deps-9.0.2-audio-arm64-r5 -R sevmorris/FilmStrip -p ffmpeg -p ffprobe -D ~/parity/old
chmod +x ~/parity/old/ffmpeg ~/parity/old/ffprobe
export FILMSTRIP_OLD_FFMPEG=~/parity/old/ffmpeg

FILMSTRIP_NEW_FFMPEG=~/parity/old/ffmpeg          ./scripts/parity-check.sh   # must pass everything
FILMSTRIP_NEW_FFMPEG=/opt/homebrew/bin/ffmpeg     ./scripts/parity-check.sh   # must FAIL
FILMSTRIP_NEW_FFMPEG=/path/to/new/ffmpeg          ./scripts/parity-check.sh   # the real run
```

A harness that passes the second run is measuring nothing. Homebrew's FFmpeg differs even at the pinned version, because it is configured and compiled differently (8 FAIL against 9.0.2-r5 on 2026-09-24). If it ever stops failing, use the previous pin as the build known to differ. The `ffprobe` beside each `ffmpeg` is used unless `FILMSTRIP_OLD_FFPROBE` or `FILMSTRIP_NEW_FFPROBE` says otherwise.

Results with the three-fixture corpus (59 gates per run):

| Old | New | Result |
|-----|-----|--------|
| 8.0.3-r4, on 2026-09-23 | itself | 59 PASS, every null −inf |
| 8.0-r4, from the installed v1.9.3 | 8.0.3-r4 | 59 PASS, every null −inf; one NOTE: 8.0.3 no longer reports the MP4 AAC stream's all-zero `vendor_id` tag, which TrackInspector does not read |
| 8.0.3-r4 | Homebrew 9.0.2, on 2026-09-23 | 14 FAIL, on every fixture. The 5.1 clip differs from pass 1 on: its pass-1 null is +1.3 dBFS, it is 7 samples shorter, and its loudnorm measurement moves 0.28 LU. The stereo clip's pass-1 null is −138 dBFS. Every AAC output changes |
| 8.0.3-r4 | 8.1.3-r5 candidate, 2026-09-24 | 11 FAIL. 8.1 brought the Matroska and AAC-encoder changes below, so it was no smaller step than 9.0 |
| 8.0.3-r4 | 9.0.2-r5 (the current pin), 2026-09-24 | 14 FAIL, accepted by the owner. FFmpeg now trims the AAC encoder delay at the start of a Matroska track, so the 5.1 clip is 7 samples shorter and its level riding shifts: loudness is unchanged, true peak moves up to 0.3 dB. FFmpeg's AAC encoder changed, so every M4A differs, at the same loudness. Stereo and mono WAV differ by −138 dBFS at most |
| 9.0.2-r5 | Homebrew 9.0.2, 2026-09-24 | 8 FAIL at the same version: pass-1 nulls down to −86 dBFS and every M4A, from Homebrew's own configure and compiler flags. Still a valid negative control |

### License

| Field | Value |
|-------|--------|
| Upstream release | **FFmpeg 9.0.2** (9.0 "Lei"), released 2026-09-17 |
| Source archive | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz |
| PGP signature | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz.asc |
| FFmpeg license | **LGPL-2.1-or-later** (no `--enable-gpl`) |
| LAME 4.0 | **LGPL-2.0-or-later** — https://lame.sourceforge.io/ |

**No GPL components.** x264, x265 and libvidstab — the GPL-licensed encoders in the previous bundled build — are not compiled in. There is no GPL Corresponding Source obligation for this binary.

The LGPL §6 obligation that does apply is satisfied by this repository: `scripts/build-ffmpeg.sh` is the complete recipe, the pinned upstream source and its signature are named in `Vendor/ffmpeg-manifest.env`, and the app invokes `ffmpeg`/`ffprobe` as **separate executables** (via `Process()`), so they are aggregated with the app rather than linked into it.

## Historical builds

Through app **v1.8.3**, FilmStrip bundled a **GPL** FFmpeg build — `--enable-gpl` with x264, x265, libvidstab, libaom, libsvtav1, libvpx and more — and committed the two binaries directly to git (~98 MB). Both facts were problems, and they were the same problem seen from two sides.

Distributing a GPL binary obliges the distributor to supply its Corresponding Source: the exact configuration and build scripts used to produce it. That build came from elsewhere and this project has no recipe for it, so the obligation could not be met. Committing the binaries to a public repository *is* distribution, as is shipping them inside the signed app, which `release.sh` does.

None of it bought anything. Every GPL component in that build is a video **encoder**, and FilmStrip has never encoded video. The replacement drops them, which removes the obligation rather than trying to satisfy it, and takes the repository's payload with it.

**The v1.8.1, v1.8.2 and v1.8.3 DMG assets were deleted deliberately and must not be restored** — each contained that GPL binary, so re-uploading any of them resumes distributing it. The git tags are kept, as `release.sh` keeps every tag. The release pages are not: it prunes old pages as new versions ship, and v1.8.1's and v1.8.2's were gone by 2026-09-17, with v1.8.3's to follow. A missing page is that pruning, not damage — do not recreate one, and never with a DMG attached. v1.9.0 is the first release carrying the LGPL build.

The old binaries also remain in git history for tags up to v1.8.3. That is a record, not a distribution channel, and nothing in any current build path references them.

## Refresh after clone

```bash
./scripts/fetch-ffmpeg.sh
```

Safe to run repeatedly — it skips the network when the local files already match the manifest checksums.
