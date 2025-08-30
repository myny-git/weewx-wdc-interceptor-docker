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

if [ -x /sbin/syslogd ]; then
    echo "[INFO] Starting syslog (/sbin/syslogd)"
    /sbin/syslogd -n -O /dev/stdout &
elif command -v busybox >/dev/null 2>&1; then
    echo "[INFO] Starting syslog (busybox syslogd)"
    busybox syslogd -n -O /dev/stdout &
else
    echo "[WARN] No syslogd available" >&2
fi
sleep 0.2 || true

# Ensure data directory exists
mkdir -p "${WEEWX_HOME}/data"

# shellcheck disable=SC1091 # virtualenv activation script not present at lint time
. "${WEEWX_HOME}/weewx-venv/bin/activate"

CONFIG_PATH="${WEEWX_HOME}/data/weewx.conf"
SKIN_PATH="${WEEWX_HOME}/data/skin.conf"

# Always ensure user module directory exists (also for restarts)
mkdir -p "${WEEWX_HOME}/bin/user"
[ -f "${WEEWX_HOME}/bin/user/__init__.py" ] || touch "${WEEWX_HOME}/bin/user/__init__.py"

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

    # Ensure user module directory exists first
    echo "[INFO] Creating user module directory structure"
    mkdir -p "${WEEWX_HOME}/bin/user"
    touch "${WEEWX_HOME}/bin/user/__init__.py"

    # Install extensions
    echo "[INFO] Installing extensions"
    echo "[DEBUG] Available extension files:"
    ls -la /opt/weewx-ext/ || true
    # Prepare interceptor archive (GitHub source zip contains top-level dir already; ensure it stays a single-root archive)
    if [ -f /opt/weewx-ext/weewx-interceptor.zip ]; then
        echo "[DEBUG] Validating interceptor archive structure"
        mkdir -p /tmp/interceptor-check
        unzip -q /opt/weewx-ext/weewx-interceptor.zip -d /tmp/interceptor-check
        rootcount=$(find /tmp/interceptor-check -maxdepth 1 -type d | wc -l || true)
        if [ "$rootcount" -gt 2 ]; then
            echo "[WARN] Interceptor zip has multiple top-level dirs; repackaging"
            firstdir=$(find /tmp/interceptor-check -mindepth 1 -maxdepth 1 -type d | head -1)
            (cd "$firstdir" && zip -qr /opt/weewx-ext/weewx-interceptor-fixed.zip .)
            mv /opt/weewx-ext/weewx-interceptor-fixed.zip /opt/weewx-ext/weewx-interceptor.zip
        fi
        rm -rf /tmp/interceptor-check
    fi

    for pkg in /opt/weewx-ext/weewx-interceptor.zip /opt/weewx-ext/weewx-forecast.zip /opt/weewx-ext/weewx-xaggs.zip /opt/weewx-ext/weewx-GTS.zip /opt/weewx-ext/weewx-wdc /opt/weewx-ext/weewx-mqtt.zip /opt/weewx-ext/weewx-xcumulative.zip; do
        if [ ! -e "${pkg}" ]; then
            echo "[ERROR] Extension file not found: ${pkg}"
            continue
        fi
        echo "[DEBUG] Installing extension: ${pkg}"
        if [ "${pkg}" = "/opt/weewx-ext/weewx-interceptor.zip" ]; then
            echo "[DEBUG] Interceptor zip contents:"
            unzip -l "${pkg}" || echo "[ERROR] Failed to list interceptor zip contents"
        fi
        echo "[DEBUG] Running: weectl extension install -y --config ${WEEWX_HOME}/weewx.conf ${pkg}"
        weectl extension install -y --config "${WEEWX_HOME}/weewx.conf" "${pkg}" || echo "[WARN] Failed to install ${pkg}"
    done
    echo "[DEBUG] Installed extensions:"
    weectl extension list --config "${WEEWX_HOME}/weewx.conf" || true

    # Verify interceptor module exists
    if [ -f "${WEEWX_HOME}/bin/user/interceptor.py" ]; then
        echo "[INFO] Interceptor module found at ${WEEWX_HOME}/bin/user/interceptor.py"
    else
        echo "[ERROR] Interceptor module not found! Checking user directory contents:"
        ls -la "${WEEWX_HOME}/bin/user/" || true
    fi

        # Reconfigure station to use interceptor driver
        echo "[INFO] Reconfiguring station to use user.interceptor"
        weectl station reconfigure --weewx-root "${WEEWX_HOME}" --config "${WEEWX_HOME}/weewx.conf" --driver=user.interceptor --no-prompt || true
        
        # Verify station_type is set correctly in [Station] section
        if ! grep -q "station_type.*=.*Interceptor" "${WEEWX_HOME}/weewx.conf"; then
            echo "[INFO] Manually setting station_type to Interceptor"
            sed -i '/^\[Station\]/,/^\[/ { /station_type[[:space:]]*=/ { s/station_type[[:space:]]*=.*/station_type = Interceptor/; } }' "${WEEWX_HOME}/weewx.conf" || true
        fi

    # Ensure single canonical [Interceptor] section
    echo "[INFO] Normalizing Interceptor section"
    tmpcfg="${WEEWX_HOME}/weewx.conf.tmp"
    awk '/^\[Interceptor\]/{in_int=1;next} /^\[/{if(in_int){in_int=0}} !in_int' "${WEEWX_HOME}/weewx.conf" > "${tmpcfg}" || cp "${WEEWX_HOME}/weewx.conf" "${tmpcfg}"
    cat >> "${tmpcfg}" <<'EOF'
[Interceptor]
driver = user.interceptor
device_type = wu-client
mode = listen
address = 0.0.0.0
port = 9877
EOF
    mv "${tmpcfg}" "${WEEWX_HOME}/weewx.conf"
    echo "[DEBUG] Interceptor section count after normalize: $(grep -c '^\[Interceptor\]' "${WEEWX_HOME}/weewx.conf" || true)"

        # Basic skin tweaks
        sed -i -z -e 's/skin = Seasons\n        enable = true/skin = Seasons\n        enable = false/' "${WEEWX_HOME}/weewx.conf" || true
        sed -i -z -e 's/skin = forecast/skin = forecast\n        enable = false/' "${WEEWX_HOME}/weewx.conf" || true

    # Save user-editable copies
    cp "${WEEWX_HOME}/weewx.conf" "${CONFIG_PATH}"
    echo "[DEBUG] Persisted config (Interceptor section):"; awk '/^\[Interceptor\]/{flag=1;next} /^\[/{flag=0} flag' "${CONFIG_PATH}" || true
    echo "[DEBUG] Station driver in config:"; grep -A1 -B1 "station_type\|driver.*=" "${CONFIG_PATH}" | head -10 || true
    if [ -f "${WEEWX_HOME}/skins/weewx-wdc/skin.conf" ]; then
        cp "${WEEWX_HOME}/skins/weewx-wdc/skin.conf" "${SKIN_PATH}" || true
    fi
else
    echo "[INFO] Existing configuration detected"
    cp "${CONFIG_PATH}" "${WEEWX_HOME}/weewx.conf"
    # Ensure skins directory base exists to avoid copy errors
    mkdir -p "${WEEWX_HOME}/skins"
    if [ -f "${SKIN_PATH}" ]; then
        mkdir -p "${WEEWX_HOME}/skins/weewx-wdc" || true
        cp "${SKIN_PATH}" "${WEEWX_HOME}/skins/weewx-wdc/skin.conf" || true
    fi

    # If user extensions vanished (e.g. because /home/weewx-data/bin was not persisted), reinstall needed ones
    if [ ! -f "${WEEWX_HOME}/bin/user/interceptor.py" ]; then
        echo "[WARN] Interceptor module missing on restart - reinstalling interceptor extension"
        if [ -f /opt/weewx-ext/weewx-interceptor.zip ]; then
            echo "[INFO] Reinstalling /opt/weewx-ext/weewx-interceptor.zip"
            weectl extension install -y --config "${WEEWX_HOME}/weewx.conf" /opt/weewx-ext/weewx-interceptor.zip || echo "[ERROR] Failed reinstall interceptor"
        else
            echo "[ERROR] Expected extension archive not found: /opt/weewx-ext/weewx-interceptor.zip" >&2
        fi
        # (Optional) reinstall mqtt etc if their modules also missing
        for pair in mqtt:mqtt.py forecast:forecast.py xaggs:xaggs.py GTS:GTS.py xcumulative:xcumulative.py; do
            name="${pair%%:*}"; file="${pair##*:}";
            if [ ! -f "${WEEWX_HOME}/bin/user/${file}" ]; then
                archive="/opt/weewx-ext/weewx-${name}.zip"
                [ "${name}" = "GTS" ] && archive="/opt/weewx-ext/weewx-GTS.zip"
                if [ -f "${archive}" ]; then
                    echo "[INFO] Reinstalling missing ${name} extension"
                    weectl extension install -y --config "${WEEWX_HOME}/weewx.conf" "${archive}" || echo "[WARN] Failed reinstall ${name}";
                fi
            fi
        done
        ls -1 "${WEEWX_HOME}/bin/user" || true
    fi

    # Reinstall WDC skin if missing (directory absent)
    if [ ! -d "${WEEWX_HOME}/skins/weewx-wdc" ] && [ -d /opt/weewx-ext/weewx-wdc ]; then
        echo "[WARN] WDC skin directory missing - restoring"
        cp -a /opt/weewx-ext/weewx-wdc "${WEEWX_HOME}/skins/" || echo "[WARN] Failed to restore WDC skin"
    fi

    # Sanitize config: remove deprecated xcumulative service lines en fix malformed booleans (Truex)
    if grep -q 'Truex' "${WEEWX_HOME}/weewx.conf"; then
        echo "[INFO] Fixing malformed boolean 'Truex' -> 'True'"
        sed -i 's/Truex/True/g' "${WEEWX_HOME}/weewx.conf" || true
    fi
fi

echo "[INFO] Launching WeeWX ${WEEWX_VERSION}"
echo "[DEBUG] PYTHONPATH before launch: ${PYTHONPATH:-<empty>}"
if [ "${DEBUG:-0}" = "1" ]; then
  echo "[DEBUG] Enabling shell trace (DEBUG=1)"; set -x
fi
echo "[DEBUG] Final check - interceptor module:"; ls -la "${WEEWX_HOME}/bin/user/interceptor.py" 2>/dev/null || echo "Not found"
echo "[DEBUG] Final check - station config:"; grep -A5 -B5 "station_type\|driver.*=" "${WEEWX_HOME}/weewx.conf" | head -15 || true
exec weewxd --config "${WEEWX_HOME}/weewx.conf"

