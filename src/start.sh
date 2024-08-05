#!/bin/bash

echo "WEEWX_HOME: ${WEEWX_HOME}"

# start rsyslog
echo 'Starting rsyslog'
# remove lingering pid file
#rm -f /run/rsyslogd.pid
# start service
#service rsyslog start
#echo 'Starting syslog'
#/sbin/syslogd -n -S -O - &
busybox syslogd -n -O /dev/stdout &

cp "${WEEWX_HOME}/weewx${WEEWX_VERSION}.conf" "${WEEWX_HOME}/data/"
cp "${WEEWX_HOME}/skins/weewx-wdc/skin${WDC_VERSION}.conf" "${WEEWX_HOME}/data/skin${WDC_VERSION}.conf"

echo 'copy weewx.conf file'
# Copy custom weewx.conf if it exists
if [ -f "${WEEWX_HOME}/data/weewx.conf" ]; then
    if [ -f "${WEEWX_HOME}/data/skin.conf" ]; then
        echo "Using custom weewx.conf and skin.conf"
        cp "${WEEWX_HOME}/data/weewx.conf" "${WEEWX_HOME}/weewx.conf"
        cp "${WEEWX_HOME}/data/skin.conf" "${WEEWX_HOME}/skins/weewx-wdc/skin.conf"      
        # start weewx
        echo "Starting Weewx version ${WEEWX_VERSION} with WDC-Skin version ${WDC_VERSION}"
        . "${WEEWX_HOME}"/weewx-venv/bin/activate
        weewxd --config "${WEEWX_HOME}/weewx.conf"
    else
        echo "Skin.conf did not exist. Please create one from the skin${WDC_VERSION}.conf file and restart the container. "
        exit 1
    fi
else
    echo "Custom weewx.conf not found, please create one from weewx${WEEWX_VERSION}.conf and restart the container. "
    exit 1
fi

