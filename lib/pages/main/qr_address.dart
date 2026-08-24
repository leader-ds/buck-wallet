import 'package:carousel_slider/carousel_slider.dart';
import 'package:flutter/material.dart' hide CarouselSliderController;
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../utils.dart';
import 'payment_payload.dart';

class AddressCarousel extends StatefulWidget {
  final void Function(int mode)? onAddressModeChanged;
  final int? amount;
  final String? memo;
  final bool paymentURI;
  AddressCarousel(
      {this.amount,
      this.memo,
      this.paymentURI = true,
      this.onAddressModeChanged});

  @override
  State<StatefulWidget> createState() => AddressCarouselState();
}

class AddressCarouselState extends State<AddressCarousel> {
  final int availableMode = WarpApi.getAvailableAddrs(aa.coin, aa.id);
  List<int> addressModes = [];
  List<Widget> addresses = [];
  int index = 0;
  final carouselController = CarouselSliderController();

  @override
  void initState() {
    super.initState();
    updateAddresses();
  }

  void updateAddresses() {
    addresses.clear();
    addressModes.clear();

    final c = coins[aa.coin];
    for (var i = 0; i < 5; i++) {
      final am = (c.defaultAddrMode - i) % 5;
      if (am == 0 && !c.supportsUA) continue;
      if (am == c.defaultAddrMode ||
          am == 4 ||
          availableMode & (1 << (am - 1)) != 0) {
        final address = QRAddressWidget(
          am,
          uaType: coinSettings.uaType,
          amount: widget.amount,
          memo: widget.memo,
          paymentURI: widget.paymentURI,
        );
        addresses.add(address);
        addressModes.add(am);
      }
    }
  }

  @override
  void didUpdateWidget(AddressCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateAddresses();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        CarouselSlider(
          carouselController: carouselController,
          items: addresses,
          options: CarouselOptions(
            height: 280,
            viewportFraction: 1.0,
            onPageChanged: (i, reason) {
              widget.onAddressModeChanged?.call(addressModes[i]);
              setState(() => index = i);
            },
          ),
        ),
        Gap(8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: addresses
              .asMap()
              .entries
              .map(
                (kv) => GestureDetector(
                  onTap: () {
                    carouselController.animateToPage(kv.key);
                  },
                  child: Container(
                    width: 12.0,
                    height: 12.0,
                    margin:
                        EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.primaryColor
                            .withOpacity(kv.key == index ? 0.9 : 0.4)),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class QRAddressWidget extends StatefulWidget {
  final int addressMode;
  final int? amount;
  final String? memo;
  final int uaType;
  final bool paymentURI;

  QRAddressWidget(
    this.addressMode, {
    super.key,
    required this.uaType,
    this.amount,
    this.memo,
    this.paymentURI = true,
  });

  @override
  State<StatefulWidget> createState() => _QRAddressState();
}

class _QRAddressState extends State<QRAddressWidget> {
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final image = aa.coin == 0
        ? const AssetImage('assets/branding/buck_logo_qr.png')
        : coins[aa.coin].image;

    return Observer(builder: (context) {
      aa.diversifiedAddress;
      final result = paymentPayload;
      final payload = result.payload;
      return Column(children: [
        if (result.isValid)
          QrImage(
            data: payload,
            version: QrVersions.auto,
            size: 200.0,
            backgroundColor: Colors.white,
            embeddedImage: image,
          )
        else
          SizedBox(width: 200.0, height: 200.0),
        Gap(8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(centerTrim(payload)),
            Padding(padding: EdgeInsets.all(4)),
            IconButton.outlined(
                onPressed: result.isValid ? () => addressCopy(payload) : null,
                icon: Icon(Icons.copy)),
            Padding(padding: EdgeInsets.all(4)),
            IconButton.outlined(
                onPressed: result.isValid ? () => qrCode(payload) : null,
                icon: Icon(Icons.qr_code)),
          ],
        ),
        Text(addressType, style: t.textTheme.labelSmall)
      ]);
    });
  }

  String get addressType {
    final s = S.of(context);
    switch (widget.addressMode) {
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

  String get address {
    if (aa.id == 0) return '';
    final uaType;
    switch (widget.addressMode) {
      case 0:
        uaType = widget.uaType;
        break;
      case 4:
        return aa.diversifiedAddress;
      default:
        uaType = 1 << (widget.addressMode - 1);
        break;
    }
    return WarpApi.getAddress(aa.coin, aa.id, uaType);
  }

  PaymentPayloadResult get paymentPayload => PaymentPayloadResult.compute(
        address: address,
        amount: widget.amount,
        memo: widget.memo,
        memoCapable: widget.addressMode != 1,
        generatePaymentUri: (address, amount, memo) =>
            WarpApi.makePaymentURI(aa.coin, address, amount, memo),
      );

  addressCopy(String payload) {
    final s = S.of(context);
    Clipboard.setData(ClipboardData(text: payload));
    showSnackBar(s.addressCopiedToClipboard);
  }

  qrCode(String payload) {
    if (widget.paymentURI)
      GoRouter.of(context).push('/account/pay_uri');
    else {
      final qrUri =
          Uri(path: '/showqr', queryParameters: {'title': widget.memo ?? ''});
      GoRouter.of(context).push(qrUri.toString(), extra: payload);
    }
  }
}
