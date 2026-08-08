import 'buck.dart';
import 'coin.dart';
import 'ycash.dart';
import 'zcash.dart';
import 'zcashtest.dart';

CoinBase buck = BuckCoin();
CoinBase ycash = YcashCoin();
CoinBase zcash = ZcashCoin();
CoinBase zcashtest = ZcashTestCoin();

final coins = [buck];

final activationDate = DateTime(2018, 10, 29);