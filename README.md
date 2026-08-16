# magazine-scan-stitcher

A narrow, distortion-conscious prototype for stitching two overlapping flatbed scans of a magazine spread.

The production direction is a custom OpenCV registration pipeline rather than a generic panorama stitcher. Scan A is never geometrically resampled. Scan B is optionally rotated 180°, registered to A, warped once at full resolution, and joined through a low-error mostly vertical seam with a narrow feather.

## Try it on real scans

On a Mac with Homebrew, the shortest path is:

```bash
brew install cmake opencv
git clone https://github.com/fabiogaliano/magazine-scan-stitcher.git
cd magazine-scan-stitcher
bash scripts/run-macos.sh A.tif B.tif spread.tif
```

The helper builds the CLI and writes:

- `spread.tif` when automatic alignment passes confidence checks.
- `spread-preview.jpg` for quick visual inspection, even when alignment is rejected.
- `spread-metrics.json` with registration/confidence measurements.
- `spread-debug/` with match, overlap, seam, and metrics diagnostics.

The helper assumes B should be rotated 180°. Pass `0` as the fourth argument when it should not be rotated:

```bash
bash scripts/run-macos.sh A.tif B.tif spread.tif 0
```

Existing final outputs are not overwritten by default. For an intentional rerun:

```bash
OVERWRITE=1 bash scripts/run-macos.sh A.tif B.tif spread.tif
```

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
- Diagnostic match, overlap, seam, preview, and JSON outputs.
- Synthetic geometry tests.

Not implemented yet: GUI, scanner control, OCR, non-rigid warping, ECC refinement, exposure compensation, or automatic homography.

### Important archival limitation

OpenCV writes the output pixels losslessly for TIFF/PNG, but this prototype does **not yet copy DPI/ICC/TIFF metadata from scan A**. Until the macOS Image I/O layer lands, treat output as a geometry/compositing prototype rather than final archival output.

## Build manually

Requirements: CMake 3.20+, a C++17 compiler, and OpenCV 4.5+ with `features2d`, `calib3d`, `imgproc`, and `imgcodecs`.

```bash
brew install cmake opencv
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
```

## CLI usage

```bash
./build/magstitch A.tif B.tif \
  --rotate-b 180 \
  --model auto \
  --output spread.tif \
  --preview spread-preview.jpg \
  --metrics spread-metrics.json \
  --debug spread-debug/
```

Final output is restricted to TIFF or PNG. A low-confidence run can still write the requested preview and diagnostics, but exits nonzero without writing the final archival image. `--force` allows writing an explicitly forced output. `--overwrite` must be supplied to replace an existing final output.

Exit codes:

- `0`: accepted output written.
- `2`: CLI usage or argument error.
- `3`: processing/I/O failure.
- `4`: automatic alignment rejected; no final output written.
- `5`: low-confidence output written because `--force` was supplied.

## Model policy

`auto` starts from a similarity estimate. It snaps down to translation or rigid only when the measured scale/rotation is already negligible. Full affine is opt-in for the prototype; homography is intentionally unavailable. The current sanity thresholds are conservative placeholders and must be calibrated on real scans.

## What matters next

Run representative real A/B pairs at the intended scan resolution. Check small text, halftone regions, gutter behavior, seam placement, and whether the confidence gate agrees with visual quality. The next engineering work should be driven by those failures rather than by adding more registration features speculatively.
