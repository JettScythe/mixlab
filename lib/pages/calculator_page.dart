import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../widgets/ingredient_picker.dart';
import 'recipe_editor_page.dart';
import 'step_mode_page.dart';

class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key, required this.state});
  final AppState state;

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _FlavorEntry {
  String? ingredientId;
  final TextEditingController percent = TextEditingController();
  void dispose() => percent.dispose();
}

class _CalculatorPageState extends State<CalculatorPage> {
  late final TextEditingController _batch;
  late final TextEditingController _nic;
  late final TextEditingController _vg;
  String? _nicId;
  String? _pgId;
  String? _vgId;
  final List<_FlavorEntry> _flavors = [];
  String _label = '';
  String? _loadedRecipeId;
  int _seenRecipeToken = 0;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _batch = TextEditingController(
      text: s.settings.defaultBatchMl.toStringAsFixed(0),
    );
    _nic = TextEditingController(text: '3');
    _vg = TextEditingController(
      text: s.settings.defaultVgPercent.toStringAsFixed(0),
    );
    for (final c in [_batch, _nic, _vg]) {
      c.addListener(() => setState(() {}));
    }
    _seenRecipeToken = s.recipeLoadToken;
    s.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    s.removeListener(_onStateChanged);
    _batch.dispose();
    _nic.dispose();
    _vg.dispose();
    for (final f in _flavors) {
      f.dispose();
    }
    super.dispose();
  }

  void _onStateChanged() {
    if (!mounted || s.recipeLoadToken == _seenRecipeToken) return;
    _seenRecipeToken = s.recipeLoadToken;
    final r = s.pendingRecipe;
    if (r != null) _applyRecipe(r);
  }

  double _val(TextEditingController c) => parseNum(c.text) ?? 0;
  bool _bad(TextEditingController c) =>
      c.text.trim().isNotEmpty && parseNum(c.text) == null;

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  Recipe? get _loadedRecipe => s.recipeById(_loadedRecipeId);

  void _applyRecipe(Recipe r) {
    _batch.text = _fmt(r.batchMl);
    _nic.text = _fmt(r.targetNic);
    _vg.text = _fmt(r.targetVgPercent);
    _label = r.name;
    _loadedRecipeId = r.id;
    for (final e in _flavors) {
      e.dispose();
    }
    _flavors.clear();
    var skipped = 0;
    for (final f in r.flavors) {
      final ing = s.byId(f.ingredientId) ?? s.flavorByName(f.name);
      if (ing == null) {
        skipped++;
        continue;
      }
      final entry = _FlavorEntry()..ingredientId = ing.id;
      entry.percent.text = _fmt(f.percent);
      _flavors.add(entry);
    }
    setState(() {});
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$skipped flavor(s) skipped — not found in inventory.'),
        ),
      );
    }
  }

  MixResult _compute() {
    final nic = s.byId(_nicId) ?? s.firstOfKind(IngredientKind.nicotine);
    final pg = s.byId(_pgId) ?? s.firstOfKind(IngredientKind.pg);
    final vg = s.byId(_vgId) ?? s.firstOfKind(IngredientKind.vg);
    return calculateMix(
      amountMl: _val(_batch),
      targetNic: _val(_nic),
      targetVgPercent: _val(_vg),
      settings: s.settings,
      nic: nic,
      pg: pg,
      vg: vg,
      flavors: [
        for (final e in _flavors)
          if (s.byId(e.ingredientId) != null)
            (s.byId(e.ingredientId)!, _val(e.percent)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _compute();
    final issues = checkStock(result, s.ingredients);
    final inputs = _buildInputs(context);
    final output = _buildResults(context, result, issues);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 980;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: inputs),
                    const SizedBox(width: 16),
                    Expanded(child: output),
                  ],
                )
              : Column(children: [inputs, const SizedBox(height: 16), output]),
        );
      },
    );
  }

  Widget _buildInputs(BuildContext context) {
    final flavorTotal = _flavors.fold(0.0, (a, e) => a + _val(e.percent));
    final nic = s.byId(_nicId) ?? s.firstOfKind(IngredientKind.nicotine);
    final pg = s.byId(_pgId) ?? s.firstOfKind(IngredientKind.pg);
    final vg = s.byId(_vgId) ?? s.firstOfKind(IngredientKind.vg);
    final loaded = _loadedRecipe;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recipe',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (_label.isNotEmpty)
                  Chip(
                    avatar: loaded != null
                        ? const Icon(Icons.menu_book, size: 16)
                        : null,
                    label: Text(_label),
                    onDeleted: () => setState(() {
                      _label = '';
                      _loadedRecipeId = null;
                    }),
                  ),
                if (loaded != null)
                  IconButton(
                    tooltip: 'Open in recipe editor',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _editLoadedRecipe(loaded),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _numField(_batch, 'Batch size (mL)')),
                const SizedBox(width: 8),
                Expanded(child: _numField(_nic, 'Target nic (mg/mL)')),
                const SizedBox(width: 8),
                Expanded(child: _numField(_vg, 'Target VG %')),
              ],
            ),
            const SizedBox(height: 12),
            IngredientPickerField(
              label: 'Nicotine base',
              items: s.ofKind(IngredientKind.nicotine),
              selectedId: nic?.id,
              settings: s.settings,
              onSelected: (id) => setState(() => _nicId = id),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: IngredientPickerField(
                    label: 'PG source',
                    items: s.ofKind(IngredientKind.pg),
                    selectedId: pg?.id,
                    settings: s.settings,
                    onSelected: (id) => setState(() => _pgId = id),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: IngredientPickerField(
                    label: 'VG source',
                    items: s.ofKind(IngredientKind.vg),
                    selectedId: vg?.id,
                    settings: s.settings,
                    onSelected: (id) => setState(() => _vgId = id),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  'Flavors  (${flavorTotal.toStringAsFixed(1)}%)',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: () => setState(() => _flavors.add(_FlavorEntry())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add flavor'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final e in _flavors) _flavorRow(e),
          ],
        ),
      ),
    );
  }

  Widget _numField(TextEditingController c, String label) => TextField(
    controller: c,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
      errorText: _bad(c) ? 'Number?' : null,
    ),
  );

  Widget _flavorRow(_FlavorEntry e) {
    final ing = s.byId(e.ingredientId);
    final needMl = _val(_batch) * _val(e.percent) / 100;
    final short = ing != null && needMl > ing.stockMl + 1e-9;
    final dupe =
        e.ingredientId != null &&
        _flavors.where((x) => x.ingredientId == e.ingredientId).length > 1;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: IngredientPickerField(
              label: 'Flavor',
              items: s.ofKind(IngredientKind.flavor),
              selectedId: e.ingredientId,
              settings: s.settings,
              emptyHint: 'No flavors yet — add them in Inventory',
              onSelected: (id) => setState(() => e.ingredientId = id),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: TextField(
              controller: e.percent,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '%',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _bad(e.percent) ? '?' : null,
              ),
            ),
          ),
          if (dupe)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Tooltip(
                message: 'Selected more than once — percentages are combined',
                child: Icon(
                  Icons.merge_type,
                  color: Theme.of(context).colorScheme.tertiary,
                  size: 20,
                ),
              ),
            ),
          if (short)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Tooltip(
                message: 'Only ${ing.stockMl.toStringAsFixed(1)} mL in stock',
                child: Icon(
                  Icons.warning_amber_rounded,
                  color: Theme.of(context).colorScheme.error,
                  size: 20,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              e.dispose();
              _flavors.remove(e);
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(
    BuildContext context,
    MixResult r,
    List<StockIssue> issues,
  ) {
    final set = s.settings;
    final theme = Theme.of(context);
    final ref = set.refBottleMl <= 0 ? 30.0 : set.refBottleMl;
    final loaded = _loadedRecipe;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Mix by weight', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(2.2),
                1: FlexColumnWidth(1.1),
                2: FlexColumnWidth(1.1),
                3: FlexColumnWidth(1.3),
              },
              children: [
                _row('Ingredient', 'grams', 'mL', 'cost', header: true),
                for (final l in r.lines)
                  _row(
                    l.name,
                    l.grams.toStringAsFixed(2),
                    l.ml.toStringAsFixed(2),
                    money(l.cost, set),
                  ),
                _row(
                  'Total',
                  r.totalGrams.toStringAsFixed(2),
                  r.totalMl.toStringAsFixed(2),
                  money(r.totalCost, set),
                  header: true,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '${r.totalGrams.toStringAsFixed(2)} g total',
              style: theme.textTheme.headlineSmall,
            ),
            Text(
              'Final ratio: ${r.actualVgPercent.toStringAsFixed(1)}% VG / '
              '${(100 - r.actualVgPercent).toStringAsFixed(1)}% PG',
            ),
            Text('Nicotine: ${r.actualNicMgPerMl.toStringAsFixed(2)} mg/mL'),
            Text(
              'Bottle cost: ${money(r.totalCost, set)}'
              '  •  per ${ref.toStringAsFixed(0)} mL: '
              '${money(r.totalMl > 0 ? r.totalCost / r.totalMl * ref : 0, set)}',
            ),
            for (final w in r.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  w,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            for (final w in scaleWarnings(r, set.scaleResolution))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  w,
                  style: TextStyle(color: theme.colorScheme.tertiary),
                ),
              ),
            if (issues.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.inventory_2_outlined,
                          size: 18,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Not enough stock',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    for (final i in issues)
                      Text(
                        'short ${i.shortMl.toStringAsFixed(2)} mL ${i.name}  '
                        '(need ${i.neededMl.toStringAsFixed(2)}, have '
                        '${i.haveMl.toStringAsFixed(2)})',
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              onPressed: r.lines.isEmpty ? null : () => _weighAlong(r, issues),
              icon: const Icon(Icons.balance),
              label: const Text('Weigh along on the scale'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: r.lines.isEmpty ? null : () => _logMix(r, issues),
              icon: const Icon(Icons.scale),
              label: const Text('Log as mixed (skip weighing)'),
            ),
            const Divider(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (loaded != null)
                  FilledButton.tonalIcon(
                    onPressed: () => _updateLoadedRecipe(loaded),
                    icon: const Icon(Icons.save_outlined),
                    label: Text('Update "${loaded.name}"'),
                  ),
                OutlinedButton.icon(
                  onPressed: _flavors.isEmpty ? null : _saveAsNewRecipe,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: Text(
                    loaded != null ? 'Save as new recipe' : 'Save as recipe',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- mixing

  Future<bool> _confirmShort(List<StockIssue> issues) async {
    if (issues.isEmpty) return true;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mix anyway?'),
        content: Text(
          'You are short on ${issues.length} ingredient(s). Logging will '
          'deduct what you have and floor those at zero. You can undo from '
          'the History tab.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return go == true;
  }

  void _logged(MixLog log) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Logged "${log.label}" — ${log.totalGrams.toStringAsFixed(2)} g, '
          'inventory deducted.',
        ),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => s.undoMix(log.id),
        ),
      ),
    );
  }

  Future<void> _weighAlong(MixResult r, List<StockIssue> issues) async {
    if (!await _confirmShort(issues)) return;
    if (!mounted) return;
    final log = await Navigator.of(context).push<MixLog>(
      MaterialPageRoute(
        builder: (_) => StepModePage(
          state: s,
          result: r,
          label: _label.isEmpty ? 'Unnamed mix' : _label,
          recipeId: _loadedRecipeId,
          targetNic: _val(_nic),
          targetVgPercent: _val(_vg),
        ),
      ),
    );
    if (log != null && mounted) _logged(log);
  }

  Future<void> _logMix(MixResult r, List<StockIssue> issues) async {
    if (!await _confirmShort(issues)) return;
    final log = s.logMix(
      r,
      label: _label,
      recipeId: _loadedRecipeId,
      targetNic: _val(_nic),
      targetVgPercent: _val(_vg),
    );
    if (!mounted) return;
    _logged(log);
  }

  // --------------------------------------------------------------- recipes

  List<RecipeFlavor> _currentFlavors() => [
    for (final e in _flavors)
      if (s.byId(e.ingredientId) != null && _val(e.percent) > 0)
        RecipeFlavor(
          ingredientId: e.ingredientId!,
          name: s.byId(e.ingredientId)!.displayName,
          percent: _val(e.percent),
        ),
  ];

  Future<void> _editLoadedRecipe(Recipe loaded) async {
    final saved = await Navigator.of(context).push<Recipe>(
      MaterialPageRoute(
        builder: (_) => RecipeEditorPage(state: s, existing: loaded),
      ),
    );
    if (saved == null || !mounted) return;
    _applyRecipe(saved); // pull the edits back into the calculator
  }

  void _updateLoadedRecipe(Recipe loaded) {
    s.updateRecipe(
      Recipe(
        id: loaded.id,
        name: loaded.name,
        notes: loaded.notes,
        batchMl: _val(_batch),
        targetNic: _val(_nic),
        targetVgPercent: _val(_vg),
        flavors: _currentFlavors(),
      ),
    );
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Updated "${loaded.name}".')));
  }

  Future<void> _saveAsNewRecipe() async {
    final name = TextEditingController(
      text: _loadedRecipe != null ? '$_label (variant)' : _label,
    );
    final notes = TextEditingController();
    final saved = await showDialog<Recipe>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save as recipe'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: notes,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  border: OutlineInputBorder(),
                ),
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
            onPressed: () => Navigator.pop(
              context,
              Recipe(
                id: newId(),
                name: name.text.trim().isEmpty
                    ? 'Untitled recipe'
                    : name.text.trim(),
                notes: notes.text.trim(),
                batchMl: _val(_batch),
                targetNic: _val(_nic),
                targetVgPercent: _val(_vg),
                flavors: _currentFlavors(),
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    name.dispose();
    notes.dispose();
    if (saved == null) return;

    s.addRecipe(saved);
    if (!mounted) return;
    setState(() {
      _label = saved.name;
      _loadedRecipeId = saved.id;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Saved "${saved.name}".')));
  }

  TableRow _row(String a, String b, String c, String d, {bool header = false}) {
    final style = header ? const TextStyle(fontWeight: FontWeight.bold) : null;
    Widget cell(String t, [TextAlign align = TextAlign.left]) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(t, style: style, textAlign: align),
    );
    return TableRow(
      children: [
        cell(a),
        cell(b, TextAlign.right),
        cell(c, TextAlign.right),
        cell(d, TextAlign.right),
      ],
    );
  }
}
