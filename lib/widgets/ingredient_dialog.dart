import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';

/// Opens the add/edit ingredient dialog. Returns the saved ingredient, or
/// null if cancelled. Does not persist — the caller decides.
Future<Ingredient?> showIngredientDialog(
  BuildContext context, {
  required AppState state,
  Ingredient? existing,
  IngredientKind? initialKind,
  String? initialName,
}) => showDialog<Ingredient>(
  context: context,
  builder: (context) => IngredientDialog(
    state: state,
    existing: existing,
    initialKind: initialKind,
    initialName: initialName,
  ),
);

class IngredientDialog extends StatefulWidget {
  const IngredientDialog({
    super.key,
    required this.state,
    this.existing,
    this.initialKind,
    this.initialName,
  });

  final AppState state;
  final Ingredient? existing;
  final IngredientKind? initialKind;

  /// Pre-fills the name, e.g. from an unmatched search query.
  final String? initialName;

  @override
  State<IngredientDialog> createState() => _IngredientDialogState();
}

class _IngredientDialogState extends State<IngredientDialog> {
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
  late NicUnit nicUnit;
  late bool isSalt;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    kind = e?.kind ?? widget.initialKind ?? IngredientKind.flavor;
    String n(double v) => v == 0 ? '' : v.toString();
    nicUnit = e?.nicUnit ?? NicUnit.perMl;
    isSalt = e?.nicIsSalt ?? false;
    var startBrand = e?.brand ?? '';
    var startName = e?.name ?? widget.initialName?.trim() ?? '';
    if (e == null && startBrand.isEmpty && startName.isNotEmpty) {
      final (b, rest) = splitBrand(startName);
      startBrand = b;
      startName = rest;
    }

    name = TextEditingController(text: startName);
    brand = TextEditingController(text: startBrand);
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
    final showCarrier = isConcentrate(kind) || isNic;
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
                      '${dup.stockMl.toStringAsFixed(1)} mL on hand. Edit or '
                      'restock that one instead.',
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
                    if (!isConcentrate(k) && k != IngredientKind.nicotine) {
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
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                  child: Text(
                    kindHint(kind),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ),
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
                    'Implied by carrier: ${_impliedDensity.toStringAsFixed(3)}',
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
                        'Use ${_impliedDensity.toStringAsFixed(3)} from '
                        'carrier',
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
              if (isNic) ...[
                Row(
                  children: [
                    Expanded(
                      child: field(nic, 'Strength (${nicUnitLabel(nicUnit)})'),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 130,
                      child: DropdownMenu<NicUnit>(
                        initialSelection: nicUnit,
                        label: const Text('Unit'),
                        expandedInsets: EdgeInsets.zero,
                        onSelected: (u) =>
                            setState(() => nicUnit = u ?? nicUnit),
                        dropdownMenuEntries: [
                          for (final u in NicUnit.values)
                            DropdownMenuEntry(value: u, label: nicUnitLabel(u)),
                        ],
                      ),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                    child: Text(
                      nicUnit == NicUnit.perGram
                          ? '${nicUnitHint(nicUnit)} '
                                'At ${_v(density).toStringAsFixed(3)} g/mL '
                                'that is '
                                '${(_v(nic) * _v(density)).toStringAsFixed(1)} '
                                'mg/mL.'
                          : nicUnitHint(nicUnit),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  title: const Text('Nicotine salt'),
                  subtitle: const Text(
                    'Recorded for the log. Mixing math is unchanged.',
                  ),
                  value: isSalt,
                  onChanged: (v) => setState(() => isSalt = v ?? false),
                ),
              ],
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
                      nicUnit: nicUnit,
                      nicIsSalt: isSalt,
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
