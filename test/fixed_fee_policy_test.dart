import 'package:buck_wallet/appsettings.dart';
import 'package:buck_wallet/coin/buck.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BUCK fixed-fee policy', () {
    test('automatic mode uses the fixed network fee', () {
      final fee = resolveFeeT(
        manualFee: false,
        configuredFee: 1,
        fixedNetworkFee: BUCK_FIXED_FEE,
      );

      expect(fee.scheme, 1);
      expect(fee.fee, BUCK_FIXED_FEE);
    });

    test('manual fee below the minimum uses the fixed network fee', () {
      final fee = resolveFeeT(
        manualFee: true,
        configuredFee: BUCK_FIXED_FEE - 1,
        fixedNetworkFee: BUCK_FIXED_FEE,
      );

      expect(fee.scheme, 1);
      expect(fee.fee, BUCK_FIXED_FEE);
    });

    test('manual fee equal to the minimum remains the fixed network fee', () {
      final fee = resolveFeeT(
        manualFee: true,
        configuredFee: BUCK_FIXED_FEE,
        fixedNetworkFee: BUCK_FIXED_FEE,
      );

      expect(fee.scheme, 1);
      expect(fee.fee, BUCK_FIXED_FEE);
    });

    test('manual fee above the minimum remains honored', () {
      final selectedFee = BUCK_FIXED_FEE + 1;
      final fee = resolveFeeT(
        manualFee: true,
        configuredFee: selectedFee,
        fixedNetworkFee: BUCK_FIXED_FEE,
      );

      expect(fee.scheme, 1);
      expect(fee.fee, selectedFee);
    });
  });

  group('coin without a fixed fee', () {
    test('automatic mode preserves dynamic fee behavior', () {
      final fee = resolveFeeT(
        manualFee: false,
        configuredFee: 12345,
      );

      expect(fee.scheme, 0);
      expect(fee.fee, 12345);
    });

    test('manual mode preserves the configured fee', () {
      final fee = resolveFeeT(
        manualFee: true,
        configuredFee: 12345,
      );

      expect(fee.scheme, 1);
      expect(fee.fee, 12345);
    });

    test('a null fixed fee resolves normally', () {
      expect(
        () => resolveFeeT(
          manualFee: false,
          configuredFee: 0,
          fixedNetworkFee: null,
        ),
        returnsNormally,
      );
    });
  });
}
