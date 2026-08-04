import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:get_it/get_it.dart';
import 'package:mobx/mobx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/server_coordinator.dart';
import 'package:warp_api/warp_api.dart';

import 'appsettings.dart';
import 'pages/utils.dart';
import 'accounts.dart';
import 'coin/coins.dart';
import 'generated/intl/messages.dart';
import 'failover_controller.dart';
import 'sync_lifecycle_coordinator.dart';
import 'runtime_server_transition.dart';

part 'store2.g.dart';
part 'store2.freezed.dart';

var appStore = AppStore();

class AppStore = _AppStore with _$AppStore;

abstract class _AppStore with Store {
  bool initialized = false;
  String dbPassword = '';

  @observable
  bool flat = false;
}

final syncProgressPort2 = ReceivePort();
final syncProgressStream = syncProgressPort2.asBroadcastStream();

void initSyncListener() {
  syncProgressStream.listen((e) {
    if (e is List<int>) {
      final token = syncLifecycleCoordinator.authoritativeToken;
      if (token == null) return;
      final progress = Progress(e);
      syncStatus2.setProgressOwned(token, progress);
      if (!syncLifecycleCoordinator.ownsAuthoritativeRun(token)) return;
      final b = progress.balances?.unpack();
      if (b != null) (token.account as ActiveAccount2).poolBalances = b;
      logger.d(progress.balances);
    }
  });
}

Future<void> startAutoSync() {
  syncLifecycleCoordinator.startAutomaticSync();
  return syncLifecycleCoordinator.requestSync(getTx: false, auto: true);
}

Future<void> setActiveAccount(int requestedCoin, int requestedAccountId) {
  return _runActiveAccountTransition(requestedCoin, requestedAccountId);
}

Future<void> activateNewAccount(
  int requestedCoin,
  int requestedAccountId, {
  required bool skipToLastHeight,
}) {
  return _runActiveAccountTransition(
    requestedCoin,
    requestedAccountId,
    beforePersistence:
        skipToLastHeight ? () => WarpApi.skipToLastHeight(requestedCoin) : null,
  );
}

Future<void> deleteActiveAccountAndInstallFallback(
  int deletedCoin,
  int deletedAccountId,
) {
  return _runActiveAccountTransition(
    0,
    0,
    beforePublish: () => WarpApi.deleteAccount(
      deletedCoin,
      deletedAccountId,
    ),
  );
}

Future<void> _runActiveAccountTransition(
  int requestedCoin,
  int requestedAccountId, {
  FutureOr<void> Function()? beforePersistence,
  FutureOr<void> Function()? beforePublish,
}) {
  return syncLifecycleCoordinator.runAccountTransition<void>(() async {
    final nextSettings = CoinSettingsExtension.load(requestedCoin);
    final nextAccount = ActiveAccount2.fromId(
      requestedCoin,
      requestedAccountId,
    );

    // Complete all fallible initialization and exact-selection persistence
    // before publishing either global.
    nextAccount.updatePrepared(null, nextSettings.uaType);
    await beforePersistence?.call();
    nextSettings.account = requestedAccountId;
    nextSettings.save(requestedCoin);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('coin', requestedCoin);
    await prefs.setInt('account', requestedAccountId);
    await beforePublish?.call();

    coinSettings = nextSettings;
    aa = nextAccount;
    syncStatus2.resetForAccount(requestedCoin);
    aaSequence.seqno = DateTime.now().microsecondsSinceEpoch;
  });
}

var syncStatus2 = SyncStatus2();

class SyncStatus2 = _SyncStatus2 with _$SyncStatus2;

abstract class _SyncStatus2 with Store {
  int startSyncedHeight = 0;
  bool isRescan = false;
  ETA eta = ETA();

  @observable
  bool connected = true;

  @observable
  int syncedHeight = 0;

  @observable
  int? latestHeight;

  @observable
  DateTime? timestamp;

  @observable
  bool syncing = false;

  @observable
  bool paused = false;

  @observable
  int downloadedSize = 0;

  @observable
  int trialDecryptionCount = 0;

  @computed
  int get changed {
    connected;
    syncedHeight;
    latestHeight;
    syncing;
    paused;
    return DateTime.now().microsecondsSinceEpoch;
  }

  bool get isSynced {
    final sh = syncedHeight;
    final lh = latestHeight;
    return lh != null && sh >= lh;
  }

  int? get confirmHeight {
    final lh = latestHeight;
    if (lh == null) return null;
    final ch = lh - appSettings.anchorOffset;
    return max(ch, 0);
  }

  @action
  void reset() {
    isRescan = false;
    syncedHeight = WarpApi.getDbHeight(aa.coin).height;
    syncing = false;
    paused = false;
  }

  @action
  void resetForAccount(int coin) {
    connected = true;
    latestHeight = null;
    final height = WarpApi.getDbHeight(coin);
    syncedHeight = height.height;
    timestamp = height.timestamp == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(height.timestamp * 1000);
    syncing = false;
    paused = false;
    isRescan = false;
    startSyncedHeight = syncedHeight;
    eta.end();
    downloadedSize = 0;
    trialDecryptionCount = 0;
  }

  @action
  void resetForServer() {
    connected = false;
    latestHeight = null;
    syncing = false;
    isRescan = false;
    startSyncedHeight = syncedHeight;
    eta.end();
    downloadedSize = 0;
    trialDecryptionCount = 0;
    // `paused` has no source/reason metadata, so preserve it as the safest
    // approximation of an explicit user pause.
  }

  @action
  Future<void> update() async {
    final token = syncLifecycleCoordinator.currentToken;
    final account = token.account as ActiveAccount2;
    await _updateOwned(token, account);
  }

  Future<void> _updateOwned(
    SyncLifecycleToken token,
    ActiveAccount2 account,
  ) async {
    try {
      final lh = latestHeight;
      final newLatestHeight = await WarpApi.getLatestHeight(token.coin);
      if (!syncLifecycleCoordinator.owns(token)) return;
      latestHeight = newLatestHeight;
      if (lh == null) {
        account.update(newLatestHeight);
      }
      if (!syncLifecycleCoordinator.owns(token)) return;
      connected = true;
    } on String catch (e) {
      logger.d(e);
      if (!syncLifecycleCoordinator.owns(token)) return;
      connected = false;
    }
    if (!syncLifecycleCoordinator.owns(token)) return;
    syncedHeight = WarpApi.getDbHeight(token.coin).height;
  }

  @action
  Future<void> sync(bool rescan, {bool auto = false}) {
    return syncLifecycleCoordinator.requestSync(getTx: rescan, auto: auto);
  }

  Future<void> syncOwned(
    SyncLifecycleToken token, {
    required bool rescan,
    required bool auto,
  }) async {
    final account = token.account as ActiveAccount2;
    logger.d('R/A/P/S $rescan $auto $paused $syncing');
    if (paused) return;
    try {
      await _updateOwned(token, account);
      if (!syncLifecycleCoordinator.ownsAuthoritativeRun(token)) return;
      final lh = latestHeight;
      if (lh == null) return;
      // don't auto sync more than 1 month of data
      if (!rescan && auto && lh - syncedHeight > 30 * 24 * 60 * 4 / 5) {
        if (!syncLifecycleCoordinator.ownsAuthoritativeRun(token)) return;
        paused = true;
        return;
      }
      if (isSynced) return;
      if (!syncLifecycleCoordinator.ownsAuthoritativeRun(token)) return;
      syncing = true;
      isRescan = rescan;
      _updateSyncedHeight(token);
      startSyncedHeight = syncedHeight;
      eta.begin(latestHeight!);
      eta.checkpoint(syncedHeight, DateTime.now());

      final preBalance = AccountBalanceSnapshot(
          coin: token.coin,
          id: token.accountId,
          balance: account.poolBalances.total);
      // This may take a long time
      await WarpApi.warpSync(
          token.coin,
          token.accountId,
          !appSettings.nogetTx,
          appSettings.anchorOffset,
          coinSettings.spamFilter ? 50 : 1000000,
          syncProgressPort2.sendPort.nativePort);

      if (!syncLifecycleCoordinator.ownsAuthoritativeRun(token)) return;
      account.update(latestHeight);
      if (!syncLifecycleCoordinator.ownsAuthoritativeRun(token)) return;
      contacts.fetchContacts();
      if (!syncLifecycleCoordinator.ownsAuthoritativeRun(token)) return;
      marketPrice.update();
      if (!syncLifecycleCoordinator.ownsAuthoritativeRun(token)) return;
      final postBalance = AccountBalanceSnapshot(
          coin: token.coin,
          id: token.accountId,
          balance: account.poolBalances.total);
      if (preBalance.sameAccount(postBalance) &&
          preBalance.balance != postBalance.balance) {
        final s = GetIt.I.get<S>();
        final ticker = coins[token.coin].ticker;
        if (preBalance.balance < postBalance.balance) {
          final amount =
              amountToString2(postBalance.balance - preBalance.balance);
          showLocalNotification(
            id: latestHeight!,
            title: s.incomingFunds,
            body: s.received(amount, ticker),
          );
        } else {
          final amount =
              amountToString2(preBalance.balance - postBalance.balance);
          showLocalNotification(
            id: latestHeight!,
            title: s.paymentMade,
            body: s.spent(amount, ticker),
          );
        }
      }
    } on String catch (e) {
      logger.d(e);
      if (syncLifecycleCoordinator.ownsAuthoritativeRun(token)) showSnackBar(e);
    } finally {
      if (syncLifecycleCoordinator.ownsAuthoritativeRun(token)) {
        syncing = false;
        eta.end();
      }
    }
  }

  @action
  Future<void> rescan(int height) async {
    WarpApi.rescanFrom(aa.coin, height);
    _updateSyncedHeight();
    paused = false;
    await sync(true);
  }

  @action
  void setPause(bool v) {
    paused = v;
  }

  @action
  void setProgress(Progress progress) {
    final token = syncLifecycleCoordinator.authoritativeToken;
    if (token == null) return;
    setProgressOwned(token, progress);
  }

  void setProgressOwned(SyncLifecycleToken token, Progress progress) {
    if (!syncLifecycleCoordinator.ownsAuthoritativeRun(token)) return;
    trialDecryptionCount = progress.trialDecryptions;
    syncedHeight = progress.height;
    downloadedSize = progress.downloaded;
    if (progress.timestamp > 0)
      timestamp =
          DateTime.fromMillisecondsSinceEpoch(progress.timestamp * 1000);
    eta.checkpoint(syncedHeight, DateTime.now());
  }

  void _updateSyncedHeight([SyncLifecycleToken? ownedToken]) {
    final token = ownedToken ?? syncLifecycleCoordinator.currentToken;
    if (!syncLifecycleCoordinator.owns(token)) return;
    final h = WarpApi.getDbHeight(token.coin);
    if (!syncLifecycleCoordinator.owns(token)) return;
    syncedHeight = h.height;
    timestamp = (h.timestamp != 0)
        ? DateTime.fromMillisecondsSinceEpoch(h.timestamp * 1000)
        : null;
  }
}

final SyncLifecycleCoordinator syncLifecycleCoordinator =
    SyncLifecycleCoordinator(
  accountProvider: () => SyncLifecycleAccount(
    coin: aa.coin,
    accountId: aa.id,
    account: aa,
  ),
  sync: (token, {required getTx, required auto}) => syncStatus2.syncOwned(
    token,
    rescan: getTx,
    auto: auto,
  ),
  cancel: WarpApi.cancelSync,
  automaticRefresh: (token) => _handleAutomaticSyncSuccess(token),
  automaticError: (error, stackTrace) {
    failoverController.observeRuntimeSyncFailure();
    unawaited(_refreshFailoverHealth());
    logger.e(
      'Automatic synchronization failed',
      error: error,
      stackTrace: stackTrace,
    );
  },
);

final RuntimeServerTransition runtimeServerTransition = RuntimeServerTransition(
  lifecycle: syncLifecycleCoordinator,
  probeServer: WarpApi.probeServer,
  updateLwd: WarpApi.updateLWD,
  getLwd: WarpApi.getLWD,
  commitSettings: (coin, url) {
    final matchingIndex = coins[coin].lwd.indexWhere(
      (server) {
        try {
          return normalizeLightwalletUrl(server.url) ==
              normalizeLightwalletUrl(url);
        } catch (_) {
          return false;
        }
      },
    );
    coinSettings.lwd.index = matchingIndex;
    coinSettings.lwd.customURL = matchingIndex < 0 ? url : '';
    coinSettings.save(coin);
  },
  resetState: syncStatus2.resetForServer,
);

final ServerCoordinator serverCoordinator = ServerCoordinator();
final Stopwatch _failoverClock = Stopwatch()..start();
final FailoverController failoverController = FailoverController(
  serverCoordinator: serverCoordinator,
  runtimeServerTransition: runtimeServerTransition,
  monotonicClock: () => _failoverClock.elapsed,
);

void _handleAutomaticSyncSuccess(SyncLifecycleToken token) {
  (token.account as ActiveAccount2).updateDivisified();
  failoverController.observeRuntimeSyncSuccess();
  unawaited(_refreshFailoverHealth());
}

Future<void> _refreshFailoverHealth() async {
  try {
    await serverCoordinator.refresh();
    final token = syncLifecycleCoordinator.currentToken;
    await failoverController.observeProbeResults(
      coin: token.coin,
      activeUrl: WarpApi.getLWD(token.coin),
    );
  } catch (error, stackTrace) {
    logger.e(
      'Automatic failover health refresh failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

Future<ServerTransitionResult> switchServer({
  required int coin,
  required String targetUrl,
}) =>
    runtimeServerTransition.switchServer(coin: coin, targetUrl: targetUrl);

class ETA {
  int endHeight = 0;
  ETACheckpoint? start;
  ETACheckpoint? prev;
  ETACheckpoint? current;

  void begin(int height) {
    end();
    endHeight = height;
  }

  void end() {
    start = null;
    prev = null;
    current = null;
  }

  void checkpoint(int height, DateTime timestamp) {
    prev = current;
    current = ETACheckpoint(height, timestamp);
    if (start == null) start = current;
  }

  @computed
  int? get remaining {
    return current?.let((c) => endHeight - c.height);
  }

  @computed
  String get timeRemaining {
    final defaultMsg = "Calculating ETA";
    final p = prev;
    final c = current;
    if (p == null || c == null) return defaultMsg;
    if (c.timestamp.millisecondsSinceEpoch ==
        p.timestamp.millisecondsSinceEpoch) return defaultMsg;
    final speed = (c.height - p.height) /
        (c.timestamp.millisecondsSinceEpoch -
            p.timestamp.millisecondsSinceEpoch);
    if (speed == 0) return defaultMsg;
    final eta = (endHeight - c.height) / speed;
    if (eta <= 0) return defaultMsg;
    final duration =
        Duration(milliseconds: eta.floor()).toString().split('.')[0];
    return "ETA: $duration";
  }

  @computed
  bool get running => start != null;

  @computed
  int? get progress {
    if (!running) return null;
    final sh = start!.height;
    final ch = current!.height;
    final total = endHeight - sh;
    final percent = total > 0 ? 100 * (ch - sh) ~/ total : 0;
    return percent;
  }
}

class ETACheckpoint {
  int height;
  DateTime timestamp;

  ETACheckpoint(this.height, this.timestamp);
}

var marketPrice = MarketPrice();

class MarketPrice = _MarketPrice with _$MarketPrice;

abstract class _MarketPrice with Store {
  @observable
  double? price;

  @action
  Future<void> update() async {
    final c = coins[aa.coin];
    price = await getFxRate(c.currency, appSettings.currency);
  }

  int? lastChartUpdateTime;
}

var contacts = ContactStore();

class ContactStore = _ContactStore with _$ContactStore;

abstract class _ContactStore with Store {
  @observable
  ObservableList<Contact> contacts = ObservableList<Contact>.of([]);

  @action
  void fetchContacts() {
    contacts.clear();
    contacts.addAll(WarpApi.getContacts(aa.coin));
  }

  @action
  void add(Contact c) {
    WarpApi.storeContact(aa.coin, c.id, c.name!, c.address!, true);
    markContactsSaved(aa.coin, false);
    fetchContacts();
  }

  @action
  void remove(Contact c) {
    contacts.removeWhere((contact) => contact.id == c.id);
    WarpApi.storeContact(aa.coin, c.id, c.name!, "", true);
    markContactsSaved(aa.coin, false);
    fetchContacts();
  }

  @action
  markContactsSaved(int coin, bool v) {
    coinSettings.contactsSaved = true;
    coinSettings.save(coin);
  }
}

class AccountBalanceSnapshot {
  final int coin;
  final int id;
  final int balance;
  AccountBalanceSnapshot({
    required this.coin,
    required this.id,
    required this.balance,
  });

  bool sameAccount(AccountBalanceSnapshot other) =>
      coin == other.coin && id == other.id;

  @override
  String toString() => '($coin, $id, $balance)';
}

@freezed
class SeedInfo with _$SeedInfo {
  const factory SeedInfo({
    required String seed,
    required int index,
  }) = _SeedInfo;
}

@freezed
class TxMemo with _$TxMemo {
  const factory TxMemo({
    required String address,
    required String memo,
  }) = _TxMemo;
}

@freezed
class SwapAmount with _$SwapAmount {
  const factory SwapAmount({
    required String amount,
    required String currency,
  }) = _SwapAmount;
}

@freezed
class SwapQuote with _$SwapQuote {
  const factory SwapQuote({
    required String estimated_amount,
    required String rate_id,
    required String valid_until,
  }) = _SwapQuote;

  factory SwapQuote.fromJson(Map<String, dynamic> json) =>
      _$SwapQuoteFromJson(json);
}

@freezed
class SwapRequest with _$SwapRequest {
  const factory SwapRequest({
    required bool fixed,
    required String rate_id,
    required String currency_from,
    required String currency_to,
    required double amount_from,
    required String address_to,
  }) = _SwapRequest;

  factory SwapRequest.fromJson(Map<String, dynamic> json) =>
      _$SwapRequestFromJson(json);
}

@freezed
class SwapLeg with _$SwapLeg {
  const factory SwapLeg({
    required String symbol,
    required String name,
    required String image,
    required String validation_address,
    required String address_explorer,
    required String tx_explorer,
  }) = _SwapLeg;

  factory SwapLeg.fromJson(Map<String, dynamic> json) =>
      _$SwapLegFromJson(json);
}

@freezed
class SwapResponse with _$SwapResponse {
  const factory SwapResponse({
    required String id,
    required String timestamp,
    required String currency_from,
    required String currency_to,
    required String amount_from,
    required String amount_to,
    required String address_from,
    required String address_to,
  }) = _SwapResponse;

  factory SwapResponse.fromJson(Map<String, dynamic> json) =>
      _$SwapResponseFromJson(json);
}

@freezed
class Election with _$Election {
  const factory Election({
    required int id,
    required String name,
    required int start_height,
    required int end_height,
    required int close_height,
    required String submit_url,
    required String question,
    required List<String> candidates,
    required String status,
  }) = _Election;

  factory Election.fromJson(Map<String, dynamic> json) =>
      _$ElectionFromJson(json);
}

@freezed
class Vote with _$Vote {
  const factory Vote({
    required Election election,
    required List<VoteNoteT> notes,
    int? candidate,
  }) = _Vote;
}
