enum ReceiverType { transparent, sapling, orchard, diversified, unified }

enum ReceiverBalanceContext { transparent, sapling, orchard, total }

class ReceiverOption {
  const ReceiverOption({
    required this.addressMode,
    required this.receiverType,
    required this.address,
    required this.memoCapable,
    required this.balanceContext,
  });

  final int addressMode;
  final ReceiverType receiverType;
  final String address;
  final bool memoCapable;
  final ReceiverBalanceContext balanceContext;
}

typedef ReceiverAddressResolver = String Function(int addressMode);

List<ReceiverOption> buildReceiverOptions({
  required int availableMode,
  required bool supportsUa,
  required ReceiverAddressResolver addressForMode,
}) {
  const orderedModes = [1, 2, 3, 4, 0];
  final options = <ReceiverOption>[];

  for (final mode in orderedModes) {
    if (!_isAvailable(mode, availableMode, supportsUa)) continue;

    final address = addressForMode(mode).trim();
    if (address.isEmpty) continue;

    options.add(
      ReceiverOption(
        addressMode: mode,
        receiverType: _receiverType(mode),
        address: address,
        memoCapable: mode != 1,
        balanceContext: _balanceContext(mode),
      ),
    );
  }

  return List.unmodifiable(options);
}

ReceiverOption? reconcileHomeReceiver(
  List<ReceiverOption> options,
  int? selectedAddressMode,
) {
  final preserved = optionForMode(options, selectedAddressMode);
  if (preserved != null) return preserved;

  return optionForMode(options, 1) ??
      optionForMode(options, 0) ??
      (options.isEmpty ? null : options.first);
}

ReceiverOption? reconcilePaymentReceiver(
  List<ReceiverOption> options,
  int? selectedAddressMode,
) {
  return optionForMode(options, selectedAddressMode) ??
      optionForMode(options, 0) ??
      (options.isEmpty ? null : options.first);
}

ReceiverOption? optionForMode(List<ReceiverOption> options, int? addressMode) {
  if (addressMode == null) return null;
  for (final option in options) {
    if (option.addressMode == addressMode) return option;
  }
  return null;
}

bool _isAvailable(int mode, int availableMode, bool supportsUa) {
  if (mode == 0) return supportsUa;
  if (mode == 4) return true;
  return availableMode & (1 << (mode - 1)) != 0;
}

ReceiverType _receiverType(int mode) {
  switch (mode) {
    case 1:
      return ReceiverType.transparent;
    case 2:
      return ReceiverType.sapling;
    case 3:
      return ReceiverType.orchard;
    case 4:
      return ReceiverType.diversified;
    default:
      return ReceiverType.unified;
  }
}

ReceiverBalanceContext _balanceContext(int mode) {
  switch (mode) {
    case 1:
      return ReceiverBalanceContext.transparent;
    case 2:
      return ReceiverBalanceContext.sapling;
    case 3:
      return ReceiverBalanceContext.orchard;
    default:
      return ReceiverBalanceContext.total;
  }
}
