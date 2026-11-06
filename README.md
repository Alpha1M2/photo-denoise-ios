# 净影 / JingYing

Personal offline iPhone RAW and JPEG AI denoiser. Target: iPhone 14 Pro Max, iOS 17+.

## Current implementation

- LibRaw 0.22.3 Bayer decoding → RawNIND Bayer model → sensor-space strength blend → uncompressed 16-bit CFA DNG.
- ImageIO/Core Image JPEG decoding → NIND RGB model → strength blend → sRGB JPEG.
- Serial overlapped tiles, reflected borders, user cancellation between inference calls, full-size processing, free pan/zoom and comparison without viewport reset.
- CPU baseline with two inference threads, optional Core ML CPU/Neural Engine scheduling and per-model session reuse. Actual accelerator placement, quality and speed require physical-device measurement.
- Default strength 50%; no sharpening applied. Full-strength denoising can remove real aircraft details.
- Output filenames are unique. Original source files are never overwritten; imports are copied to app Documents.

## Lens correction

Correction is a separate **16-bit linear RGB DNG export**, not a warp of the Bayer mosaic. The RGB model receives floating-point sRGB; output is inverse-transfer-encoded into linear RGB before DNG serialization. The native DNG export retains sensor geometry. For RAW correction, use Apple's decoder only when it reports lens correction support. Otherwise an exact full-frame FE 24–105mm F4 G OSS profile from Lensfun supplies distortion, transverse CA and vignetting; this fallback crops 4% from each edge. JPEG input correction requires explicit opt-in because Sony's in-camera corrections may already be baked in.

FE 70–200mm F2.8 GM OSS II and FE PZ 16–35mm F4 G have **no substituted profile**. Availability depends on the system decoder for the actual input file. This is not a claim of complete profile support for those lenses. Lens correction and DNG colour must be checked on real files before batch use.

## Build and install

Run the manual `Build iPhone denoiser` GitHub Actions workflow. It uses a macOS runner to build an unsigned device app, then packages `PhotoDenoise-unsigned.ipa`. No Apple passwords, signing certificates, photo files or GitHub secrets belong in this repository. Download the successful build artifact and use iLoader on Windows with your own Apple account to sign/install. Complete device trust, developer mode and account prompts yourself. Free personal signing has renewal limits.

## Validation status

This is an initial implementation; compilation results and device testing are separate. Never represent source code or an unsuccessful build as an installable app. Physical iPhone memory, heat, speed, Apple RAW compatibility and image quality require device tests. DNG is uncompressed and large; this version processes one file at a time.

## Licensing

App source: GPL-3.0-or-later. Model and third-party licenses are described in `THIRD_PARTY.md` and bundled model cards. No model training or online image processing occurs in the app.

## Mobile workflow acceptance

Target: Sony A1 II ARW → denoise and optical correction → linear DNG → native Photos → Snapseed. The requested device reports iOS 27.3. Device Photos and Snapseed compatibility has not been verified. The app includes direct PhotoKit original-file saving; permission is requested only when saving. Simulator decoder success is not equivalent to physical device workflow acceptance.

## Optional local linear model (0.3)

A locally supplied `local-linear.onnx` enables an experimental RAW route: neutral demosaic (camera white balance, no automatic brightness, linear sRGB), FP32 inference and strength blending in linear light, then 16-bit linear DNG. The tensor contract is NCHW float32 RGB, 512x512 input and central 288x288 output, with 112-pixel reflected context. JPEG without correction still uses NIND.

No proprietary model or extraction tooling is included in this repository or CI artifacts. The optional backend is not a claim of Lightroom equivalence. Linear sRGB rendering bakes in demosaic and white balance and clips to the output gamut/range; it does not retain all original sensor editing latitude. Public CI uses an independently generated crop-only fixture exclusively in its simulator bundle to test this route, not to demonstrate denoising quality.

Uncorrected local-model RAW uses a private temporary 16-bit RGB buffer to avoid a Core Image TIFF roundtrip before inference. Corrected input still uses Core Image and resampling. A synthetic test validates the direct buffer, tile indexing and DNG samples independently of denoising quality.

## Preview and continued rendering (0.4)

Pan/zoom to a detail, then use Preview. The visible image region selects a native-resolution crop capped at 1024 pixels on the longest side. Only intersecting tiles run, on the same grid and with the same surrounding pixels as full rendering. The patch stays at its image coordinates when panning/comparing; preview output is never exported as a completed full photo. Changing strength requires another preview.

Measured tile times estimate remaining inference work and, after a preview, whole-image processing time. Preparation, writing and thermal/system scheduling can add time. This is an estimate, not a timer promise.

Full renders prepare image buffers in the foreground, then request iOS 26+ BGContinuedProcessingTask for CPU inference. No background GPU entitlement is required. The system may decline or expire the request; the UI reports limited background availability and expiration cancels safely. Older systems have only limited UIKit background time. Do not force-quit the app. Completion sends a local notification if permission was granted and preserves the completed output path. Physical-device background scheduling, signing compatibility and notification delivery still require verification.

## Local lens catalog (0.5)

`Scripts/convert-lcp.py` converts a user-supplied LCP directory into a JSON catalog. The optional `local-sony-lcp.json` is added to the personal package locally; proprietary calibration data are never committed or uploaded to CI. Exact normalized lens names select RAW profiles; ambiguous matches require a camera match. The renderer uses rectilinear/fisheye distortion and polynomial vignetting with focal-length, focus-distance and aperture interpolation and automatically crops invalid borders. Unknown focus uses the farthest available calibration. LibRaw supplies a neutral linear image so native correction is not applied twice.

Distortion, vignetting and lateral chromatic aberration have separate switches. Sony ARW SubIFD correction curves take priority when present, including red/blue channel scaling; otherwise exact LCP profiles supply distortion, polynomial vignetting and relative chromatic models when supplied. Piecewise vignette samples are retained but the LCP fallback uses the accompanying polynomial approximation. Unsupported switches are disabled. This is not a claim of Lightroom parity or full validation of every calibration. Coordinate models were cross-checked against RawTherapee's open-source `rtengine/lcp.cc` and `rtengine/lensmetadata.cc`: https://github.com/RawTherapee/RawTherapee . Real lens/camera combinations still require visual testing.

The optional local FP16 model keeps float32 input/output and is selected only for Core ML. CPU mode retains the FP32 model. Core ML compilation is cached and inference sessions are reused. Desktop numerical comparison is separate from device accelerator validation; no measured iPhone speedup is claimed. Remaining time updates every second from measured tile throughput and is recalibrated as work completes.
