import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/ingredient.dart';
import 'package:mixlab/models/settings.dart';
import 'package:mixlab/models/units.dart';

import 'empty_state.dart';
import '../state.dart';
import 'ingredient_dialog.dart';

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
///
/// When [state] and [createKind] are supplied, the picker can create a new
/// ingredient inline, so building a recipe never requires leaving for the
/// Inventory tab.
class IngredientPickerField extends StatelessWidget {
  const IngredientPickerField({
    super.key,
    required this.label,
    required this.items,
    required this.selectedId,
    required this.onSelected,
    required this.settings,
    this.state,
    this.createKind,
    this.allowClear = true,
    this.trailing,
    this.emptyHint = 'No matching ingredients',
  });

  final String label;
  final List<Ingredient> items;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final Settings settings;

  /// Required for inline creation.
  final AppState? state;
  final IngredientKind? createKind;

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
            state: state,
            createKind: createKind,
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
    this.state,
    this.createKind,
  });

  final String title;
  final List<Ingredient> items;
  final String? selectedId;
  final Settings settings;
  final bool allowClear;
  final String emptyHint;
  final AppState? state;
  final IngredientKind? createKind;

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  final _q = TextEditingController();
  final _scroll = ScrollController();
  int _highlight = 0;

  bool get _canCreate => widget.state != null && widget.createKind != null;

  List<Ingredient> get _results => searchIngredients(widget.items, _q.text);

  @override
  void dispose() {
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final n = _results.length;
    if (n == 0) return;
    setState(() => _highlight = (_highlight + delta).clamp(0, n - 1));
    // Keep the highlighted row on screen. 56 is the dense ListTile height.
    const rowHeight = 56.0;
    final target = _highlight * rowHeight;
    if (_scroll.hasClients) {
      final top = _scroll.offset;
      final bottom = top + _scroll.position.viewportDimension - rowHeight;
      if (target < top) {
        _scroll.jumpTo(target);
      } else if (target > bottom) {
        _scroll.jumpTo(target - _scroll.position.viewportDimension + rowHeight);
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        final r = _results;
        if (r.isNotEmpty && _highlight < r.length) {
          Navigator.pop(context, _PickResult(r[_highlight].id));
        } else if (_canCreate && _q.text.trim().isNotEmpty) {
          _create();
        }
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  Future<void> _create() async {
    final state = widget.state!;
    final created = await showIngredientDialog(
      context,
      state: state,
      initialKind: widget.createKind,
      initialName: _q.text,
    );
    if (created == null) return;
    state.upsertIngredient(created);
    if (!mounted) return;
    Navigator.pop(context, _PickResult(created.id));
  }

  @override
  Widget build(BuildContext context) {
    final results = _results;
    final theme = Theme.of(context);
    final query = _q.text.trim();
    if (_highlight >= results.length) _highlight = 0;

    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 460,
        height: 480,
        child: Focus(
          onKeyEvent: _onKey,
          child: Column(
            children: [
              TextField(
                controller: _q,
                autofocus: true,
                onChanged: (_) => setState(() => _highlight = 0),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search brand or name…',
                  helperText: 'Arrows to move, Enter to pick',
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
                    ? EmptyState(
                        icon: Icons.search_off,
                        title: widget.emptyHint,
                        message: _canCreate && query.isNotEmpty
                            ? 'Nothing matches. You can add it now without '
                                  'losing your place.'
                            : null,
                        actionLabel: _canCreate && query.isNotEmpty
                            ? 'Create "$query"'
                            : null,
                        onAction: _canCreate && query.isNotEmpty
                            ? _create
                            : null,
                      )
                    : ListView.builder(
                        controller: _scroll,
                        itemExtent: 56,
                        itemCount: results.length,
                        itemBuilder: (context, i) {
                          final e = results[i];
                          final low = e.stockMl <= widget.settings.lowStockMl;
                          return ListTile(
                            dense: true,
                            selected:
                                i == _highlight || e.id == widget.selectedId,
                            selectedTileColor: i == _highlight
                                ? theme.colorScheme.primaryContainer
                                : null,
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
                            title: Text(
                              e.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${e.stockMl.toStringAsFixed(1)} mL on hand'
                              '${e.costPerMl > 0 ? ' • ${moneyPerMl(e.costPerMl, widget.settings)}' : ''}',
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
            ],
          ),
        ),
      ),
      actions: [
        if (_canCreate && results.isNotEmpty)
          TextButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add, size: 18),
            label: Text(
              query.isEmpty
                  ? 'New ${kindLabel(widget.createKind!).toLowerCase()}'
                  : 'Create "$query"',
            ),
          ),
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
