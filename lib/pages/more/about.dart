import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:mustache_template/mustache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../generated/intl/messages.dart';
import '../../src/version.dart';
import '../../appsettings.dart';
import '../utils.dart';

class AboutPage extends StatelessWidget {
  final String contentTemplate;
  AboutPage(this.contentTemplate);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final template = Template(contentTemplate);
    var content = template.renderString({'APP': APP_NAME});
    final id = commitId.substring(0, 8);
    final versionString = "${s.version}: $packageVersion/$id";
    return Scaffold(
        appBar: AppBar(title: Text(s.about)),
        body: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              children: [
                Image.asset(
                  Theme.of(context).brightness == Brightness.dark
                      ? 'assets/branding/buck_wordmark_white.png'
                      : 'assets/branding/buck_wordmark_black.png',
                  height: 72,
                  fit: BoxFit.contain,
                ),
                Gap(8),
                Text(
                  'BUCK Wallet',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Gap(16),
                MarkdownBody(data: content),
                Padding(padding: EdgeInsets.symmetric(vertical: 8)),
                TextButton(
                    child: Text(versionString),
                    onPressed: () => openGithub(commitId)),
              ],
            ),
          ),
        ));
  }

  openGithub(String commitId) {
    launchUrl(Uri.parse("https://github.com/hhanh00/zwallet/commit/$commitId"));
  }
}

class DisclaimerPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _DisclaimerState();
}

class _DisclaimerState extends State<DisclaimerPage> {
  List<bool> accepted = [false, false, false];
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.disclaimer)),
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: constraints.maxHeight < 620 ? 16 : 24,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111111),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: buckCherryRed, width: 2),
                    ),
                    child: Column(children: [
                      Image.asset(
                        'assets/branding/buck_symbol_white.png',
                        height: constraints.maxHeight < 620 ? 72 : 104,
                        fit: BoxFit.contain,
                      ),
                      const Gap(12),
                      Text(
                        s.disclaimerText,
                        style: t.textTheme.headlineMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ]),
                  ),
                  const Gap(20),
                  DisclaimerItem(
                    accepted[0],
                    name: 'd1',
                    text: s.disclaimer_1,
                    onChanged: (v) => setState(() => accepted[0] = v!),
                  ),
                  Gap(16),
                  DisclaimerItem(
                    accepted[1],
                    name: 'd2',
                    text: s.disclaimer_2,
                    onChanged: (v) => setState(() => accepted[1] = v!),
                  ),
                  Gap(16),
                  DisclaimerItem(
                    accepted[2],
                    name: 'd3',
                    text: s.disclaimer_3,
                    onChanged: (v) => setState(() => accepted[2] = v!),
                  ),
                  const Gap(20),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: buckCherryRed,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
                      ),
                    ),
                    onPressed: allAccepted ? _accept : null,
                    icon: const Icon(Icons.check),
                    label: Text(s.newAccount),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  _accept() async {
    appSettings.disclaimer = true;
    await appSettings.save(await SharedPreferences.getInstance());
    GoRouter.of(context).push('/first_account');
  }

  bool get allAccepted => !accepted.any((e) => !e);
}

class DisclaimerItem extends StatelessWidget {
  final String name;
  final String text;
  final bool accepted;
  final void Function(bool?)? onChanged;
  DisclaimerItem(this.accepted,
      {super.key, required this.name, required this.text, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: accepted ? buckCherryRed : t.colorScheme.outline,
                width: accepted ? 2 : 1)),
        child: Padding(
            padding: EdgeInsets.all(8),
            child: FormBuilderCheckbox(
              name: name,
              activeColor: buckCherryRed,
              title: Text(text, style: t.textTheme.titleMedium),
              onChanged: onChanged,
            )));
  }
}
