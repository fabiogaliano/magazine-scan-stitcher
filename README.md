# Magazine Scan

A macOS app for scanning, reviewing, correcting, and exporting magazine pages. Two-page alignment is an optional workflow inside the app rather than the whole product.

## Product workflow

1. **Scan or import** — use a connected scanner, or import TIFF/PNG/JPEG files. Multi-page TIFFs become multiple pages in the session.
2. **Review each page** — rotate, fine-deskew, request an auto-crop suggestion, adjust the crop manually, then explicitly validate it.
3. **Align a pair when needed** — when there are at least two pages, switch to **Align Pair** and use transparency overlay, drag, pixel nudging, fine rotation, or a conservative edge-overlap Auto Align suggestion.
4. **Export** — save a corrected single page or an aligned spread as TIFF, PNG, or JPEG.

The app is intentionally manual-first. Automatic crop/alignment should save time, but the user always gets a visual validation step before export.

## Run the macOS app

```bash
git clone https://github.com/fabiogaliano/magazine-scan-stitcher.git
cd magazine-scan-stitcher/macos
swift run MagazineScan
```

To build a local `.app` bundle:

```bash
cd macos
bash build-app.sh
open "dist/Magazine Scan.app"
```

GitHub Actions also builds and packages `Magazine Scan.app` on macOS as a downloadable `MagazineScan-macOS` artifact.

See [`macos/README.md`](macos/README.md) for app details.

## What the app currently includes

- SwiftUI macOS interface with page sidebar and review workspace.
- Scanner discovery and native scanner controls using ImageCaptureCore/Quartz.
- TIFF/PNG/JPEG import and multi-page TIFF loading.
- 90° rotation plus fine deskew.
- Conservative auto-crop suggestion with draggable crop rectangle and corner handles.
- Explicit crop validation before export.
- Optional pair-alignment workspace with opacity overlay, flicker, drag, numeric offsets, pixel nudges, and fine rotation.
- Edge-overlap Auto Align suggestion designed to avoid the false full-page matches seen in real magazine scans.
- ImageIO-based TIFF/PNG/JPEG export using the source image property dictionary as the metadata starting point.

## Current limitations

- Physical scanner behavior still needs testing on the target scanner; CI verifies the macOS code and app bundle compile, not the hardware.
- Auto-crop is a suggestion, not a final crop detector. The user validates it.
- Pair Auto Align is translation-only and intentionally searches a narrow expected edge-overlap range. It is a starting position, not an archival-quality decision.
- Pair export currently uses the chosen geometry directly; seam/blend refinement can be added after the manual workflow has been validated on more real scans.
- Metadata handling is better than the earlier OpenCV-only path, but exact archival preservation of every TIFF/ICC tag still needs real-file validation.

## Experimental C++ registration engine

The repository also contains the original C++17/OpenCV `magstitch` CLI. It remains useful for registration experiments, confidence metrics, diagnostics, and synthetic tests, but it is no longer the primary user experience.

Build it with:

```bash
brew install cmake opencv
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
```

It accepts either two separate images or a two-page TIFF. See the CLI source and `scripts/run-macos.sh` for the low-level workflow.
