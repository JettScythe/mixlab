import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/ingredient.dart';
import 'package:mixlab/models/recipe.dart';
import 'package:mixlab/models/units.dart';

import '../recipe_import.dart';
import '../state.dart';
import '../theme.dart';

import '../widgets/ingredient_picker.dart';
import '../widgets/toast.dart';

/// Paste a recipe from ELR, AllTheFlavors, a spreadsheet or a forum post,
/// review how it was understood, then import it.
class ImportRecipePage extends StatefulWidget {
  const ImportRecipePage({super.key, required this.state});
  final AppState state;

  @override
  State<ImportRecipePage> createState() => _ImportRecipePageState();
}

/// A parsed line plus the user's decision about what it maps to.
class _Row {
  _Row(this.parsed, this.matchedId);

  final ParsedLine parsed;

  /// Resolved inventory id, or null to create a new ingredient.
  String? matchedId;

  /// Kind used when creating. Defaults to flavor; sweeteners and coolants
  /// are guessed as additives.
  IngredientKind createKind = IngredientKind.flavor;

  bool include = true;
}

const _additiveHints = [
  'sucralose',
  'sweetener', // was 'sweet' — too broad, caught "Sweet Cream"
  'super sweet',
  'ws-23',
  'ws23',
  'koolada',
  'cooling',
  'coolant',
  'menthol',
  'ethyl maltol',
  'acetyl pyrazine',
  'saline',
  'sour',
  'bitter',
  'marshmallow enhancer',
];

const _thinnerHints = ['distilled water', 'water', 'pga', 'vodka', 'alcohol'];

IngredientKind _guessKind(String name) {
  final l = name.toLowerCase();
  for (final h in _thinnerHints) {
    if (l == h || l.startsWith('$h ')) return IngredientKind.thinner;
  }
  for (final h in _additiveHints) {
    if (l.contains(h)) return IngredientKind.additive;
  }
  return IngredientKind.flavor;
}

class _ImportRecipePageState extends State<ImportRecipePage> {
  final _paste = TextEditingController();
  final _name = TextEditingController();
  final _batch = TextEditingController();
  final _nic = TextEditingController();
  final _vg = TextEditingController();

  ParsedRecipe? _parsed;
  final List<_Row> _rows = [];
  BaseMode _baseMode = BaseMode.ratio;
  PercentMode _percentMode = PercentMode.byVolume;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    final set = s.settings;
    _batch.text = set.defaultBatchMl.toStringAsFixed(0);
    _nic.text = '3';
    _vg.text = set.defaultVgPercent.toStringAsFixed(0);
    _percentMode = set.defaultPercentMode;
  }

  @override
  void dispose() {
    for (final c in [_paste, _name, _batch, _nic, _vg]) {
      c.dispose();
    }
    super.dispose();
  }

  void _parse() {
    final p = parseRecipeText(_paste.text);
    setState(() {
      _parsed = p;
      _rows
        ..clear()
        ..addAll([
          for (final l in p.lines)
            _Row(l, matchParsedLine(l, s.ingredients)?.id)
              ..createKind = _guessKind(l.name),
        ]);
      if (p.name != null && p.name!.isNotEmpty) _name.text = p.name!;
      if (p.batchMl != null) _batch.text = p.batchMl!.toStringAsFixed(0);
      if (p.nic != null) _nic.text = p.nic!.toStringAsFixed(1);
      if (p.vgPercent != null) _vg.text = p.vgPercent!.toStringAsFixed(0);
      _baseMode = p.maxVg ? BaseMode.maxVg : BaseMode.ratio;
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null) return;
    _paste.text = data!.text!;
    _parse();
  }

  double _val(TextEditingController c) => parseNum(c.text) ?? 0;

  int get _toCreate =>
      _rows.where((r) => r.include && r.matchedId == null).length;

  int get _included => _rows.where((r) => r.include).length;

  bool get _canImport => _included > 0 && _name.text.trim().isNotEmpty;

  Future<void> _import() async {
    final flavors = <RecipeFlavor>[];
    var created = 0;

    for (final row in _rows) {
      if (!row.include) continue;
      var ing = s.byId(row.matchedId);
      if (ing == null) {
        ing = Ingredient(
          id: newId(),
          name: row.parsed.name,
          brand: row.parsed.brand,
          kind: row.createKind,
          density: s.settings.densityForCarrier(row.createKind, 0),
        );
        s.upsertIngredient(ing);
        created++;
      }
      flavors.add(
        RecipeFlavor(
          ingredientId: ing.id,
          name: ing.displayName,
          percent: row.parsed.percent,
        ),
      );
    }

    final recipe = Recipe(
      id: newId(),
      name: _name.text.trim(),
      notes: 'Imported ${DateTime.now().toIso8601String().split('T').first}.',
      batchMl: _val(_batch),
      targetNic: _val(_nic),
      targetVgPercent: _val(_vg),
      percentMode: _percentMode,
      baseMode: _baseMode,
      flavors: flavors,
    );
    s.addRecipe(recipe);

    if (!mounted) return;
    Navigator.pop(context, recipe);
    showToast(
      context,
      created > 0
          ? 'Imported "${recipe.name}" and created $created ingredient(s) '
                'with no stock or cost yet.'
          : 'Imported "${recipe.name}".',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import recipe'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton.icon(
              onPressed: _canImport ? _import : null,
              icon: const Icon(Icons.download_done),
              label: const Text('Import'),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = Breaks.isWide(c.maxWidth);
          final input = _inputCard(theme);
          final preview = _previewCard(theme);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.lg),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: input),
                      Gap.hLg,
                      Expanded(flex: 3, child: preview),
                    ],
                  )
                : Column(children: [input, Gap.vLg, preview]),
          );
        },
      ),
    );
  }

  Widget _inputCard(ThemeData theme) => Card(
    child: Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Paste recipe text', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Works with e-liquid-recipes.com, AllTheFlavors, spreadsheet '
            'columns and plain forum posts. Percentages with or without a '
            '% sign, vendor as a prefix or in parentheses.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _paste,
            maxLines: 12,
            minLines: 8,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText:
                  '8% TFA Strawberry (Ripe)\n'
                  '6% Vanilla Bean Ice Cream (TPA)\n'
                  '30ml, 70/30, 3mg',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _parse,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Parse'),
              ),
              OutlinedButton.icon(
                onPressed: _pasteFromClipboard,
                icon: const Icon(Icons.content_paste),
                label: const Text('Paste from clipboard'),
              ),
              if (_paste.text.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(() {
                    _paste.clear();
                    _parsed = null;
                    _rows.clear();
                  }),
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear'),
                ),
            ],
          ),
          if (_parsed != null) ...[
            const Divider(height: 28),
            Text('Recipe settings', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Recipe name',
                border: const OutlineInputBorder(),
                errorText: _name.text.trim().isEmpty ? 'Required' : null,
              ),
            ),
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
                    enabled: _baseMode == BaseMode.ratio,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<BaseMode>(
              segments: [
                for (final m in BaseMode.values)
                  ButtonSegment(value: m, label: Text(baseModeLabel(m))),
              ],
              selected: {_baseMode},
              onSelectionChanged: (v) => setState(() => _baseMode = v.first),
            ),
            const SizedBox(height: 8),
            SegmentedButton<PercentMode>(
              segments: [
                for (final m in PercentMode.values)
                  ButtonSegment(value: m, label: Text(percentModeLabel(m))),
              ],
              selected: {_percentMode},
              onSelectionChanged: (v) => setState(() => _percentMode = v.first),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Shared recipes are almost always by volume. Only switch if '
                'the source says otherwise.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _num(TextEditingController c, String label, {bool enabled = true}) =>
      TextField(
        controller: c,
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      );

  Widget _previewCard(ThemeData theme) {
    final p = _parsed;
    if (p == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Text(
              'Paste something and hit Parse.\n'
              'Nothing is saved until you press Import.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Found ${p.lines.length} ingredient(s)',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                Text(
                  '${p.totalPercent.toStringAsFixed(1)}% total',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            if (_toCreate > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '$_toCreate will be created in your inventory with no '
                  'stock or cost — fill those in later so cost figures work.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (p.lines.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'Nothing recognisable. Each ingredient needs a name and '
                    'a percentage on the same line.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            for (final row in _rows) _rowTile(row, theme),
            if (p.ignored.isNotEmpty) ...[
              const Divider(height: 24),
              Text(
                'Not understood (${p.ignored.length})',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              for (final line in p.ignored)
                Text(
                  line,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                    fontFamily: 'monospace',
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'Add these by hand after importing if they matter.',
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

  Widget _rowTile(_Row row, ThemeData theme) {
    final matched = s.byId(row.matchedId);
    final isNew = matched == null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: row.include
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: row.include,
                onChanged: (v) => setState(() => row.include = v ?? true),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  '${row.parsed.percent.toStringAsFixed(1)}%',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: Text(
                  row.parsed.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: row.include
                      ? null
                      : TextStyle(
                          decoration: TextDecoration.lineThrough,
                          color: theme.colorScheme.outline,
                        ),
                ),
              ),
              if (isNew)
                Chip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('New'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: theme.colorScheme.tertiaryContainer,
                )
              else
                Chip(
                  avatar: const Icon(Icons.check, size: 16),
                  label: const Text('Matched'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          if (row.include)
            Padding(
              padding: const EdgeInsets.only(left: 48, top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isNew)
                    Text(
                      'Using ${matched.displayName} — '
                      '${matched.stockMl.toStringAsFixed(1)} mL on hand',
                      style: theme.textTheme.bodySmall,
                    ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: IngredientPickerField(
                          label: isNew
                              ? 'Match to existing (optional)'
                              : 'Matched to',
                          items: s.concentrates,
                          selectedId: row.matchedId,
                          settings: s.settings,
                          state: s,
                          createKind: row.createKind,
                          onSelected: (id) =>
                              setState(() => row.matchedId = id),
                        ),
                      ),
                      if (isNew) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 150,
                          child: DropdownMenu<IngredientKind>(
                            initialSelection: row.createKind,
                            label: const Text('Create as'),
                            expandedInsets: EdgeInsets.zero,
                            onSelected: (k) => setState(
                              () => row.createKind = k ?? row.createKind,
                            ),
                            dropdownMenuEntries: [
                              for (final k in const [
                                IngredientKind.flavor,
                                IngredientKind.additive,
                                IngredientKind.thinner,
                              ])
                                DropdownMenuEntry(
                                  value: k,
                                  label: kindLabel(k),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'from: ${row.parsed.raw}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
