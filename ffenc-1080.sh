#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="local/ffmpeg-encoder:latest"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
IN_DIR="${BASE_DIR}/in"
OUT_DIR="${BASE_DIR}/out"

mkdir -p "${IN_DIR}" "${OUT_DIR}"

if [ $# -lt 1 ]; then
  echo "usage: $0 <input.ts>"
  exit 1
fi

INPUT_BASENAME="$(basename "$1")"
INPUT_PATH="/in/${INPUT_BASENAME}"
STEM="${INPUT_BASENAME%.*}"
OUTPUT_PATH="/out/${STEM}_1080p.mp4"

podman run --rm \
  -v "${IN_DIR}:/in:ro" \
  -v "${OUT_DIR}:/out" \
  "${IMAGE_NAME}" \
  -y \
  -i "${INPUT_PATH}" \
  -map 0:v:0 \
  -map 0:a:0? \
  -c:v libx264 \
  -preset medium \
  -crf 23 \
  -vf "scale='min(1920,iw)':-2" \
  -c:a aac \
  -b:a 192k \
  -movflags +faststart \
  "${OUTPUT_PATH}"
