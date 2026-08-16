# Architecture

## Goal

Reconstruct a magazine spread from two overlapping flatbed scans while minimizing geometric distortion and doubled text.

## Pipeline

1. Read lossless A and B.
2. Rotate B 180° when requested.
3. Downsample and convert to grayscale for registration only.
4. Detect SIFT features and retain mutual Lowe-ratio matches.
5. Estimate B→A transform with RANSAC.
6. Prefer translation/rigid/similarity; affine is explicit/guarded work, never homography.
7. Keep A fixed. Compute output bounds and warp B once at full resolution.
8. Build overlap residual from intensity and gradients.
9. Find a mostly vertical minimum-cost seam.
10. Composite with hard ownership away from the seam and a narrow feather around it.
11. Emit metrics and diagnostics; reject uncertain automatic output unless forced.

## Why not `cv::Stitcher` as the engine?

The generic stitcher is useful as a baseline, but production needs strict transform constraints, an invariant scan A, domain-specific confidence, and seam behavior that does not smear repeated fine print across a wide multiband blend.

## Confidence inputs

The current score uses inlier count/ratio, reprojection error, transform sanity, overlap plausibility, and residual improvement. The JSON schema deliberately exposes the underlying measurements because the thresholds must be calibrated from real scan pairs.

## Planned macOS layers

- SwiftUI app for import, preview, confidence display, crop, and manual correction.
- Objective-C++ bridge into this engine.
- macOS Image I/O for TIFF/PNG encoding plus DPI, ICC profile, and metadata preservation.
- Folder import/watch first; scanner integration only after real-device validation.
