# magazine-scan-stitcher

A narrow, distortion-conscious prototype for stitching two overlapping flatbed scans of a magazine spread.

The production direction is a custom OpenCV registration pipeline rather than a generic panorama stitcher. Scan A is never geometrically resampled. Scan B is optionally rotated 180°, registered to A, warped once at full resolution, and joined through a low-error mostly vertical seam with a narrow feather.

## Prototype status

This repository is **Phase 2 / CLI-first**. It implements:

- C++17 + OpenCV engine and `magstitch` CLI.
- SIFT features on downsampled grayscale images.
- Lowe-ratio filtering plus mutual matching.
- RANSAC similarity estimation using `estimateAffinePartial2D`.
- `auto|translation|rigid|similarity|affine` model selection.
- Fixed A; only B is warped.
- Full-resolution canvas composition.
- Residual/gradient seam cost and a mostly vertical dynamic-programming seam.
- Narrow feather blending instead of wide multiband blending.
- Confidence metrics, hard rejection reasons, and distinct low-confidence exit behavior.
- Diagnostic match, overlap, seam, and JSON outputs.
- Synthetic geometry tests.

Not implemented yet: GUI, scanner control, OCR, non-rigid warping, ECC refinement, exposure compensation, or automatic homography.

### Important archival limitation

OpenCV writes the output pixels losslessly for TIFF/PNG, but this first scaffold does **not yet copy DPI/ICC/TIFF metadata from scan A**. The macOS app layer should use Image I/O for explicit metadata preservation before archival use. Until that lands, treat output as a geometry/compositing prototype rather than final archival output.

## Build

Requirements: CMake 3.20+, a C++17 compiler, and OpenCV 4.5+ with `features2d`, `calib3d`, `imgproc`, and `imgcodecs`.

On macOS with Homebrew:

```bash
brew install cmake opencv
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
```

## Usage

```bash
./build/magstitch A.tif B.tif \
  --rotate-b 180 \
  --model auto \
  --output spread.tif \
  --metrics metrics.json \
  --debug debug/
```

A low-confidence run writes diagnostics and exits nonzero without producing the final image. `--force` allows writing an explicitly forced output.

Exit codes:

- `0`: accepted output written.
- `2`: CLI usage error.
- `3`: processing/I/O failure.
- `4`: automatic alignment rejected; no output written.
- `5`: low-confidence output written because `--force` was supplied.

## Model policy

`auto` starts from a similarity estimate. It snaps down to translation or rigid only when the measured scale/rotation is already negligible. Full affine is opt-in for the prototype; homography is intentionally unavailable. The current sanity thresholds are conservative placeholders and must be calibrated on real scans.

## Next validation step

Run representative real A/B pairs at the intended scan resolution. Compare transform residuals, seam placement, small text, halftone regions, and gutter behavior against a constrained `cv::Stitcher` SCANS baseline and a Hugin flat-scan project. Do not tune confidence thresholds from synthetic tests alone.
