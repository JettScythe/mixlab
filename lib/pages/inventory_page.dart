import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../widgets/ingredient_picker.dart';

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
    final set = state.settings;
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

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Inventory',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              Text('Stock value: ${money(state.stockValue, set)}'),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () => _edit(null),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ],
          ),
          if (suspect.isNotEmpty) _densityBanner(suspect),
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
                    hintText: 'Search brand or name (try "cap custard")',
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
              FilterChip(
                label: const Text('Low stock'),
                selected: _lowOnly,
                onSelected: (v) => setState(() => _lowOnly = v),
              ),
            ],
          ),
          if (brands.isNotEmpty) ...[
            const SizedBox(height: 8),
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
          const SizedBox(height: 12),
          Text(
            '${items.length} of ${state.ingredients.length} shown',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('Nothing matches.'))
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
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
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
          const SizedBox(width: 8),
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
          'Sets density from each ingredient\'s kind and carrier '
          'VG% for ${suspect.length} item(s). Measured values you entered '
          'by hand will be overwritten.',
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
          ],
        ),
        subtitle: Text(
          '${kindLabel(e.kind)} • '
          '${e.stockMl.toStringAsFixed(1)} mL '
          '(${e.stockGrams.toStringAsFixed(1)} g) on hand • '
          '${e.costPerMl.toStringAsFixed(3)} ${set.currency}/mL'
          '${e.avgCostPerMl > 0 ? ' (avg)' : ''}'
          '${e.kind == IngredientKind.nicotine ? ' • ${e.nicStrength.toStringAsFixed(0)} mg/mL' : ''}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (low)
              Padding(
                padding: const EdgeInsets.only(right: 4),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(
          'Added ${p.volumeMl.toStringAsFixed(0)} mL of '
          '${p.ingredientName} for ${money(p.cost, state.settings)}.',
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => state.undoPurchase(p.id),
        ),
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
              const SizedBox(height: 8),
              Text(
                'Used by ${usedBy.length} recipe(s):',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              for (final r in usedBy.take(6)) Text('  • ${r.name}'),
              if (usedBy.length > 6) Text('  • …and ${usedBy.length - 6} more'),
              const SizedBox(height: 4),
              const Text('Those recipes will show it as missing.'),
            ],
            if (mixes > 0) ...[
              const SizedBox(height: 8),
              Text(
                '$mixes logged mix(es) reference it; undoing those will '
                'no longer restore its stock.',
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('Deleted ${removed.$1.displayName}.'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => state.restoreIngredient(removed.$1, removed.$2),
        ),
      ),
    );
  }

  Future<void> _edit(Ingredient? existing) async {
    final result = await showDialog<Ingredient>(
      context: context,
      builder: (context) => _IngredientDialog(state: state, existing: existing),
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
                      border: const OutlineInputBorder(),
                      errorText: vol.text.trim().isNotEmpty && v == null
                          ? 'Number?'
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: cost,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Price paid (${set.currency})',
                      border: const OutlineInputBorder(),
                      errorText: cost.text.trim().isNotEmpty && c == null
                          ? 'Number?'
                          : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Blend with existing stock'),
              subtitle: const Text(
                'Weighted average cost basis. Off: this '
                'purchase price replaces the basis.',
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
              '${e.costPerMl.toStringAsFixed(3)} ${set.currency}/mL',
              '${resultBasis.toStringAsFixed(3)} ${set.currency}/mL',
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
        Text(before, style: const TextStyle(color: Colors.grey)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Icon(Icons.arrow_forward, size: 14),
        ),
        Text(after, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );
}

class _IngredientDialog extends StatefulWidget {
  const _IngredientDialog({required this.state, this.existing});
  final AppState state;
  final Ingredient? existing;
  @override
  State<_IngredientDialog> createState() => _IngredientDialogState();
}

class _IngredientDialogState extends State<_IngredientDialog> {
  late IngredientKind kind;
  late final TextEditingController name,
      brand,
      density,
      size,
      cost,
      stock,
      nic,
      carrier,
      notes;
  bool _densityTouched = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    kind = e?.kind ?? IngredientKind.flavor;
    String n(double v) => v == 0 ? '' : v.toString();
    name = TextEditingController(text: e?.name ?? '');
    brand = TextEditingController(text: e?.brand ?? '');
    carrier = TextEditingController(
      text: e != null ? (e.carrierVg * 100).toStringAsFixed(0) : '0',
    );
    density = TextEditingController(
      text: e != null
          ? e.density.toString()
          : widget.state.settings.densityForCarrier(kind, 0).toStringAsFixed(3),
    );
    size = TextEditingController(text: e != null ? n(e.bottleSizeMl) : '');
    cost = TextEditingController(text: e != null ? n(e.bottleCost) : '');
    stock = TextEditingController(text: e != null ? n(e.stockMl) : '');
    nic = TextEditingController(text: e != null ? n(e.nicStrength) : '');
    notes = TextEditingController(text: e?.notes ?? '');
  }

  @override
  void dispose() {
    for (final c in [
      name,
      brand,
      density,
      size,
      cost,
      stock,
      nic,
      carrier,
      notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double _v(TextEditingController c) => parseNum(c.text) ?? 0;
  bool _bad(TextEditingController c) =>
      c.text.trim().isNotEmpty && parseNum(c.text) == null;

  double get _carrierVg => clampd(_v(carrier) / 100, 0, 1);
  double get _impliedDensity =>
      widget.state.settings.densityForCarrier(kind, _carrierVg);

  /// Keeps density in sync with kind/carrier until the user overrides it.
  void _syncDensity() {
    if (_densityTouched) return;
    density.text = _impliedDensity.toStringAsFixed(3);
  }

  void _autosplit() {
    if (brand.text.trim().isNotEmpty) return;
    final (b, n) = splitBrand(name.text);
    if (b.isEmpty) return;
    setState(() {
      brand.text = b;
      name.text = n;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isNic = kind == IngredientKind.nicotine;
    final showCarrier = isNic || kind == IngredientKind.flavor;
    const numKeys = TextInputType.numberWithOptions(decimal: true);
    final brandKey = brand.text.trim().toUpperCase();
    final theme = Theme.of(context);

    final dup = widget.state.findDuplicate(
      brandKey,
      name.text,
      exceptId: widget.existing?.id,
    );
    final nameEmpty = name.text.trim().isEmpty;
    final anyBad = [density, size, cost, stock, nic, carrier].any(_bad);
    final blocked = anyBad || nameEmpty || dup != null;
    final densityOff = (_v(density) - _impliedDensity).abs() > 0.03;

    Widget field(
      TextEditingController c,
      String label, {
      bool numeric = true,
      String? helper,
      String? error,
      VoidCallback? onEdit,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        keyboardType: numeric ? numKeys : null,
        onChanged: (_) {
          onEdit?.call();
          setState(() {});
        },
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          border: const OutlineInputBorder(),
          errorText: error ?? (numeric && _bad(c) ? 'Enter a number' : null),
        ),
      ),
    );

    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add ingredient' : 'Edit ingredient',
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: field(brand, 'Brand', numeric: false),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: field(
                      name,
                      'Name',
                      numeric: false,
                      onEdit: _autosplit,
                      error: dup != null
                          ? 'Already in inventory'
                          : (nameEmpty ? 'Required' : null),
                    ),
                  ),
                ],
              ),
              if (dup != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '"${dup.displayName}" already exists with '
                      '${dup.stockMl.toStringAsFixed(1)} mL on hand. '
                      'Edit or restock that one instead.',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                )
              else if (brandKey.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      knownBrands[brandKey] ?? 'Custom brand "$brandKey"',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              DropdownMenu<IngredientKind>(
                initialSelection: kind,
                label: const Text('Kind'),
                expandedInsets: EdgeInsets.zero,
                onSelected: (k) {
                  if (k == null) return;
                  setState(() {
                    kind = k;
                    if (k != IngredientKind.nicotine &&
                        k != IngredientKind.flavor) {
                      carrier.text = '0';
                    }
                    _syncDensity();
                  });
                },
                dropdownMenuEntries: [
                  for (final k in IngredientKind.values)
                    DropdownMenuEntry(value: k, label: kindLabel(k)),
                ],
              ),
              const SizedBox(height: 8),
              if (showCarrier)
                field(
                  carrier,
                  'Carrier VG % (0 = pure PG)',
                  helper: 'Drives density and the PG/VG the mix inherits.',
                  onEdit: _syncDensity,
                ),
              field(
                density,
                'Density (g/mL)',
                helper:
                    'Implied by carrier: '
                    '${_impliedDensity.toStringAsFixed(3)}',
                onEdit: () => _densityTouched = true,
              ),
              if (densityOff)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextButton.icon(
                      onPressed: () => setState(() {
                        _densityTouched = false;
                        density.text = _impliedDensity.toStringAsFixed(3);
                      }),
                      icon: const Icon(Icons.auto_fix_high, size: 18),
                      label: Text(
                        'Use ${_impliedDensity.toStringAsFixed(3)} '
                        'from carrier',
                      ),
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(child: field(size, 'Bottle size (mL)')),
                  const SizedBox(width: 8),
                  Expanded(
                    child: field(
                      cost,
                      'Cost (${widget.state.settings.currency})',
                    ),
                  ),
                ],
              ),
              field(stock, 'Stock on hand (mL, blank = bottle size)'),
              if (isNic) field(nic, 'Nicotine strength (mg/mL)'),
              field(notes, 'Notes', numeric: false),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: blocked
              ? null
              : () {
                  final e = widget.existing;
                  Navigator.pop(
                    context,
                    Ingredient(
                      id: e?.id ?? newId(),
                      name: name.text.trim(),
                      brand: brandKey,
                      kind: kind,
                      density: _v(density) <= 0 ? _impliedDensity : _v(density),
                      bottleSizeMl: _v(size),
                      bottleCost: _v(cost),
                      avgCostPerMl: e?.avgCostPerMl ?? 0,
                      stockMl: stock.text.trim().isEmpty ? _v(size) : _v(stock),
                      nicStrength: _v(nic),
                      carrierVg: _carrierVg,
                      notes: notes.text.trim(),
                    ),
                  );
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
