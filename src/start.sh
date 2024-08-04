#!/bin/bash

echo "WEEWX_HOME: ${WEEWX_HOME}"

# start rsyslog
echo 'Starting rsyslog'
# remove lingering pid file
rm -f /run/rsyslogd.pid
# start service
service rsyslog start
#echo 'Starting syslog'
#/sbin/syslogd -n -S -O - &

echo 'copy weewx.conf file'
# Copy custom weewx.conf if it exists
if [ -f "${WEEWX_HOME}/data/weewx.conf" ]; then
    echo "Using custom weewx.conf"
    cp "${WEEWX_HOME}/data/weewx.conf" "${WEEWX_HOME}/weewx.conf"
else
    echo "Custom weewx.conf not found, using default"
    cp "${WEEWX_HOME}/weewx${WEEWX_VERSION}.conf" "${WEEWX_HOME}/weewx.conf"
    cp "${WEEWX_HOME}/weewx${WEEWX_VERSION}.conf" "${WEEWX_HOME}/data/weewx.conf"
fi

# start weewx
echo "Starting Weewx version ${WEEWX_VERSION}"
# shellcheck source=/dev/null
. "${WEEWX_HOME}"/weewx-venv/bin/activate
weewxd --config "${WEEWX_HOME}/weewx.conf"
