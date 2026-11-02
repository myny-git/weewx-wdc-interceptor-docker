#!/bin/bash
set -euo pipefail
umask 077

if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
fi

if [ -x /sbin/syslogd ]; then
    /sbin/syslogd -n -O /dev/stdout &
elif command -v busybox >/dev/null 2>&1; then
    busybox syslogd -n -O /dev/stdout &
fi

python /usr/local/lib/weewx-container/bootstrap.py
echo "[INFO] Launching WeeWX ${WEEWX_VERSION} (Forecast ${WEEWX_FORECAST_VERSION})"
exec weewxd --config "${WEEWX_HOME}/weewx.conf"
