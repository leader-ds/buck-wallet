import 'bootstrap_orchestration_models.dart';

enum BootstrapStartupFailureStage {
  none,
  composition,
  resolve,
  apply,
  unexpected
}

class BootstrapStartupResult {
  final bool started;
  final bool completed;
  final bool coalesced;
  final BootstrapOrchestrationResult? orchestrationResult;
  final BootstrapApplyResult? applyResult;
  final BootstrapEffectiveSource? effectiveSource;
  final bool success;
  final bool definitionsApplied;
  final bool coordinatorListChanged;
  final bool remoteConfigured;
  final BootstrapStartupFailureStage failureStage;
  final String diagnosticMessage;
  final int elapsedMilliseconds;

  const BootstrapStartupResult({
    required this.started,
    required this.completed,
    required this.coalesced,
    required this.orchestrationResult,
    required this.applyResult,
    required this.effectiveSource,
    required this.success,
    required this.definitionsApplied,
    required this.coordinatorListChanged,
    required this.remoteConfigured,
    required this.failureStage,
    required this.diagnosticMessage,
    required this.elapsedMilliseconds,
  });
}

class BootstrapRemoteConfiguration {
  final Uri? remoteUri;
  final bool configured;
  final String diagnosticMessage;

  const BootstrapRemoteConfiguration({
    required this.remoteUri,
    required this.configured,
    required this.diagnosticMessage,
  });
}
