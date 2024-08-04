#!/bin/bash

echo "WEEWX_HOME: ${WEEWX_HOME}"

# start rsyslog
#echo 'Starting rsyslog'
# remove lingering pid file
#rm -f /run/rsyslogd.pid
# start service
#service rsyslog start
 echo 'Starting syslog'
 /sbin/syslogd -n -S -O - &

# start weewx
echo 'Starting weewx 5.1.0'
echo "Starting Weewx version ${WEEWX_VERSION}"
# shellcheck source=/dev/null
. "${WEEWX_HOME}"/weewx-venv/bin/activate
weewxd --config "${WEEWX_HOME}/weewx.conf"
