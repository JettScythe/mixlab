import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../sync_merge.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';

/// Review screen for a merge. Nothing is applied until Apply is pressed,
/// and every change can be declined individually.
class MergePreviewPage extends StatefulWidget {
  const MergePreviewPage({super.key, required this.state, required this.plan});

  final AppState state;
  final MergePlan plan;

  @override
  State<MergePreviewPage> createState() => _MergePreviewPageState();
}

class _MergePreviewPageState extends State<MergePreviewPage> {
  bool _applying = false;

  MergePlan get plan => widget.plan;

  static String _when(DateTime? d) {
    if (d == null) return 'unknown time';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} days ago';
  }

  Future<void> _apply() async {
    setState(() => _applying = true);
    final summary = await widget.state.applyMerge(plan);
    if (!mounted) return;
    Navigator.pop(context, summary);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accepted = plan.items.where((i) => i.accept).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review merge'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
            child: FilledButton.icon(
              onPressed: _applying || (accepted == 0 && !plan.acceptSettings)
                  ? null
                  : _apply,
              icon: const Icon(Icons.merge),
              label: Text('Apply $accepted'),
            ),
          ),
        ],
      ),
      body: plan.isEmpty
          ? const EmptyState(
              icon: Icons.check_circle_outline,
              title: 'Already in sync',
              message: 'Nothing on the other device differs from this one.',
            )
          : ListView(
              padding: const EdgeInsets.all(Gap.lg),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'From ${plan.remoteDevice}',
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          'Exported ${_when(plan.exportedAt)}',
                          style: theme.textTheme.bodySmall,
                        ),
                        Gap.vMd,
                        Wrap(
                          spacing: Gap.md,
                          children: [
                            _stat(
                              theme,
                              'Add',
                              plan.countOf(MergeAction.add),
                              theme.colorScheme.primary,
                            ),
                            _stat(
                              theme,
                              'Update',
                              plan.countOf(MergeAction.update),
                              theme.colorScheme.tertiary,
                            ),
                            _stat(
                              theme,
                              'Remove',
                              plan.countOf(MergeAction.delete),
                              theme.colorScheme.error,
                            ),
                          ],
                        ),
                        Gap.vSm,
                        Text(
                          'Nothing changes until you press Apply. Ledger '
                          'events only ever add, so stock is recomputed '
                          'from the combined history.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (plan.incomingSettings != null)
                  Card(
                    child: CheckboxListTile(
                      value: plan.acceptSettings,
                      onChanged: (v) =>
                          setState(() => plan.acceptSettings = v ?? false),
                      title: const Text('Take their settings'),
                      subtitle: Text(
                        plan.settingsDetail.isEmpty
                            ? 'Newer than this device'
                            : plan.settingsDetail,
                      ),
                    ),
                  ),

                for (final type in RecordType.values) ..._section(theme, type),
              ],
            ),
    );
  }

  Widget _stat(ThemeData theme, String label, int n, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '$n',
        style: theme.textTheme.titleLarge?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(width: Gap.xs),
      Text(label, style: theme.textTheme.bodyMedium),
    ],
  );

  List<Widget> _section(ThemeData theme, RecordType type) {
    final items = plan.ofType(type);
    if (items.isEmpty) return const [];

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.lg, Gap.xs, Gap.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${recordTypeLabel(type)}s (${items.length})',
                style: theme.textTheme.titleMedium,
              ),
            ),
            TextButton(
              onPressed: () => setState(() {
                final allOn = items.every((i) => i.accept);
                for (final i in items) {
                  i.accept = !allOn;
                }
              }),
              child: Text(items.every((i) => i.accept) ? 'None' : 'All'),
            ),
          ],
        ),
      ),
      for (final item in items)
        Card(
          child: CheckboxListTile(
            value: item.accept,
            onChanged: (v) => setState(() => item.accept = v ?? false),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: switch (item.action) {
                      MergeAction.add => theme.colorScheme.primaryContainer,
                      MergeAction.update => theme.colorScheme.tertiaryContainer,
                      MergeAction.delete => theme.colorScheme.errorContainer,
                    },
                  ),
                  child: Text(
                    mergeActionLabel(item.action),
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(item.label, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            subtitle: Text(item.detail),
          ),
        ),
    ];
  }
}
