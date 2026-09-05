import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/toast.dart';

/// The full stock ledger for one ingredient: every purchase, mix and
/// adjustment, with a running balance.
class StockHistoryPage extends StatelessWidget {
  const StockHistoryPage({
    super.key,
    required this.state,
    required this.ingredientId,
  });

  final AppState state;
  final String ingredientId;

  static String _date(DateTime d) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final ing = state.byId(ingredientId);
        if (ing == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Stock history')),
            body: const Center(
              child: Text('This ingredient no longer exists.'),
            ),
          );
        }
        return _build(context, ing);
      },
    );
  }

  Widget _build(BuildContext context, Ingredient ing) {
    final theme = Theme.of(context);
    final set = state.settings;
    final ledger = state.ledgerFor(ingredientId).reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(ing.displayName, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
            child: OutlinedButton.icon(
              onPressed: () => _adjust(context, ing),
              icon: const Icon(Icons.tune),
              label: const Text('Adjust'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${ing.stockMl.toStringAsFixed(1)} mL on hand',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: ing.stockIsNegative
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                  Text(
                    '${ing.stockGrams.toStringAsFixed(1)} g  •  '
                    '${moneyPerMl(ing.costPerMl, set)}  •  worth '
                    '${money(ing.stockMl * ing.costPerMl, set)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (ing.stockIsNegative) ...[
                    Gap.vMd,
                    Container(
                      padding: const EdgeInsets.all(Gap.md),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Negative balance',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                          Gap.vXs,
                          Text(
                            'The ledger says you used more than you bought. '
                            'Usually an unlogged purchase, or a mix logged '
                            'twice. Count the bottle and set it straight.',
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                          Gap.vSm,
                          FilledButton.tonal(
                            onPressed: () => _adjust(context, ing),
                            child: const Text('Set actual amount'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Gap.vMd,
          Text('Ledger', style: theme.textTheme.titleLarge),
          Text(
            'Newest first. Every change to stock, and what it left behind.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          Gap.vMd,
          if (ledger.isEmpty)
            EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'Nothing recorded yet',
              message:
                  'Restock it, or set an opening balance, and every change '
                  'shows up here.',
              actionLabel: 'Adjust stock',
              onAction: () => _adjust(context, ing),
            ),
          for (final e in ledger) _entry(context, e, theme),
        ],
      ),
    );
  }

  Widget _entry(BuildContext context, StockLedgerEntry e, ThemeData theme) {
    final positive = e.deltaMl >= 0;
    return Card(
      child: ListTile(
        leading: Icon(
          e.icon,
          color: positive
              ? theme.colorScheme.primary
              : theme.colorScheme.outline,
        ),
        title: Text(e.label),
        subtitle: Text(
          '${_date(e.at)}'
          '${e.detail.isNotEmpty ? '  •  ${e.detail}' : ''}',
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${positive ? '+' : ''}${e.deltaMl.toStringAsFixed(2)} mL',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: positive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
              ),
            ),
            Text(
              '→ ${e.balanceAfter.toStringAsFixed(2)} mL',
              style: theme.textTheme.bodySmall?.copyWith(
                color: e.balanceAfter < -1e-9
                    ? theme.colorScheme.error
                    : theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _adjust(BuildContext context, Ingredient ing) async {
    final done = await showAdjustDialog(context, state: state, ingredient: ing);
    if (done == true && context.mounted) {
      showToast(context, 'Stock adjusted.');
    }
  }
}

/// Adjust-stock dialog. Offers both "change by" and "set to", because both
/// are natural: you spill 5 mL, or you count the bottle and it says 42.
Future<bool?> showAdjustDialog(
  BuildContext context, {
  required AppState state,
  required Ingredient ingredient,
}) => showDialog<bool>(
  context: context,
  builder: (context) => _AdjustDialog(state: state, ingredient: ingredient),
);

class _AdjustDialog extends StatefulWidget {
  const _AdjustDialog({required this.state, required this.ingredient});
  final AppState state;
  final Ingredient ingredient;

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  bool _setMode = true;
  AdjustReason _reason = AdjustReason.correction;

  @override
  void initState() {
    super.initState();
    _amount.text = widget.ingredient.stockMl.toStringAsFixed(1);
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ing = widget.ingredient;
    final v = parseNum(_amount.text);
    final valid = v != null;

    final resulting = !valid
        ? ing.stockMl
        : _setMode
        ? v
        : (_reason == AdjustReason.spill ||
                  _reason == AdjustReason.evaporation ||
                  _reason == AdjustReason.disposal ||
                  _reason == AdjustReason.gift
              ? ing.stockMl - v
              : ing.stockMl + v);

    return AlertDialog(
      title: Text('Adjust ${ing.displayName}'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Set to')),
                  ButtonSegment(value: false, label: Text('Change by')),
                ],
                selected: {_setMode},
                onSelectionChanged: (s) => setState(() {
                  _setMode = s.first;
                  _amount.text = _setMode ? ing.stockMl.toStringAsFixed(1) : '';
                }),
              ),
              Gap.vMd,
              TextField(
                controller: _amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _setMode
                      ? 'Actual amount on hand (mL)'
                      : 'Amount (mL)',
                  errorText: _amount.text.trim().isNotEmpty && !valid
                      ? 'Enter a number'
                      : null,
                ),
              ),
              Gap.vSm,
              DropdownMenu<AdjustReason>(
                initialSelection: _reason,
                label: const Text('Reason'),
                expandedInsets: EdgeInsets.zero,
                onSelected: (r) => setState(() => _reason = r ?? _reason),
                dropdownMenuEntries: [
                  for (final r in AdjustReason.values)
                    if (r != AdjustReason.opening)
                      DropdownMenuEntry(value: r, label: adjustReasonLabel(r)),
                ],
              ),
              Gap.vSm,
              TextField(
                controller: _note,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              Gap.vMd,
              Container(
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${ing.stockMl.toStringAsFixed(1)} mL',
                        style: TextStyle(color: theme.colorScheme.outline),
                      ),
                    ),
                    const Icon(Icons.arrow_forward, size: 16),
                    Gap.hSm,
                    Text(
                      '${resulting.toStringAsFixed(1)} mL',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: resulting < -1e-9
                            ? theme.colorScheme.error
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: !valid
              ? null
              : () {
                  if (_setMode) {
                    widget.state.setStockTo(ing.id, v, note: _note.text.trim());
                  } else {
                    final negative =
                        _reason == AdjustReason.spill ||
                        _reason == AdjustReason.evaporation ||
                        _reason == AdjustReason.disposal ||
                        _reason == AdjustReason.gift;
                    widget.state.addAdjustment(
                      ingredientId: ing.id,
                      deltaMl: negative ? -v : v,
                      reason: _reason,
                      note: _note.text.trim(),
                    );
                  }
                  Navigator.pop(context, true);
                },
          child: const Text('Record'),
        ),
      ],
    );
  }
}
