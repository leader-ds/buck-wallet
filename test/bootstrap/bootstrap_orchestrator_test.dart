import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:warp_api/server_coordinator.dart';

import '../../lib/bootstrap/bootstrap_lkg_cache.dart';
import '../../lib/bootstrap/bootstrap_orchestrator.dart';
import '../../lib/bootstrap/bootstrap_parser.dart';
import '../../lib/bootstrap/bootstrap_transport.dart';

const _valid = '''{
  "configVersion": 1,
  "network": "BUCK",
  "futureField": {"preserved": true},
  "servers": [
    {"id":"remote-b","displayName":"Remote B","grpcUrl":"https://b.example","priority":2,"enabled":true},
    {"id":"remote-a","displayName":"Remote A","grpcUrl":"https://a.example","priority":1,"enabled":true},
    {"id":"disabled","displayName":"Disabled","grpcUrl":"https://off.example","priority":0,"enabled":false}
  ]
}''';

String _document(String id, {bool enabled = true}) => jsonEncode({
      'configVersion': 1,
      'network': 'BUCK',
      'servers': [
        {
          'id': id,
          'displayName': id,
          'grpcUrl': 'https://$id.example',
          'priority': 1,
          'enabled': enabled,
        }
      ],
    });

class _Cache implements BootstrapCache {
  BootstrapCacheLoadResult loadResult = _missing();
  BootstrapCacheSaveResult saveResult = _saved();
  int loads = 0;
  int saves = 0;
  String? savedDocument;

  @override
  Future<BootstrapCacheLoadResult> load() async {
    loads++;
    return loadResult;
  }

  @override
  Future<BootstrapCacheSaveResult> saveValidated({
    required String document,
    required BootstrapParseResult parsed,
  }) async {
    saves++;
    savedDocument = document;
    return saveResult;
  }

  @override
  Future<BootstrapCacheDeleteResult> delete() => throw UnimplementedError();
}

BootstrapCacheLoadResult _missing() => const BootstrapCacheLoadResult(
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

BootstrapCacheSaveResult _saved({bool success = true}) =>
    BootstrapCacheSaveResult(
      success: success,
      byteCount: 1,
      elapsedMilliseconds: 0,
      failureCategory: success
          ? BootstrapCacheFailureCategory.none
          : BootstrapCacheFailureCategory.write,
      diagnosticMessage: success ? 'saved' : 'write failed',
      cacheKey: 'test',
      atomicReplacementCompleted: success,
    );

Future<BootstrapCacheLoadResult> _cached(String document) async {
  final parsed = await const BootstrapParser().parse(document);
  return BootstrapCacheLoadResult(
    success: parsed.success,
    found: true,
    document: document,
    parsed: parsed,
    failureCategory: parsed.success
        ? BootstrapCacheFailureCategory.none
        : BootstrapCacheFailureCategory.invalidDocument,
    diagnosticMessage: parsed.success ? 'loaded' : 'invalid',
    cacheKey: 'test',
    byteCount: document.length,
    elapsedMilliseconds: 0,
    unusable: !parsed.success,
    invalidDataRemoved: false,
  );
}

BootstrapDownloadResult _download(Uri uri, String text,
        {bool success = true}) =>
    BootstrapDownloadResult(
      requestedUri: uri,
      effectiveUri: uri,
      success: success,
      responseBytes: success ? Uint8List.fromList(utf8.encode(text)) : null,
      responseText: success ? text : null,
      httpStatusCode: success ? 200 : null,
      contentLength: success ? utf8.encode(text).length : null,
      elapsedMilliseconds: 0,
      redirectCount: 0,
      failureCategory: success
          ? BootstrapDownloadFailure.none
          : BootstrapDownloadFailure.timeout,
      diagnosticMessage: success ? 'downloaded' : 'timeout',
    );

void main() {
  final uri = Uri.parse('https://bootstrap.example/config.json');

  test('no cache and no URI uses immutable authoritative embedded FR1/FR2',
      () async {
    final cache = _Cache();
    var downloads = 0;
    final result = await BootstrapOrchestrator(
      cache: cache,
      download: (uri) async {
        downloads++;
        return _download(uri, _valid);
      },
    ).resolve();
    expect(result.success, isTrue);
    expect(result.effectiveSource, BootstrapEffectiveSource.embedded);
    expect(result.effectiveDefinitions.map((server) => server.id),
        ['fr-primary', 'fr-secondary']);
    expect(result.remoteUriConfigured, isFalse);
    expect(result.remoteAttempt.attempted, isFalse);
    expect(downloads, 0);
    expect(() => result.effectiveDefinitions.add(embeddedBuckServers.first),
        throwsUnsupportedError);
  });

  test('valid LKG wins when remote is absent or unavailable', () async {
    final cache = _Cache()..loadResult = await _cached(_document('cached'));
    final orchestrator = BootstrapOrchestrator(
      cache: cache,
      download: (uri) async => _download(uri, '', success: false),
    );
    expect((await orchestrator.resolve()).effectiveSource,
        BootstrapEffectiveSource.lastKnownGood);
    final failedRemote = await orchestrator.resolve(remoteUri: uri);
    expect(
        failedRemote.effectiveSource, BootstrapEffectiveSource.lastKnownGood);
    expect(failedRemote.remoteAttempt.failureStage,
        BootstrapOrchestrationFailureStage.remoteDownload);
  });

  test('invalid and all-disabled caches fall back without deletion', () async {
    final cache = _Cache()..loadResult = await _cached('{bad');
    expect(
        (await BootstrapOrchestrator(cache: cache).resolve()).effectiveSource,
        BootstrapEffectiveSource.embedded);
    cache.loadResult = await _cached(_document('off', enabled: false));
    final disabled = await BootstrapOrchestrator(cache: cache).resolve();
    expect(disabled.effectiveSource, BootstrapEffectiveSource.embedded);
    expect(disabled.cacheAttempt.success, isFalse);
  });

  test('valid remote overrides LKG, maps enabled servers, and saves original',
      () async {
    final cache = _Cache()..loadResult = await _cached(_document('cached'));
    final result = await BootstrapOrchestrator(
      cache: cache,
      download: (uri) async => _download(uri, _valid),
    ).resolve(remoteUri: uri);
    expect(result.effectiveSource, BootstrapEffectiveSource.remote);
    expect(result.effectiveServers.length, 3);
    expect(result.effectiveDefinitions.map((server) => server.id),
        ['remote-a', 'remote-b']);
    expect(
        result.effectiveDefinitions.every((server) => server.enabled), isTrue);
    expect(result.remoteParseResult?.unknownFieldCount, 1);
    expect(cache.saves, 1);
    expect(cache.savedDocument, _valid);
  });

  test('cache save failure is warning and remote remains effective', () async {
    final cache = _Cache()..saveResult = _saved(success: false);
    final result = await BootstrapOrchestrator(
      cache: cache,
      download: (uri) async => _download(uri, _valid),
    ).resolve(remoteUri: uri);
    expect(result.effectiveSource, BootstrapEffectiveSource.remote);
    expect(result.cacheSaveAttempt.failureStage,
        BootstrapOrchestrationFailureStage.cacheSave);
    expect(result.warnings, contains('write failed'));
  });

  test('malformed, schema-invalid, and all-disabled remote never save',
      () async {
    for (final document in [
      '{bad',
      '{"configVersion":1,"network":"OTHER","servers":[]}',
      _document('off', enabled: false),
    ]) {
      final cache = _Cache()..loadResult = await _cached(_document('cached'));
      final result = await BootstrapOrchestrator(
        cache: cache,
        download: (uri) async => _download(uri, document),
      ).resolve(remoteUri: uri);
      expect(result.effectiveSource, BootstrapEffectiveSource.lastKnownGood);
      expect(cache.saves, 0);
    }
  });

  test('identical pending calls coalesce and later call runs again', () async {
    final gate = Completer<void>();
    var calls = 0;
    final orchestrator = BootstrapOrchestrator(
      cache: _Cache(),
      download: (uri) async {
        calls++;
        await gate.future;
        return _download(uri, _valid);
      },
    );
    final first = orchestrator.resolve(remoteUri: uri);
    final second = orchestrator.resolve(remoteUri: uri);
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    gate.complete();
    await Future.wait([first, second]);
    await orchestrator.resolve(remoteUri: uri);
    expect(calls, 2);
  });

  test('distinct URI requests execute FIFO', () async {
    final firstGate = Completer<void>();
    final calls = <String>[];
    final orchestrator = BootstrapOrchestrator(
      cache: _Cache(),
      download: (uri) async {
        calls.add(uri.host);
        if (calls.length == 1) await firstGate.future;
        return _download(uri, _valid);
      },
    );
    final first = orchestrator.resolve(remoteUri: uri);
    final second = orchestrator.resolve(
        remoteUri: Uri.parse('https://second.example/config.json'));
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['bootstrap.example']);
    firstGate.complete();
    await Future.wait([first, second]);
    expect(calls, ['bootstrap.example', 'second.example']);
  });

  test('application changes definitions without probing or runtime effects',
      () async {
    var probes = 0;
    final coordinator = ServerCoordinator(probe: (url) async {
      probes++;
      throw StateError('must not probe');
    });
    final orchestrator = BootstrapOrchestrator(
      cache: _Cache(),
      download: (uri) async => _download(uri, _valid),
    );
    final resolved = await orchestrator.resolve(remoteUri: uri);
    final applied =
        await orchestrator.applyToCoordinator(resolved, coordinator);
    expect(applied.success, isTrue);
    expect(applied.coordinatorListChanged, isTrue);
    expect(coordinator.servers.map((server) => server.id),
        ['remote-a', 'remote-b']);
    expect(coordinator.statuses.map((status) => status.healthState),
        everyElement(ServerHealthState.unknown));
    expect(coordinator.selectedCandidate, isNull);
    expect(probes, 0);
    final repeated =
        await orchestrator.applyToCoordinator(resolved, coordinator);
    expect(repeated.coordinatorListChanged, isFalse);
  });
}
