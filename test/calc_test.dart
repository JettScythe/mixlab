import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixlab/models.dart';
import 'package:mixlab/state.dart';
import 'package:mixlab/widgets/ingredient_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    test('VG-carried flavor blends toward VG density', () {
      final s = Settings();
      expect(s.densityForCarrier(IngredientKind.flavor, 0), closeTo(1.0, 1e-9));
      expect(
        s.densityForCarrier(IngredientKind.flavor, 1),
        closeTo(1.261, 1e-9),
      );
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
      final f = flavor('a', stock: 100);
      s.ingredients.add(f);
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

  group('purchases (bug 9)', () {
    Ingredient vg() => Ingredient(
      id: 'v',
      name: 'VG',
      kind: IngredientKind.vg,
      density: 1.261,
      bottleSizeMl: 100,
      bottleCost: 10, // 0.10/mL
      stockMl: 100,
    );

    test('weighted average blends the cost basis', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final e = vg();
      s.ingredients.add(e);

      // 100 mL at 0.10 + 100 mL at 0.20 -> 0.15/mL
      s.recordPurchase(ingredientId: 'v', volumeMl: 100, cost: 20);
      expect(e.stockMl, closeTo(200, 1e-9));
      expect(e.costPerMl, closeTo(0.15, 1e-9));
    });

    test('replace mode adopts the new price outright', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final e = vg();
      s.ingredients.add(e);

      s.recordPurchase(
        ingredientId: 'v',
        volumeMl: 100,
        cost: 20,
        useWeightedAverage: false,
      );
      expect(e.costPerMl, closeTo(0.20, 1e-9));
    });

    test('undo restores stock and basis exactly', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final e = vg();
      s.ingredients.add(e);

      final p = s.recordPurchase(ingredientId: 'v', volumeMl: 100, cost: 20);
      expect(s.undoPurchase(p.id), isTrue);
      expect(e.stockMl, closeTo(100, 1e-9));
      expect(e.costPerMl, closeTo(0.10, 1e-9));
      expect(s.purchases, isEmpty);
    });
  });

  group('mix log', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('logMix deducts and undoMix restores exactly', () {
      final s = AppState(autoLoad: false);
      final f = flavor('a', stock: 10);
      s.ingredients.add(f);
      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: s.settings,
        flavors: [(f, 5)],
      );
      final log = s.logMix(r, label: 'Test');
      expect(f.stockMl, closeTo(5, 1e-9));
      expect(s.mixLog.length, 1);
      expect(s.undoMix(log.id), isTrue);
      expect(f.stockMl, closeTo(10, 1e-9));
      expect(s.mixLog, isEmpty);
    });

    test('short stock floors at zero and undo does not over-restore', () {
      final s = AppState(autoLoad: false);
      final f = flavor('a', stock: 2);
      s.ingredients.add(f);
      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: s.settings,
        flavors: [(f, 10)], // wants 10 mL, only 2 available
      );
      final log = s.logMix(r);
      expect(f.stockMl, 0);
      expect(log.lines.first.requestedMl, closeTo(10, 1e-9));
      expect(log.lines.first.deductedMl, closeTo(2, 1e-9));
      s.undoMix(log.id);
      expect(f.stockMl, closeTo(2, 1e-9)); // not 10
    });

    test('deleteLogEntry leaves stock alone', () {
      final s = AppState(autoLoad: false);
      final f = flavor('a', stock: 10);
      s.ingredients.add(f);
      final r = calculateMix(
        amountMl: 100,
        targetNic: 0,
        targetVgPercent: 50,
        settings: s.settings,
        flavors: [(f, 5)],
      );
      final log = s.logMix(r);
      s.deleteLogEntry(log.id);
      expect(s.mixLog, isEmpty);
      expect(f.stockMl, closeTo(5, 1e-9));
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

    test(
      'export/import round-trip preserves counts and is idempotent',
      () async {
        SharedPreferences.setMockInitialValues({});
        final a = AppState(autoLoad: false);
        a.ingredients.add(flavor('a'));
        a.recipes.add(Recipe(id: 'r', name: 'R'));
        final dump = a.exportJson();

        final b = AppState(autoLoad: false);
        await b.importJson(dump);
        expect(b.ingredients.length, 1);
        expect(b.recipes.length, 1);

        await b.importJson(dump);
        expect(b.ingredients.length, 1);
        expect(b.recipes.length, 1);
      },
    );

    test('rejects a newer schema', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      expect(
        () => s.importJson('{"schema": 999}'),
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
      await s.importJson(
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
      expect(prefs.getInt('schema_version'), 4);
    });

    test('v3 backups import with the new fields defaulted', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      await s.importJson(
        jsonEncode({
          'schema': 3,
          'mixLog': [
            {
              'id': 'old',
              'mixedAt': '2026-01-01T00:00:00.000',
              'label': 'Legacy',
              'lines': <Object>[],
            },
          ],
        }),
      );
      final l = s.mixLog.single;
      expect(l.rating, isNull);
      expect(l.tastingNotes, '');
      expect(l.recipeId, isNull);
    });
  });
  group('recipe detail aggregates', () {
    test('spend and volume sum only that recipe\'s mixes', () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState(autoLoad: false);
      final f = flavor('a', stock: 1000); // 0.10/mL
      s.ingredients.add(f);
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
}
