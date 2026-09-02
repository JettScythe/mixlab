import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../widgets/star_rating.dart';
import 'recipe_editor_page.dart';

/// Everything known about one recipe: its composition, every time it was
/// mixed, how those turned out, and what it has cost.
class RecipeDetailPage extends StatelessWidget {
  const RecipeDetailPage({
    super.key,
    required this.state,
    required this.recipeId,
    required this.onMix,
  });

  final AppState state;
  final String recipeId;

  /// Switches the shell to the calculator tab.
  final VoidCallback onMix;

  static String ago(DateTime d) {
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

  static String date(DateTime d) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final r = state.recipeById(recipeId);
        if (r == null) {
          // Deleted while this page was open.
          return Scaffold(
            appBar: AppBar(title: const Text('Recipe')),
            body: const Center(child: Text('This recipe no longer exists.')),
          );
        }
        return _build(context, r);
      },
    );
  }

  Widget _build(BuildContext context, Recipe r) {
    final set = state.settings;
    final mixes = state.mixesForRecipe(r.id);
    final rated = mixes.where((l) => l.rating != null).toList();
    final avg = state.averageRatingForRecipe(r.id);
    final spend = mixes.fold(0.0, (a, l) => a + l.totalCost);
    final volume = mixes.fold(0.0, (a, l) => a + l.batchMl);

    return Scaffold(
      appBar: AppBar(
        title: Text(r.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Edit recipe',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<Recipe>(
                builder: (_) => RecipeEditorPage(state: state, existing: r),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton.icon(
              onPressed: () {
                state.requestLoadRecipe(r);
                onMix();
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.science),
              label: const Text('Mix this'),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth > 900;
          final left = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _summary(context, r, mixes, avg, rated.length, spend, volume),
              const SizedBox(height: 16),
              _composition(context, r),
            ],
          );
          final right = _timeline(context, mixes, set);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: left),
                      const SizedBox(width: 16),
                      Expanded(flex: 3, child: right),
                    ],
                  )
                : Column(children: [left, const SizedBox(height: 16), right]),
          );
        },
      ),
    );
  }

  Widget _summary(
    BuildContext context,
    Recipe r,
    List<MixLog> mixes,
    double? avg,
    int ratedCount,
    double spend,
    double volume,
  ) {
    final theme = Theme.of(context);
    final set = state.settings;
    final last = state.lastMixedForRecipe(r.id);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (r.notes.isNotEmpty) ...[
              Text(r.notes, style: theme.textTheme.bodyMedium),
              const Divider(height: 24),
            ],
            if (avg != null) ...[
              Row(
                children: [
                  Text('Average rating', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  StarRating(value: avg.round(), size: 20),
                  const SizedBox(width: 6),
                  Text(
                    avg.toStringAsFixed(1),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Text(
                'from $ratedCount rated mix${ratedCount == 1 ? '' : 'es'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const Divider(height: 24),
            ],
            _stat(context, 'Times mixed', '${mixes.length}'),
            if (last != null) _stat(context, 'Last mixed', ago(last)),
            _stat(context, 'Total volume', '${volume.toStringAsFixed(0)} mL'),
            _stat(context, 'Total spend', money(spend, set)),
            if (volume > 0)
              _stat(
                context,
                'Cost per ${set.refBottleMl.toStringAsFixed(0)} mL',
                money(spend / volume * set.refBottleMl, set),
              ),
            const Divider(height: 24),
            _stat(context, 'Batch', '${r.batchMl.toStringAsFixed(0)} mL'),
            _stat(
              context,
              'Nicotine',
              '${r.targetNic.toStringAsFixed(1)} mg/mL',
            ),
            _stat(
              context,
              'Ratio',
              '${r.targetVgPercent.toStringAsFixed(0)}% VG',
            ),
            _stat(
              context,
              'Total flavor',
              '${r.totalFlavorPercent.toStringAsFixed(1)}%',
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          value,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  Widget _composition(BuildContext context, Recipe r) {
    final theme = Theme.of(context);
    final set = state.settings;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Flavors', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (r.flavors.isEmpty)
              Text(
                'No flavors — this is just base.',
                style: theme.textTheme.bodySmall,
              ),
            for (final f in r.flavors)
              Builder(
                builder: (context) {
                  final ing =
                      state.byId(f.ingredientId) ?? state.flavorByName(f.name);
                  final gone = ing == null;
                  final needMl = r.batchMl * f.percent / 100;
                  final short = ing != null && needMl > ing.stockMl + 1e-9;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 52,
                          child: Text(
                            '${f.percent.toStringAsFixed(1)}%',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            ing?.displayName ?? f.name,
                            overflow: TextOverflow.ellipsis,
                            style: gone
                                ? TextStyle(color: theme.colorScheme.error)
                                : null,
                          ),
                        ),
                        if (gone)
                          Text(
                            'not in inventory',
                            style: TextStyle(
                              color: theme.colorScheme.error,
                              fontSize: 12,
                            ),
                          )
                        else ...[
                          Text(
                            '${needMl.toStringAsFixed(2)} mL',
                            style: theme.textTheme.bodySmall,
                          ),
                          if (short)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Tooltip(
                                message:
                                    'Only ${ing.stockMl.toStringAsFixed(1)} '
                                    'mL in stock',
                                child: Icon(
                                  Icons.warning_amber_rounded,
                                  size: 18,
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            if (r.flavors.isNotEmpty) ...[
              const Divider(height: 20),
              Text(
                'Volumes shown at the recipe default of '
                '${r.batchMl.toStringAsFixed(0)} mL, in ${set.currency} '
                'terms from your current stock.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _timeline(BuildContext context, List<MixLog> mixes, Settings set) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Mix history', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              mixes.isEmpty
                  ? 'Never mixed yet.'
                  : 'Newest first. Ratings and notes are edited from the '
                        'History tab.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (mixes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'Mix it, and every batch shows up here with\n'
                    'what it cost and how it turned out.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            for (final l in mixes) _mixTile(context, l, set),
          ],
        ),
      ),
    );
  }

  Widget _mixTile(BuildContext context, MixLog l, Settings set) {
    final theme = Theme.of(context);
    final steepAt = l.steepDaysAtRating;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
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
              Text(
                date(l.mixedAt),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                ago(l.mixedAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              if (l.weighed)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Tooltip(
                    message: 'Weighed on a scale',
                    child: Icon(Icons.balance, size: 15),
                  ),
                ),
              const Spacer(),
              if (l.rating != null) StarSummary(average: l.rating!.toDouble()),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${l.batchMl.toStringAsFixed(0)} mL  •  '
            '${l.totalGrams.toStringAsFixed(1)} g  •  '
            '${l.actualNic.toStringAsFixed(1)} mg  •  '
            '${l.actualVgPercent.toStringAsFixed(0)}% VG  •  '
            '${money(l.totalCost, set)}',
            style: theme.textTheme.bodySmall,
          ),
          if (l.nicDrifted)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Target was ${l.targetNic.toStringAsFixed(1)} mg/mL.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ),
          if (l.tastingNotes.isNotEmpty) ...[
            const SizedBox(height: 6),
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
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () {
                state.requestLoadRecipe(state.recipeFromLog(l));
                onMix();
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.replay, size: 18),
              label: const Text('Remix this batch'),
            ),
          ),
        ],
      ),
    );
  }
}
