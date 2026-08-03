#!/usr/bin/env bash
set -u

EPGSTATION_URL="http://127.0.0.1:8888"
MIRAKURUN_CONTAINER="mirakurun"
EPGSTATION_CONTAINER="epgstation"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

log_error() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2
}

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

log "MirakurunとEPGStationの再起動が完了しました"
