#!/usr/bin/env bash
set -u

EPGSTATION_URL="http://127.0.0.1:8888"
MIRAKURUN_CONTAINER="mirakurun"
EPGSTATION_CONTAINER="epgstation"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${SVRESTART_STATE_DIR:-${BASE_DIR}/logs/.svrestart-state}"
LAST_SUCCESS_FILE="${STATE_DIR}/last-success-week"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

log_error() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

current_week_key() {
    # Use ISO week so "once per week" is stable around year boundaries.
    date '+%G-W%V'
}

already_restarted_this_week() {
    local current_week=""
    local recorded_week=""

    current_week="$(current_week_key)"
    if [ ! -f "$LAST_SUCCESS_FILE" ]; then
        return 1
    fi

    recorded_week="$(cat "$LAST_SUCCESS_FILE" 2>/dev/null || true)"
    [ "$recorded_week" = "$current_week" ]
}

mark_restart_success_this_week() {
    local current_week=""

    mkdir -p "$STATE_DIR"
    current_week="$(current_week_key)"
    printf '%s\n' "$current_week" > "$LAST_SUCCESS_FILE"
}

if already_restarted_this_week; then
    log "今週はすでに再起動済みのためスキップします"
    exit 0
fi

# EPGStationから現在録画中の一覧を取得
if ! response="$(
    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 15 \
        "${EPGSTATION_URL}/api/recording?isHalfWidth=false"
)"; then
    log_error "EPGStation APIに接続できないため、再起動を中止します"
    exit 1
fi

# APIの応答形式を確認し、録画件数を取得
if ! recording_count="$(
    jq --exit-status '.records | length' <<<"$response"
)"; then
    log_error "EPGStation APIの応答を解析できないため、再起動を中止します"
    exit 1
fi

if (( recording_count > 0 )); then
    log_error "現在${recording_count}件を録画中です。今回は再起動しません"

    # 非ゼロで終了させ、30分後に再試行させる
    exit 75
fi

log "録画中ではないため、Mirakurunを再起動します"

if ! docker restart "$MIRAKURUN_CONTAINER"; then
    log_error "Mirakurunの再起動に失敗しました"
    exit 1
fi

# Mirakurunの起動を少し待つ
sleep 10

log "EPGStationを再起動します"

if ! docker restart "$EPGSTATION_CONTAINER"; then
    log_error "EPGStationの再起動に失敗しました"
    exit 1
fi

mark_restart_success_this_week
log "MirakurunとEPGStationの再起動が完了しました"
