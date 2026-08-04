enum ServerProbeFailureCategory {
  invalidUrl,
  dns,
  timeout,
  connection,
  tls,
  grpc,
  malformedResponse,
  unknown,
}

class ServerProbeResult {
  final String url;
  final bool success;
  final ServerProbeFailureCategory? failureCategory;
  final String? errorMessage;
  final BigInt elapsedMilliseconds;
  final String? version;
  final String? vendor;
  final bool? taddrSupport;
  final String? chainName;
  final BigInt? saplingActivationHeight;
  final String? consensusBranchId;
  final BigInt? blockHeight;
  final BigInt? estimatedHeight;
  final String? gitCommit;
  final String? buildDate;

  const ServerProbeResult({
    required this.url,
    required this.success,
    required this.failureCategory,
    required this.errorMessage,
    required this.elapsedMilliseconds,
    required this.version,
    required this.vendor,
    required this.taddrSupport,
    required this.chainName,
    required this.saplingActivationHeight,
    required this.consensusBranchId,
    required this.blockHeight,
    required this.estimatedHeight,
    required this.gitCommit,
    required this.buildDate,
  });

  factory ServerProbeResult.fromJson(Map<String, dynamic> json) {
    BigInt? parseOptionalInt(String name) {
      final value = json[name];
      if (value == null) return null;
      if (value is! String) {
        throw FormatException('$name must be a decimal string');
      }
      return BigInt.parse(value);
    }

    final categoryName = json['failureCategory'] as String?;
    final category = categoryName == null
        ? null
        : ServerProbeFailureCategory.values
                .where((category) => category.name == categoryName)
                .firstOrNull ??
            ServerProbeFailureCategory.unknown;

    return ServerProbeResult(
      url: json['url'] as String,
      success: json['success'] as bool,
      failureCategory: category,
      errorMessage: json['errorMessage'] as String?,
      elapsedMilliseconds: parseOptionalInt('elapsedMilliseconds')!,
      version: json['version'] as String?,
      vendor: json['vendor'] as String?,
      taddrSupport: json['taddrSupport'] as bool?,
      chainName: json['chainName'] as String?,
      saplingActivationHeight: parseOptionalInt('saplingActivationHeight'),
      consensusBranchId: json['consensusBranchId'] as String?,
      blockHeight: parseOptionalInt('blockHeight'),
      estimatedHeight: parseOptionalInt('estimatedHeight'),
      gitCommit: json['gitCommit'] as String?,
      buildDate: json['buildDate'] as String?,
    );
  }
}

class BuckServerValidationResult {
  final List<String> failures;

  const BuckServerValidationResult(this.failures);

  bool get isValid => failures.isEmpty;
}

const _buckHeightTolerance = 10;

BuckServerValidationResult validateBuckServerProbe(ServerProbeResult result) {
  final failures = <String>[];
  if (!result.success) {
    return const BuckServerValidationResult(['probe was not successful']);
  }
  if (result.chainName != 'main') failures.add('chainName must be main');
  if (result.saplingActivationHeight != BigInt.from(261500)) {
    failures.add('saplingActivationHeight must be 261500');
  }
  if (result.consensusBranchId != 'f5b9230b') {
    failures.add('consensusBranchId must be f5b9230b');
  }
  final blockHeight = result.blockHeight;
  final estimatedHeight = result.estimatedHeight;
  if (blockHeight == null || blockHeight <= BigInt.zero) {
    failures.add('blockHeight must be positive');
  }
  if (estimatedHeight == null || estimatedHeight <= BigInt.zero) {
    failures.add('estimatedHeight must be positive');
  }
  if (blockHeight != null &&
      estimatedHeight != null &&
      (blockHeight - estimatedHeight).abs() >
          BigInt.from(_buckHeightTolerance)) {
    failures.add('blockHeight and estimatedHeight must be within 10 blocks');
  }
  return BuckServerValidationResult(List.unmodifiable(failures));
}
