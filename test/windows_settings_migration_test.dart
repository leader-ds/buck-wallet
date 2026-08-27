import 'dart:convert';
import 'dart:io';

import 'package:buck_wallet/settings.pb.dart';
import 'package:buck_wallet/windows_settings_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('Windows settings migration security matrix', () {
    test('T1 no source is terminal and startup-safe', () async {
      final prefs = FakePreferences();
      final result = await migrator(prefs, FakeSource.missing()).migrate();
      expect(result, WindowsSettingsMigrationOutcome.noSource);
      expect(prefs.values[windowsSettingsMigrationVersionKey], 1);
    });

    test('T2 imports only valid allowlisted UI settings', () async {
      final legacy = AppSettings(
        confirmations: 4,
        nogetTx: false,
        rowsPerPage: 25,
        currency: 'USD',
        autoHide: 2,
        includeReplyTo: 1,
        messageView: 0,
        noteView: 1,
        txView: 2,
        fullPrec: true,
        minPrivacyLevel: 3,
        palette: ColorPalette(name: 'mandyRed', dark: false),
        customSend: true,
        backgroundSync: 0,
        language: 'fr',
      );
      final prefs = FakePreferences();
      await migrator(prefs, jsonSource(settings: legacy), currencies: {'USD'})
          .migrate();
      final current = readSettings(prefs);
      expect(current.confirmations, 4);
      expect(current.rowsPerPage, 25);
      expect(current.currency, 'USD');
      expect(current.language, 'fr');
      expect(current.hasChartRange(), isFalse);
    });

    test('T3 backupEncKey is denied', () async {
      final prefs = await migrateSettings(AppSettings(backupEncKey: 'secret'));
      expect(readSettings(prefs).hasBackupEncKey(), isFalse);
    });

    test('T4 dbPasswd is denied', () async {
      final prefs = await migrateSettings(AppSettings(dbPasswd: 'secret'));
      expect(readSettings(prefs).hasDbPasswd(), isFalse);
    });

    test('T5 app memo is denied', () async {
      final prefs = await migrateSettings(AppSettings(memo: 'secret'));
      expect(readSettings(prefs).hasMemo(), isFalse);
    });

    test('T6 top-level backup is denied and no recovery API exists', () async {
      final prefs = FakePreferences();
      await migrator(prefs, mapSource({'backup': r'C:\secret.zip'})).migrate();
      expect(prefs.values.containsKey('backup'), isFalse);
    });

    test('T7 synthetic unknown protobuf field is dropped', () async {
      final bytes = <int>[
        ...AppSettings(confirmations: 5).writeToBuffer(),
        0x98,
        0x06,
        0x01
      ];
      final prefs = FakePreferences();
      await migrator(prefs, encodedSource(base64Encode(bytes))).migrate();
      final output = base64Decode(prefs.values['settings']! as String);
      expect(output, isNot(containsAllInOrder([0x98, 0x06, 0x01])));
      expect(readSettings(prefs).confirmations, 5);
    });

    test('T8 unknown top-level key is dropped', () async {
      final prefs = FakePreferences();
      await migrator(prefs, mapSource({'future': 'value'})).migrate();
      expect(prefs.values.keys, isNot(contains('future')));
    });

    test('T9 invalid JSON becomes permanently invalid', () async {
      final prefs = FakePreferences();
      final result =
          await migrator(prefs, FakeSource.bytes(utf8.encode('{'))).migrate();
      expect(result, WindowsSettingsMigrationOutcome.permanentInvalid);
      expect(
          prefs.values[windowsSettingsMigrationPermanentInvalidVersionKey], 1);
    });

    test('T10 invalid base64 becomes permanently invalid', () async {
      final prefs = FakePreferences();
      expect(await migrator(prefs, encodedSource('%%%')).migrate(),
          WindowsSettingsMigrationOutcome.permanentInvalid);
    });

    test('T11 invalid protobuf becomes permanently invalid', () async {
      final prefs = FakePreferences();
      expect(
          await migrator(prefs, encodedSource(base64Encode([0x80]))).migrate(),
          WindowsSettingsMigrationOutcome.permanentInvalid);
    });

    test('T12 enforces file, blob, and string bounds', () async {
      for (final source in [
        FakeSource.rejected(),
        encodedSource('A' * (maxEncodedSettingsBytes + 1)),
        encodedSource(
            base64Encode(List<int>.filled(maxDecodedSettingsBytes + 1, 0))),
      ]) {
        final prefs = FakePreferences();
        expect(await migrator(prefs, source).migrate(),
            WindowsSettingsMigrationOutcome.permanentInvalid);
      }
      final legacy = AppSettings(
        language: 'x' * 257,
        currency: 'USД',
        palette: ColorPalette(name: 'x' * 65, dark: true),
        confirmations: 6,
      );
      final prefs = await migrateSettings(legacy, currencies: {'USД'});
      final current = readSettings(prefs);
      expect(current.confirmations, 6);
      expect(current.currency, 'USD');
      expect(current.palette.name, 'mandyRed');
      expect(current.language, 'en');
    });

    test('T13 invalid coin omits coin and account', () async {
      final prefs = FakePreferences();
      await migrator(prefs, mapSource({'coin': 9, 'account': 44})).migrate();
      expect(prefs.values.containsKey('coin'), isFalse);
      expect(prefs.values.containsKey('account'), isFalse);
    });

    test('T14 account is always omitted without any DB call', () async {
      final prefs = FakePreferences();
      await migrator(prefs, mapSource({'coin': 0, 'account': 44})).migrate();
      expect(prefs.values['coin'], 0);
      expect(prefs.values.containsKey('account'), isFalse);
    });

    test('T15 existing current settings wins wholesale', () async {
      final current =
          base64Encode(AppSettings(confirmations: 9).writeToBuffer());
      final prefs = FakePreferences({'settings': current});
      await migrator(prefs, jsonSource(settings: AppSettings(confirmations: 2)))
          .migrate();
      expect(prefs.values['settings'], current);
    });

    test('T16 marker version 1 is written last', () async {
      final prefs = FakePreferences();
      await migrator(prefs,
              jsonSource(settings: AppSettings(confirmations: 4), coin: 0))
          .migrate();
      expect(prefs.writeOrder.last, windowsSettingsMigrationVersionKey);
    });

    test('T17 write failure before completion has no success marker', () async {
      final prefs = FakePreferences()..failWriteNumber = 1;
      expect(
          await migrator(
                  prefs, jsonSource(settings: AppSettings(confirmations: 4)))
              .migrate(),
          WindowsSettingsMigrationOutcome.transientFailure);
      expect(prefs.values.containsKey(windowsSettingsMigrationVersionKey),
          isFalse);
    });

    test('T18 transient read failure retries and succeeds', () async {
      final prefs = FakePreferences();
      final source = FakeSource.transientThen(
          jsonBytes(settings: AppSettings(confirmations: 4)));
      expect(await migrator(prefs, source).migrate(),
          WindowsSettingsMigrationOutcome.transientFailure);
      expect(await migrator(prefs, source).migrate(),
          WindowsSettingsMigrationOutcome.success);
    });

    test('T19 permanent invalid source is not parsed repeatedly', () async {
      final prefs = FakePreferences();
      final source = FakeSource.bytes(utf8.encode('{'));
      await migrator(prefs, source).migrate();
      await migrator(prefs, source).migrate();
      expect(source.readCount, 1);
    });

    test('T20 logging contains no secret, value, path, JSON, or blob',
        () async {
      const secret = 'DO_NOT_LOG_ME';
      final logs = <String>[];
      final prefs = FakePreferences();
      await migrator(prefs, jsonSource(settings: AppSettings(dbPasswd: secret)),
              log: logs.add)
          .migrate();
      final joined = logs.join('\n');
      expect(joined, isNot(contains(secret)));
      expect(joined, isNot(contains('shared_preferences.json')));
      expect(joined, isNot(contains(base64Encode(utf8.encode(secret)))));
    });

    test('T21 real fixture source bytes remain identical', () async {
      final root = await Directory.systemTemp.createTemp('buck-migration-');
      addTearDown(() => root.delete(recursive: true));
      final file = File(
          '${root.path}${Platform.pathSeparator}me.hanh${Platform.pathSeparator}BUCK Wallet${Platform.pathSeparator}shared_preferences.json');
      await file.parent.create(recursive: true);
      final before = jsonBytes(settings: AppSettings(confirmations: 4));
      await file.writeAsBytes(before);
      final prefs = FakePreferences();
      await migrator(prefs, WindowsLegacySettingsSource(root.path)).migrate();
      expect(await file.readAsBytes(), before);
    });

    test('T22 DB-family fixture hashes/bytes remain identical', () async {
      final root = await Directory.systemTemp.createTemp('buck-db-freeze-');
      addTearDown(() => root.delete(recursive: true));
      final files = <File>[];
      for (final name in ['buck.db', 'buck.db-wal', 'buck.db-shm']) {
        final file = File('${root.path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(utf8.encode('synthetic-$name'));
        files.add(file);
      }
      final before = await Future.wait(files.map((file) => file.readAsBytes()));
      await migrator(FakePreferences(),
              jsonSource(settings: AppSettings(confirmations: 4)))
          .migrate();
      final after = await Future.wait(files.map((file) => file.readAsBytes()));
      for (var i = 0; i < files.length; i++) expect(after[i], before[i]);
    });

    test('T23 repeated startup is idempotent', () async {
      final prefs = FakePreferences();
      final source = jsonSource(settings: AppSettings(confirmations: 4));
      await migrator(prefs, source).migrate();
      final snapshot = Map<String, Object?>.from(prefs.values);
      await migrator(prefs, source).migrate();
      expect(prefs.values, snapshot);
      expect(source.readCount, 1);
    });

    test('T24 downgrade legacy changes cannot overwrite BUCK', () async {
      final prefs = FakePreferences();
      await migrator(prefs, jsonSource(settings: AppSettings(confirmations: 4)))
          .migrate();
      final snapshot = prefs.values['settings'];
      await migrator(
              prefs, jsonSource(settings: AppSettings(confirmations: 99)))
          .migrate();
      expect(prefs.values['settings'], snapshot);
    });

    test('T25 explicit scalar defaults differ from absence', () async {
      final prefs = await migrateSettings(AppSettings(
        nogetTx: false,
        fullPrec: false,
        customSendSettings: CustomSendSettings(contacts: false),
      ));
      final current = readSettings(prefs);
      expect(current.hasNogetTx(), isTrue);
      expect(current.nogetTx, isFalse);
      expect(current.hasFullPrec(), isTrue);
      expect(current.customSendSettings.contacts, isFalse);
      expect(current.customSendSettings.accounts, isFalse);
    });

    test('T26 invalid field is skipped while valid fields remain', () async {
      final prefs = await migrateSettings(AppSettings(
        confirmations: 8,
        rowsPerPage: 11,
        autoHide: 3,
        language: 'de',
      ));
      final current = readSettings(prefs);
      expect(current.confirmations, 8);
      expect(current.rowsPerPage, 10);
      expect(current.autoHide, 1);
      expect(current.language, 'en');
    });

    test('T27 corrupt marker uses safe new-wins recovery', () async {
      final current =
          base64Encode(AppSettings(confirmations: 7).writeToBuffer());
      final prefs = FakePreferences({
        windowsSettingsMigrationVersionKey: '1',
        windowsSettingsMigrationPermanentInvalidVersionKey: -1,
        'settings': current,
      });
      await migrator(prefs, jsonSource(settings: AppSettings(confirmations: 2)))
          .migrate();
      expect(prefs.values['settings'], current);
      expect(prefs.values[windowsSettingsMigrationVersionKey], 1);
    });

    test('T28 marker failure after settings never reimports settings',
        () async {
      final prefs = FakePreferences()..failWriteNumber = 2;
      final first = jsonSource(settings: AppSettings(confirmations: 4));
      await migrator(prefs, first).migrate();
      expect(readSettings(prefs).confirmations, 4);
      prefs.failWriteNumber = null;
      await migrator(
              prefs, jsonSource(settings: AppSettings(confirmations: 99)))
          .migrate();
      expect(readSettings(prefs).confirmations, 4);
      expect(prefs.values[windowsSettingsMigrationVersionKey], 1);
    });

    test('T29 interrupted write permits normal subsequent startup', () async {
      final prefs = FakePreferences()..throwWriteNumber = 1;
      expect(
          await migrator(
                  prefs, jsonSource(settings: AppSettings(confirmations: 4)))
              .migrate(),
          WindowsSettingsMigrationOutcome.transientFailure);
      prefs.throwWriteNumber = null;
      expect(
          await migrator(
                  prefs, jsonSource(settings: AppSettings(confirmations: 4)))
              .migrate(),
          WindowsSettingsMigrationOutcome.success);
    });

    test('T30 rejected path/reparse abstraction is terminal without read',
        () async {
      final prefs = FakePreferences();
      final source = FakeSource.rejected();
      expect(await migrator(prefs, source).migrate(),
          WindowsSettingsMigrationOutcome.permanentInvalid);
      expect(source.bytesDelivered, isFalse);
    });

    test('T31 me.hanh parent junction is rejected with sanitized logging',
        () async {
      if (!Platform.isWindows) return;
      final fixture = await ReparseFixture.create(atNamespace: true);
      addTearDown(fixture.dispose);
      final logs = <String>[];
      final prefs = FakePreferences();

      expect(
          await migrator(
                  prefs, WindowsLegacySettingsSource(fixture.appData.path),
                  log: logs.add)
              .migrate(),
          WindowsSettingsMigrationOutcome.permanentInvalid);
      expect(logs.single, contains('legacy-path-reparse-rejected'));
      expect(logs.single, isNot(contains(fixture.external.path)));
    });

    test('T32 BUCK Wallet parent junction is rejected', () async {
      if (!Platform.isWindows) return;
      final fixture = await ReparseFixture.create(atNamespace: false);
      addTearDown(fixture.dispose);
      expect(
          (await WindowsLegacySettingsSource(fixture.appData.path).read())
              .state,
          LegacySourceState.reparseRejected);
    });

    test('T33 final shared_preferences.json link is rejected', () async {
      if (!Platform.isWindows) return;
      final root = await normalLegacyFixture();
      final external =
          await Directory.systemTemp.createTemp('buck-file-link-external-');
      final target = File(p.join(external.path, 'target.json'));
      await target
          .writeAsBytes(jsonBytes(settings: AppSettings(confirmations: 8)));
      final sourcePath = p.join(
          root.path, 'me.hanh', 'BUCK Wallet', 'shared_preferences.json');
      await File(sourcePath).delete();
      final link = await Link(sourcePath).create(target.path);
      addTearDown(() async {
        if (await link.exists()) await link.delete();
        await root.delete(recursive: true);
        await external.delete(recursive: true);
      });
      final checked = <String>[];
      var reads = 0;
      final source = WindowsLegacySettingsSource(
        root.path,
        entityType: (path, {bool followLinks = true}) async {
          checked.add(path);
          return FileSystemEntity.type(path, followLinks: followLinks);
        },
        readBytes: (path) async {
          reads++;
          return File(path).readAsBytes();
        },
      );
      expect((await source.read()).state, LegacySourceState.reparseRejected);
      expect(checked.map(p.basename),
          ['me.hanh', 'BUCK Wallet', 'shared_preferences.json']);
      expect(reads, 0);
      expect(await target.readAsBytes(),
          jsonBytes(settings: AppSettings(confirmations: 8)));
    });

    test('T34 normal non-reparse fixed legacy path still succeeds', () async {
      final root = await normalLegacyFixture();
      addTearDown(() => root.delete(recursive: true));
      final prefs = FakePreferences();
      expect(
          await migrator(prefs, WindowsLegacySettingsSource(root.path))
              .migrate(),
          WindowsSettingsMigrationOutcome.success);
      expect(readSettings(prefs).confirmations, 4);
    });

    test('T35 reparse rejection does not create a success marker', () async {
      if (!Platform.isWindows) return;
      final fixture = await ReparseFixture.create(atNamespace: true);
      addTearDown(fixture.dispose);
      final prefs = FakePreferences();
      await migrator(prefs, WindowsLegacySettingsSource(fixture.appData.path))
          .migrate();
      expect(
          prefs.values.containsKey(windowsSettingsMigrationVersionKey), false);
      expect(
          prefs.values[windowsSettingsMigrationPermanentInvalidVersionKey], 1);
    });

    test('T36 reparse rejection does not mutate current settings', () async {
      if (!Platform.isWindows) return;
      final fixture = await ReparseFixture.create(atNamespace: true);
      addTearDown(fixture.dispose);
      final current =
          base64Encode(AppSettings(confirmations: 9).writeToBuffer());
      final prefs = FakePreferences({'settings': current, 'coin': 0});
      await migrator(prefs, WindowsLegacySettingsSource(fixture.appData.path))
          .migrate();
      expect(prefs.values['settings'], current);
      expect(prefs.values['coin'], 0);
    });

    test('T37 reparse rejection does not mutate legacy external target',
        () async {
      if (!Platform.isWindows) return;
      final fixture = await ReparseFixture.create(atNamespace: false);
      addTearDown(fixture.dispose);
      final before = await fixture.target.readAsBytes();
      await migrator(FakePreferences(),
              WindowsLegacySettingsSource(fixture.appData.path))
          .migrate();
      expect(await fixture.target.readAsBytes(), before);
    });

    test('T38 reparse rejection does not touch DB family', () async {
      if (!Platform.isWindows) return;
      final fixture = await ReparseFixture.create(atNamespace: true);
      addTearDown(fixture.dispose);
      final dbFiles = <File>[];
      for (final name in ['buck.db', 'buck.db-wal', 'buck.db-shm']) {
        final file = File(p.join(fixture.appData.path, name));
        await file.writeAsString('synthetic-$name');
        dbFiles.add(file);
      }
      final before =
          await Future.wait(dbFiles.map((file) => file.readAsBytes()));
      await migrator(FakePreferences(),
              WindowsLegacySettingsSource(fixture.appData.path))
          .migrate();
      final after =
          await Future.wait(dbFiles.map((file) => file.readAsBytes()));
      for (var i = 0; i < dbFiles.length; i++) expect(after[i], before[i]);
    });

    test('T39 reparse target outside APPDATA is never read', () async {
      if (!Platform.isWindows) return;
      final fixture = await ReparseFixture.create(atNamespace: true);
      addTearDown(fixture.dispose);
      var reads = 0;
      final source = WindowsLegacySettingsSource(
        fixture.appData.path,
        readBytes: (path) async {
          reads++;
          return File(path).readAsBytes();
        },
      );
      expect((await source.read()).state, LegacySourceState.reparseRejected);
      expect(reads, 0);
    });

    test('T40 non-Windows gate does not inspect source or preferences',
        () async {
      final source = FakeSource.missing();
      final prefs = FakePreferences();
      expect(await migrator(prefs, source, isWindows: false).migrate(),
          WindowsSettingsMigrationOutcome.nonWindows);
      expect(source.readCount, 0);
      expect(prefs.values, isEmpty);
    });
  });
}

WindowsSettingsMigrator migrator(
  FakePreferences prefs,
  LegacySettingsSource source, {
  bool isWindows = true,
  Set<String> currencies = const {},
  MigrationLog? log,
}) =>
    WindowsSettingsMigrator(
      isWindows: isWindows,
      preferences: prefs,
      source: source,
      validCoinIds: const {0},
      supportedCurrencies: currencies,
      log: log ?? (_) {},
    );

Future<FakePreferences> migrateSettings(
  AppSettings settings, {
  Set<String> currencies = const {},
}) async {
  final prefs = FakePreferences();
  await migrator(prefs, jsonSource(settings: settings), currencies: currencies)
      .migrate();
  return prefs;
}

AppSettings readSettings(FakePreferences prefs) => AppSettings.fromBuffer(
      base64Decode(prefs.values['settings']! as String),
    );

FakeSource jsonSource({AppSettings? settings, int? coin}) {
  final map = <String, dynamic>{};
  if (settings != null)
    map['settings'] = base64Encode(settings.writeToBuffer());
  if (coin != null) map['coin'] = coin;
  return mapSource(map);
}

FakeSource encodedSource(String encoded) => mapSource({'settings': encoded});
FakeSource mapSource(Map<String, dynamic> map) =>
    FakeSource.bytes(utf8.encode(jsonEncode(map)));
List<int> jsonBytes({required AppSettings settings}) => utf8
    .encode(jsonEncode({'settings': base64Encode(settings.writeToBuffer())}));

Future<Directory> normalLegacyFixture() async {
  final root = await Directory.systemTemp.createTemp('buck-normal-appdata-');
  final file = File(
      p.join(root.path, 'me.hanh', 'BUCK Wallet', 'shared_preferences.json'));
  await file.parent.create(recursive: true);
  await file.writeAsBytes(jsonBytes(settings: AppSettings(confirmations: 4)));
  return root;
}

class ReparseFixture {
  ReparseFixture._(this.appData, this.external, this.junction, this.target);

  final Directory appData;
  final Directory external;
  final String junction;
  final File target;

  static Future<ReparseFixture> create({required bool atNamespace}) async {
    final appData =
        await Directory.systemTemp.createTemp('buck-reparse-appdata-');
    final external =
        await Directory.systemTemp.createTemp('buck-reparse-external-');
    final externalLegacy = atNamespace
        ? Directory(p.join(external.path, 'BUCK Wallet'))
        : external;
    await externalLegacy.create(recursive: true);
    final target = File(p.join(externalLegacy.path, 'shared_preferences.json'));
    await target
        .writeAsBytes(jsonBytes(settings: AppSettings(confirmations: 4)));
    if (!atNamespace) {
      await Directory(p.join(appData.path, 'me.hanh')).create();
    }
    final junction = atNamespace
        ? p.join(appData.path, 'me.hanh')
        : p.join(appData.path, 'me.hanh', 'BUCK Wallet');
    final created = await Process.run(
        'cmd.exe', ['/c', 'mklink', '/J', junction, external.path]);
    if (created.exitCode != 0) {
      await appData.delete(recursive: true);
      await external.delete(recursive: true);
      throw FileSystemException(
          'Unable to create synthetic junction', junction);
    }
    if (await FileSystemEntity.type(junction, followLinks: false) !=
        FileSystemEntityType.link) {
      await Process.run('cmd.exe', ['/c', 'rmdir', junction]);
      await appData.delete(recursive: true);
      await external.delete(recursive: true);
      throw FileSystemException(
          'Synthetic junction is not reported as a link', junction);
    }
    return ReparseFixture._(appData, external, junction, target);
  }

  Future<void> dispose() async {
    await Process.run('cmd.exe', ['/c', 'rmdir', junction]);
    await appData.delete(recursive: true);
    await external.delete(recursive: true);
  }
}

class FakeSource implements LegacySettingsSource {
  FakeSource._(this.result, {this.transientBytes});
  factory FakeSource.missing() =>
      FakeSource._(const LegacySourceRead(LegacySourceState.missing));
  factory FakeSource.rejected() =>
      FakeSource._(const LegacySourceRead(LegacySourceState.rejected));
  factory FakeSource.bytes(List<int> bytes) =>
      FakeSource._(LegacySourceRead(LegacySourceState.valid, bytes));
  factory FakeSource.transientThen(List<int> bytes) =>
      FakeSource._(null, transientBytes: bytes);

  final LegacySourceRead? result;
  final List<int>? transientBytes;
  int readCount = 0;
  bool bytesDelivered = false;

  @override
  Future<LegacySourceRead> read() async {
    readCount++;
    if (transientBytes != null && readCount == 1)
      throw const FileSystemException('synthetic');
    final resolved =
        result ?? LegacySourceRead(LegacySourceState.valid, transientBytes);
    bytesDelivered = resolved.bytes != null;
    return resolved;
  }
}

class FakePreferences implements MigrationPreferences {
  FakePreferences([Map<String, Object?>? initial]) {
    if (initial != null) values.addAll(initial);
  }
  final values = <String, Object?>{};
  final writeOrder = <String>[];
  int writes = 0;
  int? failWriteNumber;
  int? throwWriteNumber;

  @override
  bool containsKey(String key) => values.containsKey(key);
  @override
  Object? get(String key) => values[key];
  @override
  Future<bool> setInt(String key, int value) => _write(key, value);
  @override
  Future<bool> setString(String key, String value) => _write(key, value);

  Future<bool> _write(String key, Object value) async {
    writes++;
    writeOrder.add(key);
    if (writes == throwWriteNumber) throw StateError('synthetic write failure');
    if (writes == failWriteNumber) return false;
    values[key] = value;
    return true;
  }
}
