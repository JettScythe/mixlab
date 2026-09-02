import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';

/// Ranked token search over brand + name + full vendor name.
List<Ingredient> searchIngredients(List<Ingredient> items, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) {
    return [...items]..sort((a, b) => a.displayName.compareTo(b.displayName));
  }
  final tokens = q.split(RegExp(r'\s+'));
  final hits = <(int, Ingredient)>[];
  for (final e in items) {
    final key = e.searchKey;
    if (!tokens.every(key.contains)) continue;
    var score = 0;
    if (e.name.toLowerCase().startsWith(tokens.first)) score -= 3;
    if (e.brand.toLowerCase() == tokens.first) score -= 2;
    if (key.startsWith(q)) score -= 1;
    hits.add((score, e));
  }
  hits.sort((a, b) {
    final s = a.$1.compareTo(b.$1);
    return s != 0 ? s : a.$2.displayName.compareTo(b.$2.displayName);
  });
  return [for (final h in hits) h.$2];
}

/// Tap-to-open field styled like a TextField. Returns via [onSelected];
/// a null id means the selection was cleared.
class IngredientPickerField extends StatelessWidget {
  const IngredientPickerField({
    super.key,
    required this.label,
    required this.items,
    required this.selectedId,
    required this.onSelected,
    required this.settings,
    this.allowClear = true,
    this.trailing,
    this.emptyHint = 'No matching ingredients',
  });

  final String label;
  final List<Ingredient> items;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final Settings settings;
  final bool allowClear;
  final Widget? trailing;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    Ingredient? sel;
    for (final e in items) {
      if (e.id == selectedId) sel = e;
    }
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        final r = await showDialog<_PickResult>(
          context: context,
          builder: (_) => _PickerDialog(
            title: label,
            items: items,
            selectedId: selectedId,
            settings: settings,
            allowClear: allowClear && sel != null,
            emptyHint: emptyHint,
          ),
        );
        if (r != null) onSelected(r.id);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: const Icon(Icons.search, size: 20),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                sel?.displayName ?? 'Choose…',
                overflow: TextOverflow.ellipsis,
                style: sel == null ? TextStyle(color: theme.hintColor) : null,
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _PickResult {
  const _PickResult(this.id);
  final String? id;
}

class _PickerDialog extends StatefulWidget {
  const _PickerDialog({
    required this.title,
    required this.items,
    required this.selectedId,
    required this.settings,
    required this.allowClear,
    required this.emptyHint,
  });

  final String title;
  final List<Ingredient> items;
  final String? selectedId;
  final Settings settings;
  final bool allowClear;
  final String emptyHint;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = searchIngredients(widget.items, _q.text);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 460,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _q,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (results.isNotEmpty) {
                  Navigator.pop(context, _PickResult(results.first.id));
                }
              },
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search brand or flavor…',
                border: const OutlineInputBorder(),
                suffixIcon: _q.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(_q.clear),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: results.isEmpty
                  ? Center(child: Text(widget.emptyHint))
                  : Shortcuts(
                      shortcuts: const {
                        SingleActivator(LogicalKeyboardKey.enter):
                            ActivateIntent(),
                      },
                      child: ListView.builder(
                        itemCount: results.length,
                        itemBuilder: (context, i) {
                          final e = results[i];
                          final low = e.stockMl <= 5;
                          return ListTile(
                            dense: true,
                            selected: e.id == widget.selectedId,
                            leading: e.brand.isEmpty
                                ? const Icon(Icons.water_drop_outlined)
                                : Tooltip(
                                    message: knownBrands[e.brand] ?? e.brand,
                                    child: Chip(
                                      label: Text(
                                        e.brand,
                                        style: theme.textTheme.labelSmall,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                    ),
                                  ),
                            title: Text(e.name),
                            subtitle: Text(
                              '${e.stockMl.toStringAsFixed(1)} mL on hand'
                              '${e.costPerMl > 0 ? ' • ${e.costPerMl.toStringAsFixed(3)} ${widget.settings.currency}/mL' : ''}',
                            ),
                            trailing: low
                                ? Icon(
                                    Icons.error_outline,
                                    size: 18,
                                    color: theme.colorScheme.error,
                                  )
                                : null,
                            onTap: () =>
                                Navigator.pop(context, _PickResult(e.id)),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.allowClear)
          TextButton(
            onPressed: () => Navigator.pop(context, const _PickResult(null)),
            child: const Text('Clear'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
