import 'package:flutter/material.dart';

import 'coin.dart';

// Fixed BUCK network fee, expressed in base units.
const int BUCK_FIXED_FEE = 10000;

class BuckCoin extends CoinBase {
  int coin = 0;
  String name = "BUCK";
  String app = "BUCK Wallet";
  String symbol = "\$";
  String currency = "buck";
  int coinIndex = 133;
  String ticker = "BUCK";
  String dbName = "buck.db";
  String? marketTicker = null;
  @override
  int get fixedNetworkFee => BUCK_FIXED_FEE;
  AssetImage image = AssetImage('assets/branding/buck_logo_small_ui.png');

  List<LWInstance> lwd = [
    LWInstance("BUCK Lightwallet", "https://wallet.buck.red:9067"),
  ];

  int defaultAddrMode = 0;
  int defaultUAType = 7;
  bool supportsUA = true;
  bool supportsMultisig = false;
  bool supportsLedger = false;

  List<double> weights = [0.05, 0.25, 2.50];

  List<String> blockExplorers = [
    "https://explorer.buck.red/tx",
    "https://insight.buck.red/tx"
  ];
}
