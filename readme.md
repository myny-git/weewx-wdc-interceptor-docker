# WeeWX, WDC and Interceptor on Synology

Docker image for a Bresser WIFI 5-in-1 Pro, using the Interceptor `wu-client`
listener. Forked from [Daveiano's container](https://github.com/Daveiano/weewx-wdc-interceptor-docker).

| Component | Version / source revision |
| --- | --- |
| Python | 3.11, Debian Bookworm |
| WeeWX | 5.5.2 |
| Weather Data Center | 3.5.1 |
| Interceptor (`tfilo`) | 1.0.1 |
| Forecast | 5.4 |
| MQTT | 0.24, `a182707d12a5abc778eb7756856e1be2047627f9` |
| Paho MQTT | 1.6.1, required by this MQTT extension |
| XAggs | 1.0, `d36145689b6d4bd363a792432df94215d69f5026` |
| GTS | 1.2 |
| XCumulative (`hoetzgit` backup repository) | 0.1.0, `a5e412d22464b95d74d2cada02efb9bddda0db64` |

Bundled extension downloads use release tags or fixed commits; Python dependencies
are pinned in `constraints.txt`. Resolved Python
dependencies are recorded in `/opt/weewx-seed/python-packages.txt` in each image.
The virtual environment lives at `/opt/weewx-venv`; it is separate from station data.

## Persistent station data

Keep these existing mounts, with their actual existing volume names:

| Container path | Contents |
| --- | --- |
| `/home/weewx-data/archive` | Weather archive and default Forecast SQLite database |
| `/home/weewx-data/public_html` | Generated website |
| `/home/weewx-data/data` | Editable `weewx.conf`, WDC `skin.conf`, backups and migration state |

The container now also retains user modules and complete skins in
`data/station/user` and `data/station/skins`. Default runtime directories link to
these locations. Existing files are copied there before the links are created.
Explicit mounts for `bin/user` or `skins`, and paths already inside `data`, are
kept in place. This lets custom templates survive container replacement with
the original three mounts. User-created files outside these paths need their
own persistent mount and backup.

`data/skin.conf` remains the editable WDC configuration and takes precedence over
`skins/weewx-wdc/skin.conf`. Edit this persistent copy for WDC settings. Other
skin files can be edited under `data/station/skins`.

At startup the container restores missing bundled files independently. It updates
bundled Python modules with a backup when their image revision changes, while
preserving edits detected against the previously installed revision. Untracked
legacy copies of bundled modules are backed up before replacement. Custom
modules with other names and existing skin files are kept. Installers run only
when building the image, so restarting does not re-enable disabled services or
inject default credentials into your existing configuration.

## Upgrade an existing Synology installation

1. **Inventory the running container before replacing it.** Check the actual
   mounts and image ID:

   ```bash
   docker inspect weewx_bresser --format '{{json .Mounts}}'
   docker inspect weewx_bresser --format '{{.Image}}'
   ```

   Check your active `weewx.conf` for custom SQLite directories or external
   databases. Back up those locations too; the full-station script below covers
   files under `WEEWX_HOME`, including its mounted directories.

2. **Back up the full station to a different directory.** Run on the NAS with
   Bash and access to Docker. This replaces the old volume-only script interface:

   ```bash
   bash admin_scripts/backup.sh weewx_bresser /volume1/backups/weewx
   cd /volume1/backups/weewx
   sha256sum -c weewx-<timestamp>-<pid>.tar.gz.sha256
   ```

   Replace the example filename with the one printed by the script. It stops the
   selected container while copying the full station, then restarts it, including
   when a copy fails. It checks the tar archive and writes a SHA-256 checksum.
   Existing stopped containers remain stopped. The archive includes configuration,
   databases, skins, modules, container settings and the old image ID. An optional
   third argument `s3://bucket/prefix` uploads both files and keeps the local copy.
   Store backups securely: configuration and inspection data can contain credentials.

3. **Retain the old image.** Save the image ID from step 1 with `docker image save`
   to a separate archive. Do not prune it until the upgrade has been verified.

4. **Test the restore on copies.** Extract the backup into a new directory, then
   extract its `station.tar` into a separate empty station directory. This inner
   archive retains symlinks and Unix metadata. Check configuration and databases. Never run a test
   container against your live volumes. Give the test its own copies, disable
   uploads/MQTT in the test configuration, and do not redirect the station to it.

5. **Build or publish the new image.** GitHub's manual `Docker Image CI` workflow
   tests the production image and publishes that exact image under the supplied
   version tag, for example `mynygit/weewxv5_docker:5.5.2`. A Git push alone does
   not publish a Docker Hub image. Alternatively build locally:

   ```bash
   docker build -t mynygit/weewxv5_docker:5.5.2 .
   ```

6. **Change only the image tag in your existing Compose project** after the tests
   and backup succeed. Keep the existing project, mounts, ports and real volume
   names. A different project name can otherwise select new empty volumes.
   `compose.example.yaml` uses external volumes so a misspelled volume fails
   instead of silently creating an empty archive.

7. Start the replacement with `docker compose up -d` and inspect its logs.
   Verify new station packets, fresh archive timestamps, WDC reports, MQTT in
   Home Assistant and Forecast output. Keep the interruption short: a listener
   cannot recover packets the station never delivered during downtime.

**Never run `docker compose down -v`, delete the existing data directories, or
change volume names as part of this upgrade.** This repository does not access
or upgrade the NAS automatically.

## Configuration and Forecast migration

The container backs up the original config in `data/backups/<UTC timestamp>/`
before its first start with a different WeeWX version. It upgrades a runtime
copy with `weectl station upgrade --what config --yes`, checks that existing
settings did not change, validates imports and configured report generators,
and only then replaces `data/weewx.conf` atomically. File permissions and
ownership are retained. If a setting would be removed or changed, startup fails
for manual review and the persistent config stays intact. Skins are not
automatically replaced by `weectl station upgrade`.

Before the first WeeWX/Forecast version transition, all configured existing
SQLite databases are copied using SQLite's backup API and checked for integrity.
These extra recovery copies live in the same persistent data directory; keep
the separate external backup as protection against disk or volume loss.
For an external Forecast database (MySQL/MariaDB), make a server-side backup
first, then set `WEEWX_EXTERNAL_DB_BACKUP_CONFIRMED=1` to acknowledge it.

Forecast 5.4 automatically renames `desc` to `description` and `offset` to
`tide_offset` in the forecast table. Existing rows and the old template names
remain supported. See the [Forecast 5.4 release notes](https://github.com/chaunceygardiner/weewx-forecast/releases/tag/v5.4).
The sample Forecast layouts now default to NWS; explicitly set your intended
source in the Forecast skin's `[Extras]` settings if you use those layouts.
XTide still requires a separate `xtide` installation and configured location;
the optional comparison report also needs DejaVu fonts.

**Rollback requires matching data and code.** Stop the new container, restore
the pre-upgrade configuration, user modules, skins and Forecast database from
the external backup into separate restore locations, and start the retained
old image against those locations. A changed image tag alone cannot reverse the
Forecast column migration. Retain the current archive as well: replacing it
with an older snapshot would discard measurements collected after that snapshot.
Do not run the old and new containers against the same database simultaneously.

## Example deployment and station routing

Use `compose.example.yaml` as a reference. For an existing installation, set
`WEEWX_DB_VOLUME` and `WEEWX_HTML_VOLUME` to the names found by `docker inspect`,
and `WEEWX_DATA_DIR` to your existing config directory. For a new installation
only, create the intended named volumes first.

The router forwards Bresser HTTP uploads to NAS port **3010**, which maps to
container port **9877**. The Interceptor configuration inside the container is:

```ini
[Interceptor]
    driver = user.interceptor
    device_type = wu-client
    mode = listen
    address = 0.0.0.0
    port = 9877
```

Station environment variables `LAT`, `LON`, `ALTITUDE`, `LOCATION` and
`STATION_URL` apply only when creating a new configuration. `TZ=Europe/Brussels`
sets the timezone. Existing configuration takes precedence.

## Validation and publishing

```bash
docker build -t weewx-test:ci .
docker run --rm --entrypoint python \
  --mount "type=bind,source=$PWD/tests,target=/tests,readonly" \
  weewx-test:ci -m unittest discover -s /tests -v
bash tests/smoke.sh weewx-test:ci
```

GitHub runs ShellCheck, Hadolint, Python syntax checks, database migration tests,
container replacement and full backup/restore checks. Tests use the Dockerfile's
real version defaults. Docker Hub publication and GitHub releases remain manual;
both depend on the reusable validation workflow. Publish a new tag for each
image revision, such as `5.5.2-1`, so previous images remain available.
