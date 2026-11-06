# 净影 / JingYing

Personal offline iPhone RAW and JPEG AI denoiser. Target: iPhone 14 Pro Max, iOS 17+.

## Current implementation

- LibRaw 0.22.3 Bayer decoding → RawNIND Bayer model → sensor-space strength blend → uncompressed 16-bit CFA DNG.
- ImageIO/Core Image JPEG decoding → NIND RGB model → strength blend → sRGB JPEG.
- Serial overlapped tiles, reflected borders, user cancellation between inference calls, 1024-pixel ROI test and full-size processing.
- CPU baseline with two inference threads. Neural Engine performance is not claimed. Keep the app in the foreground during processing.
- Default strength 35%; no sharpening applied. Full-strength denoising can remove real aircraft details.
- Output filenames are unique. Original source files are never overwritten; imports are copied to app Documents.

## Lens correction

Correction is deliberately a separate **rendered JPEG export**, not a warp of the Bayer mosaic. The native DNG export retains sensor geometry. For RAW correction, use Apple's decoder only when it reports lens correction support. Otherwise an exact full-frame FE 24–105mm F4 G OSS profile from Lensfun supplies distortion, transverse CA and vignetting; this fallback crops 4% from each edge. JPEG correction requires explicit opt-in because Sony's in-camera corrections may already be baked in.

FE 70–200mm F2.8 GM OSS II and FE PZ 16–35mm F4 G have **no substituted profile**. Availability depends on the system decoder for the actual input file. This is not a claim of complete profile support for those lenses. Lens correction and DNG colour must be checked on real files before batch use.

## Build and install

Run the manual `Build iPhone denoiser` GitHub Actions workflow. It uses a macOS runner to build an unsigned device app, then packages `PhotoDenoise-unsigned.ipa`. No Apple passwords, signing certificates, photo files or GitHub secrets belong in this repository. Download the successful build artifact and use iLoader on Windows with your own Apple account to sign/install. Complete device trust, developer mode and account prompts yourself. Free personal signing has renewal limits.

## Validation status

This is an initial implementation; compilation results and device testing are separate. Never represent source code or an unsuccessful build as an installable app. Physical iPhone memory, heat, speed, Apple RAW compatibility and image quality require device tests. DNG is uncompressed and large; this version processes one file at a time.

## Licensing

App source: GPL-3.0-or-later. Model and third-party licenses are described in `THIRD_PARTY.md` and bundled model cards. No model training or online image processing occurs in the app.
