import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models.dart';
import '../state.dart';

class StepModePage extends StatefulWidget {
  const StepModePage({
    super.key,
    required this.state,
    required this.result,
    required this.label,
    required this.targetNic,
    required this.targetVgPercent,
  });

  final AppState state;
  final MixResult result;
  final String label;
  final double targetNic;
  final double targetVgPercent;

  @override
  State<StepModePage> createState() => _StepModePageState();
}

class _StepModePageState extends State<StepModePage> {
  late StepPlan _plan;
  late List<double?> _actual;
  late bool _tare;
  int _i = 0;
  bool _committed = false;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _plan = StepPlan(widget.result.lines, s.settings.scaleResolution);
    _actual = List<double?>.filled(_plan.length, null);
    _tare = s.settings.tareEachStep;
    WakelockPlus.enable().catchError((Object e) {
      debugPrint('Wakelock unavailable: $e');
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable().catchError((Object e) {
      debugPrint('Wakelock release failed: $e');
    });
    super.dispose();
  }

  bool get _done => _i >= _plan.length;
  double get _res => _plan.resolution;
  bool get _started => _actual.any((a) => a != null) || _i > 0;

  String _g(double v) => v.toStringAsFixed(_res >= 0.1 ? 1 : 2);

  void _advance(double grams) => setState(() {
    _actual[_i] = grams;
    _i++;
  });

  void _jumpTo(int k) => setState(() {
    for (var x = k; x < _plan.length; x++) {
      _actual[x] = null;
    }
    _i = k;
  });

  Future<bool> _confirmExit() async {
    if (_committed || !_started) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abandon this mix?'),
        content: Text(
          'You are on step ${_i + 1} of ${_plan.length}. '
          'Nothing has been logged and inventory has not changed, but '
          'your progress will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep mixing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Abandon'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _enterActual() async {
    final cumulative = !_tare;
    final prior = _plan.priorActual(_i, _actual);
    final suggested = cumulative
        ? _plan.cumulativeTargetAt(_i, _actual)
        : _plan.plannedGrams(_i);
    final c = TextEditingController(text: _g(suggested));

    final v = await showDialog<double>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          final parsed = parseNum(c.text);
          final suspicious =
              cumulative && parsed != null && parsed < prior - _res;
          return AlertDialog(
            title: Text(cumulative ? 'Scale reading' : 'Amount added'),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: c,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => setSheet(() {}),
                    onSubmitted: (t) => Navigator.pop(context, parseNum(t)),
                    decoration: InputDecoration(
                      labelText: cumulative
                          ? 'Total on the scale now (g)'
                          : 'This ingredient only (g)',
                      border: const OutlineInputBorder(),
                      helperText: cumulative
                          ? 'Bottle already holds ${_g(prior)} g. '
                                'Remaining targets shift to match.'
                          : null,
                    ),
                  ),
                  if (suspicious)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'That is less than what is already in the bottle '
                        '(${_g(prior)} g). Did you mean the per-ingredient '
                        'amount? Switch off cumulative mode in the toolbar.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
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
                onPressed: () => Navigator.pop(context, parseNum(c.text)),
                child: const Text('Record'),
              ),
            ],
          );
        },
      ),
    );
    c.dispose();
    if (v == null) return;
    _advance(cumulative ? _plan.readingToGrams(_i, v, _actual) : v);
  }

  Future<void> _commit() async {
    final lines = _plan.actualLines(_actual);
    final adjusted = MixResult(lines, const []);

    // Stock may have changed since the pre-mix check.
    final issues = checkStock(adjusted, s.ingredients);
    if (issues.isNotEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Stock is short'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Logging will deduct what is on hand and floor '
                'these at zero:',
              ),
              const SizedBox(height: 8),
              for (final i in issues)
                Text(
                  '• ${i.name}: short '
                  '${i.shortMl.toStringAsFixed(2)} mL',
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Log anyway'),
            ),
          ],
        ),
      );
      if (go != true) return;
    }

    final log = s.logMix(
      adjusted,
      label: widget.label,
      targetNic: widget.targetNic,
      targetVgPercent: widget.targetVgPercent,
      weighed: true,
    );
    _committed = true;
    if (!mounted) return;
    Navigator.pop(context, log);
  }

  @override
  Widget build(BuildContext context) {
    if (_plan.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Weigh along')),
        body: const Center(child: Text('Nothing to weigh.')),
      );
    }
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmExit() && mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            'Weigh along — ${widget.label}',
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: _tare
                  ? 'Switch to cumulative (no taring)'
                  : 'Switch to tare between ingredients',
              icon: Icon(_tare ? Icons.exposure_zero : Icons.stacked_bar_chart),
              onPressed: () => setState(() => _tare = !_tare),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(value: _i / _plan.length),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final w in _plan.warnings)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.balance,
                      size: 18,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        w,
                        style: TextStyle(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_done) _summary(theme) else _current(theme),
            const SizedBox(height: 16),
            Text('All steps', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            for (var k = 0; k < _plan.length; k++) _stepTile(k, theme),
          ],
        ),
      ),
    );
  }

  Widget _current(ThemeData theme) {
    final line = _plan.lines[_i];
    final target = _plan.plannedGrams(_i);
    final cumulative = _plan.cumulativeTargetAt(_i, _actual);
    final ing = s.byId(line.ingredientId);
    final short = ing != null && line.ml > ing.stockMl + 1e-9;
    final tooSmall = _plan.roundsToZero(_i);
    final imprecise = _plan.lowPrecision(_i);
    final shown = _tare ? target : cumulative;

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Step ${_i + 1} of ${_plan.length}',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Text(line.name, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            Text(
              _tare ? 'Tare, then add' : 'Scale should read',
              style: theme.textTheme.labelLarge,
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${tooSmall ? line.grams.toStringAsFixed(3) : _g(shown)} g',
                maxLines: 1,
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            if (!_tare)
              Text(
                'add ${tooSmall ? line.grams.toStringAsFixed(3) : _g(target)} g of this one',
                style: theme.textTheme.titleMedium,
              ),
            if (tooSmall)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Below your ${_res}g scale resolution — measure by '
                  'syringe (${line.ml.toStringAsFixed(3)} mL) or mix a '
                  'larger batch. Recorded either way.',
                  style: TextStyle(color: theme.colorScheme.tertiary),
                ),
              )
            else if (imprecise)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Small amount — expect >5% error on a ${_res}g scale.',
                  style: TextStyle(color: theme.colorScheme.tertiary),
                ),
              ),
            if (short)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Only ${ing.stockMl.toStringAsFixed(1)} mL in stock — '
                  'needs ${line.ml.toStringAsFixed(2)} mL.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onPressed: () => _advance(target),
              icon: const Icon(Icons.check),
              label: const Text('Done — on target'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _enterActual,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Enter actual'),
                ),
                OutlinedButton.icon(
                  onPressed: _i == 0 ? null : () => _jumpTo(_i - 1),
                  icon: const Icon(Icons.undo),
                  label: const Text('Back'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _summary(ThemeData theme) {
    final adjusted = MixResult(_plan.actualLines(_actual), const []);
    final target = _plan.totalPlannedGrams;
    final drift = adjusted.totalGrams - target;
    final set = s.settings;
    final nicDrift =
        (adjusted.actualNicMgPerMl - widget.targetNic).abs() > 0.05;

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.done_all, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'All ingredients added',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${_g(adjusted.totalGrams)} g',
                maxLines: 1,
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Text(
              'target ${_g(target)} g  •  '
              '${drift >= 0 ? '+' : ''}${drift.toStringAsFixed(2)} g drift',
            ),
            const SizedBox(height: 8),
            Text(
              '${adjusted.totalMl.toStringAsFixed(2)} mL  •  '
              '${money(adjusted.totalCost, set)}',
            ),
            Text(
              'Actual: '
              '${adjusted.actualNicMgPerMl.toStringAsFixed(2)} mg/mL nic  •  '
              '${adjusted.actualVgPercent.toStringAsFixed(1)}% VG',
            ),
            if (nicDrift)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Target was ${widget.targetNic.toStringAsFixed(1)} mg/mL — '
                  'what you weighed lands at '
                  '${adjusted.actualNicMgPerMl.toStringAsFixed(2)}.',
                  style: TextStyle(color: theme.colorScheme.tertiary),
                ),
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onPressed: _commit,
              icon: const Icon(Icons.save_alt),
              label: const Text('Commit — log real weights'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _jumpTo(_plan.length - 1),
              icon: const Icon(Icons.undo),
              label: const Text('Back to last step'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepTile(int k, ThemeData theme) {
    final target = _plan.plannedGrams(k);
    final actual = _actual[k];
    final complete = k < _i;
    final off = actual != null && (actual - target).abs() > _res * 1.5;
    final tooSmall = _plan.roundsToZero(k);
    return ListTile(
      dense: true,
      leading: Icon(
        complete
            ? Icons.check_circle
            : (k == _i
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              _plan.lines[k].name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: k == _i ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          if (tooSmall)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Tooltip(
                message: 'Below scale resolution',
                child: Icon(
                  Icons.balance,
                  size: 15,
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ),
        ],
      ),
      subtitle: complete && off
          ? Text(
              'added ${_g(actual!)} g (target ${_g(target)} g)',
              style: TextStyle(color: theme.colorScheme.error),
            )
          : null,
      trailing: Text(
        '${tooSmall && !complete ? _plan.exactGrams(k).toStringAsFixed(3) : _g(complete ? actual! : target)} g',
        style: theme.textTheme.titleMedium,
      ),
      onTap: complete ? () => _jumpTo(k) : null,
    );
  }
}
