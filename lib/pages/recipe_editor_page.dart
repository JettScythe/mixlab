import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mixlab/models/calculate_mix.dart';
import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/ingredient.dart';
import 'package:mixlab/models/mix.dart';
import 'package:mixlab/models/recipe.dart';
import 'package:mixlab/models/step_plan.dart';
import 'package:mixlab/models/units.dart';

import '../state.dart';
import '../theme.dart';
import '../widgets/ingredient_picker.dart';

/// Full-screen editor for creating or modifying a recipe.
/// Pops with the saved [Recipe], or null if cancelled.
class RecipeEditorPage extends StatefulWidget {
  const RecipeEditorPage({super.key, required this.state, this.existing});

  final AppState state;
  final Recipe? existing;

  @override
  State<RecipeEditorPage> createState() => _RecipeEditorPageState();
}

/// One reorderable ingredient row. Carries its kind so additives and
/// thinners can be listed alongside flavors without polluting the total.
class _ConcentrateRow {
  _ConcentrateRow(this.kind, {this.ingredientId, String percent = ''})
    : percent = TextEditingController(text: percent);

  final Key key = UniqueKey();
  IngredientKind kind;
  String? ingredientId;
  final TextEditingController percent;

  void dispose() => percent.dispose();
}

class _RecipeEditorPageState extends State<RecipeEditorPage> {
  late final TextEditingController _name, _notes, _batch, _nic, _vg;
  final List<_ConcentrateRow> _rows = [];
  late PercentMode _percentMode;
  late BaseMode _baseMode;
  late String _initialSnapshot;

  /// Bottles this recipe is mixed from. Null means "whatever is selected
  /// at mix time", which is how every recipe behaved before v12.
  String? _nicId, _pgId, _vgId;

  AppState get s => widget.state;
  bool get _isNew => widget.existing == null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final set = s.settings;

    _name = TextEditingController(text: e?.name ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _batch = TextEditingController(
      text: _fmt(e?.batchMl ?? set.defaultBatchMl),
    );
    _nic = TextEditingController(text: _fmt(e?.targetNic ?? 3));
    _vg = TextEditingController(
      text: _fmt(e?.targetVgPercent ?? set.defaultVgPercent),
    );
    _percentMode = e?.percentMode ?? set.defaultPercentMode;
    _baseMode = e?.baseMode ?? BaseMode.ratio;
    _nicId = e?.nicId;
    _pgId = e?.pgId;
    _vgId = e?.vgId;

    if (e != null) {
      for (final f in e.flavors) {
        final ing = s.byId(f.ingredientId) ?? s.flavorByName(f.name);
        _rows.add(
          _ConcentrateRow(
            ing?.kind ?? IngredientKind.flavor,
            ingredientId: ing?.id,
            percent: _fmt(f.percent),
          ),
        );
      }
    }

    for (final c in [_name, _notes, _batch, _nic, _vg]) {
      c.addListener(_onChanged);
    }
    for (final r in _rows) {
      r.percent.addListener(_onChanged);
    }
    _initialSnapshot = _snapshot();
  }

  @override
  void dispose() {
    for (final c in [_name, _notes, _batch, _nic, _vg]) {
      c.dispose();
    }
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _onChanged() => setState(() {});

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  double _val(TextEditingController c) => parseNum(c.text) ?? 0;

  bool _bad(TextEditingController c) =>
      c.text.trim().isNotEmpty && parseNum(c.text) == null;

  /// Stable representation used for the unsaved-changes check. Covers every
  /// field including row order and both modes.
  String _snapshot() => jsonEncode(_build('snapshot').toJson());

  bool get _dirty => _snapshot() != _initialSnapshot;

  Recipe _build(String id) => Recipe(
    id: id,
    name: _name.text.trim(),
    notes: _notes.text.trim(),
    batchMl: _val(_batch),
    targetNic: _val(_nic),
    targetVgPercent: _val(_vg),
    percentMode: _percentMode,
    baseMode: _baseMode,
    nicId: _nicId,
    pgId: _pgId,
    vgId: _vgId,
    flavors: [
      for (final r in _rows)
        if (s.byId(r.ingredientId) != null && _val(r.percent) > 0)
          RecipeFlavor(
            ingredientId: r.ingredientId!,
            name: s.byId(r.ingredientId)!.displayName,
            percent: _val(r.percent),
          ),
    ],
  );

  // -------------------------------------------------------------- validation

  int get _incompleteRows => _rows
      .where((r) => s.byId(r.ingredientId) == null || _val(r.percent) <= 0)
      .length;

  Set<String> get _duplicateIds {
    final seen = <String>{};
    final dupes = <String>{};
    for (final r in _rows) {
      final id = r.ingredientId;
      if (id == null) continue;
      if (!seen.add(id)) dupes.add(id);
    }
    return dupes;
  }

  bool get _canSave {
    if (_name.text.trim().isEmpty) return false;
    if ([_batch, _nic, _vg].any(_bad)) return false;
    if (_rows.any((r) => _bad(r.percent))) return false;
    return true;
  }

  // ----------------------------------------------------------------- actions

  void _addRow(IngredientKind kind) => setState(() {
    _rows.add(_ConcentrateRow(kind)..percent.addListener(_onChanged));
  });

  void _removeRow(_ConcentrateRow row) => setState(() {
    row.dispose();
    _rows.remove(row);
  });

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: Text(
          _isNew
              ? 'This recipe has not been saved yet.'
              : 'Your edits to "${widget.existing!.name}" will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _save() {
    final recipe = _build(widget.existing?.id ?? newId());
    if (_isNew) {
      s.addRecipe(recipe);
    } else {
      s.updateRecipe(recipe);
    }
    Navigator.pop(context, recipe);
  }

  // -------------------------------------------------------------------- view

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard()) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'New recipe' : 'Edit recipe'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.icon(
                onPressed: _canSave ? _save : null,
                icon: const Icon(Icons.check),
                label: Text(_isNew ? 'Create' : 'Save'),
              ),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, c) {
            final wide = Breaks.isWide(c.maxWidth);
            final form = _form(theme);
            final preview = _preview(theme);
            return SingleChildScrollView(
              padding: const EdgeInsets.all(Gap.lg),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: form),
                        Gap.hLg,
                        Expanded(flex: 2, child: preview),
                      ],
                    )
                  : Column(children: [form, Gap.vLg, preview]),
            );
          },
        ),
      ),
    );
  }

  Widget _form(ThemeData theme) {
    final nameClash = s.recipeByName(_name.text, exceptId: widget.existing?.id);
    final isMaxVg = _baseMode == BaseMode.maxVg;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: _isNew,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Recipe name',
                border: const OutlineInputBorder(),
                errorText: _name.text.trim().isEmpty ? 'Required' : null,
                helperText: nameClash != null
                    ? 'Another recipe already uses this name'
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Notes',
                hintText: 'Steep time, origin, tweaks to try…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            Text('Defaults when mixing', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _num(_batch, 'Batch (mL)')),
                const SizedBox(width: 8),
                Expanded(child: _num(_nic, 'Nic (mg/mL)')),
                const SizedBox(width: 8),
                Expanded(
                  child: _num(
                    _vg,
                    'VG %',
                    // Max VG ignores the target, so do not pretend otherwise.
                    enabled: !isMaxVg,
                    hint: isMaxVg ? 'set by mix' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

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

            Text('Bases', style: theme.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(
              'Which bottles this recipe is mixed from. Leave any unset to '
              'use whatever is selected at mix time.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            IngredientPickerField(
              label: 'Nicotine base',
              placeholder: 'Any — use current selection',
              items: s.ofKind(IngredientKind.nicotine),
              selectedId: _nicId,
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
                    placeholder: 'Any',
                    items: s.ofKind(IngredientKind.pg),
                    selectedId: _pgId,
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
                    placeholder: 'Any',
                    items: s.ofKind(IngredientKind.vg),
                    selectedId: _vgId,
                    settings: s.settings,
                    state: s,
                    createKind: IngredientKind.vg,
                    emptyHint: 'No VG in inventory',
                    onSelected: (id) => setState(() => _vgId = id),
                  ),
                ),
              ],
            ),
            if (s.hasMissingBase(_build('check')))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'A base this recipe named is no longer in your inventory. '
                  'Pick another, or clear it to use the current selection.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),

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
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                percentModeHint(_percentMode),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: Text(
                    'Ingredients (${_rows.length})',
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
                        onPressed: () => _addRow(k),
                        child: Text(kindLabel(k)),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No ingredients yet.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              )
            else
              ReorderableListView(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                physics: const NeverScrollableScrollPhysics(),
                onReorderItem: (oldIndex, newIndex) => setState(() {
                  _rows.insert(newIndex, _rows.removeAt(oldIndex));
                }),
                children: [
                  for (var i = 0; i < _rows.length; i++) _rowTile(i, theme),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _num(
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

  Widget _rowTile(int i, ThemeData theme) {
    final row = _rows[i];
    final ing = s.byId(row.ingredientId);
    final isDupe =
        row.ingredientId != null && _duplicateIds.contains(row.ingredientId);
    final needMl = _val(_batch) * _val(row.percent) / 100;
    final short = ing != null && needMl > ing.stockMl + 1e-9;

    return Padding(
      key: row.key,
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: i,
            child: const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.drag_indicator, size: 20),
            ),
          ),

          // Kind badge, tappable to reclassify the row.
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: MenuAnchor(
              builder: (context, controller, child) => Tooltip(
                message: '${kindLabel(row.kind)} — tap to change',
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
                      color: switch (row.kind) {
                        IngredientKind.additive =>
                          theme.colorScheme.tertiaryContainer,
                        IngredientKind.thinner =>
                          theme.colorScheme.secondaryContainer,
                        _ => theme.colorScheme.surfaceContainerHighest,
                      },
                    ),
                    child: Icon(switch (row.kind) {
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
                      row.kind = k;
                      // The current selection may not belong to the new kind.
                      if (s.byId(row.ingredientId)?.kind != k) {
                        row.ingredientId = null;
                      }
                    }),
                    child: Text(kindLabel(k)),
                  ),
              ],
            ),
          ),

          Expanded(
            child: IngredientPickerField(
              label: kindLabel(row.kind),
              items: s.ofKind(row.kind),
              selectedId: row.ingredientId,
              settings: s.settings,
              state: s,
              createKind: row.kind,
              emptyHint:
                  'No ${kindLabel(row.kind).toLowerCase()}s yet — '
                  'search a name and create it',
              onSelected: (id) => setState(() => row.ingredientId = id),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: TextField(
              controller: row.percent,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: '%',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _bad(row.percent) ? '?' : null,
              ),
            ),
          ),
          if (isDupe)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Tooltip(
                message: 'Listed more than once — amounts will be combined',
                child: Icon(
                  Icons.merge_type,
                  size: 20,
                  color: theme.colorScheme.tertiary,
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
                  size: 20,
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Remove',
            onPressed: () => _removeRow(row),
          ),
        ],
      ),
    );
  }

  Widget _preview(ThemeData theme) {
    final set = s.settings;
    final draft = _build('preview');
    final flavors = <(Ingredient, double)>[
      for (final f in draft.flavors)
        if (s.byId(f.ingredientId) != null)
          (s.byId(f.ingredientId)!, f.percent),
    ];
    final result = calculateMix(
      amountMl: draft.batchMl,
      targetNic: draft.targetNic,
      targetVgPercent: draft.targetVgPercent,
      settings: set,
      percentMode: _percentMode,
      baseMode: _baseMode,
      nic: s.baseFor(draft, IngredientKind.nicotine),
      pg: s.baseFor(draft, IngredientKind.pg),
      vg: s.baseFor(draft, IngredientKind.vg),
      flavors: flavors,
    );
    final issues = checkStock(result, s.ingredients);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Preview', style: theme.textTheme.titleLarge),
                ),
                if (_baseMode == BaseMode.maxVg)
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
            Text(
              'At ${_fmt(draft.batchMl)} mL, using '
              '${_nicId == null && _pgId == null && _vgId == null ? 'your default bases' : 'this recipe\'s bases'}.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _stat(
              'Flavor',
              '${result.flavorPercentByVolume.toStringAsFixed(1)}% vol / '
                  '${result.flavorPercentByWeight.toStringAsFixed(1)}% wt',
              theme,
            ),
            if (result.hasAdditives)
              _stat(
                'Additives',
                '${result.additivePercentByVolume.toStringAsFixed(1)}%',
                theme,
              ),
            _stat(
              'Batch weight',
              '${result.totalGrams.toStringAsFixed(2)} g',
              theme,
            ),
            _stat(
              'Final ratio',
              '${result.actualVgPercent.toStringAsFixed(0)}% VG',
              theme,
            ),
            _stat(
              'Nicotine',
              '${result.actualNicMgPerMl.toStringAsFixed(2)} mg/mL',
              theme,
            ),
            _stat('Cost', money(result.totalCost, set), theme),
            const Divider(height: 24),
            if (_incompleteRows > 0)
              _note(
                '$_incompleteRows incomplete row(s) will be dropped on save.',
                theme.colorScheme.tertiary,
                theme,
              ),
            for (final w in result.warnings)
              _note(w, theme.colorScheme.error, theme),
            for (final w in scaleWarnings(result, set.scaleResolution))
              _note(w, theme.colorScheme.tertiary, theme),
            if (issues.isNotEmpty)
              _note(
                'Short on ${issues.length} ingredient(s) at this batch size.',
                theme.colorScheme.error,
                theme,
              ),
            if (_rows.isEmpty)
              _note(
                'A recipe with no ingredients is allowed, but it is just base.',
                theme.colorScheme.outline,
                theme,
              ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    ),
  );

  Widget _note(String text, Color color, ThemeData theme) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color)),
  );
}
