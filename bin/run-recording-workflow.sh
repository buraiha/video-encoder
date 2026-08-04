#!/usr/bin/env bash
set -uo pipefail

SOURCE_ROOT="/Volumes/recorded"
ENCODER_ROOT="/Volumes/ExtSSD_T72T/video-encoder_exSSD"
ARCHIVE_ROOT="/Volumes/myvideos/★テレビ録画"

INBOX_720="${ENCODER_ROOT}/inbox-720p"
INBOX_1080="${ENCODER_ROOT}/inbox-1080p"
LOG_ROOT="${ENCODER_ROOT}/logs"
RUN_LOG_DIR="${LOG_ROOT}/workflow-runs"
COPY_LOG_DIR="${LOG_ROOT}/copy-runs"
WORKFLOW_LOCK="${LOG_ROOT}/.recording-workflow.lock"
WORKFLOW_PID_FILE="${WORKFLOW_LOCK}/pid"
COPY_LOCK="${LOG_ROOT}/.copy-to-encoder.lock"

EXCLUDED_SOURCE_DIR="${SOURCE_ROOT}/ニュース"
RECENT_SECONDS="${RECENT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-60}"
RUN_ID="${WORKFLOW_RUN_ID:-$(date '+%Y%m%d-%H%M%S')}"
RUN_LOG="${RUN_LOG_DIR}/${RUN_ID}-recording-workflow.log"
COPY_LOG="${COPY_LOG_DIR}/${RUN_ID}.log"
SOURCE_MAP="${COPY_LOG_DIR}/${RUN_ID}-source-map.tsv"
ARCHIVE_LOG="${RUN_LOG_DIR}/${RUN_ID}-archive-after-encode.log"
ARCHIVE_LOCK="${LOG_ROOT}/.${RUN_ID}-archive.lock"

workflow_lock_acquired=0
copy_lock_acquired=0
archive_lock_acquired=0

log_to() {
  local target="$1"
  shift
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$target"
}

workflow_log() {
  log_to "$RUN_LOG" "$@"
}

copy_log() {
  log_to "$COPY_LOG" "$@"
}

archive_log() {
  log_to "$ARCHIVE_LOG" "$@"
}

cleanup_locks() {
  if [ "$archive_lock_acquired" -eq 1 ]; then
    rmdir "$ARCHIVE_LOCK" 2>/dev/null || true
  fi
  if [ "$copy_lock_acquired" -eq 1 ]; then
    rmdir "$COPY_LOCK" 2>/dev/null || true
  fi
  if [ "$workflow_lock_acquired" -eq 1 ]; then
    rm -f "$WORKFLOW_PID_FILE"
    rmdir "$WORKFLOW_LOCK" 2>/dev/null || true
  fi
}

acquire_workflow_lock() {
  local active_pid=""

  if mkdir "$WORKFLOW_LOCK" 2>/dev/null; then
    workflow_lock_acquired=1
    printf '%s\n' "$$" > "$WORKFLOW_PID_FILE"
    return 0
  fi

  active_pid="$(sed -n '1p' "$WORKFLOW_PID_FILE" 2>/dev/null || true)"
  if [ -n "$active_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
    workflow_log "workflow skipped: another workflow is active pid=${active_pid}"
    return 1
  fi

  rm -f "$WORKFLOW_PID_FILE"
  rmdir "$WORKFLOW_LOCK" 2>/dev/null || true

  if mkdir "$WORKFLOW_LOCK" 2>/dev/null; then
    workflow_lock_acquired=1
    printf '%s\n' "$$" > "$WORKFLOW_PID_FILE"
    return 0
  fi

  workflow_log "workflow failed: could not acquire lock"
  return 1
}

encoder_is_busy() {
  [ -d "$COPY_LOCK" ] && return 0

  find \
    "${ENCODER_ROOT}/inbox-720p" \
    "${ENCODER_ROOT}/inbox-1080p" \
    "${ENCODER_ROOT}/working" \
    -type f -name '*.ts' -print -quit 2>/dev/null | grep -q .
}

check_requirements() {
  local missing=0
  local command_name=""

  for command_name in bash find stat rsync iconv sed awk cp mv rm mkdir basename dirname tee grep; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      printf 'MISSING_COMMAND %s\n' "$command_name" >&2
      missing=1
    fi
  done

  for required_dir in "$SOURCE_ROOT" "$ENCODER_ROOT" "$ARCHIVE_ROOT"; do
    if [ ! -d "$required_dir" ]; then
      printf 'MISSING_DIRECTORY %s\n' "$required_dir" >&2
      missing=1
    fi
  done

  if [ "$missing" -ne 0 ]; then
    return 1
  fi

  printf 'CHECK_OK source=%s encoder=%s archive=%s\n' \
    "$SOURCE_ROOT" "$ENCODER_ROOT" "$ARCHIVE_ROOT"
}

copy_recordings() {
  local cutoff_epoch=""
  local eligible_count=0
  local copied_count=0
  local skipped_recent=0
  local skipped_existing=0
  local skipped_encode_error=0
  local failed_count=0
  local source_file=""
  local source_name=""
  local source_mtime=""
  local source_size=""
  local current_mtime=""
  local current_size=""
  local profile=""
  local inbox_dir=""
  local queued_file=""
  local partial_file=""
  local changed_file=""

  if ! mkdir "$COPY_LOCK" 2>/dev/null; then
    copy_log "ERROR another copy run is active lock=${COPY_LOCK}"
    return 75
  fi
  copy_lock_acquired=1

  cutoff_epoch="$(($(date '+%s') - RECENT_SECONDS))"
  printf 'profile\tsource_path\tqueued_path\n' > "$SOURCE_MAP"
  copy_log "copy run starting source=${SOURCE_ROOT} encoder=${ENCODER_ROOT} excluded=${EXCLUDED_SOURCE_DIR} recent_guard_seconds=${RECENT_SECONDS}"

  while IFS= read -r -d '' source_file; do
    source_name="$(basename "$source_file")"

    case "$source_name" in
      enc_error_*)
        skipped_encode_error=$((skipped_encode_error + 1))
        copy_log "SKIPPED_ENCODE_ERROR source=${source_file}"
        continue
        ;;
    esac

    source_mtime="$(stat -f '%m' "$source_file" 2>/dev/null || true)"
    source_size="$(stat -f '%z' "$source_file" 2>/dev/null || true)"
    if [ -z "$source_mtime" ] || [ -z "$source_size" ]; then
      failed_count=$((failed_count + 1))
      copy_log "COPY_FAILED reason=source_stat_failed source=${source_file}"
      continue
    fi

    if [ "$source_mtime" -gt "$cutoff_epoch" ]; then
      skipped_recent=$((skipped_recent + 1))
      copy_log "SKIPPED_RECORDING_OR_RECENT source=${source_file}"
      continue
    fi

    eligible_count=$((eligible_count + 1))

    case "$source_file" in
      "${SOURCE_ROOT}/1080pエンコード物件/"*)
        profile="1080p"
        inbox_dir="$INBOX_1080"
        ;;
      *)
        profile="720p"
        inbox_dir="$INBOX_720"
        ;;
    esac

    queued_file="${inbox_dir}/${source_name}"
    partial_file="${queued_file}.part-${RUN_ID}"

    if [ -e "$queued_file" ]; then
      skipped_existing=$((skipped_existing + 1))
      copy_log "SKIPPED_EXISTING profile=${profile} source=${source_file} queued=${queued_file}"
      continue
    fi

    rm -f "$partial_file"
    copy_log "COPY_START profile=${profile} bytes=${source_size} source=${source_file}"
    if ! rsync -a --progress -- "$source_file" "$partial_file" 2>&1 | tee -a "$COPY_LOG"; then
      failed_count=$((failed_count + 1))
      copy_log "COPY_FAILED profile=${profile} source=${source_file} partial=${partial_file}"
      continue
    fi

    current_mtime="$(stat -f '%m' "$source_file" 2>/dev/null || true)"
    current_size="$(stat -f '%z' "$source_file" 2>/dev/null || true)"
    if [ "$current_mtime" != "$source_mtime" ] || [ "$current_size" != "$source_size" ]; then
      failed_count=$((failed_count + 1))
      changed_file="${partial_file}.source-changed-${RUN_ID}"
      mv "$partial_file" "$changed_file"
      copy_log "COPY_NOT_QUEUED_SOURCE_CHANGED source=${source_file} saved_partial=${changed_file}"
      continue
    fi

    if ! mv "$partial_file" "$queued_file"; then
      failed_count=$((failed_count + 1))
      copy_log "COPY_FAILED reason=queue_finalize_failed profile=${profile} source=${source_file} partial=${partial_file}"
      continue
    fi

    printf '%s\t%s\t%s\n' "$profile" "$source_file" "$queued_file" >> "$SOURCE_MAP"
    copied_count=$((copied_count + 1))
    copy_log "QUEUED profile=${profile} source=${source_file} queued=${queued_file}"
  done < <(
    find "$SOURCE_ROOT" \
      -path "$EXCLUDED_SOURCE_DIR" -prune -o \
      -type f -name '*.ts' ! -name '.*' -print0
  )

  rmdir "$COPY_LOCK" 2>/dev/null || true
  copy_lock_acquired=0

  copy_log "copy run finished eligible=${eligible_count} queued=${copied_count} skipped_recent=${skipped_recent} skipped_existing=${skipped_existing} skipped_encode_error=${skipped_encode_error} failed=${failed_count} map=${SOURCE_MAP}"

  if [ "$failed_count" -ne 0 ]; then
    return 1
  fi
}

queued_count() {
  awk 'NR > 1 && NF >= 3 { count++ } END { print count + 0 }' "$SOURCE_MAP"
}

normalize_utf8() {
  iconv -f UTF-8-MAC -t UTF-8
}

normalize_stem() {
  local stem="$1"

  printf '%s' "$stem" \
    | normalize_utf8 \
    | sed -E \
      -e 's/^(＜(時代劇|3時のサスペンス|お昼のサスペンス|土曜サスペンス|金曜時代劇)＞)+[[:space:]]*//' \
      -e 's/\[(字|解|再|終|デ|二|SS|映|生|新|前|後)\]//g' \
      -e 's/182ch韓ドラ(_[0-9]{4}-[0-9]{2}-[0-9]{2})$/\1/' \
      -e 's/^[[:space:]]+//' \
      -e 's/[[:space:]]+$//' \
      -e 's/[[:space:]]{2,}/ /g'
}

category_for() {
  local source_path="$1"
  local title="$2"
  local source_nfc=""

  source_nfc="$(printf '%s' "$source_path" | normalize_utf8)"

  case "$source_nfc" in
    */二時間ドラマ/*|*＜3時のサスペンス＞*|*＜お昼のサスペンス＞*|*＜土曜サスペンス＞*)
      printf '%s\n' "二時間ドラマ"
      return
      ;;
    */時代劇/*|*＜時代劇＞*|*＜金曜時代劇＞*)
      printf '%s\n' "時代劇"
      return
      ;;
  esac

  case "$title" in
    *美の壺*)
      printf '%s\n' "美の壺"
      ;;
    *暴れん坊将軍*|*鬼平犯科帳*)
      printf '%s\n' "時代劇"
      ;;
    *ミステリー*|*浅見光彦*|*神楽坂署*|*さすらい署長*)
      printf '%s\n' "二時間ドラマ"
      ;;
    *釣りびと*)
      printf '%s\n' "釣り"
      ;;
    *昼酒*|*立ち食いそば*|*晩酌の流儀*|*町中華*|*その酒に人は宿る*)
      printf '%s\n' "酒・グルメ"
      ;;
    *みみより\!解説*|*時論公論*|*視点・論点*)
      printf '%s\n' "時事・ニュース"
      ;;
    *映像の世紀*|*浮世絵EDO-LIFE*|*豊臣兄弟*|*100分de名著*|*英雄たちの選択*|*歴史探偵*)
      printf '%s\n' "歴史ドキュメンタリー"
      ;;
    *京都はんなり紀行*|*京都浪漫*|*新日本風土記*)
      printf '%s\n' "日本の美しいもの"
      ;;
    *中井精也の絶景\!てつたび*|*ヨーロッパ絶景の道*|*世界ふれあい街歩き*|*さわやか自然百景*|*にっぽん百低山*|*地球でイチバン*|*ワールドツアー完璧MAP*)
      printf '%s\n' "アンビエント・旅"
      ;;
    *)
      printf '%s\n' "ドキュメンタリー"
      ;;
  esac
}

expected_source_size() {
  local source_path="$1"

  awk -v source_path="$source_path" '
    index($0, "COPY_START ") && index($0, "source=" source_path) {
      line = $0
      sub(/^.*bytes=/, "", line)
      sub(/ source=.*$/, "", line)
      size = line
    }
    END {
      if (size != "") {
        print size
      }
    }
  ' "$COPY_LOG"
}

mark_encode_error_source() {
  local source_path="$1"
  local source_dir=""
  local source_name=""
  local renamed_path=""

  if [ ! -e "$source_path" ]; then
    archive_log "ENCODE_ERROR_SOURCE_MISSING source=${source_path}"
    return 0
  fi

  source_dir="${source_path%/*}"
  source_name="${source_path##*/}"

  case "$source_name" in
    enc_error_*)
      archive_log "ENCODE_ERROR_ALREADY_PREFIXED source=${source_path}"
      return 0
      ;;
  esac

  renamed_path="${source_dir}/enc_error_${source_name}"
  if [ -e "$renamed_path" ]; then
    archive_log "ENCODE_ERROR_RENAME_FAILED reason=destination_exists source=${source_path} destination=${renamed_path}"
    return 1
  fi

  if mv "$source_path" "$renamed_path"; then
    archive_log "ENCODE_ERROR_SOURCE_RENAMED source=${source_path} destination=${renamed_path}"
    return 0
  fi

  archive_log "ENCODE_ERROR_RENAME_FAILED reason=rename_failed source=${source_path} destination=${renamed_path}"
  return 1
}

count_encode_status() {
  local profile=""
  local source_path=""
  local queued_path=""
  local source_name=""
  local stem=""
  local done_ts=""
  local failed_ts=""
  local out_mp4=""
  local pending=0
  local succeeded=0
  local failed=0

  while IFS=$'\t' read -r profile source_path queued_path; do
    [ "$profile" = "profile" ] && continue
    [ -n "$profile" ] || continue

    source_name="$(basename "$queued_path")"
    stem="${source_name%.ts}"
    done_ts="${ENCODER_ROOT}/done/${profile}/${source_name}"
    failed_ts="${ENCODER_ROOT}/failed/${profile}/${source_name}"
    out_mp4="${ENCODER_ROOT}/out/${profile}/${stem}.mp4"

    if [ -f "$done_ts" ] && [ -f "$out_mp4" ]; then
      succeeded=$((succeeded + 1))
    elif [ -f "$failed_ts" ]; then
      failed=$((failed + 1))
    else
      pending=$((pending + 1))
    fi
  done < "$SOURCE_MAP"

  printf '%s\t%s\t%s\n' "$pending" "$succeeded" "$failed"
}

archive_all() {
  local profile=""
  local source_path=""
  local queued_path=""
  local source_name=""
  local stem=""
  local done_ts=""
  local failed_ts=""
  local out_mp4=""
  local clean_stem=""
  local category=""
  local destination_dir=""
  local destination=""
  local partial=""
  local expected_size=""
  local current_size=""
  local output_size=""
  local partial_size=""
  local archived=0
  local archive_failed=0
  local encode_failed=0
  local cleanup_pending=0
  local source_deleted=0

  while IFS=$'\t' read -r profile source_path queued_path; do
    [ "$profile" = "profile" ] && continue
    [ -n "$profile" ] || continue

    source_name="$(basename "$queued_path")"
    stem="${source_name%.ts}"
    done_ts="${ENCODER_ROOT}/done/${profile}/${source_name}"
    failed_ts="${ENCODER_ROOT}/failed/${profile}/${source_name}"
    out_mp4="${ENCODER_ROOT}/out/${profile}/${stem}.mp4"

    if [ -f "$failed_ts" ] || [ ! -f "$done_ts" ] || [ ! -f "$out_mp4" ]; then
      encode_failed=$((encode_failed + 1))
      archive_log "ENCODE_FAILED source=${source_path}"
      mark_encode_error_source "$source_path" || true
      continue
    fi

    clean_stem="$(normalize_stem "$stem")"
    category="$(category_for "$source_path" "$clean_stem")"
    destination_dir="${ARCHIVE_ROOT}/${category}"
    destination="${destination_dir}/${clean_stem}.mp4"
    partial="${destination}.part-${RUN_ID}"

    if [ -e "$destination" ]; then
      archive_failed=$((archive_failed + 1))
      archive_log "ARCHIVE_FAILED reason=destination_exists source=${source_path} destination=${destination}"
      continue
    fi

    mkdir -p "$destination_dir"
    rm -f "$partial"
    archive_log "ARCHIVE_COPY_START category=${category} source=${out_mp4} destination=${destination}"

    if ! cp -p "$out_mp4" "$partial"; then
      archive_failed=$((archive_failed + 1))
      rm -f "$partial"
      archive_log "ARCHIVE_FAILED reason=copy_failed source=${source_path} destination=${destination}"
      continue
    fi

    output_size="$(stat -f '%z' "$out_mp4" 2>/dev/null || true)"
    partial_size="$(stat -f '%z' "$partial" 2>/dev/null || true)"
    if [ -z "$output_size" ] || [ "$partial_size" != "$output_size" ]; then
      archive_failed=$((archive_failed + 1))
      rm -f "$partial"
      archive_log "ARCHIVE_FAILED reason=copied_size_mismatch source=${source_path} destination=${destination}"
      continue
    fi

    if ! mv "$partial" "$destination"; then
      archive_failed=$((archive_failed + 1))
      rm -f "$partial"
      archive_log "ARCHIVE_FAILED reason=finalize_failed source=${source_path} destination=${destination}"
      continue
    fi

    archived=$((archived + 1))
    source_deleted=0

    if [ ! -e "$source_path" ]; then
      source_deleted=1
      archive_log "SOURCE_ALREADY_MISSING source=${source_path}"
    else
      expected_size="$(expected_source_size "$source_path")"
      current_size="$(stat -f '%z' "$source_path" 2>/dev/null || true)"

      if [ -n "$expected_size" ] && [ "$current_size" = "$expected_size" ]; then
        if rm "$source_path"; then
          source_deleted=1
          archive_log "SOURCE_DELETED source=${source_path}"
        else
          archive_log "SOURCE_DELETE_FAILED source=${source_path}"
        fi
      else
        archive_log "SOURCE_DELETE_SKIPPED_CHANGED expected_bytes=${expected_size:-unknown} current_bytes=${current_size:-unknown} source=${source_path}"
      fi
    fi

    if [ "$source_deleted" -eq 1 ]; then
      rm -f "$out_mp4" "$done_ts"
      archive_log "ARCHIVED cleanup=complete category=${category} title=${clean_stem} destination=${destination}"
    else
      cleanup_pending=$((cleanup_pending + 1))
      archive_log "ARCHIVED cleanup=pending category=${category} title=${clean_stem} destination=${destination}"
    fi
  done < "$SOURCE_MAP"

  archive_log "archive run finished archived=${archived} archive_failed=${archive_failed} encode_failed=${encode_failed} cleanup_pending=${cleanup_pending}"

  if [ "$archive_failed" -ne 0 ] || [ "$cleanup_pending" -ne 0 ]; then
    return 1
  fi
}

run_archive_once() {
  local status=""
  local pending=""
  local succeeded=""
  local failed=""

  if ! mkdir "$ARCHIVE_LOCK" 2>/dev/null; then
    archive_log "ERROR another archive action is active lock=${ARCHIVE_LOCK}"
    return 75
  fi
  archive_lock_acquired=1

  status="$(count_encode_status)"
  IFS=$'\t' read -r pending succeeded failed <<EOF
$status
EOF
  archive_log "ENCODE_STATUS pending=${pending} succeeded=${succeeded} failed=${failed}"

  if [ "$pending" -gt 0 ]; then
    rmdir "$ARCHIVE_LOCK" 2>/dev/null || true
    archive_lock_acquired=0
    return 75
  fi

  archive_log "encoding batch finished succeeded=${succeeded} failed=${failed}; starting archive"
  archive_all
  local archive_result=$?

  rmdir "$ARCHIVE_LOCK" 2>/dev/null || true
  archive_lock_acquired=0
  return "$archive_result"
}

main() {
  local copy_result=0
  local archive_result=0
  local queued=0

  if [ "${1:-}" = "--check" ]; then
    check_requirements
    return
  fi

  if [ "$#" -ne 0 ]; then
    printf 'Usage: %s [--check]\n' "$0" >&2
    return 64
  fi

  mkdir -p \
    "$INBOX_720" \
    "$INBOX_1080" \
    "$RUN_LOG_DIR" \
    "$COPY_LOG_DIR"

  if ! acquire_workflow_lock; then
    return 75
  fi
  trap cleanup_locks EXIT INT TERM

  if encoder_is_busy; then
    workflow_log "workflow skipped: encoder or copy queue is already busy"
    return 75
  fi

  workflow_log "workflow starting run_id=${RUN_ID}"

  copy_recordings || copy_result=$?
  queued="$(queued_count)"
  workflow_log "copy phase finished result=${copy_result} queued=${queued} copy_log=${COPY_LOG}"

  if [ "$queued" -eq 0 ]; then
    workflow_log "workflow finished queued=0 archived=0"
    return "$copy_result"
  fi

  while :; do
    archive_result=0
    run_archive_once || archive_result=$?

    if [ "$archive_result" -eq 75 ]; then
      sleep "$POLL_SECONDS"
      continue
    fi

    if [ "$archive_result" -ne 0 ]; then
      workflow_log "workflow failed during archive result=${archive_result} archive_log=${ARCHIVE_LOG}"
      return "$archive_result"
    fi

    break
  done

  workflow_log "workflow finished queued=${queued} archive_log=${ARCHIVE_LOG}"
  return "$copy_result"
}

main "$@"
