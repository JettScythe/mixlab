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
  static const currentSchema = 6;

  static const _allKeys = [
    _kSchema,
    _kIngredients,
    _kSettings,
    _kRecipes,
    _kMixLog,
    _kPurchases,
  ];

  final List<Ingredient> ingredients = [];
  final List<Recipe> recipes = [];
  final List<MixLog> mixLog = []; // newest first
  final List<Purchase> purchases = []; // newest first
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

    if (v < 2) {
      // v2: pull recognised brand shorthands out of the combined name.
      final raw = prefs.getString(_kIngredients);
      if (raw != null) {
        final list = (jsonDecode(raw) as List)
            .cast<Map<String, dynamic>>()
            .toList();
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
      // All are additive with safe defaults, so no transform is needed.
      v = 3;
    }
    if (v < 4) {
      // v4 adds recipeId, rating and tasting notes to mix logs. The new
      // fields default safely, but old entries can often be linked to a
      // recipe by matching the label they were mixed under.
      final rawLog = prefs.getString(_kMixLog);
      final rawRec = prefs.getString(_kRecipes);
      if (rawLog != null && rawRec != null) {
        final byName = <String, String>{};
        for (final r
            in (jsonDecode(rawRec) as List).cast<Map<String, dynamic>>()) {
          final n = (r['name'] as String? ?? '').trim().toLowerCase();
          if (n.isNotEmpty) byName.putIfAbsent(n, () => r['id'] as String);
        }
        final logs = (jsonDecode(rawLog) as List)
            .cast<Map<String, dynamic>>()
            .toList();
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
      // v5 adds additive/thinner ingredient kinds and per-recipe percent
      // mode. Both are additive with safe defaults, so no transform runs —
      // the bump exists so an older build refuses to import v5 data rather
      // than crashing on an unknown enum index. flavor density now defaults to PG density, since nearly all
      // concentrates are PG-based. Only move it if the old default was
      // never changed — a measured value stays.
      final raw = prefs.getString(_kSettings);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final fd = (j['flavorDensity'] as num?)?.toDouble();
        if (fd != null && (fd - 1.0).abs() < 1e-9) {
          j['flavorDensity'] = kFlavorDensity;
          await prefs.setString(_kSettings, jsonEncode(j));
          debugPrint('Flavor density default moved to $kFlavorDensity (v6).');
        }
      }
      v = 5;
    }
    if (v < 6) {
      // v6 adds Recipe.baseMode. Existing recipes were mixed to their
      // stored ratio, which is the default, so no transform is needed.
      v = 6;
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
        'Backup schema v$schema is newer than '
        'this build (v$currentSchema).',
      );
    }

    if (replace) {
      ingredients.clear();
      recipes.clear();
      mixLog.clear();
      purchases.clear();
    }

    var ni = 0, nr = 0, nl = 0, np = 0;
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
    mixLog.sort((a, b) => b.mixedAt.compareTo(a.mixedAt));
    purchases.sort((a, b) => b.at.compareTo(a.at));

    if (decoded['settings'] != null) {
      settings = Settings.fromJson(decoded['settings'] as Map<String, dynamic>);
    }

    notifyListeners();
    await _save();
    return 'Imported $ni ingredients, $nr recipes, $nl mixes, $np restocks.';
  }

  Future<void> factoryReset() async {
    ingredients.clear();
    recipes.clear();
    mixLog.clear();
    purchases.clear();
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
      stockMl: size,
      nicStrength: nic,
    );

    ingredients.addAll([
      mk('PG', IngredientKind.pg, size: 500, cost: 12),
      mk('VG', IngredientKind.vg, size: 500, cost: 14),
      mk(
        'Nic 100mg (PG)',
        IngredientKind.nicotine,
        size: 120,
        cost: 25,
        nic: 100,
      ),
    ]);
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
            'Strawberry Ripe famous. Shake-and-vape friendly; some '
            'versions run 6/6.',
        [rf(sbRipe, 8), rf(vbic, 6)],
      ),
      r(
        'Nana Cream',
        "Botboy141's homage to the Bombies classic. Commonly posted at "
            '6/4; add 2% Vanilla Bean Ice Cream for a richer take.',
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
        'Five Pawns-style coconut-almond-bourbon custard. '
            'Long steep, 3+ weeks.',
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

  // ----------------------------------------------------------------- queries

  Ingredient? byId(String? id) {
    if (id == null) return null;
    for (final e in ingredients) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Everything addable by percentage: flavors, additives and thinners.
  List<Ingredient> get concentrates => [
    for (final e in ingredients)
      if (isConcentrate(e.kind)) e,
  ];

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
  /// pushed back through the calculator. Flavor percentages are derived from
  /// the volumes requested at mix time, not from the current recipe — a
  /// remix reproduces that bottle even if the recipe has since changed.
  ///
  /// The returned recipe carries a synthetic id, so the calculator treats it
  /// as unsaved rather than offering to overwrite anything.
  Recipe recipeFromLog(MixLog l) {
    final flavors = <RecipeFlavor>[];
    for (final line in l.lines) {
      final ing = byId(line.ingredientId);
      if (ing == null || ing.kind != IngredientKind.flavor) continue;
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

  Ingredient? flavorByName(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final e in ingredients) {
      if (e.kind != IngredientKind.flavor) continue;
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

  List<Recipe> recipesUsing(String ingredientId) => [
    for (final r in recipes)
      if (r.flavors.any((f) => f.ingredientId == ingredientId)) r,
  ];

  int mixesUsing(String ingredientId) => mixLog
      .where((l) => l.lines.any((x) => x.ingredientId == ingredientId))
      .length;

  List<Ingredient> ofKind(IngredientKind k) =>
      ingredients.where((e) => e.kind == k).toList();

  Ingredient? firstOfKind(IngredientKind k) {
    final list = ofKind(k);
    return list.isEmpty ? null : list.first;
  }

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
  double get lifetimeSpend => purchases.fold(0.0, (a, p) => a + p.cost);

  // ---------------------------------------------------------------- mutation

  void upsertIngredient(Ingredient ing) {
    final i = ingredients.indexWhere((e) => e.id == ing.id);
    if (i >= 0) {
      ingredients[i] = ing;
    } else {
      ingredients.add(ing);
    }
    notifyListeners();
    _save();
  }

  /// Removes an ingredient and returns it plus its index, so the caller can
  /// offer an undo. Callers must confirm first — see [recipesUsing].
  (Ingredient, int)? removeIngredient(String id) {
    final i = ingredients.indexWhere((e) => e.id == id);
    if (i < 0) return null;
    final removed = ingredients.removeAt(i);
    notifyListeners();
    _save();
    return (removed, i);
  }

  void restoreIngredient(Ingredient ing, int index) {
    final at = index.clamp(0, ingredients.length);
    ingredients.insert(at, ing);
    notifyListeners();
    _save();
  }

  /// Records a restock. The cost basis becomes the volume-weighted average of
  /// existing stock and this purchase, rather than silently adopting the
  /// current bottle price.
  Purchase recordPurchase({
    required String ingredientId,
    required double volumeMl,
    required double cost,
    bool useWeightedAverage = true,
  }) {
    final ing = byId(ingredientId)!;
    final prevStock = ing.stockMl;
    final prevCostPerMl = ing.costPerMl;
    final prevAvg = ing.avgCostPerMl;

    final newCostPerMl = volumeMl > 0 ? cost / volumeMl : 0.0;
    ing.stockMl = prevStock + volumeMl;
    if (useWeightedAverage) {
      final denom = prevStock + volumeMl;
      ing.avgCostPerMl = denom > 0
          ? (prevStock * prevCostPerMl + volumeMl * newCostPerMl) / denom
          : newCostPerMl;
    } else {
      ing.avgCostPerMl = newCostPerMl;
    }

    final p = Purchase(
      id: newId(),
      ingredientId: ingredientId,
      ingredientName: ing.displayName,
      at: DateTime.now(),
      volumeMl: volumeMl,
      cost: cost,
      prevStockMl: prevStock,
      prevCostPerMl: prevCostPerMl,
      prevAvgCostPerMl: prevAvg,
    );
    purchases.insert(0, p);
    notifyListeners();
    _save();
    return p;
  }

  /// Restores the exact pre-purchase stock and cost basis.
  bool undoPurchase(String purchaseId) {
    final i = purchases.indexWhere((e) => e.id == purchaseId);
    if (i < 0) return false;
    final p = purchases[i];
    final ing = byId(p.ingredientId);
    if (ing != null) {
      ing.stockMl = p.prevStockMl;
      ing.avgCostPerMl = p.prevAvgCostPerMl;
    }
    purchases.removeAt(i);
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
  /// Falls back to appending if the id is unknown.
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

  /// Removes a recipe and returns it with its index so the caller can undo.
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

  /// Records a mix, deducts stock, and returns the log entry.
  /// Achieved nicotine and VG% are recomputed from the real amounts.
  /// Records a mix, deducts stock, and returns the log entry.
  /// Achieved nicotine and VG% are recomputed from the real amounts.
  MixLog logMix(
    MixResult r, {
    String label = '',
    String? recipeId,
    double targetNic = 0,
    double targetVgPercent = 0,
    bool weighed = false,
  }) {
    final lines = <MixLogLine>[];
    for (final l in r.lines) {
      final ing = byId(l.ingredientId);
      var deducted = 0.0;
      if (ing != null && l.ml > 0) {
        deducted = l.ml <= ing.stockMl ? l.ml : ing.stockMl;
        if (deducted < 0) deducted = 0;
        ing.stockMl = ing.stockMl - deducted;
        if (ing.stockMl < 0) ing.stockMl = 0;
      }
      lines.add(
        MixLogLine(
          name: l.name,
          ingredientId: l.ingredientId,
          requestedMl: l.ml,
          deductedMl: deducted,
          grams: l.grams,
          cost: l.cost,
        ),
      );
    }
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
      weighed: weighed,
      lines: lines,
    );
    mixLog.insert(0, log);
    notifyListeners();
    _save();
    return log;
  }

  /// Sets or clears the rating and tasting notes on a logged mix.
  /// Stamps [ratedAt] so the steep time at tasting is recoverable.
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

  bool undoMix(String logId) {
    final i = mixLog.indexWhere((e) => e.id == logId);
    if (i < 0) return false;
    for (final line in mixLog[i].lines) {
      final ing = byId(line.ingredientId);
      if (ing == null) continue;
      ing.stockMl = ing.stockMl + line.deductedMl;
    }
    mixLog.removeAt(i);
    notifyListeners();
    _save();
    return true;
  }

  void deleteLogEntry(String logId) {
    mixLog.removeWhere((e) => e.id == logId);
    notifyListeners();
    _save();
  }
}
