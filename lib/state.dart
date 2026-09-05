import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

int _idCounter = 0;
String newId() => '${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';

class AppState extends ChangeNotifier {
  AppState({bool autoLoad = true}) {
    if (autoLoad) {
      load();
    } else {
      _ready = true;
    }
  }

  static const _kSchema = 'schema_version';
  static const _kIngredients = 'ingredients_v1';
  static const _kSettings = 'settings_v1';
  static const _kRecipes = 'recipes_v1';
  static const _kMixLog = 'mixlog_v1';
  static const _kPurchases = 'purchases_v1';
  static const _kAdjustments = 'adjustments_v1';
  static const currentSchema = 9;

  static const _allKeys = [
    _kSchema,
    _kIngredients,
    _kSettings,
    _kRecipes,
    _kMixLog,
    _kPurchases,
    _kAdjustments,
  ];

  final List<Ingredient> ingredients = [];
  final List<Recipe> recipes = [];
  final List<MixLog> mixLog = []; // newest first
  final List<Purchase> purchases = []; // newest first
  final List<StockAdjustment> adjustments = []; // newest first
  Settings settings = Settings();

  bool _ready = false;
  bool get isReady => _ready;

  /// Non-null when load() failed. The UI shows a recovery screen instead of
  /// hanging on a spinner forever.
  String? loadError;

  /// Non-null when the last write failed. Surfaced as a snackbar.
  String? lastSaveError;
  int saveErrorToken = 0;

  Recipe? _pendingRecipe;
  Recipe? get pendingRecipe => _pendingRecipe;
  int recipeLoadToken = 0;

  void requestLoadRecipe(Recipe r) {
    _pendingRecipe = r;
    recipeLoadToken++;
    notifyListeners();
  }

  // ---------------------------------------------------------------- loading

  Future<void> load() async {
    loadError = null;
    var seeded = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrate(prefs);

      ingredients.clear();
      recipes.clear();
      mixLog.clear();
      purchases.clear();
      adjustments.clear();

      final raw = prefs.getString(_kIngredients);
      if (raw != null) {
        ingredients.addAll(
          (jsonDecode(raw) as List).map(
            (e) => Ingredient.fromJson(e as Map<String, dynamic>),
          ),
        );
      } else {
        _seedIngredients();
        seeded = true;
      }

      final s = prefs.getString(_kSettings);
      if (s != null) {
        settings = Settings.fromJson(jsonDecode(s) as Map<String, dynamic>);
      }

      final rraw = prefs.getString(_kRecipes);
      if (rraw != null) {
        recipes.addAll(
          (jsonDecode(rraw) as List).map(
            (e) => Recipe.fromJson(e as Map<String, dynamic>),
          ),
        );
      } else {
        _seedRecipes();
        seeded = true;
      }

      final lraw = prefs.getString(_kMixLog);
      if (lraw != null) {
        mixLog.addAll(
          (jsonDecode(lraw) as List).map(
            (e) => MixLog.fromJson(e as Map<String, dynamic>),
          ),
        );
        mixLog.sort((a, b) => b.mixedAt.compareTo(a.mixedAt));
      }

      final praw = prefs.getString(_kPurchases);
      if (praw != null) {
        purchases.addAll(
          (jsonDecode(praw) as List).map(
            (e) => Purchase.fromJson(e as Map<String, dynamic>),
          ),
        );
        purchases.sort((a, b) => b.at.compareTo(a.at));
      }

      final araw = prefs.getString(_kAdjustments);
      if (araw != null) {
        adjustments.addAll(
          (jsonDecode(araw) as List).map(
            (e) => StockAdjustment.fromJson(e as Map<String, dynamic>),
          ),
        );
        adjustments.sort((a, b) => b.at.compareTo(a.at));
      }

      // Stock is derived, so the persisted snapshot is authoritative only
      // until the ledger has been replayed.
      recomputeStock();
    } catch (e, st) {
      loadError = e.toString();
      debugPrint('AppState.load failed: $e');
      debugPrintStack(stackTrace: st);
    } finally {
      _ready = true;
      notifyListeners();
    }
    if (seeded && loadError == null) await _save();
  }

  /// Absent version key with existing data means v1. A fresh install is
  /// stamped at [currentSchema] directly.
  Future<void> _migrate(SharedPreferences prefs) async {
    final hasData = prefs.getString(_kIngredients) != null;
    var v = prefs.getInt(_kSchema) ?? (hasData ? 1 : currentSchema);

    if (v > currentSchema) {
      debugPrint(
        'Stored data is schema v$v, newer than this build '
        '(v$currentSchema); loading as-is.',
      );
      return;
    }

    List<Map<String, dynamic>> decode(String? raw) => raw == null
        ? <Map<String, dynamic>>[]
        : (jsonDecode(raw) as List).cast<Map<String, dynamic>>().toList();

    if (v < 2) {
      // v2: pull recognised brand shorthands out of the combined name.
      final raw = prefs.getString(_kIngredients);
      if (raw != null) {
        final list = decode(raw);
        for (final j in list) {
          final existing = j['brand'] as String?;
          if (existing != null && existing.isNotEmpty) continue;
          final (b, n) = splitBrand(j['name'] as String? ?? '');
          j['brand'] = b;
          j['name'] = n;
        }
        await prefs.setString(_kIngredients, jsonEncode(list));
        debugPrint('Migrated ${list.length} ingredients to schema v2.');
      }
      v = 2;
    }

    if (v < 3) {
      // v3 adds avgCostPerMl, purchases, and achieved nic/VG on mix logs.
      // All additive with safe defaults.
      v = 3;
    }

    if (v < 4) {
      // v4 adds recipeId, rating and tasting notes to mix logs. Old
      // entries can often be linked to a recipe by matching the label
      // they were mixed under.
      final rawLog = prefs.getString(_kMixLog);
      final rawRec = prefs.getString(_kRecipes);
      if (rawLog != null && rawRec != null) {
        final byName = <String, String>{};
        for (final r in decode(rawRec)) {
          final n = (r['name'] as String? ?? '').trim().toLowerCase();
          if (n.isNotEmpty) byName.putIfAbsent(n, () => r['id'] as String);
        }
        final logs = decode(rawLog);
        var linked = 0;
        for (final l in logs) {
          if (l['recipeId'] != null) continue;
          final id = byName[(l['label'] as String? ?? '').trim().toLowerCase()];
          if (id != null) {
            l['recipeId'] = id;
            linked++;
          }
        }
        if (linked > 0) {
          await prefs.setString(_kMixLog, jsonEncode(logs));
          debugPrint('Linked $linked mix log entries to recipes (v4).');
        }
      }
      v = 4;
    }

    if (v < 5) {
      // v5 adds additive/thinner kinds and per-recipe percent mode. The
      // bump exists so an older build refuses v5 data rather than crashing
      // on an unknown enum index.
      v = 5;
    }

    if (v < 6) {
      // v6 adds Recipe.baseMode. Existing recipes were mixed to their
      // stored ratio, which is the default.
      v = 6;
    }

    if (v < 7) {
      // v7 adds nicotine strength units and the salt flag. Existing bases
      // were all mg/mL, which is the default. The bump stops an older
      // build reading a mg/g base as mg/mL.
      v = 7;
    }

    if (v < 8) {
      // v8 adds hardware costs on mixes and shipping on purchases. Both
      // default to zero, so existing figures are unchanged.
      v = 8;
    }

    if (v < 9) {
      // v9 makes stock derived from an append-only ledger. Existing
      // stockMl already reflects past purchases and mixes, so replaying
      // those alone would double-count or lose history. Instead, replay
      // what the ledger gives, then write one opening-balance adjustment
      // per ingredient for the difference — so derived stock comes out
      // exactly equal to what the user sees today.
      final rawIng = prefs.getString(_kIngredients);
      if (rawIng != null) {
        final ings = decode(rawIng);

        final replayed = <String, double>{};
        for (final p in decode(prefs.getString(_kPurchases))) {
          final id = p['ingredientId'] as String?;
          if (id == null) continue;
          replayed[id] =
              (replayed[id] ?? 0) + ((p['volumeMl'] as num?)?.toDouble() ?? 0);
        }
        for (final l in decode(prefs.getString(_kMixLog))) {
          for (final line in (l['lines'] as List? ?? const [])) {
            final m = line as Map<String, dynamic>;
            final id = m['ingredientId'] as String?;
            if (id == null) continue;
            replayed[id] =
                (replayed[id] ?? 0) -
                ((m['requestedMl'] as num?)?.toDouble() ?? 0);
          }
        }

        final now = DateTime.now().toIso8601String();
        final opening = <Map<String, dynamic>>[];
        for (final j in ings) {
          final id = j['id'] as String;
          final current = (j['stockMl'] as num?)?.toDouble() ?? 0;
          final delta = current - (replayed[id] ?? 0);
          if (delta.abs() < 1e-9) continue;

          // Carry the existing cost basis so per-mL costs do not reset.
          final avg = (j['avgCostPerMl'] as num?)?.toDouble() ?? 0;
          final size = (j['bottleSizeMl'] as num?)?.toDouble() ?? 0;
          final price = (j['bottleCost'] as num?)?.toDouble() ?? 0;
          final basis = avg > 0 ? avg : (size > 0 ? price / size : 0.0);

          opening.add({
            'id': 'opening-$id',
            'ingredientId': id,
            'ingredientName': j['name'] ?? '',
            'at': now,
            'deltaMl': delta,
            'reason': AdjustReason.opening.index,
            'costPerMl': delta > 0 ? basis : 0,
            'note': 'Opening balance, recorded when stock became a ledger.',
          });
        }

        if (opening.isNotEmpty) {
          final existing = decode(prefs.getString(_kAdjustments))
            ..addAll(opening);
          await prefs.setString(_kAdjustments, jsonEncode(existing));
          debugPrint('Wrote ${opening.length} opening balances (v9).');
        }
      }
      v = 9;
    }

    await prefs.setInt(_kSchema, v);
  }

  // ----------------------------------------------------------------- writing

  /// Writes are chained so overlapping mutations can never interleave, and
  /// failures surface instead of vanishing into an unawaited future.
  Future<void> _writeChain = Future<void>.value();

  Future<void> _save() {
    _writeChain = _writeChain.then((_) => _write()).catchError((
      Object e,
      StackTrace st,
    ) {
      lastSaveError = e.toString();
      saveErrorToken++;
      debugPrint('AppState save failed: $e');
      debugPrintStack(stackTrace: st);
      Future.microtask(notifyListeners);
    });
    return _writeChain;
  }

  Future<void> _write() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSchema, currentSchema);
    await prefs.setString(
      _kIngredients,
      jsonEncode(ingredients.map((e) => e.toJson()).toList()),
    );
    await prefs.setString(_kSettings, jsonEncode(settings.toJson()));
    await prefs.setString(
      _kRecipes,
      jsonEncode(recipes.map((e) => e.toJson()).toList()),
    );
    await prefs.setString(
      _kMixLog,
      jsonEncode(mixLog.map((e) => e.toJson()).toList()),
    );
    await prefs.setString(
      _kPurchases,
      jsonEncode(purchases.map((e) => e.toJson()).toList()),
    );
    await prefs.setString(
      _kAdjustments,
      jsonEncode(adjustments.map((e) => e.toJson()).toList()),
    );
  }

  /// Awaits any pending write. Use in tests and before export.
  Future<void> flush() => _writeChain;

  // ------------------------------------------------------------ export/import

  String exportJson() => const JsonEncoder.withIndent('  ').convert({
    'app': 'mixlab',
    'schema': currentSchema,
    'exportedAt': DateTime.now().toIso8601String(),
    'settings': settings.toJson(),
    'ingredients': ingredients.map((e) => e.toJson()).toList(),
    'recipes': recipes.map((e) => e.toJson()).toList(),
    'mixLog': mixLog.map((e) => e.toJson()).toList(),
    'purchases': purchases.map((e) => e.toJson()).toList(),
    'adjustments': adjustments.map((e) => e.toJson()).toList(),
  });

  /// Raw stored strings, for salvaging data when load() has failed.
  Future<String> rawDump() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <String, Object?>{};
    for (final k in _allKeys) {
      out[k] = prefs.get(k);
    }
    return const JsonEncoder.withIndent('  ').convert(out);
  }

  Future<String> importJson(String raw, {bool replace = false}) async {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Not an object at the top level.');
    }
    final schema = (decoded['schema'] as num?)?.toInt() ?? 1;
    if (schema > currentSchema) {
      throw FormatException(
        'Backup schema v$schema is newer than this build (v$currentSchema).',
      );
    }

    if (replace) {
      ingredients.clear();
      recipes.clear();
      mixLog.clear();
      purchases.clear();
      adjustments.clear();
    }

    var ni = 0, nr = 0, nl = 0, np = 0, na = 0;

    final haveIng = ingredients.map((e) => e.id).toSet();
    for (final e in (decoded['ingredients'] as List? ?? const [])) {
      final j = e as Map<String, dynamic>;
      if (schema < 2 && ((j['brand'] as String?) ?? '').isEmpty) {
        final (b, n) = splitBrand(j['name'] as String? ?? '');
        j['brand'] = b;
        j['name'] = n;
      }
      final ing = Ingredient.fromJson(j);
      if (haveIng.add(ing.id)) {
        ingredients.add(ing);
        ni++;
      }
    }

    final haveRec = recipes.map((e) => e.id).toSet();
    for (final e in (decoded['recipes'] as List? ?? const [])) {
      final r = Recipe.fromJson(e as Map<String, dynamic>);
      if (haveRec.add(r.id)) {
        recipes.add(r);
        nr++;
      }
    }

    final haveLog = mixLog.map((e) => e.id).toSet();
    for (final e in (decoded['mixLog'] as List? ?? const [])) {
      final l = MixLog.fromJson(e as Map<String, dynamic>);
      if (haveLog.add(l.id)) {
        mixLog.add(l);
        nl++;
      }
    }

    final havePur = purchases.map((e) => e.id).toSet();
    for (final e in (decoded['purchases'] as List? ?? const [])) {
      final p = Purchase.fromJson(e as Map<String, dynamic>);
      if (havePur.add(p.id)) {
        purchases.add(p);
        np++;
      }
    }

    final haveAdj = adjustments.map((e) => e.id).toSet();
    for (final e in (decoded['adjustments'] as List? ?? const [])) {
      final a = StockAdjustment.fromJson(e as Map<String, dynamic>);
      if (haveAdj.add(a.id)) {
        adjustments.add(a);
        na++;
      }
    }

    // A pre-v9 backup carries stock as a number with no ledger behind it.
    // Give each imported ingredient an opening balance so the replay
    // reproduces what the backup said.
    if (schema < 9) {
      final now = DateTime.now();
      for (final e in (decoded['ingredients'] as List? ?? const [])) {
        final j = e as Map<String, dynamic>;
        final id = j['id'] as String;
        final stock = (j['stockMl'] as num?)?.toDouble() ?? 0;
        if (stock.abs() < 1e-9) continue;
        final openingId = 'opening-import-$id';
        if (!haveAdj.add(openingId)) continue;
        final avg = (j['avgCostPerMl'] as num?)?.toDouble() ?? 0;
        final size = (j['bottleSizeMl'] as num?)?.toDouble() ?? 0;
        final price = (j['bottleCost'] as num?)?.toDouble() ?? 0;
        adjustments.add(
          StockAdjustment(
            id: openingId,
            ingredientId: id,
            ingredientName: j['name'] as String? ?? '',
            at: now,
            deltaMl: stock,
            reason: AdjustReason.opening,
            costPerMl: avg > 0 ? avg : (size > 0 ? price / size : 0),
            note: 'Opening balance from an imported pre-ledger backup.',
          ),
        );
        na++;
      }
    }

    mixLog.sort((a, b) => b.mixedAt.compareTo(a.mixedAt));
    purchases.sort((a, b) => b.at.compareTo(a.at));
    adjustments.sort((a, b) => b.at.compareTo(a.at));

    if (decoded['settings'] != null) {
      settings = Settings.fromJson(decoded['settings'] as Map<String, dynamic>);
    }

    recomputeStock();
    notifyListeners();
    await _save();
    return 'Imported $ni ingredients, $nr recipes, $nl mixes, $np restocks, '
        '$na adjustments.';
  }

  Future<void> factoryReset() async {
    ingredients.clear();
    recipes.clear();
    mixLog.clear();
    purchases.clear();
    adjustments.clear();
    settings = Settings();
    _seedIngredients();
    _seedRecipes();
    loadError = null;
    notifyListeners();
    await _save();
  }

  /// Wipes storage entirely, for unrecoverable load failures.
  Future<void> hardReset() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in _allKeys) {
      await prefs.remove(k);
    }
    await load();
  }

  // ----------------------------------------------------------------- seeding

  void _seedIngredients() {
    Ingredient mk(
      String name,
      IngredientKind kind, {
      double carrierVg = 0,
      double size = 0,
      double cost = 0,
      double nic = 0,
    }) => Ingredient(
      id: newId(),
      name: name,
      kind: kind,
      carrierVg: carrierVg,
      density: settings.densityForCarrier(kind, carrierVg),
      bottleSizeMl: size,
      bottleCost: cost,
      nicStrength: nic,
    );

    final seeded = [
      mk('PG', IngredientKind.pg, size: 500, cost: 12),
      mk('VG', IngredientKind.vg, size: 500, cost: 14),
      mk(
        'Nic 100mg (PG)',
        IngredientKind.nicotine,
        size: 120,
        cost: 25,
        nic: 100,
      ),
    ];
    ingredients.addAll(seeded);

    // Stock enters through the ledger, never by assignment.
    final now = DateTime.now();
    for (final e in seeded) {
      if (e.bottleSizeMl <= 0) continue;
      adjustments.add(
        StockAdjustment(
          id: newId(),
          ingredientId: e.id,
          ingredientName: e.displayName,
          at: now,
          deltaMl: e.bottleSizeMl,
          reason: AdjustReason.opening,
          costPerMl: e.bottleCost / e.bottleSizeMl,
          note: 'Starting stock.',
        ),
      );
    }
    recomputeStock();
  }

  /// r/DIY_eJuice classics, circa 2014-2016. Percentages are the commonly
  /// posted versions — verify against ELR before trusting them.
  void _seedRecipes() {
    RecipeFlavor rf(Ingredient i, double pct) =>
        RecipeFlavor(ingredientId: i.id, name: i.displayName, percent: pct);

    final sbRipe = ensureFlavor('TFA', 'Strawberry (Ripe)');
    final vbic = ensureFlavor('TFA', 'Vanilla Bean Ice Cream');
    final bananaCream = ensureFlavor('LA', 'Banana Cream');
    final custard = ensureFlavor('CAP', 'Vanilla Custard v1');
    final sweetCream = ensureFlavor('CAP', 'Sweet Cream');
    final ry4 = ensureFlavor('TFA', 'RY4 Double');
    final graham = ensureFlavor('TFA', 'Graham Cracker (Clear)');
    final bourbon = ensureFlavor('TFA', 'Kentucky Bourbon');
    final coconut = ensureFlavor('FW', 'Coconut');
    final almond = ensureFlavor('FA', 'Almond');
    final brownSugar = ensureFlavor('TFA', 'Brown Sugar');
    final fruitCircles = ensureFlavor('TFA', 'Fruit Circles');

    Recipe r(String name, String notes, List<RecipeFlavor> flavors) => Recipe(
      id: newId(),
      name: name,
      notes: notes,
      batchMl: 30,
      targetNic: 3,
      targetVgPercent: 70,
      flavors: flavors,
    );

    recipes.addAll([
      r(
        'Mustard Milk',
        "u/Vurve's 2014 strawberry milk — the recipe that made TFA "
            'Strawberry Ripe famous. Shake-and-vape friendly; some versions '
            'run 6/6.',
        [rf(sbRipe, 8), rf(vbic, 6)],
      ),
      r(
        'Nana Cream',
        "Botboy141's homage to the Bombies classic. Commonly posted at 6/4; "
            'add 2% Vanilla Bean Ice Cream for a richer take.',
        [rf(bananaCream, 6), rf(sbRipe, 4)],
      ),
      r(
        'Unicorn Milk (clone)',
        'Cuttwood-style strawberry cream. Steep 1-2 weeks.',
        [rf(sbRipe, 6), rf(custard, 4), rf(vbic, 4), rf(sweetCream, 2)],
      ),
      r('Tribeca (clone)', 'Halo-style RY4 tobacco. Steep 2+ weeks.', [
        rf(ry4, 8),
        rf(graham, 2),
        rf(custard, 2),
      ]),
      r(
        'Castle Long (clone)',
        'Five Pawns-style coconut-almond-bourbon custard. Long steep, '
            '3+ weeks.',
        [
          rf(custard, 3),
          rf(bourbon, 2),
          rf(coconut, 2),
          rf(almond, 1),
          rf(brownSugar, 1),
        ],
      ),
      r(
        'Looper (clone)',
        'Fruit-loops-and-milk in the style of the old Looper clones.',
        [rf(fruitCircles, 10), rf(vbic, 3)],
      ),
    ]);
  }

  Ingredient ensureFlavor(String brand, String name) {
    final existing = flavorByName('$brand $name'.trim());
    if (existing != null) return existing;
    final ing = Ingredient(
      id: newId(),
      name: name,
      brand: brand,
      kind: IngredientKind.flavor,
      density: settings.densityForCarrier(IngredientKind.flavor, 0),
    );
    ingredients.add(ing);
    return ing;
  }

  // ------------------------------------------------------------------ ledger

  /// Recomputes derived stock and cost basis for every ingredient in one
  /// pass over the ledger. Called after any mutation that touches it.
  ///
  /// O(events + ingredients), so cheap enough to run eagerly rather than
  /// caching per ingredient and risking staleness.
  void recomputeStock() {
    final vol = <String, double>{};
    final costVol = <String, double>{};
    final costSum = <String, double>{};

    for (final p in purchases) {
      vol[p.ingredientId] = (vol[p.ingredientId] ?? 0) + p.volumeMl;
      if (p.volumeMl > 0) {
        costVol[p.ingredientId] = (costVol[p.ingredientId] ?? 0) + p.volumeMl;
        costSum[p.ingredientId] = (costSum[p.ingredientId] ?? 0) + p.totalCost;
      }
    }

    for (final l in mixLog) {
      for (final line in l.lines) {
        final id = line.ingredientId;
        if (id == null) continue;
        vol[id] = (vol[id] ?? 0) - line.requestedMl;
      }
    }

    for (final a in adjustments) {
      vol[a.ingredientId] = (vol[a.ingredientId] ?? 0) + a.deltaMl;
      if (a.deltaMl > 0 && a.costPerMl > 0) {
        costVol[a.ingredientId] = (costVol[a.ingredientId] ?? 0) + a.deltaMl;
        costSum[a.ingredientId] =
            (costSum[a.ingredientId] ?? 0) + a.deltaMl * a.costPerMl;
      }
    }

    for (final e in ingredients) {
      e.stockMl = vol[e.id] ?? 0;
      final cv = costVol[e.id] ?? 0;
      e.avgCostPerMl = cv > 0 ? (costSum[e.id] ?? 0) / cv : 0;
    }
  }

  /// Full ledger for one ingredient, oldest first, with running balance.
  List<StockLedgerEntry> ledgerFor(String ingredientId) {
    final raw = <(DateTime, double, String, dynamic, String, String?, bool)>[];

    for (final p in purchases) {
      if (p.ingredientId != ingredientId) continue;
      raw.add((
        p.at,
        p.volumeMl,
        'Restocked',
        adjustReasonIcon(AdjustReason.other),
        '${money(p.totalCost, settings)}'
            '${p.shippingCost > 0 ? ' incl. ${money(p.shippingCost, settings)} shipping' : ''}',
        p.id,
        true,
      ));
    }

    for (final l in mixLog) {
      for (final line in l.lines) {
        if (line.ingredientId != ingredientId) continue;
        raw.add((
          l.mixedAt,
          -line.requestedMl,
          'Mixed "${l.label}"',
          adjustReasonIcon(AdjustReason.other),
          '${line.grams.toStringAsFixed(2)} g',
          l.id,
          true,
        ));
      }
    }

    for (final a in adjustments) {
      if (a.ingredientId != ingredientId) continue;
      raw.add((
        a.at,
        a.deltaMl,
        adjustReasonLabel(a.reason),
        adjustReasonIcon(a.reason),
        a.note,
        a.id,
        a.reason != AdjustReason.opening,
      ));
    }

    raw.sort((x, y) => x.$1.compareTo(y.$1));

    var balance = 0.0;
    return [
      for (final r in raw)
        StockLedgerEntry(
          at: r.$1,
          deltaMl: r.$2,
          label: r.$3,
          icon: r.$4 as dynamic,
          detail: r.$5,
          sourceId: r.$6,
          canUndo: r.$7,
          balanceAfter: balance += r.$2,
        ),
    ];
  }

  List<Ingredient> get negativeStock => [
    for (final e in ingredients)
      if (e.stockIsNegative) e,
  ];

  // ----------------------------------------------------------------- queries

  Ingredient? byId(String? id) {
    if (id == null) return null;
    for (final e in ingredients) {
      if (e.id == id) return e;
    }
    return null;
  }

  Ingredient? flavorByName(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final e in ingredients) {
      if (!isConcentrate(e.kind)) continue;
      if (e.displayName.toLowerCase() == q || e.name.toLowerCase() == q) {
        return e;
      }
    }
    return null;
  }

  /// Existing ingredient with the same brand + name, ignoring [exceptId].
  Ingredient? findDuplicate(String brand, String name, {String? exceptId}) {
    final key = '${brand.trim().toLowerCase()}|${name.trim().toLowerCase()}';
    for (final e in ingredients) {
      if (e.id == exceptId) continue;
      if (e.dedupKey == key) return e;
    }
    return null;
  }

  Recipe? recipeById(String? id) {
    if (id == null) return null;
    for (final r in recipes) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Another recipe with the same name, ignoring [exceptId]. Not blocking —
  /// duplicate names are legal, just worth flagging.
  Recipe? recipeByName(String name, {String? exceptId}) {
    final q = name.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final r in recipes) {
      if (r.id == exceptId) continue;
      if (r.name.trim().toLowerCase() == q) return r;
    }
    return null;
  }

  List<Recipe> recipesUsing(String ingredientId) => [
    for (final r in recipes)
      if (r.flavors.any((f) => f.ingredientId == ingredientId)) r,
  ];

  int mixesUsing(String ingredientId) => mixLog
      .where((l) => l.lines.any((x) => x.ingredientId == ingredientId))
      .length;

  List<MixLog> mixesForRecipe(String recipeId) => [
    for (final l in mixLog)
      if (l.recipeId == recipeId) l,
  ];

  int mixCountForRecipe(String recipeId) => mixesForRecipe(recipeId).length;

  /// Most recent mix of a recipe, or null if never mixed.
  DateTime? lastMixedForRecipe(String recipeId) {
    DateTime? best;
    for (final l in mixLog) {
      if (l.recipeId != recipeId) continue;
      if (best == null || l.mixedAt.isAfter(best)) best = l.mixedAt;
    }
    return best;
  }

  /// Mean rating across rated mixes of a recipe, or null if none are rated.
  double? averageRatingForRecipe(String recipeId) {
    var sum = 0, n = 0;
    for (final l in mixLog) {
      if (l.recipeId != recipeId || l.rating == null) continue;
      sum += l.rating!;
      n++;
    }
    return n == 0 ? null : sum / n;
  }

  int get ratedMixCount => mixLog.where((l) => l.rating != null).length;

  /// Rebuilds a recipe from what was actually mixed, so a log entry can be
  /// pushed back through the calculator. Flavor percentages are derived
  /// from the volumes requested at mix time, not from the current recipe —
  /// a remix reproduces that bottle even if the recipe has since changed.
  ///
  /// The returned recipe carries a synthetic id, so the calculator treats
  /// it as unsaved rather than offering to overwrite anything.
  Recipe recipeFromLog(MixLog l) {
    final flavors = <RecipeFlavor>[];
    for (final line in l.lines) {
      final ing = byId(line.ingredientId);
      if (ing == null || !isConcentrate(ing.kind)) continue;
      if (line.requestedMl <= 0 || l.batchMl <= 0) continue;
      flavors.add(
        RecipeFlavor(
          ingredientId: ing.id,
          name: ing.displayName,
          percent: roundPercent(line.requestedMl / l.batchMl * 100),
        ),
      );
    }
    return Recipe(
      id: 'remix:${l.id}',
      name: l.label,
      notes: l.tastingNotes,
      batchMl: l.batchMl,
      targetNic: l.targetNic,
      targetVgPercent: l.targetVgPercent,
      flavors: flavors,
    );
  }

  List<Ingredient> ofKind(IngredientKind k) =>
      ingredients.where((e) => e.kind == k).toList();

  Ingredient? firstOfKind(IngredientKind k) {
    final list = ofKind(k);
    return list.isEmpty ? null : list.first;
  }

  /// Everything addable by percentage: flavors, additives and thinners.
  List<Ingredient> get concentrates => [
    for (final e in ingredients)
      if (isConcentrate(e.kind)) e,
  ];

  List<String> get brands {
    final set = <String>{};
    for (final e in ingredients) {
      if (e.brand.isNotEmpty) set.add(e.brand);
    }
    final list = set.toList()..sort();
    return list;
  }

  List<Ingredient> get suspectDensities => [
    for (final e in ingredients)
      if (e.densityLooksWrong(settings)) e,
  ];

  double get stockValue =>
      ingredients.fold(0.0, (a, e) => a + e.stockMl * e.costPerMl);

  double get lifetimeMixCost => mixLog.fold(0.0, (a, l) => a + l.totalCost);

  double get lifetimeHardwareCost =>
      mixLog.fold(0.0, (a, l) => a + l.hardwareCost);

  double get lifetimeSpend => purchases.fold(0.0, (a, p) => a + p.totalCost);

  /// Largest batch of [r] mixable from current stock, or null if unlimited.
  double? capacityFor(Recipe r) {
    final ref = r.batchMl > 0 ? r.batchMl : 30.0;
    final result = calculateMix(
      amountMl: ref,
      targetNic: r.targetNic,
      targetVgPercent: r.targetVgPercent,
      settings: settings,
      percentMode: r.percentMode,
      baseMode: r.baseMode,
      nic: firstOfKind(IngredientKind.nicotine),
      pg: firstOfKind(IngredientKind.pg),
      vg: firstOfKind(IngredientKind.vg),
      flavors: [
        for (final f in r.flavors)
          if (byId(f.ingredientId) != null) (byId(f.ingredientId)!, f.percent),
      ],
    );
    return maxBatchMl(result, ref, ingredients);
  }

  /// True when the recipe can be mixed at its stated batch size right now.
  bool canMakeNow(Recipe r) {
    if (r.flavors.any((f) => byId(f.ingredientId) == null)) return false;
    final cap = capacityFor(r);
    return cap == null || cap >= (r.batchMl > 0 ? r.batchMl : 30.0) - 1e-9;
  }

  // ---------------------------------------------------------------- mutation

  void upsertIngredient(Ingredient ing) {
    final i = ingredients.indexWhere((e) => e.id == ing.id);
    if (i >= 0) {
      ingredients[i] = ing;
    } else {
      ingredients.add(ing);
    }
    recomputeStock();
    notifyListeners();
    _save();
  }

  /// Removes an ingredient and returns it plus its index, so the caller can
  /// offer an undo. Its ledger events are left alone, so restoring brings
  /// the stock back exactly.
  (Ingredient, int)? removeIngredient(String id) {
    final i = ingredients.indexWhere((e) => e.id == id);
    if (i < 0) return null;
    final removed = ingredients.removeAt(i);
    notifyListeners();
    _save();
    return (removed, i);
  }

  void restoreIngredient(Ingredient ing, int index) {
    ingredients.insert(index.clamp(0, ingredients.length), ing);
    recomputeStock();
    notifyListeners();
    _save();
  }

  /// Records a restock. Stock and cost basis are derived, so this only
  /// appends to the ledger.
  Purchase recordPurchase({
    required String ingredientId,
    required double volumeMl,
    required double cost,
    double shippingCost = 0,
  }) {
    final ing = byId(ingredientId)!;
    final p = Purchase(
      id: newId(),
      ingredientId: ingredientId,
      ingredientName: ing.displayName,
      at: DateTime.now(),
      volumeMl: volumeMl,
      cost: cost,
      shippingCost: shippingCost,
      prevStockMl: ing.stockMl,
      prevCostPerMl: ing.costPerMl,
      prevAvgCostPerMl: ing.avgCostPerMl,
    );
    purchases.insert(0, p);
    recomputeStock();
    notifyListeners();
    _save();
    return p;
  }

  /// Removes a purchase from the ledger. Stock and cost fall out correctly
  /// from the replay, so there is nothing to restore by hand.
  bool undoPurchase(String purchaseId) {
    final i = purchases.indexWhere((e) => e.id == purchaseId);
    if (i < 0) return false;
    purchases.removeAt(i);
    recomputeStock();
    notifyListeners();
    _save();
    return true;
  }

  StockAdjustment addAdjustment({
    required String ingredientId,
    required double deltaMl,
    AdjustReason reason = AdjustReason.correction,
    double costPerMl = 0,
    String note = '',
  }) {
    final ing = byId(ingredientId)!;
    final a = StockAdjustment(
      id: newId(),
      ingredientId: ingredientId,
      ingredientName: ing.displayName,
      at: DateTime.now(),
      deltaMl: deltaMl,
      reason: reason,
      costPerMl: costPerMl,
      note: note,
    );
    adjustments.insert(0, a);
    recomputeStock();
    notifyListeners();
    _save();
    return a;
  }

  /// Convenience: writes whatever adjustment makes derived stock equal
  /// [targetMl]. This is how "I counted the bottle" gets recorded.
  StockAdjustment setStockTo(
    String ingredientId,
    double targetMl, {
    String note = '',
  }) {
    final current = byId(ingredientId)!.stockMl;
    return addAdjustment(
      ingredientId: ingredientId,
      deltaMl: targetMl - current,
      reason: AdjustReason.correction,
      note: note.isEmpty ? 'Set to ${targetMl.toStringAsFixed(1)} mL' : note,
    );
  }

  bool removeAdjustment(String adjustmentId) {
    final i = adjustments.indexWhere((e) => e.id == adjustmentId);
    if (i < 0) return false;
    adjustments.removeAt(i);
    recomputeStock();
    notifyListeners();
    _save();
    return true;
  }

  void addRecipe(Recipe r) {
    recipes.add(r);
    notifyListeners();
    _save();
  }

  /// Replaces a recipe in place, keeping its position in the list.
  void updateRecipe(Recipe r) {
    final i = recipes.indexWhere((e) => e.id == r.id);
    if (i >= 0) {
      recipes[i] = r;
    } else {
      recipes.add(r);
    }
    notifyListeners();
    _save();
  }

  /// Copies a recipe under a new id, inserted right after the original.
  Recipe? duplicateRecipe(String id) {
    final i = recipes.indexWhere((e) => e.id == id);
    if (i < 0) return null;
    final src = recipes[i];
    final copy = Recipe(
      id: newId(),
      name: '${src.name} (copy)',
      notes: src.notes,
      batchMl: src.batchMl,
      targetNic: src.targetNic,
      targetVgPercent: src.targetVgPercent,
      percentMode: src.percentMode,
      baseMode: src.baseMode,
      flavors: [
        for (final f in src.flavors)
          RecipeFlavor(
            ingredientId: f.ingredientId,
            name: f.name,
            percent: f.percent,
          ),
      ],
    );
    recipes.insert(i + 1, copy);
    notifyListeners();
    _save();
    return copy;
  }

  (Recipe, int)? removeRecipe(String id) {
    final i = recipes.indexWhere((e) => e.id == id);
    if (i < 0) return null;
    final removed = recipes.removeAt(i);
    notifyListeners();
    _save();
    return (removed, i);
  }

  void restoreRecipe(Recipe r, int index) {
    recipes.insert(index.clamp(0, recipes.length), r);
    notifyListeners();
    _save();
  }

  void updateSettings(Settings s) {
    settings = s;
    notifyListeners();
    _save();
  }

  /// Records a mix. Stock is derived, so this appends a log entry and
  /// replays — no in-place deduction, and no flooring at zero. A mix larger
  /// than stock leaves a negative balance, which is surfaced rather than
  /// silently absorbed.
  MixLog logMix(
    MixResult r, {
    String label = '',
    String? recipeId,
    double targetNic = 0,
    double targetVgPercent = 0,
    bool weighed = false,
  }) {
    final lines = [
      for (final l in r.lines)
        MixLogLine(
          name: l.name,
          ingredientId: l.ingredientId,
          requestedMl: l.ml,
          // Equal under event sourcing; kept so pre-v9 logs still read.
          deductedMl: l.ml,
          grams: l.grams,
          cost: l.cost,
        ),
    ];

    final log = MixLog(
      id: newId(),
      mixedAt: DateTime.now(),
      label: label.trim().isEmpty ? 'Unnamed mix' : label.trim(),
      recipeId: recipeId,
      batchMl: r.totalMl,
      targetNic: targetNic,
      targetVgPercent: targetVgPercent,
      actualNic: r.actualNicMgPerMl,
      actualVgPercent: r.actualVgPercent,
      totalGrams: r.totalGrams,
      totalCost: r.totalCost,
      hardwareCost: hardwareCostFor(r.totalMl, settings),
      weighed: weighed,
      lines: lines,
    );
    mixLog.insert(0, log);
    recomputeStock();
    notifyListeners();
    _save();
    return log;
  }

  bool undoMix(String logId) {
    final i = mixLog.indexWhere((e) => e.id == logId);
    if (i < 0) return false;
    mixLog.removeAt(i);
    recomputeStock();
    notifyListeners();
    _save();
    return true;
  }

  /// Under a ledger the entry *is* the deduction, so this is the same as
  /// [undoMix]. Kept as a distinct name for call sites that read better.
  void deleteLogEntry(String logId) => undoMix(logId);

  /// Sets or clears the rating and tasting notes on a logged mix.
  /// Stamps ratedAt so the steep time at tasting is recoverable.
  bool rateMix(
    String logId, {
    int? rating,
    bool clearRating = false,
    String? notes,
  }) {
    final i = mixLog.indexWhere((e) => e.id == logId);
    if (i < 0) return false;
    mixLog[i] = mixLog[i].copyWith(
      rating: rating,
      clearRating: clearRating,
      tastingNotes: notes,
      ratedAt: DateTime.now(),
    );
    notifyListeners();
    _save();
    return true;
  }
}
