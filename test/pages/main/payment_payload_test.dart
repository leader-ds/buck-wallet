import 'package:flutter_test/flutter_test.dart';

import 'package:buck_wallet/pages/main/payment_payload.dart';

void main() {
  group('PaymentPayloadResult', () {
    late List<_GeneratorCall> calls;
    late PaymentUriGenerator generator;

    setUp(() {
      calls = [];
      generator = (address, amount, memo) {
        calls.add(_GeneratorCall(address, amount, memo));
        return 'uri:$address:$amount:$memo';
      };
    });

    PaymentPayloadResult compute({
      String address = 'synthetic-address',
      int? amount,
      String? memo,
      bool memoCapable = true,
      PaymentUriGenerator? overrideGenerator,
    }) =>
        PaymentPayloadResult.compute(
          address: address,
          amount: amount,
          memo: memo,
          memoCapable: memoCapable,
          generatePaymentUri: overrideGenerator ?? generator,
        );

    void expectSynchronized(PaymentPayloadResult result) {
      expect(result.isValid, isTrue);
      expect(result.payload, isNotEmpty);
      final displaySource = result.payload;
      final copyPayload = result.payload;
      final inlineQrPayload = result.payload;
      final showQrPayload = result.payload;
      expect(displaySource, result.payload);
      expect(copyPayload, result.payload);
      expect(inlineQrPayload, result.payload);
      expect(showQrPayload, result.payload);
    }

    test('raw address only', () {
      final result = compute();
      expect(result.type, PaymentPayloadType.rawAddress);
      expect(result.rawAddress, 'synthetic-address');
      expect(result.payload, 'synthetic-address');
      expect(calls, isEmpty);
      expectSynchronized(result);
    });

    test('null amount and no memo uses raw address', () {
      final result = compute(amount: null, memo: null);
      expect(result.type, PaymentPayloadType.rawAddress);
      expect(calls, isEmpty);
      expectSynchronized(result);
    });

    test('zero amount and no memo uses raw address', () {
      final result = compute(amount: 0);
      expect(result.type, PaymentPayloadType.rawAddress);
      expect(calls, isEmpty);
      expectSynchronized(result);
    });

    test('positive amount and no memo uses payment URI', () {
      final result = compute(amount: 42);
      expect(result.type, PaymentPayloadType.paymentUri);
      expect(calls.single, _GeneratorCall('synthetic-address', 42, ''));
      expectSynchronized(result);
    });

    test('positive amount and memo uses exact inputs', () {
      final result = compute(amount: 42, memo: 'memo');
      expect(result.type, PaymentPayloadType.paymentUri);
      expect(calls.single, _GeneratorCall('synthetic-address', 42, 'memo'));
      expectSynchronized(result);
    });

    test('zero amount and memo generates with native amount zero', () {
      final result = compute(amount: 0, memo: 'memo');
      expect(calls.single, _GeneratorCall('synthetic-address', 0, 'memo'));
      expectSynchronized(result);
    });

    test('null amount and memo generates with native amount zero', () {
      final result = compute(amount: null, memo: 'memo');
      expect(calls.single, _GeneratorCall('synthetic-address', 0, 'memo'));
      expectSynchronized(result);
    });

    test('Unicode memo is preserved exactly', () {
      final result = compute(memo: '  Árvíztűrő 🚀  ');
      expect(
        calls.single,
        _GeneratorCall('synthetic-address', 0, '  Árvíztűrő 🚀  '),
      );
      expectSynchronized(result);
    });

    test('empty memo is absent', () {
      final result = compute(memo: '');
      expect(result.type, PaymentPayloadType.rawAddress);
      expect(calls, isEmpty);
      expectSynchronized(result);
    });

    test('empty address is invalid without generator invocation', () {
      final result = compute(address: '', amount: 42);
      expect(result.type, PaymentPayloadType.invalid);
      expect(result.error, PaymentPayloadError.emptyAddress);
      expect(result.payload, isEmpty);
      expect(calls, isEmpty);
    });

    test('URI generator error is invalid with no raw-address fallback', () {
      final result = compute(
        amount: 42,
        overrideGenerator: (_, __, ___) => throw StateError('synthetic'),
      );
      expect(result.type, PaymentPayloadType.invalid);
      expect(result.error, PaymentPayloadError.uriGenerationFailed);
      expect(result.rawAddress, 'synthetic-address');
      expect(result.payload, isEmpty);
    });

    test('empty URI generator result is invalid', () {
      final result = compute(amount: 42, overrideGenerator: (_, __, ___) => '');
      expect(result.type, PaymentPayloadType.invalid);
      expect(result.error, PaymentPayloadError.uriGenerationFailed);
      expect(result.payload, isEmpty);
    });

    test('empty diversified address equivalent is invalid', () {
      final result = compute(address: '', memo: 'memo');
      expect(result.error, PaymentPayloadError.emptyAddress);
      expect(calls, isEmpty);
    });

    test('negative amount is invalid without generator invocation', () {
      final result = compute(amount: -1, memo: 'memo');
      expect(result.error, PaymentPayloadError.negativeAmount);
      expect(calls, isEmpty);
    });

    test('memo-incompatible receiver with memo is invalid', () {
      final result = compute(memo: 'memo', memoCapable: false);
      expect(result.error, PaymentPayloadError.memoNotSupported);
      expect(calls, isEmpty);
    });
  });
}

class _GeneratorCall {
  final String address;
  final int amount;
  final String memo;

  const _GeneratorCall(this.address, this.amount, this.memo);

  @override
  bool operator ==(Object other) =>
      other is _GeneratorCall &&
      address == other.address &&
      amount == other.amount &&
      memo == other.memo;

  @override
  int get hashCode => Object.hash(address, amount, memo);
}
