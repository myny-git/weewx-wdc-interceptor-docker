#!/bin/bash
set -euo pipefail

echo "[INFO] WeeWX container start"
echo "[INFO] WEEWX_HOME: ${WEEWX_HOME}"

if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    echo "[INFO] Setting timezone to ${TZ}"
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
else
    echo "[INFO] Using default UTC timezone (set TZ env to override)"
fi

if ! command -v busybox >/dev/null 2>&1; then
    echo "[WARN] busybox not found (expected in image)" >&2
else
    echo "[INFO] Starting syslog (busybox syslogd)"
    busybox syslogd -n -O /dev/stdout &
fi

# Ensure data directory exists
mkdir -p "${WEEWX_HOME}/data"

# shellcheck disable=SC1091 # virtualenv activation script not present at lint time
. "${WEEWX_HOME}/weewx-venv/bin/activate"

CONFIG_PATH="${WEEWX_HOME}/data/weewx.conf"
SKIN_PATH="${WEEWX_HOME}/data/skin.conf"

if [ ! -f "${CONFIG_PATH}" ]; then
    : "${LAT:=0.0}"
    : "${LON:=0.0}"
    : "${ALTITUDE:=0,meter}"
    : "${LOCATION:=Unknown}"
    : "${STATION_URL:=}"
    echo "[INFO] First run: creating station configuration"
    weectl station create "${WEEWX_HOME}" --no-prompt \
        --driver=weewx.drivers.simulator \
        --altitude="${ALTITUDE}" \
    --latitude="${LAT}" \
    --longitude="${LON}" \
        --location="${LOCATION}" \
        --register="n" \
        --station-url="${STATION_URL}" \
        --units="metric"

    # Install extensions
    echo "[INFO] Installing extensions"
    for pkg in /tmp/weewx-interceptor.zip /tmp/weewx-forecast.zip /tmp/weewx-xaggs.zip /tmp/weewx-GTS.zip /tmp/weewx-wdc /tmp/weewx-mqtt.zip; do
        weectl extension install -y --config "${WEEWX_HOME}/weewx.conf" "${pkg}"
    done
    weectl extension list --config "${WEEWX_HOME}/weewx.conf" || true

    # Basic config tweaks
    sed -i -e 's/device_type = acurite-bridge/device_type = wu-client\n    port = 9877\n    address = 0.0.0.0/' "${WEEWX_HOME}/weewx.conf" || true
    sed -i -z -e 's/skin = Seasons\n        enable = true/skin = Seasons\n        enable = false/' "${WEEWX_HOME}/weewx.conf" || true
    sed -i -z -e 's/skin = forecast/skin = forecast\n        enable = false/' "${WEEWX_HOME}/weewx.conf" || true

    # Save user-editable copies
    cp "${WEEWX_HOME}/weewx.conf" "${CONFIG_PATH}"
    if [ -f "${WEEWX_HOME}/skins/weewx-wdc/skin.conf" ]; then
        cp "${WEEWX_HOME}/skins/weewx-wdc/skin.conf" "${SKIN_PATH}" || true
    fi
else
    echo "[INFO] Existing configuration detected"
    cp "${CONFIG_PATH}" "${WEEWX_HOME}/weewx.conf"
    if [ -f "${SKIN_PATH}" ]; then
        cp "${SKIN_PATH}" "${WEEWX_HOME}/skins/weewx-wdc/skin.conf" || true
    fi
fi

echo "[INFO] Launching WeeWX ${WEEWX_VERSION}"
exec weewxd --config "${WEEWX_HOME}/weewx.conf"

