#!/usr/bin/env bash
set -euo pipefail

# Resizes a logo so its longest dimension becomes the canvas size,
# then pads the top with 300px of transparent space so text above
# never overlaps the logo.
#
# Usage: ./scripts/process-logo.sh <input> [output]
#   input:  path to source image
#   output: path for processed image (default: <input-basename>_processed.<ext>)

INPUT="${1:-}"
if [[ -z "$INPUT" ]]; then
  echo "Usage: $0 <input-image> [output-image]" >&2
  exit 1
fi

if ! command -v convert &>/dev/null || ! command -v identify &>/dev/null; then
  echo "ERROR: ImageMagick not found. Install it with: brew install imagemagick" >&2
  exit 1
fi

EXT="${INPUT##*.}"
BASENAME="${INPUT%.*}"
OUTPUT="${2:-${BASENAME}_processed.${EXT}}"

read -r W H < <(identify -format "%w %h" "$INPUT")
MAX=$(( W > H ? W : H ))
NEW_HEIGHT=$(( MAX + 300 ))

echo "Input:      $INPUT (${W}x${H})"
echo "Resizing:   ${MAX}x${MAX}"
echo "Canvas:     ${MAX}x${NEW_HEIGHT} (300px top padding)"
echo "Output:     $OUTPUT"

convert "$INPUT" \
  -resize "${MAX}x${MAX}" \
  -gravity South \
  -background none \
  -extent "${MAX}x${NEW_HEIGHT}" \
  "$OUTPUT"

echo "Done."
