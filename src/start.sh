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

echo 'copy weewx.conf file'
# Copy custom weewx.conf if it exists
if [ -f "${WEEWX_HOME}/data/weewx.conf" ]; then
    echo "Using custom weewx.conf"
    cp "${WEEWX_HOME}/data/weewx.conf" "${WEEWX_HOME}/weewx.conf"
    cp "${WEEWX_HOME}/weewx${WEEWX_VERSION}.conf" "${WEEWX_HOME}/data/"
    echo "Copying also skin.conf to the right folder"
    cp "${WEEWX_HOME}/data/skin.conf" "${WEEWX_HOME}/skins/weewx-wdc/skin.conf"
else
    echo "Custom weewx.conf not found, please create one from weewx${WEEWX_VERSION}.conf and restart the container. "
    cp "${WEEWX_HOME}/weewx${WEEWX_VERSION}.conf" "${WEEWX_HOME}/data/"
fi

# start weewx
echo "Starting Weewx version ${WEEWX_VERSION}"
# shellcheck source=/dev/null
. "${WEEWX_HOME}"/weewx-venv/bin/activate
weewxd --config "${WEEWX_HOME}/weewx.conf"
