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
    for pkg in /opt/weewx-ext/weewx-interceptor.zip /opt/weewx-ext/weewx-forecast.zip /opt/weewx-ext/weewx-xaggs.zip /opt/weewx-ext/weewx-GTS.zip /opt/weewx-ext/weewx-wdc /opt/weewx-ext/weewx-mqtt.zip; do
        weectl extension install -y --config "${WEEWX_HOME}/weewx.conf" "${pkg}"
    done
    weectl extension list --config "${WEEWX_HOME}/weewx.conf" || true

        # Reconfigure station to use interceptor driver
        echo "[INFO] Reconfiguring station to use user.interceptor"
        weectl station reconfigure --weewx-root "${WEEWX_HOME}" --config "${WEEWX_HOME}/weewx.conf" --driver=user.interceptor --no-prompt || true

        # Ensure [Interceptor] section with expected settings
    # Normalize existing Interceptor section by removing it, then append clean block
    tmpcfg="${WEEWX_HOME}/weewx.conf.tmp"
    awk 'BEGIN{skip=0} /^\[Interceptor\]/{skip=1} skip && /^\[/{skip=0} !skip' "${WEEWX_HOME}/weewx.conf" > "${tmpcfg}" || cp "${WEEWX_HOME}/weewx.conf" "${tmpcfg}"
    cat >> "${tmpcfg}" <<'EOF'
[Interceptor]
        driver = user.interceptor
        device_type = wu-client
        mode = listen
        address = 0.0.0.0
        port = 9877
EOF
    mv "${tmpcfg}" "${WEEWX_HOME}/weewx.conf"

        # Basic skin tweaks
        sed -i -z -e 's/skin = Seasons\n        enable = true/skin = Seasons\n        enable = false/' "${WEEWX_HOME}/weewx.conf" || true
        sed -i -z -e 's/skin = forecast/skin = forecast\n        enable = false/' "${WEEWX_HOME}/weewx.conf" || true

    # Save user-editable copies
    cp "${WEEWX_HOME}/weewx.conf" "${CONFIG_PATH}"
    echo "[DEBUG] Persisted config (Interceptor section):"; awk '/^\[Interceptor\]/{flag=1;next} /^\[/{flag=0} flag' "${CONFIG_PATH}" || true
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

