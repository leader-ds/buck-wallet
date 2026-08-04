import 'dart:async';

typedef SyncLifecycleAccountProvider = SyncLifecycleAccount Function();
typedef SyncLifecycleRun = Future<void> Function(
  SyncLifecycleToken token, {
  required bool getTx,
  required bool auto,
});
typedef SyncLifecycleCancel = void Function();
typedef SyncLifecycleTimerFactory = SyncLifecycleTimer Function(
  Duration interval,
  void Function() callback,
);
typedef SyncLifecycleAutomaticRefresh = void Function(
  SyncLifecycleToken token,
);
typedef SyncLifecycleAutomaticError = void Function(
  Object error,
  StackTrace stackTrace,
);
typedef SyncLifecycleMutation<T> = FutureOr<T> Function();

enum SyncLifecycleResumePolicy { sync, idle, blocked }

class SyncLifecycleServerMutation<T> {
  final T value;
  final SyncLifecycleResumePolicy resumePolicy;

  const SyncLifecycleServerMutation(this.value, this.resumePolicy);
}

class SyncLifecycleServerExecution<T> {
  final T value;
  final Object? refreshError;
  final StackTrace? refreshStackTrace;

  const SyncLifecycleServerExecution(
    this.value, {
    this.refreshError,
    this.refreshStackTrace,
  });
}

class SyncLifecycleContextChanged implements Exception {
  const SyncLifecycleContextChanged();
}

class SyncLifecycleCancellationFailed implements Exception {
  final Object error;
  final StackTrace stackTrace;

  const SyncLifecycleCancellationFailed(this.error, this.stackTrace);
}

abstract interface class SyncLifecycleTimer {
  void cancel();
}

class SyncLifecycleAccount {
  final int coin;
  final int accountId;
  final Object account;

  const SyncLifecycleAccount({
    required this.coin,
    required this.accountId,
    required this.account,
  });
}

class SyncLifecycleToken {
  final int generation;
  final int coin;
  final int accountId;
  final Object account;

  const SyncLifecycleToken({
    required this.generation,
    required this.coin,
    required this.accountId,
    required this.account,
  });
}

class _DartSyncLifecycleTimer implements SyncLifecycleTimer {
  final Timer _timer;

  _DartSyncLifecycleTimer(this._timer);

  @override
  void cancel() => _timer.cancel();
}

class _InFlightSync {
  final SyncLifecycleToken token;
  final Completer<void> completer;
  bool cancellationRequested = false;

  _InFlightSync(this.token, this.completer);

  Future<void> get future => completer.future;
}

class SyncLifecycleCoordinator {
  static const automaticSyncInterval = Duration(seconds: 15);

  final SyncLifecycleAccountProvider _accountProvider;
  final SyncLifecycleRun _sync;
  final SyncLifecycleCancel _cancel;
  final SyncLifecycleTimerFactory _timerFactory;
  final SyncLifecycleAutomaticRefresh? _automaticRefresh;
  final SyncLifecycleAutomaticError? _automaticError;

  late SyncLifecycleToken _currentToken;
  _InFlightSync? _inFlight;
  SyncLifecycleTimer? _automaticTimer;
  Future<void>? _cancellationTransition;
  Future<void> _transitionTail = Future<void>.value();
  int _pendingAccountTransitions = 0;
  int _pendingServerTransitions = 0;
  bool _accountInstalledDuringBatch = false;
  bool _transitioning = false;
  bool _criticallyBlocked = false;

  SyncLifecycleCoordinator({
    required SyncLifecycleAccountProvider accountProvider,
    required SyncLifecycleRun sync,
    required SyncLifecycleCancel cancel,
    SyncLifecycleTimerFactory? timerFactory,
    SyncLifecycleAutomaticRefresh? automaticRefresh,
    SyncLifecycleAutomaticError? automaticError,
    int initialGeneration = 0,
  })  : _accountProvider = accountProvider,
        _sync = sync,
        _cancel = cancel,
        _timerFactory = timerFactory ?? _createTimer,
        _automaticRefresh = automaticRefresh,
        _automaticError = automaticError {
    _currentToken = _captureToken(initialGeneration);
  }

  static SyncLifecycleTimer _createTimer(
    Duration interval,
    void Function() callback,
  ) =>
      _DartSyncLifecycleTimer(Timer.periodic(interval, (_) => callback()));

  SyncLifecycleToken get currentToken => _currentToken;
  Future<void>? get inFlight => _inFlight?.future;
  SyncLifecycleToken? get authoritativeToken => _inFlight?.token;
  bool get hasAutomaticTimer => _automaticTimer != null;
  bool get isTransitioning => _transitioning;

  bool owns(SyncLifecycleToken token) =>
      identical(token, _currentToken) &&
      token.generation == _currentToken.generation &&
      identical(token.account, _currentToken.account) &&
      token.coin == _currentToken.coin &&
      token.accountId == _currentToken.accountId;

  bool ownsAuthoritativeRun(SyncLifecycleToken token) {
    final active = _inFlight;
    return active != null && identical(active.token, token) && owns(token);
  }

  Future<void> requestSync({required bool getTx, required bool auto}) {
    final active = _inFlight;
    if (active != null) return active.future;
    if (_transitioning) return Future<void>.value();

    final token = _currentToken;
    final operation = _InFlightSync(token, Completer<void>());
    // The authoritative slot is claimed before user code or an await can run.
    _inFlight = operation;
    _execute(operation, getTx: getTx, auto: auto);
    return operation.future;
  }

  Future<void> _execute(
    _InFlightSync operation, {
    required bool getTx,
    required bool auto,
  }) async {
    Object? error;
    StackTrace? stackTrace;
    try {
      await _sync(operation.token, getTx: getTx, auto: auto);
    } catch (e, s) {
      error = e;
      stackTrace = s;
    } finally {
      if (identical(_inFlight, operation)) _inFlight = null;
    }
    if (error == null) {
      operation.completer.complete();
    } else {
      operation.completer.completeError(error, stackTrace!);
    }
  }

  Future<void> cancelAndAwaitCurrent() {
    final existing = _cancellationTransition;
    if (existing != null) return existing;

    final transition = Completer<void>();
    _cancellationTransition = transition.future;
    _beginCancellation(transition);
    return transition.future;
  }

  /// Runs account mutations in deterministic FIFO order.
  ///
  /// Submission invalidates lifecycle ownership and blocks sync immediately.
  /// Every submitted mutation is retained; distinct selections are never
  /// silently combined. A successful final transition starts one coordinator-
  /// owned sync request without recreating the automatic timer.
  Future<T> runAccountTransition<T>(SyncLifecycleMutation<T> mutation) {
    final result = Completer<T>();
    if (_pendingAccountTransitions == 0) {
      _accountInstalledDuringBatch = false;
    }
    _pendingAccountTransitions++;
    _transitioning = true;
    _invalidate();
    final cancellation = _cancelForAccountTransition();

    final predecessor = _transitionTail;
    final queued = predecessor.catchError((Object _) {}).then<void>((_) async {
      try {
        await cancellation;
        final value = await mutation();
        _currentToken = _captureToken(_currentToken.generation + 1);
        _accountInstalledDuringBatch = true;
        result.complete(value);
      } catch (error, stackTrace) {
        // The mutation contract requires global replacement to be atomic. On
        // failure, recapture whichever valid account the provider still owns.
        _currentToken = _captureToken(_currentToken.generation + 1);
        result.completeError(error, stackTrace);
      } finally {
        _pendingAccountTransitions--;
        if (_pendingAccountTransitions == 0 &&
            _pendingServerTransitions == 0 &&
            !_criticallyBlocked) {
          _transitioning = false;
          if (_accountInstalledDuringBatch) {
            requestSync(getTx: false, auto: true).then<void>((_) {},
                onError: (Object error, StackTrace stackTrace) {
              _automaticError?.call(error, stackTrace);
            });
          }
        }
      }
    });
    _transitionTail = queued;
    return result.future;
  }

  /// Runs explicit server transitions FIFO on the same barrier as account
  /// transitions. Distinct and duplicate requests are both retained.
  Future<SyncLifecycleServerExecution<T>> runServerTransition<T>({
    required bool Function(SyncLifecycleToken token) contextMatches,
    required Future<SyncLifecycleServerMutation<T>> Function() mutation,
  }) {
    final result = Completer<SyncLifecycleServerExecution<T>>();
    _pendingServerTransitions++;
    _transitioning = true;

    final predecessor = _transitionTail;
    final queued = predecessor.catchError((Object _) {}).then<void>((_) async {
      SyncLifecycleServerMutation<T>? completedMutation;
      try {
        if (!contextMatches(_currentToken)) {
          throw const SyncLifecycleContextChanged();
        }
        _invalidate();
        try {
          await _cancelForAccountTransition();
        } catch (error, stackTrace) {
          throw SyncLifecycleCancellationFailed(error, stackTrace);
        }
        completedMutation = await mutation();
        if (completedMutation.resumePolicy !=
            SyncLifecycleResumePolicy.blocked) {
          // Recapture the unchanged account after the URL mutation without a
          // second generation change.
          _currentToken = _captureToken(_currentToken.generation);
        } else {
          _criticallyBlocked = true;
        }
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        _pendingServerTransitions--;
      }

      if (completedMutation == null) {
        if (_pendingAccountTransitions == 0 &&
            _pendingServerTransitions == 0 &&
            !_criticallyBlocked) {
          _transitioning = false;
        }
        return;
      }

      final mutationResult = completedMutation;
      if (mutationResult.resumePolicy == SyncLifecycleResumePolicy.blocked) {
        result.complete(SyncLifecycleServerExecution(mutationResult.value));
        return;
      }
      if (_pendingAccountTransitions == 0 && _pendingServerTransitions == 0) {
        _transitioning = false;
      }
      if (mutationResult.resumePolicy == SyncLifecycleResumePolicy.idle) {
        result.complete(SyncLifecycleServerExecution(mutationResult.value));
        return;
      }
      try {
        await requestSync(getTx: false, auto: true);
        result.complete(SyncLifecycleServerExecution(mutationResult.value));
      } catch (error, stackTrace) {
        result.complete(SyncLifecycleServerExecution(
          mutationResult.value,
          refreshError: error,
          refreshStackTrace: stackTrace,
        ));
      }
    });
    _transitionTail = queued;
    return result.future;
  }

  Future<void> _cancelForAccountTransition() {
    final existing = _cancellationTransition;
    if (existing != null) return existing;

    final transition = Completer<void>();
    _cancellationTransition = transition.future;
    final operation = _inFlight;
    if (operation != null && !operation.cancellationRequested) {
      operation.cancellationRequested = true;
      _cancel();
    }
    () async {
      try {
        if (operation != null) await operation.future;
        transition.complete();
      } catch (error, stackTrace) {
        transition.completeError(error, stackTrace);
      } finally {
        if (identical(_inFlight, operation)) _inFlight = null;
        if (identical(_cancellationTransition, transition.future)) {
          _cancellationTransition = null;
        }
      }
    }();
    return transition.future;
  }

  Future<void> _beginCancellation(Completer<void> transition) async {
    _invalidate();
    final operation = _inFlight;
    _transitioning = true;
    if (operation != null && !operation.cancellationRequested) {
      operation.cancellationRequested = true;
      _cancel();
    }
    Object? error;
    StackTrace? stackTrace;
    try {
      if (operation != null) await operation.future;
    } catch (e, s) {
      error = e;
      stackTrace = s;
    } finally {
      if (identical(_inFlight, operation)) _inFlight = null;
      _transitioning = _pendingAccountTransitions != 0;
      _cancellationTransition = null;
    }
    if (error == null) {
      transition.complete();
    } else {
      transition.completeError(error, stackTrace!);
    }
  }

  void startAutomaticSync() {
    if (_automaticTimer != null) return;
    _automaticTimer = _timerFactory(automaticSyncInterval, _automaticTick);
  }

  void stopAutomaticSync() {
    _automaticTimer?.cancel();
    _automaticTimer = null;
  }

  void _automaticTick() {
    if (_transitioning) return;
    final token = _currentToken;
    final sync = requestSync(getTx: false, auto: true);
    sync.then<void>((_) {
      if (owns(token)) _automaticRefresh?.call(token);
    }, onError: (Object error, StackTrace stackTrace) {
      _automaticError?.call(error, stackTrace);
    });
  }

  void _invalidate() {
    _currentToken = _captureToken(_currentToken.generation + 1);
  }

  SyncLifecycleToken _captureToken(int generation) {
    final account = _accountProvider();
    return SyncLifecycleToken(
      generation: generation,
      coin: account.coin,
      accountId: account.accountId,
      account: account.account,
    );
  }
}
