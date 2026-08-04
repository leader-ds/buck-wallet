import 'dart:async';

import 'package:warp_api/server_probe.dart';

import 'sync_lifecycle_coordinator.dart';

enum ServerTransitionFailureStage {
  invalidRequest,
  probe,
  validation,
  contextChanged,
  cancellation,
  apply,
  verification,
  rollback,
  refresh,
  unknown,
}

class ServerTransitionResult {
  final int requestedCoin;
  final String previousUrl;
  final String targetUrl;
  final bool success;
  final bool noOp;
  final ServerProbeResult? probeResult;
  final BuckServerValidationResult? validationResult;
  final ServerTransitionFailureStage? failureStage;
  final String? errorMessage;
  final bool rollbackAttempted;
  final bool? rollbackSucceeded;
  final String? configuredUrl;
  final int elapsedMilliseconds;

  const ServerTransitionResult({
    required this.requestedCoin,
    required this.previousUrl,
    required this.targetUrl,
    required this.success,
    required this.noOp,
    required this.probeResult,
    required this.validationResult,
    required this.failureStage,
    required this.errorMessage,
    required this.rollbackAttempted,
    required this.rollbackSucceeded,
    required this.configuredUrl,
    required this.elapsedMilliseconds,
  });

  ServerTransitionResult withElapsed(int milliseconds) =>
      ServerTransitionResult(
        requestedCoin: requestedCoin,
        previousUrl: previousUrl,
        targetUrl: targetUrl,
        success: success,
        noOp: noOp,
        probeResult: probeResult,
        validationResult: validationResult,
        failureStage: failureStage,
        errorMessage: errorMessage,
        rollbackAttempted: rollbackAttempted,
        rollbackSucceeded: rollbackSucceeded,
        configuredUrl: configuredUrl,
        elapsedMilliseconds: milliseconds,
      );
}

typedef RuntimeServerProbe = Future<ServerProbeResult> Function(String url);
typedef RuntimeServerSetter = void Function(int coin, String url);
typedef RuntimeServerGetter = String Function(int coin);
typedef RuntimeServerSettingsCommit = void Function(int coin, String url);
typedef RuntimeServerStateReset = void Function();

class RuntimeServerTransition {
  final SyncLifecycleCoordinator lifecycle;
  final RuntimeServerProbe probeServer;
  final RuntimeServerSetter updateLwd;
  final RuntimeServerGetter getLwd;
  final RuntimeServerSettingsCommit commitSettings;
  final RuntimeServerStateReset resetState;

  const RuntimeServerTransition({
    required this.lifecycle,
    required this.probeServer,
    required this.updateLwd,
    required this.getLwd,
    required this.commitSettings,
    required this.resetState,
  });

  Future<ServerTransitionResult> switchServer({
    required int coin,
    required String targetUrl,
  }) async {
    final stopwatch = Stopwatch()..start();
    final capturedToken = lifecycle.currentToken;
    final previousRaw = getLwd(coin);
    Uri target;
    Uri previous;
    try {
      target = normalizeLightwalletUrl(targetUrl);
      previous = normalizeLightwalletUrl(previousRaw);
    } catch (error) {
      return _result(
        coin: coin,
        previousUrl: previousRaw,
        targetUrl: targetUrl,
        stage: ServerTransitionFailureStage.invalidRequest,
        message: error.toString(),
        configuredUrl: previousRaw,
        elapsed: stopwatch.elapsedMilliseconds,
      );
    }

    if (target == previous) {
      return _result(
        coin: coin,
        previousUrl: previous.toString(),
        targetUrl: target.toString(),
        success: true,
        noOp: true,
        configuredUrl: previous.toString(),
        elapsed: stopwatch.elapsedMilliseconds,
      );
    }

    ServerProbeResult probe;
    try {
      probe = await probeServer(target.toString());
    } catch (error) {
      return _result(
        coin: coin,
        previousUrl: previous.toString(),
        targetUrl: target.toString(),
        stage: ServerTransitionFailureStage.probe,
        message: error.toString(),
        configuredUrl: previous.toString(),
        elapsed: stopwatch.elapsedMilliseconds,
      );
    }
    if (!probe.success) {
      return _result(
        coin: coin,
        previousUrl: previous.toString(),
        targetUrl: target.toString(),
        probe: probe,
        stage: ServerTransitionFailureStage.probe,
        message: probe.errorMessage ?? 'Server probe failed',
        configuredUrl: previous.toString(),
        elapsed: stopwatch.elapsedMilliseconds,
      );
    }
    final validation = validateBuckServerProbe(probe);
    if (!validation.isValid) {
      return _result(
        coin: coin,
        previousUrl: previous.toString(),
        targetUrl: target.toString(),
        probe: probe,
        validation: validation,
        stage: ServerTransitionFailureStage.validation,
        message: validation.failures.join('; '),
        configuredUrl: previous.toString(),
        elapsed: stopwatch.elapsedMilliseconds,
      );
    }

    try {
      final execution =
          await lifecycle.runServerTransition<ServerTransitionResult>(
        contextMatches: (token) =>
            token.coin == capturedToken.coin &&
            token.accountId == capturedToken.accountId &&
            identical(token.account, capturedToken.account) &&
            coin == capturedToken.coin,
        mutation: () async {
          try {
            updateLwd(coin, target.toString());
          } catch (error) {
            var rollbackSucceeded = false;
            String? afterRollback;
            Object? rollbackError;
            try {
              updateLwd(coin, previous.toString());
              afterRollback = _safeGet(coin);
              rollbackSucceeded = _sameUrl(afterRollback, previous);
            } catch (rollbackFailure) {
              rollbackError = rollbackFailure;
              afterRollback = _safeGet(coin);
            }
            if (rollbackSucceeded) resetState();
            return SyncLifecycleServerMutation(
              _result(
                coin: coin,
                previousUrl: previous.toString(),
                targetUrl: target.toString(),
                probe: probe,
                validation: validation,
                stage: rollbackSucceeded
                    ? ServerTransitionFailureStage.apply
                    : ServerTransitionFailureStage.rollback,
                message: rollbackSucceeded
                    ? '$error; rollback succeeded'
                    : '$error; rollback failed${rollbackError == null ? '' : ': $rollbackError'}',
                rollbackAttempted: true,
                rollbackSucceeded: rollbackSucceeded,
                configuredUrl: afterRollback,
                elapsed: 0,
              ),
              rollbackSucceeded
                  ? SyncLifecycleResumePolicy.sync
                  : SyncLifecycleResumePolicy.blocked,
            );
          }

          final configured = _safeGet(coin);
          if (!_sameUrl(configured, target)) {
            var rollbackSucceeded = false;
            String? afterRollback;
            Object? rollbackError;
            try {
              updateLwd(coin, previous.toString());
              afterRollback = _safeGet(coin);
              rollbackSucceeded = _sameUrl(afterRollback, previous);
            } catch (error) {
              rollbackError = error;
              afterRollback = _safeGet(coin);
            }
            final failed = _result(
              coin: coin,
              previousUrl: previous.toString(),
              targetUrl: target.toString(),
              probe: probe,
              validation: validation,
              stage: rollbackSucceeded
                  ? ServerTransitionFailureStage.verification
                  : ServerTransitionFailureStage.rollback,
              message: rollbackSucceeded
                  ? 'Configured URL did not match target; rollback succeeded'
                  : 'Configured URL did not match target; rollback failed${rollbackError == null ? '' : ': $rollbackError'}',
              rollbackAttempted: true,
              rollbackSucceeded: rollbackSucceeded,
              configuredUrl: afterRollback,
              elapsed: 0,
            );
            if (rollbackSucceeded) resetState();
            return SyncLifecycleServerMutation(
              failed,
              rollbackSucceeded
                  ? SyncLifecycleResumePolicy.sync
                  : SyncLifecycleResumePolicy.blocked,
            );
          }

          commitSettings(coin, target.toString());
          resetState();
          return SyncLifecycleServerMutation(
            _result(
              coin: coin,
              previousUrl: previous.toString(),
              targetUrl: target.toString(),
              success: true,
              probe: probe,
              validation: validation,
              configuredUrl: configured,
              elapsed: 0,
            ),
            SyncLifecycleResumePolicy.sync,
          );
        },
      );
      var result = execution.value;
      if (execution.refreshError != null && result.success) {
        result = _result(
          coin: coin,
          previousUrl: previous.toString(),
          targetUrl: target.toString(),
          probe: probe,
          validation: validation,
          stage: ServerTransitionFailureStage.refresh,
          message: execution.refreshError.toString(),
          configuredUrl: _safeGet(coin),
          elapsed: 0,
        );
      }
      return result.withElapsed(stopwatch.elapsedMilliseconds);
    } on SyncLifecycleContextChanged {
      return _result(
        coin: coin,
        previousUrl: previous.toString(),
        targetUrl: target.toString(),
        probe: probe,
        validation: validation,
        stage: ServerTransitionFailureStage.contextChanged,
        message: 'Active coin or account changed before mutation',
        configuredUrl: _safeGet(coin),
        elapsed: stopwatch.elapsedMilliseconds,
      );
    } on SyncLifecycleCancellationFailed catch (error) {
      return _result(
        coin: coin,
        previousUrl: previous.toString(),
        targetUrl: target.toString(),
        probe: probe,
        validation: validation,
        stage: ServerTransitionFailureStage.cancellation,
        message: error.error.toString(),
        configuredUrl: _safeGet(coin),
        elapsed: stopwatch.elapsedMilliseconds,
      );
    } catch (error) {
      return _result(
        coin: coin,
        previousUrl: previous.toString(),
        targetUrl: target.toString(),
        probe: probe,
        validation: validation,
        stage: ServerTransitionFailureStage.unknown,
        message: error.toString(),
        configuredUrl: _safeGet(coin),
        elapsed: stopwatch.elapsedMilliseconds,
      );
    }
  }

  String? _safeGet(int coin) {
    try {
      return getLwd(coin);
    } catch (_) {
      return null;
    }
  }

  bool _sameUrl(String? value, Uri expected) {
    if (value == null) return false;
    try {
      return normalizeLightwalletUrl(value) == expected;
    } catch (_) {
      return false;
    }
  }
}

Uri normalizeLightwalletUrl(String value) {
  final parsed = Uri.parse(value.trim());
  final scheme = parsed.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') || parsed.host.isEmpty) {
    throw const FormatException('Lightwallet URL requires http(s) and a host');
  }
  if (parsed.userInfo.isNotEmpty ||
      parsed.query.isNotEmpty ||
      parsed.hasFragment) {
    throw const FormatException(
        'Lightwallet URL cannot contain credentials, query, or fragment');
  }
  final path = parsed.path == '/' ? '' : parsed.path;
  return parsed.replace(
      scheme: scheme, host: parsed.host.toLowerCase(), path: path);
}

ServerTransitionResult _result({
  required int coin,
  required String previousUrl,
  required String targetUrl,
  bool success = false,
  bool noOp = false,
  ServerProbeResult? probe,
  BuckServerValidationResult? validation,
  ServerTransitionFailureStage? stage,
  String? message,
  bool rollbackAttempted = false,
  bool? rollbackSucceeded,
  String? configuredUrl,
  required int elapsed,
}) =>
    ServerTransitionResult(
      requestedCoin: coin,
      previousUrl: previousUrl,
      targetUrl: targetUrl,
      success: success,
      noOp: noOp,
      probeResult: probe,
      validationResult: validation,
      failureStage: stage,
      errorMessage: message,
      rollbackAttempted: rollbackAttempted,
      rollbackSucceeded: rollbackSucceeded,
      configuredUrl: configuredUrl,
      elapsedMilliseconds: elapsed,
    );
