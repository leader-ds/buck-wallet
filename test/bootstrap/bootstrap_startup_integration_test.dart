import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:warp_api/server_coordinator.dart';

import '../../lib/bootstrap/bootstrap_lkg_cache.dart';
import '../../lib/bootstrap/bootstrap_orchestrator.dart';
import '../../lib/bootstrap/bootstrap_parser.dart';
import '../../lib/bootstrap/bootstrap_startup_integration.dart';

class _Cache implements BootstrapCache {
  @override
  Future<BootstrapCacheLoadResult> load() async =>
      const BootstrapCacheLoadResult(
        success: true,
        found: false,
        document: null,
        parsed: null,
        failureCategory: BootstrapCacheFailureCategory.notFound,
        diagnosticMessage: 'missing',
        cacheKey: 'test',
        byteCount: null,
        elapsedMilliseconds: 0,
        unusable: false,
        invalidDataRemoved: false,
      );

  @override
  Future<BootstrapCacheSaveResult> saveValidated({
    required String document,
    required BootstrapParseResult parsed,
  }) =>
      throw UnimplementedError();

  @override
  Future<BootstrapCacheDeleteResult> delete() => throw UnimplementedError();
}

Future<BootstrapOrchestrationResult> _embeddedResult() =>
    BootstrapOrchestrator(cache: _Cache()).resolve();

void main() {
  test('one shot coalesces concurrent and completed calls', () async {
    final result = await _embeddedResult();
    final gate = Completer<void>();
    var resolves = 0;
    final integration = BootstrapStartupIntegration(
      orchestrator: BootstrapOrchestrator(cache: _Cache()),
      coordinator:
          ServerCoordinator(probe: (_) async => throw StateError('probe')),
      remoteUri: null,
      resolve: ({remoteUri}) async {
        resolves++;
        await gate.future;
        return result;
      },
    );

    final first = integration.start();
    final concurrent = integration.start();
    expect(identical(first, concurrent), isTrue);
    expect(resolves, 1);
    gate.complete();
    final completed = await first;
    expect(completed.success, isTrue);
    expect(completed.coalesced, isTrue);
    expect(identical(integration.start(), first), isTrue);
    expect(resolves, 1);
  });

  test('delayed resolve does not block wallet-ready work', () async {
    final result = await _embeddedResult();
    final gate = Completer<void>();
    final ready = Completer<void>();
    final integration = BootstrapStartupIntegration(
      orchestrator: BootstrapOrchestrator(cache: _Cache()),
      coordinator: ServerCoordinator(),
      remoteUri: null,
      resolve: ({remoteUri}) async {
        await gate.future;
        return result;
      },
    );

    final operation = integration.start();
    var completed = false;
    operation.then((_) => completed = true);
    ready.complete();
    await ready.future;
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    gate.complete();
    expect((await operation).completed, isTrue);
  });

  test('embedded definitions exist before resolve and apply is typed no-op',
      () async {
    final coordinator = ServerCoordinator();
    expect(coordinator.servers.map((server) => server.id),
        ['fr-primary', 'fr-secondary']);
    var applies = 0;
    final integration = BootstrapStartupIntegration(
      orchestrator: BootstrapOrchestrator(cache: _Cache()),
      coordinator: coordinator,
      remoteUri: null,
      apply: (result, target) {
        applies++;
        expect(identical(target, coordinator), isTrue);
        return BootstrapOrchestrator(cache: _Cache())
            .applyToCoordinator(result, target);
      },
    );
    final startup = await integration.start();
    expect(applies, 1);
    expect(startup.success, isTrue);
    expect(startup.effectiveSource, BootstrapEffectiveSource.embedded);
    expect(startup.definitionsApplied, isTrue);
    expect(startup.coordinatorListChanged, isFalse);
  });

  test('changed definitions apply exactly once without probing', () async {
    var probes = 0;
    final coordinator = ServerCoordinator(probe: (_) async {
      probes++;
      throw StateError('not expected');
    });
    final base = await _embeddedResult();
    final changed = BootstrapOrchestrationResult(
      success: true,
      effectiveSource: BootstrapEffectiveSource.lastKnownGood,
      effectiveParseResult: base.effectiveParseResult,
      effectiveServers: base.effectiveServers,
      effectiveDefinitions: const [
        ServerDefinition(
          id: 'cache',
          name: 'Cache',
          url: 'https://cache.example',
          priority: 1,
          enabled: true,
        ),
      ],
      embeddedAvailable: true,
      cacheAttempt: base.cacheAttempt,
      cacheLoadResult: base.cacheLoadResult,
      remoteAttempt: base.remoteAttempt,
      remoteTransportResult: null,
      remoteParseResult: null,
      cacheSaveAttempt: base.cacheSaveAttempt,
      cacheSaveResult: null,
      warnings: const [],
      elapsedMilliseconds: 0,
      remoteUriConfigured: false,
    );
    var applies = 0;
    final integration = BootstrapStartupIntegration(
      orchestrator: BootstrapOrchestrator(cache: _Cache()),
      coordinator: coordinator,
      remoteUri: null,
      resolve: ({remoteUri}) async => changed,
      apply: (result, target) {
        applies++;
        return BootstrapOrchestrator(cache: _Cache())
            .applyToCoordinator(result, target);
      },
    );
    final startup = await integration.start();
    expect(startup.success, isTrue);
    expect(startup.coordinatorListChanged, isTrue);
    expect(applies, 1);
    expect(probes, 0);
  });

  test('resolve and apply exceptions are contained as typed failures',
      () async {
    final coordinator = ServerCoordinator();
    final resolveFailure = BootstrapStartupIntegration(
      orchestrator: BootstrapOrchestrator(cache: _Cache()),
      coordinator: coordinator,
      remoteUri: null,
      resolve: ({remoteUri}) => throw StateError('secret document body'),
    );
    final resolved = await resolveFailure.start();
    expect(resolved.success, isFalse);
    expect(resolved.failureStage, BootstrapStartupFailureStage.unexpected);
    expect(resolved.diagnosticMessage, isNot(contains('secret document body')));

    final embedded = await _embeddedResult();
    final applyFailure = BootstrapStartupIntegration(
      orchestrator: BootstrapOrchestrator(cache: _Cache()),
      coordinator: coordinator,
      remoteUri: null,
      resolve: ({remoteUri}) async => embedded,
      apply: (_, __) => throw StateError('apply detail'),
    );
    final applied = await applyFailure.start();
    expect(applied.failureStage, BootstrapStartupFailureStage.apply);
    expect(applied.diagnosticMessage, isNot(contains('apply detail')));
  });

  test('empty, valid, and invalid configuration are safe and query-private',
      () {
    final empty = parseBootstrapRemoteConfiguration('');
    expect(empty.remoteUri, isNull);
    expect(empty.configured, isFalse);

    final valid = parseBootstrapRemoteConfiguration(
        'https://bootstrap.example/config?token=secret');
    expect(valid.remoteUri?.host, 'bootstrap.example');
    expect(valid.diagnosticMessage, isNot(contains('token')));
    expect(valid.diagnosticMessage, isNot(contains('secret')));

    final invalid = parseBootstrapRemoteConfiguration('http://bad.example');
    expect(invalid.remoteUri, isNull);
    expect(invalid.configured, isTrue);
  });

  test('configured URI is passed only to resolve', () async {
    final uri = Uri.parse('https://bootstrap.example/config');
    final embedded = await _embeddedResult();
    Uri? observed;
    final integration = BootstrapStartupIntegration(
      orchestrator: BootstrapOrchestrator(cache: _Cache()),
      coordinator: ServerCoordinator(),
      remoteUri: uri,
      resolve: ({remoteUri}) async {
        observed = remoteUri;
        return embedded;
      },
    );
    expect((await integration.start()).remoteConfigured, isTrue);
    expect(observed, uri);
  });
}
