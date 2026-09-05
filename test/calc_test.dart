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
        () => s.restoreFromBackup('{"schema": 999}'),
        throwsA(isA<FormatException>()),
      );
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
          'schema': 1,
          'ingredients': [
            {'id': 'z', 'name': 'CAP Sweet Cream', 'kind': 3, 'density': 1.0},
          ],
        }),
      );
      expect(s.byId('z')!.brand, 'CAP');
      expect(s.byId('z')!.name, 'Sweet Cream');
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
        () => a.previewMerge('{"schema": 999}'),
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

      s.updateSettings(Settings(costBasis: CostBasis.fifo));
      s.recomputeStock();
      // The same historical mix now costs what the oldest liquid cost.
      expect(s.mixLog.first.totalCost, closeTo(10, 1e-9));
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
