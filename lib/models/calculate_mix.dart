import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/ingredient.dart';
import 'package:mixlab/models/mix.dart';
import 'package:mixlab/models/settings.dart';
import 'package:mixlab/models/units.dart';

/// Weight-first mixing math. Volumes are computed, then converted to grams.
///
/// [flavors] accepts any percentage-based ingredient — flavors, additives
/// and thinners alike. Each line's kind is preserved so the flavor total can
/// exclude the ones that are not flavor.
///
/// In [PercentMode.byWeight], a percentage is a share of the finished mass
/// rather than the batch volume. Because the finished mass depends on the
/// concentrate amounts, which depend on the mass, this is solved by
/// fixed-point iteration. The map is a strong contraction, so it settles in
/// a handful of passes.
///
/// Ingredients selected more than once are coalesced into a single line with
/// their percentages summed, so one bottle is never weighed twice.
MixResult calculateMix({
  required double amountMl,
  required double targetNic,
  required double targetVgPercent,
  required Settings settings,
  PercentMode percentMode = PercentMode.byVolume,
  BaseMode baseMode = BaseMode.ratio,
  Ingredient? nic,
  Ingredient? pg,
  Ingredient? vg,
  List<(Ingredient, double)> flavors = const [],
}) {
  if (amountMl <= 0) {
    return MixResult(const [], const ['Enter a batch size above zero.']);
  }

  // Coalesce repeated selections, preserving first-seen order.
  final merged = <String, (Ingredient, double)>{};
  final order = <String>[];
  var hadDuplicates = false;
  for (final (f, pct) in flavors) {
    if (pct <= 0) continue;
    final prev = merged[f.id];
    if (prev == null) {
      merged[f.id] = (f, pct);
      order.add(f.id);
    } else {
      merged[f.id] = (f, prev.$2 + pct);
      hadDuplicates = true;
    }
  }

  /// Builds the mix given an assumed finished mass, which is only consulted
  /// in by-weight mode.
  MixResult attempt(double assumedGrams) {
    final lines = <MixLine>[];
    final warnings = <String>[];

    final maxVg = baseMode == BaseMode.maxVg;
    // Max VG adds no neat PG, so VG starts as the whole batch and every
    // other ingredient is carved out of it regardless of carrier.
    var vgMl = maxVg
        ? amountMl
        : amountMl * clampd(targetVgPercent, 0, 100) / 100;
    var pgMl = maxVg ? 0.0 : amountMl - vgMl;

    if (targetNic > 0) {
      if (nic == null || nic.nicMgPerMl <= 0) {
        warnings.add(
          'Target nicotine is ${targetNic.toStringAsFixed(1)} mg/mL but no '
          'nicotine base is selected — this mix will be 0 mg.',
        );
      } else if (targetNic >= nic.nicMgPerMl) {
        warnings.add(
          'Target strength must be below the base strength '
          '(${nic.nicMgPerMl.toStringAsFixed(0)} mg/mL).',
        );
      } else {
        // Nicotine is inherently volumetric: mg/mL of the finished volume.
        final ml = amountMl * targetNic / nic.nicMgPerMl;
        final carrier = clampd(nic.carrierVg, 0, 1);
        if (maxVg) {
          vgMl -= ml;
        } else {
          vgMl -= ml * carrier;
          pgMl -= ml * (1 - carrier);
        }
        lines.add(
          MixLine(
            nic.displayName,
            ml,
            ml * nic.density,
            ml * nic.costPerMl,
            nic.id,
            kind: IngredientKind.nicotine,
            vgFraction: carrier,
            density: nic.density,
            costPerMl: nic.costPerMl,
            nicMgPerMl: nic.nicMgPerMl,
          ),
        );
      }
    }

    if (hadDuplicates) {
      warnings.add('Duplicate ingredients were combined into one line each.');
    }

    var totalPct = 0.0;
    for (final id in order) {
      final (f, pct) = merged[id]!;
      totalPct += pct;
      final density = f.density > 0 ? f.density : 1.0;
      final ml = percentMode == PercentMode.byWeight
          ? assumedGrams * pct / 100 / density
          : amountMl * pct / 100;
      final carrier = clampd(f.carrierVg, 0, 1);
      if (maxVg) {
        vgMl -= ml;
      } else {
        vgMl -= ml * carrier;
        pgMl -= ml * (1 - carrier);
      }
      lines.add(
        MixLine(
          f.displayName,
          ml,
          ml * density,
          ml * f.costPerMl,
          f.id,
          kind: f.kind,
          vgFraction: carrier,
          density: density,
          costPerMl: f.costPerMl,
          nicMgPerMl: f.nicMgPerMl,
        ),
      );
    }
    if (totalPct > 100) {
      warnings.add(
        'Listed ingredients total ${totalPct.toStringAsFixed(1)}% — '
        'over 100%.',
      );
    }

    const eps = 1e-12;
    if (maxVg) {
      if (vgMl < -eps) {
        warnings.add(
          'Nicotine and concentrates alone exceed '
          '${amountMl.toStringAsFixed(1)} mL — the finished mix will be '
          'larger than the requested batch.',
        );
      }
      vgMl = clampd(vgMl, 0, double.infinity);
    } else if (pgMl < -eps || vgMl < -eps) {
      // Absorb the overflow from the opposite side to keep total volume
      // equal to the requested batch size.
      if (pgMl < 0) {
        vgMl += pgMl;
        pgMl = 0;
      } else {
        pgMl += vgMl;
        vgMl = 0;
      }
      if (pgMl < -eps || vgMl < -eps) {
        warnings.add(
          'Nicotine and concentrates alone exceed '
          '${amountMl.toStringAsFixed(1)} mL — the finished mix will be '
          'larger than the requested batch.',
        );
      } else {
        warnings.add(
          'Concentrates carry in more PG/VG than the target ratio allows; '
          'the finished ratio will differ from the target.',
        );
      }
      pgMl = clampd(pgMl, 0, double.infinity);
      vgMl = clampd(vgMl, 0, double.infinity);
    }

    final pgD = pg?.density ?? settings.pgDensity;
    final vgD = vg?.density ?? settings.vgDensity;
    lines.add(
      MixLine(
        pg?.displayName ?? 'PG',
        pgMl,
        pgMl * pgD,
        pgMl * (pg?.costPerMl ?? 0),
        pg?.id,
        kind: IngredientKind.pg,
        vgFraction: 0,
        density: pgD,
        costPerMl: pg?.costPerMl ?? 0,
      ),
    );
    lines.add(
      MixLine(
        vg?.displayName ?? 'VG',
        vgMl,
        vgMl * vgD,
        vgMl * (vg?.costPerMl ?? 0),
        vg?.id,
        kind: IngredientKind.vg,
        vgFraction: 1,
        density: vgD,
        costPerMl: vg?.costPerMl ?? 0,
      ),
    );

    return MixResult(lines, warnings);
  }

  if (percentMode == PercentMode.byVolume || order.isEmpty) {
    return attempt(0);
  }

  // Fixed-point solve for the finished mass.
  var mass = amountMl * 1.15; // between PG and VG density, a good seed
  var result = attempt(mass);
  var converged = false;
  for (var i = 0; i < 32; i++) {
    final next = result.totalGrams;
    if ((next - mass).abs() < 1e-9) {
      converged = true;
      break;
    }
    mass = next;
    result = attempt(mass);
  }
  if (!converged && (result.totalGrams - mass).abs() < 1e-6) converged = true;

  return MixResult(result.lines, [
    ...result.warnings,
    if (!converged)
      'By-weight percentages did not settle; treat these amounts as '
          'approximate.',
  ], converged: converged);
}

/// Cost of the physical parts of a batch: bottles plus per-batch
/// consumables. Bottles are counted whole, because mixing 100 mL into
/// 30 mL bottles uses four of them, not 3.33.
double hardwareCostFor(double batchMl, Settings s) {
  if (!s.includeHardware || batchMl <= 0) return 0;
  var cost = s.consumablesCost;
  if (s.emptyBottleMl > 0 && s.emptyBottleCost > 0) {
    cost += (batchMl / s.emptyBottleMl).ceil() * s.emptyBottleCost;
  }
  return cost;
}

/// Largest batch mixable from current stock, given a mix computed at
/// [referenceMl].
///
/// Every ingredient scales linearly with batch volume in both percent
/// modes, so the most-constrained ingredient's stock ratio scales the
/// reference directly. Returns null when nothing tracked limits it —
/// typically because PG and VG are untracked.
double? maxBatchMl(
  MixResult reference,
  double referenceMl,
  Iterable<Ingredient> inventory,
) {
  if (referenceMl <= 0) return null;
  final need = <String, double>{};
  for (final l in reference.lines) {
    final id = l.ingredientId;
    if (id == null || l.ml <= 0) continue;
    need[id] = (need[id] ?? 0) + l.ml;
  }
  if (need.isEmpty) return null;

  double? worst;
  for (final ing in inventory) {
    final n = need[ing.id];
    if (n == null || n <= 0) continue;
    final ratio = ing.stockMl / n;
    if (worst == null || ratio < worst) worst = ratio;
  }
  return worst == null ? null : worst * referenceMl;
}
