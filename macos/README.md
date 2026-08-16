# Magazine Scan macOS app

This is the product UI. The C++ `magstitch` CLI in the repository remains an experimental registration engine; the app is designed around the complete scan workflow.

## Current workflow

- Discover connected macOS scanners and open Apple's native scanner controls.
- Import existing TIFF/PNG/JPEG/PDF scans when a scanner is not available.
- Multi-page TIFFs automatically become multiple review pages.
- Review every page independently: rotate 90°, fine deskew, auto-crop suggestion, manual crop handles, explicit crop validation.
- For sessions with at least two pages, switch to **Align Pair** for transparency overlay, drag alignment, pixel nudging, and fine rotation.
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
./build-app.sh
open "dist/Magazine Scan.app"
```

The generated app is ad-hoc signed for local use. It is intentionally not sandboxed yet; macOS 14+ requires the USB device entitlement for sandboxed ImageCaptureCore apps.

## UX rule

Stitching is optional. A one-page scan should feel complete without ever seeing alignment controls. Every scan follows the same review loop: scan/import → crop/rotate/deskew → validate → export. Pair alignment is revealed only when a session contains two or more pages.
