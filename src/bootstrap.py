"""Restore missing station files and safely migrate persistent configuration.

Installers never run against user configuration. SQLite databases are backed up
using read-only connections before an upgrade, never edited here.
"""
import importlib
import hashlib
import inspect
import json
import os
import shutil
import sqlite3
import stat
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from configobj import ConfigObj, Section
import weecfg
import weeutil.startup
import weeutil.weeutil
import weewx
import weewx.manager
import weewx.reportengine

SEED = Path('/opt/weewx-seed')


def atomic_copy(source, destination):
    """Replace a file in one rename, retaining existing permissions/ownership."""
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    old_stat = destination.stat() if destination.exists() else None
    fd, tmp = tempfile.mkstemp(prefix=f'.{destination.name}.', dir=destination.parent)
    try:
        with os.fdopen(fd, 'wb') as out, open(source, 'rb') as src:
            shutil.copyfileobj(src, out)
            out.flush()
            os.fsync(out.fileno())
        if old_stat:
            os.chmod(tmp, stat.S_IMODE(old_stat.st_mode))
            os.chown(tmp, old_stat.st_uid, old_stat.st_gid)
        os.replace(tmp, destination)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_config(path):
    return ConfigObj(str(path), encoding='utf-8', interpolation=False, file_error=True)


def check_settings(before, after, path=()):
    """Refuse a migration that removes or changes an existing user setting."""
    for key, value in before.items():
        if not path and key == 'version':
            continue
        location = (*path, key)
        if key not in after:
            raise RuntimeError(f'Migration removed setting {"/".join(location)}')
        if isinstance(value, Section):
            if not isinstance(after[key], Section):
                raise RuntimeError(f'Migration changed section {"/".join(location)}')
            check_settings(value, after[key], location)
        elif value != after[key]:
            # Log keys only: values may contain credentials.
            raise RuntimeError(f'Migration changed setting {"/".join(location)}; review manually')


def restore_files(config, state, backup):
    roots = weeutil.startup.extract_roots(config)
    restored = 0
    hashes = {}
    for relative in json.loads((SEED / 'files.json').read_text()):
        if relative.startswith('bin/user/'):
            target = Path(roots['USER_DIR']) / relative[len('bin/user/'):]
        else:
            target = Path(roots['SKIN_DIR']) / relative[len('skins/'):]
        source = SEED / relative
        managed = (relative.startswith('bin/user/') and '/installer/' not in relative
                   and relative not in ('bin/user/__init__.py', 'bin/user/extensions.py'))
        if managed:
            hashes[relative] = hashlib.sha256(source.read_bytes()).hexdigest()
            if target.exists():
                actual = hashlib.sha256(target.read_bytes()).hexdigest()
                previous = state.get('module_hashes', {}).get(relative)
                if actual != hashes[relative] and previous != hashes[relative]:
                    if previous and actual != previous:
                        print(f'[WARN] Keeping locally modified module {relative}', flush=True)
                    else:
                        atomic_copy(target, backup / 'files' / relative)
                        atomic_copy(source, target)
        # Existing templates and settings always take precedence.
        if not target.exists():
            atomic_copy(source, target)
            restored += 1
    print(f'[INFO] Restored {restored} missing station files', flush=True)
    state['module_hashes'] = hashes
    return roots


def backup_databases(config, backup):
    """Resolve configured database paths using WeeWX's own inheritance rules."""
    for name in config['Databases'].sections:
        database = weewx.manager.get_database_dict_from_config(config, name)
        if database['driver'] != 'weedb.sqlite':
            continue
        source = Path(database.get('SQLITE_ROOT', '')) / database['database_name']
        if not source.exists():
            continue
        destination = backup / 'databases' / f'{name}.sdb'
        destination.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(source.resolve().as_uri() + '?mode=ro', uri=True) as src:
            with sqlite3.connect(destination) as dst:
                src.backup(dst)
                if dst.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
                    raise RuntimeError(f'Backup failed integrity check: {name}')
        print(f'[INFO] Verified SQLite backup: {name}', flush=True)


def persist_directories(config, data):
    """Keep user modules and ALL skin files with the existing data mount.

    Explicit mounts and paths already inside data are left in place. Legacy
    writable-layer directories are copied before switching to a symlink.
    """
    roots = weeutil.startup.extract_roots(config)
    mounts = {line.split()[4].replace('\\040', ' ') for line in
              Path('/proc/self/mountinfo').read_text().splitlines()}
    for key, name in (('USER_DIR', 'user'), ('SKIN_DIR', 'skins')):
        target = Path(roots[key])
        if str(target) in mounts or target.resolve().is_relative_to(data.resolve()):
            continue
        saved = data / 'station' / name
        saved.mkdir(parents=True, exist_ok=True)
        if target.exists():
            # Merge missing legacy files, keeping already-persisted edits.
            for source in target.rglob('*'):
                destination = saved / source.relative_to(target)
                if source.is_file() and not destination.exists():
                    atomic_copy(source, destination)
            previous = target.with_name(target.name + '.before-persistence')
            if previous.exists():
                raise RuntimeError(f'Review existing directory before migration: {previous}')
            target.rename(previous)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(saved, target_is_directory=True)


def validate_imports(config):
    weeutil.startup.initialize(config)
    driver = config['Station']['station_type']
    importlib.import_module(config[driver]['driver'])
    objects = []
    for services in config['Engine']['Services'].values():
        objects.extend(weeutil.weeutil.option_as_list(services) or [])
    skin_root = Path(weeutil.startup.extract_roots(config)['SKIN_DIR'])
    for report in config['StdReport'].sections:
        settings = config['StdReport'][report]
        if not weeutil.weeutil.to_bool(settings.get('enable', True)):
            continue
        skin = settings.get('skin')
        if skin:
            skin_config = read_config(skin_root / skin / 'skin.conf')
            objects.extend(weeutil.weeutil.option_as_list(
                skin_config.get('Generators', {}).get('generator_list', [])) or [])
    for dotted_name in objects:
        obj = weeutil.weeutil.get_object(dotted_name)
        if inspect.isclass(obj) and issubclass(obj, weewx.reportengine.ReportGenerator):
            signature = inspect.signature(obj.__init__)
            if 'stop_event' not in signature.parameters and not any(
                    p.kind == p.VAR_KEYWORD for p in signature.parameters.values()):
                raise RuntimeError(f'{dotted_name} needs WeeWX 5.5 stop_event support')


def main():
    home = Path(os.environ['WEEWX_HOME'])
    data = home / 'data'
    data.mkdir(parents=True, exist_ok=True)
    persistent = data / 'weewx.conf'
    runtime = home / 'weewx.conf'
    state_path = data / '.container-state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    backup = data / 'backups' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')

    # Recover an older root-only layout instead of creating a new station.
    existing = persistent.exists() or runtime.exists()
    source = persistent if persistent.exists() else runtime
    if existing:
        before = read_config(source)
        if source != runtime:
            atomic_copy(source, runtime)
    else:
        if any((home / 'archive').glob('*.sdb')):
            raise RuntimeError('Database found without station configuration; restore weewx.conf first')
        before = None
        config = read_config(SEED / 'weewx.conf')
        config.filename = str(runtime)
        config['WEEWX_ROOT'] = str(home)
        station = config['Station']
        station['location'] = os.environ.get('LOCATION', 'Unknown')
        station['latitude'] = os.environ.get('LAT', '0.0')
        station['longitude'] = os.environ.get('LON', '0.0')
        station['altitude'] = os.environ.get('ALTITUDE', '0,meter').split(',')
        station['station_url'] = os.environ.get('STATION_URL', '')
        config.write()

    if existing and state.get('weewx_version') != weewx.__version__:
        backup.mkdir(parents=True, mode=0o700)
        atomic_copy(source, backup / 'weewx.conf')
        if (data / 'skin.conf').exists():
            atomic_copy(data / 'skin.conf', backup / 'skin.conf')
        print(f'[INFO] Configuration backup: {backup}', flush=True)
        # Work on the runtime copy. Upstream --dry-run does not guard config writes.
        subprocess.run(['weectl', 'station', 'upgrade', '--config', str(runtime),
                        '--what', 'config', '--yes'], check=True)
        check_settings(before, read_config(runtime))

    _, config = weecfg.read_config(str(runtime))
    forecast_version = os.environ['WEEWX_FORECAST_VERSION']
    if existing and (state.get('weewx_version') != weewx.__version__
                     or state.get('forecast_version') != forecast_version):
        # The weather archive and forecast DB are both covered before first launch.
        backup_databases(config, backup)
        binding = config.get('Forecast', {}).get('data_binding', 'forecast_binding')
        if binding in config['DataBindings']:
            name = config['DataBindings'][binding]['database']
            database = weewx.manager.get_database_dict_from_config(config, name)
            if (database['driver'] != 'weedb.sqlite'
                    and os.environ.get('WEEWX_EXTERNAL_DB_BACKUP_CONFIRMED') != '1'):
                raise RuntimeError('Back up the external forecast DB, then set '
                                   'WEEWX_EXTERNAL_DB_BACKUP_CONFIRMED=1')
    persist_directories(config, data)
    roots = restore_files(config, state, backup)
    skin = Path(roots['SKIN_DIR']) / 'weewx-wdc' / 'skin.conf'
    if (data / 'skin.conf').exists():
        atomic_copy(data / 'skin.conf', skin)
    validate_imports(config)
    if not persistent.exists() or runtime.read_bytes() != persistent.read_bytes():
        atomic_copy(runtime, persistent)
    if not (data / 'skin.conf').exists():
        atomic_copy(skin, data / 'skin.conf')
    state['weewx_version'] = weewx.__version__
    state['forecast_version'] = forecast_version
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8') as tmp:
        json.dump(state, tmp)
        tmp.flush()
        atomic_copy(tmp.name, state_path)
    print('[INFO] Station configuration and imports verified', flush=True)


if __name__ == '__main__':
    main()
