import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/ingredient_dialog.dart';
import '../widgets/ingredient_picker.dart';
import '../widgets/toast.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key, required this.state});
  final AppState state;

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final _search = TextEditingController();
  bool _lowOnly = false;
  String? _brand;

  AppState get state => widget.state;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final set = state.settings;
    final noneAtAll = state.ingredients.isEmpty;

    var items = searchIngredients(state.ingredients, _search.text);
    if (_search.text.trim().isEmpty) {
      items.sort((a, b) {
        final k = a.kind.index.compareTo(b.kind.index);
        if (k != 0) return k;
        final b2 = a.brand.compareTo(b.brand);
        return b2 != 0 ? b2 : a.name.compareTo(b.name);
      });
    }
    if (_brand != null) {
      items = items.where((e) => e.brand == _brand).toList();
    }
    if (_lowOnly) {
      items = items.where((e) => e.stockMl <= set.lowStockMl).toList();
    }
    final brands = state.brands;
    final suspect = state.suspectDensities;
    final filtered = _brand != null || _lowOnly || _search.text.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Inventory', style: theme.textTheme.headlineSmall),
              ),
              if (!noneAtAll)
                Text('Stock value: ${money(state.stockValue, set)}'),
              Gap.hMd,
              FilledButton.icon(
                onPressed: () => _edit(null),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ],
          ),
          if (suspect.isNotEmpty) _densityBanner(suspect),
          if (!noneAtAll) ...[
            Gap.vMd,
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search brand or name (try "cap custard")',
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
                FilterChip(
                  label: const Text('Low stock'),
                  selected: _lowOnly,
                  onSelected: (v) => setState(() => _lowOnly = v),
                ),
              ],
            ),
            if (brands.isNotEmpty) ...[
              Gap.vSm,
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: const Text('All brands'),
                        selected: _brand == null,
                        onSelected: (_) => setState(() => _brand = null),
                      ),
                    ),
                    for (final b in brands)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: Text(b),
                          tooltip: knownBrands[b],
                          selected: _brand == b,
                          onSelected: (v) =>
                              setState(() => _brand = v ? b : null),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            Gap.vMd,
            Text(
              '${items.length} of ${state.ingredients.length} shown',
              style: theme.textTheme.bodySmall,
            ),
            Gap.vXs,
          ],
          Expanded(
            child: noneAtAll
                ? EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: 'Nothing in your stash',
                    message:
                        'Add your PG, VG, nicotine base and flavors here. '
                        'Bottle size and price make cost-per-bottle work.',
                    actionLabel: 'Add ingredient',
                    onAction: () => _edit(null),
                  )
                : items.isEmpty
                ? EmptyState(
                    icon: Icons.search_off,
                    title: 'Nothing matches',
                    message: filtered
                        ? 'Try clearing the search or filters.'
                        : null,
                    actionLabel: filtered ? 'Clear filters' : 'Add ingredient',
                    onAction: filtered
                        ? () => setState(() {
                            _search.clear();
                            _lowOnly = false;
                            _brand = null;
                          })
                        : () => _edit(null),
                  )
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, i) => _tile(items[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _densityBanner(List<Ingredient> suspect) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: Gap.md),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          Gap.hSm,
          Expanded(
            child: Text(
              '${suspect.length} ingredient(s) have a density that does not '
              'match their carrier — gram amounts for these will be off.',
              style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
            ),
          ),
          TextButton(
            onPressed: () => _fixDensities(suspect),
            child: const Text('Fix all'),
          ),
        ],
      ),
    );
  }

  Future<void> _fixDensities(List<Ingredient> suspect) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recalculate densities?'),
        content: Text(
          "Sets density from each ingredient's kind and carrier VG% for "
          '${suspect.length} item(s). Measured values you entered by hand '
          'will be overwritten.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Recalculate'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final e in suspect) {
      e.density = state.settings.densityForCarrier(e.kind, e.carrierVg);
      state.upsertIngredient(e);
    }
  }

  Widget _tile(Ingredient e) {
    final set = state.settings;
    final low = e.stockMl <= set.lowStockMl;
    final theme = Theme.of(context);

    return Card(
      child: ListTile(
        leading: e.brand.isEmpty
            ? Icon(
                low ? Icons.error_outline : Icons.water_drop_outlined,
                color: low ? theme.colorScheme.error : null,
              )
            : Tooltip(
                message: knownBrands[e.brand] ?? e.brand,
                child: Chip(
                  label: Text(e.brand, style: theme.textTheme.labelSmall),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
              ),
        title: Row(
          children: [
            Flexible(child: Text(e.name, overflow: TextOverflow.ellipsis)),
            if (e.densityLooksWrong(set))
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Tooltip(
                  message:
                      'Density ${e.density.toStringAsFixed(3)} does not '
                      'match carrier; expected '
                      '${set.densityForCarrier(e.kind, e.carrierVg).toStringAsFixed(3)}',
                  child: Icon(
                    Icons.info_outline,
                    size: 16,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
            if (e.nicIsSalt)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Tooltip(
                  message: 'Nicotine salt',
                  child: Icon(Icons.grain, size: 15),
                ),
              ),
          ],
        ),
        subtitle: Text(
          '${kindLabel(e.kind)} • '
          '${e.stockMl.toStringAsFixed(1)} mL '
          '(${e.stockGrams.toStringAsFixed(1)} g) on hand • '
          '${moneyPerMl(e.costPerMl, set)}'
          '${e.avgCostPerMl > 0 ? ' (avg)' : ''}'
          '${e.kind == IngredientKind.nicotine ? ' • ${e.nicStrength.toStringAsFixed(0)} ${nicUnitLabel(e.nicUnit)}' : ''}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (low)
              Padding(
                padding: const EdgeInsets.only(right: Gap.xs),
                child: Icon(
                  Icons.error_outline,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
              ),
            IconButton(
              icon: const Icon(Icons.add_shopping_cart_outlined),
              tooltip: 'Restock',
              onPressed: () => _restock(e),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _edit(e),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDelete(e),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restock(Ingredient e) async {
    final p = await showDialog<Purchase>(
      context: context,
      builder: (context) => _RestockDialog(state: state, ingredient: e),
    );
    if (p == null || !mounted) return;
    showToast(
      context,
      'Added ${p.volumeMl.toStringAsFixed(0)} mL of ${p.ingredientName} '
      'for ${money(p.cost, state.settings)}.',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => state.undoPurchase(p.id),
      ),
    );
  }

  Future<void> _confirmDelete(Ingredient e) async {
    final usedBy = state.recipesUsing(e.id);
    final mixes = state.mixesUsing(e.id);
    final theme = Theme.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${e.displayName}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (e.stockMl > 0)
              Text(
                '${e.stockMl.toStringAsFixed(1)} mL on hand, worth '
                '${money(e.stockMl * e.costPerMl, state.settings)}.',
              ),
            if (usedBy.isNotEmpty) ...[
              Gap.vSm,
              Text(
                'Used by ${usedBy.length} recipe(s):',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              for (final r in usedBy.take(6)) Text('  • ${r.name}'),
              if (usedBy.length > 6) Text('  • …and ${usedBy.length - 6} more'),
              Gap.vXs,
              const Text('Those recipes will show it as missing.'),
            ],
            if (mixes > 0) ...[
              Gap.vSm,
              Text(
                '$mixes logged mix(es) reference it; undoing those will no '
                'longer restore its stock.',
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final removed = state.removeIngredient(e.id);
    if (removed == null || !mounted) return;
    showToast(
      context,
      'Deleted ${removed.$1.displayName}.',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => state.restoreIngredient(removed.$1, removed.$2),
      ),
    );
  }

  Future<void> _edit(Ingredient? existing) async {
    final result = await showIngredientDialog(
      context,
      state: state,
      existing: existing,
    );
    if (result != null) state.upsertIngredient(result);
  }
}

class _RestockDialog extends StatefulWidget {
  const _RestockDialog({required this.state, required this.ingredient});
  final AppState state;
  final Ingredient ingredient;

  @override
  State<_RestockDialog> createState() => _RestockDialogState();
}

class _RestockDialogState extends State<_RestockDialog> {
  late final TextEditingController vol, cost;
  bool weighted = true;

  @override
  void initState() {
    super.initState();
    final e = widget.ingredient;
    vol = TextEditingController(
      text: e.bottleSizeMl > 0 ? e.bottleSizeMl.toStringAsFixed(0) : '',
    );
    cost = TextEditingController(
      text: e.bottleCost > 0 ? e.bottleCost.toStringAsFixed(2) : '',
    );
  }

  @override
  void dispose() {
    vol.dispose();
    cost.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.ingredient;
    final set = widget.state.settings;
    final v = parseNum(vol.text);
    final c = parseNum(cost.text);
    final valid = v != null && v > 0 && c != null;

    final newPerMl = valid ? c / v : 0.0;
    final denom = e.stockMl + (v ?? 0);
    final blended = valid && denom > 0
        ? (e.stockMl * e.costPerMl + v * newPerMl) / denom
        : e.costPerMl;
    final resultBasis = weighted ? blended : newPerMl;

    return AlertDialog(
      title: Text('Restock ${e.displayName}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: vol,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Volume added (mL)',
                      errorText: vol.text.trim().isNotEmpty && v == null
                          ? 'Number?'
                          : null,
                    ),
                  ),
                ),
                Gap.hSm,
                Expanded(
                  child: TextField(
                    controller: cost,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Price paid (${set.currency})',
                      errorText: cost.text.trim().isNotEmpty && c == null
                          ? 'Number?'
                          : null,
                    ),
                  ),
                ),
              ],
            ),
            Gap.vMd,
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Blend with existing stock'),
              subtitle: const Text(
                'Weighted average cost basis. Off: this purchase price '
                'replaces the basis.',
              ),
              value: weighted,
              onChanged: (x) => setState(() => weighted = x),
            ),
            const Divider(),
            _row(
              'Stock',
              '${e.stockMl.toStringAsFixed(1)} mL',
              '${(e.stockMl + (v ?? 0)).toStringAsFixed(1)} mL',
            ),
            _row(
              'Cost basis',
              moneyPerMl(e.costPerMl, set),
              moneyPerMl(resultBasis, set),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: !valid
              ? null
              : () => Navigator.pop(
                  context,
                  widget.state.recordPurchase(
                    ingredientId: e.id,
                    volumeMl: v,
                    cost: c,
                    useWeightedAverage: weighted,
                  ),
                ),
          child: const Text('Record'),
        ),
      ],
    );
  }

  Widget _row(String label, String before, String after) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(before, style: TextStyle(color: Theme.of(context).hintColor)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Icon(Icons.arrow_forward, size: 14),
        ),
        Text(after, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );
}
