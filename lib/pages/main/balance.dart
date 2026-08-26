import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';

import '../../appsettings.dart';
import '../../store2.dart';
import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../utils.dart';

class BalanceWidget extends StatefulWidget {
  final int? mode;
  final void Function()? onMode;
  BalanceWidget(this.mode, {this.onMode, super.key});
  @override
  State<StatefulWidget> createState() => BalanceState();
}

class BalanceState extends State<BalanceWidget> {
  @override
  void initState() {
    super.initState();
    Future(marketPrice.update);
  }

  String _formatFiat(double x) =>
      decimalFormat(x, 2, symbol: appSettings.currency);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mode = widget.mode;

    const color = buckCherryRed;

    return Observer(builder: (context) {
      aaSequence.settingsSeqno;
      aa.height;
      aa.currency;
      appStore.flat;

      final hideBalance = hide(appStore.flat);
      if (hideBalance) return SizedBox();

      final c = coins[aa.coin];
      final total = totalBalance;
      final balHi = decimalFormat((total ~/ 100000) / 1000.0, 3);
      final balLo = (total % 100000).toString().padLeft(5, '0');
      final fiat = marketPrice.price;
      final balFiat = fiat?.let((fx) => total * fx / ZECUNIT);
      final txtFiat = fiat?.let(_formatFiat);
      final txtBalFiat = balFiat?.let(_formatFiat);

      final balanceWidget = SizedBox(
        width: double.infinity,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            textBaseline: TextBaseline.alphabetic,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            children: [
              Text(c.symbol, style: t.textTheme.bodyLarge),
              Text(balHi,
                  style: t.textTheme.displayMedium?.apply(color: color)),
              Text(balLo, style: t.textTheme.bodyMedium),
            ],
          ),
        ),
      );
      final selected = selectedBalance;
      final s = S.of(context);

      return GestureDetector(
        onTap: widget.onMode,
        child: Column(
          children: [
            Text(s.totalBalance, style: t.textTheme.labelLarge),
            const SizedBox(height: 8),
            balanceWidget,
            Padding(padding: EdgeInsets.all(4)),
            if (txtBalFiat != null)
              Text(txtBalFiat, style: t.textTheme.titleLarge),
            if (txtFiat != null) Text('1 ${c.ticker} = $txtFiat'),
            if (mode != null) ...[
              const Divider(height: 24),
              Text('${receiverLabel(s, mode)} ${s.balance}',
                  style: t.textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(amountToString2(selected), style: t.textTheme.titleLarge),
            ],
          ],
        ),
      );
    });
  }

  bool hide(bool flat) {
    switch (appSettings.autoHide) {
      case 0:
        return true;
      case 1:
        return flat;
      default:
        return false;
    }
  }

  int get selectedBalance {
    switch (widget.mode) {
      case null:
      case 0:
      case 4:
        return totalBalance;
      case 1:
        return aa.poolBalances.transparent;
      case 2:
        return aa.poolBalances.sapling;
      case 3:
        return aa.poolBalances.orchard;
    }
    throw 'Unreachable';
  }

  int get totalBalance =>
      aa.poolBalances.transparent +
      aa.poolBalances.sapling +
      aa.poolBalances.orchard;

  String receiverLabel(S s, int? mode) {
    switch (mode) {
      case 1:
        return s.transparent;
      case 2:
        return s.sapling;
      case 3:
        return s.orchard;
      case 4:
        return s.diversified;
      default:
        return s.mainAddress;
    }
  }
}
