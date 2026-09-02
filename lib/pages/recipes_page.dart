import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';

class RecipesPage extends StatelessWidget {
  const RecipesPage({super.key, required this.state, required this.onMix});
  final AppState state;
  final VoidCallback onMix;

  @override
  Widget build(BuildContext context) {
    final recipes = state.recipes;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Recipes', style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              Text('${recipes.length} saved'),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: recipes.isEmpty
                ? const Center(
                    child: Text('No recipes yet — save one from the Mix tab.'),
                  )
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  '${r.batchMl.toStringAsFixed(0)} mL  •  '
                  '${r.targetNic.toStringAsFixed(1)} mg  •  '
                  '${r.targetVgPercent.toStringAsFixed(0)}% VG',
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete recipe',
                  onPressed: () => state.removeRecipe(r.id),
                ),
              ],
            ),
            if (r.notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  r.notes,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            for (final f in r.flavors)
              Builder(
                builder: (context) {
                  final ing =
                      state.byId(f.ingredientId) ?? state.flavorByName(f.name);
                  final missing = ing == null;
                  return Text(
                    '${f.percent.toStringAsFixed(1)}%   '
                    '${ing?.displayName ?? f.name}${missing ? '  (not in inventory)' : ''}',
                    style: missing
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  );
                },
              ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () {
                state.requestLoadRecipe(r);
                onMix();
              },
              icon: const Icon(Icons.science),
              label: const Text('Load into calculator'),
            ),
          ],
        ),
      ),
    );
  }
}
