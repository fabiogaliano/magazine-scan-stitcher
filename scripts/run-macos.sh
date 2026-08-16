#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "Usage: bash scripts/run-macos.sh A.tif B.tif output.tif [180|0]" >&2
  exit 2
fi

A=$1
B=$2
OUT=$3
ROTATE=${4:-180}

if [[ "$ROTATE" != "180" && "$ROTATE" != "0" ]]; then
  echo "Rotation must be 180 or 0" >&2
  exit 2
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$ROOT/build"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required. Install it first, then run: brew install cmake opencv" >&2
  exit 3
fi

if ! command -v cmake >/dev/null 2>&1 || ! brew --prefix opencv >/dev/null 2>&1; then
  echo "Missing build dependencies. Run: brew install cmake opencv" >&2
  exit 3
fi

OPENCV_PREFIX=$(brew --prefix opencv)
cmake -S "$ROOT" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOpenCV_DIR="$OPENCV_PREFIX/lib/cmake/opencv4"
cmake --build "$BUILD" -j

STEM=${OUT%.*}
EXTRA=()
if [[ "${OVERWRITE:-0}" == "1" ]]; then
  EXTRA+=(--overwrite)
fi

set +e
"$BUILD/magstitch" "$A" "$B" \
  --rotate-b "$ROTATE" \
  --model auto \
  --output "$OUT" \
  --preview "${STEM}-preview.jpg" \
  --metrics "${STEM}-metrics.json" \
  --debug "${STEM}-debug" \
  "${EXTRA[@]}"
STATUS=$?
set -e

case "$STATUS" in
  0)
    echo "Stitch accepted: $OUT"
    echo "Preview: ${STEM}-preview.jpg"
    ;;
  4)
    echo "Automatic alignment was rejected; no final TIFF/PNG was written." >&2
    echo "Inspect: ${STEM}-preview.jpg and ${STEM}-debug/" >&2
    ;;
  5)
    echo "Low-confidence output was written because --force was used." >&2
    ;;
  *)
    echo "magstitch failed with exit code $STATUS" >&2
    ;;
esac

exit "$STATUS"
