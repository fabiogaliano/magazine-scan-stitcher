#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/run-macos.sh scans.tiff output.tif [180|0]
  bash scripts/run-macos.sh A.tif B.tif output.tif [180|0]
EOF
}

INPUTS=()
ROTATE=180

case $# in
  2)
    INPUTS=("$1")
    OUT=$2
    ;;
  3)
    if [[ "$3" == "180" || "$3" == "0" ]]; then
      INPUTS=("$1")
      OUT=$2
      ROTATE=$3
    else
      INPUTS=("$1" "$2")
      OUT=$3
    fi
    ;;
  4)
    INPUTS=("$1" "$2")
    OUT=$3
    ROTATE=$4
    ;;
  *)
    usage
    exit 2
    ;;
esac

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
"$BUILD/magstitch" "${INPUTS[@]}" \
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
