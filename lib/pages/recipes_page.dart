import 'package:flutter/material.dart';
import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/recipe.dart';

import '../state.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/star_rating.dart';
import '../widgets/toast.dart';
import 'import_page.dart';
import 'recipe_detail_page.dart';
import 'recipe_editor_page.dart';

enum _Sort { name, flavorCount, flavorPercent, nicotine }

String _sortLabel(_Sort s) => switch (s) {
  _Sort.name => 'Name',
  _Sort.flavorCount => 'Flavor count',
  _Sort.flavorPercent => 'Total flavor %',
  _Sort.nicotine => 'Nicotine',
};

class RecipesPage extends StatefulWidget {
  const RecipesPage({super.key, required this.state, required this.onMix});

  final AppState state;
  final VoidCallback onMix;

  @override
  State<RecipesPage> createState() => _RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage> {
  final _search = TextEditingController();
  _Sort _sort = _Sort.name;
  bool _canMakeOnly = false;

  AppState get state => widget.state;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static String _ago(DateTime d) {
    final days = DateTime.now().difference(d).inDays;
    return switch (days) {
      <= 0 => 'today',
      1 => 'yesterday',
      < 30 => '$days days ago',
      < 60 => 'a month ago',
      < 365 => '${(days / 30).round()} months ago',
      _ => '${(days / 365).round()} year(s) ago',
    };
  }

  List<Recipe> get _visible {
    final q = _search.text.trim().toLowerCase();
    final list = state.recipes.where((r) {
      if (q.isEmpty) return true;
      if (r.name.toLowerCase().contains(q)) return true;
      if (r.notes.toLowerCase().contains(q)) return true;
      return r.flavors.any((f) {
        final ing = state.byId(f.ingredientId);
        final label = ing?.displayName ?? f.name;
        return label.toLowerCase().contains(q);
      });
    }).toList();

    if (_canMakeOnly) list.removeWhere((r) => !state.canMakeNow(r));

    list.sort(switch (_sort) {
      _Sort.name => (a, b) => a.name.toLowerCase().compareTo(
        b.name.toLowerCase(),
      ),
      _Sort.flavorCount => (a, b) => b.flavors.length.compareTo(
        a.flavors.length,
      ),
      _Sort.flavorPercent => (a, b) => b.totalFlavorPercent.compareTo(
        a.totalFlavorPercent,
      ),
      _Sort.nicotine => (a, b) => b.targetNic.compareTo(a.targetNic),
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recipes = _visible;
    final hasAny = state.recipes.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Recipes', style: theme.textTheme.headlineSmall),
              ),
              OutlinedButton.icon(
                onPressed: _openImport,
                icon: const Icon(Icons.content_paste_go),
                label: const Text('Import'),
              ),
              Gap.hSm,
              FilledButton.icon(
                onPressed: () => _openEditor(null),
                icon: const Icon(Icons.add),
                label: const Text('New recipe'),
              ),
            ],
          ),
          Gap.vMd,
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search name, notes or flavor',
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(_search.clear),
                          ),
                  ),
                ),
              ),
              Gap.hMd,
              PopupMenuButton<_Sort>(
                initialValue: _sort,
                onSelected: (v) => setState(() => _sort = v),
                tooltip: 'Sort',
                itemBuilder: (context) => [
                  for (final v in _Sort.values)
                    PopupMenuItem(value: v, child: Text(_sortLabel(v))),
                ],
                child: Chip(
                  avatar: const Icon(Icons.sort, size: 18),
                  label: Text(_sortLabel(_sort)),
                ),
              ),
              Gap.hSm,
              FilterChip(
                label: const Text('Can make now'),
                selected: _canMakeOnly,
                onSelected: (v) => setState(() => _canMakeOnly = v),
              ),
            ],
          ),
          Gap.vSm,
          Text(
            '${recipes.length} of ${state.recipes.length} shown',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          Gap.vSm,
          Expanded(
            child: recipes.isEmpty
                ? (hasAny
                      ? EmptyState(
                          icon: Icons.filter_alt_off_outlined,
                          title: 'Nothing matches',
                          message: _canMakeOnly
                              ? 'No recipe is fully mixable from current '
                                    'stock. Turn off the filter to see them '
                                    'all.'
                              : 'Try a different search.',
                          actionLabel: _canMakeOnly ? 'Show all' : null,
                          onAction: _canMakeOnly
                              ? () => setState(() => _canMakeOnly = false)
                              : null,
                        )
                      : EmptyState(
                          icon: Icons.menu_book_outlined,
                          title: 'No recipes yet',
                          message:
                              'Paste one in from e-liquid-recipes.com or '
                              'AllTheFlavors, or build one from scratch.',
                          actionLabel: 'Import a recipe',
                          onAction: _openImport,
                        ))
                : ListView.builder(
                    itemCount: recipes.length,
                    itemBuilder: (context, i) => _card(context, recipes[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, Recipe r) {
    final theme = Theme.of(context);
    final missing = r.flavors
        .where(
          (f) =>
              state.byId(f.ingredientId) == null &&
              state.flavorByName(f.name) == null,
        )
        .length;

    final mixCount = state.mixCountForRecipe(r.id);
    final lastMixed = state.lastMixedForRecipe(r.id);
    final avgRating = state.averageRatingForRecipe(r.id);
    final ratedCount = state
        .mixesForRecipe(r.id)
        .where((l) => l.rating != null)
        .length;
    final capacity = state.capacityFor(r);
    final canMake = state.canMakeNow(r);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDetail(r),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.sm, Gap.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      r.name,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (avgRating != null)
                    Padding(
                      padding: const EdgeInsets.only(right: Gap.sm),
                      child: StarSummary(average: avgRating, count: ratedCount),
                    ),
                  Text(
                    '${r.batchMl.toStringAsFixed(0)} mL  •  '
                    '${r.targetNic.toStringAsFixed(1)} mg  •  '
                    '${r.baseMode == BaseMode.maxVg ? 'Max VG' : '${r.targetVgPercent.toStringAsFixed(0)}% VG'}'
                    '  •  ${r.totalFlavorPercent.toStringAsFixed(1)}% flavor',
                    style: theme.textTheme.bodySmall,
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: (v) {
                      switch (v) {
                        case 'details':
                          _openDetail(r);
                        case 'edit':
                          _openEditor(r);
                        case 'duplicate':
                          _duplicate(r);
                        case 'delete':
                          _confirmDelete(r);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'details',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.insights_outlined),
                          title: Text('Details'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Edit'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'duplicate',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.copy_outlined),
                          title: Text('Duplicate'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_outline),
                          title: Text('Delete'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              if (mixCount > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.xs),
                  child: Text(
                    'Mixed $mixCount time${mixCount == 1 ? '' : 's'}'
                    '${lastMixed != null ? ' • last ${_ago(lastMixed)}' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),

              // Stock capacity, the "can I make this right now" line.
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Row(
                  children: [
                    Icon(
                      canMake ? Icons.check_circle_outline : Icons.block,
                      size: 14,
                      color: canMake
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: Gap.xs),
                    Flexible(
                      child: Text(
                        capacity == null
                            ? 'Stock not tracked for this one'
                            : canMake
                            ? 'Can make up to ${capacity.toStringAsFixed(0)} '
                                  'mL from stock'
                            : 'Only enough for '
                                  '${capacity.toStringAsFixed(1)} mL',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: canMake
                              ? theme.colorScheme.outline
                              : theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              if (r.notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.xs, right: Gap.sm),
                  child: Text(r.notes, style: theme.textTheme.bodySmall),
                ),

              for (final f in r.flavors)
                Builder(
                  builder: (context) {
                    final ing =
                        state.byId(f.ingredientId) ??
                        state.flavorByName(f.name);
                    final gone = ing == null;
                    return Text(
                      '${f.percent.toStringAsFixed(1)}%   '
                      '${ing?.displayName ?? f.name}'
                      '${gone ? '  (not in inventory)' : ''}',
                      style: gone
                          ? TextStyle(color: theme.colorScheme.error)
                          : null,
                    );
                  },
                ),

              if (missing > 0)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    '$missing flavor(s) missing — they will be skipped when '
                    'loaded.',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),

              Gap.vSm,
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () {
                      state.requestLoadRecipe(r);
                      widget.onMix();
                    },
                    icon: const Icon(Icons.science),
                    label: const Text('Load into calculator'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _openDetail(r),
                    icon: const Icon(Icons.insights_outlined),
                    label: const Text('Details'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _openEditor(r),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openDetail(Recipe r) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          RecipeDetailPage(state: state, recipeId: r.id, onMix: widget.onMix),
    ),
  );

  Future<void> _openImport() async {
    final r = await Navigator.of(context).push<Recipe>(
      MaterialPageRoute(builder: (_) => ImportRecipePage(state: state)),
    );
    if (r != null && mounted) setState(() {});
  }

  Future<void> _openEditor(Recipe? existing) async {
    final saved = await Navigator.of(context).push<Recipe>(
      MaterialPageRoute(
        builder: (_) => RecipeEditorPage(state: state, existing: existing),
      ),
    );
    if (saved == null || !mounted) return;
    showToast(
      context,
      existing == null ? 'Created "${saved.name}".' : 'Saved "${saved.name}".',
    );
  }

  void _duplicate(Recipe r) {
    final copy = state.duplicateRecipe(r.id);
    if (copy == null || !mounted) return;
    showToast(
      context,
      'Duplicated as "${copy.name}".',
      action: SnackBarAction(label: 'Edit', onPressed: () => _openEditor(copy)),
    );
  }

  Future<void> _confirmDelete(Recipe r) async {
    final mixes = state.mixCountForRecipe(r.id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${r.name}"?'),
        content: Text(
          '${r.flavors.length} flavor(s).'
          '${mixes > 0 ? ' $mixes logged mix(es) will lose their link to it, '
                    'but stay in your history.' : ''}'
          ' Your inventory is not affected.',
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
    if (ok != true) return;

    final removed = state.removeRecipe(r.id);
    if (removed == null || !mounted) return;
    showToast(
      context,
      'Deleted "${removed.$1.name}".',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => state.restoreRecipe(removed.$1, removed.$2),
      ),
    );
  }
}
