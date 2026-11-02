#!/bin/bash
# Back up mounted data AND the station files in the container's writable layer.
set -euo pipefail
umask 077

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <CONTAINER> <OUTPUT_DIRECTORY> [s3://bucket/prefix]" >&2
    exit 1
fi
container=$1
mkdir -p "$2"
output=$(cd "$2" && pwd -P)
s3_uri=${3:-}
if [[ -n "$s3_uri" && "$s3_uri" != s3://* ]]; then
    echo "The optional upload destination must start with s3://" >&2
    exit 1
fi
for tool in docker tar sha256sum; do command -v "$tool" >/dev/null; done
if [[ -n "$s3_uri" ]]; then command -v aws >/dev/null; fi

docker inspect "$container" >/dev/null
station_root=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container" |
    sed -n 's/^WEEWX_HOME=//p')
station_root=${station_root:-/home/weewx-data}
if [[ "$station_root" != /* || "$station_root" == / ]]; then
    echo "Invalid WEEWX_HOME: $station_root" >&2
    exit 1
fi
while IFS= read -r source; do
    [[ -n "$source" ]] || continue
    case "$output/" in
        "$source/"*) echo "Choose a backup directory outside the container mounts." >&2; exit 1 ;;
    esac
done < <(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$container")

work=$(mktemp -d "$output/.weewx-backup.XXXXXX")
restart=0
cleanup() {
    result=$?
    trap - EXIT
    if [[ "$restart" == 1 ]]; then
        if ! docker start "$container" >/dev/null; then
            echo "ERROR: restart $container manually; backup work is at $work" >&2
            result=1
        fi
    fi
    if [[ "$result" != 0 ]]; then
        echo "Backup failed; retained diagnostic files in $work" >&2
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker inspect "$container" > "$work/container-inspect.json"
image_id=$(docker inspect --format '{{.Image}}' "$container")
docker image inspect "$image_id" > "$work/image-inspect.json"
if [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]]; then
    restart=1
    docker stop --time 60 "$container" >/dev/null
fi
# Keep Docker's tar stream intact: no host symlink support is required, and
# metadata/links survive even when the backup is made from a Windows client.
docker cp "$container:$station_root/." - > "$work/station.tar"
tar -tf "$work/station.tar" >/dev/null
if [[ "$restart" == 1 ]]; then
    docker start "$container" >/dev/null
    restart=0
fi
archive="$output/weewx-$(date -u +%Y%m%dT%H%M%SZ)-$$.tar.gz"
tar -czf "$archive.partial" -C "$work" station.tar container-inspect.json image-inspect.json
tar -tzf "$archive.partial" >/dev/null
mv "$archive.partial" "$archive"
(cd "$output" && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256")
if [[ -n "$s3_uri" ]]; then
    aws s3 cp "$archive" "${s3_uri%/}/"
    aws s3 cp "$archive.sha256" "${s3_uri%/}/"
fi
# Delete only the staging directory created by mktemp above, after verification.
rm -rf -- "$work"
echo "Verified backup: $archive"
echo "Keep the old Docker image as well; metadata records $image_id"
