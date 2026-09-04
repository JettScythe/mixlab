import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../state.dart';
import '../widgets/toast.dart';

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
      lowStock;
  late double scaleRes;
  late bool tareEach;
  late PercentMode defaultMode;
  late int themeMode;

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
    scaleRes = _scaleOptions.contains(c.scaleResolution)
        ? c.scaleResolution
        : 0.01;
    tareEach = c.tareEachStep;
    defaultMode = c.defaultPercentMode;
    themeMode = c.themeMode;
  }

  /// Re-reads every control from settings, after an import or reset.
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
    scaleRes = _scaleOptions.contains(c.scaleResolution)
        ? c.scaleResolution
        : 0.01;
    tareEach = c.tareEachStep;
    defaultMode = c.defaultPercentMode;
    themeMode = c.themeMode;
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
    ].any(_bad);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _card('Appearance', [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('System')),
                ButtonSegment(value: 1, label: Text('Light')),
                ButtonSegment(value: 2, label: Text('Dark')),
              ],
              selected: {themeMode},
              onSelectionChanged: (v) => setState(() => themeMode = v.first),
            ),
            const SizedBox(height: 4),
            Text(
              'Applies when you save.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _card('Densities', [
            Text(
              'Used when an ingredient has no measured density of its own. '
              'Concentrates are mostly carrier, so a PG-based flavor sits '
              'close to PG.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
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
          const SizedBox(height: 16),

          _card('Mixing defaults', [
            _field(
              currency,
              'Currency code (ISO, e.g. USD, EUR, GBP)',
              numeric: false,
            ),
            _field(defVg, 'Default target VG %'),
            _field(defBatch, 'Default batch size (mL)'),
            _field(refBottle, 'Reference bottle for cost readout (mL)'),
            _field(lowStock, 'Low stock warning below (mL)'),
            const SizedBox(height: 8),
            Text(
              'Default percentage mode for new recipes',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            SegmentedButton<PercentMode>(
              segments: [
                for (final m in PercentMode.values)
                  ButtonSegment(value: m, label: Text(percentModeLabel(m))),
              ],
              selected: {defaultMode},
              onSelectionChanged: (v) => setState(() => defaultMode = v.first),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                percentModeHint(defaultMode),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 16),

          _card('Scale', [
            Text(
              'Resolution of your scale. Amounts smaller than this get '
              'flagged in the calculator and weigh-along.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<double>(
                segments: const [
                  ButtonSegment(value: 0.001, label: Text('0.001 g')),
                  ButtonSegment(value: 0.01, label: Text('0.01 g')),
                  ButtonSegment(value: 0.1, label: Text('0.1 g')),
                ],
                selected: {scaleRes},
                onSelectionChanged: (v) => setState(() => scaleRes = v.first),
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
          const SizedBox(height: 16),

          FilledButton.icon(
            onPressed: anyBad ? null : _saveSettings,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save settings'),
          ),
          const SizedBox(height: 24),

          _card('Backup', [
            const Text(
              'Exports ingredients, recipes, restocks, mix history and '
              'settings as one JSON file. Import merges by id, so '
              're-importing the same file is safe.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
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
                  onPressed: () => _import(replace: false),
                  icon: const Icon(Icons.upload_outlined),
                  label: const Text('Import (merge)'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _import(replace: true),
                  icon: const Icon(Icons.sync_alt),
                  label: const Text('Import (replace all)'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Schema v${AppState.currentSchema}  •  '
              '${s.ingredients.length} ingredients, '
              '${s.recipes.length} recipes, '
              '${s.mixLog.length} mixes, '
              '${s.purchases.length} restocks',
              style: theme.textTheme.bodySmall,
            ),
          ]),
          const SizedBox(height: 16),

          _card('Danger zone', [
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
      ),
    );
    showToast(context, 'Settings saved.');
  }

  Widget _card(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );

  Widget _field(
    TextEditingController c,
    String label, {
    bool numeric = true,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: TextField(
      controller: c,
      onChanged: (_) => setState(() {}),
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
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
      showToast(context, 'Backup saved to $path');
    } catch (e, st) {
      debugPrint('Export failed: $e');
      debugPrintStack(stackTrace: st);
      await _showError('Export failed', e);
    }
  }

  Future<void> _import({required bool replace}) async {
    if (replace) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace everything?'),
          content: const Text(
            'Your current ingredients, recipes, restocks and mix history '
            'will be deleted and replaced by the backup.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      const group = XTypeGroup(label: 'JSON', extensions: ['json']);
      final file = await openFile(acceptedTypeGroups: const [group]);
      if (file == null) return;
      final summary = await s.importJson(
        await file.readAsString(),
        replace: replace,
      );
      if (!mounted) return;
      setState(_refillFromSettings);
      showToast(context, summary);
    } catch (e, st) {
      debugPrint('Import failed: $e');
      debugPrintStack(stackTrace: st);
      await _showError('Import failed', e);
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
