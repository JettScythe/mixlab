import 'package:mixlab/models/mix.dart';
import 'package:mixlab/models/units.dart';

/// Ordered plan for weighing a mix, lightest first so small flavor amounts
/// land before the bottle gets heavy.
///
/// Lines are never dropped: an amount that rounds to 0 g on the configured
/// scale is kept at its exact value and flagged via [roundsToZero], because
/// silently omitting it would desync the log and inventory from the recipe.
class StepPlan {
  StepPlan(List<MixLine> lines, double resolution)
    : resolution = resolution <= 0 ? 0.01 : resolution,
      lines = [
        for (final l in lines)
          if (l.grams > 0) l,
      ]..sort((a, b) => a.grams.compareTo(b.grams));

  final List<MixLine> lines;
  final double resolution;

  int get length => lines.length;
  bool get isEmpty => lines.isEmpty;

  double exactGrams(int i) => lines[i].grams;

  /// What to actually add: snapped to scale resolution, but never zero.
  double plannedGrams(int i) {
    final r = roundTo(lines[i].grams, resolution);
    return r > 0 ? r : lines[i].grams;
  }

  /// Amount is smaller than the scale can register at all.
  bool roundsToZero(int i) => roundTo(lines[i].grams, resolution) <= 0;

  /// Amount is small enough that scale error exceeds ~5%.
  bool lowPrecision(int i) =>
      !roundsToZero(i) && lines[i].grams < resolution * 10;

  double get totalPlannedGrams {
    var t = 0.0;
    for (var i = 0; i < length; i++) {
      t += plannedGrams(i);
    }
    return t;
  }

  /// Sum of what was actually added before step [i]; unrecorded steps fall
  /// back to their planned amount.
  double priorActual(int i, List<double?> actual) {
    var t = 0.0;
    for (var k = 0; k < i && k < length; k++) {
      t += actual[k] ?? plannedGrams(k);
    }
    return t;
  }

  /// What the scale should read after completing step [i] without taring.
  double cumulativeTargetAt(int i, List<double?> actual) =>
      priorActual(i, actual) + plannedGrams(i);

  /// Converts a cumulative scale reading at step [i] into this ingredient's
  /// own weight, floored at zero.
  double readingToGrams(int i, double reading, List<double?> actual) {
    final g = reading - priorActual(i, actual);
    return g < 0 ? 0 : g;
  }

  List<MixLine> actualLines(List<double?> actual) => [
    for (var i = 0; i < length; i++)
      lines[i].withGrams(actual[i] ?? plannedGrams(i)),
  ];

  /// Human-readable problems with weighing this mix on this scale.
  List<String> get warnings {
    final tooSmall = <String>[];
    final imprecise = <String>[];
    for (var i = 0; i < length; i++) {
      if (roundsToZero(i)) {
        tooSmall.add(lines[i].name);
      } else if (lowPrecision(i)) {
        imprecise.add(lines[i].name);
      }
    }
    final out = <String>[];
    if (tooSmall.isNotEmpty) {
      out.add(
        'Below your ${resolution}g scale resolution: ${tooSmall.join(', ')}. '
        'Mix a larger batch or use a syringe for these.',
      );
    }
    if (imprecise.isNotEmpty) {
      out.add(
        'Under 10x scale resolution, so >5% error likely: '
        '${imprecise.join(', ')}.',
      );
    }
    return out;
  }
}

/// Scale-feasibility warnings without building a full plan.
List<String> scaleWarnings(MixResult r, double resolution) =>
    StepPlan(r.lines, resolution).warnings;
