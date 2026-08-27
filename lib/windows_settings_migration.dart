import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'settings.pb.dart';

const windowsSettingsMigrationVersionKey =
    'buck_windows_settings_migration_version';
const windowsSettingsMigrationPermanentInvalidVersionKey =
    'buck_windows_settings_migration_permanent_invalid_version';
const windowsSettingsMigrationVersion = 1;
const maxLegacyJsonBytes = 1048576;
const maxEncodedSettingsBytes = 524288;
const maxDecodedSettingsBytes = 393216;

enum WindowsSettingsMigrationOutcome {
  nonWindows,
  alreadyComplete,
  noSource,
  success,
  permanentInvalid,
  transientFailure,
}

abstract interface class MigrationPreferences {
  bool containsKey(String key);
  Object? get(String key);
  Future<bool> setInt(String key, int value);
  Future<bool> setString(String key, String value);
}

class SharedPreferencesMigrationPreferences implements MigrationPreferences {
  SharedPreferencesMigrationPreferences(this._preferences);
  final SharedPreferences _preferences;

  @override
  bool containsKey(String key) => _preferences.containsKey(key);
  @override
  Object? get(String key) => _preferences.get(key);
  @override
  Future<bool> setInt(String key, int value) => _preferences.setInt(key, value);
  @override
  Future<bool> setString(String key, String value) =>
      _preferences.setString(key, value);
}

enum LegacySourceState { missing, valid, rejected, reparseRejected }

class LegacySourceRead {
  const LegacySourceRead(this.state, [this.bytes]);
  final LegacySourceState state;
  final List<int>? bytes;
}

abstract interface class LegacySettingsSource {
  Future<LegacySourceRead> read();
}

class WindowsLegacySettingsSource implements LegacySettingsSource {
  WindowsLegacySettingsSource(
    this.appData, {
    Future<FileSystemEntityType> Function(String path, {bool followLinks})?
        entityType,
    Future<List<int>> Function(String path)? readBytes,
  })  : _entityType = entityType ?? FileSystemEntity.type,
        _readBytes = readBytes ?? _readFileBytes;
  final String appData;
  final Future<FileSystemEntityType> Function(String path, {bool followLinks})
      _entityType;
  final Future<List<int>> Function(String path) _readBytes;

  @override
  Future<LegacySourceRead> read() async {
    final namespace = Directory(p.join(appData, 'me.hanh'));
    final legacyDirectory = Directory(p.join(namespace.path, 'BUCK Wallet'));
    final source =
        File(p.join(legacyDirectory.path, 'shared_preferences.json'));
    final components = <(String, FileSystemEntityType)>[
      (namespace.path, FileSystemEntityType.directory),
      (legacyDirectory.path, FileSystemEntityType.directory),
      (source.path, FileSystemEntityType.file),
    ];
    for (final component in components) {
      final type = await _entityType(component.$1, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return const LegacySourceRead(LegacySourceState.missing);
      }
      if (type == FileSystemEntityType.link) {
        return const LegacySourceRead(LegacySourceState.reparseRejected);
      }
      if (type != component.$2) {
        return const LegacySourceRead(LegacySourceState.rejected);
      }
    }
    final resolvedAppData = await Directory(appData).resolveSymbolicLinks();
    final resolvedDirectory = await legacyDirectory.resolveSymbolicLinks();
    final resolvedSource = await source.resolveSymbolicLinks();
    final expectedDirectory = p.join(resolvedAppData, 'me.hanh', 'BUCK Wallet');
    final expectedSource = p.join(expectedDirectory, 'shared_preferences.json');
    if (!p.equals(resolvedDirectory, expectedDirectory) ||
        !p.equals(resolvedSource, expectedSource) ||
        !p.equals(p.dirname(resolvedSource), resolvedDirectory)) {
      return const LegacySourceRead(LegacySourceState.rejected);
    }
    final stat = await source.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size > maxLegacyJsonBytes) {
      return const LegacySourceRead(LegacySourceState.rejected);
    }
    final bytes = await _readBytes(source.path);
    if (bytes.length > maxLegacyJsonBytes) {
      return const LegacySourceRead(LegacySourceState.rejected);
    }
    return LegacySourceRead(LegacySourceState.valid, bytes);
  }
}

Future<List<int>> _readFileBytes(String path) => File(path).readAsBytes();

typedef MigrationLog = void Function(String message);

class WindowsSettingsMigrator {
  WindowsSettingsMigrator({
    required this.isWindows,
    required this.preferences,
    required this.source,
    required this.validCoinIds,
    this.supportedCurrencies = const <String>{},
    this.log = _discardLog,
  });
  final bool isWindows;
  final MigrationPreferences preferences;
  final LegacySettingsSource source;
  final Set<int> validCoinIds;
  final Set<String> supportedCurrencies;
  final MigrationLog log;

  Future<WindowsSettingsMigrationOutcome> migrate() async {
    try {
      return await _migrate();
    } catch (_) {
      log('windows settings migration v1 category=transient-unexpected');
      return WindowsSettingsMigrationOutcome.transientFailure;
    }
  }

  Future<WindowsSettingsMigrationOutcome> _migrate() async {
    if (!isWindows) return WindowsSettingsMigrationOutcome.nonWindows;
    if (_isVersionOne(windowsSettingsMigrationVersionKey) ||
        _isVersionOne(windowsSettingsMigrationPermanentInvalidVersionKey)) {
      log('windows settings migration v1 skipped marker=terminal');
      return WindowsSettingsMigrationOutcome.alreadyComplete;
    }
    LegacySourceRead input;
    try {
      input = await source.read();
    } on FileSystemException {
      log('windows settings migration v1 source=YES category=transient-io');
      return WindowsSettingsMigrationOutcome.transientFailure;
    } catch (_) {
      log('windows settings migration v1 source=YES category=transient');
      return WindowsSettingsMigrationOutcome.transientFailure;
    }
    if (input.state == LegacySourceState.missing) {
      log('windows settings migration v1 source=NO category=no-source');
      return await _writeSuccessMarker()
          ? WindowsSettingsMigrationOutcome.noSource
          : WindowsSettingsMigrationOutcome.transientFailure;
    }
    if (input.state == LegacySourceState.rejected) {
      return _markPermanentInvalid('source-validation');
    }
    if (input.state == LegacySourceState.reparseRejected) {
      return _markPermanentInvalid('legacy-path-reparse-rejected');
    }
    Map<String, dynamic> legacy;
    try {
      final value =
          jsonDecode(utf8.decode(input.bytes!, allowMalformed: false));
      if (value is! Map<String, dynamic>) {
        return _markPermanentInvalid('json-top-level');
      }
      legacy = value;
    } catch (_) {
      return _markPermanentInvalid('json-parse');
    }
    AppSettings? migratedSettings;
    List<String> importedSettingsFields = const [];
    if (!preferences.containsKey('settings') &&
        legacy.containsKey('settings')) {
      final parsed = _parseSettings(legacy['settings']);
      if (parsed == null) return _markPermanentInvalid('settings-parse');
      migratedSettings = parsed.settings;
      importedSettingsFields = parsed.fields;
    }
    int? migratedCoin;
    if (!preferences.containsKey('coin') && legacy.containsKey('coin')) {
      final coin = legacy['coin'];
      if (coin is int && validCoinIds.contains(coin)) migratedCoin = coin;
    }
    try {
      if (migratedSettings != null) {
        final encoded = base64Encode(migratedSettings.writeToBuffer());
        if (!await preferences.setString('settings', encoded)) {
          throw const _PreferenceWriteFailure();
        }
      }
      if (migratedCoin != null &&
          !await preferences.setInt('coin', migratedCoin)) {
        throw const _PreferenceWriteFailure();
      }
      if (!await _writeSuccessMarker()) throw const _PreferenceWriteFailure();
    } catch (_) {
      log('windows settings migration v1 category=transient-write');
      return WindowsSettingsMigrationOutcome.transientFailure;
    }
    final names = <String>[
      ...importedSettingsFields,
      if (migratedCoin != null) 'coin',
    ];
    log('windows settings migration v1 category=success '
        'imported=${names.length} fields=${names.join(',')}');
    return WindowsSettingsMigrationOutcome.success;
  }

  bool _isVersionOne(String key) {
    final marker = preferences.get(key);
    return marker is int && marker == windowsSettingsMigrationVersion;
  }

  Future<bool> _writeSuccessMarker() => preferences.setInt(
        windowsSettingsMigrationVersionKey,
        windowsSettingsMigrationVersion,
      );

  Future<WindowsSettingsMigrationOutcome> _markPermanentInvalid(
      String category) async {
    log('windows settings migration v1 source=YES '
        'category=permanent-invalid class=$category');
    try {
      final written = await preferences.setInt(
        windowsSettingsMigrationPermanentInvalidVersionKey,
        windowsSettingsMigrationVersion,
      );
      if (!written) return WindowsSettingsMigrationOutcome.transientFailure;
    } catch (_) {}
    return preferences
                .get(windowsSettingsMigrationPermanentInvalidVersionKey) ==
            windowsSettingsMigrationVersion
        ? WindowsSettingsMigrationOutcome.permanentInvalid
        : WindowsSettingsMigrationOutcome.transientFailure;
  }

  _ParsedSettings? _parseSettings(Object? encodedValue) {
    if (encodedValue is! String ||
        utf8.encode(encodedValue).length > maxEncodedSettingsBytes ||
        !_strictBase64.hasMatch(encodedValue)) return null;
    late final List<int> bytes;
    try {
      bytes = base64Decode(encodedValue);
    } catch (_) {
      return null;
    }
    if (bytes.length > maxDecodedSettingsBytes) return null;
    late final AppSettings legacy;
    try {
      legacy = AppSettings.fromBuffer(bytes);
    } catch (_) {
      return null;
    }
    final current = AppSettings();
    final fields = <String>[];
    if (legacy.hasConfirmations() && legacy.confirmations >= 1) {
      current.confirmations = legacy.confirmations;
      fields.add('confirmations');
    }
    if (legacy.hasNogetTx()) {
      current.nogetTx = legacy.nogetTx;
      fields.add('nogetTx');
    }
    if (legacy.hasRowsPerPage() &&
        (legacy.rowsPerPage == 10 || legacy.rowsPerPage == 25)) {
      current.rowsPerPage = legacy.rowsPerPage;
      fields.add('rowsPerPage');
    }
    if (legacy.hasCurrency() && _validCurrency(legacy.currency)) {
      current.currency = legacy.currency;
      fields.add('currency');
    }
    _copyRanged(legacy.hasAutoHide(), legacy.autoHide, 0, 2,
        (value) => current.autoHide = value, 'autoHide', fields);
    _copyRanged(legacy.hasIncludeReplyTo(), legacy.includeReplyTo, 0, 1,
        (value) => current.includeReplyTo = value, 'includeReplyTo', fields);
    _copyRanged(legacy.hasMessageView(), legacy.messageView, 0, 2,
        (value) => current.messageView = value, 'messageView', fields);
    _copyRanged(legacy.hasNoteView(), legacy.noteView, 0, 2,
        (value) => current.noteView = value, 'noteView', fields);
    _copyRanged(legacy.hasTxView(), legacy.txView, 0, 2,
        (value) => current.txView = value, 'txView', fields);
    if (legacy.hasFullPrec()) {
      current.fullPrec = legacy.fullPrec;
      fields.add('fullPrec');
    }
    _copyRanged(legacy.hasMinPrivacyLevel(), legacy.minPrivacyLevel, 0, 3,
        (value) => current.minPrivacyLevel = value, 'minPrivacyLevel', fields);
    if (legacy.hasPalette() &&
        legacy.palette.hasName() &&
        legacy.palette.hasDark() &&
        utf8.encode(legacy.palette.name).length <= 64 &&
        _paletteNames.contains(legacy.palette.name)) {
      current.palette =
          ColorPalette(name: legacy.palette.name, dark: legacy.palette.dark);
      fields.add('palette');
    }
    if (legacy.hasCustomSend()) {
      current.customSend = legacy.customSend;
      fields.add('customSend');
    }
    if (legacy.hasCustomSendSettings()) {
      final child = _copyCustomSendSettings(legacy.customSendSettings);
      current.customSendSettings = child.settings;
      fields.addAll(child.fields);
    }
    _copyRanged(legacy.hasBackgroundSync(), legacy.backgroundSync, 0, 2,
        (value) => current.backgroundSync = value, 'backgroundSync', fields);
    if (legacy.hasLanguage() &&
        utf8.encode(legacy.language).length <= 256 &&
        _languages.contains(legacy.language)) {
      current.language = legacy.language;
      fields.add('language');
    }
    _applyCurrentDefaults(current);
    return _ParsedSettings(current, fields);
  }

  bool _validCurrency(String value) =>
      value.length <= 16 &&
      value.codeUnits.every((unit) => unit <= 0x7f) &&
      supportedCurrencies.contains(value);
}

class _ParsedSettings {
  const _ParsedSettings(this.settings, this.fields);
  final AppSettings settings;
  final List<String> fields;
}

class _ParsedCustomSendSettings {
  const _ParsedCustomSendSettings(this.settings, this.fields);
  final CustomSendSettings settings;
  final List<String> fields;
}

_ParsedCustomSendSettings _copyCustomSendSettings(CustomSendSettings legacy) {
  final current = CustomSendSettings();
  final fields = <String>[];
  void copy(bool present, bool value, void Function(bool) assign, String name) {
    if (!present) return;
    assign(value);
    fields.add('customSendSettings.$name');
  }

  copy(legacy.hasContacts(), legacy.contacts, (v) => current.contacts = v,
      'contacts');
  copy(legacy.hasAccounts(), legacy.accounts, (v) => current.accounts = v,
      'accounts');
  copy(legacy.hasPools(), legacy.pools, (v) => current.pools = v, 'pools');
  copy(legacy.hasAmountCurrency(), legacy.amountCurrency,
      (v) => current.amountCurrency = v, 'amountCurrency');
  copy(legacy.hasAmountSlider(), legacy.amountSlider,
      (v) => current.amountSlider = v, 'amountSlider');
  copy(legacy.hasMax(), legacy.max, (v) => current.max = v, 'max');
  copy(legacy.hasDeductFee(), legacy.deductFee, (v) => current.deductFee = v,
      'deductFee');
  copy(legacy.hasReplyAddress(), legacy.replyAddress,
      (v) => current.replyAddress = v, 'replyAddress');
  copy(legacy.hasMemoSubject(), legacy.memoSubject,
      (v) => current.memoSubject = v, 'memoSubject');
  copy(legacy.hasMemo(), legacy.memo, (v) => current.memo = v, 'memo');
  copy(legacy.hasRecipientPools(), legacy.recipientPools,
      (v) => current.recipientPools = v, 'recipientPools');
  return _ParsedCustomSendSettings(current, fields);
}

void _copyRanged(bool present, int value, int minimum, int maximum,
    void Function(int) assign, String name, List<String> fields) {
  if (!present || value < minimum || value > maximum) return;
  assign(value);
  fields.add(name);
}

final _strictBase64 = RegExp(
  r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
);
// Exact names from the pinned flex_color_scheme 7.3.1 FlexScheme enum.
const _paletteNames = <String>{
  'material',
  'materialHc',
  'blue',
  'indigo',
  'hippieBlue',
  'aquaBlue',
  'brandBlue',
  'deepBlue',
  'sakura',
  'mandyRed',
  'red',
  'redWine',
  'purpleBrown',
  'green',
  'money',
  'jungle',
  'greyLaw',
  'wasabi',
  'gold',
  'mango',
  'amber',
  'vesuviusBurn',
  'deepPurple',
  'ebonyClay',
  'barossa',
  'shark',
  'bigStone',
  'damask',
  'bahamaBlue',
  'mallardGreen',
  'espresso',
  'outerSpace',
  'blueWhale',
  'sanJuanBlue',
  'rosewood',
  'blumineBlue',
  'flutterDash',
  'materialBaseline',
  'verdunHemlock',
  'dellGenoa',
  'redM3',
  'pinkM3',
  'purpleM3',
  'indigoM3',
  'blueM3',
  'cyanM3',
  'tealM3',
  'greenM3',
  'limeM3',
  'yellowM3',
  'orangeM3',
  'deepOrangeM3',
  'custom',
};
const _languages = <String>{'en', 'es', 'pt', 'fr'};
void _discardLog(String _) {}

class _PreferenceWriteFailure implements Exception {
  const _PreferenceWriteFailure();
}

void _applyCurrentDefaults(AppSettings settings) {
  if (!settings.hasConfirmations()) settings.confirmations = 3;
  if (!settings.hasRowsPerPage()) settings.rowsPerPage = 10;
  if (!settings.hasDeveloperMode()) settings.developerMode = 5;
  if (!settings.hasCurrency()) settings.currency = 'USD';
  if (!settings.hasAutoHide()) settings.autoHide = 1;
  if (!settings.hasPalette()) {
    settings.palette = ColorPalette(name: 'mandyRed', dark: true);
  }
  if (!settings.hasNoteView()) settings.noteView = 2;
  if (!settings.hasTxView()) settings.txView = 2;
  if (!settings.hasMessageView()) settings.messageView = 2;
  if (!settings.hasCustomSendSettings()) {
    settings.customSendSettings = CustomSendSettings(
      contacts: true,
      accounts: true,
      pools: true,
      recipientPools: true,
      amountCurrency: true,
      amountSlider: true,
      max: true,
      deductFee: true,
      replyAddress: true,
      memoSubject: true,
      memo: true,
    );
  }
  if (!settings.hasBackgroundSync()) settings.backgroundSync = 1;
  if (!settings.hasLanguage()) settings.language = 'en';
}

Future<WindowsSettingsMigrationOutcome> migrateLegacyWindowsSettings({
  MigrationLog log = _discardLog,
}) async {
  if (!Platform.isWindows) return WindowsSettingsMigrationOutcome.nonWindows;
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty || !p.windows.isAbsolute(appData)) {
    log('windows settings migration v1 category=transient-environment');
    return WindowsSettingsMigrationOutcome.transientFailure;
  }
  final preferences = await SharedPreferences.getInstance();
  return WindowsSettingsMigrator(
    isWindows: true,
    preferences: SharedPreferencesMigrationPreferences(preferences),
    source: WindowsLegacySettingsSource(appData),
    validCoinIds: const {0},
    supportedCurrencies: const {},
    log: log,
  ).migrate();
}
