"""Run inside the built image: python -m unittest discover -s /tests -v."""
import hashlib
import importlib
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import queue
import unittest
from pathlib import Path

from configobj import ConfigObj
import weecfg
import weewx.manager

BOOTSTRAP = '/usr/local/lib/weewx-container/bootstrap.py'


class StationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.data = self.home / 'data'
        self.config = self.data / 'weewx.conf'
        self.env = dict(os.environ, WEEWX_HOME=str(self.home), LOCATION='Test station',
                        LAT='51.1', LON='4.2', TZ='Europe/Brussels')

    def bootstrap(self, success=True):
        result = subprocess.run([sys.executable, BOOTSTRAP], env=self.env,
                                capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def config_obj(self):
        return ConfigObj(str(self.config), encoding='utf-8', interpolation=False)

    def legacy(self):
        self.bootstrap()
        (self.data / '.container-state.json').unlink()
        config = self.config_obj()
        config['version'] = '5.3.1'
        config['Station']['location'] = 'My own station'
        config['StdRESTful']['MQTT']['server_url'] = 'mqtt://test-user:test-password@broker:1883'
        config['Interceptor']['port'] = '9877'
        config.write()
        return config

    def test_fresh_install_and_repeat_start(self):
        self.bootstrap()
        config = self.config_obj()
        self.assertEqual(config['Station']['location'], 'Test station')
        self.assertEqual(config['Station']['station_type'], 'Interceptor')
        self.assertEqual(config['Interceptor']['port'], '9877')
        self.assertIn('user.mqtt.MQTT', config['Engine']['Services']['restful_services'])
        before = self.config.read_bytes()
        self.bootstrap()
        self.assertEqual(self.config.read_bytes(), before)

    def test_upgrade_preserves_settings_and_backs_up_databases(self):
        old = self.legacy()
        archive = self.home / 'archive'
        archive.mkdir()
        for name in ('weewx', 'forecast'):
            with sqlite3.connect(archive / f'{name}.sdb') as db:
                db.execute('CREATE TABLE history (value TEXT)')
                db.execute('INSERT INTO history VALUES (?)', ('weather-data',))
        before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in archive.iterdir()}
        old_config = self.config.read_bytes()
        self.config.chmod(0o640)
        self.bootstrap()
        new = self.config_obj()
        self.assertEqual(new['Station'], old['Station'])
        self.assertEqual(new['StdRESTful']['MQTT'], old['StdRESTful']['MQTT'])
        self.assertEqual(new['Databases'], old['Databases'])
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        backup = next((self.data / 'backups').iterdir())
        self.assertEqual((backup / 'weewx.conf').read_bytes(), old_config)
        for name in ('archive_sqlite', 'forecast_sqlite'):
            with sqlite3.connect(backup / 'databases' / f'{name}.sdb') as db:
                self.assertEqual(db.execute('SELECT * FROM history').fetchall(), [('weather-data',)])
        self.assertEqual(before, {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in archive.iterdir()})

    def test_recreation_restores_all_files_and_preserves_customizations(self):
        self.bootstrap()
        skin = self.home / 'skins/weewx-wdc'
        (skin / 'custom.html.tmpl').write_text('my template')
        custom_config = (self.data / 'skin.conf').read_bytes() + b'\n# my WDC settings\n'
        (self.data / 'skin.conf').write_bytes(custom_config)
        (self.home / 'bin/user/custom.py').write_text('VALUE = 123\n')
        # A missing MQTT module must be repaired even with Interceptor present.
        (self.home / 'bin/user/mqtt.py').unlink()
        self.bootstrap()
        self.assertTrue((self.home / 'bin/user/mqtt.py').exists())
        self.assertEqual((skin / 'skin.conf').read_bytes(), custom_config)
        self.assertEqual((skin / 'custom.html.tmpl').read_text(), 'my template')
        # Simulate the old Compose setup: only data/archive/html survive recreation.
        shutil.rmtree(self.home / 'bin')
        (self.home / 'skins').unlink()
        (self.home / 'weewx.conf').unlink()
        self.bootstrap()
        for name in ('interceptor', 'mqtt', 'forecast', 'xaggs', 'GTS', 'dayboundarystats',
                     'barometer', 'weewx_wdc', 'xcumulative'):
            self.assertTrue((self.home / f'bin/user/{name}.py').exists(), name)
        self.assertTrue((skin / 'dist/main.js').exists())
        self.assertEqual((skin / 'skin.conf').read_bytes(), custom_config)
        self.assertEqual((skin / 'custom.html.tmpl').read_text(), 'my template')
        self.assertEqual((self.home / 'bin/user/custom.py').read_text(), 'VALUE = 123\n')

    def test_old_managed_module_is_backed_up_and_updated(self):
        self.legacy()
        module = self.home / 'bin/user/forecast.py'
        module.write_text('# old forecast module\n')
        self.bootstrap()
        self.assertIn('rename_old_columns', module.read_text())
        backups = list((self.data / 'backups').glob('*/files/bin/user/forecast.py'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), '# old forecast module\n')

    def test_locally_modified_module_is_preserved(self):
        self.bootstrap()
        module = self.home / 'bin/user/xaggs.py'
        original = module.read_bytes() + b'\n# local customization\n'
        module.write_bytes(original)
        self.bootstrap()
        self.assertEqual(module.read_bytes(), original)

    def test_failed_validation_keeps_persistent_config(self):
        self.legacy()
        bad_skin = self.home / 'skins/Bad'
        bad_skin.mkdir()
        (bad_skin / 'skin.conf').write_text('[Generators]\n generator_list = user.custom.Bad\n')
        (self.home / 'bin/user/custom.py').write_text(
            'from weewx.reportengine import ReportGenerator\n'
            'class Bad(ReportGenerator):\n def __init__(self, config, skin): pass\n')
        config = self.config_obj()
        config['StdReport']['Bad'] = {'skin': 'Bad', 'enable': 'true'}
        config.write()
        original = self.config.read_bytes()
        result = self.bootstrap(success=False)
        self.assertIn('stop_event', result.stderr)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.data / '.container-state.json').exists())

    def test_missing_configuration_with_archive_refuses_new_station(self):
        (self.home / 'archive').mkdir()
        (self.home / 'archive/weewx.sdb').write_bytes(b'existing data')
        self.bootstrap(success=False)
        self.assertFalse(self.config.exists())

    def test_forecast_column_migration_preserves_rows_and_backup(self):
        self.legacy()
        sys.path.insert(0, str(self.home / 'bin'))
        # Load this test station's module, rather than a previous test's package.
        for name in list(sys.modules):
            if name == 'user' or name.startswith('user.'):
                del sys.modules[name]
        forecast = importlib.import_module('user.forecast')
        database = self.home / 'archive/forecast.sdb'
        database.parent.mkdir()
        old_names = {'description': 'desc', 'tide_offset': 'offset'}
        columns = [f'"{old_names.get(name, name)}" {kind}' for name, kind in forecast.schema]
        with sqlite3.connect(database) as db:
            db.execute('CREATE TABLE archive (' + ','.join(columns) + ')')
            db.execute('INSERT INTO archive (method, usUnits, dateTime, issued_ts, event_ts, '
                       '"desc", "offset") VALUES (?, ?, ?, ?, ?, ?, ?)',
                       ('Zambretti', 1, 1700000000, 1700000000, 1700000300, 'Fine', 1.25))
        self.bootstrap()
        _, config = weecfg.read_config(str(self.home / 'weewx.conf'))
        with weewx.manager.open_manager_with_config(config, 'forecast_binding') as manager:
            forecast.Forecast.rename_old_columns(manager)
        with sqlite3.connect(database) as db:
            row = db.execute('SELECT description, tide_offset FROM archive').fetchone()
            self.assertEqual(row, ('Fine', 1.25))
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone(), ('ok',))
        backup = next((self.data / 'backups').glob('*/databases/forecast_sqlite.sdb'))
        with sqlite3.connect(backup) as db:
            self.assertEqual(db.execute('SELECT "desc", "offset" FROM archive').fetchone(),
                             ('Fine', 1.25))

    def test_wdc_report_renders_existing_weather_records(self):
        self.bootstrap()
        _, config = weecfg.read_config(str(self.home / 'weewx.conf'))
        now = int(time.time()) // 300 * 300
        with weewx.manager.open_manager_with_config(config, 'wx_binding', initialize=True) as db:
            for age in (600, 300, 0):
                db.addRecord(dict(dateTime=now-age, usUnits=1, interval=5,
                                  outTemp=68.0, outHumidity=50.0, barometer=29.92,
                                  windSpeed=3.0, windDir=180.0, rain=0.0))
        result = subprocess.run(['weectl', 'report', 'run', '--config',
                                 str(self.home / 'weewx.conf')],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        index = self.home / 'public_html/index.html'
        self.assertTrue(index.exists(), result.stdout + result.stderr)
        self.assertGreater(index.stat().st_size, 1000)

    def test_mqtt_extension_connects_and_publishes_with_pinned_paho(self):
        self.bootstrap()
        sys.path.insert(0, str(self.home / 'bin'))
        for name in list(sys.modules):
            if name == 'user' or name.startswith('user.'):
                del sys.modules[name]
        mqtt = importlib.import_module('user.mqtt')
        received = queue.Queue()
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(10)
        self.addCleanup(listener.close)

        def broker():
            try:
                with listener.accept()[0] as connection:
                    connection.settimeout(10)
                    while True:
                        header = connection.recv(1)
                        if not header:
                            return
                        length = 0
                        multiplier = 1
                        while True:
                            byte = connection.recv(1)[0]
                            length += (byte & 127) * multiplier
                            if not byte & 128:
                                break
                            multiplier *= 128
                        body = b''
                        while len(body) < length:
                            body += connection.recv(length-len(body))
                        if header[0] >> 4 == 1:
                            connection.sendall(b'\x20\x02\x00\x00')
                        elif header[0] >> 4 == 3:
                            size = int.from_bytes(body[:2], 'big')
                            received.put((body[2:2+size], body[2+size:]))
                            return
            except Exception as error:
                received.put(error)

        worker = threading.Thread(target=broker, daemon=True)
        worker.start()
        client = mqtt.MQTTThread(queue.Queue(),
                                 f'mqtt://127.0.0.1:{listener.getsockname()[1]}',
                                 retry_wait=0, augment_record=False)
        client.get_mqtt_client()
        self.assertIsNotNone(client.mc)
        try:
            published = client.mc.publish('weather/test', '20.0')
            published.wait_for_publish(timeout=5)
            self.assertEqual(received.get(timeout=10), (b'weather/test', b'20.0'))
        finally:
            client.mc.disconnect()
            client.mc.loop_stop()
            worker.join(timeout=10)


if __name__ == '__main__':
    unittest.main()
