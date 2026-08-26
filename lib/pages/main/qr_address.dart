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
import 'receiver_option.dart';

class AddressCarousel extends StatefulWidget {
  final void Function(int mode)? onAddressModeChanged;
  final ValueChanged<int?>? onSelectionChanged;
  final int? amount;
  final String? memo;
  final bool paymentURI;
  final bool homeSelection;
  final int? initialAddressMode;
  AddressCarousel({
    this.amount,
    this.memo,
    this.paymentURI = true,
    this.homeSelection = false,
    this.initialAddressMode,
    this.onAddressModeChanged,
    this.onSelectionChanged,
  });

  @override
  State<StatefulWidget> createState() => AddressCarouselState();
}

class AddressCarouselState extends State<AddressCarousel> {
  List<ReceiverOption> receiverOptions = const [];
  int? selectedAddressMode;
  int index = 0;
  bool _refreshScheduled = false;
  final _selectionCoordinator = ReceiverSelectionCoordinator();
  final carouselController = CarouselSliderController();

  @override
  void initState() {
    super.initState();
    selectedAddressMode = widget.initialAddressMode;
    _reconcileReceiverOptions(notify: true);
  }

  List<ReceiverOption> _buildReceiverOptions() {
    final c = coins[aa.coin];
    final availableMode = WarpApi.getAvailableAddrs(aa.coin, aa.id);
    return buildReceiverOptions(
      availableMode: availableMode,
      supportsUa: c.supportsUA,
      addressForMode: _addressForMode,
    );
  }

  String _addressForMode(int addressMode) {
    if (aa.id == 0) return '';
    if (addressMode == 4) return aa.diversifiedAddress;
    final uaType =
        addressMode == 0 ? coinSettings.uaType : 1 << (addressMode - 1);
    return WarpApi.getAddress(aa.coin, aa.id, uaType);
  }

  void _reconcileReceiverOptions({bool notify = false}) {
    final options = _buildReceiverOptions();
    final selected = widget.homeSelection
        ? reconcileHomeReceiver(options, selectedAddressMode)
        : reconcilePaymentReceiver(options, selectedAddressMode);
    final nextIndex = selected == null
        ? 0
        : options.indexWhere(
            (option) => option.addressMode == selected.addressMode,
          );
    final pageChanged = nextIndex != index;
    receiverOptions = options;
    selectedAddressMode = selected?.addressMode;
    index = nextIndex;

    final notification = _selectionCoordinator.update(
      selected?.addressMode,
      notifyCurrent: notify,
    );
    if (notification != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_isCurrentNotification(notification)) return;
        if (!_selectionCoordinator.consume(notification)) return;
        _notifyParent(notification.addressMode);
      });
    }
    if (pageChanged) {
      final expectedMode = selected?.addressMode;
      final expectedIndex = nextIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || receiverOptions.isEmpty || expectedMode == null) return;
        if (selectedAddressMode != expectedMode || index != expectedIndex)
          return;
        if (expectedIndex < 0 || expectedIndex >= receiverOptions.length)
          return;
        if (receiverOptions[expectedIndex].addressMode != expectedMode) return;
        carouselController.jumpToPage(expectedIndex);
      });
    }
  }

  bool _isCurrentNotification(ReceiverSelectionNotification notification) {
    if (selectedAddressMode != notification.addressMode) return false;
    if (notification.addressMode == null) return receiverOptions.isEmpty;
    return optionForMode(receiverOptions, notification.addressMode) != null;
  }

  void _notifyParent(int? addressMode) {
    widget.onSelectionChanged?.call(addressMode);
    if (addressMode != null) {
      widget.onAddressModeChanged?.call(addressMode);
    }
  }

  @override
  void didUpdateWidget(AddressCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reconcileReceiverOptions();
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        aaSequence.seqno;
        aaSequence.settingsSeqno;
        aa.diversifiedAddress;
        final nextOptions = _buildReceiverOptions();
        final optionsChanged = !_sameOptions(receiverOptions, nextOptions);
        if (optionsChanged && !_refreshScheduled) {
          _refreshScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _refreshScheduled = false;
              _reconcileReceiverOptions();
            });
          });
        }
        final addresses = receiverOptions
            .map(
              (option) => QRAddressWidget(
                option.addressMode,
                address: option.address,
                uaType: coinSettings.uaType,
                amount: widget.amount,
                memo: widget.memo,
                paymentURI: widget.paymentURI,
              ),
            )
            .toList();
        if (addresses.isEmpty) return const SizedBox(height: 286);
        return Column(
          children: [
            CarouselSlider(
              carouselController: carouselController,
              items: addresses,
              options: CarouselOptions(
                height: 286,
                initialPage: index,
                viewportFraction: 1.0,
                onPageChanged: (i, reason) {
                  final option = receiverOptions[i];
                  setState(() {
                    index = i;
                    selectedAddressMode = option.addressMode;
                  });
                  final notification =
                      _selectionCoordinator.update(option.addressMode);
                  if (notification != null &&
                      _selectionCoordinator.consume(notification)) {
                    _notifyParent(option.addressMode);
                  }
                },
              ),
            ),
            const Gap(2),
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
                        margin: EdgeInsets.symmetric(
                          vertical: 8.0,
                          horizontal: 4.0,
                        ),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: buckCherryRed.withOpacity(
                            kv.key == index ? 0.9 : 0.4,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        );
      },
    );
  }

  bool _sameOptions(List<ReceiverOption> a, List<ReceiverOption> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].addressMode != b[i].addressMode || a[i].address != b[i].address)
        return false;
    }
    return true;
  }
}

class QRAddressWidget extends StatefulWidget {
  final int addressMode;
  final String? address;
  final int? amount;
  final String? memo;
  final int uaType;
  final bool paymentURI;

  QRAddressWidget(
    this.addressMode, {
    super.key,
    this.address,
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

    return Observer(
      builder: (context) {
        aa.diversifiedAddress;
        final result = paymentPayload;
        final payload = result.payload;
        return Column(
          children: [
            if (result.isValid)
              QrImage(
                data: payload,
                version: QrVersions.auto,
                size: 184.0,
                backgroundColor: Colors.white,
              )
            else
              const SizedBox(width: 184.0, height: 184.0),
            const Gap(6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SelectableText(
                payload,
                textAlign: TextAlign.center,
                maxLines: 3,
                style: t.textTheme.bodySmall,
              ),
            ),
            const Gap(2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.outlined(
                  tooltip: S.of(context).copy,
                  style: IconButton.styleFrom(foregroundColor: buckCherryRed),
                  onPressed: result.isValid ? () => addressCopy(payload) : null,
                  icon: const Icon(Icons.copy),
                ),
                const Gap(8),
                IconButton.outlined(
                  tooltip: S.of(context).qr,
                  style: IconButton.styleFrom(foregroundColor: buckCherryRed),
                  onPressed: result.isValid ? () => qrCode(payload) : null,
                  icon: const Icon(Icons.qr_code),
                ),
              ],
            ),
            Text(addressType, style: t.textTheme.labelSmall),
          ],
        );
      },
    );
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
    if (widget.address != null) return widget.address!;
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
      final qrUri = Uri(
        path: '/showqr',
        queryParameters: {'title': widget.memo ?? ''},
      );
      GoRouter.of(context).push(qrUri.toString(), extra: payload);
    }
  }
}
