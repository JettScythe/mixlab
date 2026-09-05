import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixlab/models/calculate_mix.dart';
import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/ingredient.dart';
import 'package:mixlab/models/ledger.dart';
import 'package:mixlab/models/mix.dart';
import 'package:mixlab/models/recipe.dart';
import 'package:mixlab/models/settings.dart';
import 'package:mixlab/models/step_plan.dart';
import 'package:mixlab/models/units.dart';
import 'package:mixlab/state.dart';
import 'package:mixlab/sync_merge.dart';
import 'package:mixlab/widgets/ingredient_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mixlab/recipe_import.dart';

Ingredient nicBase({double strength = 100, double carrierVg = 0}) => Ingredient(
  id: 'nic',
  name: 'Nic',
  kind: IngredientKind.nicotine,
  density: 1.036,
  nicStrength: strength,
  carrierVg: carrierVg,
  stockMl: 100,
);

Ingredient flavor(String id, {double carrierVg = 0, double stock = 100}) =>
    Ingredient(
      id: id,
      name: id,
      kind: IngredientKind.flavor,
      density: 1.0,
      carrierVg: carrierVg,
      stockMl: stock,
      bottleSizeMl: 30,
      bottleCost: 3, // 0.10 per mL
    );

/// Adds an ingredient to [s] and seeds its stock through the ledger, which
/// since v9 is the only way stock enters. Assigning stockMl directly no
/// longer survives a recompute.
Ingredient addStocked(AppState s, Ingredient e, double stockMl) {
  e.stockMl = 0;
  s.ingredients.add(e);
  if (stockMl != 0) {
    s.addAdjustment(
      ingredientId: e.id,
      deltaMl: stockMl,
      reason: AdjustReason.opening,
      costPerMl: e.bottleSizeMl > 0 ? e.bottleCost / e.bottleSizeMl : 0,
    );
  } else {
    s.recomputeStock();
  }
  return e;
}

/// Waits for an auto-loading AppState without hanging the suite forever.
Future<void> waitReady(AppState s) async {
  for (var i = 0; i < 200 && !s.isReady; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(s.isReady, isTrue, reason: 'AppState never finished loading');
}

void main() {
  group('calculateMix', () {
    test('30 mL, 70/30, 3 mg from a 100 mg PG base', () {
      final r = calculateMix(
        amountMl: 30,
        targetNic: 3,
        targetVgPercent: 70,
        settings: Settings(),
        nic: nicBase(),
      );
      expect(r.lines[0].ml, closeTo(0.9, 1e-9)); // nic base
      expect(r.lines[1].ml, closeTo(8.1, 1e-9)); // PG = 9 - 0.9
      expect(r.lines[2].ml, closeTo(21.0, 1e-9)); // VG
      expect(r.totalMl, closeTo(30, 1e-9));
      expect(r.actualVgPercent, closeTo(70, 1e-9));
      expect(r.warnings, isEmpty);
    });

    test('VG-carrier nic is subtracted from VG, not PG', () {
      final r = calculateMix(
        amountMl: 100,
        targetNic: 6,
        targetVgPercent: 50,
        settings: Settings(),
        nic: nicBase(carrierVg: 1),
      );
      expect(r.lines[0].ml, closeTo(6, 1e-9));
      expect(r.lines[1].ml, closeTo(50, 1e-9)); // PG untouched
      expect(r.lines[2].ml, closeTo(44, 1e-9)); // VG absorbed the 6
      expect(r.actualVgPercent, closeTo(50, 1e-9));
    });

    test('grams follow density', () {
      final r = calculateMix(
        amountMl: 10,
        targetNic: 0,
        targetVgPercent: 100,
        settings: Settings(),
      );
      expect(r.totalGrams, closeTo(10 * 1.261, 1e-9));
    });

    test(
      'over-target flavors clamp PG at zero, hold batch volume, and warn',
      () {
        final r = calculateMix(
          amountMl: 10,
          targetNic: 0,
          targetVgPercent: 95,
          settings: Settings(),
          flavors: [(flavor('a'), 10)],
        );
        final pg = r.lines.firstWhere((l) => l.name == 'PG');
        final vg = r.lines.firstWhere((l) => l.name == 'VG');
        expect(pg.ml, 0);
        expect(vg.ml, closeTo(9.0, 1e-9)); // gave up 0.5 to cover the deficit
        expect(r.totalMl, closeTo(10, 1e-9)); // batch volume preserved
        expect(
          r.actualVgPercent,
          closeTo(90, 1e-9),
        ); // ratio drifted, as it must
        expect(r.warnings, isNotEmpty);
      },
    );

    test('concentrates beyond the batch size overshoot and say so', () {
      final r = calculateMix(
        amountMl: 10,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        flavors: [(flavor('a'), 60), (flavor('b'), 50)], // 11 mL of flavor
      );
      expect(r.lines.firstWhere((l) => l.name == 'PG').ml, 0);
      expect(r.lines.firstWhere((l) => l.name == 'VG').ml, 0);
      expect(r.totalMl, closeTo(11, 1e-9));
      expect(r.warnings.any((w) => w.contains('larger than')), isTrue);
    });

    test('flavor total above 100% warns', () {
      final r = calculateMix(
        amountMl: 10,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        flavors: [(flavor('a'), 60), (flavor('b'), 50)],
      );
      expect(r.warnings.any((w) => w.contains('over 100%')), isTrue);
    });

    test('target nic at or above base strength warns', () {
      final r = calculateMix(
        amountMl: 30,
        targetNic: 100,
        targetVgPercent: 70,
        settings: Settings(),
        nic: nicBase(),
      );
      expect(r.warnings.any((w) => w.contains('below the base')), isTrue);
    });

    test('target nic with no base selected warns loudly', () {
      final r = calculateMix(
        amountMl: 30,
        targetNic: 3,
        targetVgPercent: 70,
        settings: Settings(),
      );
      expect(r.warnings.any((w) => w.contains('0 mg')), isTrue);
      expect(r.actualNicMgPerMl, 0);
    });

    test('zero batch size returns only a warning', () {
      final r = calculateMix(
        amountMl: 0,
        targetNic: 3,
        targetVgPercent: 70,
        settings: Settings(),
      );
      expect(r.lines, isEmpty);
      expect(r.warnings.length, 1);
    });

    test('cost sums per-mL bottle cost', () {
      final f = flavor('a'); // 3 per 30 mL = 0.1/mL
      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        flavors: [(f, 10)],
      );
      expect(r.totalCost, closeTo(1.0, 1e-9)); // 10 mL * 0.1
    });
  });

  group('parseNum', () {
    test('accepts comma decimals, rejects junk and negatives', () {
      expect(parseNum('1,5'), 1.5);
      expect(parseNum(' 2.25 '), 2.25);
      expect(parseNum(''), isNull);
      expect(parseNum('abc'), isNull);
      expect(parseNum('-1'), isNull);
    });
  });

  group('roundTo', () {
    test('snaps to scale resolution', () {
      expect(roundTo(1.234, 0.01), closeTo(1.23, 1e-9));
      expect(roundTo(1.236, 0.01), closeTo(1.24, 1e-9));
      expect(roundTo(1.24, 0.1), closeTo(1.2, 1e-9));
      expect(roundTo(1.24, 0), 1.24); // no-op
    });
  });

  group('checkStock', () {
    test('aggregates duplicates and reports the shortfall', () {
      final f = flavor('a', stock: 1.0);
      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        flavors: [(f, 5), (f, 5)], // 10 mL needed, 1 mL on hand
      );
      final issues = checkStock(r, [f]);
      expect(issues.length, 1);
      expect(issues.single.neededMl, closeTo(10, 1e-9));
      expect(issues.single.shortMl, closeTo(9, 1e-9));
    });

    test('no issues when stock suffices', () {
      final f = flavor('a', stock: 100);
      final r = calculateMix(
        amountMl: 30,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        flavors: [(f, 5)],
      );
      expect(checkStock(r, [f]), isEmpty);
    });
  });

  group('brand handling', () {
    test('splits known shorthands, leaves unknown alone', () {
      expect(splitBrand('TFA Strawberry (Ripe)'), ('TFA', 'Strawberry (Ripe)'));
      expect(splitBrand('cap Vanilla Custard v1'), (
        'CAP',
        'Vanilla Custard v1',
      ));
      expect(splitBrand('Strawberry Ripe'), ('', 'Strawberry Ripe'));
      expect(splitBrand('TFA'), ('', 'TFA')); // brand with no name
      expect(splitBrand('VG'), ('', 'VG'));
    });

    test('displayName and searchKey include the vendor', () {
      final i = Ingredient(
        id: 'x',
        name: 'Sweet Cream',
        brand: 'CAP',
        kind: IngredientKind.flavor,
        density: 1,
      );
      expect(i.displayName, 'CAP Sweet Cream');
      expect(i.searchKey.contains('capella'), isTrue);
    });

    test('search matches brand shorthand, vendor name and tokens', () {
      final items = [
        Ingredient(
          id: 'a',
          name: 'Vanilla Custard v1',
          brand: 'CAP',
          kind: IngredientKind.flavor,
          density: 1,
        ),
        Ingredient(
          id: 'b',
          name: 'Strawberry (Ripe)',
          brand: 'TFA',
          kind: IngredientKind.flavor,
          density: 1,
        ),
      ];
      expect(searchIngredients(items, 'cap custard').single.id, 'a');
      expect(searchIngredients(items, 'capella').single.id, 'a');
      expect(searchIngredients(items, 'ripe').single.id, 'b');
      expect(searchIngredients(items, 'zzz'), isEmpty);
      expect(searchIngredients(items, '').length, 2);
    });
  });

  group('carrier-aware density (bugs 2, 3)', () {
    test('VG nicotine base is not given the PG density', () {
      final s = Settings();
      expect(
        s.densityForCarrier(IngredientKind.nicotine, 0),
        closeTo(1.036, 1e-9),
      );
      expect(
        s.densityForCarrier(IngredientKind.nicotine, 1),
        closeTo(1.261, 1e-9),
      );
      expect(
        s.densityForCarrier(IngredientKind.nicotine, 0.5),
        closeTo(1.1485, 1e-9),
      );
    });
    test('a PG-carried flavor matches PG density', () {
      final s = Settings();
      // Concentrates are mostly carrier, so a PG-based flavor is ~1.036,
      // not 1.0. Anything else made densityForCarrier inconsistent between
      // nicotine and flavor.
      expect(
        s.densityForCarrier(IngredientKind.flavor, 0),
        closeTo(s.pgDensity, 1e-9),
      );
      expect(
        s.densityForCarrier(IngredientKind.flavor, 1),
        closeTo(1.261, 1e-9),
      );
    });

    test('flavor, additive and nicotine agree at the same carrier', () {
      final s = Settings();
      for (final v in [0.0, 0.5, 1.0]) {
        final nic = s.densityForCarrier(IngredientKind.nicotine, v);
        expect(
          s.densityForCarrier(IngredientKind.flavor, v),
          closeTo(nic, 1e-9),
        );
        expect(
          s.densityForCarrier(IngredientKind.additive, v),
          closeTo(nic, 1e-9),
        );
      }
    });

    test('densityLooksWrong flags a VG base left at the PG default', () {
      final s = Settings();
      final bad = Ingredient(
        id: 'n',
        name: 'Nic VG',
        kind: IngredientKind.nicotine,
        density: 1.036,
        carrierVg: 1,
      );
      expect(bad.densityLooksWrong(s), isTrue);
      bad.density = 1.261;
      expect(bad.densityLooksWrong(s), isFalse);
    });

    test('a thinner blends from its own base, not PG', () {
      final s = Settings();
      // Distilled water and PGA sit near 1.0, below PG. Sharing the flavor
      // base would weigh a water-thinned mix ~4% heavy.
      expect(
        s.densityForCarrier(IngredientKind.thinner, 0),
        closeTo(s.thinnerDensity, 1e-9),
      );
      expect(
        s.densityForCarrier(IngredientKind.thinner, 0.5),
        closeTo((1.0 + 1.261) / 2, 1e-9),
      );
      expect(
        s.densityForCarrier(IngredientKind.thinner, 1),
        closeTo(s.vgDensity, 1e-9),
      );
      expect(
        s.densityForCarrier(IngredientKind.thinner, 0),
        lessThan(s.densityForCarrier(IngredientKind.flavor, 0)),
      );
    });

    test('PG and VG ignore the carrier fraction entirely', () {
      final s = Settings();
      // Neat base is its own carrier, so a stray carrierVg on a PG bottle
      // must not drag its density toward VG.
      for (final v in [0.0, 0.5, 1.0]) {
        expect(s.densityForCarrier(IngredientKind.pg, v), closeTo(1.036, 1e-9));
        expect(s.densityForCarrier(IngredientKind.vg, v), closeTo(1.261, 1e-9));
      }
    });

    test('carrier fractions outside 0..1 are clamped, never extrapolated', () {
      final s = Settings();
      // Corrupt or hand-edited data must not produce a density below PG or
      // above VG — that would be a physically impossible weight.
      expect(
        s.densityForCarrier(IngredientKind.flavor, -0.5),
        closeTo(s.densityForCarrier(IngredientKind.flavor, 0), 1e-9),
      );
      expect(
        s.densityForCarrier(IngredientKind.nicotine, 1.5),
        closeTo(s.densityForCarrier(IngredientKind.nicotine, 1), 1e-9),
      );
      expect(
        s.densityForCarrier(IngredientKind.thinner, 99),
        closeTo(s.vgDensity, 1e-9),
      );
    });

    test('a missing density is repaired on load, not left at zero', () {
      // Hand-edited backups and records from builds that never set the
      // field arrive here. Zero is not a measurement.
      final vgFlavor = Ingredient.fromJson({
        'id': 'a',
        'name': 'VG flavor',
        'kind': IngredientKind.flavor.index,
        'density': 0,
        'carrierVg': 1.0,
      });
      expect(vgFlavor.density, closeTo(1.261, 1e-9));

      final missing = Ingredient.fromJson({
        'id': 'b',
        'name': 'No density at all',
        'kind': IngredientKind.nicotine.index,
        'carrierVg': 0.0,
      });
      expect(missing.density, closeTo(1.036, 1e-9));

      // A real stored density is never overwritten.
      final measured = Ingredient.fromJson({
        'id': 'c',
        'name': 'Measured',
        'kind': IngredientKind.flavor.index,
        'density': 0.98,
        'carrierVg': 1.0,
      });
      expect(measured.density, closeTo(0.98, 1e-9));
    });

    test('effectiveDensity never yields a shared constant', () {
      final s = Settings();
      final vgFlavor = Ingredient(
        id: 'a',
        name: 'a',
        kind: IngredientKind.flavor,
        density: 0,
        carrierVg: 1,
      );
      // The old fallback was a flat 1.0 — 26% light on VG-carried stock,
      // and the error compounds through the whole weigh-along.
      expect(vgFlavor.effectiveDensity(s), closeTo(1.261, 1e-9));
      expect(vgFlavor.effectiveDensity(s), isNot(closeTo(1.0, 1e-6)));
    });

    test('a zero-density flavor is weighed by its carrier in a mix', () {
      final broken = Ingredient(
        id: 'a',
        name: 'VG flavor',
        kind: IngredientKind.flavor,
        density: 0,
        carrierVg: 1,
        stockMl: 100,
      );
      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        flavors: [(broken, 10)],
      );
      final line = r.lines.firstWhere((l) => l.ingredientId == 'a');
      expect(line.ml, closeTo(10, 1e-9));
      // 10 mL of VG-carried concentrate is 12.61 g, not 10 g.
      expect(line.grams, closeTo(12.61, 1e-9));
      expect(line.density, closeTo(1.261, 1e-9));
    });

    test('a zero-density nicotine base is weighed by its carrier', () {
      final broken = Ingredient(
        id: 'n',
        name: 'Nic VG',
        kind: IngredientKind.nicotine,
        density: 0,
        nicStrength: 100,
        carrierVg: 1,
      );
      final r = calculateMix(
        amountMl: 100,
        targetNic: 3,
        targetVgPercent: 100,
        settings: Settings(),
        nic: broken,
      );
      final line = r.lines.firstWhere((l) => l.ingredientId == 'n');
      expect(line.ml, closeTo(3, 1e-9));
      expect(line.grams, closeTo(3 * 1.261, 1e-9));
    });

    test('a weighed line with no density still deducts stock', () {
      // withGrams used to map every weight to 0 mL when density was zero,
      // so an overpour logged grams but deducted nothing at all.
      final line = MixLine(
        'Broken',
        10,
        0,
        1.0,
        'a',
        density: 0,
        costPerMl: 0.1,
      );
      final weighed = line.withGrams(12.61);
      expect(weighed.grams, closeTo(12.61, 1e-9));
      expect(weighed.ml, greaterThan(0));
      expect(weighed.cost, greaterThan(0));
    });

    test('withGrams recovers the planned ratio when density is missing', () {
      // grams/ml on the planned line is the best evidence available.
      final line = MixLine('Planned', 10, 12.61, 1.0, 'a', density: 0);
      final weighed = line.withGrams(25.22);
      expect(weighed.ml, closeTo(20, 1e-9));
      expect(weighed.density, closeTo(1.261, 1e-9));
    });

    test('custom densities flow through the carrier blend', () {
      // The blend must read the user's settings, not baked-in constants.
      final s = Settings(pgDensity: 1.0, vgDensity: 1.3, flavorDensity: 1.0);
      expect(
        s.densityForCarrier(IngredientKind.nicotine, 0.5),
        closeTo(1.15, 1e-9),
      );
      expect(
        s.densityForCarrier(IngredientKind.flavor, 0.5),
        closeTo(1.15, 1e-9),
      );
    });
  });

  group('StepPlan', () {
    MixResult basicMix() => calculateMix(
      amountMl: 30,
      targetNic: 3,
      targetVgPercent: 70,
      settings: Settings(),
      nic: nicBase(),
      flavors: [(flavor('a'), 8)],
    );

    test('orders lightest first so VG lands last', () {
      final plan = StepPlan(basicMix().lines, 0.01);
      final grams = [
        for (var i = 0; i < plan.length; i++) plan.plannedGrams(i),
      ];
      final sorted = [...grams]..sort();
      expect(grams, sorted);
      expect(plan.lines.last.name, 'VG'); // heaviest last
      expect(grams.every((g) => g > 0), isTrue);
    });

    test('cumulative targets shift after an overpour', () {
      final plan = StepPlan(basicMix().lines, 0.01);
      final actual = List<double?>.filled(plan.length, null);
      final t0 = plan.plannedGrams(0);
      final expected1 = plan.cumulativeTargetAt(1, actual);

      actual[0] = t0 + 0.05; // overpoured the first ingredient
      expect(
        plan.cumulativeTargetAt(1, actual),
        closeTo(expected1 + 0.05, 1e-9),
      );
    });

    test('readingToGrams converts a cumulative reading', () {
      final plan = StepPlan(basicMix().lines, 0.01);
      final actual = List<double?>.filled(plan.length, null);
      actual[0] = 1.0;
      // Scale reads 3.5 total, 1.0 was already in the bottle.
      expect(plan.readingToGrams(1, 3.5, actual), closeTo(2.5, 1e-9));
      // Never negative.
      expect(plan.readingToGrams(1, 0.5, actual), 0);
    });

    test('actualLines rescale ml and cost from weighed grams', () {
      final f = flavor('a'); // density 1.0, 0.1/mL
      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        flavors: [(f, 10)],
      );
      final plan = StepPlan(r.lines, 0.01);
      final i = plan.lines.indexWhere((l) => l.ingredientId == 'a');
      final actual = List<double?>.filled(plan.length, null);
      actual[i] = 20.0; // weighed 20 g instead of the 10 g target

      final line = plan
          .actualLines(actual)
          .firstWhere((l) => l.ingredientId == 'a');
      expect(line.grams, 20.0);
      expect(line.ml, closeTo(20.0, 1e-9)); // density 1.0
      expect(line.cost, closeTo(2.0, 1e-9)); // 20 mL * 0.1
    });

    test('weighed totals feed logMix and deduct the real amount', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = addStocked(s, flavor('a'), 100);

      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: s.settings,
        flavors: [(f, 10)],
      );
      final plan = StepPlan(r.lines, 0.01);
      final i = plan.lines.indexWhere((l) => l.ingredientId == 'a');
      final actual = List<double?>.filled(plan.length, null);
      actual[i] = 12.0; // overpoured by 2 g

      final log = s.logMix(
        MixResult(plan.actualLines(actual), const []),
        label: 'Weighed',
        weighed: true,
      );
      expect(log.weighed, isTrue);
      expect(f.stockMl, closeTo(88.0, 1e-9)); // 12 mL gone, not 10
    });
  });

  group('StepPlan keeps small steps (bugs 4, 5)', () {
    MixResult tinyFlavorMix() => calculateMix(
      amountMl: 10,
      targetNic: 0,
      targetVgPercent: 50,
      settings: Settings(),
      flavors: [(flavor('tiny'), 0.05)], // 0.005 mL -> 0.005 g
    );

    test('sub-resolution lines survive instead of vanishing', () {
      final r = tinyFlavorMix();
      final plan = StepPlan(r.lines, 0.1);
      expect(plan.lines.any((l) => l.ingredientId == 'tiny'), isTrue);
      final i = plan.lines.indexWhere((l) => l.ingredientId == 'tiny');
      expect(plan.roundsToZero(i), isTrue);
      expect(plan.plannedGrams(i), greaterThan(0)); // never silently zero
    });

    test('warns about sub-resolution amounts', () {
      final plan = StepPlan(tinyFlavorMix().lines, 0.1);
      expect(plan.warnings.any((w) => w.contains('Below your')), isTrue);
    });

    test('scaleWarnings surfaces the same problems from a MixResult', () {
      expect(scaleWarnings(tinyFlavorMix(), 0.1), isNotEmpty);
      expect(scaleWarnings(tinyFlavorMix(), 0.0001), isEmpty);
    });

    test('total mass is preserved through the plan', () {
      final r = tinyFlavorMix();
      final plan = StepPlan(r.lines, 0.01);
      expect(plan.totalPlannedGrams, closeTo(r.totalGrams, 0.02));
    });
  });

  group('achieved nicotine (bug 7)', () {
    test('matches the target when weighed exactly', () {
      final r = calculateMix(
        amountMl: 30,
        targetNic: 3,
        targetVgPercent: 70,
        settings: Settings(),
        nic: nicBase(),
      );
      expect(r.actualNicMgPerMl, closeTo(3.0, 1e-9));
    });

    test('drops when VG is overpoured', () {
      final r = calculateMix(
        amountMl: 100,
        targetNic: 6,
        targetVgPercent: 50,
        settings: Settings(),
        nic: nicBase(),
      );
      final plan = StepPlan(r.lines, 0.01);
      final vgIdx = plan.lines.indexWhere((l) => l.name == 'VG');
      final actual = List<double?>.filled(plan.length, null);
      actual[vgIdx] = plan.plannedGrams(vgIdx) * 2; // way over

      final weighed = MixResult(plan.actualLines(actual), const []);
      expect(weighed.actualNicMgPerMl, lessThan(6.0));
      expect(weighed.actualNicMgPerMl, greaterThan(3.0));
    });

    test('logMix records achieved, not target', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final n = nicBase();
      s.ingredients.add(n);
      final r = calculateMix(
        amountMl: 100,
        targetNic: 6,
        targetVgPercent: 50,
        settings: s.settings,
        nic: n,
      );
      final plan = StepPlan(r.lines, 0.01);
      final vgIdx = plan.lines.indexWhere((l) => l.name == 'VG');
      final actual = List<double?>.filled(plan.length, null);
      actual[vgIdx] = plan.plannedGrams(vgIdx) * 2;

      final log = s.logMix(
        MixResult(plan.actualLines(actual), const []),
        targetNic: 6,
        weighed: true,
      );
      expect(log.targetNic, 6);
      expect(log.actualNic, lessThan(6));
      expect(log.nicDrifted, isTrue);
    });
  });

  group('achieved ratio and flavor after weighing', () {
    /// 100 mL at 50/50 with a 10% flavor, then one line overpoured.
    (StepPlan, List<double?>) weighed(String overpour, double factor) {
      final r = calculateMix(
        amountMl: 100,
        targetNic: 3,
        targetVgPercent: 50,
        settings: Settings(),
        nic: nicBase(),
        flavors: [(flavor('a'), 10)],
      );
      final plan = StepPlan(r.lines, 0.01);
      final i = plan.lines.indexWhere((l) => l.name == overpour);
      final actual = List<double?>.filled(plan.length, null);
      actual[i] = plan.plannedGrams(i) * factor;
      return (plan, actual);
    }

    test('overpouring VG raises the achieved VG percentage', () {
      final planned = calculateMix(
        amountMl: 100,
        targetNic: 3,
        targetVgPercent: 50,
        settings: Settings(),
        nic: nicBase(),
        flavors: [(flavor('a'), 10)],
      );
      expect(planned.actualVgPercent, closeTo(50, 1e-9));

      final (plan, actual) = weighed('VG', 2);
      final result = MixResult(plan.actualLines(actual), const []);
      // Recomputed from real weights, not read back off the plan.
      expect(result.actualVgPercent, greaterThan(60));
      expect(result.actualVgPercent, lessThan(100));
    });

    test('overpouring PG lowers it, symmetrically', () {
      final (plan, actual) = weighed('PG', 2);
      final result = MixResult(plan.actualLines(actual), const []);
      expect(result.actualVgPercent, lessThan(50));
    });

    test('logMix persists the achieved ratio, not the target', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final (plan, actual) = weighed('VG', 2);

      final log = s.logMix(
        MixResult(plan.actualLines(actual), const []),
        targetVgPercent: 50,
        targetNic: 3,
        weighed: true,
      );
      expect(log.targetVgPercent, 50);
      expect(log.actualVgPercent, greaterThan(60));
    });

    test('overpouring a flavor raises both flavor percentages', () {
      final planned = calculateMix(
        amountMl: 100,
        targetNic: 3,
        targetVgPercent: 50,
        settings: Settings(),
        nic: nicBase(),
        flavors: [(flavor('a'), 10)],
      );
      expect(planned.flavorPercentByVolume, closeTo(10, 1e-9));

      final (plan, actual) = weighed('a', 2);
      final result = MixResult(plan.actualLines(actual), const []);
      expect(result.flavorPercentByVolume, greaterThan(17));
      expect(result.flavorPercentByWeight, greaterThan(15));
      // Flavor is lighter than the VG-heavy remainder, so the weight
      // share stays below the volume share.
      expect(
        result.flavorPercentByWeight,
        lessThan(result.flavorPercentByVolume),
      );
    });

    test('underpouring is reflected too, not just overpouring', () {
      final (plan, actual) = weighed('VG', 0.5);
      final result = MixResult(plan.actualLines(actual), const []);
      expect(result.actualVgPercent, lessThan(40));
    });
  });

  group('duplicate handling (bugs 10, 11)', () {
    test('the same flavor twice becomes one line with summed percent', () {
      final f = flavor('a');
      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        flavors: [(f, 3), (f, 2)],
      );
      final hits = r.lines.where((l) => l.ingredientId == 'a').toList();
      expect(hits.length, 1);
      expect(hits.single.ml, closeTo(5.0, 1e-9));
      expect(r.warnings.any((w) => w.contains('Duplicate')), isTrue);
      expect(r.totalMl, closeTo(100, 1e-9));
    });

    test('findDuplicate matches on brand + name, case-insensitively', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.ingredients.add(
        Ingredient(
          id: 'a',
          name: 'Sweet Cream',
          brand: 'CAP',
          kind: IngredientKind.flavor,
          density: 1,
        ),
      );
      expect(s.findDuplicate('cap', ' sweet cream ')?.id, 'a');
      expect(s.findDuplicate('CAP', 'Sweet Cream', exceptId: 'a'), isNull);
      expect(s.findDuplicate('TFA', 'Sweet Cream'), isNull);
    });
  });

  group('load resilience (bug 1)', () {
    late DebugPrintCallback original;
    setUp(() {
      original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {};
    });

    tearDown(() => debugPrint = original);
    test('corrupt JSON reports an error instead of hanging', () async {
      SharedPreferences.setMockInitialValues({
        'schema_version': 3,
        'ingredients_v1': '{{{ not json',
      });
      final s = AppState();
      await waitReady(s); // never stuck on the spinner
      expect(s.loadError, isNotNull);
    });

    test('hardReset recovers to a working seeded state', () async {
      SharedPreferences.setMockInitialValues({'ingredients_v1': 'garbage'});
      final s = AppState();
      await waitReady(s);
      expect(s.loadError, isNotNull);

      await s.hardReset();
      expect(s.loadError, isNull);
      expect(s.ingredients, isNotEmpty);
      expect(s.recipes, isNotEmpty);
    });
  });

  group('event-sourced stock', () {
    AppState seeded() {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.ingredients.add(flavor('a', stock: 0));
      s.addAdjustment(
        ingredientId: 'a',
        deltaMl: 100,
        reason: AdjustReason.opening,
        costPerMl: 0.1,
      );
      return s;
    }

    test('stock is derived from the ledger, not assigned', () {
      final s = seeded();
      expect(s.byId('a')!.stockMl, closeTo(100, 1e-9));

      s.recordPurchase(ingredientId: 'a', volumeMl: 30, cost: 4.50);
      expect(s.byId('a')!.stockMl, closeTo(130, 1e-9));

      s.addAdjustment(
        ingredientId: 'a',
        deltaMl: -5,
        reason: AdjustReason.spill,
      );
      expect(s.byId('a')!.stockMl, closeTo(125, 1e-9));
    });

    test('mixing deducts and undo restores by replay', () {
      final s = seeded();
      final f = s.byId('a')!;
      final log = s.logMix(
        calculateMix(
          amountMl: 100,
          targetNic: 0,
          targetVgPercent: 50,
          settings: s.settings,
          flavors: [(f, 10)],
        ),
      );
      expect(f.stockMl, closeTo(90, 1e-9));

      s.undoMix(log.id);
      expect(f.stockMl, closeTo(100, 1e-9));
      expect(s.mixLog, isEmpty);
    });

    test('two mixes both survive — the old model lost one', () {
      final s = seeded();
      final f = s.byId('a')!;
      MixResult mix() => calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: s.settings,
        flavors: [(f, 10)],
      );
      s.logMix(mix());
      s.logMix(mix());
      expect(f.stockMl, closeTo(80, 1e-9));
    });

    test('stock goes negative rather than flooring at zero', () {
      final s = seeded();
      final f = s.byId('a')!;
      s.logMix(
        calculateMix(
          amountMl: 100,
          targetNic: 0,
          targetVgPercent: 50,
          settings: s.settings,
          flavors: [(f, 150)], // 150 mL of a 100 mL supply
        ),
      );
      expect(f.stockMl, lessThan(0));
      expect(f.stockIsNegative, isTrue);
      expect(s.negativeStock.single.id, 'a');
    });

    test('setStockTo writes the difference', () {
      final s = seeded();
      s.setStockTo('a', 42);
      expect(s.byId('a')!.stockMl, closeTo(42, 1e-9));
      expect(s.adjustments.first.deltaMl, closeTo(-58, 1e-9));
    });

    test('cost basis is the weighted average of the whole ledger', () {
      final s = seeded(); // 100 mL at 0.10
      s.recordPurchase(ingredientId: 'a', volumeMl: 100, cost: 20);
      // (100*0.10 + 100*0.20) / 200 = 0.15
      expect(s.byId('a')!.costPerMl, closeTo(0.15, 1e-9));

      s.recordPurchase(
        ingredientId: 'a',
        volumeMl: 100,
        cost: 20,
        shippingCost: 10,
      );
      // (10 + 20 + 30) / 300 = 0.20
      expect(s.byId('a')!.costPerMl, closeTo(0.20, 1e-9));
    });

    test('undoing a purchase removes its effect on stock and cost', () {
      final s = seeded();
      final p = s.recordPurchase(ingredientId: 'a', volumeMl: 100, cost: 20);
      s.undoPurchase(p.id);
      expect(s.byId('a')!.stockMl, closeTo(100, 1e-9));
      expect(s.byId('a')!.costPerMl, closeTo(0.10, 1e-9));
    });

    test('deleting and restoring an ingredient keeps its stock', () {
      final s = seeded();
      final removed = s.removeIngredient('a')!;
      s.restoreIngredient(removed.$1, removed.$2);
      // Events were never touched, so the balance comes straight back.
      expect(s.byId('a')!.stockMl, closeTo(100, 1e-9));
    });

    test('ledger reports a running balance oldest first', () {
      final s = seeded();
      final f = s.byId('a')!;
      s.recordPurchase(ingredientId: 'a', volumeMl: 50, cost: 5);
      s.logMix(
        calculateMix(
          amountMl: 100,
          targetNic: 0,
          targetVgPercent: 50,
          settings: s.settings,
          flavors: [(f, 10)],
        ),
      );

      final ledger = s.ledgerFor('a');
      expect(ledger.length, 3);
      expect(ledger.first.deltaMl, closeTo(100, 1e-9)); // opening
      expect(ledger.last.balanceAfter, closeTo(f.stockMl, 1e-9));
    });
  });

  group('schema v9 migration', () {
    test('opening balances make derived stock equal the old value', () async {
      SharedPreferences.setMockInitialValues({
        'schema_version': 8,
        'ingredients_v1': jsonEncode([
          {
            'id': 'a',
            'name': 'Strawberry',
            'brand': 'TFA',
            'kind': IngredientKind.flavor.index,
            'density': 1.0,
            'stockMl': 22.5,
            'bottleSizeMl': 30,
            'bottleCost': 3,
          },
        ]),
        'purchases_v1': jsonEncode([
          {
            'id': 'p1',
            'ingredientId': 'a',
            'ingredientName': 'TFA Strawberry',
            'at': '2026-01-01T00:00:00.000',
            'volumeMl': 30,
            'cost': 3,
          },
        ]),
        'mixlog_v1': jsonEncode([
          {
            'id': 'l1',
            'mixedAt': '2026-01-02T00:00:00.000',
            'label': 'Test',
            'lines': [
              {
                'name': 'TFA Strawberry',
                'ingredientId': 'a',
                'requestedMl': 7.5,
                'deductedMl': 7.5,
              },
            ],
          },
        ]),
      });

      final s = AppState();
      await waitReady(s);

      // Replay gives 30 - 7.5 = 22.5, which already matches, so no opening
      // balance is needed and stock is unchanged.
      expect(s.byId('a')!.stockMl, closeTo(22.5, 1e-9));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('schema_version'), AppState.currentSchema);
    });

    test('unexplained stock becomes an opening balance', () async {
      SharedPreferences.setMockInitialValues({
        'schema_version': 8,
        'ingredients_v1': jsonEncode([
          {
            'id': 'v',
            'name': 'VG',
            'kind': IngredientKind.vg.index,
            'density': 1.261,
            'stockMl': 500,
            'bottleSizeMl': 500,
            'bottleCost': 14,
          },
        ]),
      });

      final s = AppState();
      await waitReady(s);

      expect(s.byId('v')!.stockMl, closeTo(500, 1e-9));
      expect(s.adjustments.single.reason, AdjustReason.opening);
      expect(s.adjustments.single.deltaMl, closeTo(500, 1e-9));
      // Cost basis carries across rather than resetting to zero.
      expect(s.byId('v')!.costPerMl, closeTo(0.028, 1e-3));
    });

    test('a fresh install seeds stock through the ledger', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState();
      await waitReady(s);

      expect(s.adjustments, isNotEmpty);
      expect(
        s.adjustments.every((a) => a.reason == AdjustReason.opening),
        isTrue,
      );
      final vg = s.ingredients.firstWhere((e) => e.name == 'VG');
      expect(vg.stockMl, closeTo(500, 1e-9));
    });
  });

  group('ingredient deletion (bug 6)', () {
    test('reports recipe usage and supports exact undo', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = flavor('a');
      s.ingredients.addAll([flavor('x'), f, flavor('z')]);
      s.recipes.add(
        Recipe(
          id: 'r',
          name: 'R',
          flavors: [RecipeFlavor(ingredientId: 'a', name: 'a', percent: 5)],
        ),
      );

      expect(s.recipesUsing('a').length, 1);
      final removed = s.removeIngredient('a')!;
      expect(removed.$2, 1); // original index
      expect(s.byId('a'), isNull);

      s.restoreIngredient(removed.$1, removed.$2);
      expect(s.ingredients[1].id, 'a');
    });
  });

  group('serialized writes (bug 8)', () {
    test('rapid mutations all land', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      for (var i = 0; i < 20; i++) {
        s.upsertIngredient(flavor('f$i'));
      }
      await s.flush();
      expect(s.lastSaveError, isNull);

      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString('ingredients_v1')!) as List;
      expect(stored.length, 20);
    });
  });

  group('corrupt enum indices degrade instead of throwing', () {
    test('an out-of-range index falls back to the default', () {
      // A RangeError here would abort the whole load, where every other
      // field in these models tolerates rubbish.
      final r = Recipe.fromJson({
        'id': 'r',
        'name': 'R',
        'percentMode': 99,
        'baseMode': -3,
      });
      expect(r.percentMode, PercentMode.byVolume);
      expect(r.baseMode, BaseMode.ratio);

      final s = Settings.fromJson({'defaultPercentMode': 42, 'costBasis': -1});
      expect(s.defaultPercentMode, PercentMode.byVolume);
      expect(s.costBasis, CostBasis.movingAverage);

      final i = Ingredient.fromJson({
        'id': 'i',
        'name': 'I',
        'kind': 3,
        'density': 1.0,
        'nicUnit': 7,
      });
      expect(i.nicUnit, NicUnit.perMl);

      final a = StockAdjustment.fromJson({
        'id': 'a',
        'ingredientId': 'x',
        'reason': 99,
      });
      expect(a.reason, AdjustReason.correction);

      final t = Tombstone.fromJson({'recordId': 'x', 'type': 99});
      expect(t.type, RecordType.ingredient);
    });

    test('a whole backup of corrupt indices still restores', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      await s.restoreFromBackup(
        jsonEncode({
          'app': 'mixlab',
          'schema': AppState.currentSchema,
          'ingredients': [
            {
              'id': 'a',
              'name': 'Odd',
              'kind': 99,
              'density': 1.0,
              'nicUnit': 99,
            },
          ],
          'recipes': [
            {'id': 'r', 'name': 'Odd', 'percentMode': 99, 'baseMode': 99},
          ],
        }),
      );
      expect(s.byId('a')!.kind, IngredientKind.flavor);
      expect(s.recipes.single.percentMode, PercentMode.byVolume);
    });
  });

  group('ledger writes reject a stale ingredient id', () {
    AppState empty() {
      SharedPreferences.setMockInitialValues({});
      return AppState(autoLoad: false);
    }

    test('recordPurchase explains itself instead of crashing', () {
      expect(
        () =>
            empty().recordPurchase(ingredientId: 'gone', volumeMl: 10, cost: 1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('addAdjustment and setStockTo do the same', () {
      expect(
        () => empty().addAdjustment(ingredientId: 'gone', deltaMl: 5),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => empty().setStockTo('gone', 5),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('nothing is written when the id is unknown', () {
      final s = empty();
      try {
        s.addAdjustment(ingredientId: 'gone', deltaMl: 5);
      } on ArgumentError {
        // expected
      }
      expect(s.adjustments, isEmpty);
      expect(s.purchases, isEmpty);
    });
  });

  group('serialization', () {
    test('recipe round-trip', () {
      final r = Recipe(
        id: 'x',
        name: 'Test',
        notes: 'n',
        batchMl: 60,
        targetNic: 6,
        targetVgPercent: 50,
        flavors: [RecipeFlavor(ingredientId: 'a', name: 'A', percent: 5)],
      );
      final back = Recipe.fromJson(
        jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
      );
      expect(back.name, 'Test');
      expect(back.targetVgPercent, 50);
      expect(back.flavors.single.percent, 5);
      expect(back.totalFlavorPercent, 5);
    });

    test('restore replaces everything with the backup', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppState(autoLoad: false);
      a.ingredients.add(flavor('a'));
      a.recipes.add(Recipe(id: 'r', name: 'R'));
      final dump = a.exportJson();

      final b = AppState(autoLoad: false);
      b.ingredients.add(flavor('local-only'));
      b.recipes.add(Recipe(id: 'local-r', name: 'Local'));

      await b.restoreFromBackup(dump);
      // Local records are gone, not merged — that is the point of restore.
      expect(b.ingredients.length, 1);
      expect(b.ingredients.single.id, 'a');
      expect(b.recipes.single.id, 'r');

      await b.restoreFromBackup(dump); // idempotent
      expect(b.ingredients.length, 1);
      expect(b.recipes.length, 1);
    });

    test('rejects a newer schema', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      expect(
        () => s.restoreFromBackup('{"app": "mixlab", "schema": 999}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a file that is not a MixLab backup', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.ingredients.add(flavor('keep'));
      s.recipes.add(Recipe(id: 'keep-r', name: 'Keep'));

      // Valid JSON, no marker — before, this wiped everything and
      // reported "Restored 0 ingredients" as a success.
      await expectLater(
        s.restoreFromBackup('{"ingredients": [], "recipes": []}'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        s.restoreFromBackup('{"app": "something-else", "ingredients": []}'),
        throwsA(isA<FormatException>()),
      );

      expect(s.ingredients.single.id, 'keep');
      expect(s.recipes.single.id, 'keep-r');
    });

    test('a corrupt record leaves existing data untouched', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.ingredients.add(flavor('keep'));
      s.recipes.add(Recipe(id: 'keep-r', name: 'Keep'));
      s.settings.currency = 'GBP';

      // Second ingredient has no name, so Ingredient.fromJson throws
      // partway through. The restore must be all-or-nothing.
      await expectLater(
        s.restoreFromBackup(
          jsonEncode({
            'app': 'mixlab',
            'schema': AppState.currentSchema,
            'settings': Settings(currency: 'EUR').toJson(),
            'ingredients': [
              {'id': 'good', 'name': 'OK', 'kind': 3, 'density': 1.0},
              {'id': 'bad', 'kind': 3, 'density': 1.0},
            ],
            'recipes': [
              {'id': 'incoming-r', 'name': 'Incoming'},
            ],
          }),
        ),
        throwsA(anything),
      );

      expect(s.ingredients.single.id, 'keep');
      expect(s.recipes.single.id, 'keep-r');
      expect(s.settings.currency, 'GBP');
    });
  });

  group('schema migration', () {
    test('v1 data gets brand back-filled from the name', () async {
      SharedPreferences.setMockInitialValues({
        'ingredients_v1': jsonEncode([
          {
            'id': 'a',
            'name': 'TFA Strawberry (Ripe)',
            'kind': 3, // IngredientKind.flavor
            'density': 1.0,
          },
          {
            'id': 'b',
            'name': 'VG',
            'kind': 1, // IngredientKind.vg
            'density': 1.261,
          },
        ]),
        'recipes_v1': jsonEncode(<Object>[]),
      });

      final s = AppState();
      await waitReady(s);

      final a = s.byId('a')!;
      expect(a.brand, 'TFA');
      expect(a.name, 'Strawberry (Ripe)');
      expect(a.displayName, 'TFA Strawberry (Ripe)');
      expect(s.byId('b')!.brand, ''); // untouched
      expect(s.brands, ['TFA']);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('schema_version'), AppState.currentSchema);
    });

    test('importing a v1 backup splits brands too', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      await s.restoreFromBackup(
        jsonEncode({
          'app': 'mixlab',
          'schema': 1,
          'ingredients': [
            {'id': 'z', 'name': 'CAP Sweet Cream', 'kind': 3, 'density': 1.0},
          ],
        }),
      );
      expect(s.byId('z')!.brand, 'CAP');
      expect(s.byId('z')!.name, 'Sweet Cream');
    });

    /// The full ladder, on one store. Each migration is covered in
    /// isolation elsewhere; this proves they compose — v2 rewrites the
    /// ingredient blob that v9 later re-reads, and v4 links logs that v9
    /// then replays for stock.
    test('a v1 store migrates all the way to current in one load', () async {
      // No schema_version key at all, which is how a real v1 install reads.
      SharedPreferences.setMockInitialValues({
        'ingredients_v1': jsonEncode([
          {
            'id': 'a',
            'name': 'TFA Strawberry (Ripe)', // v2 splits this
            'kind': IngredientKind.flavor.index,
            'density': 1.0,
            'stockMl': 22.5, // v9 reconciles this
            'bottleSizeMl': 30,
            'bottleCost': 3,
          },
          {
            'id': 'v',
            'name': 'VG',
            'kind': IngredientKind.vg.index,
            'density': 1.261,
            'stockMl': 480,
            'bottleSizeMl': 500,
            'bottleCost': 14,
          },
        ]),
        'recipes_v1': jsonEncode([
          {'id': 'r1', 'name': 'Mustard Milk', 'flavors': <Object>[]},
        ]),
        'mixlog_v1': jsonEncode([
          {
            'id': 'l1',
            'mixedAt': '2026-01-02T00:00:00.000',
            'label': 'mustard milk', // v4 links this by label
            'batchMl': 30,
            'lines': [
              {
                'name': 'TFA Strawberry (Ripe)',
                'ingredientId': 'a',
                'requestedMl': 7.5,
                'deductedMl': 7.5,
              },
              {
                'name': 'VG',
                'ingredientId': 'v',
                'requestedMl': 20,
                'deductedMl': 20,
              },
            ],
          },
        ]),
        'purchases_v1': jsonEncode([
          {
            'id': 'p1',
            'ingredientId': 'a',
            'ingredientName': 'TFA Strawberry (Ripe)',
            'at': '2026-01-01T00:00:00.000',
            'volumeMl': 30,
            'cost': 3,
          },
        ]),
      });

      final s = AppState();
      await waitReady(s);
      expect(s.loadError, isNull);

      // v2: brand pulled off the front of the name.
      expect(s.byId('a')!.brand, 'TFA');
      expect(s.byId('a')!.name, 'Strawberry (Ripe)');

      // v4: the log found its recipe despite the case difference.
      expect(s.mixLog.single.recipeId, 'r1');

      // v9: stock comes out exactly where the user left it. 'a' needs no
      // opening balance (30 bought - 7.5 mixed = 22.5 already), 'v' needs
      // one for the whole 500 it never had a purchase for.
      expect(s.byId('a')!.stockMl, closeTo(22.5, 1e-9));
      expect(s.byId('v')!.stockMl, closeTo(480, 1e-9));
      expect(
        s.adjustments.where((x) => x.reason == AdjustReason.opening).length,
        1,
      );
      expect(s.byId('v')!.costPerMl, closeTo(0.028, 1e-3));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('schema_version'), AppState.currentSchema);
    });

    test('an interrupted v9 does not double stock on the next load', () async {
      // The v9 block writes adjustments, then stamps the schema. A crash
      // between the two leaves this: opening balances present, version
      // still 8. Re-running must be a no-op, not a second balance.
      SharedPreferences.setMockInitialValues({
        'schema_version': 8,
        'ingredients_v1': jsonEncode([
          {
            'id': 'v',
            'name': 'VG',
            'kind': IngredientKind.vg.index,
            'density': 1.261,
            'stockMl': 500,
            'bottleSizeMl': 500,
            'bottleCost': 14,
          },
        ]),
        'adjustments_v1': jsonEncode([
          {
            'id': 'opening-v',
            'ingredientId': 'v',
            'ingredientName': 'VG',
            'at': '2026-01-01T00:00:00.000',
            'deltaMl': 500,
            'reason': AdjustReason.opening.index,
            'costPerMl': 0.028,
            'note': 'Opening balance, recorded when stock became a ledger.',
          },
        ]),
      });

      final s = AppState();
      await waitReady(s);

      expect(s.adjustments.length, 1);
      expect(s.byId('v')!.stockMl, closeTo(500, 1e-9));
    });
  });

  group('recipe editing', () {
    Recipe sample({String id = 'r1', String name = 'Sample'}) => Recipe(
      id: id,
      name: name,
      notes: 'note',
      batchMl: 30,
      targetNic: 3,
      targetVgPercent: 70,
      flavors: [RecipeFlavor(ingredientId: 'a', name: 'a', percent: 5)],
    );

    test('updateRecipe replaces in place, keeping position', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.recipes.addAll([
        sample(id: 'r0', name: 'First'),
        sample(id: 'r1', name: 'Second'),
        sample(id: 'r2', name: 'Third'),
      ]);

      s.updateRecipe(
        Recipe(id: 'r1', name: 'Renamed', batchMl: 60, targetNic: 6),
      );

      expect(s.recipes.length, 3);
      expect(s.recipes[1].id, 'r1'); // position preserved
      expect(s.recipes[1].name, 'Renamed');
      expect(s.recipes[1].batchMl, 60);
      expect(s.recipes[0].name, 'First'); // neighbours untouched
      expect(s.recipes[2].name, 'Third');
    });

    test('updateRecipe appends when the id is unknown', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.updateRecipe(sample(id: 'ghost'));
      expect(s.recipes.single.id, 'ghost');
    });

    test('duplicateRecipe deep-copies and inserts after the original', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.recipes.addAll([sample(id: 'r0'), sample(id: 'r1', name: 'Tail')]);

      final copy = s.duplicateRecipe('r0')!;
      expect(s.recipes.length, 3);
      expect(s.recipes[1].id, copy.id);
      expect(copy.id, isNot('r0'));
      expect(copy.name, 'Sample (copy)');
      expect(s.recipes[2].name, 'Tail'); // inserted, not appended

      // Flavor lists must not be shared between original and copy.
      expect(identical(copy.flavors, s.recipes[0].flavors), isFalse);
      expect(copy.flavors.single.percent, 5);
    });

    test('duplicateRecipe returns null for a missing id', () {
      SharedPreferences.setMockInitialValues({});
      expect(AppState(autoLoad: false).duplicateRecipe('nope'), isNull);
    });

    test('removeRecipe reports its index and restore puts it back', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.recipes.addAll([sample(id: 'r0'), sample(id: 'r1'), sample(id: 'r2')]);

      final removed = s.removeRecipe('r1')!;
      expect(removed.$2, 1);
      expect(s.recipes.map((e) => e.id), ['r0', 'r2']);

      s.restoreRecipe(removed.$1, removed.$2);
      expect(s.recipes.map((e) => e.id), ['r0', 'r1', 'r2']);
    });

    test('recipeById and recipeByName look up correctly', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.recipes.add(sample(id: 'r1', name: 'Mustard Milk'));

      expect(s.recipeById('r1')?.name, 'Mustard Milk');
      expect(s.recipeById('nope'), isNull);
      expect(s.recipeById(null), isNull);
      expect(s.recipeByName('  mustard milk ')?.id, 'r1');
      expect(s.recipeByName('Mustard Milk', exceptId: 'r1'), isNull);
      expect(s.recipeByName(''), isNull);
    });

    test('an edited recipe survives a JSON round-trip', () {
      final edited = Recipe(
        id: 'r1',
        name: 'Edited',
        notes: 'reworked',
        batchMl: 120,
        targetNic: 1.5,
        targetVgPercent: 80,
        flavors: [
          RecipeFlavor(ingredientId: 'a', name: 'TFA A', percent: 2.5),
          RecipeFlavor(ingredientId: 'b', name: 'CAP B', percent: 1),
        ],
      );
      final back = Recipe.fromJson(
        jsonDecode(jsonEncode(edited.toJson())) as Map<String, dynamic>,
      );
      expect(back.name, 'Edited');
      expect(back.batchMl, 120);
      expect(back.targetNic, 1.5);
      expect(back.flavors.length, 2);
      expect(back.totalFlavorPercent, 3.5);
      // Flavor order is meaningful now that rows are reorderable.
      expect(back.flavors.first.name, 'TFA A');
    });
  });

  group('ratings and tasting notes', () {
    MixResult simpleMix(AppState s, Ingredient f) => calculateMix(
      amountMl: 100,
      targetNic: 0,
      targetVgPercent: 50,
      settings: s.settings,
      flavors: [(f, 5)],
    );

    test('a new log starts unrated', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = flavor('a');
      s.ingredients.add(f);
      final log = s.logMix(simpleMix(s, f));
      expect(log.rating, isNull);
      expect(log.tastingNotes, '');
      expect(log.hasFeedback, isFalse);
      expect(log.ratedAt, isNull);
      expect(log.steepDaysAtRating, isNull);
    });

    test('rateMix sets rating, notes and a timestamp', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = flavor('a');
      s.ingredients.add(f);
      final log = s.logMix(simpleMix(s, f));

      expect(s.rateMix(log.id, rating: 4, notes: 'needs a week'), isTrue);
      final updated = s.mixLog.single;
      expect(updated.id, log.id); // same entry, replaced in place
      expect(updated.rating, 4);
      expect(updated.tastingNotes, 'needs a week');
      expect(updated.hasFeedback, isTrue);
      expect(updated.ratedAt, isNotNull);
      expect(updated.steepDaysAtRating, 0);
      expect(s.ratedMixCount, 1);
    });

    test('clearRating removes the rating but keeps the notes', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = flavor('a');
      s.ingredients.add(f);
      final log = s.logMix(simpleMix(s, f));
      s.rateMix(log.id, rating: 5, notes: 'great');

      s.rateMix(log.id, clearRating: true);
      expect(s.mixLog.single.rating, isNull);
      expect(s.mixLog.single.tastingNotes, 'great');
      expect(s.ratedMixCount, 0);
    });

    test('rateMix returns false for an unknown id', () {
      SharedPreferences.setMockInitialValues({});
      expect(AppState(autoLoad: false).rateMix('nope', rating: 3), isFalse);
    });

    test('rating and notes survive a JSON round-trip', () {
      final l = MixLog(
        id: 'l1',
        mixedAt: DateTime(2026, 1, 1),
        label: 'Test',
        recipeId: 'r1',
        batchMl: 30,
        targetNic: 3,
        targetVgPercent: 70,
        totalGrams: 33.5,
        totalCost: 1.25,
        lines: const [],
        rating: 4,
        tastingNotes: 'peppery',
        ratedAt: DateTime(2026, 1, 15),
      );
      final back = MixLog.fromJson(
        jsonDecode(jsonEncode(l.toJson())) as Map<String, dynamic>,
      );
      expect(back.rating, 4);
      expect(back.tastingNotes, 'peppery');
      expect(back.recipeId, 'r1');
      expect(back.steepDaysAtRating, 14);
    });
  });

  group('recipe linkage', () {
    test('logMix stores the recipe id and stats aggregate', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = flavor('a', stock: 1000);
      s.ingredients.add(f);
      s.recipes.add(Recipe(id: 'r1', name: 'Mustard Milk'));

      MixResult mix() => calculateMix(
        amountMl: 30,
        targetNic: 0,
        targetVgPercent: 70,
        settings: s.settings,
        flavors: [(f, 8)],
      );

      final a = s.logMix(mix(), label: 'Mustard Milk', recipeId: 'r1');
      final b = s.logMix(mix(), label: 'Mustard Milk', recipeId: 'r1');
      s.logMix(mix(), label: 'Something else');

      expect(a.recipeId, 'r1');
      expect(s.mixCountForRecipe('r1'), 2);
      expect(s.mixesForRecipe('r1').map((l) => l.id), [b.id, a.id]);
      expect(s.lastMixedForRecipe('r1'), isNotNull);
      expect(s.lastMixedForRecipe('nope'), isNull);

      expect(s.averageRatingForRecipe('r1'), isNull); // none rated yet
      s.rateMix(a.id, rating: 5);
      s.rateMix(b.id, rating: 3);
      expect(s.averageRatingForRecipe('r1'), 4.0);
    });
  });

  group('remix', () {
    test('reconstructs flavor percentages from what was mixed', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f1 = flavor('a', stock: 1000);
      final f2 = flavor('b', stock: 1000);
      s.ingredients.addAll([f1, f2]);

      final r = calculateMix(
        amountMl: 30,
        targetNic: 0,
        targetVgPercent: 70,
        settings: s.settings,
        flavors: [(f1, 8), (f2, 6)],
      );
      final log = s.logMix(r, label: 'Mustard Milk', targetVgPercent: 70);

      final remix = s.recipeFromLog(log);
      expect(remix.name, 'Mustard Milk');
      expect(remix.batchMl, closeTo(30, 1e-9));
      expect(remix.targetVgPercent, 70);
      expect(remix.flavors.length, 2); // base lines excluded
      expect(remix.flavors[0].percent, closeTo(8, 1e-9));
      expect(remix.flavors[1].percent, closeTo(6, 1e-9));
      expect(remix.id.startsWith('remix:'), isTrue);
    });

    test('round-trips through calculateMix to the same volumes', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = flavor('a', stock: 1000);
      final n = nicBase();
      s.ingredients.addAll([f, n]);

      final original = calculateMix(
        amountMl: 60,
        targetNic: 3,
        targetVgPercent: 70,
        settings: s.settings,
        nic: n,
        flavors: [(f, 7.5)],
      );
      final log = s.logMix(
        original,
        label: 'X',
        targetNic: 3,
        targetVgPercent: 70,
      );

      final remix = s.recipeFromLog(log);
      final rebuilt = calculateMix(
        amountMl: remix.batchMl,
        targetNic: remix.targetNic,
        targetVgPercent: remix.targetVgPercent,
        settings: s.settings,
        nic: n,
        flavors: [
          for (final rf in remix.flavors)
            (s.byId(rf.ingredientId)!, rf.percent),
        ],
      );
      expect(rebuilt.totalMl, closeTo(original.totalMl, 1e-6));
      expect(rebuilt.totalGrams, closeTo(original.totalGrams, 1e-6));
      final origFlavor = original.lines.firstWhere(
        (l) => l.ingredientId == 'a',
      );
      final newFlavor = rebuilt.lines.firstWhere((l) => l.ingredientId == 'a');
      expect(newFlavor.ml, closeTo(origFlavor.ml, 1e-6));
    });

    test('deleted ingredients are dropped from the reconstruction', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = flavor('a', stock: 1000);
      s.ingredients.add(f);
      final log = s.logMix(
        calculateMix(
          amountMl: 30,
          targetNic: 0,
          targetVgPercent: 70,
          settings: s.settings,
          flavors: [(f, 8)],
        ),
      );

      s.removeIngredient('a');
      expect(s.recipeFromLog(log).flavors, isEmpty);
    });

    test('roundPercent tidies division artifacts', () {
      expect(roundPercent(7.999999999), 8.0);
      expect(roundPercent(0.3333333), 0.33);
      expect(roundPercent(12.5), 12.5);
    });
  });

  group('schema v4 migration', () {
    test('links old log entries to recipes by label', () async {
      SharedPreferences.setMockInitialValues({
        'schema_version': 3,
        'ingredients_v1': jsonEncode(<Object>[]),
        'recipes_v1': jsonEncode([
          {'id': 'r1', 'name': 'Mustard Milk', 'flavors': <Object>[]},
        ]),
        'mixlog_v1': jsonEncode([
          {
            'id': 'l1',
            'mixedAt': '2026-01-01T00:00:00.000',
            'label': 'mustard milk', // different case on purpose
            'lines': <Object>[],
          },
          {
            'id': 'l2',
            'mixedAt': '2026-01-02T00:00:00.000',
            'label': 'One-off experiment',
            'lines': <Object>[],
          },
        ]),
      });

      final s = AppState();
      await waitReady(s);

      expect(s.loadError, isNull);
      final linked = s.mixLog.firstWhere((l) => l.id == 'l1');
      final unlinked = s.mixLog.firstWhere((l) => l.id == 'l2');
      expect(linked.recipeId, 'r1');
      expect(unlinked.recipeId, isNull);
      expect(s.mixCountForRecipe('r1'), 1);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('schema_version'), AppState.currentSchema);
    });

    test('a pre-ledger backup gets opening balances', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      await s.restoreFromBackup(
        jsonEncode({
          'app': 'mixlab',
          'schema': 8,
          'ingredients': [
            {
              'id': 'v',
              'name': 'VG',
              'kind': IngredientKind.vg.index,
              'density': 1.261,
              'stockMl': 500,
              'bottleSizeMl': 500,
              'bottleCost': 14,
            },
          ],
        }),
      );
      // Stock lived on the ingredient before v9; without synthesised
      // opening balances the ledger would replay to zero.
      expect(s.byId('v')!.stockMl, closeTo(500, 1e-9));
      expect(s.adjustments.single.reason, AdjustReason.opening);
    });

    test('data from a newer build is refused, not down-stamped', () async {
      final future = AppState.currentSchema + 1;
      SharedPreferences.setMockInitialValues({
        'schema_version': future,
        'ingredients_v1': jsonEncode([
          {
            'id': 'a',
            'name': 'Strawberry',
            'brand': 'TFA',
            'kind': 3,
            'density': 1.0,
            'somethingNewerBuildsKnow': 42,
          },
        ]),
      });

      final s = AppState();
      await waitReady(s);

      // The recovery screen, not a silent partial load.
      expect(s.loadError, isNotNull);
      expect(s.loadError, contains('v$future'));

      // And the store still says v$future, so the newer build's
      // migrations can still run against it.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('schema_version'), future);
    });
  });
  group('recipe detail aggregates', () {
    test('spend and volume sum only that recipe\'s mixes', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = addStocked(s, flavor('a'), 1000); // 0.10/mL via the ledger
      s.recipes.add(Recipe(id: 'r1', name: 'Target'));

      MixResult mix(double ml) => calculateMix(
        amountMl: ml,
        targetNic: 0,
        targetVgPercent: 70,
        settings: s.settings,
        flavors: [(f, 10)],
      );

      s.logMix(mix(30), label: 'Target', recipeId: 'r1');
      s.logMix(mix(60), label: 'Target', recipeId: 'r1');
      s.logMix(mix(100), label: 'Other'); // unlinked

      final mine = s.mixesForRecipe('r1');
      expect(mine.length, 2);
      final volume = mine.fold(0.0, (a, l) => a + l.batchMl);
      final spend = mine.fold(0.0, (a, l) => a + l.totalCost);
      expect(volume, closeTo(90, 1e-9));
      // 10% flavor at 0.10/mL = 0.01/mL of finished juice.
      expect(spend, closeTo(0.9, 1e-9));
    });

    test('average rating ignores unrated mixes of the same recipe', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = flavor('a', stock: 1000);
      s.ingredients.add(f);
      s.recipes.add(Recipe(id: 'r1', name: 'R'));

      MixResult mix() => calculateMix(
        amountMl: 30,
        targetNic: 0,
        targetVgPercent: 70,
        settings: s.settings,
        flavors: [(f, 5)],
      );

      final a = s.logMix(mix(), recipeId: 'r1');
      final b = s.logMix(mix(), recipeId: 'r1');
      s.logMix(mix(), recipeId: 'r1'); // never rated

      s.rateMix(a.id, rating: 5);
      s.rateMix(b.id, rating: 2);
      expect(s.averageRatingForRecipe('r1'), 3.5);
      expect(s.mixCountForRecipe('r1'), 3);
    });
  });
  group('max VG', () {
    test('adds no neat PG and fills with VG', () {
      final f = flavor('a');
      final r = calculateMix(
        amountMl: 30,
        targetNic: 3,
        targetVgPercent: 70, // ignored
        settings: Settings(),
        baseMode: BaseMode.maxVg,
        nic: nicBase(), // PG-carried, 0.9 mL
        flavors: [(f, 10)], // 3 mL
      );
      expect(r.lines.firstWhere((l) => l.name == 'PG').ml, 0);
      expect(
        r.lines.firstWhere((l) => l.name == 'VG').ml,
        closeTo(30 - 0.9 - 3, 1e-9),
      );
      expect(r.totalMl, closeTo(30, 1e-9));
      expect(r.warnings, isEmpty);
    });

    test('achieved ratio reflects carrier PG only', () {
      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        baseMode: BaseMode.maxVg,
        flavors: [(flavor('a'), 10)], // PG-carried
      );
      expect(r.actualVgPercent, closeTo(90, 1e-9));
    });

    test('VG-carried concentrates give a full 100% VG mix', () {
      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        baseMode: BaseMode.maxVg,
        flavors: [(flavor('a', carrierVg: 1), 10)],
      );
      expect(r.actualVgPercent, closeTo(100, 1e-9));
    });

    test('warns and clamps when concentrates exceed the batch', () {
      final r = calculateMix(
        amountMl: 10,
        targetNic: 0,
        targetVgPercent: 50,
        settings: Settings(),
        baseMode: BaseMode.maxVg,
        flavors: [(flavor('a'), 60), (flavor('b'), 60)],
      );
      expect(r.lines.firstWhere((l) => l.name == 'VG').ml, 0);
      expect(r.warnings.any((w) => w.contains('larger than')), isTrue);
    });

    test('ratio mode is unaffected', () {
      final r = calculateMix(
        amountMl: 30,
        targetNic: 0,
        targetVgPercent: 70,
        settings: Settings(),
        flavors: [(flavor('a'), 10)],
      );
      expect(r.lines.firstWhere((l) => l.name == 'PG').ml, greaterThan(0));
    });

    test('baseMode round-trips and defaults to ratio', () {
      final r = Recipe(id: 'r', name: 'M', baseMode: BaseMode.maxVg);
      final back = Recipe.fromJson(
        jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
      );
      expect(back.baseMode, BaseMode.maxVg);
      expect(
        Recipe.fromJson({'id': 'x', 'name': 'Old'}).baseMode,
        BaseMode.ratio,
      );
    });
  });

  group('recipe stores its bases', () {
    AppState withBases() {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.ingredients.addAll([
        Ingredient(
          id: 'nic-pg',
          name: 'Nic 100 (PG)',
          kind: IngredientKind.nicotine,
          density: 1.036,
          nicStrength: 100,
        ),
        Ingredient(
          id: 'nic-vg',
          name: 'Nic 250 (VG)',
          kind: IngredientKind.nicotine,
          density: 1.261,
          nicStrength: 250,
          carrierVg: 1,
        ),
        Ingredient(
          id: 'pg',
          name: 'PG',
          kind: IngredientKind.pg,
          density: 1.036,
        ),
        Ingredient(
          id: 'vg',
          name: 'VG',
          kind: IngredientKind.vg,
          density: 1.261,
        ),
      ]);
      return s;
    }

    test('an unpinned recipe still uses the first of each kind', () {
      final s = withBases();
      final r = Recipe(id: 'r', name: 'R');
      expect(s.baseFor(r, IngredientKind.nicotine)!.id, 'nic-pg');
      expect(s.baseFor(r, IngredientKind.pg)!.id, 'pg');
      expect(s.baseFor(r, IngredientKind.vg)!.id, 'vg');
      expect(s.hasMissingBase(r), isFalse);
    });

    test('a pinned base is used instead of the first', () {
      final s = withBases();
      final r = Recipe(id: 'r', name: 'R', nicId: 'nic-vg');
      expect(s.baseFor(r, IngredientKind.nicotine)!.id, 'nic-vg');
    });

    test('which base is pinned changes the mix', () {
      // The bug this closes: a recipe recorded 3 mg/mL and nothing else,
      // so it silently mixed with whatever base happened to be selected.
      // A 100 mg/mL PG base and a 250 mg/mL VG base are not interchangeable.
      final s = withBases();
      MixResult mix(Recipe r, {BaseMode base = BaseMode.ratio}) => calculateMix(
        amountMl: 100,
        targetNic: r.targetNic,
        targetVgPercent: r.targetVgPercent,
        settings: s.settings,
        baseMode: base,
        nic: s.baseFor(r, IngredientKind.nicotine),
        pg: s.baseFor(r, IngredientKind.pg),
        vg: s.baseFor(r, IngredientKind.vg),
      );

      final weakR = Recipe(id: 'a', name: 'A', nicId: 'nic-pg');
      final strongR = Recipe(id: 'b', name: 'B', nicId: 'nic-vg');
      final weak = mix(weakR);
      final strong = mix(strongR);

      // 3 mL of a 100 mg/mL base versus 1.2 mL of a 250 mg/mL one — a
      // different bottle drawn down by a different amount.
      expect(
        weak.lines.firstWhere((l) => l.ingredientId == 'nic-pg').ml,
        closeTo(3, 1e-9),
      );
      expect(
        strong.lines.firstWhere((l) => l.ingredientId == 'nic-vg').ml,
        closeTo(1.2, 1e-9),
      );

      // In ratio mode the calculator carves the carrier out of the target,
      // so both still land on 3 mg and 70% VG. That is by design.
      for (final r in [weak, strong]) {
        expect(r.actualNicMgPerMl, closeTo(3, 1e-9));
        expect(r.actualVgPercent, closeTo(70, 1e-9));
      }

      // Max VG has no neat PG to absorb the difference, so the carrier the
      // base drags in lands directly on the finished ratio.
      expect(
        mix(weakR, base: BaseMode.maxVg).actualVgPercent,
        closeTo(97, 1e-9),
      );
      expect(
        mix(strongR, base: BaseMode.maxVg).actualVgPercent,
        closeTo(100, 1e-9),
      );
    });

    test('a deleted base falls back rather than dropping the nicotine', () {
      final s = withBases();
      final r = Recipe(id: 'r', name: 'R', nicId: 'nic-vg');
      s.removeIngredient('nic-vg');

      expect(s.hasMissingBase(r), isTrue);
      // Falls back rather than returning null — mixing with the wrong base
      // is recoverable, silently mixing 0 mg is not.
      expect(s.baseFor(r, IngredientKind.nicotine)!.id, 'nic-pg');
    });

    test('an id of the wrong kind is refused', () {
      final s = withBases();
      // A PG bottle pinned as the nicotine base would otherwise mix 0 mg.
      final r = Recipe(id: 'r', name: 'R', nicId: 'pg');
      expect(s.hasMissingBase(r), isTrue);
      expect(s.baseFor(r, IngredientKind.nicotine)!.id, 'nic-pg');
    });

    test('bases round-trip and default to null for old recipes', () {
      final r = Recipe(
        id: 'r',
        name: 'R',
        nicId: 'nic-vg',
        pgId: 'pg',
        vgId: 'vg',
      );
      final back = Recipe.fromJson(
        jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
      );
      expect(back.nicId, 'nic-vg');
      expect(back.pgId, 'pg');
      expect(back.vgId, 'vg');

      // A pre-v12 recipe has no such keys, which reads as no preference.
      final old = Recipe.fromJson({'id': 'o', 'name': 'Old'});
      expect(old.nicId, isNull);
      expect(old.pgId, isNull);
      expect(old.vgId, isNull);
    });

    test('capacity is computed against the pinned base', () {
      final s = withBases();
      // Plenty of everything except the strong base, of which there is
      // barely any.
      for (final (id, ml) in [
        ('nic-pg', 500.0),
        ('nic-vg', 1.0),
        ('pg', 1000.0),
        ('vg', 1000.0),
      ]) {
        s.addAdjustment(
          ingredientId: id,
          deltaMl: ml,
          reason: AdjustReason.opening,
        );
      }

      final pinned = Recipe(id: 'a', name: 'A', batchMl: 100, nicId: 'nic-vg');
      final unpinned = Recipe(id: 'b', name: 'B', batchMl: 100);

      // At 3 mg, 1 mL of a 250 mg/mL base makes ~83 mL. The weak base is
      // not the constraint at all, so the unpinned recipe is limited only
      // by the 1000 mL of PG/VG.
      expect(s.capacityFor(pinned)!, closeTo(1 / 1.2 * 100, 1e-6));
      expect(s.capacityFor(unpinned)!, greaterThan(1000));
    });

    test('a v11 store migrates to v12 without touching its recipes', () async {
      SharedPreferences.setMockInitialValues({
        'schema_version': 11,
        'ingredients_v1': jsonEncode(<Object>[]),
        'recipes_v1': jsonEncode([
          {
            'id': 'r1',
            'name': 'Old recipe',
            'batchMl': 30,
            'targetNic': 3,
            'targetVgPercent': 70,
            'flavors': <Object>[],
          },
        ]),
      });

      final s = AppState();
      await waitReady(s);
      expect(s.loadError, isNull);

      final r = s.recipeById('r1')!;
      expect(r.nicId, isNull);
      expect(r.targetNic, 3);
      expect(r.targetVgPercent, 70);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('schema_version'), 12);
    });
  });

  group('recipe as shareable text', () {
    AppState stocked() {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.ingredients.addAll([
        Ingredient(
          id: 'sb',
          name: 'Strawberry (Ripe)',
          brand: 'TFA',
          kind: IngredientKind.flavor,
          density: 1.036,
        ),
        Ingredient(
          id: 'vbic',
          name: 'Vanilla Bean Ice Cream',
          brand: 'TFA',
          kind: IngredientKind.flavor,
          density: 1.036,
        ),
      ]);
      return s;
    }

    Recipe sample() => Recipe(
      id: 'r',
      name: 'Mustard Milk',
      notes: 'Shake and vape.',
      batchMl: 30,
      targetNic: 3,
      targetVgPercent: 70,
      flavors: [
        RecipeFlavor(
          ingredientId: 'sb',
          name: 'TFA Strawberry (Ripe)',
          percent: 8,
        ),
        RecipeFlavor(
          ingredientId: 'vbic',
          name: 'TFA Vanilla Bean Ice Cream',
          percent: 6,
        ),
      ],
    );

    test('renders percentages, bases and notes', () {
      final text = stocked().recipeAsText(sample());
      expect(text, contains('Mustard Milk'));
      expect(text, contains('8% TFA Strawberry (Ripe)'));
      expect(text, contains('6% TFA Vanilla Bean Ice Cream'));
      expect(text, contains('30ml'));
      expect(text, contains('70/30 VG/PG'));
      expect(text, contains('3mg'));
      expect(text, contains('Shake and vape.'));
    });

    test('round-trips back through the parser', () {
      // The whole point of emitting this dialect: what MixLab shares,
      // MixLab can read.
      final s = stocked();
      final parsed = parseRecipeText(s.recipeAsText(sample()));

      expect(parsed.batchMl, 30);
      expect(parsed.nic, 3);
      expect(parsed.vgPercent, 70);
      expect(parsed.lines.length, 2);
      expect(parsed.name, 'Mustard Milk');

      // And the ingredients resolve back to the same bottles.
      expect(matchParsedLine(parsed.lines[0], s.ingredients)?.id, 'sb');
      expect(matchParsedLine(parsed.lines[1], s.ingredients)?.id, 'vbic');
      expect(parsed.lines[0].percent, 8);
      expect(parsed.lines[1].percent, 6);
    });

    test('max VG survives the round trip', () {
      final s = stocked();
      final r = sample()..baseMode = BaseMode.maxVg;
      final text = s.recipeAsText(r);
      expect(text, contains('Max VG'));
      expect(parseRecipeText(text).maxVg, isTrue);
    });

    test('by-weight recipes say so', () {
      final s = stocked();
      final r = sample()..percentMode = PercentMode.byWeight;
      expect(s.recipeAsText(r), contains('by weight'));
      // A by-volume recipe stays silent rather than claiming a default.
      expect(s.recipeAsText(sample()), isNot(contains('by weight')));
    });

    test('named bases appear as a human note, not as ids', () {
      final s = stocked();
      s.ingredients.add(
        Ingredient(
          id: 'nic-vg',
          name: 'Nic 250 (VG)',
          kind: IngredientKind.nicotine,
          density: 1.261,
          nicStrength: 250,
        ),
      );
      final text = s.recipeAsText(sample()..nicId = 'nic-vg');
      expect(text, contains('Nic 250 (VG)'));
      expect(text, isNot(contains('nic-vg')));
    });

    test('fractional percentages keep their precision', () {
      final s = stocked();
      final r = Recipe(
        id: 'r',
        name: 'Fiddly',
        flavors: [
          RecipeFlavor(
            ingredientId: 'sb',
            name: 'TFA Strawberry (Ripe)',
            percent: 0.25,
          ),
        ],
      );
      final text = s.recipeAsText(r);
      expect(text, contains('0.25%'));
      expect(parseRecipeText(text).lines.single.percent, closeTo(0.25, 1e-9));
    });

    test('a base-only recipe still renders', () {
      final s = stocked();
      final text = s.recipeAsText(Recipe(id: 'r', name: 'Just base'));
      expect(text, contains('Just base'));
      expect(text, contains('base only'));
    });

    test('names come from inventory, so a rename is picked up', () {
      final s = stocked();
      s.byId('sb')!.name = 'Strawberry Ripe (renamed)';
      // The recipe still carries the old label; inventory wins.
      expect(s.recipeAsText(sample()), contains('renamed'));
    });
  });

  group('recipe text import', () {
    test('percent-prefix with brand shorthand', () {
      final p = parseRecipeText('''
Mustard Milk
8% TFA Strawberry (Ripe)
6% TFA Vanilla Bean Ice Cream
''');
      expect(p.name, 'Mustard Milk');
      expect(p.lines.length, 2);
      expect(p.lines[0].brand, 'TFA');
      expect(p.lines[0].name, 'Strawberry (Ripe)');
      expect(p.lines[0].percent, 8);
      expect(p.totalPercent, 14);
    });

    test('trailing vendor in parentheses, TPA aliased to TFA', () {
      final p = parseRecipeText('''
8% Strawberry (Ripe) (TPA)
2.5% Bavarian Cream (TPA)
''');
      expect(p.lines[0].brand, 'TFA');
      expect(p.lines[0].name, 'Strawberry (Ripe)');
      expect(p.lines[1].percent, 2.5);
      expect(p.lines[1].name, 'Bavarian Cream');
    });

    test('tab-separated columns', () {
      final p = parseRecipeText(
        'Strawberry (Ripe)\tTPA\t8\nVanilla Bean Ice Cream\tTPA\t6',
      );
      expect(p.lines.length, 2);
      expect(p.lines[0].brand, 'TFA');
      expect(p.lines[0].name, 'Strawberry (Ripe)');
      expect(p.lines[0].percent, 8);
    });

    test('name first with trailing percent', () {
      final p = parseRecipeText('CAP Sweet Cream 2%');
      expect(p.lines.single.brand, 'CAP');
      expect(p.lines.single.name, 'Sweet Cream');
      expect(p.lines.single.percent, 2);
    });

    test('picks up batch size, nicotine and ratio', () {
      final p = parseRecipeText('''
30ml
70/30 VG/PG
3mg
8% TFA Strawberry (Ripe)
''');
      expect(p.batchMl, 30);
      expect(p.nic, 3);
      expect(p.vgPercent, 70);
      expect(p.lines.length, 1);
    });

    test('detects max VG', () {
      final p = parseRecipeText('Max VG\n10% TFA Fruit Circles');
      expect(p.maxVg, isTrue);
      expect(p.lines.length, 1);
    });

    test('comma decimals and unrecognised vendors survive', () {
      final p = parseRecipeText('1,5% Some Vendor Mystery Flavor');
      expect(p.lines.single.percent, 1.5);
      expect(p.lines.single.brand, '');
      expect(p.lines.single.name, 'Some Vendor Mystery Flavor');
    });

    test('noise lines are skipped, junk is reported not dropped', () {
      final p = parseRecipeText('''
Flavor	Vendor	Percentage
https://alltheflavors.com/recipes/1234
8% TFA Strawberry (Ripe)
some line with no numbers at all
''');
      expect(p.lines.length, 1);
      expect(p.ignored.length, 1);
      expect(p.ignored.single.contains('no numbers'), isTrue);
    });

    test('canonicalBrand handles aliases and full names', () {
      expect(canonicalBrand('tpa'), 'TFA');
      expect(canonicalBrand('Capella'), 'CAP');
      expect(canonicalBrand('T.F.A.'), 'TFA');
      expect(canonicalBrand('Nonsense'), '');
    });
  });

  group('import matching', () {
    test('matches on brand and name, ignoring punctuation and case', () {
      final inv = [
        Ingredient(
          id: 'a',
          name: 'Strawberry (Ripe)',
          brand: 'TFA',
          kind: IngredientKind.flavor,
          density: 1,
        ),
      ];
      final line = parseRecipeText('8% strawberry ripe (TPA)').lines.single;
      expect(matchParsedLine(line, inv)?.id, 'a');
    });

    test('falls back to a unique name match across brands', () {
      final inv = [
        Ingredient(
          id: 'a',
          name: 'Sweet Cream',
          brand: 'CAP',
          kind: IngredientKind.flavor,
          density: 1,
        ),
      ];
      final line = parseRecipeText('2% Sweet Cream').lines.single;
      expect(matchParsedLine(line, inv)?.id, 'a');
    });

    test('refuses an ambiguous name match', () {
      final inv = [
        Ingredient(
          id: 'a',
          name: 'Vanilla',
          brand: 'CAP',
          kind: IngredientKind.flavor,
          density: 1,
        ),
        Ingredient(
          id: 'b',
          name: 'Vanilla',
          brand: 'TFA',
          kind: IngredientKind.flavor,
          density: 1,
        ),
      ];
      final line = parseRecipeText('2% Vanilla').lines.single;
      expect(matchParsedLine(line, inv), isNull);
    });

    test('bases are read as metadata, not ingredients', () {
      expect(parseRecipeText('50% VG').lines, isEmpty);
      expect(parseRecipeText('50% VG').vgPercent, 50);
    });

    test('matching ignores non-concentrate kinds', () {
      final inv = [
        Ingredient(
          id: 'v',
          name: 'Menthol',
          kind: IngredientKind.vg, // deliberately wrong kind
          density: 1,
        ),
      ];
      final line = parseRecipeText('2% Menthol').lines.single;
      expect(matchParsedLine(line, inv), isNull);
    });
    test('a header word inside an ingredient name is not noise', () {
      final p = parseRecipeText('1,5% Some Vendor Mystery Flavor');
      expect(p.lines.single.percent, 1.5);
      expect(p.ignored, isEmpty);
    });
  });
  group('nicotine strength units', () {
    test('mg/mL is unchanged', () {
      final n = Ingredient(
        id: 'n',
        name: 'Nic',
        kind: IngredientKind.nicotine,
        density: 1.036,
        nicStrength: 100,
      );
      expect(n.nicMgPerMl, 100);
    });

    test('mg/g converts through density', () {
      final n = Ingredient(
        id: 'n',
        name: 'Nic VG',
        kind: IngredientKind.nicotine,
        density: 1.261,
        nicStrength: 100,
        nicUnit: NicUnit.perGram,
        carrierVg: 1,
      );
      // 100 mg per gram, 1.261 g per mL -> 126.1 mg/mL
      expect(n.nicMgPerMl, closeTo(126.1, 1e-9));
    });

    test('a mg/g base needs less volume for the same target', () {
      Ingredient base(NicUnit u) => Ingredient(
        id: 'n',
        name: 'Nic',
        kind: IngredientKind.nicotine,
        density: 1.261,
        nicStrength: 100,
        nicUnit: u,
        carrierVg: 1,
        stockMl: 100,
      );

      double nicMl(NicUnit u) => calculateMix(
        amountMl: 100,
        targetNic: 6,
        targetVgPercent: 100,
        settings: Settings(),
        nic: base(u),
      ).lines.first.ml;

      expect(nicMl(NicUnit.perMl), closeTo(6, 1e-9));
      expect(nicMl(NicUnit.perGram), closeTo(100 * 6 / 126.1, 1e-9));
      expect(nicMl(NicUnit.perGram), lessThan(nicMl(NicUnit.perMl)));
    });

    test('achieved strength still lands on target for mg/g', () {
      final r = calculateMix(
        amountMl: 100,
        targetNic: 6,
        targetVgPercent: 100,
        settings: Settings(),
        nic: Ingredient(
          id: 'n',
          name: 'Nic',
          kind: IngredientKind.nicotine,
          density: 1.261,
          nicStrength: 100,
          nicUnit: NicUnit.perGram,
          carrierVg: 1,
          stockMl: 100,
        ),
      );
      expect(r.actualNicMgPerMl, closeTo(6, 1e-9));
    });

    test('over-strength warning uses the converted value', () {
      final r = calculateMix(
        amountMl: 30,
        targetNic: 120, // under 126.1 mg/mL, so this must NOT warn
        targetVgPercent: 100,
        settings: Settings(),
        nic: Ingredient(
          id: 'n',
          name: 'Nic',
          kind: IngredientKind.nicotine,
          density: 1.261,
          nicStrength: 100,
          nicUnit: NicUnit.perGram,
          stockMl: 100,
        ),
      );
      expect(r.warnings.any((w) => w.contains('below the base')), isFalse);
    });

    test('unit and salt flag round-trip, defaulting for old data', () {
      final n = Ingredient(
        id: 'n',
        name: 'Salt',
        kind: IngredientKind.nicotine,
        density: 1.036,
        nicStrength: 50,
        nicUnit: NicUnit.perGram,
        nicIsSalt: true,
      );
      final back = Ingredient.fromJson(
        jsonDecode(jsonEncode(n.toJson())) as Map<String, dynamic>,
      );
      expect(back.nicUnit, NicUnit.perGram);
      expect(back.nicIsSalt, isTrue);

      final old = Ingredient.fromJson({
        'id': 'x',
        'name': 'Legacy',
        'kind': IngredientKind.nicotine.index,
        'density': 1.036,
        'nicStrength': 100,
      });
      expect(old.nicUnit, NicUnit.perMl);
      expect(old.nicIsSalt, isFalse);
      expect(old.nicMgPerMl, 100);
    });
  });

  group('currency formatting', () {
    test('falls back gracefully for an unknown code', () {
      final s = Settings(currency: 'ZZZ');
      expect(money(1.5, s).contains('1.50'), isTrue);
    });

    test('per-mL keeps three decimals', () {
      expect(moneyPerMl(0.1234, Settings()), '0.123 USD/mL');
    });
  });

  group('hardware costs', () {
    test('off by default, so existing figures do not move', () {
      expect(hardwareCostFor(30, Settings()), 0);
    });

    test('counts whole bottles plus consumables', () {
      final s = Settings(
        includeHardware: true,
        emptyBottleCost: 0.40,
        emptyBottleMl: 30,
        consumablesCost: 0.10,
      );
      expect(hardwareCostFor(30, s), closeTo(0.50, 1e-9)); // 1 bottle
      expect(hardwareCostFor(31, s), closeTo(0.90, 1e-9)); // 2 bottles
      expect(hardwareCostFor(100, s), closeTo(1.70, 1e-9)); // 4 bottles
      expect(hardwareCostFor(0, s), 0);
    });

    test('logMix records it separately from juice cost', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false)
        ..settings = Settings(
          includeHardware: true,
          emptyBottleCost: 1,
          emptyBottleMl: 30,
        );
      final f = addStocked(s, flavor('a'), 1000);
      s.ingredients.add(f);

      final log = s.logMix(
        calculateMix(
          amountMl: 60,
          targetNic: 0,
          targetVgPercent: 50,
          settings: s.settings,
          flavors: [(f, 10)],
        ),
      );
      expect(log.hardwareCost, closeTo(2, 1e-9)); // two 30 mL bottles
      expect(log.totalCost, closeTo(0.6, 1e-9)); // juice only
      expect(log.grandTotalCost, closeTo(2.6, 1e-9));
    });
  });

  group('shipping in the cost basis', () {
    test('lands in the weighted average', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final e = Ingredient(
        id: 'v',
        name: 'VG',
        kind: IngredientKind.vg,
        density: 1.261,
        bottleSizeMl: 100,
        bottleCost: 10,
        stockMl: 0, // empty, so the new basis is purely this purchase
      );
      s.ingredients.add(e);

      final p = s.recordPurchase(
        ingredientId: 'v',
        volumeMl: 100,
        cost: 10,
        shippingCost: 5,
      );
      expect(p.totalCost, 15);
      expect(e.costPerMl, closeTo(0.15, 1e-9));
      expect(s.lifetimeSpend, 15);
    });

    test('undo still restores the old basis exactly', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final e = addStocked(
        s,
        Ingredient(
          id: 'v',
          name: 'VG',
          kind: IngredientKind.vg,
          density: 1.261,
          bottleSizeMl: 100,
          bottleCost: 10, // opening balance carries 0.10/mL
        ),
        100,
      );

      final p = s.recordPurchase(
        ingredientId: 'v',
        volumeMl: 100,
        cost: 10,
        shippingCost: 8,
      );
      expect(e.costPerMl, closeTo(0.14, 1e-9)); // (10 + 18) / 200

      s.undoPurchase(p.id);
      expect(e.stockMl, closeTo(100, 1e-9));
      expect(e.costPerMl, closeTo(0.10, 1e-9));
    });
  });

  group('what can I make', () {
    AppState withStock(double flavorStock) {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.ingredients.add(flavor('a', stock: flavorStock));
      s.recipes.add(
        Recipe(
          id: 'r',
          name: 'R',
          batchMl: 30,
          targetNic: 0,
          targetVgPercent: 70,
          flavors: [RecipeFlavor(ingredientId: 'a', name: 'a', percent: 10)],
        ),
      );
      return s;
    }

    test('capacity scales from the limiting ingredient', () {
      final s = withStock(9); // 10% of a batch, so 9 mL supports 90 mL
      expect(s.capacityFor(s.recipes.single), closeTo(90, 1e-6));
      expect(s.canMakeNow(s.recipes.single), isTrue);
    });

    test('short stock reports a partial batch and blocks', () {
      final s = withStock(1.5); // supports only 15 mL
      expect(s.capacityFor(s.recipes.single), closeTo(15, 1e-6));
      expect(s.canMakeNow(s.recipes.single), isFalse);
    });

    test('a missing ingredient means it cannot be made', () {
      final s = withStock(100);
      s.removeIngredient('a');
      expect(s.canMakeNow(s.recipes.single), isFalse);
    });

    test('untracked bases give an unlimited result', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.recipes.add(Recipe(id: 'r', name: 'Base only', batchMl: 30));
      expect(s.capacityFor(s.recipes.single), isNull);
      expect(s.canMakeNow(s.recipes.single), isTrue);
    });

    test('respects by-weight recipes too', () {
      final s = withStock(9);
      s.recipes.single.percentMode = PercentMode.byWeight;
      final cap = s.capacityFor(s.recipes.single);
      expect(cap, isNotNull);
      expect(cap!, greaterThan(60)); // scales, just not identically
    });
  });

  group('sync merge', () {
    /// Two independent installs, each with its own device id.
    (AppState, AppState) twoDevices() {
      SharedPreferences.setMockInitialValues({});
      final a = AppState(autoLoad: false)..deviceId = 'aaa';
      final b = AppState(autoLoad: false)..deviceId = 'bbb';
      return (a, b);
    }

    Ingredient stocked(AppState s, String id, double ml) {
      final e = flavor(id);
      e.updatedAt = DateTime.now();
      s.ingredients.add(e);
      s.addAdjustment(
        ingredientId: id,
        deltaMl: ml,
        reason: AdjustReason.opening,
      );
      return e;
    }

    test('ledger events from both sides survive — the old union lost one', () {
      final (a, b) = twoDevices();
      final fa = stocked(a, 'x', 100);
      final fb = stocked(b, 'x', 100);
      // Same opening balance id on both, as v9 produces.
      b.adjustments.first = StockAdjustment(
        id: a.adjustments.first.id,
        ingredientId: 'x',
        ingredientName: 'x',
        at: a.adjustments.first.at,
        deltaMl: 100,
        reason: AdjustReason.opening,
      );
      b.recomputeStock();

      MixResult mix(AppState s, Ingredient f) => calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: s.settings,
        flavors: [(f, 10)],
      );

      a.logMix(mix(a, fa), label: 'On A');
      b.logMix(mix(b, fb), label: 'On B');
      expect(fa.stockMl, closeTo(90, 1e-9));

      final plan = a.previewMerge(b.exportJson());
      expect(plan.countOf(MergeAction.add), 1); // B's mix
      a.applyMerge(plan);

      // Both deductions land, which mutable stockMl could never do.
      expect(a.byId('x')!.stockMl, closeTo(80, 1e-9));
      expect(a.mixLog.length, 2);
    });

    test('last write wins on an edited ingredient', () async {
      final (a, b) = twoDevices();
      final shared = flavor('x')
        ..updatedAt = DateTime(2026, 1, 1)
        ..name = 'Original';
      a.ingredients.add(shared);
      b.ingredients.add(
        Ingredient.fromJson(
          jsonDecode(jsonEncode(shared.toJson())) as Map<String, dynamic>,
        ),
      );

      // B edits later.
      b.byId('x')!.name = 'Renamed on B';
      b.upsertIngredient(b.byId('x')!);

      final plan = a.previewMerge(b.exportJson());
      expect(plan.countOf(MergeAction.update), 1);
      expect(plan.items.single.detail.contains('Renamed on B'), isTrue);

      await a.applyMerge(plan);
      expect(a.byId('x')!.name, 'Renamed on B');
    });

    test('an older edit does not overwrite a newer one', () async {
      final (a, b) = twoDevices();
      final base = flavor('x')..updatedAt = DateTime(2026, 1, 1);
      a.ingredients.add(base);
      b.ingredients.add(
        Ingredient.fromJson(
          jsonDecode(jsonEncode(base.toJson())) as Map<String, dynamic>,
        ),
      );

      b.byId('x')!.name = 'Stale';
      b.byId('x')!.updatedAt = DateTime(2026, 1, 2);
      a.byId('x')!.name = 'Fresh';
      a.byId('x')!.updatedAt = DateTime(2026, 6, 1);

      final plan = a.previewMerge(b.exportJson());
      expect(plan.items, isEmpty);
    });

    test('deletions propagate instead of resurrecting', () async {
      final (a, b) = twoDevices();
      final r = Recipe(id: 'r1', name: 'Doomed')
        ..updatedAt = DateTime(2026, 1, 1);
      a.recipes.add(r);
      b.recipes.add(
        Recipe.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
        ),
      );

      b.removeRecipe('r1'); // writes a tombstone

      final plan = a.previewMerge(b.exportJson());
      expect(plan.countOf(MergeAction.delete), 1);

      await a.applyMerge(plan);
      expect(a.recipeById('r1'), isNull);
      // The tombstone came across, so a later merge cannot bring it back.
      expect(a.tombstones.any((t) => t.recordId == 'r1'), isTrue);
    });

    test('a record edited after deletion is not deleted', () async {
      final (a, b) = twoDevices();
      final r = Recipe(id: 'r1', name: 'Kept')
        ..updatedAt = DateTime(2026, 6, 1);
      a.recipes.add(r);
      b.recipes.add(
        Recipe(id: 'r1', name: 'Kept')..updatedAt = DateTime(2026, 1, 1),
      );
      b.removeRecipe('r1');
      // B's tombstone is now, which beats A's June edit only if later.
      b.tombstones.last = Tombstone(
        type: RecordType.recipe,
        recordId: 'r1',
        deletedAt: DateTime(2026, 2, 1), // before A's edit
      );

      final plan = a.previewMerge(b.exportJson());
      expect(plan.countOf(MergeAction.delete), 0);
    });

    test('declined items are not applied', () async {
      final (a, b) = twoDevices();
      b.recipes.add(
        Recipe(id: 'r1', name: 'Theirs')..updatedAt = DateTime.now(),
      );
      b.recipes.add(
        Recipe(id: 'r2', name: 'Also theirs')..updatedAt = DateTime.now(),
      );

      final plan = a.previewMerge(b.exportJson());
      expect(plan.items.length, 2);
      plan.items.first.accept = false;

      await a.applyMerge(plan);
      expect(a.recipes.length, 1);
    });

    test('merging twice changes nothing the second time', () async {
      final (a, b) = twoDevices();
      stocked(b, 'x', 100);
      b.recipes.add(Recipe(id: 'r1', name: 'R')..updatedAt = DateTime.now());

      final dump = b.exportJson();
      await a.applyMerge(a.previewMerge(dump));
      final after = a.byId('x')!.stockMl;

      final second = a.previewMerge(dump);
      expect(second.items, isEmpty);
      await a.applyMerge(second);
      expect(a.byId('x')!.stockMl, closeTo(after, 1e-9));
    });

    test('ids carry a device fragment', () {
      SharedPreferences.setMockInitialValues({});
      final ids = List.generate(5, (_) => newId());
      expect(ids.toSet().length, 5);
      expect(ids.every((i) => i.split('-').length >= 3), isTrue);
    });

    test('refuses a backup from a newer schema', () {
      final (a, _) = twoDevices();
      expect(
        () => a.previewMerge('{"app": "mixlab", "schema": 999}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuses a file that is not a MixLab backup', () {
      final (a, _) = twoDevices();
      expect(
        () => a.previewMerge('{"ingredients": []}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('settings only offered when strictly newer', () async {
      final (a, b) = twoDevices();
      a.settings.updatedAt = DateTime(2026, 6, 1);
      b.settings
        ..currency = 'EUR'
        ..updatedAt = DateTime(2026, 1, 1);
      expect(a.previewMerge(b.exportJson()).incomingSettings, isNull);

      b.settings.updatedAt = DateTime(2026, 12, 1);
      final plan = a.previewMerge(b.exportJson());
      expect(plan.incomingSettings, isNotNull);
      expect(plan.settingsDetail.contains('EUR'), isTrue);

      // Off by default — settings should not change silently.
      expect(plan.acceptSettings, isFalse);
      await a.applyMerge(plan);
      expect(a.settings.currency, 'USD');
    });

    test('a declined delete keeps the record and its tombstone away', () async {
      final (a, b) = twoDevices();
      final r = Recipe(id: 'r1', name: 'Contested')
        ..updatedAt = DateTime(2026, 1, 1);
      a.recipes.add(r);
      b.recipes.add(
        Recipe.fromJson(
          jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
        ),
      );
      b.removeRecipe('r1');

      final plan = a.previewMerge(b.exportJson());
      expect(plan.countOf(MergeAction.delete), 1);
      plan.items.single.accept = false;
      await a.applyMerge(plan);

      // The record survives, as asked.
      expect(a.recipeById('r1'), isNotNull);
      // And no grave was dug for it. Folding the tombstone anyway would
      // make A tell every other device to delete a record A still holds,
      // and buried() would stop it ever syncing back.
      expect(a.tombstones.any((t) => t.recordId == 'r1'), isFalse);
    });

    test('applying the same plan twice does not double stock', () async {
      final (a, b) = twoDevices();
      stocked(b, 'x', 100);

      final plan = a.previewMerge(b.exportJson());
      await a.applyMerge(plan);
      final after = a.byId('x')!.stockMl;
      expect(after, closeTo(100, 1e-9));

      // The preview would filter a second pass, but the plan object itself
      // must be idempotent — ledger events have no undo but a fresh replay.
      await a.applyMerge(plan);
      expect(a.adjustments.length, 1);
      expect(a.byId('x')!.stockMl, closeTo(after, 1e-9));
    });

    test('a pre-ledger backup merges with its stock intact', () async {
      final (a, _) = twoDevices();
      final dump = jsonEncode({
        'app': 'mixlab',
        'schema': 8,
        'deviceId': 'old-device',
        'ingredients': [
          {
            'id': 'v',
            'name': 'VG',
            'kind': IngredientKind.vg.index,
            'density': 1.261,
            'stockMl': 500,
            'bottleSizeMl': 500,
            'bottleCost': 14,
            'updatedAt': DateTime(2026, 1, 1).toIso8601String(),
          },
        ],
      });

      await a.applyMerge(a.previewMerge(dump));

      // Stock is derived from the ledger, so without synthesised opening
      // balances the whole inventory would arrive reading 0 mL.
      expect(a.byId('v')!.stockMl, closeTo(500, 1e-9));
      expect(a.adjustments.single.reason, AdjustReason.opening);
      expect(a.byId('v')!.costPerMl, closeTo(0.028, 1e-3));

      // Idempotent: the opening id is deterministic, so a second merge of
      // the same file is a no-op.
      expect(a.previewMerge(dump).items, isEmpty);
      await a.applyMerge(a.previewMerge(dump));
      expect(a.byId('v')!.stockMl, closeTo(500, 1e-9));
    });

    test('a pre-v2 backup merges with its brand split out', () async {
      final (a, _) = twoDevices();
      await a.applyMerge(
        a.previewMerge(
          jsonEncode({
            'app': 'mixlab',
            'schema': 1,
            'ingredients': [
              {
                'id': 'z',
                'name': 'CAP Sweet Cream',
                'kind': IngredientKind.flavor.index,
                'density': 1.036,
              },
            ],
          }),
        ),
      );
      expect(a.byId('z')!.brand, 'CAP');
      expect(a.byId('z')!.name, 'Sweet Cream');
    });
  });

  group('merge deduplicates ingredients by name', () {
    (AppState, AppState) twoDevices() {
      SharedPreferences.setMockInitialValues({});
      return (
        AppState(autoLoad: false)..deviceId = 'aaa',
        AppState(autoLoad: false)..deviceId = 'bbb',
      );
    }

    /// The same bottle typed into two installs, so each minted its own id.
    Ingredient typed(AppState s, String id, String brand, String name) {
      final e = Ingredient(
        id: id,
        name: name,
        brand: brand,
        kind: IngredientKind.flavor,
        density: 1.036,
        updatedAt: DateTime(2026, 1, 1),
      );
      s.ingredients.add(e);
      return e;
    }

    test('the same bottle under two ids becomes one ingredient', () async {
      final (a, b) = twoDevices();
      typed(a, 'local-1', 'TFA', 'Strawberry (Ripe)');
      typed(b, 'remote-9', 'TFA', 'Strawberry (Ripe)');

      final plan = a.previewMerge(b.exportJson());
      expect(plan.matchedByName, 1);
      // No add proposed: it is not a new bottle, it is the same one.
      expect(plan.ofType(RecordType.ingredient), isEmpty);

      await a.applyMerge(plan);
      expect(a.ingredients.length, 1);
      expect(a.byId('local-1'), isNotNull);
      expect(a.byId('remote-9'), isNull);
    });

    test('matching ignores case and surrounding whitespace', () async {
      final (a, b) = twoDevices();
      typed(a, 'local-1', 'TFA', 'Strawberry (Ripe)');
      typed(b, 'remote-9', '  tfa ', ' STRAWBERRY (RIPE)  ');

      await a.applyMerge(a.previewMerge(b.exportJson()));
      expect(a.ingredients.length, 1);
    });

    test('a genuinely different bottle is still added', () async {
      final (a, b) = twoDevices();
      typed(a, 'local-1', 'TFA', 'Strawberry (Ripe)');
      typed(b, 'remote-9', 'CAP', 'Sweet Cream');

      final plan = a.previewMerge(b.exportJson());
      expect(plan.matchedByName, 0);
      expect(plan.countOf(MergeAction.add), 1);

      await a.applyMerge(plan);
      expect(a.ingredients.length, 2);
    });

    test('the same brand with a different flavor is not merged', () async {
      final (a, b) = twoDevices();
      typed(a, 'local-1', 'TFA', 'Strawberry (Ripe)');
      typed(b, 'remote-9', 'TFA', 'Vanilla Bean Ice Cream');

      await a.applyMerge(a.previewMerge(b.exportJson()));
      expect(a.ingredients.length, 2);
    });

    test('their stock lands on our copy, not a duplicate', () async {
      final (a, b) = twoDevices();
      typed(a, 'local-1', 'TFA', 'Strawberry (Ripe)');
      typed(b, 'remote-9', 'TFA', 'Strawberry (Ripe)');
      a.addAdjustment(
        ingredientId: 'local-1',
        deltaMl: 30,
        reason: AdjustReason.opening,
      );
      b.addAdjustment(
        ingredientId: 'remote-9',
        deltaMl: 20,
        reason: AdjustReason.opening,
      );

      await a.applyMerge(a.previewMerge(b.exportJson()));

      // Both ledger events survive, both pointing at the surviving record.
      expect(a.ingredients.length, 1);
      expect(a.byId('local-1')!.stockMl, closeTo(50, 1e-9));
      expect(
        a.adjustments.every((x) => x.ingredientId == 'local-1'),
        isTrue,
        reason: 'an adjustment still pointing at the remote id is orphaned',
      );
    });

    test('their recipes point at our ingredient', () async {
      final (a, b) = twoDevices();
      typed(a, 'local-1', 'TFA', 'Strawberry (Ripe)');
      typed(b, 'remote-9', 'TFA', 'Strawberry (Ripe)');
      b.recipes.add(
        Recipe(
          id: 'r1',
          name: 'Theirs',
          flavors: [
            RecipeFlavor(
              ingredientId: 'remote-9',
              name: 'TFA Strawberry (Ripe)',
              percent: 8,
            ),
          ],
        )..updatedAt = DateTime(2026, 2, 1),
      );

      await a.applyMerge(a.previewMerge(b.exportJson()));

      final r = a.recipeById('r1')!;
      expect(r.flavors.single.ingredientId, 'local-1');
      // Resolvable, so the recipe is mixable rather than showing a gap.
      expect(a.byId(r.flavors.single.ingredientId), isNotNull);
    });

    test('their mix log lines point at our ingredient', () async {
      final (a, b) = twoDevices();
      typed(a, 'local-1', 'TFA', 'Strawberry (Ripe)');
      typed(b, 'remote-9', 'TFA', 'Strawberry (Ripe)');
      a.addAdjustment(
        ingredientId: 'local-1',
        deltaMl: 100,
        reason: AdjustReason.opening,
      );
      b.addAdjustment(
        ingredientId: 'remote-9',
        deltaMl: 100,
        reason: AdjustReason.opening,
      );
      b.logMix(
        calculateMix(
          amountMl: 100,
          targetNic: 0,
          targetVgPercent: 50,
          settings: b.settings,
          flavors: [(b.byId('remote-9')!, 10)],
        ),
        label: 'On B',
      );

      await a.applyMerge(a.previewMerge(b.exportJson()));

      // 100 + 100 opening, minus the 10 mL their mix drew.
      expect(a.byId('local-1')!.stockMl, closeTo(190, 1e-9));
      expect(
        a.mixLog.single.lines.any((l) => l.ingredientId == 'remote-9'),
        isFalse,
      );
    });

    test('an id present on both sides is never re-matched', () async {
      // A rename must stay a rename. If the ids agree they are the same
      // record by definition, whatever the names now say.
      final (a, b) = twoDevices();
      typed(a, 'shared', 'TFA', 'Old Name');
      typed(a, 'other', 'CAP', 'Sweet Cream');
      typed(b, 'shared', 'CAP', 'Sweet Cream').updatedAt = DateTime(2026, 6, 1);

      final plan = a.previewMerge(b.exportJson());
      expect(plan.matchedByName, 0);
      await a.applyMerge(plan);

      expect(a.ingredients.length, 2);
      expect(a.byId('shared')!.name, 'Sweet Cream');
      expect(a.byId('other'), isNotNull);
    });

    test('two remote duplicates cannot both claim one local record', () async {
      final (a, b) = twoDevices();
      typed(a, 'local-1', 'TFA', 'Strawberry (Ripe)');
      typed(b, 'remote-9', 'TFA', 'Strawberry (Ripe)');
      typed(b, 'remote-8', 'TFA', 'Strawberry (Ripe)');

      final plan = a.previewMerge(b.exportJson());
      expect(plan.matchedByName, 1);
      await a.applyMerge(plan);

      // One aliased onto ours; the other arrives as its own record rather
      // than silently overwriting the first.
      expect(a.ingredients.length, 2);
      expect(a.byId('local-1'), isNotNull);
    });

    test('merging twice is still a no-op the second time', () async {
      final (a, b) = twoDevices();
      typed(a, 'local-1', 'TFA', 'Strawberry (Ripe)');
      typed(b, 'remote-9', 'TFA', 'Strawberry (Ripe)');
      b.addAdjustment(
        ingredientId: 'remote-9',
        deltaMl: 20,
        reason: AdjustReason.opening,
      );

      final dump = b.exportJson();
      await a.applyMerge(a.previewMerge(dump));
      final stock = a.byId('local-1')!.stockMl;

      await a.applyMerge(a.previewMerge(dump));
      expect(a.ingredients.length, 1);
      expect(a.byId('local-1')!.stockMl, closeTo(stock, 1e-9));
    });

    test('a nameless ingredient is not matched to another nameless one', () {
      final (a, b) = twoDevices();
      typed(a, 'local-1', '', '');
      typed(b, 'remote-9', '', '');
      expect(a.previewMerge(b.exportJson()).matchedByName, 0);
    });
  });

  group('cost basis', () {
    /// Two purchases at different prices, then a draw.
    AppState twoPrices(CostBasis basis) {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false)
        ..settings = Settings(costBasis: basis);
      final f = flavor('a')..stockMl = 0;
      s.ingredients.add(f);
      // 100 mL at 0.10, then 100 mL at 0.30.
      s.purchases.add(
        Purchase(
          id: 'p1',
          ingredientId: 'a',
          ingredientName: 'a',
          at: DateTime(2026, 1, 1),
          volumeMl: 100,
          cost: 10,
          prevStockMl: 0,
          prevCostPerMl: 0,
          prevAvgCostPerMl: 0,
        ),
      );
      s.purchases.add(
        Purchase(
          id: 'p2',
          ingredientId: 'a',
          ingredientName: 'a',
          at: DateTime(2026, 2, 1),
          volumeMl: 100,
          cost: 30,
          prevStockMl: 0,
          prevCostPerMl: 0,
          prevAvgCostPerMl: 0,
        ),
      );
      s.recomputeStock();
      return s;
    }

    void drawMix(AppState s, double ml, {DateTime? at}) {
      s.mixLog.insert(
        0,
        MixLog(
          id: 'mix-$ml-${at?.month ?? 0}',
          mixedAt: at ?? DateTime(2026, 3, 1),
          label: 'Draw',
          batchMl: ml,
          targetNic: 0,
          targetVgPercent: 0,
          totalGrams: 0,
          totalCost: 0,
          lines: [
            MixLogLine(
              name: 'a',
              ingredientId: 'a',
              requestedMl: ml,
              deductedMl: ml,
              grams: ml,
              cost: 0,
            ),
          ],
        ),
      );
      s.recomputeStock();
    }

    test('moving average blends every layer into one price', () {
      final s = twoPrices(CostBasis.movingAverage);
      expect(s.byId('a')!.stockMl, closeTo(200, 1e-9));
      expect(s.byId('a')!.costPerMl, closeTo(0.20, 1e-9));

      drawMix(s, 50);
      // Drawing does not move a blended basis.
      expect(s.byId('a')!.costPerMl, closeTo(0.20, 1e-9));
      expect(s.mixLog.first.totalCost, closeTo(10.0, 1e-9)); // 50 * 0.20
    });

    test('FIFO consumes the cheap layer first', () {
      final s = twoPrices(CostBasis.fifo);
      expect(s.byId('a')!.costPerMl, closeTo(0.20, 1e-9)); // 40 / 200

      drawMix(s, 50);
      // Entirely from the 0.10 layer.
      expect(s.mixLog.first.totalCost, closeTo(5.0, 1e-9));
      // 50 left at 0.10 plus 100 at 0.30 => 35 / 150.
      expect(s.byId('a')!.costPerMl, closeTo(35 / 150, 1e-9));
    });

    test('a FIFO draw can span two price layers', () {
      final s = twoPrices(CostBasis.fifo);
      drawMix(s, 150); // 100 at 0.10, then 50 at 0.30
      expect(s.mixLog.first.totalCost, closeTo(10 + 15, 1e-9));
      expect(s.byId('a')!.stockMl, closeTo(50, 1e-9));
      expect(s.byId('a')!.costPerMl, closeTo(0.30, 1e-9)); // only the dear
    });

    test('the two policies genuinely differ on the same ledger', () {
      final avg = twoPrices(CostBasis.movingAverage);
      final fifo = twoPrices(CostBasis.fifo);
      drawMix(avg, 100);
      drawMix(fifo, 100);
      expect(avg.mixLog.first.totalCost, closeTo(20, 1e-9));
      expect(fifo.mixLog.first.totalCost, closeTo(10, 1e-9));
    });

    test('switching basis is retroactive', () {
      final s = twoPrices(CostBasis.movingAverage);
      drawMix(s, 100);
      expect(s.mixLog.first.totalCost, closeTo(20, 1e-9));

      // updateSettings alone must be enough — the Settings screen promises
      // the change "applies to your whole history", and no other recompute
      // happens before the stale figures get persisted.
      s.updateSettings(Settings(costBasis: CostBasis.fifo));
      // The same historical mix now costs what the oldest liquid cost.
      expect(s.mixLog.first.totalCost, closeTo(10, 1e-9));
      expect(s.byId('a')!.costPerMl, closeTo(0.30, 1e-9));
      expect(s.stockValue, closeTo(30, 1e-9));
    });

    test('the old lifetime average no longer lingers after stock is used', () {
      // The bug this fixes: buy cheap, use it all, buy dear — the basis
      // should reflect what is in the bottle, not what was ever bought.
      final s = twoPrices(CostBasis.movingAverage);
      drawMix(s, 100, at: DateTime(2026, 1, 15)); // all of the cheap layer

      // Only the 0.30 purchase remains.
      expect(s.byId('a')!.stockMl, closeTo(100, 1e-9));
      expect(s.byId('a')!.costPerMl, closeTo(0.30, 1e-9));
      // A lifetime average would have said 0.20 forever.
    });

    test('drawing beyond stock is priced at the last known rate', () {
      final s = twoPrices(CostBasis.fifo);
      drawMix(s, 250); // 50 mL more than exists

      expect(s.byId('a')!.stockMl, closeTo(-50, 1e-9));
      // 100*0.10 + 100*0.30 + 50*0.30 assumed.
      expect(s.mixLog.first.totalCost, closeTo(10 + 30 + 15, 1e-9));
      expect(s.mixLog.first.costEstimated, isTrue);
      expect(s.byId('a')!.costPerMl, closeTo(0.30, 1e-9));
    });

    test('restocking after an overdraw does not re-price the deficit', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false)
        ..settings = Settings(costBasis: CostBasis.fifo);
      s.ingredients.add(flavor('a')..stockMl = 0);
      s.purchases.add(
        Purchase(
          id: 'p1',
          ingredientId: 'a',
          ingredientName: 'a',
          at: DateTime(2026, 1, 1),
          volumeMl: 100,
          cost: 10, // 0.10/mL
        ),
      );
      s.recomputeStock();

      drawMix(s, 150, at: DateTime(2026, 2, 1)); // 50 mL beyond stock
      expect(s.byId('a')!.stockMl, closeTo(-50, 1e-9));
      // 100 at 0.10 plus 50 assumed at 0.10.
      expect(s.mixLog.first.totalCost, closeTo(15, 1e-9));
      expect(s.byId('a')!.stockValue, closeTo(-5, 1e-9));

      // Restock 20 mL at triple the price. That only part-settles the 50
      // mL owed. The 30 mL still outstanding was charged at 0.10 and must
      // stay valued there — pricing it at 0.30 would invent cost that was
      // never spent and never charged.
      s.purchases.add(
        Purchase(
          id: 'p2',
          ingredientId: 'a',
          ingredientName: 'a',
          at: DateTime(2026, 3, 1),
          volumeMl: 20,
          cost: 6, // 0.30/mL
        ),
      );
      s.recomputeStock();

      expect(s.byId('a')!.stockMl, closeTo(-30, 1e-9));
      expect(s.byId('a')!.stockValue, closeTo(-3, 1e-9));
      // The historical mix is untouched: a later purchase cannot change
      // what an earlier mix cost.
      expect(s.mixLog.first.totalCost, closeTo(15, 1e-9));
    });

    test('a settled deficit leaves the new price in charge', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false)
        ..settings = Settings(costBasis: CostBasis.fifo);
      s.ingredients.add(flavor('a')..stockMl = 0);
      s.purchases.add(
        Purchase(
          id: 'p1',
          ingredientId: 'a',
          ingredientName: 'a',
          at: DateTime(2026, 1, 1),
          volumeMl: 100,
          cost: 10,
        ),
      );
      s.recomputeStock();
      drawMix(s, 150, at: DateTime(2026, 2, 1));

      // Restock enough to clear the 50 mL deficit and leave 50 mL on hand.
      s.purchases.add(
        Purchase(
          id: 'p2',
          ingredientId: 'a',
          ingredientName: 'a',
          at: DateTime(2026, 3, 1),
          volumeMl: 100,
          cost: 30, // 0.30/mL
        ),
      );
      s.recomputeStock();

      expect(s.byId('a')!.stockMl, closeTo(50, 1e-9));
      expect(s.byId('a')!.costPerMl, closeTo(0.30, 1e-9));
      expect(s.byId('a')!.stockValue, closeTo(15, 1e-9));
    });

    test('deficits at different rates blend before being settled', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false)
        ..settings = Settings(costBasis: CostBasis.fifo);
      s.ingredients.add(flavor('a')..stockMl = 0);
      s.purchases.add(
        Purchase(
          id: 'p1',
          ingredientId: 'a',
          ingredientName: 'a',
          at: DateTime(2026, 1, 1),
          volumeMl: 100,
          cost: 10, // 0.10/mL
        ),
      );
      s.recomputeStock();

      drawMix(s, 140, at: DateTime(2026, 2, 1)); // 40 mL over, at 0.10
      // Restock at 0.50, then overdraw again at that rate.
      s.purchases.add(
        Purchase(
          id: 'p2',
          ingredientId: 'a',
          ingredientName: 'a',
          at: DateTime(2026, 3, 1),
          volumeMl: 40, // exactly settles the first deficit
          cost: 20, // 0.50/mL
        ),
      );
      s.recomputeStock();
      drawMix(s, 60, at: DateTime(2026, 4, 1)); // all 60 beyond stock

      expect(s.byId('a')!.stockMl, closeTo(-60, 1e-9));
      // The second deficit accrued entirely at the 0.50 rate.
      expect(s.byId('a')!.stockValue, closeTo(-30, 1e-9));
    });

    test('restock preview matches what recording actually does', () {
      for (final basis in CostBasis.values) {
        final s = twoPrices(basis);
        drawMix(s, 150); // leaves 50 mL, and under FIFO only the dear layer

        final predicted = s.previewRestockBasis(
          ingredientId: 'a',
          volumeMl: 100,
          cost: 5, // 0.05/mL, far below anything already in the book
        );
        s.recordPurchase(ingredientId: 'a', volumeMl: 100, cost: 5);

        expect(
          s.byId('a')!.costPerMl,
          closeTo(predicted, 1e-9),
          reason: 'preview disagreed with reality under $basis',
        );
      }
    });

    test('the preview is basis-aware, not always a moving average', () {
      final avg = twoPrices(CostBasis.movingAverage);
      final fifo = twoPrices(CostBasis.fifo);
      drawMix(avg, 150);
      drawMix(fifo, 150);

      double preview(AppState s) =>
          s.previewRestockBasis(ingredientId: 'a', volumeMl: 100, cost: 5);

      // Same ledger, same pending purchase, genuinely different answers.
      // The old hand-rolled blend returned the moving-average figure for
      // both, so FIFO users were shown a number the app would not use.
      expect(preview(avg), isNot(closeTo(preview(fifo), 1e-6)));
    });

    test('preview folds shipping in and handles an empty ledger', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.ingredients.add(flavor('a')..stockMl = 0);
      s.recomputeStock();

      expect(
        s.previewRestockBasis(
          ingredientId: 'a',
          volumeMl: 100,
          cost: 10,
          shippingCost: 5,
        ),
        closeTo(0.15, 1e-9),
      );
      // A zero-volume restock is not a purchase; fall back to what we show.
      expect(
        s.previewRestockBasis(ingredientId: 'a', volumeMl: 0, cost: 10),
        closeTo(s.byId('a')!.costPerMl, 1e-9),
      );
    });

    test('an ingredient with no ledger costs nothing and holds nothing', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.ingredients.add(flavor('lonely')..stockMl = 0);
      s.recomputeStock();
      expect(s.byId('lonely')!.stockMl, 0);
      expect(s.byId('lonely')!.stockValue, 0);
      // Falls back to the bottle price for display.
      expect(s.byId('lonely')!.costPerMl, closeTo(0.10, 1e-9));
    });

    test('stock value equals volume times basis in both policies', () {
      for (final b in CostBasis.values) {
        final s = twoPrices(b);
        drawMix(s, 30);
        final e = s.byId('a')!;
        expect(e.stockValue, closeTo(e.stockMl * e.costPerMl, 1e-6));
      }
    });

    test('replay is deterministic when timestamps collide', () {
      SharedPreferences.setMockInitialValues({});
      final at = DateTime(2026, 1, 1);
      final s = AppState(autoLoad: false)
        ..settings = Settings(costBasis: CostBasis.fifo);
      s.ingredients.add(flavor('a')..stockMl = 0);
      for (final (id, cost) in [('p1', 10.0), ('p2', 30.0)]) {
        s.purchases.add(
          Purchase(
            id: id,
            ingredientId: 'a',
            ingredientName: 'a',
            at: at, // identical
            volumeMl: 100,
            cost: cost,
            prevStockMl: 0,
            prevCostPerMl: 0,
            prevAvgCostPerMl: 0,
          ),
        );
      }
      s.recomputeStock();
      final first = s.byId('a')!.costPerMl;
      s.purchases.setAll(0, s.purchases.reversed.toList());
      s.recomputeStock();
      // Ordering falls back to id, so list order does not change the answer.
      expect(s.byId('a')!.costPerMl, closeTo(first, 1e-9));
    });

    test('shipping still lands in the basis', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      s.ingredients.add(flavor('a')..stockMl = 0);
      s.recordPurchase(
        ingredientId: 'a',
        volumeMl: 100,
        cost: 10,
        shippingCost: 5,
      );
      expect(s.byId('a')!.costPerMl, closeTo(0.15, 1e-9));
    });

    test('basis setting round-trips', () {
      final back = Settings.fromJson(
        jsonDecode(jsonEncode(Settings(costBasis: CostBasis.fifo).toJson()))
            as Map<String, dynamic>,
      );
      expect(back.costBasis, CostBasis.fifo);
      expect(Settings.fromJson({}).costBasis, CostBasis.movingAverage);
    });
  });
}
