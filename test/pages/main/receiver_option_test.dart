import 'package:flutter_test/flutter_test.dart';

import 'package:YWallet/pages/main/receiver_option.dart';

void main() {
  List<ReceiverOption> build({
    int availableMode = 7,
    bool supportsUa = true,
    String diversified = 'diversified',
    Set<int> emptyModes = const {},
  }) {
    return buildReceiverOptions(
      availableMode: availableMode,
      supportsUa: supportsUa,
      addressForMode: (mode) {
        if (emptyModes.contains(mode)) return '';
        return mode == 4 ? diversified : 'address-$mode';
      },
    );
  }

  group('BUCK receiver options', () {
    test('uses T, S, O, diversified, UA order', () {
      expect(build().map((option) => option.addressMode), [1, 2, 3, 4, 0]);
    });

    test('excludes unavailable receivers', () {
      expect(build(availableMode: 1).map((option) => option.addressMode), [
        1,
        4,
        0,
      ]);
    });

    test('excludes empty diversified and includes it when non-empty', () {
      expect(build(diversified: '').map((option) => option.addressMode), [
        1,
        2,
        3,
        0,
      ]);
      expect(build(diversified: 'new').map((option) => option.addressMode), [
        1,
        2,
        3,
        4,
        0,
      ]);
    });

    test('returns a completely empty option list', () {
      expect(
        build(
          availableMode: 0,
          supportsUa: false,
          diversified: '',
        ),
        isEmpty,
      );
    });

    test('excludes UA when support is true but its address is empty', () {
      expect(build(emptyModes: {0}).map((option) => option.addressMode), [
        1,
        2,
        3,
        4,
      ]);
    });

    test('excludes transparent when its availability bit has no address', () {
      expect(build(emptyModes: {1}).map((option) => option.addressMode), [
        2,
        3,
        4,
        0,
      ]);
    });

    test('returns no options when all receiver addresses are empty', () {
      expect(build(diversified: '', emptyModes: {0, 1, 2, 3}), isEmpty);
    });
  });

  group('Home reconciliation', () {
    test('initial selection is transparent when available', () {
      expect(reconcileHomeReceiver(build(), null)!.addressMode, 1);
    });

    test('falls back to UA when transparent is unavailable', () {
      expect(
        reconcileHomeReceiver(build(availableMode: 6), null)!.addressMode,
        0,
      );
    });

    test('falls back to first valid receiver without T or UA', () {
      expect(
        reconcileHomeReceiver(
          build(availableMode: 6, supportsUa: false),
          null,
        )!
            .addressMode,
        2,
      );
    });

    test('preserves a selected mode across index changes', () {
      final selected = reconcileHomeReceiver(build(), 3)!;
      final changed = build(availableMode: 6);
      expect(changed.indexWhere((option) => option.addressMode == 3), 1);
      expect(
        reconcileHomeReceiver(changed, selected.addressMode)!.addressMode,
        3,
      );
    });

    test('reconciles immediately when selected mode disappears', () {
      expect(reconcileHomeReceiver(build(diversified: ''), 4)!.addressMode, 1);
    });

    test('new diversified receiver does not replace current receiver', () {
      expect(
        reconcileHomeReceiver(build(diversified: 'new'), 2)!.addressMode,
        2,
      );
    });

    test('account replacement does not retain an absent receiver', () {
      final replacement = build(availableMode: 6, diversified: '');
      final selected = reconcileHomeReceiver(replacement, 1)!;
      expect(selected.addressMode, 0);
      expect(selected.address, 'address-0');
    });

    test('clears selection when selected receiver has no fallback', () {
      final empty = build(
        availableMode: 0,
        supportsUa: false,
        diversified: '',
      );
      expect(reconcileHomeReceiver(empty, 3), isNull);
    });

    test('uses T when the selected receiver disappears', () {
      expect(reconcileHomeReceiver(build(diversified: ''), 4)!.addressMode, 1);
    });

    test('uses only UA when the selected receiver disappears', () {
      final options = build(
        availableMode: 0,
        diversified: '',
        emptyModes: {1, 2, 3},
      );
      expect(reconcileHomeReceiver(options, 4)!.addressMode, 0);
    });

    test('recovers from empty state using T-first selection', () {
      final empty = build(
        availableMode: 0,
        supportsUa: false,
        diversified: '',
      );
      expect(reconcileHomeReceiver(empty, null), isNull);
      expect(reconcileHomeReceiver(build(), null)!.addressMode, 1);
    });

    test('diversified disappearance falls back to T', () {
      expect(reconcileHomeReceiver(build(diversified: ''), 4)!.addressMode, 1);
    });

    test('valid user selection survives an unrelated option rebuild', () {
      final rebuilt = build(diversified: 'replacement');
      expect(reconcileHomeReceiver(rebuilt, 3)!.addressMode, 3);
    });
  });

  test('payment reconciliation remains independent of Home T-first', () {
    final options = build();
    expect(reconcileHomeReceiver(options, null)!.addressMode, 1);
    expect(reconcilePaymentReceiver(options, 2)!.addressMode, 2);
    expect(reconcilePaymentReceiver(options, 9)!.addressMode, 0);
  });

  test('payment selection disappears using payment fallback, not Home policy',
      () {
    final options = build(availableMode: 6);
    expect(reconcilePaymentReceiver(options, 1)!.addressMode, 0);
  });
}
