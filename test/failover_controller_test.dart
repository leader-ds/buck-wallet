import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:warp_api/server_coordinator.dart';
import 'package:warp_api/server_probe.dart';

import '../lib/failover_controller.dart';
import '../lib/runtime_server_transition.dart';
import '../lib/sync_lifecycle_coordinator.dart';

const primaryUrl = 'https://wallet.buck.red:9067';
const secondaryUrl = 'https://lwd2.buck.red:9067';

ServerProbeResult healthyProbe(String url) => ServerProbeResult(
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
      gitCommit: 'test',
      buildDate: 'today',
    );

ServerProbeResult failedProbe(String url) => ServerProbeResult(
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
    );

class _FakeTimer implements SyncLifecycleTimer {
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

class Harness {
  Duration now = Duration.zero;
  bool primaryHealthy = false;
  bool secondaryHealthy = true;
  bool secondaryValid = true;
  bool throwOnTarget = false;
  bool mismatchTarget = false;
  int switchCalls = 0;
  int timerCreations = 0;
  String activeUrl = primaryUrl;
  Completer<void>? transitionProbeGate;

  late final ServerCoordinator coordinator = ServerCoordinator(
    probe: (url) async {
      if (url == primaryUrl) {
        return primaryHealthy ? healthyProbe(url) : failedProbe(url);
      }
      if (!secondaryHealthy) return failedProbe(url);
      final result = healthyProbe(url);
      if (secondaryValid) return result;
      return ServerProbeResult(
        url: result.url,
        success: result.success,
        failureCategory: result.failureCategory,
        errorMessage: result.errorMessage,
        elapsedMilliseconds: result.elapsedMilliseconds,
        version: result.version,
        vendor: result.vendor,
        taddrSupport: result.taddrSupport,
        chainName: 'test',
        saplingActivationHeight: result.saplingActivationHeight,
        consensusBranchId: result.consensusBranchId,
        blockHeight: result.blockHeight,
        estimatedHeight: result.estimatedHeight,
        gitCommit: result.gitCommit,
        buildDate: result.buildDate,
      );
    },
  );

  late final SyncLifecycleCoordinator lifecycle = SyncLifecycleCoordinator(
    accountProvider: () => const SyncLifecycleAccount(
      coin: 0,
      accountId: 1,
      account: 'account',
    ),
    sync: (token, {required getTx, required auto}) async {},
    cancel: () {},
    timerFactory: (interval, callback) {
      timerCreations++;
      return _FakeTimer();
    },
  );

  late final RuntimeServerTransition transition = RuntimeServerTransition(
    lifecycle: lifecycle,
    probeServer: (url) async {
      switchCalls++;
      await transitionProbeGate?.future;
      return healthyProbe(url);
    },
    updateLwd: (coin, url) {
      if (url == secondaryUrl && throwOnTarget) throw StateError('apply');
      activeUrl = url == secondaryUrl && mismatchTarget ? primaryUrl : url;
    },
    getLwd: (coin) => activeUrl,
    commitSettings: (coin, url) {},
    resetState: () {},
  );

  late final FailoverController controller = FailoverController(
    serverCoordinator: coordinator,
    runtimeServerTransition: transition,
    monotonicClock: () => now,
  );

  Future<ServerTransitionResult?> observe() =>
      controller.observeProbeResults(coin: 0, activeUrl: activeUrl);

  Future<ServerTransitionResult?> refreshAndObserve() async {
    await coordinator.refresh();
    return observe();
  }
}

void main() {
  test('one failed probe does not fail over', () async {
    final h = Harness();
    expect(await h.refreshAndObserve(), isNull);
    expect(h.controller.state, FailoverHealthState.healthy);
    expect(h.switchCalls, 0);
  });

  test('two failed probes enter suspect only', () async {
    final h = Harness();
    await h.refreshAndObserve();
    expect(await h.refreshAndObserve(), isNull);
    expect(h.controller.state, FailoverHealthState.suspect);
    expect(h.switchCalls, 0);
  });

  test('three failed probes request exactly one runtime transition', () async {
    final h = Harness();
    await h.refreshAndObserve();
    await h.refreshAndObserve();
    final result = await h.refreshAndObserve();
    expect(result?.success, isTrue);
    expect(h.switchCalls, 1);
    expect(h.activeUrl, secondaryUrl);
  });

  test('candidate unavailable does not transition', () async {
    final h = Harness()..secondaryHealthy = false;
    for (var i = 0; i < 3; i++) await h.refreshAndObserve();
    expect(h.controller.state, FailoverHealthState.failed);
    expect(h.switchCalls, 0);
  });

  test('candidate invalid for BUCK does not transition', () async {
    final h = Harness()..secondaryValid = false;
    for (var i = 0; i < 3; i++) await h.refreshAndObserve();
    expect(h.coordinator.selectedCandidate, isNull);
    expect(h.switchCalls, 0);
  });

  test('candidate with the same normalized URL does not transition', () async {
    const same = 'https://same.example:9067';
    var calls = 0;
    final coordinator = ServerCoordinator(
      servers: const [
        ServerDefinition(
          id: 'active',
          name: 'Active',
          url: same,
          priority: 1,
          enabled: true,
        ),
        ServerDefinition(
          id: 'duplicate',
          name: 'Duplicate',
          url: '$same/',
          priority: 2,
          enabled: true,
        ),
      ],
      probe: (url) async {
        calls++;
        return calls.isOdd ? failedProbe(url) : healthyProbe(url);
      },
    );
    final h = Harness();
    final controller = FailoverController(
      serverCoordinator: coordinator,
      runtimeServerTransition: h.transition,
      monotonicClock: () => h.now,
    );
    for (var i = 0; i < 3; i++) {
      await coordinator.refresh();
      await controller.observeProbeResults(coin: 0, activeUrl: same);
    }
    expect(h.switchCalls, 0);
  });

  test('successful transition begins cooldown and marks secondary active',
      () async {
    final h = Harness();
    for (var i = 0; i < 3; i++) await h.refreshAndObserve();
    expect(h.controller.state, FailoverHealthState.secondaryActive);
    h.primaryHealthy = true;
    await h.refreshAndObserve();
    expect(h.switchCalls, 1);
  });

  test('transition failure is retryable only after cooldown', () async {
    final h = Harness()..throwOnTarget = true;
    for (var i = 0; i < 3; i++) await h.refreshAndObserve();
    expect(h.controller.lastTransitionResult?.success, isFalse);
    expect(h.controller.lastTransitionResult?.rollbackSucceeded, isTrue);
    expect(h.activeUrl, primaryUrl);
    await h.refreshAndObserve();
    expect(h.switchCalls, 1);
    h.now += const Duration(seconds: 60);
    h.throwOnTarget = false;
    final retry = await h.refreshAndObserve();
    expect(retry?.success, isTrue);
    expect(h.switchCalls, 2);
  });

  test('verification rollback result is respected without extra rollback',
      () async {
    final h = Harness()..mismatchTarget = true;
    for (var i = 0; i < 3; i++) await h.refreshAndObserve();
    final result = h.controller.lastTransitionResult;
    expect(result?.success, isFalse);
    expect(result?.rollbackAttempted, isTrue);
    expect(result?.rollbackSucceeded, isTrue);
    expect(h.activeUrl, primaryUrl);
  });

  test('successful active probe clears accumulated failures', () async {
    final h = Harness();
    await h.refreshAndObserve();
    await h.refreshAndObserve();
    expect(h.controller.consecutiveFailedProbes, 2);
    h.primaryHealthy = true;
    await h.refreshAndObserve();
    expect(h.controller.consecutiveFailedProbes, 0);
    expect(h.controller.state, FailoverHealthState.healthy);
  });

  test('runtime sync failures are observed but cannot trigger failover',
      () async {
    final h = Harness();
    h.controller.observeRuntimeSyncFailure();
    h.controller.observeRuntimeSyncFailure();
    h.controller.observeRuntimeSyncFailure();
    expect(h.controller.consecutiveRuntimeSyncFailures, 3);
    expect(h.switchCalls, 0);
    h.controller.observeRuntimeSyncSuccess();
    expect(h.controller.consecutiveRuntimeSyncFailures, 0);
  });

  test('recovered FR1 is recorded and never selected automatically', () async {
    final h = Harness();
    for (var i = 0; i < 3; i++) await h.refreshAndObserve();
    h.primaryHealthy = true;
    await h.refreshAndObserve();
    expect(h.coordinator.selectedCandidate?.id, 'fr-primary');
    expect(h.controller.preferredServerRecovered, isTrue);
    expect(h.activeUrl, secondaryUrl);
    expect(h.switchCalls, 1);
  });

  test('concurrent observations call RuntimeServerTransition exactly once',
      () async {
    final h = Harness();
    await h.refreshAndObserve();
    await h.refreshAndObserve();
    await h.coordinator.refresh();
    h.transitionProbeGate = Completer<void>();
    final first = h.observe();
    await Future<void>.delayed(Duration.zero);
    final second = h.observe();
    expect(h.switchCalls, 1);
    h.transitionProbeGate!.complete();
    final results = await Future.wait([first, second]);
    expect(results.every((result) => result?.success == true), isTrue);
    expect(h.switchCalls, 1);
  });

  test('controller creates no timer and preserves lifecycle timer ownership',
      () async {
    final h = Harness();
    h.lifecycle.startAutomaticSync();
    h.lifecycle.startAutomaticSync();
    for (var i = 0; i < 3; i++) await h.refreshAndObserve();
    expect(h.timerCreations, 1);
    expect(h.lifecycle.hasAutomaticTimer, isTrue);
  });

  test('ServerCoordinator remains the probe and candidate selector', () async {
    final h = Harness();
    for (var i = 0; i < 3; i++) await h.refreshAndObserve();
    expect(h.coordinator.selectedCandidate?.id, 'fr-secondary');
    expect(h.controller.lastTransitionResult?.targetUrl, secondaryUrl);
  });
}
