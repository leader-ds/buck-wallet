import 'package:warp_api/server_coordinator.dart';

import 'bootstrap_lkg_cache_models.dart';
import 'bootstrap_parse_models.dart';
import 'bootstrap_transport.dart';

enum BootstrapEffectiveSource { embedded, lastKnownGood, remote }

enum BootstrapOrchestrationFailureStage {
  none,
  cacheLoad,
  remoteDownload,
  remoteParse,
  remoteUnusable,
  cacheSave,
  mapping,
  coordinatorApply,
  unavailable,
  unknown,
}

class BootstrapSourceAttempt {
  final bool attempted;
  final bool success;
  final BootstrapOrchestrationFailureStage failureStage;
  final String diagnosticMessage;

  const BootstrapSourceAttempt({
    required this.attempted,
    required this.success,
    required this.failureStage,
    required this.diagnosticMessage,
  });

  const BootstrapSourceAttempt.notAttempted(String message)
      : this(
          attempted: false,
          success: false,
          failureStage: BootstrapOrchestrationFailureStage.none,
          diagnosticMessage: message,
        );
}

class BootstrapOrchestrationResult {
  final bool success;
  final BootstrapEffectiveSource effectiveSource;
  final BootstrapParseResult effectiveParseResult;
  final List<BootstrapServer> effectiveServers;
  final List<ServerDefinition> effectiveDefinitions;
  final bool embeddedAvailable;
  final BootstrapSourceAttempt cacheAttempt;
  final BootstrapCacheLoadResult? cacheLoadResult;
  final BootstrapSourceAttempt remoteAttempt;
  final BootstrapDownloadResult? remoteTransportResult;
  final BootstrapParseResult? remoteParseResult;
  final BootstrapSourceAttempt cacheSaveAttempt;
  final BootstrapCacheSaveResult? cacheSaveResult;
  final List<String> warnings;
  final int elapsedMilliseconds;
  final bool remoteUriConfigured;

  BootstrapOrchestrationResult({
    required this.success,
    required this.effectiveSource,
    required this.effectiveParseResult,
    required List<BootstrapServer> effectiveServers,
    required List<ServerDefinition> effectiveDefinitions,
    required this.embeddedAvailable,
    required this.cacheAttempt,
    required this.cacheLoadResult,
    required this.remoteAttempt,
    required this.remoteTransportResult,
    required this.remoteParseResult,
    required this.cacheSaveAttempt,
    required this.cacheSaveResult,
    required List<String> warnings,
    required this.elapsedMilliseconds,
    required this.remoteUriConfigured,
  })  : effectiveServers = List.unmodifiable(effectiveServers),
        effectiveDefinitions = List.unmodifiable(effectiveDefinitions),
        warnings = List.unmodifiable(warnings);
}

class BootstrapApplyResult {
  final bool success;
  final bool attempted;
  final bool applied;
  final bool coordinatorListChanged;
  final BootstrapOrchestrationFailureStage failureStage;
  final String diagnosticMessage;
  final ServerDefinitionsApplyResult? coordinatorResult;

  const BootstrapApplyResult({
    required this.success,
    required this.attempted,
    required this.applied,
    required this.coordinatorListChanged,
    required this.failureStage,
    required this.diagnosticMessage,
    required this.coordinatorResult,
  });
}
