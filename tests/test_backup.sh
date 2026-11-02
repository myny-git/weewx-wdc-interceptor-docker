#!/bin/bash
# Failure-path checks with a fake Docker command; no real containers are touched.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
export BACKUP_TEST_ROOT=$test_dir
mkdir -p "$test_dir/bin" "$test_dir/fixture/data" "$test_dir/output"
echo keep-my-data > "$test_dir/fixture/data/weewx.conf"
cat > "$test_dir/bin/docker" <<'MOCK'
#!/bin/bash
set -euo pipefail
case "$1" in
    inspect)
        if [[ "${2:-}" != --format ]]; then echo '{}'; exit; fi
        case "$3" in
            *Config.Env*) echo 'WEEWX_HOME=/home/weewx-data' ;;
            *Mounts*) : ;;
            *State.Running*) cat "$BACKUP_TEST_ROOT/running" ;;
            *Image*) echo 'sha256:old-image' ;;
        esac ;;
    image) echo '{}' ;;
    stop) echo stop >> "$BACKUP_TEST_ROOT/events"; echo false > "$BACKUP_TEST_ROOT/running" ;;
    start) echo start >> "$BACKUP_TEST_ROOT/events"; echo true > "$BACKUP_TEST_ROOT/running" ;;
    cp)
        if [[ "${FAIL_COPY:-0}" == 1 ]]; then exit 42; fi
        tar -cf - -C "$BACKUP_TEST_ROOT/fixture" . ;;
    *) exit 1 ;;
esac
MOCK
cat > "$test_dir/bin/aws" <<'MOCK'
#!/bin/bash
exit 42
MOCK
chmod +x "$test_dir/bin/docker" "$test_dir/bin/aws"
export PATH="$test_dir/bin:$PATH"

echo true > "$test_dir/running"
bash "$repo/admin_scripts/backup.sh" test "$test_dir/output"
[[ $(cat "$test_dir/running") == true ]]
[[ $(cat "$test_dir/events") == $'stop\nstart' ]]
(cd "$test_dir/output" && sha256sum -c ./*.sha256)
archive=$(find "$test_dir/output" -name '*.tar.gz' -print -quit)
mkdir "$test_dir/restore"
tar -xzf "$archive" -C "$test_dir/restore"
mkdir "$test_dir/restored-station"
tar -xf "$test_dir/restore/station.tar" -C "$test_dir/restored-station"
cmp "$test_dir/fixture/data/weewx.conf" "$test_dir/restored-station/data/weewx.conf"

# A failed copy restarts a previously running container and retains diagnostics.
: > "$test_dir/events"
if FAIL_COPY=1 bash "$repo/admin_scripts/backup.sh" test "$test_dir/output"; then exit 1; fi
[[ $(cat "$test_dir/running") == true ]]
[[ $(cat "$test_dir/events") == $'stop\nstart' ]]

# A stopped container must not be started by backup.
echo false > "$test_dir/running"
: > "$test_dir/events"
bash "$repo/admin_scripts/backup.sh" test "$test_dir/output"
[[ $(cat "$test_dir/running") == false ]]
[[ ! -s "$test_dir/events" ]]

# Failed S3 uploads keep the verified local backup.
count_before=$(find "$test_dir/output" -name '*.tar.gz' | wc -l)
if bash "$repo/admin_scripts/backup.sh" test "$test_dir/output" s3://test-bucket; then exit 1; fi
count_after=$(find "$test_dir/output" -name '*.tar.gz' | wc -l)
[[ "$count_after" -gt "$count_before" ]]
echo 'Backup restore, copy failure, stopped container and failed S3 upload passed'
