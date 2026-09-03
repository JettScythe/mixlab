enum IngredientKind { pg, vg, nicotine, flavor }

String kindLabel(IngredientKind k) => switch (k) {
  IngredientKind.pg => 'PG',
  IngredientKind.vg => 'VG',
  IngredientKind.nicotine => 'Nicotine base',
  IngredientKind.flavor => 'Flavor',
};

/// Brand shorthands seen in DIY recipes, mapped to full vendor names.
/// Verify against e-liquid-recipes.com before trusting any of these.
const knownBrands = <String, String>{
  'TFA': 'The Flavor Apprentice',
  'TPA': 'The Flavor Apprentice',
  'CAP': 'Capella',
  'FW': 'Flavor West',
  'FA': 'FlavourArt',
  'LA': 'LorAnn',
  'INW': 'Inawera',
  'JF': 'Jungle Flavors',
  'MF': 'Medicine Flower',
  'RF': 'Real Flavors',
  'WF': 'Wonder Flavours',
  'VT': 'Vape Train',
  'HS': 'Hangsen',
  'FLV': 'Flavorah',
  'OOO': 'One On One',
  'PUR': 'Purilum',
  'CLY': 'Clyrolinx',
};

/// Splits a leading recognised brand shorthand off a combined name.
(String, String) splitBrand(String full) {
  final t = full.trim();
  final i = t.indexOf(' ');
  if (i <= 0) return ('', t);
  final head = t.substring(0, i).toUpperCase();
  if (!knownBrands.containsKey(head)) return ('', t);
  final rest = t.substring(i + 1).trim();
  return rest.isEmpty ? ('', t) : (head, rest);
}

double clampd(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// Rounds to the nearest [step]. A step <= 0 is a no-op.
double roundTo(double v, double step) =>
    step <= 0 ? v : (v / step).round() * step;

/// Rounds a percentage to 2 decimals, so reconstructed recipes don't show
/// 7.999999999 after a division round-trip.
double roundPercent(double v) => (v * 100).round() / 100;

/// Locale-tolerant, non-negative number parsing.
double? parseNum(String s) {
  final t = s.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || v.isNaN || v.isInfinite || v < 0) return null;
  return v;
}

String money(double v, Settings s) => '${v.toStringAsFixed(2)} ${s.currency}';

class Ingredient {
  Ingredient({
    required this.id,
    required this.name,
    required this.kind,
    required this.density, // g per mL
    this.brand = '',
    this.bottleSizeMl = 0,
    this.bottleCost = 0,
    this.avgCostPerMl = 0, // weighted average from restocks; 0 = unset
    this.stockMl = 0,
    this.nicStrength = 0, // mg/mL, nicotine bases only
    this.carrierVg = 0, // 0..1 fraction of carrier that is VG
    this.notes = '',
  });

  final String id;
  String name;
  String brand;
  IngredientKind kind;
  double density;
  double bottleSizeMl;
  double bottleCost;
  double avgCostPerMl;
  double stockMl;
  double nicStrength;
  double carrierVg;
  String notes;

  String get displayName => brand.isEmpty ? name : '$brand $name';
  String get searchKey =>
      '$brand $name ${knownBrands[brand] ?? ''}'.toLowerCase();

  /// Identity for duplicate detection: brand + name, case-insensitive.
  String get dedupKey =>
      '${brand.trim().toLowerCase()}|${name.trim().toLowerCase()}';

  /// Weighted average basis when restocks have set one, else bottle price.
  double get costPerMl => avgCostPerMl > 0
      ? avgCostPerMl
      : (bottleSizeMl > 0 ? bottleCost / bottleSizeMl : 0);

  double get stockGrams => stockMl * density;

  /// True when [density] disagrees with what the carrier implies. Catches
  /// VG-based nicotine and concentrates left at the PG default.
  bool densityLooksWrong(Settings s) {
    final expected = s.densityForCarrier(kind, carrierVg);
    return (density - expected).abs() > 0.03;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'brand': brand,
    'kind': kind.index,
    'density': density,
    'bottleSizeMl': bottleSizeMl,
    'bottleCost': bottleCost,
    'avgCostPerMl': avgCostPerMl,
    'stockMl': stockMl,
    'nicStrength': nicStrength,
    'carrierVg': carrierVg,
    'notes': notes,
  };

  factory Ingredient.fromJson(Map<String, dynamic> j) => Ingredient(
    id: j['id'] as String,
    name: j['name'] as String,
    brand: j['brand'] as String? ?? '',
    kind: IngredientKind.values[j['kind'] as int],
    density: (j['density'] as num).toDouble(),
    bottleSizeMl: (j['bottleSizeMl'] as num?)?.toDouble() ?? 0,
    bottleCost: (j['bottleCost'] as num?)?.toDouble() ?? 0,
    avgCostPerMl: (j['avgCostPerMl'] as num?)?.toDouble() ?? 0,
    stockMl: (j['stockMl'] as num?)?.toDouble() ?? 0,
    nicStrength: (j['nicStrength'] as num?)?.toDouble() ?? 0,
    carrierVg: (j['carrierVg'] as num?)?.toDouble() ?? 0,
    notes: j['notes'] as String? ?? '',
  );
}

class Settings {
  Settings({
    this.pgDensity = 1.036,
    this.vgDensity = 1.261,
    this.flavorDensity = 1.036,
    this.currency = 'USD',
    this.defaultVgPercent = 70,
    this.defaultBatchMl = 30,
    this.refBottleMl = 30,
    this.scaleResolution = 0.01,
    this.tareEachStep = true,
    this.lowStockMl = 5,
  });

  double pgDensity;
  double vgDensity;
  double flavorDensity;
  String currency;
  double defaultVgPercent;
  double defaultBatchMl;
  double refBottleMl;
  double scaleResolution;
  bool tareEachStep;
  double lowStockMl;

  /// Density implied by kind alone. Prefer [densityForCarrier].
  double densityFor(IngredientKind k) => densityForCarrier(k, 0);

  /// Carrier-aware density. A 100% VG nicotine base is ~1.26 g/mL, not the
  /// 1.036 that a naive PG default would give — a ~20% weight error.
  double densityForCarrier(IngredientKind k, double carrierVg) {
    final v = clampd(carrierVg, 0, 1);
    return switch (k) {
      IngredientKind.pg => pgDensity,
      IngredientKind.vg => vgDensity,
      IngredientKind.nicotine => pgDensity * (1 - v) + vgDensity * v,
      IngredientKind.flavor => flavorDensity * (1 - v) + vgDensity * v,
    };
  }

  Map<String, dynamic> toJson() => {
    'pgDensity': pgDensity,
    'vgDensity': vgDensity,
    'flavorDensity': flavorDensity,
    'currency': currency,
    'defaultVgPercent': defaultVgPercent,
    'defaultBatchMl': defaultBatchMl,
    'refBottleMl': refBottleMl,
    'scaleResolution': scaleResolution,
    'tareEachStep': tareEachStep,
    'lowStockMl': lowStockMl,
  };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
    pgDensity: (j['pgDensity'] as num?)?.toDouble() ?? 1.036,
    vgDensity: (j['vgDensity'] as num?)?.toDouble() ?? 1.261,
    flavorDensity: (j['flavorDensity'] as num?)?.toDouble() ?? 1.036,
    currency: j['currency'] as String? ?? 'USD',
    defaultVgPercent: (j['defaultVgPercent'] as num?)?.toDouble() ?? 70,
    defaultBatchMl: (j['defaultBatchMl'] as num?)?.toDouble() ?? 30,
    refBottleMl: (j['refBottleMl'] as num?)?.toDouble() ?? 30,
    scaleResolution: (j['scaleResolution'] as num?)?.toDouble() ?? 0.01,
    tareEachStep: j['tareEachStep'] as bool? ?? true,
    lowStockMl: (j['lowStockMl'] as num?)?.toDouble() ?? 5,
  );
}

class RecipeFlavor {
  RecipeFlavor({
    required this.ingredientId,
    required this.name,
    required this.percent,
  });

  final String ingredientId;
  final String name;
  final double percent;

  Map<String, dynamic> toJson() => {
    'ingredientId': ingredientId,
    'name': name,
    'percent': percent,
  };

  factory RecipeFlavor.fromJson(Map<String, dynamic> j) => RecipeFlavor(
    ingredientId: j['ingredientId'] as String,
    name: j['name'] as String,
    percent: (j['percent'] as num).toDouble(),
  );
}

class Recipe {
  Recipe({
    required this.id,
    required this.name,
    this.notes = '',
    this.batchMl = 30,
    this.targetNic = 3,
    this.targetVgPercent = 70,
    List<RecipeFlavor>? flavors,
  }) : flavors = flavors ?? [];

  final String id;
  String name;
  String notes;
  double batchMl;
  double targetNic;
  double targetVgPercent;
  final List<RecipeFlavor> flavors;

  double get totalFlavorPercent => flavors.fold(0.0, (a, f) => a + f.percent);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'notes': notes,
    'batchMl': batchMl,
    'targetNic': targetNic,
    'targetVgPercent': targetVgPercent,
    'flavors': flavors.map((f) => f.toJson()).toList(),
  };

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
    id: j['id'] as String,
    name: j['name'] as String,
    notes: j['notes'] as String? ?? '',
    batchMl: (j['batchMl'] as num?)?.toDouble() ?? 30,
    targetNic: (j['targetNic'] as num?)?.toDouble() ?? 0,
    targetVgPercent: (j['targetVgPercent'] as num?)?.toDouble() ?? 70,
    flavors: [
      for (final f in (j['flavors'] as List? ?? const []))
        RecipeFlavor.fromJson(f as Map<String, dynamic>),
    ],
  );
}

/// A restock. Stores the pre-purchase state so undo is exact.
class Purchase {
  Purchase({
    required this.id,
    required this.ingredientId,
    required this.ingredientName,
    required this.at,
    required this.volumeMl,
    required this.cost,
    required this.prevStockMl,
    required this.prevCostPerMl,
    required this.prevAvgCostPerMl,
  });

  final String id;
  final String ingredientId;
  final String ingredientName;
  final DateTime at;
  final double volumeMl;
  final double cost;
  final double prevStockMl;
  final double prevCostPerMl;
  final double prevAvgCostPerMl;

  double get costPerMl => volumeMl > 0 ? cost / volumeMl : 0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'ingredientId': ingredientId,
    'ingredientName': ingredientName,
    'at': at.toIso8601String(),
    'volumeMl': volumeMl,
    'cost': cost,
    'prevStockMl': prevStockMl,
    'prevCostPerMl': prevCostPerMl,
    'prevAvgCostPerMl': prevAvgCostPerMl,
  };

  factory Purchase.fromJson(Map<String, dynamic> j) => Purchase(
    id: j['id'] as String,
    ingredientId: j['ingredientId'] as String,
    ingredientName: j['ingredientName'] as String? ?? '',
    at:
        DateTime.tryParse(j['at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    volumeMl: (j['volumeMl'] as num?)?.toDouble() ?? 0,
    cost: (j['cost'] as num?)?.toDouble() ?? 0,
    prevStockMl: (j['prevStockMl'] as num?)?.toDouble() ?? 0,
    prevCostPerMl: (j['prevCostPerMl'] as num?)?.toDouble() ?? 0,
    prevAvgCostPerMl: (j['prevAvgCostPerMl'] as num?)?.toDouble() ?? 0,
  );
}

class MixLine {
  MixLine(
    this.name,
    this.ml,
    this.grams,
    this.cost,
    this.ingredientId, {
    this.vgFraction = 0,
    this.density = 1,
    this.costPerMl = 0,
    this.nicMgPerMl = 0,
  });

  final String name;
  final double ml;
  final double grams;
  final double cost;
  final String? ingredientId;
  final double vgFraction;
  final double density;
  final double costPerMl;

  /// Nicotine concentration of this ingredient itself, mg/mL.
  final double nicMgPerMl;

  /// Rebuilds this line around an actual weighed amount.
  MixLine withGrams(double g) {
    final v = density > 0 ? g / density : 0.0;
    return MixLine(
      name,
      v,
      g,
      v * costPerMl,
      ingredientId,
      vgFraction: vgFraction,
      density: density,
      costPerMl: costPerMl,
      nicMgPerMl: nicMgPerMl,
    );
  }
}

class MixResult {
  MixResult(this.lines, this.warnings);
  final List<MixLine> lines;
  final List<String> warnings;

  double get totalMl => lines.fold(0.0, (a, l) => a + l.ml);
  double get totalGrams => lines.fold(0.0, (a, l) => a + l.grams);
  double get totalCost => lines.fold(0.0, (a, l) => a + l.cost);

  double get actualVgPercent {
    final t = totalMl;
    if (t <= 0) return 0;
    final vg = lines.fold(0.0, (a, l) => a + l.ml * l.vgFraction);
    return vg / t * 100;
  }

  /// Nicotine strength the finished mix actually has. After weighing this
  /// diverges from the target whenever a line was over- or under-poured.
  double get actualNicMgPerMl {
    final t = totalMl;
    if (t <= 0) return 0;
    final mg = lines.fold(0.0, (a, l) => a + l.ml * l.nicMgPerMl);
    return mg / t;
  }
}

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
        'Below your ${resolution}g scale resolution: '
        '${tooSmall.join(', ')}. Mix a larger batch or use a syringe '
        'for these.',
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

class StockIssue {
  StockIssue(this.name, this.neededMl, this.haveMl);
  final String name;
  final double neededMl;
  final double haveMl;
  double get shortMl => neededMl - haveMl;
}

List<StockIssue> checkStock(MixResult r, Iterable<Ingredient> inventory) {
  final needed = <String, double>{};
  for (final l in r.lines) {
    final id = l.ingredientId;
    if (id == null || l.ml <= 0) continue;
    needed[id] = (needed[id] ?? 0) + l.ml;
  }
  final issues = <StockIssue>[];
  for (final ing in inventory) {
    final need = needed[ing.id];
    if (need == null) continue;
    if (need > ing.stockMl + 1e-9) {
      issues.add(StockIssue(ing.displayName, need, ing.stockMl));
    }
  }
  issues.sort((a, b) => b.shortMl.compareTo(a.shortMl));
  return issues;
}

class MixLogLine {
  MixLogLine({
    required this.name,
    required this.ingredientId,
    required this.requestedMl,
    required this.deductedMl,
    required this.grams,
    required this.cost,
  });

  final String name;
  final String? ingredientId;
  final double requestedMl;
  final double deductedMl;
  final double grams;
  final double cost;

  Map<String, dynamic> toJson() => {
    'name': name,
    'ingredientId': ingredientId,
    'requestedMl': requestedMl,
    'deductedMl': deductedMl,
    'grams': grams,
    'cost': cost,
  };

  factory MixLogLine.fromJson(Map<String, dynamic> j) => MixLogLine(
    name: j['name'] as String,
    ingredientId: j['ingredientId'] as String?,
    requestedMl: (j['requestedMl'] as num?)?.toDouble() ?? 0,
    deductedMl: (j['deductedMl'] as num?)?.toDouble() ?? 0,
    grams: (j['grams'] as num?)?.toDouble() ?? 0,
    cost: (j['cost'] as num?)?.toDouble() ?? 0,
  );
}

class MixLog {
  MixLog({
    required this.id,
    required this.mixedAt,
    required this.label,
    required this.batchMl,
    required this.targetNic,
    required this.targetVgPercent,
    required this.totalGrams,
    required this.totalCost,
    required this.lines,
    this.recipeId,
    this.actualNic = 0,
    this.actualVgPercent = 0,
    this.weighed = false,
    this.rating,
    this.tastingNotes = '',
    this.ratedAt,
  });

  final String id;
  final DateTime mixedAt;
  final String label;

  /// Recipe this was mixed from, when it came from one. Null for ad-hoc
  /// mixes, and left dangling if the recipe is later deleted.
  final String? recipeId;

  final double batchMl;
  final double targetNic;
  final double targetVgPercent;

  /// What the mix actually came out at, recomputed from the real amounts.
  final double actualNic;
  final double actualVgPercent;

  final double totalGrams;
  final double totalCost;
  final List<MixLogLine> lines;
  final bool weighed;

  /// 1-5, or null if never rated.
  final int? rating;
  final String tastingNotes;
  final DateTime? ratedAt;

  int get daysSteeping => DateTime.now().difference(mixedAt).inDays;

  bool get nicDrifted => (actualNic - targetNic).abs() > 0.05;

  bool get hasFeedback => rating != null || tastingNotes.isNotEmpty;

  /// Days between mixing and the tasting note, i.e. how long it steeped
  /// before you judged it.
  int? get steepDaysAtRating => ratedAt?.difference(mixedAt).inDays;

  MixLog copyWith({
    int? rating,
    bool clearRating = false,
    String? tastingNotes,
    DateTime? ratedAt,
    String? recipeId,
    bool clearRecipeId = false,
  }) => MixLog(
    id: id,
    mixedAt: mixedAt,
    label: label,
    recipeId: clearRecipeId ? null : (recipeId ?? this.recipeId),
    batchMl: batchMl,
    targetNic: targetNic,
    targetVgPercent: targetVgPercent,
    actualNic: actualNic,
    actualVgPercent: actualVgPercent,
    totalGrams: totalGrams,
    totalCost: totalCost,
    lines: lines,
    weighed: weighed,
    rating: clearRating ? null : (rating ?? this.rating),
    tastingNotes: tastingNotes ?? this.tastingNotes,
    ratedAt: ratedAt ?? this.ratedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'mixedAt': mixedAt.toIso8601String(),
    'label': label,
    'recipeId': recipeId,
    'batchMl': batchMl,
    'targetNic': targetNic,
    'targetVgPercent': targetVgPercent,
    'actualNic': actualNic,
    'actualVgPercent': actualVgPercent,
    'totalGrams': totalGrams,
    'totalCost': totalCost,
    'weighed': weighed,
    'rating': rating,
    'tastingNotes': tastingNotes,
    'ratedAt': ratedAt?.toIso8601String(),
    'lines': lines.map((l) => l.toJson()).toList(),
  };

  factory MixLog.fromJson(Map<String, dynamic> j) => MixLog(
    id: j['id'] as String,
    mixedAt:
        DateTime.tryParse(j['mixedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    label: j['label'] as String? ?? '',
    recipeId: j['recipeId'] as String?,
    batchMl: (j['batchMl'] as num?)?.toDouble() ?? 0,
    targetNic: (j['targetNic'] as num?)?.toDouble() ?? 0,
    targetVgPercent: (j['targetVgPercent'] as num?)?.toDouble() ?? 0,
    // Pre-v3 logs never stored achieved values; fall back to targets.
    actualNic:
        (j['actualNic'] as num?)?.toDouble() ??
        (j['targetNic'] as num?)?.toDouble() ??
        0,
    actualVgPercent:
        (j['actualVgPercent'] as num?)?.toDouble() ??
        (j['targetVgPercent'] as num?)?.toDouble() ??
        0,
    totalGrams: (j['totalGrams'] as num?)?.toDouble() ?? 0,
    totalCost: (j['totalCost'] as num?)?.toDouble() ?? 0,
    weighed: j['weighed'] as bool? ?? false,
    rating: (j['rating'] as num?)?.toInt(),
    tastingNotes: j['tastingNotes'] as String? ?? '',
    ratedAt: DateTime.tryParse(j['ratedAt'] as String? ?? ''),
    lines: [
      for (final l in (j['lines'] as List? ?? const []))
        MixLogLine.fromJson(l as Map<String, dynamic>),
    ],
  );
}

/// Weight-first mixing math. Volumes are computed, then converted to grams.
///
/// Flavors selected more than once are coalesced into a single line with
/// their percentages summed, so one bottle is never weighed twice.
MixResult calculateMix({
  required double amountMl,
  required double targetNic,
  required double targetVgPercent,
  required Settings settings,
  Ingredient? nic,
  Ingredient? pg,
  Ingredient? vg,
  List<(Ingredient, double)> flavors = const [],
}) {
  final lines = <MixLine>[];
  final warnings = <String>[];
  if (amountMl <= 0) {
    return MixResult(lines, const ['Enter a batch size above zero.']);
  }

  var vgMl = amountMl * clampd(targetVgPercent, 0, 100) / 100;
  var pgMl = amountMl - vgMl;

  if (targetNic > 0) {
    if (nic == null || nic.nicStrength <= 0) {
      warnings.add(
        'Target nicotine is ${targetNic.toStringAsFixed(1)} mg/mL '
        'but no nicotine base is selected — this mix will be 0 mg.',
      );
    } else if (targetNic >= nic.nicStrength) {
      warnings.add(
        'Target strength must be below the base strength '
        '(${nic.nicStrength.toStringAsFixed(0)} mg/mL).',
      );
    } else {
      final ml = amountMl * targetNic / nic.nicStrength;
      final carrier = clampd(nic.carrierVg, 0, 1);
      vgMl -= ml * carrier;
      pgMl -= ml * (1 - carrier);
      lines.add(
        MixLine(
          nic.displayName,
          ml,
          ml * nic.density,
          ml * nic.costPerMl,
          nic.id,
          vgFraction: carrier,
          density: nic.density,
          costPerMl: nic.costPerMl,
          nicMgPerMl: nic.nicStrength,
        ),
      );
    }
  }

  // Coalesce repeated selections of the same ingredient.
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
  if (hadDuplicates) {
    warnings.add('Duplicate flavors were combined into one line each.');
  }

  var flavorPct = 0.0;
  for (final id in order) {
    final (f, pct) = merged[id]!;
    flavorPct += pct;
    final ml = amountMl * pct / 100;
    final carrier = clampd(f.carrierVg, 0, 1);
    vgMl -= ml * carrier;
    pgMl -= ml * (1 - carrier);
    lines.add(
      MixLine(
        f.displayName,
        ml,
        ml * f.density,
        ml * f.costPerMl,
        f.id,
        vgFraction: carrier,
        density: f.density,
        costPerMl: f.costPerMl,
        nicMgPerMl: f.nicStrength,
      ),
    );
  }
  if (flavorPct > 100) {
    warnings.add(
      'Flavor total is ${flavorPct.toStringAsFixed(1)}% — '
      'over 100%.',
    );
  }

  const eps = 1e-12;
  if (pgMl < -eps || vgMl < -eps) {
    if (pgMl < 0) {
      vgMl += pgMl;
      pgMl = 0;
    } else {
      pgMl += vgMl;
      vgMl = 0;
    }
    if (pgMl < -eps || vgMl < -eps) {
      warnings.add(
        'Nicotine and flavors alone exceed '
        '${amountMl.toStringAsFixed(1)} mL — the finished mix will be '
        'larger than the requested batch.',
      );
    } else {
      warnings.add(
        'Concentrates carry in more PG/VG than the target ratio '
        'allows; the finished ratio will differ from the target.',
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
      vgFraction: 1,
      density: vgD,
      costPerMl: vg?.costPerMl ?? 0,
    ),
  );

  return MixResult(lines, warnings);
}
