import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.state});
  final AppState state;

  static String _date(DateTime d) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final logs = state.mixLog;
    final set = state.settings;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Mix history',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  '${logs.length} mixes  •  '
                  '${money(state.lifetimeMixCost, set)} of juice',
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: logs.isEmpty
                ? const Center(
                    child: Text(
                      'No mixes logged yet.\n'
                      'Log one from the Mix tab and it lands here.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (context, i) => _entry(context, logs[i], set),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _entry(BuildContext context, MixLog l, Settings set) {
    final theme = Theme.of(context);
    final days = l.daysSteeping;
    final steep = days <= 0
        ? 'mixed today'
        : days == 1
        ? 'steeping 1 day'
        : 'steeping $days days';

    return Card(
      child: ExpansionTile(
        title: Row(
          children: [
            Flexible(child: Text(l.label, overflow: TextOverflow.ellipsis)),
            if (l.weighed)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Tooltip(
                  message:
                      'Committed from weigh-along with real scale readings',
                  child: Icon(Icons.balance, size: 16),
                ),
              ),
            if (l.nicDrifted)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Tooltip(
                  message: 'Finished strength differs from the target',
                  child: Icon(
                    Icons.info_outline,
                    size: 16,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
          ],
        ),
        // Shows what the mix actually came out at, not what was aimed for.
        subtitle: Text(
          '${_date(l.mixedAt)}  •  $steep\n'
          '${l.batchMl.toStringAsFixed(1)} mL  •  '
          '${l.totalGrams.toStringAsFixed(2)} g  •  '
          '${l.actualNic.toStringAsFixed(2)} mg  •  '
          '${l.actualVgPercent.toStringAsFixed(0)}% VG  •  '
          '${money(l.totalCost, set)}',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drift notice sits above the ingredient list.
                if (l.nicDrifted)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Target was ${l.targetNic.toStringAsFixed(1)} mg/mL; '
                      'came out at ${l.actualNic.toStringAsFixed(2)}.',
                      style: TextStyle(color: theme.colorScheme.tertiary),
                    ),
                  ),
                for (final line in l.lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            line.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${line.grams.toStringAsFixed(2)} g   '
                          '${line.deductedMl.toStringAsFixed(2)} mL',
                        ),
                        if (line.deductedMl + 1e-9 < line.requestedMl)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Tooltip(
                              message:
                                  'Short at mix time: needed '
                                  '${line.requestedMl.toStringAsFixed(2)} mL',
                              child: Icon(
                                Icons.warning_amber_rounded,
                                size: 18,
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _confirmUndo(context, l),
                      icon: const Icon(Icons.undo),
                      label: const Text('Undo (restore stock)'),
                    ),
                    TextButton.icon(
                      onPressed: () => _confirmDeleteEntry(context, l),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete entry only'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmUndo(BuildContext context, MixLog l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Undo this mix?'),
        content: Text(
          'Restores exactly what was deducted for "${l.label}" '
          'and removes the entry.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Undo'),
          ),
        ],
      ),
    );
    if (ok == true) state.undoMix(l.id);
  }

  Future<void> _confirmDeleteEntry(BuildContext context, MixLog l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this entry?'),
        content: Text(
          'Removes the record of "${l.label}" without returning '
          'anything to inventory. Use this only if you already corrected '
          'stock by hand.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) state.deleteLogEntry(l.id);
  }
}
