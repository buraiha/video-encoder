#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="local/ffmpeg-encoder:latest"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
IN_DIR="${BASE_DIR}/in"
OUT_DIR="${BASE_DIR}/out"

mkdir -p "${IN_DIR}" "${OUT_DIR}"

shopt -s nullglob

INPUT_FILES=("${IN_DIR}"/*)

if [ ${#INPUT_FILES[@]} -eq 0 ]; then
  echo "No input files found in ${IN_DIR}"
  exit 1
fi

for input_file in "${INPUT_FILES[@]}"; do
  if [ ! -f "${input_file}" ]; then
    continue
  fi

  input_basename="$(basename "${input_file}")"
  input_path="/in/${input_basename}"
  stem="${input_basename%.*}"
  output_path="/out/${stem}_720p.mp4"

  echo "Encoding ${input_basename} -> ${stem}_720p.mp4"

  podman run --rm \
    -v "${IN_DIR}:/in:ro" \
    -v "${OUT_DIR}:/out" \
    "${IMAGE_NAME}" \
    -y \
    -i "${input_path}" \
    -map "0:v:0" \
    -map "0:a?" \
    -c:v libx264 \
    -preset medium \
    -crf 23 \
    -vf "scale=-2:720" \
    -c:a aac \
    -b:a 128k \
    -movflags +faststart \
    "${output_path}"
done
