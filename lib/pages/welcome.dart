import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';

import '../generated/intl/messages.dart';
import 'utils.dart';

class WelcomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final t = Theme.of(context);
    return Scaffold(
        appBar: AppBar(title: Text(APP_NAME)),
        body: LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxHeight < 560;
          final logoHeight = compact ? 112.0 : 168.0;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(children: [
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: compact ? 20 : 32,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111111),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: buckCherryRed, width: 2),
                    ),
                    child: Image.asset(
                      'assets/branding/buck_logo_coin_white.png',
                      height: logoHeight,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const Gap(24),
                  Text(
                    s.welcomeToBuckWallet,
                    style: t.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const Gap(8),
                  Text(
                    s.thePrivateWalletMessenger,
                    style: t.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const Gap(24),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: buckCherryRed,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
                      ),
                    ),
                    onPressed: () => _onNew(context),
                    icon: const Icon(Icons.arrow_forward),
                    label: Text(s.newAccount),
                  ),
                ]),
              ),
            ),
          );
        }));
  }

  _onNew(BuildContext context) {
    GoRouter.of(context).push('/disclaimer');
  }
}
