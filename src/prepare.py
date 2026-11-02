"""Install bundled extensions once, into an immutable image seed."""
import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from configobj import ConfigObj


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)


def main():
    seed = Path('/opt/weewx-seed')
    run(['weectl', 'station', 'create', str(seed), '--no-prompt', '--units=metric'])
    for name in ('interceptor', 'forecast', 'mqtt', 'xaggs', 'GTS', 'wdc', 'xcumulative'):
        with tempfile.TemporaryDirectory() as tmp:
            with zipfile.ZipFile(Path(sys.argv[1]) / f'{name}.zip') as archive:
                archive.extractall(tmp)
            installers = list(Path(tmp).rglob('install.py'))
            if len(installers) != 1:
                raise RuntimeError(f'{name}: expected exactly one extension installer')
            run(['weectl', 'extension', 'install', '--yes', '--config',
                 str(seed / 'weewx.conf'), str(installers[0].parent)])
            print(f'Installed {name}', flush=True)

    config = ConfigObj(str(seed / 'weewx.conf'), encoding='utf-8', interpolation=False)
    config['Station']['station_type'] = 'Interceptor'
    config['Interceptor'] = dict(driver='user.interceptor', device_type='wu-client',
                                 mode='listen', address='0.0.0.0', port='9877')
    for report in ('SeasonsReport', 'StandardReport', 'SmartphoneReport', 'MobileReport', 'forecast'):
        if report in config['StdReport']:
            config['StdReport'][report]['enable'] = 'false'
    config.write()
    files = [str(p.relative_to(seed)) for base in ('bin/user', 'skins')
             for p in sorted((seed / base).rglob('*')) if p.is_file()]
    (seed / 'files.json').write_text(json.dumps(files, indent=2) + '\n')


if __name__ == '__main__':
    main()
