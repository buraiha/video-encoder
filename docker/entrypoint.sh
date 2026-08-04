#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/app}"
CRON_FILE="/etc/cron.d/video-encoder"
CRON_SCHEDULE="${CRON_SCHEDULE:-* * * * *}"
RUN_ON_STARTUP="${RUN_ON_STARTUP:-0}"

mkdir -p "${APP_DIR}/logs"
chmod +x "${APP_DIR}/bin/encode-one.sh" "${APP_DIR}/bin/watch-and-encode.sh" 2>/dev/null || true

cat > "${CRON_FILE}" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TZ=${TZ:-Asia/Tokyo}
${CRON_SCHEDULE} root cd ${APP_DIR} && /bin/bash ./bin/watch-and-encode.sh >> /proc/1/fd/1 2>> /proc/1/fd/2

EOF

chmod 0644 "${CRON_FILE}"

if [ "${RUN_ON_STARTUP}" = "1" ]; then
  cd "${APP_DIR}"
  /bin/bash ./bin/watch-and-encode.sh
fi

exec cron -f