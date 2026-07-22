#!/usr/bin/env bash
set -u

EPGSTATION_URL="http://127.0.0.1:8888"
MIRAKURUN_CONTAINER="mirakurun"
EPGSTATION_CONTAINER="epgstation"

# EPGStationから現在録画中の一覧を取得
if ! response="$(
    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 15 \
        "${EPGSTATION_URL}/api/recording?isHalfWidth=false"
)"; then
    echo "EPGStation APIに接続できないため、再起動を中止します" >&2
    exit 1
fi

# APIの応答形式を確認し、録画件数を取得
if ! recording_count="$(
    jq --exit-status '.records | length' <<<"$response"
)"; then
    echo "EPGStation APIの応答を解析できないため、再起動を中止します" >&2
    exit 1
fi

if (( recording_count > 0 )); then
    echo "現在${recording_count}件を録画中です。今回は再起動しません" >&2

    # 非ゼロで終了させ、30分後に再試行させる
    exit 75
fi

echo "録画中ではないため、Mirakurunを再起動します"

if ! docker restart "$MIRAKURUN_CONTAINER"; then
    echo "Mirakurunの再起動に失敗しました" >&2
    exit 1
fi

# Mirakurunの起動を少し待つ
sleep 10

echo "EPGStationを再起動します"

if ! docker restart "$EPGSTATION_CONTAINER"; then
    echo "EPGStationの再起動に失敗しました" >&2
    exit 1
fi

echo "MirakurunとEPGStationの再起動が完了しました"

