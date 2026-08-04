import 'bootstrap_parse_models.dart';

enum BootstrapCacheFailureCategory {
  none,
  unavailable,
  notFound,
  read,
  write,
  flush,
  rename,
  permission,
  sizeLimit,
  invalidUtf8,
  invalidDocument,
  corrupt,
  delete,
  unknown,
}

class BootstrapCacheLoadResult {
  final bool success;
  final bool found;
  final String? document;
  final BootstrapParseResult? parsed;
  final BootstrapCacheFailureCategory failureCategory;
  final String diagnosticMessage;
  final String cacheKey;
  final int? byteCount;
  final int elapsedMilliseconds;
  final bool unusable;
  final bool invalidDataRemoved;

  const BootstrapCacheLoadResult({
    required this.success,
    required this.found,
    required this.document,
    required this.parsed,
    required this.failureCategory,
    required this.diagnosticMessage,
    required this.cacheKey,
    required this.byteCount,
    required this.elapsedMilliseconds,
    required this.unusable,
    required this.invalidDataRemoved,
  });
}

class BootstrapCacheSaveResult {
  final bool success;
  final int byteCount;
  final int elapsedMilliseconds;
  final BootstrapCacheFailureCategory failureCategory;
  final String diagnosticMessage;
  final String cacheKey;
  final bool atomicReplacementCompleted;

  const BootstrapCacheSaveResult({
    required this.success,
    required this.byteCount,
    required this.elapsedMilliseconds,
    required this.failureCategory,
    required this.diagnosticMessage,
    required this.cacheKey,
    required this.atomicReplacementCompleted,
  });
}

class BootstrapCacheDeleteResult {
  final bool success;
  final bool existed;
  final BootstrapCacheFailureCategory failureCategory;
  final String diagnosticMessage;

  const BootstrapCacheDeleteResult({
    required this.success,
    required this.existed,
    required this.failureCategory,
    required this.diagnosticMessage,
  });
}
