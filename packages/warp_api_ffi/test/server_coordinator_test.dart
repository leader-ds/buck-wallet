import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:warp_api/server_coordinator.dart';
import 'package:warp_api/server_probe.dart';

ServerProbeResult probeResult(
  String url, {
  bool success = true,
  ServerProbeFailureCategory? failureCategory,
  String? errorMessage,
  String chainName = 'main',
  int saplingActivationHeight = 261500,
  String consensusBranchId = 'f5b9230b',
}) {
  return ServerProbeResult(
    url: url,
    success: success,
    failureCategory: failureCategory,
    errorMessage: errorMessage,
    elapsedMilliseconds: BigInt.from(42),
    version: success ? 'v1' : null,
    vendor: success ? 'BUCK' : null,
    taddrSupport: success ? true : null,
    chainName: success ? chainName : null,
    saplingActivationHeight:
        success ? BigInt.from(saplingActivationHeight) : null,
    consensusBranchId: success ? consensusBranchId : null,
    blockHeight: success ? BigInt.from(3000000) : null,
    estimatedHeight: success ? BigInt.from(3000000) : null,
    gitCommit: success ? 'abc123' : null,
    buildDate: success ? 'today' : null,
  );
}

ServerProbeResult unreachable(String url) => probeResult(
      url,
      success: false,
      failureCategory: ServerProbeFailureCategory.connection,
      errorMessage: 'connection failed',
    );

ServerStatus statusFor(ServerCoordinator coordinator, String id) =>
    coordinator.statuses.singleWhere((status) => status.server.id == id);

void main() {
  test('starts with exactly the embedded FR servers in unknown state', () {
    final coordinator =
        ServerCoordinator(probe: (url) async => unreachable(url));

    expect(coordinator.servers, hasLength(2));
    expect(
      coordinator.servers.map(
        (server) =>
            [server.id, server.url, server.priority, server.enabled],
      ),
      [
        ['fr-primary', 'https://wallet.buck.red:9067', 1, true],
        ['fr-secondary', 'https://lwd2.buck.red:9067', 2, true],
      ],
    );
    expect(
      coordinator.statuses.map((status) => status.healthState),
      everyElement(ServerHealthState.unknown),
    );
    expect(coordinator.selectedCandidate, isNull);
    expect(
      () => coordinator.servers.add(coordinator.servers.first),
      throwsUnsupportedError,
    );
    expect(() => coordinator.statuses.clear(), throwsUnsupportedError);
  });

  test('selects FR1 when both servers are healthy', () async {
    final coordinator =
        ServerCoordinator(probe: (url) async => probeResult(url));
    await coordinator.refresh();
    expect(coordinator.selectedCandidate?.id, 'fr-primary');
  });

  test('selects FR2 when FR1 is unreachable', () async {
    final coordinator = ServerCoordinator(
      probe: (url) async =>
          url.contains('wallet.') ? unreachable(url) : probeResult(url),
    );
    await coordinator.refresh();
    expect(statusFor(coordinator, 'fr-primary').healthState,
        ServerHealthState.unreachable);
    expect(coordinator.selectedCandidate?.id, 'fr-secondary');
  });

  test('marks invalid BUCK identity invalid and selects FR2', () async {
    final coordinator = ServerCoordinator(
      probe: (url) async => url.contains('wallet.')
          ? probeResult(url, chainName: 'test')
          : probeResult(url),
    );
    await coordinator.refresh();
    expect(statusFor(coordinator, 'fr-primary').healthState,
        ServerHealthState.invalid);
    expect(coordinator.selectedCandidate?.id, 'fr-secondary');
  });

  test('selects FR1 when FR2 is unreachable', () async {
    final coordinator = ServerCoordinator(
      probe: (url) async =>
          url.contains('lwd2.') ? unreachable(url) : probeResult(url),
    );
    await coordinator.refresh();
    expect(coordinator.selectedCandidate?.id, 'fr-primary');
  });

  test('selects no candidate when both servers are unreachable', () async {
    final coordinator =
        ServerCoordinator(probe: (url) async => unreachable(url));
    await coordinator.refresh();
    expect(coordinator.selectedCandidate, isNull);
  });

  test('selects no candidate when both servers are invalid', () async {
    final coordinator = ServerCoordinator(
      probe: (url) async => probeResult(url, consensusBranchId: 'wrong'),
    );
    await coordinator.refresh();
    expect(coordinator.statuses.map((status) => status.healthState),
        everyElement(ServerHealthState.invalid));
    expect(coordinator.selectedCandidate, isNull);
  });

  test('does not probe a disabled server', () async {
    final calls = <String>[];
    final coordinator = ServerCoordinator(
      servers: const [
        ServerDefinition(
          id: 'disabled',
          name: 'Disabled',
          url: 'disabled',
          priority: 1,
          enabled: false,
        ),
        ServerDefinition(
          id: 'enabled',
          name: 'Enabled',
          url: 'enabled',
          priority: 2,
          enabled: true,
        ),
      ],
      probe: (url) async {
        calls.add(url);
        return probeResult(url);
      },
    );
    await coordinator.refresh();
    expect(calls, ['enabled']);
    expect(statusFor(coordinator, 'disabled').healthState,
        ServerHealthState.unknown);
    expect(coordinator.selectedCandidate?.id, 'enabled');
  });

  test('preserves structured failure and successful LightdInfo fields',
      () async {
    final coordinator = ServerCoordinator(
      probe: (url) async =>
          url.contains('wallet.') ? unreachable(url) : probeResult(url),
    );
    await coordinator.refresh();
    final failed = statusFor(coordinator, 'fr-primary');
    final succeeded = statusFor(coordinator, 'fr-secondary');
    expect(failed.probeResult?.failureCategory,
        ServerProbeFailureCategory.connection);
    expect(failed.diagnosticMessage, 'connection failed');
    expect(failed.elapsedMilliseconds, BigInt.from(42));
    expect(succeeded.probeResult?.chainName, 'main');
    expect(succeeded.probeResult?.saplingActivationHeight, BigInt.from(261500));
    expect(succeeded.probeResult?.consensusBranchId, 'f5b9230b');
    expect(succeeded.validationResult?.isValid, isTrue);
  });

  test('repeated refresh replaces stale status and selection', () async {
    var firstRefresh = true;
    final coordinator = ServerCoordinator(
      probe: (url) async {
        final isPrimary = url.contains('wallet.');
        return isPrimary == firstRefresh ? probeResult(url) : unreachable(url);
      },
    );
    await coordinator.refresh();
    expect(coordinator.selectedCandidate?.id, 'fr-primary');
    firstRefresh = false;
    await coordinator.refresh();
    expect(statusFor(coordinator, 'fr-primary').probeResult?.success, isFalse);
    expect(statusFor(coordinator, 'fr-secondary').probeResult?.success, isTrue);
    expect(coordinator.selectedCandidate?.id, 'fr-secondary');
  });

  test('concurrent callers share one refresh cycle', () async {
    final gate = Completer<void>();
    var calls = 0;
    final coordinator = ServerCoordinator(
      probe: (url) async {
        calls++;
        await gate.future;
        return probeResult(url);
      },
    );
    final first = coordinator.refresh();
    final second = coordinator.refresh();
    expect(identical(first, second), isTrue);
    expect(calls, 1);
    gate.complete();
    await Future.wait([first, second]);
    expect(calls, 2);
  });

  test('selection uses numeric priority rather than insertion order', () async {
    final coordinator = ServerCoordinator(
      servers: const [
        ServerDefinition(
          id: 'later',
          name: 'Later',
          url: 'later',
          priority: 20,
          enabled: true,
        ),
        ServerDefinition(
          id: 'preferred',
          name: 'Preferred',
          url: 'preferred',
          priority: 10,
          enabled: true,
        ),
      ],
      probe: (url) async => probeResult(url),
    );
    await coordinator.refresh();
    expect(coordinator.selectedCandidate?.id, 'preferred');
  });
}
