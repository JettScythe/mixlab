import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../widgets/star_rating.dart';
import 'recipe_detail_page.dart';

enum _Filter { all, rated, unrated, weighed }

String _filterLabel(_Filter f) => switch (f) {
  _Filter.all => 'All',
  _Filter.rated => 'Rated',
  _Filter.unrated => 'Not rated',
  _Filter.weighed => 'Weighed',
};

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.state, required this.onMix});

  final AppState state;
  final VoidCallback onMix;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _search = TextEditingController();
  _Filter _filter = _Filter.all;

  AppState get state => widget.state;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static String _date(DateTime d) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  static String _steep(int days) => switch (days) {
    <= 0 => 'mixed today',
    1 => 'steeping 1 day',
    _ => 'steeping $days days',
  };

  List<MixLog> get _visible {
    final q = _search.text.trim().toLowerCase();
    return state.mixLog.where((l) {
      switch (_filter) {
        case _Filter.rated:
          if (l.rating == null) return false;
        case _Filter.unrated:
          if (l.rating != null) return false;
        case _Filter.weighed:
          if (!l.weighed) return false;
        case _Filter.all:
          break;
      }
      if (q.isEmpty) return true;
      if (l.label.toLowerCase().contains(q)) return true;
      if (l.tastingNotes.toLowerCase().contains(q)) return true;
      return l.lines.any((x) => x.name.toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final set = state.settings;
    final logs = _visible;
    final rated = state.ratedMixCount;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Mix history',
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              Flexible(
                child: Text(
                  '${state.mixLog.length} mixes  •  $rated rated  •  '
                  '${money(state.lifetimeMixCost, set)} of juice',
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search name, notes or ingredient',
                    border: const OutlineInputBorder(),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(_search.clear),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              PopupMenuButton<_Filter>(
                initialValue: _filter,
                onSelected: (v) => setState(() => _filter = v),
                tooltip: 'Filter',
                itemBuilder: (context) => [
                  for (final v in _Filter.values)
                    PopupMenuItem(value: v, child: Text(_filterLabel(v))),
                ],
                child: Chip(
                  avatar: const Icon(Icons.filter_list, size: 18),
                  label: Text(_filterLabel(_filter)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Text(
                      state.mixLog.isEmpty
                          ? 'No mixes logged yet.\n'
                                'Log one from the Mix tab and it lands here.'
                          : 'Nothing matches.',
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
    final recipe = state.recipeById(l.recipeId);
    final orphaned = l.recipeId != null && recipe == null;

    return Card(
      child: ExpansionTile(
        title: Row(
          children: [
            Flexible(child: Text(l.label, overflow: TextOverflow.ellipsis)),
            if (l.weighed)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Tooltip(
                  message: 'Committed from weigh-along with real readings',
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
            const Spacer(),
            if (l.rating != null) StarSummary(average: l.rating!.toDouble()),
          ],
        ),
        subtitle: Text(
          '${_date(l.mixedAt)}  •  ${_steep(l.daysSteeping)}\n'
          '${l.batchMl.toStringAsFixed(1)} mL  •  '
          '${l.totalGrams.toStringAsFixed(2)} g  •  '
          '${l.actualNic.toStringAsFixed(2)} mg  •  '
          '${l.actualVgPercent.toStringAsFixed(0)}% VG  •  '
          '${money(l.totalCost, set)}',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (l.nicDrifted)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Target was ${l.targetNic.toStringAsFixed(1)} mg/mL; '
                      'came out at ${l.actualNic.toStringAsFixed(2)}.',
                      style: TextStyle(color: theme.colorScheme.tertiary),
                    ),
                  ),
                _feedback(context, l, theme),
                const Divider(height: 20),
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
                if (orphaned)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'The recipe this came from has been deleted. Remix '
                      'still works — it rebuilds from this log.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => _remix(l),
                      icon: const Icon(Icons.replay),
                      label: const Text('Remix this'),
                    ),
                    if (recipe != null)
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => RecipeDetailPage(
                              state: state,
                              recipeId: recipe.id,
                              onMix: widget.onMix,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.menu_book_outlined),
                        label: const Text('View recipe'),
                      ),
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

  Widget _feedback(BuildContext context, MixLog l, ThemeData theme) {
    final steepAt = l.steepDaysAtRating;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('How was it?', style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              StarRating(
                value: l.rating,
                onChanged: (v) =>
                    state.rateMix(l.id, rating: v, clearRating: v == null),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _editNotes(l),
                icon: Icon(
                  l.tastingNotes.isEmpty
                      ? Icons.note_add_outlined
                      : Icons.edit_note,
                  size: 20,
                ),
                label: Text(l.tastingNotes.isEmpty ? 'Add notes' : 'Edit'),
              ),
            ],
          ),
          if (l.tastingNotes.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(l.tastingNotes),
          ],
          if (steepAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Tasted at $steepAt day${steepAt == 1 ? '' : 's'} steeped.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _remix(MixLog l) {
    state.requestLoadRecipe(state.recipeFromLog(l));
    widget.onMix();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Loaded "${l.label}" into the calculator.')),
    );
  }

  Future<void> _editNotes(MixLog l) async {
    final c = TextEditingController(text: l.tastingNotes);
    var rating = l.rating;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => AlertDialog(
          title: Text(l.label),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Mixed ${_date(l.mixedAt)} — ${_steep(l.daysSteeping)}.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                StarRating(
                  value: rating,
                  size: 30,
                  onChanged: (v) => setSheet(() => rating = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: c,
                  autofocus: true,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Tasting notes',
                    hintText:
                        'Too sweet at 2 weeks? Needs more custard? '
                        'Coil gunking?',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    final notes = c.text.trim();
    c.dispose();
    if (saved != true) return;
    state.rateMix(
      l.id,
      rating: rating,
      clearRating: rating == null,
      notes: notes,
    );
  }

  Future<void> _confirmUndo(BuildContext context, MixLog l) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Undo this mix?'),
        content: Text(
          'Restores exactly what was deducted for "${l.label}" and removes '
          'the entry, including any rating and notes.',
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
          'Removes the record of "${l.label}" without returning anything to '
          'inventory. Use this only if you already corrected stock by hand.',
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
