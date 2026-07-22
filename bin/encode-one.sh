#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <720p|1080p> /path/to/file.ts"
  exit 1
fi

PROFILE="$1"
INPUT="$2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKING_DIR="${BASE_DIR}/working"
LOG_DIR="${BASE_DIR}/logs"

case "$PROFILE" in
  720p)
    VFILTER="yadif,scale=1280:-2"
    OUT_DIR="${BASE_DIR}/out/720p"
    DONE_DIR="${BASE_DIR}/done/720p"
    FAILED_DIR="${BASE_DIR}/failed/720p"
    WORK_PREFIX="720p__"
    ;;
  1080p)
    VFILTER="yadif"
    OUT_DIR="${BASE_DIR}/out/1080p"
    DONE_DIR="${BASE_DIR}/done/1080p"
    FAILED_DIR="${BASE_DIR}/failed/1080p"
    WORK_PREFIX="1080p__"
    ;;
  *)
    echo "unknown profile: $PROFILE"
    exit 1
    ;;
esac

mkdir -p "$WORKING_DIR" "$OUT_DIR" "$DONE_DIR" "$FAILED_DIR" "$LOG_DIR"

if [ ! -f "$INPUT" ]; then
  echo "file not found: $INPUT"
  exit 1
fi

BASENAME="$(basename "$INPUT")"
STEM="${BASENAME%.*}"

case "$BASENAME" in
  .*|._*)
    echo "skip hidden/appledouble file: $INPUT"
    exit 0
    ;;
esac

if [[ "$BASENAME" == "${WORK_PREFIX}"* ]]; then
  ORIG_BASENAME="${BASENAME#${WORK_PREFIX}}"
  WORK_FILE="$INPUT"
  STEM="${ORIG_BASENAME%.*}"
else
  ORIG_BASENAME="$BASENAME"
  WORK_FILE="${WORKING_DIR}/${WORK_PREFIX}${ORIG_BASENAME}"
fi

OUT_FILE="${OUT_DIR}/${STEM}.mp4"
LOG_FILE="${LOG_DIR}/${STEM}.${PROFILE}.log"

move_to_failed() {
  local reason="$1"
  local src_file="$2"
  local base_name="$3"
  local reason_tag=""
  local failed_name=""

  reason_tag="${reason//[^A-Za-z0-9_-]/_}"
  [ -n "$reason_tag" ] || reason_tag="failed"

  failed_name="${reason_tag}_${base_name}"

  if [ -e "${FAILED_DIR}/${failed_name}" ]; then
    failed_name="${reason_tag}_$(date '+%Y%m%d%H%M%S')_${base_name}"
  fi

  if [ -f "$src_file" ]; then
    mv "$src_file" "${FAILED_DIR}/${failed_name}"
    echo "[$(date '+%F %T')] moved to failed: ${FAILED_DIR}/${failed_name}" | tee -a "$LOG_FILE"
  else
    echo "[$(date '+%F %T')] failed source not found: $src_file" | tee -a "$LOG_FILE"
  fi
}

if [ -e "$OUT_FILE" ]; then
  echo "output already exists: $OUT_FILE"
  if [ -f "$INPUT" ]; then
    move_to_failed "duplicate" "$INPUT" "$ORIG_BASENAME"
  elif [ -f "$WORK_FILE" ]; then
    move_to_failed "duplicate" "$WORK_FILE" "$ORIG_BASENAME"
  fi
  exit 2
fi

if [ "$INPUT" != "$WORK_FILE" ]; then
  mv "$INPUT" "$WORK_FILE"
fi

echo "[$(date '+%F %T')] start profile=${PROFILE} input=${WORK_FILE}" | tee -a "$LOG_FILE"

if nice -n 19 ionice -c2 -n7 ffmpeg -hide_banner -y \
  -i "$WORK_FILE" \
  -map 0:v:0 -map 0:a:0? \
  -vf "$VFILTER" \
  -c:v libx264 -preset veryfast -crf 23 \
  -c:a aac -b:a 192k \
  -movflags +faststart \
  "$OUT_FILE" >> "$LOG_FILE" 2>&1
then
  mv "$WORK_FILE" "${DONE_DIR}/${ORIG_BASENAME}"
  echo "[$(date '+%F %T')] success: $OUT_FILE" | tee -a "$LOG_FILE"
else
  move_to_failed "enc_error" "$WORK_FILE" "$ORIG_BASENAME"
  echo "[$(date '+%F %T')] failed: $WORK_FILE" | tee -a "$LOG_FILE"
  exit 1
fi
