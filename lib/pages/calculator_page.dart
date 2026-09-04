import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/ingredient_picker.dart';
import '../widgets/toast.dart';
import 'recipe_editor_page.dart';
import 'step_mode_page.dart';

class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key, required this.state});
  final AppState state;

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

/// One percentage-based row. Holds its kind so the picker can filter and so
/// additives and thinners can be excluded from the flavor total.
class _ConcentrateEntry {
  _ConcentrateEntry(this.kind, {this.ingredientId, String percent = ''})
    : percent = TextEditingController(text: percent);

  IngredientKind kind;
  String? ingredientId;
  final TextEditingController percent;

  void dispose() => percent.dispose();
}

class _CalculatorPageState extends State<CalculatorPage> {
  late final TextEditingController _batch;
  late final TextEditingController _nic;
  late final TextEditingController _vg;

  String? _nicId;
  String? _pgId;
  String? _vgId;

  final List<_ConcentrateEntry> _rows = [];

  String _label = '';
  String? _loadedRecipeId;
  int _seenRecipeToken = 0;
  late PercentMode _percentMode;
  late BaseMode _baseMode;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    final set = s.settings;
    _batch = TextEditingController(text: set.defaultBatchMl.toStringAsFixed(0));
    _nic = TextEditingController(text: '3');
    _vg = TextEditingController(text: set.defaultVgPercent.toStringAsFixed(0));
    _percentMode = set.defaultPercentMode;
    _baseMode = BaseMode.ratio;

    for (final c in [_batch, _nic, _vg]) {
      c.addListener(_rebuild);
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
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _rebuild() => setState(() {});

  void _onStateChanged() {
    if (!mounted || s.recipeLoadToken == _seenRecipeToken) return;
    _seenRecipeToken = s.recipeLoadToken;
    final r = s.pendingRecipe;
    if (r != null) _applyRecipe(r);
  }

  // ----------------------------------------------------------------- helpers

  double _val(TextEditingController c) => parseNum(c.text) ?? 0;

  bool _bad(TextEditingController c) =>
      c.text.trim().isNotEmpty && parseNum(c.text) == null;

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  /// The saved recipe currently loaded, if any. Remixed logs carry a
  /// synthetic id that never resolves, so they correctly read as unsaved.
  Recipe? get _loadedRecipe => s.recipeById(_loadedRecipeId);

  void _applyRecipe(Recipe r) {
    _batch.text = _fmt(r.batchMl);
    _nic.text = _fmt(r.targetNic);
    _vg.text = _fmt(r.targetVgPercent);
    _label = r.name;
    _percentMode = r.percentMode;
    _baseMode = r.baseMode;
    _loadedRecipeId = r.id.startsWith('remix:') ? null : r.id;

    for (final e in _rows) {
      e.dispose();
    }
    _rows.clear();

    var skipped = 0;
    for (final f in r.flavors) {
      final ing = s.byId(f.ingredientId) ?? s.flavorByName(f.name);
      if (ing == null) {
        skipped++;
        continue;
      }
      _rows.add(
        _ConcentrateEntry(
          ing.kind,
          ingredientId: ing.id,
          percent: _fmt(f.percent),
        )..percent.addListener(_rebuild),
      );
    }

    setState(() {});
    if (skipped > 0) {
      showToast(
        context,
        '$skipped ingredient(s) skipped — not found in inventory.',
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
      percentMode: _percentMode,
      baseMode: _baseMode,
      nic: nic,
      pg: pg,
      vg: vg,
      flavors: [
        for (final e in _rows)
          if (s.byId(e.ingredientId) != null)
            (s.byId(e.ingredientId)!, _val(e.percent)),
      ],
    );
  }

  // -------------------------------------------------------------------- view

  @override
  Widget build(BuildContext context) {
    final result = _compute();
    final issues = checkStock(result, s.ingredients);
    final inputs = _buildInputs(context);
    final output = _buildResults(context, result, issues);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = Breaks.isWide(constraints.maxWidth);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(Gap.lg),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: inputs),
                    Gap.hLg,
                    Expanded(child: output),
                  ],
                )
              : Column(children: [inputs, Gap.vLg, output]),
        );
      },
    );
  }

  Widget _buildInputs(BuildContext context) {
    final theme = Theme.of(context);
    final nic = s.byId(_nicId) ?? s.firstOfKind(IngredientKind.nicotine);
    final pg = s.byId(_pgId) ?? s.firstOfKind(IngredientKind.pg);
    final vg = s.byId(_vgId) ?? s.firstOfKind(IngredientKind.vg);
    final loaded = _loadedRecipe;
    final listedTotal = _rows.fold(0.0, (a, e) => a + _val(e.percent));
    final isMaxVg = _baseMode == BaseMode.maxVg;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header, with the loaded-recipe chip and an editor shortcut.
            Row(
              children: [
                Expanded(
                  child: Text('Recipe', style: theme.textTheme.titleLarge),
                ),
                if (_label.isNotEmpty)
                  Flexible(
                    child: Chip(
                      avatar: loaded != null
                          ? const Icon(Icons.menu_book, size: 16)
                          : null,
                      label: Text(_label, overflow: TextOverflow.ellipsis),
                      onDeleted: () => setState(() {
                        _label = '';
                        _loadedRecipeId = null;
                      }),
                    ),
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

            // Batch size, nicotine target, ratio target.
            Row(
              children: [
                Expanded(child: _numField(_batch, 'Batch size (mL)')),
                const SizedBox(width: 8),
                Expanded(child: _numField(_nic, 'Target nic (mg/mL)')),
                const SizedBox(width: 8),
                Expanded(
                  child: _numField(
                    _vg,
                    'Target VG %',
                    enabled: !isMaxVg,
                    // Max VG ignores the target entirely, so show what the
                    // mix will actually land at rather than a stale number.
                    hint: isMaxVg ? 'set by mix' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Base ingredients. Each picker can create inline.
            IngredientPickerField(
              label: 'Nicotine base',
              items: s.ofKind(IngredientKind.nicotine),
              selectedId: nic?.id,
              settings: s.settings,
              state: s,
              createKind: IngredientKind.nicotine,
              emptyHint: 'No nicotine bases yet — search a name and create it',
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
                    state: s,
                    createKind: IngredientKind.pg,
                    emptyHint: 'No PG in inventory',
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
                    state: s,
                    createKind: IngredientKind.vg,
                    emptyHint: 'No VG in inventory',
                    onSelected: (id) => setState(() => _vgId = id),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // How the base is allocated.
            Text('Base', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            SegmentedButton<BaseMode>(
              segments: [
                for (final m in BaseMode.values)
                  ButtonSegment(value: m, label: Text(baseModeLabel(m))),
              ],
              selected: {_baseMode},
              onSelectionChanged: (v) => setState(() => _baseMode = v.first),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                baseModeHint(_baseMode),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            const SizedBox(height: 16),

            // How percentages are interpreted.
            Text('Percentages are', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            SegmentedButton<PercentMode>(
              segments: [
                for (final m in PercentMode.values)
                  ButtonSegment(value: m, label: Text(percentModeLabel(m))),
              ],
              selected: {_percentMode},
              onSelectionChanged: (v) => setState(() => _percentMode = v.first),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 16),
              child: Text(
                percentModeHint(_percentMode),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),

            // Concentrate rows.
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Ingredients  (${listedTotal.toStringAsFixed(1)}% listed)',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                MenuAnchor(
                  builder: (context, controller, child) =>
                      FilledButton.tonalIcon(
                        onPressed: () => controller.isOpen
                            ? controller.close()
                            : controller.open(),
                        icon: const Icon(Icons.add),
                        label: const Text('Add'),
                      ),
                  menuChildren: [
                    for (final k in const [
                      IngredientKind.flavor,
                      IngredientKind.additive,
                      IngredientKind.thinner,
                    ])
                      MenuItemButton(
                        onPressed: () => setState(() {
                          _rows.add(
                            _ConcentrateEntry(k)..percent.addListener(_rebuild),
                          );
                        }),
                        child: Text(kindLabel(k)),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    'No flavors yet — use Add above.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            for (final e in _rows) _concentrateRow(e),
          ],
        ),
      ),
    );
  }

  Widget _numField(
    TextEditingController c,
    String label, {
    bool enabled = true,
    String? hint,
  }) => TextField(
    controller: c,
    enabled: enabled,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      isDense: true,
      errorText: _bad(c) ? 'Number?' : null,
    ),
  );

  Widget _concentrateRow(_ConcentrateEntry e) {
    final theme = Theme.of(context);
    final ing = s.byId(e.ingredientId);
    final needMl = _val(_batch) * _val(e.percent) / 100;
    final short = ing != null && needMl > ing.stockMl + 1e-9;
    final dupe =
        e.ingredientId != null &&
        _rows.where((x) => x.ingredientId == e.ingredientId).length > 1;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          // Kind badge, tappable to reclassify the row.
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: MenuAnchor(
              builder: (context, controller, child) => Tooltip(
                message: '${kindLabel(e.kind)} — tap to change',
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  child: Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: switch (e.kind) {
                        IngredientKind.additive =>
                          theme.colorScheme.tertiaryContainer,
                        IngredientKind.thinner =>
                          theme.colorScheme.secondaryContainer,
                        _ => theme.colorScheme.surfaceContainerHighest,
                      },
                    ),
                    child: Icon(switch (e.kind) {
                      IngredientKind.additive => Icons.auto_awesome,
                      IngredientKind.thinner => Icons.water_drop_outlined,
                      _ => Icons.local_florist_outlined,
                    }, size: 18),
                  ),
                ),
              ),
              menuChildren: [
                for (final k in const [
                  IngredientKind.flavor,
                  IngredientKind.additive,
                  IngredientKind.thinner,
                ])
                  MenuItemButton(
                    onPressed: () => setState(() {
                      e.kind = k;
                      // The current selection may not belong to the new kind.
                      if (s.byId(e.ingredientId)?.kind != k) {
                        e.ingredientId = null;
                      }
                    }),
                    child: Text(kindLabel(k)),
                  ),
              ],
            ),
          ),
          Expanded(
            child: IngredientPickerField(
              label: kindLabel(e.kind),
              items: s.ofKind(e.kind),
              selectedId: e.ingredientId,
              settings: s.settings,
              state: s,
              createKind: e.kind,
              emptyHint:
                  'No ${kindLabel(e.kind).toLowerCase()}s yet — '
                  'search a name and create it',
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
                message: 'Selected more than once — amounts are combined',
                child: Icon(
                  Icons.merge_type,
                  color: theme.colorScheme.tertiary,
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
                  color: theme.colorScheme.error,
                  size: 20,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Remove',
            onPressed: () => setState(() {
              e.dispose();
              _rows.remove(e);
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
    final isMaxVg = _baseMode == BaseMode.maxVg;

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
                    'Mix by weight',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (isMaxVg)
                  Chip(
                    label: const Text('Max VG'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: theme.colorScheme.secondaryContainer,
                  ),
                if (_percentMode == PercentMode.byWeight)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Chip(
                      label: const Text('By weight'),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: theme.colorScheme.tertiaryContainer,
                    ),
                  ),
              ],
            ),
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
              'Flavor: ${r.flavorPercentByWeight.toStringAsFixed(1)}% by '
              'weight, ${r.flavorPercentByVolume.toStringAsFixed(1)}% by '
              'volume',
            ),
            if (r.hasAdditives || r.hasThinners)
              Text(
                'Additives and thinners are excluded from the flavor total.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            Text(
              'Bottle cost: ${money(r.totalCost, set)}  •  per '
              '${ref.toStringAsFixed(0)} mL: '
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
                  onPressed: _rows.isEmpty ? null : _saveAsNewRecipe,
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

  // ------------------------------------------------------------------ mixing

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
    showToast(
      context,
      'Logged "${log.label}" — ${log.totalGrams.toStringAsFixed(2)} g, '
      'inventory deducted.',
      action: SnackBarAction(label: 'Undo', onPressed: () => s.undoMix(log.id)),
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

  // ----------------------------------------------------------------- recipes

  List<RecipeFlavor> _currentFlavors() => [
    for (final e in _rows)
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
        percentMode: _percentMode,
        baseMode: _baseMode,
        flavors: _currentFlavors(),
      ),
    );
    showToast(context, 'Updated "${loaded.name}".');
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
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
              const SizedBox(height: 8),
              Text(
                'Saved as ${percentModeLabel(_percentMode).toLowerCase()} '
                'percentages, ${baseModeLabel(_baseMode).toLowerCase()} base.',
                style: Theme.of(context).textTheme.bodySmall,
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
                percentMode: _percentMode,
                baseMode: _baseMode,
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
    showToast(context, 'Saved "${saved.name}".');
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
