import 'package:flutter/material.dart';
import 'package:mixlab/models/recipe.dart';

import '../state.dart';

/// Picks a recipe from the bundled starter library.
///
/// Returns the raw paste-dialect text of the chosen recipe — not a saved
/// Recipe — so the normal import review runs over it: the user sees which
/// ingredients will be created (all of them, at zero stock and zero cost)
/// before anything lands in the library.
///
/// Returns null if dismissed, or the empty string when the user chose
/// "paste my own" instead.
Future<String?> showStarterLibraryPicker(BuildContext context, AppState state) {
  return showDialog<String>(
    context: context,
    builder: (_) => _StarterLibraryDialog(state: state),
  );
}

class _StarterLibraryDialog extends StatefulWidget {
  const _StarterLibraryDialog({required this.state});

  final AppState state;

  @override
  State<_StarterLibraryDialog> createState() => _StarterLibraryDialogState();
}

class _StarterLibraryDialogState extends State<_StarterLibraryDialog> {
  Future<List<Recipe>>? _recipes;

  @override
  void initState() {
    super.initState();
    _recipes = widget.state.parseStarterRecipes();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Starter recipes'),
      content: SizedBox(
        width: 420,
        height: 320,
        child: FutureBuilder<List<Recipe>>(
          future: _recipes,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final recipes = snap.data ?? const <Recipe>[];
            return ListView.builder(
              itemCount: recipes.length,
              itemBuilder: (context, i) {
                final r = recipes[i];
                return ListTile(
                  title: Text(r.name),
                  subtitle: Text(
                    '${r.flavors.length} flavor(s) • '
                    '${r.targetNic.toStringAsFixed(0)} mg • '
                    '${r.targetVgPercent.toStringAsFixed(0)}% VG'
                    '${r.notes.isEmpty ? '' : ' — ${r.notes}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, r.sourceText!),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('Paste my own'),
        ),
      ],
    );
  }
}
