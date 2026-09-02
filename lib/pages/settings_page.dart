import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../state.dart';

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
      currency,
      defVg,
      defBatch,
      scaleRes,
      refBottle;
  bool tareEach = false;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    final c = s.settings;

    pg = TextEditingController(text: c.pgDensity.toString());
    vg = TextEditingController(text: c.vgDensity.toString());
    flavor = TextEditingController(text: c.flavorDensity.toString());
    currency = TextEditingController(text: c.currency);
    defVg = TextEditingController(text: c.defaultVgPercent.toStringAsFixed(0));
    defBatch = TextEditingController(text: c.defaultBatchMl.toStringAsFixed(0));
    refBottle = TextEditingController(text: c.refBottleMl.toStringAsFixed(0));
    scaleRes = TextEditingController(text: c.scaleResolution.toString());
    tareEach = c.tareEachStep;
  }

  @override
  void dispose() {
    for (final c in [
      pg,
      vg,
      flavor,
      currency,
      defVg,
      defBatch,
      refBottle,
      scaleRes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double _v(TextEditingController c, double fallback) =>
      parseNum(c.text) ?? fallback;
  bool _bad(TextEditingController c) =>
      c.text.trim().isNotEmpty && parseNum(c.text) == null;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _card('Mixing defaults', [
            _field(pg, 'PG density (g/mL)'),
            _field(vg, 'VG density (g/mL)'),
            _field(flavor, 'Default flavor density (g/mL)'),
            _field(
              currency,
              'Currency code (ISO, e.g. USD, EUR, GBP)',
              numeric: false,
            ),
            _field(defVg, 'Default target VG %'),
            _field(defBatch, 'Default batch size (mL)'),
            _field(refBottle, 'Reference bottle for cost readout (mL)'),
            const SizedBox(height: 4),
            FilledButton.icon(
              onPressed: () {
                final old = s.settings;
                s.updateSettings(
                  Settings(
                    pgDensity: _v(pg, old.pgDensity),
                    vgDensity: _v(vg, old.vgDensity),
                    flavorDensity: _v(flavor, old.flavorDensity),
                    currency: currency.text.trim().isEmpty
                        ? old.currency
                        : currency.text.trim().toUpperCase(),
                    defaultVgPercent: _v(defVg, old.defaultVgPercent),
                    defaultBatchMl: _v(defBatch, old.defaultBatchMl),
                    refBottleMl: _v(refBottle, old.refBottleMl),
                    scaleResolution: _v(scaleRes, old.scaleResolution),
                    tareEachStep: tareEach,
                  ),
                );
                _toast('Settings saved.');
              },
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save settings'),
            ),
          ]),
          const SizedBox(height: 16),
          _card('Scale', [
            _field(scaleRes, 'Scale resolution (g) — 0.01 or 0.1'),
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
          _card('Backup', [
            const Text(
              'Exports ingredients, recipes, mix history and '
              'settings as a single JSON file. Import merges by id, so '
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
                  label: const Text('Export to file'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: s.exportJson()),
                    );
                    _toast('Backup JSON copied to clipboard.');
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
              '${s.mixLog.length} logged mixes',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ]),
          const SizedBox(height: 16),
          _card('Danger zone', [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
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

  Widget _field(TextEditingController c, String label, {bool numeric = true}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: c,
          onChanged: (_) => setState(() {}),
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : null,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            errorText: numeric && _bad(c) ? 'Enter a number' : null,
          ),
        ),
      );

  Future<void> _export() async {
    try {
      final json = s.exportJson();
      final bytes = Uint8List.fromList(utf8.encode(json));
      final stamp = DateTime.now().toIso8601String().split('T').first;
      final name = 'ejuice-backup-$stamp.json';
      final file = XFile.fromData(
        bytes,
        name: name,
        mimeType: 'application/json',
      );
      if (kIsWeb) {
        await file.saveTo(name);
        _toast('Backup downloaded.');
        return;
      }
      final loc = await getSaveLocation(suggestedName: name);
      if (loc == null) return;
      await file.saveTo(loc.path);
      _toast('Backup saved.');
    } catch (e) {
      _toast('Export failed: $e');
    }
  }

  Future<void> _import({required bool replace}) async {
    if (replace) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace everything?'),
          content: const Text(
            'Your current ingredients, recipes and mix '
            'history will be deleted and replaced by the backup.',
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
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return;
      final summary = await s.importJson(
        await file.readAsString(),
        replace: replace,
      );
      if (!mounted) return;
      setState(() {
        final c = s.settings;
        pg.text = c.pgDensity.toString();
        vg.text = c.vgDensity.toString();
        flavor.text = c.flavorDensity.toString();
        currency.text = c.currency;
        defVg.text = c.defaultVgPercent.toStringAsFixed(0);
        defBatch.text = c.defaultBatchMl.toStringAsFixed(0);
        refBottle.text = c.refBottleMl.toStringAsFixed(0);
        scaleRes.text = c.scaleResolution.toString();
        tareEach = c.tareEachStep;
      });
      _toast(summary);
    } catch (e) {
      _toast('Import failed: $e');
    }
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset all data?'),
        content: const Text(
          'Everything goes back to the seeded flavors and '
          'recipes. Export a backup first if you care about your stash.',
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
    if (ok == true) {
      await s.factoryReset();
      _toast('Data reset.');
    }
  }
}
