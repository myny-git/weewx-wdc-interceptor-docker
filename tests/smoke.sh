#!/bin/bash
# This test owns every container, volume and directory it removes.
set -euo pipefail
image=${1:-weewx-test:ci}
name="weewx-ci-${RANDOM}-$$"
test_dir=$(mktemp -d)
repo=$(cd "$(dirname "$0")/.." && pwd)
cleanup() {
    result=$?
    trap - EXIT
    if [[ "$result" != 0 ]]; then docker logs --tail 60 "$name" || true; fi
    docker rm -fv "$name" >/dev/null 2>&1 || true
    rm -rf -- "$test_dir"
    exit "$result"
}
trap cleanup EXIT
mkdir -p "$test_dir/data" "$test_dir/archive" "$test_dir/html" "$test_dir/backups"

start() {
    docker run -d --name "$name" --health-interval 2s --health-start-period 2s \
        --mount "type=bind,source=$test_dir/data,target=/home/weewx-data/data" \
        --mount "type=bind,source=$test_dir/archive,target=/home/weewx-data/archive" \
        --mount "type=bind,source=$test_dir/html,target=/home/weewx-data/public_html" \
        -e TZ=Europe/Brussels "$image" >/dev/null
    for _attempt in {1..30}; do
        if [[ $(docker inspect --format '{{.State.Health.Status}}' "$name") == healthy ]]; then
            return
        fi
        sleep 2
    done
    echo "Container did not become healthy" >&2
    return 1
}
start
docker exec "$name" python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:9877/weatherstation/updateweatherstation.php?action=updateraw&ID=TEST&PASSWORD=TEST&dateutc=now&tempf=68&humidity=50&baromin=29.92&windspeedmph=2&winddir=180&rainin=0", timeout=10).read()'
docker exec "$name" sh -c 'echo custom-template > /home/weewx-data/skins/weewx-wdc/custom.html.tmpl'
docker restart "$name" >/dev/null
# Exercise backup.sh against real named/bind mounts and a writable-layer file.
bash "$repo/admin_scripts/backup.sh" "$name" "$test_dir/backups"
(cd "$test_dir/backups" && sha256sum -c ./*.sha256)
archive=$(find "$test_dir/backups" -maxdepth 1 -name '*.tar.gz' -print -quit)
mkdir "$test_dir/restored"
tar -xzf "$archive" -C "$test_dir/restored"
mkdir "$test_dir/restored/station"
tar -xf "$test_dir/restored/station.tar" -C "$test_dir/restored/station"
cmp "$test_dir/data/weewx.conf" "$test_dir/restored/station/data/weewx.conf"
test -f "$test_dir/restored/station/archive/weewx.sdb"
test -f "$test_dir/restored/station/data/station/skins/weewx-wdc/custom.html.tmpl"
# Replace the container while keeping exactly the three original mounts.
docker rm -fv "$name" >/dev/null
start
docker exec "$name" test -f /home/weewx-data/skins/weewx-wdc/custom.html.tmpl
docker exec "$name" python -c 'import sqlite3; c=sqlite3.connect("/home/weewx-data/archive/weewx.sdb"); assert c.execute("PRAGMA integrity_check").fetchone()==("ok",)'
echo "Container start, restart, replacement and backup/restore passed"
