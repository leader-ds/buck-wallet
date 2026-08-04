enum BootstrapParseFailureCategory {
  invalidJson,
  unsupportedSchema,
  missingField,
  wrongType,
  invalidNetwork,
  invalidServer,
  duplicateServer,
  invalidUri,
  unsupportedValue,
  unknown,
}

class BootstrapValidationError {
  final BootstrapParseFailureCategory category;
  final String path;
  final String message;

  const BootstrapValidationError({
    required this.category,
    required this.path,
    required this.message,
  });
}

class BootstrapServer {
  final String id;
  final String displayName;
  final Uri grpcUrl;
  final int priority;
  final bool enabled;

  const BootstrapServer({
    required this.id,
    required this.displayName,
    required this.grpcUrl,
    required this.priority,
    required this.enabled,
  });
}

class BootstrapParseResult {
  final int? configVersion;
  final String? network;
  final List<BootstrapServer> servers;
  final List<BootstrapValidationError> validationErrors;
  final List<String> warnings;
  final int unknownFieldCount;

  BootstrapParseResult({
    required this.configVersion,
    required this.network,
    required List<BootstrapServer> servers,
    required List<BootstrapValidationError> validationErrors,
    List<String> warnings = const [],
    this.unknownFieldCount = 0,
  })  : servers = List.unmodifiable(servers),
        validationErrors = List.unmodifiable(validationErrors),
        warnings = List.unmodifiable(warnings);

  bool get success => validationErrors.isEmpty;
}
