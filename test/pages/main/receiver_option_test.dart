import 'package:flutter_test/flutter_test.dart';

import 'package:YWallet/pages/main/receiver_option.dart';

void main() {
  List<ReceiverOption> build({
    int availableMode = 7,
    bool supportsUa = true,
    String diversified = 'diversified',
  }) {
    return buildReceiverOptions(
      availableMode: availableMode,
      supportsUa: supportsUa,
      addressForMode: (mode) => mode == 4 ? diversified : 'address-$mode',
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
        )!.addressMode,
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
  });

  test('payment reconciliation remains independent of Home T-first', () {
    final options = build();
    expect(reconcileHomeReceiver(options, null)!.addressMode, 1);
    expect(reconcilePaymentReceiver(options, 2)!.addressMode, 2);
    expect(reconcilePaymentReceiver(options, 9)!.addressMode, 0);
  });
}
