#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="local/ffmpeg-encoder:latest"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

podman build -t "${IMAGE_NAME}" .
echo "built: ${IMAGE_NAME}"
