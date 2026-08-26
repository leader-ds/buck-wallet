import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../../accounts.dart';
import '../../appsettings.dart';
import '../../generated/intl/messages.dart';
import '../../store2.dart';
import '../utils.dart';
import 'balance.dart';
import 'qr_address.dart';
import 'sync_status.dart';

class HomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Observer(builder: (context) {
        return HomePageInner(key: ValueKey(aaSequence.seqno));
      });
}

class HomePageInner extends StatefulWidget {
  HomePageInner({super.key});
  @override
  State<HomePageInner> createState() => _HomeState();
}

class _HomeState extends State<HomePageInner> {
  static const desktopBreakpoint = 900.0;
  final balanceKey = GlobalKey<BalanceState>();
  int? addressMode;

  @override
  void initState() {
    super.initState();
    syncStatus2.update();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        child: Observer(builder: (context) {
          aaSequence.seqno;
          aa.poolBalances;
          syncStatus2.changed;
          return LayoutBuilder(builder: (context, constraints) {
            final wide = constraints.maxWidth >= desktopBreakpoint;
            final identity = _WalletIdentityPanel(
              addressMode: addressMode,
              balanceKey: balanceKey,
            );
            final information = _WalletInformationPanel(
              showBackup: !aa.saved,
              expandToFill: wide,
              onBackup: _backup,
            );
            final receive = _WalletReceivePanel(
              onSelectionChanged: (mode) {
                if (addressMode != mode) setState(() => addressMode = mode);
              },
              onSend: () => _send(false),
              onCustomSend: () => _send(true),
            );
            return Column(children: [
              SyncStatusWidget(),
              const Gap(2),
              if (wide)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 31, child: identity),
                      const Gap(16),
                      Expanded(flex: 30, child: information),
                      const Gap(16),
                      Expanded(flex: 39, child: receive),
                    ],
                  ),
                )
              else
                Column(children: [
                  identity,
                  const Gap(16),
                  information,
                  const Gap(16),
                  receive,
                ]),
            ]);
          });
        }),
      ),
    );
  }

  Future<void> _send(bool custom) async {
    if (appSettings.protectSend) {
      final authed = await authBarrier(context, dismissable: true);
      if (!authed) return;
    }
    if (!mounted) return;
    GoRouter.of(context).push('/account/quick_send?custom=${custom ? 1 : 0}');
  }

  void _backup() => GoRouter.of(context).push('/more/backup');
}

class _WalletIdentityPanel extends StatelessWidget {
  const _WalletIdentityPanel(
      {required this.addressMode, required this.balanceKey});
  final int? addressMode;
  final GlobalKey<BalanceState> balanceKey;

  @override
  Widget build(BuildContext context) => _DashboardPanel(
        child: Column(children: [
          _DashboardPanel(
            inset: true,
            child: SizedBox(
              height: 166,
              width: double.infinity,
              child: Image.asset(
                'assets/branding/buck_logo_coin_white.png',
                fit: BoxFit.contain,
              ),
            ),
          ),
          const Gap(10),
          _DashboardPanel(
            inset: true,
            child: BalanceWidget(addressMode, key: balanceKey),
          ),
        ]),
      );
}

class _WalletInformationPanel extends StatelessWidget {
  const _WalletInformationPanel({
    required this.showBackup,
    required this.expandToFill,
    required this.onBackup,
  });
  final bool showBackup;
  final bool expandToFill;
  final VoidCallback onBackup;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    final status = !syncStatus2.connected
        ? s.error
        : syncStatus2.paused
            ? s.syncPaused
            : s.sync;
    Widget informationRow(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(children: [
            Icon(icon, size: 21, color: buckCherryRed),
            const Gap(10),
            Expanded(child: Text(label)),
            Flexible(
              child: Text(value,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
        );
    return _DashboardPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: showBackup && expandToFill
            ? MainAxisAlignment.spaceBetween
            : MainAxisAlignment.start,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.status, style: theme.textTheme.titleLarge),
            const Gap(10),
            informationRow(
                Icons.account_balance_wallet_outlined, s.account, aa.name),
            const Divider(),
            informationRow(Icons.sync_outlined, s.status, status),
            const Divider(),
            informationRow(Icons.storage_outlined, s.height,
                '${syncStatus2.syncedHeight}'),
            if (syncStatus2.latestHeight != null) ...[
              const Divider(),
              informationRow(Icons.cloud_outlined, s.server,
                  '${syncStatus2.latestHeight}'),
            ],
          ]),
          if (showBackup)
            Padding(
              padding: EdgeInsets.only(top: expandToFill ? 12 : 18),
              child: Center(
                child: OutlinedButton.icon(
                  style:
                      OutlinedButton.styleFrom(foregroundColor: buckCherryRed),
                  onPressed: onBackup,
                  icon: const Icon(Icons.backup_outlined),
                  label: Text(s.backupMissing),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WalletReceivePanel extends StatelessWidget {
  const _WalletReceivePanel({
    required this.onSelectionChanged,
    required this.onSend,
    required this.onCustomSend,
  });
  final ValueChanged<int?> onSelectionChanged;
  final VoidCallback onSend;
  final VoidCallback onCustomSend;

  @override
  Widget build(BuildContext context) => _DashboardPanel(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            AddressCarousel(
              homeSelection: true,
              onSelectionChanged: onSelectionChanged,
            ),
            const Gap(6),
            GestureDetector(
              onLongPress: onCustomSend,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: buckCherryRed),
                onPressed: onSend,
                icon: const Icon(Icons.send),
                label: Text(S.of(context).send),
              ),
            ),
          ],
        ),
      );
}

class _DashboardPanel extends StatelessWidget {
  const _DashboardPanel({required this.child, this.inset = false});
  final Widget child;
  final bool inset;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = inset
        ? Color.alphaBlend(colors.onSurface.withOpacity(0.035), colors.surface)
        : colors.surface;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(inset ? 12 : 16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(inset ? 22 : 26),
        border:
            inset ? null : Border.all(color: colors.outline.withOpacity(0.28)),
      ),
      child: child,
    );
  }
}
