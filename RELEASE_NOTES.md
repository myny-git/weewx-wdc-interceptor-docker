WeeWX 5.5.2 and Forecast 5.4, retaining Python 3.11, WDC 3.5.1 and Interceptor 1.0.1.

- Pin MQTT, XAggs and XCumulative source revisions and GTS 1.2; use Paho MQTT 1.6.1 with weewx-mqtt 0.24.
- Prepare extensions during the build. Restore missing files independently without rerunning installers against existing user settings.
- Persist all skins and user modules using the existing data mount; back up replaced bundled modules and preserve detected local edits.
- Back up configuration and verify SQLite backups before the first version upgrade. Check existing settings before atomically committing the migrated config.
- Forecast 5.4 automatically renames forecast columns `desc` to `description` and `offset` to `tide_offset`. Restore the pre-upgrade forecast database before reverting to Forecast 4.1.
- Back up the full station from the correct container, restart it on errors, verify the archive and keep local copies after optional S3 upload.
- Test migrations, customized settings, missing modules, container replacement, Forecast rows and backup/restore. Publishing remains manual and uses the exact tested image.

Before upgrading the NAS, make and verify a full external backup, retain the old image and confirm the actual existing volume names. See readme.md for the procedure. Automatic backups in the data mount are an extra recovery point, not a substitute for an external backup.
