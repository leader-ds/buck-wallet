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

enum ServerDefinitionsApplyFailure {
  none,
  empty,
  invalidDefinition,
  duplicateId,
  duplicateUrl,
}

class ServerDefinitionsApplyResult {
  final bool success;
  final bool changed;
  final ServerDefinitionsApplyFailure failure;
  final String diagnosticMessage;
  final List<ServerDefinition> definitions;

  ServerDefinitionsApplyResult({
    required this.success,
    required this.changed,
    required this.failure,
    required this.diagnosticMessage,
    required List<ServerDefinition> definitions,
  }) : definitions = List.unmodifiable(definitions);
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
  late List<ServerDefinition> _servers;
  late List<ServerStatus> _statuses;
  ServerDefinition? _selectedCandidate;
  Future<void>? _inFlightRefresh;

  ServerCoordinator({
    List<ServerDefinition> servers = embeddedBuckServers,
    ServerProbe probe = WarpApi.probeServer,
  })  : _probe = probe,
        _servers = _orderedServers(servers) {
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

  /// Replaces definitions after any active refresh completes.
  ///
  /// All probe state is reset. This method only changes the candidate set; it
  /// never changes the wallet's active server.
  Future<ServerDefinitionsApplyResult> replaceServers(
      List<ServerDefinition> servers) async {
    final validation = _validateAndOrderServers(servers);
    if (!validation.success) return validation;
    final replacement = validation.definitions;
    final refresh = _inFlightRefresh;
    if (refresh != null) await refresh;
    if (_sameDefinitions(_servers, replacement)) {
      return ServerDefinitionsApplyResult(
        success: true,
        changed: false,
        failure: ServerDefinitionsApplyFailure.none,
        diagnosticMessage: 'Server definitions are unchanged.',
        definitions: _servers,
      );
    }
    _servers = replacement;
    _statuses = List.unmodifiable(
      _servers.map(
        (server) => ServerStatus(
          server: server,
          healthState: ServerHealthState.unknown,
        ),
      ),
    );
    _selectedCandidate = null;
    return ServerDefinitionsApplyResult(
      success: true,
      changed: true,
      failure: ServerDefinitionsApplyFailure.none,
      diagnosticMessage: 'Server definitions replaced; probe state reset.',
      definitions: _servers,
    );
  }

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

List<ServerDefinition> _orderedServers(List<ServerDefinition> servers) {
  final ordered = List<ServerDefinition>.of(servers)
    ..sort((left, right) {
      final priority = left.priority.compareTo(right.priority);
      return priority != 0 ? priority : left.id.compareTo(right.id);
    });
  return List.unmodifiable(ordered);
}

ServerDefinitionsApplyResult _validateAndOrderServers(
    List<ServerDefinition> servers) {
  if (servers.isEmpty) {
    return ServerDefinitionsApplyResult(
      success: false,
      changed: false,
      failure: ServerDefinitionsApplyFailure.empty,
      diagnosticMessage: 'Server definitions must not be empty.',
      definitions: const [],
    );
  }
  final ids = <String>{};
  final urls = <String>{};
  final normalized = <ServerDefinition>[];
  for (final server in servers) {
    if (server.id.isEmpty ||
        server.id.trim() != server.id ||
        server.name.trim().isEmpty ||
        server.priority < 0 ||
        server.priority > 1000) {
      return _invalidApply(ServerDefinitionsApplyFailure.invalidDefinition,
          'A server definition has invalid identity fields.');
    }
    if (!ids.add(server.id)) {
      return _invalidApply(ServerDefinitionsApplyFailure.duplicateId,
          'Server definition IDs must be unique.');
    }
    final url = _normalizedServerUrl(server.url);
    if (url == null) {
      return _invalidApply(ServerDefinitionsApplyFailure.invalidDefinition,
          'A server definition has an invalid HTTPS URL.');
    }
    if (!urls.add(url)) {
      return _invalidApply(ServerDefinitionsApplyFailure.duplicateUrl,
          'Server definition URLs must be unique.');
    }
    normalized.add(ServerDefinition(
      id: server.id,
      name: server.name,
      url: url,
      priority: server.priority,
      enabled: server.enabled,
    ));
  }
  final ordered = _orderedServers(normalized);
  return ServerDefinitionsApplyResult(
    success: true,
    changed: false,
    failure: ServerDefinitionsApplyFailure.none,
    diagnosticMessage: 'Server definitions validated.',
    definitions: ordered,
  );
}

ServerDefinitionsApplyResult _invalidApply(
        ServerDefinitionsApplyFailure failure, String message) =>
    ServerDefinitionsApplyResult(
      success: false,
      changed: false,
      failure: failure,
      diagnosticMessage: message,
      definitions: const [],
    );

String? _normalizedServerUrl(String value) {
  try {
    final uri = Uri.parse(value);
    if (!uri.isAbsolute ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final path = uri.path.isEmpty ? '/' : uri.path;
    return uri
        .replace(scheme: 'https', host: uri.host.toLowerCase(), path: path)
        .normalizePath()
        .toString();
  } on FormatException {
    return null;
  }
}

bool _sameDefinitions(
    List<ServerDefinition> left, List<ServerDefinition> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    final a = left[index];
    final b = right[index];
    if (a.id != b.id ||
        a.name != b.name ||
        _normalizedServerUrl(a.url) != _normalizedServerUrl(b.url) ||
        a.priority != b.priority ||
        a.enabled != b.enabled) {
      return false;
    }
  }
  return true;
}
