# Magazine Scan macOS app

This is the product UI. The C++ `magstitch` CLI in the repository remains an experimental registration engine; the app is designed around the complete scan workflow.

## Current workflow

- Discover connected macOS scanners and open native scanner controls.
- Import existing TIFF, PNG, and JPEG scans when a scanner is not available.
- Multi-page TIFFs automatically become multiple review pages.
- Review every page independently: rotate 90°, fine deskew, auto-crop suggestion, manual crop handles, explicit crop validation.
- For sessions with at least two pages, switch to **Align Pair** for transparency overlay, drag alignment, pixel nudging, fine rotation, and a conservative **Auto Align** starting suggestion based only on the expected edge overlap.
- Export a corrected single page or an aligned two-page spread as TIFF, PNG, or JPEG.
- ImageIO export starts from the source page's metadata dictionary so DPI/profile metadata has a preservation path instead of being discarded by OpenCV.

## Run from source

```bash
cd macos
swift run MagazineScan
```

## Build a `.app`

```bash
cd macos
bash build-app.sh
open "dist/Magazine Scan.app"
```

The generated app is ad-hoc signed for local use. CI also packages the app as `MagazineScan-macOS.zip` so a green workflow run has a downloadable build.

## UX rule

Stitching is optional. A one-page scan should feel complete without ever seeing alignment controls. Every scan follows the same review loop: scan/import → crop/rotate/deskew → validate → export. Pair alignment is revealed only when a session contains two or more pages, and automatic alignment is only a suggestion that must be checked with the overlay.

## Validation status

The macOS target is compiled in GitHub Actions on macOS. Scanner discovery and the native scan panel compile against ImageCaptureCore/Quartz, but physical scanner behavior still needs validation on the target hardware. Auto-crop and pair alignment are deliberately conservative and always leave the user in control of the final crop/alignment.
