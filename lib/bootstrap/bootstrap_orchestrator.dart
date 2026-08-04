import 'dart:async';

import 'package:warp_api/server_coordinator.dart';

import 'bootstrap_lkg_cache.dart';
import 'bootstrap_orchestration_models.dart';
import 'bootstrap_parser.dart';
import 'bootstrap_transport.dart';

export 'bootstrap_orchestration_models.dart';

typedef BootstrapDownload = Future<BootstrapDownloadResult> Function(Uri uri);
typedef BootstrapOrchestrationElapsedMilliseconds = int Function();

/// Resolves embedded, Last-Known-Good, and optional remote definitions.
///
/// Schema validity and LKG acceptance establish structure, not authenticity.
/// HTTPS does not prevent hosting, repository-account, DNS, or trusted-CA
/// compromise. Stage 6 signature verification must precede treating a future
/// signed remote/cache document as authenticated. Compiled FR1/FR2 remain the
/// availability anchor.
///
/// Identical pending URI requests coalesce. Distinct URI requests execute FIFO.
class BootstrapOrchestrator {
  final BootstrapCache cache;
  final BootstrapParser parser;
  final BootstrapDownload download;
  final BootstrapOrchestrationElapsedMilliseconds? elapsedMilliseconds;

  Future<void> _tail = Future<void>.value();
  final Map<String, Future<BootstrapOrchestrationResult>> _pending = {};

  BootstrapOrchestrator({
    required this.cache,
    this.parser = const BootstrapParser(),
    BootstrapTransport transport = const BootstrapTransport(),
    BootstrapDownload? download,
    this.elapsedMilliseconds,
  }) : download = download ?? transport.download;

  Future<BootstrapOrchestrationResult> resolve({Uri? remoteUri}) {
    final key = remoteUri?.toString() ?? '<not-configured>';
    final existing = _pending[key];
    if (existing != null) return existing;

    final completer = Completer<BootstrapOrchestrationResult>();
    final future = completer.future;
    _pending[key] = future;
    final predecessor = _tail;
    final operation = predecessor.then((_) => _resolve(remoteUri));
    _tail = operation.then<void>((_) {}, onError: (_, __) {});
    operation
        .then(completer.complete, onError: completer.completeError)
        .whenComplete(() {
      if (identical(_pending[key], future)) _pending.remove(key);
    });
    return future;
  }

  Future<BootstrapApplyResult> applyToCoordinator(
    BootstrapOrchestrationResult result,
    ServerCoordinator coordinator,
  ) async {
    if (!result.success || result.effectiveDefinitions.isEmpty) {
      return const BootstrapApplyResult(
        success: false,
        attempted: false,
        applied: false,
        coordinatorListChanged: false,
        failureStage: BootstrapOrchestrationFailureStage.coordinatorApply,
        diagnosticMessage: 'No usable bootstrap definitions to apply.',
        coordinatorResult: null,
      );
    }
    final applied =
        await coordinator.replaceServers(result.effectiveDefinitions);
    return BootstrapApplyResult(
      success: applied.success,
      attempted: true,
      applied: applied.success,
      coordinatorListChanged: applied.changed,
      failureStage: applied.success
          ? BootstrapOrchestrationFailureStage.none
          : BootstrapOrchestrationFailureStage.coordinatorApply,
      diagnosticMessage: applied.diagnosticMessage,
      coordinatorResult: applied,
    );
  }

  Future<BootstrapOrchestrationResult> _resolve(Uri? remoteUri) async {
    final stopwatch =
        elapsedMilliseconds == null ? (Stopwatch()..start()) : null;
    final start = elapsedMilliseconds?.call() ?? 0;
    int elapsed() =>
        (elapsedMilliseconds?.call() ?? stopwatch!.elapsedMilliseconds) - start;

    final embeddedServers = List<BootstrapServer>.unmodifiable(
      embeddedBuckServers.map(_fromDefinition),
    );
    final embeddedParsed = BootstrapParseResult(
      configVersion: null,
      network: 'BUCK',
      servers: embeddedServers,
      validationErrors: const [],
      warnings: const ['Compiled embedded availability fallback.'],
    );
    var source = BootstrapEffectiveSource.embedded;
    var parsed = embeddedParsed;
    var definitions = List<ServerDefinition>.unmodifiable(embeddedBuckServers);
    var cacheAttempt =
        const BootstrapSourceAttempt.notAttempted('Cache not loaded.');
    BootstrapCacheLoadResult? cacheResult;
    var remoteAttempt =
        const BootstrapSourceAttempt.notAttempted('Remote URI not configured.');
    BootstrapDownloadResult? transportResult;
    BootstrapParseResult? remoteParsed;
    var saveAttempt = const BootstrapSourceAttempt.notAttempted(
        'No valid remote document to save.');
    BootstrapCacheSaveResult? saveResult;
    final warnings = <String>[];

    try {
      cacheResult = await cache.load();
      final cacheParsed = cacheResult.parsed;
      if (cacheResult.success &&
          cacheResult.found &&
          cacheParsed != null &&
          cacheParsed.success &&
          _hasEnabled(cacheParsed)) {
        final mapped = _mapEnabled(cacheParsed);
        source = BootstrapEffectiveSource.lastKnownGood;
        parsed = cacheParsed;
        definitions = mapped;
        cacheAttempt = const BootstrapSourceAttempt(
          attempted: true,
          success: true,
          failureStage: BootstrapOrchestrationFailureStage.none,
          diagnosticMessage:
              'Valid Last-Known-Good definitions selected provisionally.',
        );
      } else {
        final allDisabled =
            cacheParsed?.success == true && !_hasEnabled(cacheParsed!);
        cacheAttempt = BootstrapSourceAttempt(
          attempted: true,
          success: false,
          failureStage: BootstrapOrchestrationFailureStage.cacheLoad,
          diagnosticMessage: allDisabled
              ? 'Last-Known-Good document has no enabled servers.'
              : cacheResult.diagnosticMessage,
        );
        if (cacheResult.found) warnings.add(cacheAttempt.diagnosticMessage);
      }
    } catch (_) {
      cacheAttempt = const BootstrapSourceAttempt(
        attempted: true,
        success: false,
        failureStage: BootstrapOrchestrationFailureStage.cacheLoad,
        diagnosticMessage: 'Last-Known-Good cache load failed.',
      );
      warnings.add(cacheAttempt.diagnosticMessage);
    }

    if (remoteUri != null) {
      try {
        transportResult = await download(remoteUri);
        if (!transportResult.success || transportResult.responseText == null) {
          remoteAttempt = BootstrapSourceAttempt(
            attempted: true,
            success: false,
            failureStage: BootstrapOrchestrationFailureStage.remoteDownload,
            diagnosticMessage: transportResult.diagnosticMessage,
          );
          warnings.add(remoteAttempt.diagnosticMessage);
        } else {
          remoteParsed = await parser.parse(transportResult.responseText!);
          if (!remoteParsed.success) {
            remoteAttempt = const BootstrapSourceAttempt(
              attempted: true,
              success: false,
              failureStage: BootstrapOrchestrationFailureStage.remoteParse,
              diagnosticMessage: 'Remote document failed schema validation.',
            );
            warnings.add(remoteAttempt.diagnosticMessage);
          } else if (!_hasEnabled(remoteParsed)) {
            remoteAttempt = const BootstrapSourceAttempt(
              attempted: true,
              success: false,
              failureStage: BootstrapOrchestrationFailureStage.remoteUnusable,
              diagnosticMessage: 'Remote document has no enabled servers.',
            );
            warnings.add(remoteAttempt.diagnosticMessage);
          } else {
            definitions = _mapEnabled(remoteParsed);
            source = BootstrapEffectiveSource.remote;
            parsed = remoteParsed;
            remoteAttempt = const BootstrapSourceAttempt(
              attempted: true,
              success: true,
              failureStage: BootstrapOrchestrationFailureStage.none,
              diagnosticMessage: 'Valid remote definitions selected.',
            );
            try {
              saveResult = await cache.saveValidated(
                document: transportResult.responseText!,
                parsed: remoteParsed,
              );
              saveAttempt = BootstrapSourceAttempt(
                attempted: true,
                success: saveResult.success,
                failureStage: saveResult.success
                    ? BootstrapOrchestrationFailureStage.none
                    : BootstrapOrchestrationFailureStage.cacheSave,
                diagnosticMessage: saveResult.diagnosticMessage,
              );
              if (!saveResult.success)
                warnings.add(saveResult.diagnosticMessage);
            } catch (_) {
              saveAttempt = const BootstrapSourceAttempt(
                attempted: true,
                success: false,
                failureStage: BootstrapOrchestrationFailureStage.cacheSave,
                diagnosticMessage: 'Valid remote document could not be cached.',
              );
              warnings.add(saveAttempt.diagnosticMessage);
            }
          }
        }
      } catch (_) {
        remoteAttempt = const BootstrapSourceAttempt(
          attempted: true,
          success: false,
          failureStage: BootstrapOrchestrationFailureStage.remoteDownload,
          diagnosticMessage: 'Remote bootstrap download failed.',
        );
        warnings.add(remoteAttempt.diagnosticMessage);
      }
    }

    stopwatch?.stop();
    return BootstrapOrchestrationResult(
      success: definitions.isNotEmpty,
      effectiveSource: source,
      effectiveParseResult: parsed,
      effectiveServers: parsed.servers,
      effectiveDefinitions: definitions,
      embeddedAvailable: embeddedServers.isNotEmpty,
      cacheAttempt: cacheAttempt,
      cacheLoadResult: cacheResult,
      remoteAttempt: remoteAttempt,
      remoteTransportResult: transportResult,
      remoteParseResult: remoteParsed,
      cacheSaveAttempt: saveAttempt,
      cacheSaveResult: saveResult,
      warnings: warnings,
      elapsedMilliseconds: elapsed(),
      remoteUriConfigured: remoteUri != null,
    );
  }

  static bool _hasEnabled(BootstrapParseResult parsed) =>
      parsed.servers.any((server) => server.enabled);

  static List<ServerDefinition> _mapEnabled(BootstrapParseResult parsed) {
    final mapped = parsed.servers
        .where((server) => server.enabled)
        .map((server) => ServerDefinition(
              id: server.id,
              name: server.displayName,
              url: server.grpcUrl.toString(),
              priority: server.priority,
              enabled: server.enabled,
            ))
        .toList()
      ..sort((left, right) {
        final priority = left.priority.compareTo(right.priority);
        return priority != 0 ? priority : left.id.compareTo(right.id);
      });
    return List.unmodifiable(mapped);
  }

  static BootstrapServer _fromDefinition(ServerDefinition definition) =>
      BootstrapServer(
        id: definition.id,
        displayName: definition.name,
        grpcUrl: Uri.parse(definition.url),
        priority: definition.priority,
        enabled: definition.enabled,
      );
}
