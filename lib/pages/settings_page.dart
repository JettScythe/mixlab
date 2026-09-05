import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/toast.dart';
import 'merge_preview_page.dart';

/// Platforms where file_selector implements a native save panel.
bool get _canSaveToFile {
  if (kIsWeb) return true; // browser download
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}

const _scaleOptions = <double>[0.001, 0.01, 0.1];

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});
  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController pg,
      vg,
      flavor,
      thinner,
      currency,
      defVg,
      defBatch,
      refBottle,
      lowStock,
      bottleCost,
      bottleMl,
      consumables;

  late double scaleRes;
  late bool tareEach;
  late PercentMode defaultMode;
  late int themeMode;
  late bool includeHardware;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    final c = s.settings;
    pg = TextEditingController(text: c.pgDensity.toString());
    vg = TextEditingController(text: c.vgDensity.toString());
    flavor = TextEditingController(text: c.flavorDensity.toString());
    thinner = TextEditingController(text: c.thinnerDensity.toString());
    currency = TextEditingController(text: c.currency);
    defVg = TextEditingController(text: c.defaultVgPercent.toStringAsFixed(0));
    defBatch = TextEditingController(text: c.defaultBatchMl.toStringAsFixed(0));
    refBottle = TextEditingController(text: c.refBottleMl.toStringAsFixed(0));
    lowStock = TextEditingController(text: c.lowStockMl.toStringAsFixed(0));
    bottleCost = TextEditingController(
      text: c.emptyBottleCost == 0 ? '' : c.emptyBottleCost.toString(),
    );
    bottleMl = TextEditingController(text: c.emptyBottleMl.toStringAsFixed(0));
    consumables = TextEditingController(
      text: c.consumablesCost == 0 ? '' : c.consumablesCost.toString(),
    );

    scaleRes = _scaleOptions.contains(c.scaleResolution)
        ? c.scaleResolution
        : 0.01;
    tareEach = c.tareEachStep;
    defaultMode = c.defaultPercentMode;
    themeMode = c.themeMode;
    includeHardware = c.includeHardware;
  }

  /// Re-reads every control from settings, after an import or a reset.
  void _refillFromSettings() {
    final c = s.settings;
    pg.text = c.pgDensity.toString();
    vg.text = c.vgDensity.toString();
    flavor.text = c.flavorDensity.toString();
    thinner.text = c.thinnerDensity.toString();
    currency.text = c.currency;
    defVg.text = c.defaultVgPercent.toStringAsFixed(0);
    defBatch.text = c.defaultBatchMl.toStringAsFixed(0);
    refBottle.text = c.refBottleMl.toStringAsFixed(0);
    lowStock.text = c.lowStockMl.toStringAsFixed(0);
    bottleCost.text = c.emptyBottleCost == 0
        ? ''
        : c.emptyBottleCost.toString();
    bottleMl.text = c.emptyBottleMl.toStringAsFixed(0);
    consumables.text = c.consumablesCost == 0
        ? ''
        : c.consumablesCost.toString();
    scaleRes = _scaleOptions.contains(c.scaleResolution)
        ? c.scaleResolution
        : 0.01;
    tareEach = c.tareEachStep;
    defaultMode = c.defaultPercentMode;
    themeMode = c.themeMode;
    includeHardware = c.includeHardware;
  }

  Future<void> _merge() async {
    try {
      const group = XTypeGroup(label: 'JSON', extensions: ['json']);
      final file = await openFile(acceptedTypeGroups: const [group]);
      if (file == null) return;

      final plan = s.previewMerge(await file.readAsString());
      if (!mounted) return;

      final summary = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => MergePreviewPage(state: s, plan: plan),
        ),
      );
      if (summary == null || !mounted) return;
      setState(_refillFromSettings);
      showToast(context, summary);
    } catch (e, st) {
      debugPrint('Merge failed: $e');
      debugPrintStack(stackTrace: st);
      await _showError('Merge failed', e);
    }
  }

  @override
  void dispose() {
    for (final c in [
      pg,
      vg,
      flavor,
      thinner,
      currency,
      defVg,
      defBatch,
      refBottle,
      lowStock,
      bottleCost,
      bottleMl,
      consumables,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double _v(TextEditingController c, double fallback) =>
      parseNum(c.text) ?? fallback;

  bool _bad(TextEditingController c) =>
      c.text.trim().isNotEmpty && parseNum(c.text) == null;

  /// Errors go in a dialog with selectable text — a snackbar is too easy to
  /// miss and impossible to copy.
  Future<void> _showError(String title, Object error) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(child: SelectableText('$error')),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: '$error'));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final anyBad = [
      pg,
      vg,
      flavor,
      thinner,
      defVg,
      defBatch,
      refBottle,
      lowStock,
      bottleCost,
      bottleMl,
      consumables,
    ].any(_bad);

    final perBottle = parseNum(bottleMl.text) ?? 30;
    final bottlesFor100 = perBottle > 0 ? (100 / perBottle).ceil() : 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              _card(theme, 'Appearance', [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('System')),
                    ButtonSegment(value: 1, label: Text('Light')),
                    ButtonSegment(value: 2, label: Text('Dark')),
                  ],
                  selected: {themeMode},
                  onSelectionChanged: (v) =>
                      setState(() => themeMode = v.first),
                ),
                Gap.vXs,
                _hint(theme, 'Applies when you save.'),
              ]),

              _card(theme, 'Densities', [
                _hint(
                  theme,
                  'Used when an ingredient has no measured density of its '
                  'own. Concentrates are mostly carrier, so a PG-based '
                  'flavor sits close to PG.',
                ),
                Gap.vMd,
                _field(pg, 'PG density (g/mL)'),
                _field(vg, 'VG density (g/mL)'),
                _field(
                  flavor,
                  'Flavor and additive base density (g/mL)',
                  helper: 'Most concentrates are PG-based.',
                ),
                _field(
                  thinner,
                  'Thinner density (g/mL)',
                  helper: 'Distilled water ~1.0, PGA ~0.95.',
                ),
              ]),

              _card(theme, 'Mixing defaults', [
                _field(
                  currency,
                  'Currency code (ISO, e.g. USD, EUR, GBP)',
                  numeric: false,
                ),
                _field(defVg, 'Default target VG %'),
                _field(defBatch, 'Default batch size (mL)'),
                _field(refBottle, 'Reference bottle for cost readout (mL)'),
                _field(lowStock, 'Low stock warning below (mL)'),
                Gap.vSm,
                Text(
                  'Default percentage mode for new recipes',
                  style: theme.textTheme.titleSmall,
                ),
                Gap.vXs,
                SegmentedButton<PercentMode>(
                  segments: [
                    for (final m in PercentMode.values)
                      ButtonSegment(value: m, label: Text(percentModeLabel(m))),
                  ],
                  selected: {defaultMode},
                  onSelectionChanged: (v) =>
                      setState(() => defaultMode = v.first),
                ),
                Gap.vXs,
                _hint(theme, percentModeHint(defaultMode)),
              ]),

              _card(theme, 'Hardware costs', [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include hardware in mix cost'),
                  subtitle: const Text(
                    'Bottles and consumables are a real cost. Leaving this '
                    'off means your cost per bottle is understated.',
                  ),
                  value: includeHardware,
                  onChanged: (v) => setState(() => includeHardware = v),
                ),
                if (includeHardware) ...[
                  Gap.vSm,
                  Row(
                    children: [
                      Expanded(
                        child: _field(
                          bottleCost,
                          'Empty bottle cost (${currency.text.trim()})',
                        ),
                      ),
                      Gap.hSm,
                      Expanded(child: _field(bottleMl, 'Bottle size (mL)')),
                    ],
                  ),
                  _field(
                    consumables,
                    'Consumables per batch (${currency.text.trim()})',
                    helper: 'Caps, labels, gloves — anything spent per mix.',
                  ),
                  if (bottlesFor100 > 0)
                    _hint(
                      theme,
                      'Bottles are counted whole: a 100 mL batch into '
                      '${perBottle.toStringAsFixed(0)} mL bottles uses '
                      '$bottlesFor100.',
                    ),
                ],
              ]),

              _card(theme, 'Scale', [
                _hint(
                  theme,
                  'Resolution of your scale. Amounts smaller than this get '
                  'flagged in the calculator and weigh-along.',
                ),
                Gap.vMd,
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<double>(
                    segments: const [
                      ButtonSegment(value: 0.001, label: Text('0.001 g')),
                      ButtonSegment(value: 0.01, label: Text('0.01 g')),
                      ButtonSegment(value: 0.1, label: Text('0.1 g')),
                    ],
                    selected: {scaleRes},
                    onSelectionChanged: (v) =>
                        setState(() => scaleRes = v.first),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Tare between ingredients'),
                  subtitle: const Text(
                    'Off: one cumulative running total (recommended). '
                    'On: zero the scale before each ingredient.',
                  ),
                  value: tareEach,
                  onChanged: (v) => setState(() => tareEach = v),
                ),
              ]),

              FilledButton.icon(
                onPressed: anyBad ? null : _saveSettings,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save settings'),
              ),
              Gap.vXl,

              _card(theme, 'Backup', [
                const Text(
                  'Exports ingredients, recipes, restocks, mix history and '
                  'settings as one JSON file. Import merges by id, so '
                  're-importing the same file is safe.',
                ),
                Gap.vMd,
                Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.sm,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _export,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(_canSaveToFile ? 'Export to file' : 'Export'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await s.flush();
                        await Clipboard.setData(
                          ClipboardData(text: s.exportJson()),
                        );
                        if (!context.mounted) return;
                        showToast(context, 'Backup JSON copied to clipboard.');
                      },
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Copy JSON'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _merge,
                      icon: const Icon(Icons.merge),
                      label: const Text('Merge '),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _restore,
                      icon: const Icon(Icons.settings_backup_restore),
                      label: const Text('Restore (replace all)'),
                    ),
                  ],
                ),
                Gap.vSm,
                _hint(
                  theme,
                  'Schema v${AppState.currentSchema}  •  device '
                  '${s.deviceId}  •  '
                  '${s.ingredients.length} ingredients, '
                  '${s.recipes.length} recipes, '
                  '${s.mixLog.length} mixes, '
                  '${s.purchases.length} restocks',
                ),
              ]),

              _card(theme, 'Danger zone', [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: _reset,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Reset all data to seed'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  void _saveSettings() {
    final old = s.settings;
    s.updateSettings(
      Settings(
        pgDensity: _v(pg, old.pgDensity),
        vgDensity: _v(vg, old.vgDensity),
        flavorDensity: _v(flavor, old.flavorDensity),
        thinnerDensity: _v(thinner, old.thinnerDensity),
        currency: currency.text.trim().isEmpty
            ? old.currency
            : currency.text.trim().toUpperCase(),
        defaultVgPercent: _v(defVg, old.defaultVgPercent),
        defaultBatchMl: _v(defBatch, old.defaultBatchMl),
        refBottleMl: _v(refBottle, old.refBottleMl),
        scaleResolution: scaleRes,
        tareEachStep: tareEach,
        lowStockMl: _v(lowStock, old.lowStockMl),
        defaultPercentMode: defaultMode,
        themeMode: themeMode,
        includeHardware: includeHardware,
        emptyBottleCost: _v(bottleCost, 0),
        emptyBottleMl: _v(bottleMl, old.emptyBottleMl),
        consumablesCost: _v(consumables, 0),
      ),
    );
    showToast(context, 'Settings saved.');
  }

  Widget _card(ThemeData theme, String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.titleLarge),
          Gap.vMd,
          ...children,
        ],
      ),
    ),
  );

  Widget _hint(ThemeData theme, String text) => Text(
    text,
    style: theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    ),
  );

  Widget _field(
    TextEditingController c,
    String label, {
    bool numeric = true,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.sm),
    child: TextField(
      controller: c,
      onChanged: (_) => setState(() {}),
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        errorText: numeric && _bad(c) ? 'Enter a number' : null,
      ),
    ),
  );

  Future<void> _export() async {
    try {
      await s.flush(); // make sure pending writes are in the snapshot
      final json = s.exportJson();
      final stamp = DateTime.now().toIso8601String().split('T').first;
      final suggested = 'mixlab-backup-$stamp.json';

      if (!_canSaveToFile) {
        await Clipboard.setData(ClipboardData(text: json));
        if (!mounted) return;
        showToast(
          context,
          'Saving to a file is not supported here — backup copied to the '
          'clipboard instead.',
        );
        return;
      }

      final bytes = Uint8List.fromList(utf8.encode(json));
      final file = XFile.fromData(
        bytes,
        name: suggested,
        mimeType: 'application/json',
      );

      if (kIsWeb) {
        await file.saveTo(suggested); // triggers a browser download
        if (!mounted) return;
        showToast(context, 'Backup downloaded.');
        return;
      }

      const group = XTypeGroup(label: 'JSON', extensions: ['json']);
      final loc = await getSaveLocation(
        suggestedName: suggested,
        acceptedTypeGroups: const [group],
        confirmButtonText: 'Save backup',
      );
      if (loc == null) {
        if (!mounted) return;
        showToast(context, 'Export cancelled.');
        return;
      }

      final path = loc.path.toLowerCase().endsWith('.json')
          ? loc.path
          : '${loc.path}.json';
      await file.saveTo(path);
      if (!mounted) return;
      showToast(context, 'Backup saved.');
    } catch (e, st) {
      debugPrint('Export failed: $e');
      debugPrintStack(stackTrace: st);
      await _showError('Export failed', e);
    }
  }

  /// Wholesale restore. Everything local is discarded — this is the
  /// "put it back the way it was" path. For combining two devices use
  /// [_merge] instead.
  Future<void> _restore() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace everything?'),
        content: const Text(
          'Your current ingredients, recipes, restocks, stock history and '
          'mix history will be deleted and replaced by the backup.\n\n'
          'To combine two devices instead, use "Merge from another '
          'device".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      const group = XTypeGroup(label: 'JSON', extensions: ['json']);
      final file = await openFile(acceptedTypeGroups: const [group]);
      if (file == null) return;
      final summary = await s.restoreFromBackup(await file.readAsString());
      if (!mounted) return;
      setState(_refillFromSettings);
      showToast(context, summary);
    } catch (e, st) {
      debugPrint('Restore failed: $e');
      debugPrintStack(stackTrace: st);
      await _showError('Restore failed', e);
    }
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset all data?'),
        content: const Text(
          'Everything goes back to the seeded flavors and recipes. Export a '
          'backup first if you care about your stash.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await s.factoryReset();
    if (!mounted) return;
    setState(_refillFromSettings);
    showToast(context, 'Data reset.');
  }
}
