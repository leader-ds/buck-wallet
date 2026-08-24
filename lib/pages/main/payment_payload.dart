typedef PaymentUriGenerator =
    String Function(String address, int amount, String memo);

enum PaymentPayloadType { rawAddress, paymentUri, invalid }

enum PaymentPayloadError {
  emptyAddress,
  negativeAmount,
  memoNotSupported,
  uriGenerationFailed,
}

class PaymentPayloadResult {
  final String rawAddress;
  final String payload;
  final PaymentPayloadType type;
  final PaymentPayloadError? error;

  const PaymentPayloadResult._({
    required this.rawAddress,
    required this.payload,
    required this.type,
    this.error,
  });

  bool get isValid => type != PaymentPayloadType.invalid;

  static PaymentPayloadResult compute({
    required String address,
    required int? amount,
    required String? memo,
    required bool memoCapable,
    required PaymentUriGenerator generatePaymentUri,
  }) {
    if (address.isEmpty) {
      return _invalid(address, PaymentPayloadError.emptyAddress);
    }
    if (amount != null && amount < 0) {
      return _invalid(address, PaymentPayloadError.negativeAmount);
    }

    final hasMemo = memo?.isNotEmpty == true;
    if (hasMemo && !memoCapable) {
      return _invalid(address, PaymentPayloadError.memoNotSupported);
    }

    if ((amount == null || amount == 0) && !hasMemo) {
      return PaymentPayloadResult._(
        rawAddress: address,
        payload: address,
        type: PaymentPayloadType.rawAddress,
      );
    }

    try {
      final payload = generatePaymentUri(address, amount ?? 0, memo ?? '');
      if (payload.isEmpty) {
        return _invalid(address, PaymentPayloadError.uriGenerationFailed);
      }
      return PaymentPayloadResult._(
        rawAddress: address,
        payload: payload,
        type: PaymentPayloadType.paymentUri,
      );
    } catch (_) {
      return _invalid(address, PaymentPayloadError.uriGenerationFailed);
    }
  }

  static PaymentPayloadResult _invalid(
    String address,
    PaymentPayloadError error,
  ) => PaymentPayloadResult._(
    rawAddress: address,
    payload: '',
    type: PaymentPayloadType.invalid,
    error: error,
  );
}
