import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:warp_api/server_probe.dart';

import '../lib/runtime_server_transition.dart';
import '../lib/sync_lifecycle_coordinator.dart';

const fr1 = 'https://wallet.buck.red:9067';
const fr2 = 'https://lwd2.buck.red:9067';

class Account {
  final int coin;
  final int id;
  Account(this.coin, this.id);
}

class FakeTimer implements SyncLifecycleTimer {
  final void Function() callback;
  bool cancelled = false;
  FakeTimer(this.callback);
  void tick() => callback();
  @override
  void cancel() => cancelled = true;
}

ServerProbeResult validProbe(String url) => ServerProbeResult(
      url: url,
      success: true,
      failureCategory: null,
      errorMessage: null,
      elapsedMilliseconds: BigInt.one,
      version: 'v1',
      vendor: 'BUCK',
      taddrSupport: true,
      chainName: 'main',
      saplingActivationHeight: BigInt.from(261500),
      consensusBranchId: 'f5b9230b',
      blockHeight: BigInt.from(3000000),
      estimatedHeight: BigInt.from(3000000),
      gitCommit: null,
      buildDate: null,
    );

class Harness {
  Account account = Account(0, 7);
  String configured = fr1;
  final events = <String>[];
  final timers = <FakeTimer>[];
  final settings = <String>[];
  final syncGates = <Completer<void>>[];
  bool holdSync = false;
  bool failSync = false;
  bool mismatch = false;
  bool rollbackFails = false;
  int cancels = 0;
  int resets = 0;
  late final SyncLifecycleCoordinator coordinator;
  late RuntimeServerTransition service;

  Harness() {
    coordinator = SyncLifecycleCoordinator(
      accountProvider: () => SyncLifecycleAccount(
        coin: account.coin,
        accountId: account.id,
        account: account,
      ),
      sync: (token, {required getTx, required auto}) async {
        events.add('sync:${configured}');
        if (failSync) throw StateError('refresh failed');
        if (holdSync) {
          final gate = Completer<void>();
          syncGates.add(gate);
          await gate.future;
        }
      },
      cancel: () {
        cancels++;
        events.add('cancel');
      },
      timerFactory: (_, callback) {
        final timer = FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
    );
    service = RuntimeServerTransition(
      lifecycle: coordinator,
      probeServer: (url) async {
        events.add('probe:$url');
        return validProbe(url);
      },
      updateLwd: (_, url) {
        events.add('apply:$url');
        if (rollbackFails && url == fr1) throw StateError('rollback failed');
        if (url == fr1) {
          configured = url;
          mismatch = false;
        } else {
          configured = mismatch ? 'https://mismatch.example:9067' : url;
        }
      },
      getLwd: (_) {
        events.add('get:$configured');
        return configured;
      },
      commitSettings: (_, url) {
        events.add('settings:$url');
        settings.add(url);
      },
      resetState: () {
        events.add('reset');
        resets++;
      },
    );
  }
}

void main() {
  test('FR1 to FR2 probes, applies, verifies, resets, and syncs in order',
      () async {
    final h = Harness();
    final generation = h.coordinator.currentToken.generation;
    final result = await h.service.switchServer(coin: 0, targetUrl: fr2);
    expect(result.success, isTrue);
    expect(h.events, [
      'get:$fr1',
      'probe:$fr2',
      'apply:$fr2',
      'get:$fr2',
      'settings:$fr2',
      'reset',
      'sync:$fr2',
    ]);
    expect(h.coordinator.currentToken.generation, generation + 1);
  });

  test('FR2 to FR1 succeeds and setter is called once', () async {
    final h = Harness()..configured = fr2;
    final result = await h.service.switchServer(coin: 0, targetUrl: fr1);
    expect(result.success, isTrue);
    expect(h.events.where((e) => e.startsWith('apply:')), ['apply:$fr1']);
  });

  test('same normalized URL is a no-op without probe, mutation, or sync',
      () async {
    final h = Harness()..configured = 'https://WALLET.BUCK.RED:9067/';
    final generation = h.coordinator.currentToken.generation;
    final result = await h.service.switchServer(coin: 0, targetUrl: fr1);
    expect(result.success, isTrue);
    expect(result.noOp, isTrue);
    expect(h.events, ['get:https://WALLET.BUCK.RED:9067/']);
    expect(h.cancels, 0);
    expect(h.coordinator.currentToken.generation, generation);
  });

  test('probe failure does not mutate lifecycle or call setter', () async {
    final h = Harness();
    h.service = RuntimeServerTransition(
      lifecycle: h.coordinator,
      probeServer: (url) async => ServerProbeResult(
        url: url,
        success: false,
        failureCategory: ServerProbeFailureCategory.connection,
        errorMessage: 'offline',
        elapsedMilliseconds: BigInt.one,
        version: null,
        vendor: null,
        taddrSupport: null,
        chainName: null,
        saplingActivationHeight: null,
        consensusBranchId: null,
        blockHeight: null,
        estimatedHeight: null,
        gitCommit: null,
        buildDate: null,
      ),
      updateLwd: (_, __) => fail('setter called'),
      getLwd: (_) => fr1,
      commitSettings: (_, __) {},
      resetState: () {},
    );
    final generation = h.coordinator.currentToken.generation;
    final result = await h.service.switchServer(coin: 0, targetUrl: fr2);
    expect(result.failureStage, ServerTransitionFailureStage.probe);
    expect(h.coordinator.currentToken.generation, generation);
  });

  test('malformed target fails before probe or lifecycle mutation', () async {
    final h = Harness();
    final generation = h.coordinator.currentToken.generation;
    final result = await h.service.switchServer(coin: 0, targetUrl: 'no-host');
    expect(result.failureStage, ServerTransitionFailureStage.invalidRequest);
    expect(h.events, ['get:$fr1']);
    expect(h.coordinator.currentToken.generation, generation);
  });

  test('invalid BUCK identity does not mutate lifecycle or call setter',
      () async {
    final h = Harness();
    h.service = RuntimeServerTransition(
      lifecycle: h.coordinator,
      probeServer: (url) async {
        final p = validProbe(url);
        return ServerProbeResult(
          url: p.url,
          success: true,
          failureCategory: null,
          errorMessage: null,
          elapsedMilliseconds: p.elapsedMilliseconds,
          version: p.version,
          vendor: p.vendor,
          taddrSupport: p.taddrSupport,
          chainName: 'test',
          saplingActivationHeight: p.saplingActivationHeight,
          consensusBranchId: p.consensusBranchId,
          blockHeight: p.blockHeight,
          estimatedHeight: p.estimatedHeight,
          gitCommit: null,
          buildDate: null,
        );
      },
      updateLwd: (_, __) => fail('setter called'),
      getLwd: (_) => fr1,
      commitSettings: (_, __) {},
      resetState: () {},
    );
    final generation = h.coordinator.currentToken.generation;
    final result = await h.service.switchServer(coin: 0, targetUrl: fr2);
    expect(result.failureStage, ServerTransitionFailureStage.validation);
    expect(h.coordinator.currentToken.generation, generation);
  });

  test('context change during probe aborts before setter', () async {
    final h = Harness();
    final gate = Completer<void>();
    h.service = RuntimeServerTransition(
      lifecycle: h.coordinator,
      probeServer: (url) async {
        await gate.future;
        return validProbe(url);
      },
      updateLwd: (_, __) => fail('setter called'),
      getLwd: (_) => fr1,
      commitSettings: (_, __) {},
      resetState: () {},
    );
    final future = h.service.switchServer(coin: 0, targetUrl: fr2);
    await h.coordinator.runAccountTransition<void>(() {
      h.account = Account(1, 9);
    });
    gate.complete();
    final result = await future;
    expect(result.failureStage, ServerTransitionFailureStage.contextChanged);
  });

  test('active synchronization is cancelled once and awaited before setter',
      () async {
    final h = Harness()..holdSync = true;
    h.coordinator.requestSync(getTx: false, auto: false);
    await Future<void>.delayed(Duration.zero);
    final transition = h.service.switchServer(coin: 0, targetUrl: fr2);
    await Future<void>.delayed(Duration.zero);
    expect(h.cancels, 1);
    expect(h.events.where((e) => e.startsWith('apply:')), isEmpty);
    h.holdSync = false;
    h.syncGates.single.complete();
    await transition;
    expect(
        h.events.indexOf('cancel'), lessThan(h.events.indexOf('apply:$fr2')));
  });

  test('failed cancellation returns typed failure before setter', () async {
    final h = Harness()..holdSync = true;
    h.coordinator.requestSync(getTx: false, auto: false);
    await Future<void>.delayed(Duration.zero);
    final transition = h.service.switchServer(coin: 0, targetUrl: fr2);
    await Future<void>.delayed(Duration.zero);
    h.syncGates.single.completeError(StateError('cancel failed'));
    final result = await transition;
    expect(result.failureStage, ServerTransitionFailureStage.cancellation);
    expect(h.events.where((e) => e.startsWith('apply:')), isEmpty);
  });

  test('timer submits no run during transition and timer remains singular',
      () async {
    final h = Harness()..holdSync = true;
    h.coordinator.startAutomaticSync();
    final transition = h.service.switchServer(coin: 0, targetUrl: fr2);
    await Future<void>.delayed(Duration.zero);
    h.timers.single.tick();
    expect(h.events.where((e) => e.startsWith('sync:')), hasLength(1));
    h.holdSync = false;
    h.syncGates.single.complete();
    await transition;
    await h.service.switchServer(coin: 0, targetUrl: fr1);
    expect(h.timers, hasLength(1));
  });

  test('verification mismatch rolls back and starts one recovery sync',
      () async {
    final h = Harness()..mismatch = true;
    final result = await h.service.switchServer(coin: 0, targetUrl: fr2);
    expect(result.failureStage, ServerTransitionFailureStage.verification);
    expect(result.rollbackAttempted, isTrue);
    expect(result.rollbackSucceeded, isTrue);
    expect(h.configured, fr1);
    expect(h.settings, isEmpty);
    expect(h.events.where((e) => e == 'sync:$fr1'), hasLength(1));
  });

  test('rollback failure is critical and leaves synchronization blocked',
      () async {
    final h = Harness()
      ..mismatch = true
      ..rollbackFails = true;
    final result = await h.service.switchServer(coin: 0, targetUrl: fr2);
    expect(result.failureStage, ServerTransitionFailureStage.rollback);
    expect(result.rollbackSucceeded, isFalse);
    expect(h.coordinator.isTransitioning, isTrue);
    expect(h.events.where((e) => e.startsWith('sync:')), isEmpty);
  });

  test('refresh failure retains target and a later manual sync can retry',
      () async {
    final h = Harness()..failSync = true;
    final result = await h.service.switchServer(coin: 0, targetUrl: fr2);
    expect(result.failureStage, ServerTransitionFailureStage.refresh);
    expect(h.configured, fr2);
    expect(h.settings, [fr2]);
    h.failSync = false;
    await h.coordinator.requestSync(getTx: false, auto: false);
    expect(h.events.where((e) => e == 'sync:$fr2'), hasLength(2));
  });

  test('account and server transitions share FIFO mutual exclusion', () async {
    final h = Harness();
    final accountGate = Completer<void>();
    final accountTransition =
        h.coordinator.runAccountTransition<void>(() async {
      h.events.add('account-start');
      await accountGate.future;
      h.events.add('account-end');
    });
    final serverTransition = h.service.switchServer(coin: 0, targetUrl: fr2);
    await Future<void>.delayed(Duration.zero);
    expect(h.events, contains('account-start'));
    expect(h.events, isNot(contains('apply:$fr2')));
    accountGate.complete();
    await accountTransition;
    await serverTransition;
    expect(h.events.indexOf('account-end'),
        lessThan(h.events.indexOf('apply:$fr2')));
  });

  test('distinct and duplicate requests execute FIFO without coalescing',
      () async {
    final h = Harness();
    final first = h.service.switchServer(coin: 0, targetUrl: fr2);
    final second = h.service
        .switchServer(coin: 0, targetUrl: 'https://third.example:9067');
    final duplicate = h.service.switchServer(coin: 0, targetUrl: fr2);
    await Future.wait([first, second, duplicate]);
    expect(h.events.where((e) => e.startsWith('apply:')), [
      'apply:$fr2',
      'apply:https://third.example:9067',
      'apply:$fr2',
    ]);
  });

  test('URL normalization preserves scheme and explicit port', () {
    expect(normalizeLightwalletUrl('HTTPS://Example.COM:9067/').toString(),
        'https://example.com:9067');
    expect(normalizeLightwalletUrl('http://example.com:9067'),
        isNot(normalizeLightwalletUrl('https://example.com:9067')));
    expect(() => normalizeLightwalletUrl('https:///missing'),
        throwsFormatException);
  });
}
