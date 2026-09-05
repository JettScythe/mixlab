import 'package:flutter/material.dart' show IconData, Icons;
import 'package:intl/intl.dart';

enum IngredientKind { pg, vg, nicotine, flavor, additive, thinner }

/// Enum indices are persisted, so values may only be appended.
/// Unknown indices from a newer build degrade to [IngredientKind.flavor].
IngredientKind kindFromIndex(int i) =>
    (i >= 0 && i < IngredientKind.values.length)
    ? IngredientKind.values[i]
    : IngredientKind.flavor;

String kindLabel(IngredientKind k) => switch (k) {
  IngredientKind.pg => 'PG',
  IngredientKind.vg => 'VG',
  IngredientKind.nicotine => 'Nicotine base',
  IngredientKind.flavor => 'Flavor',
  IngredientKind.additive => 'Additive',
  IngredientKind.thinner => 'Thinner',
};

String kindHint(IngredientKind k) => switch (k) {
  IngredientKind.pg => 'Propylene glycol base.',
  IngredientKind.vg => 'Vegetable glycerin base.',
  IngredientKind.nicotine => 'Nicotine base, measured in mg/mL or mg/g.',
  IngredientKind.flavor => 'Counts toward the recipe flavor percentage.',
  IngredientKind.additive =>
    'Sweeteners, coolants, enhancers. Added by percentage but excluded '
        'from the flavor total.',
  IngredientKind.thinner =>
    'Distilled water, PGA and similar diluents. Excluded from the flavor '
        'total.',
};

/// Ingredients added as a percentage of the batch rather than filling it.
bool isConcentrate(IngredientKind k) =>
    k == IngredientKind.flavor ||
    k == IngredientKind.additive ||
    k == IngredientKind.thinner;

/// How recipe percentages are interpreted.
enum PercentMode { byVolume, byWeight }

String percentModeLabel(PercentMode m) => switch (m) {
  PercentMode.byVolume => 'By volume',
  PercentMode.byWeight => 'By weight',
};

String percentModeHint(PercentMode m) => switch (m) {
  PercentMode.byVolume =>
    'A 10% flavor in a 30 mL batch means 3 mL. This is how ELR and most '
        'shared recipes are written.',
  PercentMode.byWeight =>
    'A 10% flavor means 10% of the finished weight. Differs from volume '
        'by up to ~20% on VG-heavy mixes.',
};

/// How the PG/VG base is allocated.
enum BaseMode { ratio, maxVg }

String baseModeLabel(BaseMode m) => switch (m) {
  BaseMode.ratio => 'Target ratio',
  BaseMode.maxVg => 'Max VG',
};

String baseModeHint(BaseMode m) => switch (m) {
  BaseMode.ratio => 'Add PG and VG to hit a chosen PG/VG split.',
  BaseMode.maxVg =>
    'Add no neat PG at all. VG fills whatever the nicotine and '
        'concentrates leave, so the final ratio is whatever it works out to.',
};

/// How a nicotine base's strength is labelled.
enum NicUnit { perMl, perGram }

String nicUnitLabel(NicUnit u) => switch (u) {
  NicUnit.perMl => 'mg/mL',
  NicUnit.perGram => 'mg/g',
};

String nicUnitHint(NicUnit u) => switch (u) {
  NicUnit.perMl => 'Strength per millilitre. The usual labelling.',
  NicUnit.perGram =>
    "Strength per gram. Converted using this base's density, so get the "
        'density right or the whole mix is off.',
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

/// Same as [parseNum] but allows negatives, for signed stock adjustments.
double? parseSigned(String s) {
  final t = s.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || v.isNaN || v.isInfinite) return null;
  return v;
}

NumberFormat? _moneyFormat;
String? _moneyCurrency;

/// Locale-correct currency formatting, falling back to a plain suffix for
/// codes intl does not recognise.
String money(double v, Settings s) {
  if (_moneyCurrency != s.currency) {
    _moneyCurrency = s.currency;
    try {
      _moneyFormat = NumberFormat.simpleCurrency(name: s.currency);
    } catch (_) {
      _moneyFormat = null;
    }
  }
  final f = _moneyFormat;
  return f == null ? '${v.toStringAsFixed(2)} ${s.currency}' : f.format(v);
}

/// Three-decimal variant for per-mL figures, where rounding to cents hides
/// the difference between ingredients.
String moneyPerMl(double v, Settings s) =>
    '${v.toStringAsFixed(3)} ${s.currency}/mL';

/// Snackbar timings. Plain confirmations vanish fast; anything with an undo
/// action stays long enough to actually click it.
const toastShort = Duration(milliseconds: 1500);
const toastUndo = Duration(seconds: 5);

class Ingredient {
  Ingredient({
    required this.id,
    required this.name,
    required this.kind,
    required this.density, // g per mL
    this.brand = '',
    this.bottleSizeMl = 0,
    this.bottleCost = 0,
    this.avgCostPerMl = 0,
    this.stockMl = 0,
    this.nicStrength = 0,
    this.nicUnit = NicUnit.perMl,
    this.nicIsSalt = false,
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

  /// Weighted average from the stock ledger. Derived — see [stockMl].
  double avgCostPerMl;

  /// Derived from the stock ledger: purchases, mixes and adjustments.
  /// Never assign this directly; [AppState.recomputeStock] owns it.
  /// Persisted only as a snapshot so the value is inspectable in a backup.
  double stockMl;

  double nicStrength;
  NicUnit nicUnit;

  /// Informational. Salt nicotine is not mixed differently, but recording
  /// it keeps the log honest about what is in the bottle.
  bool nicIsSalt;

  double carrierVg;
  String notes;

  String get displayName => brand.isEmpty ? name : '$brand $name';
  String get searchKey =>
      '$brand $name ${knownBrands[brand] ?? ''}'.toLowerCase();

  /// Identity for duplicate detection: brand + name, case-insensitive.
  String get dedupKey =>
      '${brand.trim().toLowerCase()}|${name.trim().toLowerCase()}';

  /// Weighted average basis from the ledger, else the bottle price.
  double get costPerMl => avgCostPerMl > 0
      ? avgCostPerMl
      : (bottleSizeMl > 0 ? bottleCost / bottleSizeMl : 0);

  double get stockGrams => stockMl * density;

  /// Records disagree with reality. Almost always an unlogged purchase or
  /// a mix logged twice.
  bool get stockIsNegative => stockMl < -1e-9;

  /// Strength normalised to mg per mL, which is what the mixing math wants.
  /// A mg/g base converts through its density, so a 100 mg/g VG base is
  /// about 126 mg/mL.
  double get nicMgPerMl => switch (nicUnit) {
    NicUnit.perMl => nicStrength,
    NicUnit.perGram => nicStrength * density,
  };

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
    'nicUnit': nicUnit.index,
    'nicIsSalt': nicIsSalt,
    'carrierVg': carrierVg,
    'notes': notes,
  };

  factory Ingredient.fromJson(Map<String, dynamic> j) => Ingredient(
    id: j['id'] as String,
    name: j['name'] as String,
    brand: j['brand'] as String? ?? '',
    kind: kindFromIndex(j['kind'] as int),
    density: (j['density'] as num).toDouble(),
    bottleSizeMl: (j['bottleSizeMl'] as num?)?.toDouble() ?? 0,
    bottleCost: (j['bottleCost'] as num?)?.toDouble() ?? 0,
    avgCostPerMl: (j['avgCostPerMl'] as num?)?.toDouble() ?? 0,
    stockMl: (j['stockMl'] as num?)?.toDouble() ?? 0,
    nicStrength: (j['nicStrength'] as num?)?.toDouble() ?? 0,
    nicUnit: NicUnit.values[(j['nicUnit'] as num?)?.toInt() ?? 0],
    nicIsSalt: j['nicIsSalt'] as bool? ?? false,
    carrierVg: (j['carrierVg'] as num?)?.toDouble() ?? 0,
    notes: j['notes'] as String? ?? '',
  );
}

class Settings {
  Settings({
    this.pgDensity = 1.036,
    this.vgDensity = 1.261,
    // Concentrates are mostly carrier, so a PG-based flavor sits at PG's
    // density rather than at 1.0.
    this.flavorDensity = 1.036,
    this.thinnerDensity = 1.0,
    this.currency = 'USD',
    this.defaultVgPercent = 70,
    this.defaultBatchMl = 30,
    this.refBottleMl = 30,
    this.scaleResolution = 0.01,
    this.tareEachStep = false,
    this.lowStockMl = 5,
    this.defaultPercentMode = PercentMode.byVolume,
    this.themeMode = 0,
    this.includeHardware = false,
    this.emptyBottleCost = 0,
    this.emptyBottleMl = 30,
    this.consumablesCost = 0,
  });

  double pgDensity;
  double vgDensity;
  double flavorDensity;
  double thinnerDensity; // distilled water ~1.0, PGA ~0.95
  String currency;
  double defaultVgPercent;
  double defaultBatchMl;
  double refBottleMl;
  double scaleResolution;
  bool tareEachStep;
  double lowStockMl;
  PercentMode defaultPercentMode;

  /// 0 system, 1 light, 2 dark.
  int themeMode;

  /// Bottles, caps and gloves are a real per-batch cost. Off by default so
  /// existing figures do not change under you.
  bool includeHardware;
  double emptyBottleCost;
  double emptyBottleMl;

  /// Caps, labels, gloves — anything spent per batch regardless of size.
  double consumablesCost;

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
      IngredientKind.additive => flavorDensity * (1 - v) + vgDensity * v,
      IngredientKind.thinner => thinnerDensity * (1 - v) + vgDensity * v,
    };
  }

  Map<String, dynamic> toJson() => {
    'pgDensity': pgDensity,
    'vgDensity': vgDensity,
    'flavorDensity': flavorDensity,
    'thinnerDensity': thinnerDensity,
    'currency': currency,
    'defaultVgPercent': defaultVgPercent,
    'defaultBatchMl': defaultBatchMl,
    'refBottleMl': refBottleMl,
    'scaleResolution': scaleResolution,
    'tareEachStep': tareEachStep,
    'lowStockMl': lowStockMl,
    'defaultPercentMode': defaultPercentMode.index,
    'themeMode': themeMode,
    'includeHardware': includeHardware,
    'emptyBottleCost': emptyBottleCost,
    'emptyBottleMl': emptyBottleMl,
    'consumablesCost': consumablesCost,
  };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
    pgDensity: (j['pgDensity'] as num?)?.toDouble() ?? 1.036,
    vgDensity: (j['vgDensity'] as num?)?.toDouble() ?? 1.261,
    flavorDensity: (j['flavorDensity'] as num?)?.toDouble() ?? 1.036,
    thinnerDensity: (j['thinnerDensity'] as num?)?.toDouble() ?? 1.0,
    currency: j['currency'] as String? ?? 'USD',
    defaultVgPercent: (j['defaultVgPercent'] as num?)?.toDouble() ?? 70,
    defaultBatchMl: (j['defaultBatchMl'] as num?)?.toDouble() ?? 30,
    refBottleMl: (j['refBottleMl'] as num?)?.toDouble() ?? 30,
    scaleResolution: (j['scaleResolution'] as num?)?.toDouble() ?? 0.01,
    tareEachStep: j['tareEachStep'] as bool? ?? false,
    lowStockMl: (j['lowStockMl'] as num?)?.toDouble() ?? 5,
    defaultPercentMode:
        PercentMode.values[(j['defaultPercentMode'] as num?)?.toInt() ?? 0],
    themeMode: (j['themeMode'] as num?)?.toInt() ?? 0,
    includeHardware: j['includeHardware'] as bool? ?? false,
    emptyBottleCost: (j['emptyBottleCost'] as num?)?.toDouble() ?? 0,
    emptyBottleMl: (j['emptyBottleMl'] as num?)?.toDouble() ?? 30,
    consumablesCost: (j['consumablesCost'] as num?)?.toDouble() ?? 0,
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
    this.percentMode = PercentMode.byVolume,
    this.baseMode = BaseMode.ratio,
    List<RecipeFlavor>? flavors,
  }) : flavors = flavors ?? [];

  final String id;
  String name;
  String notes;
  double batchMl;
  double targetNic;
  double targetVgPercent;

  /// How this recipe's percentages are meant to be read. Recipes written
  /// before this existed are by volume, matching ELR convention.
  PercentMode percentMode;

  /// Whether [targetVgPercent] is honoured or ignored in favour of max VG.
  BaseMode baseMode;

  final List<RecipeFlavor> flavors;

  /// Sum of every listed percentage, including additives and thinners.
  /// For the flavor-only figure use [MixResult.flavorPercentByVolume].
  double get totalFlavorPercent => flavors.fold(0.0, (a, f) => a + f.percent);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'notes': notes,
    'batchMl': batchMl,
    'targetNic': targetNic,
    'targetVgPercent': targetVgPercent,
    'percentMode': percentMode.index,
    'baseMode': baseMode.index,
    'flavors': flavors.map((f) => f.toJson()).toList(),
  };

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
    id: j['id'] as String,
    name: j['name'] as String,
    notes: j['notes'] as String? ?? '',
    batchMl: (j['batchMl'] as num?)?.toDouble() ?? 30,
    targetNic: (j['targetNic'] as num?)?.toDouble() ?? 0,
    targetVgPercent: (j['targetVgPercent'] as num?)?.toDouble() ?? 70,
    percentMode: PercentMode.values[(j['percentMode'] as num?)?.toInt() ?? 0],
    baseMode: BaseMode.values[(j['baseMode'] as num?)?.toInt() ?? 0],
    flavors: [
      for (final f in (j['flavors'] as List? ?? const []))
        RecipeFlavor.fromJson(f as Map<String, dynamic>),
    ],
  );
}

/// A restock. Append-only: stock and cost basis are derived by replaying
/// the ledger, so removing this entry removes its effect entirely.
class Purchase {
  Purchase({
    required this.id,
    required this.ingredientId,
    required this.ingredientName,
    required this.at,
    required this.volumeMl,
    required this.cost,
    this.shippingCost = 0,
    this.prevStockMl = 0,
    this.prevCostPerMl = 0,
    this.prevAvgCostPerMl = 0,
  });

  final String id;
  final String ingredientId;
  final String ingredientName;
  final DateTime at;
  final double volumeMl;
  final double cost;

  /// Share of an order's shipping attributed to this item.
  final double shippingCost;

  /// Retained from the pre-ledger model so old backups round-trip.
  /// No longer consulted — undo works by replay.
  final double prevStockMl;
  final double prevCostPerMl;
  final double prevAvgCostPerMl;

  double get totalCost => cost + shippingCost;
  double get costPerMl => volumeMl > 0 ? totalCost / volumeMl : 0;

  Map<String, dynamic> toJson() => {
    'id': id,
    'ingredientId': ingredientId,
    'ingredientName': ingredientName,
    'at': at.toIso8601String(),
    'volumeMl': volumeMl,
    'cost': cost,
    'shippingCost': shippingCost,
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
    shippingCost: (j['shippingCost'] as num?)?.toDouble() ?? 0,
    prevStockMl: (j['prevStockMl'] as num?)?.toDouble() ?? 0,
    prevCostPerMl: (j['prevCostPerMl'] as num?)?.toDouble() ?? 0,
    prevAvgCostPerMl: (j['prevAvgCostPerMl'] as num?)?.toDouble() ?? 0,
  );
}

/// Why stock changed outside a purchase or a mix.
enum AdjustReason {
  opening,
  correction,
  spill,
  evaporation,
  gift,
  disposal,
  other,
}

String adjustReasonLabel(AdjustReason r) => switch (r) {
  AdjustReason.opening => 'Opening balance',
  AdjustReason.correction => 'Correction',
  AdjustReason.spill => 'Spill or waste',
  AdjustReason.evaporation => 'Evaporation',
  AdjustReason.gift => 'Gift or trade',
  AdjustReason.disposal => 'Disposed',
  AdjustReason.other => 'Other',
};

IconData adjustReasonIcon(AdjustReason r) => switch (r) {
  AdjustReason.opening => Icons.flag_outlined,
  AdjustReason.correction => Icons.tune,
  AdjustReason.spill => Icons.water_damage_outlined,
  AdjustReason.evaporation => Icons.air,
  AdjustReason.gift => Icons.card_giftcard,
  AdjustReason.disposal => Icons.delete_outline,
  AdjustReason.other => Icons.more_horiz,
};

/// Reasons that represent stock leaving, used to sign a "change by" amount.
bool adjustReasonRemoves(AdjustReason r) =>
    r == AdjustReason.spill ||
    r == AdjustReason.evaporation ||
    r == AdjustReason.disposal ||
    r == AdjustReason.gift;

/// A manual change to stock that is neither a purchase nor a mix.
///
/// Signed: positive adds, negative removes. Opening balances are how
/// pre-existing stock enters the ledger.
class StockAdjustment {
  StockAdjustment({
    required this.id,
    required this.ingredientId,
    required this.ingredientName,
    required this.at,
    required this.deltaMl,
    this.reason = AdjustReason.correction,
    this.costPerMl = 0,
    this.note = '',
  });

  final String id;
  final String ingredientId;
  final String ingredientName;
  final DateTime at;
  final double deltaMl;
  final AdjustReason reason;

  /// Cost basis for stock added this way. Only meaningful when [deltaMl] is
  /// positive; lets an opening balance carry its original price.
  final double costPerMl;

  final String note;

  Map<String, dynamic> toJson() => {
    'id': id,
    'ingredientId': ingredientId,
    'ingredientName': ingredientName,
    'at': at.toIso8601String(),
    'deltaMl': deltaMl,
    'reason': reason.index,
    'costPerMl': costPerMl,
    'note': note,
  };

  factory StockAdjustment.fromJson(Map<String, dynamic> j) => StockAdjustment(
    id: j['id'] as String,
    ingredientId: j['ingredientId'] as String,
    ingredientName: j['ingredientName'] as String? ?? '',
    at:
        DateTime.tryParse(j['at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    deltaMl: (j['deltaMl'] as num?)?.toDouble() ?? 0,
    reason:
        AdjustReason.values[((j['reason'] as num?)?.toInt() ?? 1).clamp(
          0,
          AdjustReason.values.length - 1,
        )],
    costPerMl: (j['costPerMl'] as num?)?.toDouble() ?? 0,
    note: j['note'] as String? ?? '',
  );
}

/// One line of an ingredient's stock ledger, for display.
class StockLedgerEntry {
  StockLedgerEntry({
    required this.at,
    required this.deltaMl,
    required this.label,
    required this.icon,
    required this.balanceAfter,
    this.detail = '',
    this.sourceId,
    this.canUndo = false,
  });

  final DateTime at;
  final double deltaMl;
  final String label;
  final IconData icon;
  final double balanceAfter;
  final String detail;
  final String? sourceId;
  final bool canUndo;
}

class MixLine {
  MixLine(
    this.name,
    this.ml,
    this.grams,
    this.cost,
    this.ingredientId, {
    this.kind = IngredientKind.flavor,
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

  /// Kept so the flavor percentage can exclude additives and thinners.
  final IngredientKind kind;

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
      kind: kind,
      vgFraction: vgFraction,
      density: density,
      costPerMl: costPerMl,
      nicMgPerMl: nicMgPerMl,
    );
  }
}

class MixResult {
  MixResult(this.lines, this.warnings, {this.converged = true});

  final List<MixLine> lines;
  final List<String> warnings;

  /// False when by-weight percentages failed to settle. Should not happen
  /// in practice; surfaced rather than hidden.
  final bool converged;

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

  double _sum(bool Function(MixLine) where, double Function(MixLine) pick) =>
      lines.fold(0.0, (a, l) => where(l) ? a + pick(l) : a);

  /// Flavor only — additives and thinners are excluded, which is the number
  /// mixers actually mean by "total flavor".
  double get flavorPercentByVolume {
    final t = totalMl;
    if (t <= 0) return 0;
    return _sum((l) => l.kind == IngredientKind.flavor, (l) => l.ml) / t * 100;
  }

  double get flavorPercentByWeight {
    final t = totalGrams;
    if (t <= 0) return 0;
    return _sum((l) => l.kind == IngredientKind.flavor, (l) => l.grams) /
        t *
        100;
  }

  double get additivePercentByVolume {
    final t = totalMl;
    if (t <= 0) return 0;
    return _sum((l) => l.kind == IngredientKind.additive, (l) => l.ml) /
        t *
        100;
  }

  bool get hasAdditives => lines.any((l) => l.kind == IngredientKind.additive);
  bool get hasThinners => lines.any((l) => l.kind == IngredientKind.thinner);
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

  /// What the mix called for. Under event sourcing this is what the ledger
  /// subtracts — there is no flooring at zero.
  final double requestedMl;

  /// Equal to [requestedMl] from schema v9 onward. Kept so pre-v9 logs,
  /// where a short mix deducted less than it asked for, still read back.
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
    this.hardwareCost = 0,
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

  /// Bottles and consumables at mix time. Separate from [totalCost] so the
  /// juice cost stays comparable across batches.
  final double hardwareCost;

  final List<MixLogLine> lines;
  final bool weighed;

  /// 1-5, or null if never rated.
  final int? rating;
  final String tastingNotes;
  final DateTime? ratedAt;

  double get grandTotalCost => totalCost + hardwareCost;

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
    hardwareCost: hardwareCost,
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
    'hardwareCost': hardwareCost,
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
    hardwareCost: (j['hardwareCost'] as num?)?.toDouble() ?? 0,
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
