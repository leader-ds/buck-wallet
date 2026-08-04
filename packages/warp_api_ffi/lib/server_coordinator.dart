import 'warp_api.dart';

typedef ServerProbe = Future<ServerProbeResult> Function(String url);

class ServerDefinition {
  final String id;
  final String name;
  final String url;
  final int priority;
  final bool enabled;

  const ServerDefinition({
    required this.id,
    required this.name,
    required this.url,
    required this.priority,
    required this.enabled,
  });
}

const embeddedBuckServers = <ServerDefinition>[
  ServerDefinition(
    id: 'fr-primary',
    name: 'France Primary',
    url: 'https://wallet.buck.red:9067',
    priority: 1,
    enabled: true,
  ),
  ServerDefinition(
    id: 'fr-secondary',
    name: 'France Secondary',
    url: 'https://lwd2.buck.red:9067',
    priority: 2,
    enabled: true,
  ),
];

enum ServerHealthState {
  unknown,
  checking,
  healthy,
  unreachable,
  invalid,
}

class ServerStatus {
  final ServerDefinition server;
  final ServerHealthState healthState;
  final ServerProbeResult? probeResult;
  final BuckServerValidationResult? validationResult;
  final BigInt? elapsedMilliseconds;
  final String? diagnosticMessage;
  final DateTime? lastCheckedAt;

  const ServerStatus({
    required this.server,
    required this.healthState,
    this.probeResult,
    this.validationResult,
    this.elapsedMilliseconds,
    this.diagnosticMessage,
    this.lastCheckedAt,
  });
}

class ServerCoordinator {
  final ServerProbe _probe;
  final List<ServerDefinition> _servers;
  late List<ServerStatus> _statuses;
  ServerDefinition? _selectedCandidate;
  Future<void>? _inFlightRefresh;

  ServerCoordinator({
    List<ServerDefinition> servers = embeddedBuckServers,
    ServerProbe probe = WarpApi.probeServer,
  })  : _probe = probe,
        _servers = List.unmodifiable(servers) {
    _statuses = List.unmodifiable(
      _servers.map(
        (server) => ServerStatus(
          server: server,
          healthState: ServerHealthState.unknown,
        ),
      ),
    );
  }

  List<ServerDefinition> get servers => _servers;

  List<ServerStatus> get statuses => _statuses;

  ServerDefinition? get selectedCandidate => _selectedCandidate;

  ServerDefinition? get preferredHealthyServer => _selectedCandidate;

  Future<void> refresh() {
    final existing = _inFlightRefresh;
    if (existing != null) return existing;

    final refresh = _refreshServers();
    _inFlightRefresh = refresh;
    refresh.whenComplete(() {
      if (identical(_inFlightRefresh, refresh)) {
        _inFlightRefresh = null;
      }
    });
    return refresh;
  }

  Future<void> _refreshServers() async {
    _selectedCandidate = null;
    _statuses = List.unmodifiable([
      for (final status in _statuses)
        if (status.server.enabled)
          ServerStatus(
            server: status.server,
            healthState: ServerHealthState.checking,
          )
        else
          status,
    ]);

    for (var index = 0; index < _servers.length; index++) {
      final server = _servers[index];
      if (!server.enabled) continue;
      final checkedAt = DateTime.now();
      ServerStatus status;
      try {
        final probeResult = await _probe(server.url);
        if (!probeResult.success) {
          status = ServerStatus(
            server: server,
            healthState: ServerHealthState.unreachable,
            probeResult: probeResult,
            elapsedMilliseconds: probeResult.elapsedMilliseconds,
            diagnosticMessage: probeResult.errorMessage,
            lastCheckedAt: checkedAt,
          );
        } else {
          final validation = validateBuckServerProbe(probeResult);
          status = ServerStatus(
            server: server,
            healthState: validation.isValid
                ? ServerHealthState.healthy
                : ServerHealthState.invalid,
            probeResult: probeResult,
            validationResult: validation,
            elapsedMilliseconds: probeResult.elapsedMilliseconds,
            diagnosticMessage:
                validation.isValid ? null : validation.failures.join('; '),
            lastCheckedAt: checkedAt,
          );
        }
      } catch (error) {
        status = ServerStatus(
          server: server,
          healthState: ServerHealthState.unreachable,
          diagnosticMessage: error.toString(),
          lastCheckedAt: checkedAt,
        );
      }
      _replaceStatus(index, status);
    }

    for (final status in _statuses) {
      if (!status.server.enabled ||
          status.healthState != ServerHealthState.healthy) {
        continue;
      }
      final selected = _selectedCandidate;
      if (selected == null || status.server.priority < selected.priority) {
        _selectedCandidate = status.server;
      }
    }
  }

  void _replaceStatus(int index, ServerStatus status) {
    final updated = List<ServerStatus>.of(_statuses);
    updated[index] = status;
    _statuses = List.unmodifiable(updated);
  }
}
