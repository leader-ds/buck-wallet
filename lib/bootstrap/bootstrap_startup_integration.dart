import 'dart:async';

import 'package:warp_api/server_coordinator.dart';

import 'bootstrap_orchestrator.dart';
import 'bootstrap_startup_models.dart';

export 'bootstrap_startup_models.dart';

typedef BootstrapResolve = Future<BootstrapOrchestrationResult> Function({
  Uri? remoteUri,
});
typedef BootstrapApply = Future<BootstrapApplyResult> Function(
  BootstrapOrchestrationResult result,
  ServerCoordinator coordinator,
);
typedef BootstrapStartupElapsedMilliseconds = int Function();

BootstrapRemoteConfiguration parseBootstrapRemoteConfiguration(String value) {
  if (value.trim().isEmpty) {
    return const BootstrapRemoteConfiguration(
      remoteUri: null,
      configured: false,
      diagnosticMessage: 'Remote bootstrap URI is not configured.',
    );
  }
  try {
    final uri = Uri.parse(value);
    if (!uri.isAbsolute ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException();
    }
    return BootstrapRemoteConfiguration(
      remoteUri: uri,
      configured: true,
      diagnosticMessage: 'Remote bootstrap URI is configured for ${uri.host}.',
    );
  } on FormatException {
    return const BootstrapRemoteConfiguration(
      remoteUri: null,
      configured: true,
      diagnosticMessage: 'Remote bootstrap URI configuration is invalid.',
    );
  }
}

/// Runs the bootstrap resolve/apply pipeline once without touching runtime state.
///
/// This only replaces validated coordinator definitions. It owns no timer and
/// never probes, synchronizes, changes the active lightwallet URL, or invokes
/// failover/runtime transition APIs.
class BootstrapStartupIntegration {
  final BootstrapOrchestrator orchestrator;
  final ServerCoordinator coordinator;
  final Uri? remoteUri;
  final bool remoteConfigured;
  final String configurationDiagnostic;
  final BootstrapResolve _resolve;
  final BootstrapApply _apply;
  final BootstrapStartupElapsedMilliseconds? elapsedMilliseconds;

  Future<BootstrapStartupResult>? _operation;
  bool _coalesced = false;

  BootstrapStartupIntegration({
    required this.orchestrator,
    required this.coordinator,
    required this.remoteUri,
    bool? remoteConfigured,
    this.configurationDiagnostic = 'Bootstrap configuration accepted.',
    BootstrapResolve? resolve,
    BootstrapApply? apply,
    this.elapsedMilliseconds,
  })  : remoteConfigured = remoteConfigured ?? remoteUri != null,
        _resolve = resolve ?? orchestrator.resolve,
        _apply = apply ?? orchestrator.applyToCoordinator;

  Future<BootstrapStartupResult> start() {
    final existing = _operation;
    if (existing != null) {
      _coalesced = true;
      return existing;
    }
    final completer = Completer<BootstrapStartupResult>();
    _operation = completer.future;
    _run().then(completer.complete, onError: (Object error, StackTrace stack) {
      completer.complete(_unexpectedResult(error, 0));
    });
    return _operation!;
  }

  Future<BootstrapStartupResult> _run() async {
    final stopwatch =
        elapsedMilliseconds == null ? (Stopwatch()..start()) : null;
    final startedAt = elapsedMilliseconds?.call() ?? 0;
    int elapsed() =>
        (elapsedMilliseconds?.call() ?? stopwatch!.elapsedMilliseconds) -
        startedAt;

    BootstrapOrchestrationResult orchestration;
    try {
      orchestration = await _resolve(remoteUri: remoteUri);
    } catch (error) {
      stopwatch?.stop();
      return _failure(
        BootstrapStartupFailureStage.unexpected,
        'Bootstrap resolution failed unexpectedly (${error.runtimeType}).',
        elapsed(),
      );
    }

    BootstrapApplyResult applied;
    try {
      applied = await _apply(orchestration, coordinator);
    } catch (error) {
      stopwatch?.stop();
      return _failure(
        BootstrapStartupFailureStage.apply,
        'Bootstrap coordinator application failed (${error.runtimeType}).',
        elapsed(),
        orchestration: orchestration,
      );
    }
    stopwatch?.stop();
    final success = orchestration.success && applied.success;
    return BootstrapStartupResult(
      started: true,
      completed: true,
      coalesced: _coalesced,
      orchestrationResult: orchestration,
      applyResult: applied,
      effectiveSource: orchestration.effectiveSource,
      success: success,
      definitionsApplied: applied.applied,
      coordinatorListChanged: applied.coordinatorListChanged,
      remoteConfigured: remoteConfigured,
      failureStage: success
          ? BootstrapStartupFailureStage.none
          : BootstrapStartupFailureStage.apply,
      diagnosticMessage: success
          ? '${applied.diagnosticMessage} $configurationDiagnostic'
          : applied.diagnosticMessage,
      elapsedMilliseconds: elapsed(),
    );
  }

  BootstrapStartupResult _failure(
    BootstrapStartupFailureStage stage,
    String message,
    int elapsed, {
    BootstrapOrchestrationResult? orchestration,
  }) =>
      BootstrapStartupResult(
        started: true,
        completed: true,
        coalesced: _coalesced,
        orchestrationResult: orchestration,
        applyResult: null,
        effectiveSource: orchestration?.effectiveSource,
        success: false,
        definitionsApplied: false,
        coordinatorListChanged: false,
        remoteConfigured: remoteConfigured,
        failureStage: stage,
        diagnosticMessage: message,
        elapsedMilliseconds: elapsed,
      );

  BootstrapStartupResult _unexpectedResult(Object error, int elapsed) =>
      _failure(
        BootstrapStartupFailureStage.unexpected,
        'Bootstrap startup failed unexpectedly (${error.runtimeType}).',
        elapsed,
      );
}
