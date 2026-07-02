import 'package:flutter/material.dart';

import 'coin.dart';

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
  // TODO: Replace with official BUCK asset in the branding milestone.
  AssetImage image = AssetImage('assets/zcash.png');

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
