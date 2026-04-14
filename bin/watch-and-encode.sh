#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN_DIR="${BASE_DIR}/bin"
INBOX_720="${BASE_DIR}/inbox-720p"
INBOX_1080="${BASE_DIR}/inbox-1080p"
WORKING_DIR="${BASE_DIR}/working"
LOG_FILE="${BASE_DIR}/logs/watcher.log"
STATE_DIR="${BASE_DIR}/logs/.watcher-state"
LOCK_DIR="${STATE_DIR}/lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
SNAPSHOT_720="${STATE_DIR}/inbox-720p.lst"
SNAPSHOT_1080="${STATE_DIR}/inbox-1080p.lst"

mkdir -p "$INBOX_720" "$INBOX_1080" "$WORKING_DIR" "${BASE_DIR}/logs" "$STATE_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

acquire_lock() {
  local active_pid=""

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_PID_FILE"
    return 0
  fi

  if [ -f "$LOCK_PID_FILE" ]; then
    active_pid="$(cat "$LOCK_PID_FILE" 2>/dev/null || true)"
    if [ -n "$active_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
      log "another run is active: pid=${active_pid}"
      exit 0
    fi
  fi

  log "stale lock detected, recovering"
  rm -f "$LOCK_PID_FILE"
  rmdir "$LOCK_DIR" 2>/dev/null || true

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_PID_FILE"
    return 0
  fi

  log "failed to acquire lock"
  exit 1
}

release_lock() {
  rm -f "$LOCK_PID_FILE"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

list_valid_ts() {
  local dir="$1"

  find "$dir" -maxdepth 1 -type f -name '*.ts' ! -name '.*' ! -name '._*' | sort
}

log_snapshot_diff() {
  local profile="$1"
  local inbox_dir="$2"
  local snapshot_file="$3"
  local current_file=""
  local path=""

  current_file="$(mktemp "${TMPDIR:-/tmp}/video-encoder.${profile}.XXXXXX")"
  list_valid_ts "$inbox_dir" > "$current_file"

  if [ -f "$snapshot_file" ]; then
    while read -r path; do
      [ -n "$path" ] || continue
      log "queue added profile=${profile} file=${path}"
    done < <(comm -13 "$snapshot_file" "$current_file")

    while read -r path; do
      [ -n "$path" ] || continue
      log "queue removed profile=${profile} file=${path}"
    done < <(comm -23 "$snapshot_file" "$current_file")
  else
    while read -r path; do
      [ -n "$path" ] || continue
      log "queue added profile=${profile} file=${path}"
    done < "$current_file"
  fi

  mv "$current_file" "$snapshot_file"
}

is_valid_ts() {
  local f="$1"
  local b
  b="$(basename "$f")"

  [ -f "$f" ] || return 1
  [[ "$b" == *.ts ]] || return 1
  [[ "$b" == .* ]] && return 1
  [[ "$b" == "._"* ]] && return 1

  return 0
}

process_one() {
  local profile="$1"
  local f="$2"

  if ! is_valid_ts "$f"; then
    log "skip invalid file: $f"
    return 0
  fi

  log "dispatch profile=${profile} file=${f}"
  if "$BIN_DIR/encode-one.sh" "$profile" "$f"; then
    log "done profile=${profile} file=${f}"
    return 0
  else
    log "ERROR profile=${profile} file=${f}"
    return 0
  fi
}

drain_queue() {
  local found=1
  local f720=""
  local f1080=""

  while [ "$found" -eq 1 ]; do
    found=0

    f720="$(find "$INBOX_720" -maxdepth 1 -type f -name '*.ts' ! -name '.*' ! -name '._*' | sort | head -n 1)"
    if [ -n "$f720" ]; then
      found=1
      process_one 720p "$f720"
      continue
    fi

    f1080="$(find "$INBOX_1080" -maxdepth 1 -type f -name '*.ts' ! -name '.*' ! -name '._*' | sort | head -n 1)"
    if [ -n "$f1080" ]; then
      found=1
      process_one 1080p "$f1080"
      continue
    fi
  done
}

recover_working() {
  local f=""
  log "recovering leftover files in working/"
  find "$WORKING_DIR" -maxdepth 1 -type f -name '*.ts' ! -name '.*' ! -name '._*' | sort | while read -r f; do
    case "$(basename "$f")" in
      720p__*)
        process_one 720p "$f"
        ;;
      1080p__*)
        process_one 1080p "$f"
        ;;
      *)
        log "skip unknown leftover: $f"
        ;;
    esac
  done
}

main() {
  trap release_lock EXIT INT TERM
  acquire_lock

  log "cron watcher starting"

  log_snapshot_diff 720p "$INBOX_720" "$SNAPSHOT_720"
  log_snapshot_diff 1080p "$INBOX_1080" "$SNAPSHOT_1080"

  recover_working
  drain_queue

  log "cron watcher finished"
}

main
