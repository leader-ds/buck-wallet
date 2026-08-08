import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:warp_api/warp_api.dart';

import '../accounts.dart';
import '../generated/intl/messages.dart';
import '../appsettings.dart';
import '../store2.dart';
import '../tablelist.dart';
import 'utils.dart';
import 'widgets.dart';

class TxPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => TxPageState();
}

class TxPageState extends State<TxPage> {
  @override
  void initState() {
    super.initState();
    syncStatus2.latestHeight?.let((height) {
      Future(() async {
        final txListUpdated =
            await WarpApi.transparentSync(aa.coin, aa.id, height);
        if (txListUpdated) aa.update(height); // reload if updated
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return SortSetting(
      child: Observer(
        builder: (context) {
          aaSequence.seqno;
          aaSequence.settingsSeqno;
          syncStatus2.changed;
          if (aa.txs.items.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'No BUCK transactions yet',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  Gap(8),
                  Text('Sent and received transactions will appear here.'),
                ],
              ),
            );
          }
          return TableListPage(
            listKey: PageStorageKey('txs'),
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            view: appSettings.txView,
            items: aa.txs.items,
            metadata: TableListTxMetadata(),
          );
        },
      ),
    );
  }
}

class TableListTxMetadata extends TableListItemMetadata<Tx> {
  @override
  List<Widget>? actions(BuildContext context) => null;

  @override
  Text? headerText(BuildContext context) => null;

  @override
  void inverseSelection() {}

  @override
  Widget toListTile(BuildContext context, int index, Tx tx,
      {void Function(void Function())? setState}) {
    ZMessage? message;
    try {
      message = aa.messages.items.firstWhere((m) => m.txId == tx.id);
    } on StateError {
      message = null;
    }
    return TxItem(tx, message, index: index);
  }

  @override
  List<ColumnDefinition> columns(BuildContext context) {
    final s = S.of(context);
    return [
      ColumnDefinition(label: 'Direction'),
      ColumnDefinition(field: 'height', label: s.height, numeric: true),
      ColumnDefinition(field: 'confirmations', label: 'Status'),
      ColumnDefinition(field: 'timestamp', label: s.datetime),
      ColumnDefinition(field: 'value', label: s.amount),
      ColumnDefinition(field: 'fullTxId', label: s.txID),
      ColumnDefinition(field: 'address', label: s.address),
      ColumnDefinition(field: 'memo', label: s.memo),
    ];
  }

  @override
  DataRow toRow(BuildContext context, int index, Tx tx) {
    final t = Theme.of(context);
    final color = amountColor(context, tx.value);
    var style = t.textTheme.bodyMedium!.copyWith(color: color);
    style = weightFromAmount(style, tx.value);
    final a = tx.contact ?? centerTrim(tx.address ?? '');
    final m = tx.memo?.let((m) => m.substring(0, min(m.length, 32))) ?? '';

    return DataRow.byIndex(
        index: index,
        cells: [
          DataCell(_DirectionLabel(tx.value)),
          DataCell(Text("${tx.height}")),
          DataCell(Text(_transactionStatus(tx.confirmations))),
          DataCell(Text("${txDateFormat.format(tx.timestamp)}")),
          DataCell(Text(_formatBuckAmount(tx.value),
              style: style, textAlign: TextAlign.left)),
          DataCell(Text("${tx.txId}")),
          DataCell(Text("$a")),
          DataCell(Text("$m")),
        ],
        onSelectChanged: (_) => gotoTx(context, index));
  }

  @override
  SortConfig2? sortBy(String field) {
    aa.txs.setSortOrder(field);
    return aa.txs.order;
  }

  @override
  Widget? header(BuildContext context) => null;
}

class TxItem extends StatelessWidget {
  final Tx tx;
  final int? index;
  final ZMessage? message;
  TxItem(this.tx, this.message, {this.index});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = amountColor(context, tx.value);

    final direction = _transactionDirection(tx.value);
    final dateString = Text(
      humanizeDateTime(context, tx.timestamp),
      style: theme.textTheme.bodySmall,
    );
    final value = Text(
      _formatBuckAmount(tx.value),
      style: theme.textTheme.titleMedium!.apply(color: color),
      textAlign: TextAlign.end,
    );
    final status = Text(
      _transactionStatus(tx.confirmations),
      style: theme.textTheme.bodySmall,
      textAlign: TextAlign.end,
    );
    final trailing = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [dateString, value, status],
    );

    return GestureDetector(
        onTap: () {
          if (index != null) gotoTx(context, index!);
        },
        behavior: HitTestBehavior.translucent,
        child: Row(
          children: [
            CircleAvatar(
              child: Icon(_transactionDirectionIcon(tx.value)),
            ),
            Gap(15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(direction, style: theme.textTheme.titleMedium),
                  MessageContentWidget(
                      tx.contact ?? tx.address ?? '', message, tx.memo ?? ''),
                ],
              ),
            ),
            Gap(8),
            Flexible(child: trailing),
          ],
        ));
  }
}

class TransactionPage extends StatefulWidget {
  final int txIndex;

  TransactionPage(this.txIndex);

  @override
  State<StatefulWidget> createState() => TransactionState();
}

class TransactionState extends State<TransactionPage> {
  late final s = S.of(context);
  late int idx;

  @override
  void initState() {
    super.initState();
    idx = widget.txIndex;
  }

  Tx get tx => aa.txs.items[idx];

  @override
  Widget build(BuildContext context) {
    final n = aa.txs.items.length;
    return Scaffold(
        appBar: AppBar(title: Text(s.transactionDetails), actions: [
          IconButton(
              onPressed: idx > 0 ? prev : null, icon: Icon(Icons.chevron_left)),
          IconButton(
              onPressed: idx < n - 1 ? next : null,
              icon: Icon(Icons.chevron_right)),
          IconButton(onPressed: open, icon: Icon(Icons.open_in_browser)),
        ]),
        body: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                Gap(16),
                Panel(
                  'Direction',
                  child: Row(
                    children: [
                      Icon(_transactionDirectionIcon(tx.value)),
                      Gap(8),
                      Text(
                        _transactionDirection(tx.value),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                Gap(8),
                Panel(s.amount, text: _formatBuckAmount(tx.value)),
                Gap(8),
                Panel('Status',
                    text: _transactionStatusLabel(tx.confirmations)),
                Gap(8),
                Panel(s.confs, text: (tx.confirmations ?? 0).toString()),
                Gap(8),
                Panel(s.txID, text: tx.fullTxId),
                Gap(8),
                Panel(s.height, text: tx.height.toString()),
                Gap(8),
                Panel(s.timestamp, text: noteDateFormat.format(tx.timestamp)),
                if (tx.address?.trim().isNotEmpty == true) ...[
                  Gap(8),
                  Panel(s.address, text: tx.address),
                ],
                if (tx.contact?.trim().isNotEmpty == true) ...[
                  Gap(8),
                  Panel(s.contactName, text: tx.contact), // Add Contact button
                ],
                if (tx.memo?.trim().isNotEmpty == true) ...[
                  Gap(8),
                  Panel(s.memo, text: tx.memo),
                ],
                Gap(8),
                ..._memos()
              ],
            ),
          ),
        ));
  }

  List<Widget> _memos() {
    List<Widget> ms = [];
    for (var txm in tx.memos) {
      if (txm.memo.trim().isEmpty) continue;
      ms.add(Gap(8));
      ms.add(Panel(s.memo, text: txm.address + '\n' + txm.memo));
    }
    return ms;
  }

  open() {
    openTxInExplorer(tx.fullTxId);
  }

  prev() {
    if (idx > 0) idx -= 1;
    setState(() {});
  }

  next() {
    final n = aa.txs.items.length;
    if (idx < n - 1) idx += 1;
    setState(() {});
  }

  _addContact() async {
    // await addContact(context, ContactT(address: tx.address));
  }
}

void gotoTx(BuildContext context, int index) {
  GoRouter.of(context).push('/history/details?index=$index');
}

String _transactionDirection(double value) {
  if (value < 0) return 'Sent';
  if (value > 0) return 'Received';
  return 'Transaction';
}

IconData _transactionDirectionIcon(double value) {
  if (value < 0) return Icons.arrow_outward;
  if (value > 0) return Icons.arrow_downward;
  return Icons.swap_horiz;
}

String _formatBuckAmount(double value) {
  final sign = value > 0
      ? '+'
      : value < 0
          ? '−'
          : '';
  return '$sign${decimalFormat(value.abs(), MAX_PRECISION)} BUCK';
}

String _transactionStatusLabel(int? confirmations) =>
    (confirmations ?? 0) > 0 ? 'Confirmed' : 'Pending';

String _transactionStatus(int? confirmations) {
  final count = confirmations ?? 0;
  return count > 0 ? 'Confirmed ($count)' : 'Pending';
}

class _DirectionLabel extends StatelessWidget {
  final double value;

  const _DirectionLabel(this.value);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_transactionDirectionIcon(value), size: 18),
        Gap(4),
        Text(_transactionDirection(value)),
      ],
    );
  }
}
