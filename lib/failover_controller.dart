import 'package:warp_api/server_coordinator.dart';

import 'runtime_server_transition.dart';

typedef FailoverMonotonicClock = Duration Function();

enum FailoverHealthState {
  healthy,
  suspect,
  failed,
  transitioning,
  secondaryActive,
}

/// Decides whether already-observed server health warrants a runtime switch.
///
/// State transitions are:
/// * healthy -> suspect after two consecutive unhealthy active-server probes;
/// * suspect -> failed after three consecutive unhealthy probes;
/// * failed -> transitioning when an eligible healthy candidate exists;
/// * transitioning -> secondaryActive after a successful switch;
/// * transitioning -> failed after any unsuccessful switch, including rollback;
/// * healthy/suspect/failed -> healthy after a successful active-server probe.
///
/// Once secondaryActive is reached, recovery of the preferred server is only
/// recorded. Automatic preferred-server recovery is deliberately out of scope.
class FailoverController {
  static const suspectThreshold = 2;
  static const failedThreshold = 3;
  static const defaultCooldown = Duration(seconds: 60);

  final ServerCoordinator serverCoordinator;
  final RuntimeServerTransition runtimeServerTransition;
  final FailoverMonotonicClock monotonicClock;
  final Duration cooldown;

  FailoverHealthState _state = FailoverHealthState.healthy;
  int _consecutiveFailedProbes = 0;
  int _consecutiveRuntimeSyncFailures = 0;
  Duration? _lastTransitionAttemptAt;
  Future<ServerTransitionResult>? _transitionInFlight;
  ServerTransitionResult? _lastTransitionResult;
  bool _preferredServerRecovered = false;
  bool _automaticFailoverCompleted = false;
  String? _lastObservedActiveServerId;

  FailoverController({
    required this.serverCoordinator,
    required this.runtimeServerTransition,
    required this.monotonicClock,
    this.cooldown = defaultCooldown,
  });

  FailoverHealthState get state => _state;
  int get consecutiveFailedProbes => _consecutiveFailedProbes;
  int get consecutiveRuntimeSyncFailures => _consecutiveRuntimeSyncFailures;
  bool get preferredServerRecovered => _preferredServerRecovered;
  bool get transitionInProgress => _transitionInFlight != null;
  ServerTransitionResult? get lastTransitionResult => _lastTransitionResult;

  void observeRuntimeSyncFailure() {
    _consecutiveRuntimeSyncFailures++;
  }

  void observeRuntimeSyncSuccess() {
    _consecutiveRuntimeSyncFailures = 0;
  }

  /// Observes the latest completed [ServerCoordinator.refresh] results.
  ///
  /// This method never initiates probing. The caller supplies the active
  /// runtime context and chooses an existing scheduling opportunity on which
  /// the coordinator is refreshed.
  Future<ServerTransitionResult?> observeProbeResults({
    required int coin,
    required String activeUrl,
  }) async {
    final inFlight = _transitionInFlight;
    if (inFlight != null) return inFlight;

    final activeStatus = _statusForUrl(activeUrl);
    final activeServerId = activeStatus?.server.id;
    if (activeServerId != _lastObservedActiveServerId) {
      _consecutiveFailedProbes = 0;
      _lastObservedActiveServerId = activeServerId;
    }
    if (activeStatus == null ||
        activeStatus.healthState == ServerHealthState.unknown ||
        activeStatus.healthState == ServerHealthState.checking) {
      return null;
    }

    final activeIsHealthy =
        activeStatus.healthState == ServerHealthState.healthy &&
            activeStatus.validationResult?.isValid == true;
    if (activeIsHealthy) {
      _consecutiveFailedProbes = 0;
      if (_automaticFailoverCompleted) {
        _state = FailoverHealthState.secondaryActive;
        _recordPreferredRecovery(activeUrl);
      } else {
        _state = FailoverHealthState.healthy;
      }
      return null;
    }

    _consecutiveFailedProbes++;
    if (_consecutiveFailedProbes < suspectThreshold) {
      return null;
    }
    if (_consecutiveFailedProbes < failedThreshold) {
      _state = FailoverHealthState.suspect;
      return null;
    }
    _state = FailoverHealthState.failed;

    if (_automaticFailoverCompleted || !_cooldownExpired()) return null;

    final candidate = serverCoordinator.selectedCandidate;
    if (candidate == null || _sameUrl(candidate.url, activeUrl)) return null;
    final candidateStatus = _statusForServer(candidate);
    if (candidateStatus == null ||
        candidateStatus.healthState != ServerHealthState.healthy ||
        candidateStatus.validationResult?.isValid != true) {
      return null;
    }

    _state = FailoverHealthState.transitioning;
    final transition = runtimeServerTransition.switchServer(
      coin: coin,
      targetUrl: candidate.url,
    );
    _transitionInFlight = transition;
    _lastTransitionAttemptAt = monotonicClock();
    try {
      final result = await transition;
      _lastTransitionResult = result;
      if (result.success && !result.noOp) {
        _automaticFailoverCompleted = true;
        _consecutiveFailedProbes = 0;
        _state = FailoverHealthState.secondaryActive;
      } else {
        _state = FailoverHealthState.failed;
      }
      return result;
    } finally {
      if (identical(_transitionInFlight, transition)) {
        _transitionInFlight = null;
      }
    }
  }

  bool _cooldownExpired() {
    final attemptedAt = _lastTransitionAttemptAt;
    return attemptedAt == null || monotonicClock() - attemptedAt >= cooldown;
  }

  void _recordPreferredRecovery(String activeUrl) {
    final preferred = serverCoordinator.preferredHealthyServer;
    if (preferred != null &&
        preferred.priority < _priorityForUrl(activeUrl) &&
        !_sameUrl(preferred.url, activeUrl)) {
      _preferredServerRecovered = true;
    }
  }

  int _priorityForUrl(String url) {
    for (final server in serverCoordinator.servers) {
      if (_sameUrl(server.url, url)) return server.priority;
    }
    return 1 << 30;
  }

  ServerStatus? _statusForUrl(String url) {
    for (final status in serverCoordinator.statuses) {
      if (_sameUrl(status.server.url, url)) return status;
    }
    return null;
  }

  ServerStatus? _statusForServer(ServerDefinition server) {
    for (final status in serverCoordinator.statuses) {
      if (identical(status.server, server) || status.server.id == server.id) {
        return status;
      }
    }
    return null;
  }

  bool _sameUrl(String first, String second) {
    try {
      return normalizeLightwalletUrl(first) == normalizeLightwalletUrl(second);
    } catch (_) {
      return first.trim() == second.trim();
    }
  }
}
