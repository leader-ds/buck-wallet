import 'package:flutter_test/flutter_test.dart';
import 'package:warp_api/server_probe.dart';

ServerProbeResult successfulProbe({
  int blockHeight = 3000000,
  int estimatedHeight = 3000000,
}) {
  return ServerProbeResult(
    url: 'https://wallet.buck.red:9067',
    success: true,
    failureCategory: null,
    errorMessage: null,
    elapsedMilliseconds: BigInt.from(42),
    version: 'v1',
    vendor: 'BUCK',
    taddrSupport: true,
    chainName: 'main',
    saplingActivationHeight: BigInt.from(261500),
    consensusBranchId: 'f5b9230b',
    blockHeight: BigInt.from(blockHeight),
    estimatedHeight: BigInt.from(estimatedHeight),
    gitCommit: 'abc123',
    buildDate: 'today',
  );
}

void main() {
  test('parses a successful probe without losing u64 values', () {
    final result = ServerProbeResult.fromJson({
      'url': 'https://wallet.buck.red:9067',
      'success': true,
      'failureCategory': null,
      'errorMessage': null,
      'elapsedMilliseconds': '42',
      'version': 'v1',
      'vendor': 'BUCK',
      'taddrSupport': true,
      'chainName': 'main',
      'saplingActivationHeight': '18446744073709551615',
      'consensusBranchId': 'f5b9230b',
      'blockHeight': '9007199254740993',
      'estimatedHeight': '9007199254740994',
      'gitCommit': 'abc123',
      'buildDate': 'today',
    });

    expect(
        result.saplingActivationHeight, BigInt.parse('18446744073709551615'));
    expect(result.blockHeight, BigInt.parse('9007199254740993'));
    expect(result.estimatedHeight, BigInt.parse('9007199254740994'));
  });

  test('parses a typed failure category', () {
    final result = ServerProbeResult.fromJson({
      'url': 'https://invalid.example:9067',
      'success': false,
      'failureCategory': 'dns',
      'errorMessage': 'name resolution failed',
      'elapsedMilliseconds': '5000',
      'version': null,
      'vendor': null,
      'taddrSupport': null,
      'chainName': null,
      'saplingActivationHeight': null,
      'consensusBranchId': null,
      'blockHeight': null,
      'estimatedHeight': null,
      'gitCommit': null,
      'buildDate': null,
    });

    expect(result.failureCategory, ServerProbeFailureCategory.dns);
    expect(result.success, isFalse);
  });

  test('maps an unknown failure category to unknown', () {
    final result = ServerProbeResult.fromJson({
      'url': 'https://invalid.example:9067',
      'success': false,
      'failureCategory': 'futureCategory',
      'errorMessage': 'future failure',
      'elapsedMilliseconds': '1',
      'version': null,
      'vendor': null,
      'taddrSupport': null,
      'chainName': null,
      'saplingActivationHeight': null,
      'consensusBranchId': null,
      'blockHeight': null,
      'estimatedHeight': null,
      'gitCommit': null,
      'buildDate': null,
    });

    expect(result.failureCategory, ServerProbeFailureCategory.unknown);
  });

  test('failed probes do not accumulate identity validation failures', () {
    final probe = ServerProbeResult(
      url: 'https://invalid.example:9067',
      success: false,
      failureCategory: ServerProbeFailureCategory.connection,
      errorMessage: 'connection failed',
      elapsedMilliseconds: BigInt.one,
      version: null,
      vendor: null,
      taddrSupport: null,
      chainName: null,
      saplingActivationHeight: null,
      consensusBranchId: null,
      blockHeight: null,
      estimatedHeight: null,
      gitCommit: null,
      buildDate: null,
    );

    final validation = validateBuckServerProbe(probe);

    expect(validation.failures, ['probe was not successful']);
  });

  test('accepts a BUCK server whose heights differ by 10', () {
    final validation = validateBuckServerProbe(
      successfulProbe(blockHeight: 3000000, estimatedHeight: 3000010),
    );

    expect(validation.isValid, isTrue);
    expect(validation.failures, isEmpty);
  });

  test('rejects a BUCK server whose heights differ by 11', () {
    final validation = validateBuckServerProbe(
      successfulProbe(blockHeight: 3000000, estimatedHeight: 3000011),
    );

    expect(validation.isValid, isFalse);
    expect(validation.failures, [
      'blockHeight and estimatedHeight must be within 10 blocks',
    ]);
  });

  test('reports each BUCK identity and height validation failure', () {
    final probe = ServerProbeResult(
      url: 'https://example.invalid:9067',
      success: true,
      failureCategory: null,
      errorMessage: null,
      elapsedMilliseconds: BigInt.one,
      version: null,
      vendor: null,
      taddrSupport: null,
      chainName: 'test',
      saplingActivationHeight: BigInt.one,
      consensusBranchId: 'other',
      blockHeight: BigInt.zero,
      estimatedHeight: BigInt.from(20),
      gitCommit: null,
      buildDate: null,
    );

    final validation = validateBuckServerProbe(probe);

    expect(validation.isValid, isFalse);
    expect(validation.failures, hasLength(5));
  });
}
