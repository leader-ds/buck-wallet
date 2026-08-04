import 'dart:convert';

import 'bootstrap_parse_models.dart';

export 'bootstrap_parse_models.dart';

const bootstrapMaximumServerCount = 64;

/// Parses and validates an already-downloaded BUCK bootstrap document.
///
/// Schema validation establishes structure, not trust. Signature verification
/// is intentionally deferred to Stage 6.
class BootstrapParser {
  const BootstrapParser();

  Future<BootstrapParseResult> parse(String document) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(document);
    } on FormatException {
      return _failure(BootstrapParseFailureCategory.invalidJson, r'$',
          'The bootstrap document is not valid JSON.');
    } catch (_) {
      return _failure(BootstrapParseFailureCategory.unknown, r'$',
          'The bootstrap document could not be parsed.');
    }

    if (decoded is! Map<String, dynamic>) {
      return _failure(BootstrapParseFailureCategory.unsupportedSchema, r'$',
          'The bootstrap document must be a JSON object.');
    }

    final errors = <BootstrapValidationError>[];
    final version = _integerField(decoded, 'configVersion', errors);
    if (version != null && version < 1) {
      errors.add(const BootstrapValidationError(
        category: BootstrapParseFailureCategory.unsupportedValue,
        path: r'$.configVersion',
        message: 'configVersion must be at least 1.',
      ));
    }

    final networkValue = _requiredField(decoded, 'network', errors);
    String? network;
    if (networkValue != null) {
      if (networkValue is! String) {
        _wrongType(errors, r'$.network', 'network must be a string.');
      } else if (networkValue != 'BUCK') {
        errors.add(const BootstrapValidationError(
          category: BootstrapParseFailureCategory.invalidNetwork,
          path: r'$.network',
          message: 'network must be BUCK.',
        ));
      } else {
        network = networkValue;
      }
    }

    final serversValue = _requiredField(decoded, 'servers', errors);
    final parsed = <_IndexedServer>[];
    var unknownFields =
        decoded.keys.where((key) => !_topLevelFields.contains(key)).length;
    if (serversValue != null) {
      if (serversValue is! List) {
        _wrongType(errors, r'$.servers', 'servers must be an array.');
      } else if (serversValue.isEmpty) {
        errors.add(const BootstrapValidationError(
          category: BootstrapParseFailureCategory.invalidServer,
          path: r'$.servers',
          message: 'servers must contain at least one server.',
        ));
      } else if (serversValue.length > bootstrapMaximumServerCount) {
        errors.add(const BootstrapValidationError(
          category: BootstrapParseFailureCategory.unsupportedValue,
          path: r'$.servers',
          message: 'servers must contain at most 64 servers.',
        ));
      } else {
        for (var index = 0; index < serversValue.length; index++) {
          final entry = serversValue[index];
          if (entry is! Map<String, dynamic>) {
            errors.add(BootstrapValidationError(
              category: BootstrapParseFailureCategory.invalidServer,
              path: r'$.servers[' + index.toString() + ']',
              message: 'Each server must be an object.',
            ));
            continue;
          }
          unknownFields +=
              entry.keys.where((key) => !_serverFields.contains(key)).length;
          final server = _parseServer(entry, index, errors);
          if (server != null) parsed.add(_IndexedServer(index, server));
        }
      }
    }

    _rejectDuplicates(parsed, errors);
    parsed.sort((a, b) {
      final priority = a.server.priority.compareTo(b.server.priority);
      return priority != 0 ? priority : a.index.compareTo(b.index);
    });

    return BootstrapParseResult(
      configVersion: version != null && version >= 1 ? version : null,
      network: network,
      servers: parsed.map((item) => item.server).toList(),
      validationErrors: errors,
      unknownFieldCount: unknownFields,
    );
  }
}

const _topLevelFields = {'configVersion', 'network', 'servers'};
const _serverFields = {'id', 'displayName', 'grpcUrl', 'priority', 'enabled'};

dynamic _requiredField(Map<String, dynamic> object, String name,
    List<BootstrapValidationError> errors) {
  if (!object.containsKey(name) || object[name] == null) {
    errors.add(BootstrapValidationError(
      category: BootstrapParseFailureCategory.missingField,
      path: r'$.' + name,
      message: '$name is required.',
    ));
    return null;
  }
  return object[name];
}

int? _integerField(Map<String, dynamic> object, String name,
    List<BootstrapValidationError> errors) {
  final value = _requiredField(object, name, errors);
  if (value == null) return null;
  if (value is! int) {
    _wrongType(errors, r'$.' + name, '$name must be an integer.');
    return null;
  }
  return value;
}

BootstrapServer? _parseServer(Map<String, dynamic> entry, int index,
    List<BootstrapValidationError> errors) {
  final prefix = r'$.servers[' + index.toString() + ']';
  final errorCount = errors.length;
  final idValue = _requiredField(entry, 'id', errors);
  final displayNameValue = _requiredField(entry, 'displayName', errors);
  final grpcUrlValue = _requiredField(entry, 'grpcUrl', errors);
  final priority = _integerField(entry, 'priority', errors);
  final enabledValue = _requiredField(entry, 'enabled', errors);

  String? id;
  if (idValue != null) {
    if (idValue is! String) {
      _wrongType(errors, '$prefix.id', 'id must be a string.');
    } else if (idValue.trim().isEmpty || !_printableAscii.hasMatch(idValue)) {
      errors.add(BootstrapValidationError(
        category: BootstrapParseFailureCategory.invalidServer,
        path: '$prefix.id',
        message: 'id must be non-empty printable ASCII.',
      ));
    } else {
      id = idValue;
    }
  }

  String? displayName;
  if (displayNameValue != null) {
    if (displayNameValue is! String) {
      _wrongType(
          errors, '$prefix.displayName', 'displayName must be a string.');
    } else if (displayNameValue.trim().isEmpty) {
      errors.add(BootstrapValidationError(
        category: BootstrapParseFailureCategory.invalidServer,
        path: '$prefix.displayName',
        message: 'displayName must be non-empty.',
      ));
    } else {
      displayName = displayNameValue;
    }
  }

  Uri? grpcUrl;
  if (grpcUrlValue != null) {
    if (grpcUrlValue is! String) {
      _wrongType(errors, '$prefix.grpcUrl', 'grpcUrl must be a string.');
    } else {
      grpcUrl = _httpsUri(grpcUrlValue);
      if (grpcUrl == null) {
        errors.add(BootstrapValidationError(
          category: BootstrapParseFailureCategory.invalidUri,
          path: '$prefix.grpcUrl',
          message:
              'grpcUrl must be an absolute HTTPS URI with a host and no credentials.',
        ));
      }
    }
  }

  if (priority != null && (priority < 0 || priority > 1000)) {
    errors.add(BootstrapValidationError(
      category: BootstrapParseFailureCategory.unsupportedValue,
      path: '$prefix.priority',
      message: 'priority must be between 0 and 1000.',
    ));
  }

  bool? enabled;
  if (enabledValue != null) {
    if (enabledValue is! bool) {
      _wrongType(errors, '$prefix.enabled', 'enabled must be a boolean.');
    } else {
      enabled = enabledValue;
    }
  }

  if (errors.length != errorCount ||
      id == null ||
      displayName == null ||
      grpcUrl == null ||
      priority == null ||
      enabled == null) {
    return null;
  }
  return BootstrapServer(
    id: id,
    displayName: displayName,
    grpcUrl: grpcUrl,
    priority: priority,
    enabled: enabled,
  );
}

final _printableAscii = RegExp(r'^[\x20-\x7E]+$');

Uri? _httpsUri(String value) {
  try {
    final uri = Uri.parse(value);
    if (!uri.isAbsolute ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  } on FormatException {
    return null;
  }
}

void _rejectDuplicates(
    List<_IndexedServer> parsed, List<BootstrapValidationError> errors) {
  final ids = <String>{};
  final urls = <String>{};
  for (final item in parsed) {
    final prefix = r'$.servers[' + item.index.toString() + ']';
    if (!ids.add(item.server.id)) {
      errors.add(BootstrapValidationError(
        category: BootstrapParseFailureCategory.duplicateServer,
        path: '$prefix.id',
        message: 'Server id is duplicated.',
      ));
    }
    final normalizedUrl = _normalizedUri(item.server.grpcUrl);
    if (!urls.add(normalizedUrl)) {
      errors.add(BootstrapValidationError(
        category: BootstrapParseFailureCategory.duplicateServer,
        path: '$prefix.grpcUrl',
        message: 'Server grpcUrl is duplicated.',
      ));
    }
  }
}

String _normalizedUri(Uri uri) {
  final path = uri.path.isEmpty ? '/' : uri.path;
  return uri
      .replace(scheme: 'https', host: uri.host.toLowerCase(), path: path)
      .normalizePath()
      .toString();
}

void _wrongType(
        List<BootstrapValidationError> errors, String path, String message) =>
    errors.add(BootstrapValidationError(
      category: BootstrapParseFailureCategory.wrongType,
      path: path,
      message: message,
    ));

BootstrapParseResult _failure(
        BootstrapParseFailureCategory category, String path, String message) =>
    BootstrapParseResult(
      configVersion: null,
      network: null,
      servers: const [],
      validationErrors: [
        BootstrapValidationError(
          category: category,
          path: path,
          message: message,
        ),
      ],
    );

class _IndexedServer {
  final int index;
  final BootstrapServer server;

  const _IndexedServer(this.index, this.server);
}
