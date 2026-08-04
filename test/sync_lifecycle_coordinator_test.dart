import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:YWallet/sync_lifecycle_coordinator.dart';

class FakeAccount {
  final int coin;
  final int id;
  int refreshes = 0;

  FakeAccount(this.coin, this.id);
}

class FakeTimer implements SyncLifecycleTimer {
  final void Function() callback;
  bool cancelled = false;

  FakeTimer(this.callback);

  void tick() {
    if (!cancelled) callback();
  }

  @override
  void cancel() => cancelled = true;
}

void main() {
  late FakeAccount account;
  late List<FakeTimer> timers;
  late List<Completer<void>> runs;
  late int syncCalls;
  late int cancelCalls;
  late List<Object> automaticErrors;
  late SyncLifecycleCoordinator coordinator;

  setUp(() {
    account = FakeAccount(0, 7);
    timers = [];
    runs = [];
    syncCalls = 0;
    cancelCalls = 0;
    automaticErrors = [];
    coordinator = SyncLifecycleCoordinator(
      accountProvider: () => SyncLifecycleAccount(
        coin: account.coin,
        accountId: account.id,
        account: account,
      ),
      sync: (token, {required getTx, required auto}) {
        syncCalls++;
        final run = Completer<void>();
        runs.add(run);
        return run.future;
      },
      cancel: () => cancelCalls++,
      timerFactory: (interval, callback) {
        expect(interval, SyncLifecycleCoordinator.automaticSyncInterval);
        final timer = FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
      automaticRefresh: (token) {
        (token.account as FakeAccount).refreshes++;
      },
      automaticError: (error, stackTrace) => automaticErrors.add(error),
    );
  });

  test('initial state has a deterministic token and no owners', () {
    expect(coordinator.currentToken.generation, 0);
    expect(coordinator.currentToken.coin, 0);
    expect(coordinator.currentToken.accountId, 7);
    expect(coordinator.inFlight, isNull);
    expect(coordinator.hasAutomaticTimer, isFalse);
  });

  test('claims synchronously and concurrent requests share exact future', () {
    late bool ownedInsideSync;
    coordinator = SyncLifecycleCoordinator(
      accountProvider: () => SyncLifecycleAccount(
        coin: account.coin,
        accountId: account.id,
        account: account,
      ),
      sync: (token, {required getTx, required auto}) {
        syncCalls++;
        ownedInsideSync = coordinator.ownsAuthoritativeRun(token);
        final run = Completer<void>();
        runs.add(run);
        return run.future;
      },
      cancel: () => cancelCalls++,
    );

    final first = coordinator.requestSync(getTx: false, auto: false);
    final second = coordinator.requestSync(getTx: false, auto: true);

    expect(ownedInsideSync, isTrue);
    expect(identical(first, second), isTrue);
    expect(syncCalls, 1);
  });

  test('timer and manual collision submit once and timer starts once', () {
    coordinator.startAutomaticSync();
    coordinator.startAutomaticSync();
    expect(timers, hasLength(1));

    timers.single.tick();
    final manual = coordinator.requestSync(getTx: false, auto: false);
    expect(identical(manual, coordinator.inFlight), isTrue);
    expect(syncCalls, 1);
  });

  test('completion clears its slot and permits a later operation', () async {
    final first = coordinator.requestSync(getTx: false, auto: false);
    runs[0].complete();
    await first;
    expect(coordinator.inFlight, isNull);

    coordinator.requestSync(getTx: false, auto: false);
    expect(syncCalls, 2);
  });

  test('failure is observable, clears ownership, and permits retry', () async {
    final first = coordinator.requestSync(getTx: false, auto: false);
    runs[0].completeError(StateError('failed'));
    await expectLater(first, throwsStateError);
    expect(coordinator.inFlight, isNull);

    coordinator.requestSync(getTx: false, auto: false);
    expect(syncCalls, 2);
  });

  test('synchronous failure and its stack trace are preserved', () async {
    final failure = StateError('synchronous failure');
    late StackTrace thrownAt;
    coordinator = SyncLifecycleCoordinator(
      accountProvider: () => SyncLifecycleAccount(
        coin: account.coin,
        accountId: account.id,
        account: account,
      ),
      sync: (token, {required getTx, required auto}) {
        try {
          throw failure;
        } catch (_, stackTrace) {
          thrownAt = stackTrace;
          rethrow;
        }
      },
      cancel: () => cancelCalls++,
    );

    final future = coordinator.requestSync(getTx: false, auto: false);
    Object? received;
    StackTrace? receivedStack;
    await future.catchError((Object error, StackTrace stackTrace) {
      received = error;
      receivedStack = stackTrace;
    });
    expect(received, same(failure));
    expect(receivedStack.toString(), thrownAt.toString());
    expect(coordinator.inFlight, isNull);
  });

  test('cancellation invalidates immediately, calls once, and awaits run',
      () async {
    final oldToken = coordinator.currentToken;
    coordinator.requestSync(getTx: false, auto: false);
    var cancellationFinished = false;

    final firstCancel = coordinator.cancelAndAwaitCurrent().then((_) {
      cancellationFinished = true;
    });
    final secondCancel = coordinator.cancelAndAwaitCurrent();

    expect(coordinator.currentToken.generation, 1);
    expect(coordinator.owns(oldToken), isFalse);
    expect(cancelCalls, 1);
    await Future<void>.delayed(Duration.zero);
    expect(cancellationFinished, isFalse);
    runs[0].complete();
    await Future.wait([firstCancel, secondCancel]);
    expect(cancellationFinished, isTrue);
  });

  test('concurrent cancellation callers share the exact transition', () async {
    coordinator.requestSync(getTx: false, auto: false);
    final first = coordinator.cancelAndAwaitCurrent();
    final second = coordinator.cancelAndAwaitCurrent();

    expect(identical(first, second), isTrue);
    expect(coordinator.currentToken.generation, 1);
    expect(cancelCalls, 1);
    runs.single.complete();
    await first;
  });

  test('invalid token callbacks are rejected and later generation runs',
      () async {
    final oldToken = coordinator.currentToken;
    coordinator.requestSync(getTx: false, auto: false);
    final cancelling = coordinator.cancelAndAwaitCurrent();
    expect(coordinator.ownsAuthoritativeRun(oldToken), isFalse);

    runs[0].complete();
    await cancelling;
    coordinator.requestSync(getTx: false, auto: false);
    expect(syncCalls, 2);
    expect(coordinator.ownsAuthoritativeRun(oldToken), isFalse);
  });

  test('captured account differs from replacement and is not retargeted',
      () async {
    final original = account;
    coordinator.startAutomaticSync();
    timers.single.tick();
    expect(original.refreshes, 0);

    account = FakeAccount(1, 9);
    final cancelling = coordinator.cancelAndAwaitCurrent();
    expect(coordinator.currentToken.account, same(account));
    expect(coordinator.currentToken.account, isNot(same(original)));
    runs[0].complete();
    await cancelling;

    await Future<void>.delayed(Duration.zero);
    expect(original.refreshes, 0);
    expect(account.refreshes, 0);
  });

  test('timer stop cancels the only timer and prevents later ticks', () {
    coordinator.startAutomaticSync();
    final timer = timers.single;
    coordinator.stopAutomaticSync();
    coordinator.stopAutomaticSync();

    expect(timer.cancelled, isTrue);
    expect(coordinator.hasAutomaticTimer, isFalse);
    timer.tick();
    expect(syncCalls, 0);
  });

  test('invalid generation blocks delayed diversified refresh', () async {
    coordinator.startAutomaticSync();
    final oldToken = coordinator.currentToken;
    coordinator.requestSync(getTx: false, auto: false);
    final cancelling = coordinator.cancelAndAwaitCurrent();
    expect(coordinator.owns(oldToken), isFalse);
    expect(oldToken.account, same(account));
    expect(account.refreshes, 0);
    runs[0].complete();
    await cancelling;
  });

  test('successful timer run refreshes only its captured account', () async {
    final original = account;
    coordinator.startAutomaticSync();
    timers.single.tick();
    expect(original.refreshes, 0);

    runs.single.complete();
    await coordinator.inFlight;
    await Future<void>.delayed(Duration.zero);
    expect(original.refreshes, 1);
  });

  test('timer failure is handled and does not refresh', () async {
    coordinator.startAutomaticSync();
    timers.single.tick();
    final failure = StateError('timer failure');
    runs.single.completeError(failure);

    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(automaticErrors, [same(failure)]);
    expect(account.refreshes, 0);
    expect(coordinator.inFlight, isNull);
  });

  test('paused-style no-op still coalesces synchronous submissions', () async {
    syncCalls = 0;
    coordinator = SyncLifecycleCoordinator(
      accountProvider: () => SyncLifecycleAccount(
        coin: account.coin,
        accountId: account.id,
        account: account,
      ),
      sync: (token, {required getTx, required auto}) async {
        syncCalls++;
      },
      cancel: () => cancelCalls++,
    );

    final first = coordinator.requestSync(getTx: false, auto: true);
    final second = coordinator.requestSync(getTx: false, auto: false);
    expect(identical(first, second), isTrue);
    await first;
    expect(syncCalls, 1);
  });

  test('cancellation without a run is safe and explicitly invalidates',
      () async {
    await coordinator.cancelAndAwaitCurrent();
    expect(coordinator.currentToken.generation, 1);
    expect(cancelCalls, 0);
  });

  test('account mutation waits for cancellation and invalidates immediately',
      () async {
    final oldToken = coordinator.currentToken;
    coordinator.requestSync(getTx: false, auto: false);
    var mutations = 0;

    final transition = coordinator.runAccountTransition<void>(() {
      mutations++;
      account = FakeAccount(1, 9);
    });

    expect(coordinator.owns(oldToken), isFalse);
    expect(coordinator.isTransitioning, isTrue);
    expect(cancelCalls, 1);
    expect(mutations, 0);
    runs.first.complete();
    await transition;
    expect(mutations, 1);
    expect(coordinator.currentToken.coin, 1);
    expect(coordinator.currentToken.accountId, 9);
    expect(coordinator.currentToken.account, same(account));
  });

  test('timer and manual requests submit no sync during transition', () async {
    coordinator.startAutomaticSync();
    final mutation = Completer<void>();
    final transition = coordinator.runAccountTransition<void>(() async {
      await mutation.future;
      account = FakeAccount(1, 9);
    });
    await Future<void>.delayed(Duration.zero);

    timers.single.tick();
    await coordinator.requestSync(getTx: false, auto: false);
    expect(syncCalls, 0);
    mutation.complete();
    await transition;
    expect(syncCalls, 1);
    expect(timers, hasLength(1));
  });

  test('FIFO transitions preserve both selections and persist exact requests',
      () async {
    final gate = Completer<void>();
    final installed = <int>[];
    final persisted = <int>[];
    final first = coordinator.runAccountTransition<void>(() async {
      await gate.future;
      persisted.add(8);
      account = FakeAccount(0, 8);
      installed.add(account.id);
    });
    final second = coordinator.runAccountTransition<void>(() {
      persisted.add(9);
      account = FakeAccount(1, 9);
      installed.add(account.id);
    });

    gate.complete();
    await Future.wait([first, second]);
    expect(installed, [8, 9]);
    expect(persisted, [8, 9]);
    expect(coordinator.currentToken.account, same(account));
    expect(syncCalls, 1);
  });

  test('old completion and delayed refresh cannot publish after transition',
      () async {
    final original = account;
    coordinator.startAutomaticSync();
    timers.single.tick();
    final transition = coordinator.runAccountTransition<void>(() {
      account = FakeAccount(1, 9);
    });
    runs.first.complete();
    await transition;
    await Future<void>.delayed(Duration.zero);

    expect(original.refreshes, 0);
    expect(account.refreshes, 0);
  });

  test('transition failure does not recapture a partial account and can retry',
      () async {
    final original = account;
    final failed = coordinator.runAccountTransition<void>(() {
      throw StateError('load failed');
    });
    await expectLater(failed, throwsStateError);
    expect(coordinator.currentToken.account, same(original));
    expect(syncCalls, 0);

    await coordinator.runAccountTransition<void>(() {
      account = FakeAccount(1, 11);
    });
    expect(coordinator.currentToken.account, same(account));
    expect(syncCalls, 1);
  });

  test('failed old synchronization prevents installation but permits retry',
      () async {
    coordinator.requestSync(getTx: false, auto: false);
    var mutations = 0;
    final failed = coordinator.runAccountTransition<void>(() {
      mutations++;
    });
    runs.first.completeError(StateError('sync failed'));
    await expectLater(failed, throwsStateError);
    expect(mutations, 0);

    await coordinator.runAccountTransition<void>(() {
      mutations++;
      account = FakeAccount(1, 12);
    });
    expect(mutations, 1);
  });

  test('repeated account switches retain exactly one automatic timer',
      () async {
    coordinator.startAutomaticSync();
    await coordinator.runAccountTransition<void>(() {
      account = FakeAccount(0, 8);
    });
    runs.single.complete();
    await Future<void>.delayed(Duration.zero);
    await coordinator.runAccountTransition<void>(() {
      account = FakeAccount(1, 9);
    });
    expect(timers, hasLength(1));
  });

  test('no-active-run startup installation captures account and syncs once',
      () async {
    account = FakeAccount(1, 20);
    await coordinator.runAccountTransition<void>(() {});

    expect(cancelCalls, 0);
    expect(coordinator.currentToken.coin, 1);
    expect(coordinator.currentToken.accountId, 20);
    expect(syncCalls, 1);
  });

  test('installation publishes once then advances sequence and clears pause',
      () async {
    var active = account;
    var replacements = 0;
    var sequence = 0;
    var paused = true;
    final requested = FakeAccount(1, 21);

    await coordinator.runAccountTransition<void>(() {
      // Models the application mutation's required publication order.
      expect(sequence, 0);
      active = requested;
      account = active;
      replacements++;
      paused = false;
      sequence++;
    });

    expect(replacements, 1);
    expect(sequence, 1);
    expect(paused, isFalse);
    expect(coordinator.currentToken.account, same(requested));
  });

  test('deletion fallback mutation uses the same cancellation barrier',
      () async {
    coordinator.requestSync(getTx: false, auto: false);
    var deleted = false;
    final fallback = coordinator.runAccountTransition<void>(() {
      deleted = true;
      account = FakeAccount(0, 0);
    });

    expect(deleted, isFalse);
    runs.first.complete();
    await fallback;
    expect(deleted, isTrue);
    expect(coordinator.currentToken.accountId, 0);
  });

  test('new import activation uses the same cancellation barrier', () async {
    coordinator.requestSync(getTx: false, auto: false);
    var initialized = false;
    final activation = coordinator.runAccountTransition<void>(() {
      initialized = true;
      account = FakeAccount(1, 30);
    });

    expect(initialized, isFalse);
    runs.first.complete();
    await activation;
    expect(initialized, isTrue);
    expect(coordinator.currentToken.account, same(account));
  });

  test('old finally ownership check cannot clear replacement state', () async {
    var syncing = true;
    late SyncLifecycleToken oldToken;
    coordinator = SyncLifecycleCoordinator(
      accountProvider: () => SyncLifecycleAccount(
        coin: account.coin,
        accountId: account.id,
        account: account,
      ),
      sync: (token, {required getTx, required auto}) async {
        oldToken = token;
        final run = Completer<void>();
        runs.add(run);
        try {
          await run.future;
        } finally {
          if (coordinator.ownsAuthoritativeRun(token)) syncing = false;
        }
      },
      cancel: () => cancelCalls++,
    );
    coordinator.requestSync(getTx: false, auto: false);
    final transition = coordinator.runAccountTransition<void>(() {
      account = FakeAccount(1, 31);
      syncing = true;
    });
    expect(coordinator.owns(oldToken), isFalse);
    runs.first.complete();
    await transition;
    expect(syncing, isTrue);
  });
}
