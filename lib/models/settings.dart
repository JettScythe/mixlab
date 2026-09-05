import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/units.dart';

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
    this.costBasis = CostBasis.movingAverage,
    this.updatedAt,
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

  /// Applies retroactively — the whole ledger is replayed under whichever
  /// policy is selected, so historical mix costs change when this changes.
  CostBasis costBasis;

  /// 0 system, 1 light, 2 dark.
  int themeMode;

  /// Bottles, caps and gloves are a real per-batch cost. Off by default so
  /// existing figures do not change under you.
  bool includeHardware;
  double emptyBottleCost;
  double emptyBottleMl;

  /// Caps, labels, gloves — anything spent per batch regardless of size.
  double consumablesCost;

  /// Last modification, used for last-write-wins merging. Null means the
  /// record predates sync tracking.
  DateTime? updatedAt;

  DateTime get syncStamp => updatedAt ?? beforeSync;

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
    'updatedAt': updatedAt?.toIso8601String(),
    'costBasis': costBasis.index,
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
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
    costBasis:
        CostBasis.values[(j['costBasis'] as num?)?.toInt().clamp(
              0,
              CostBasis.values.length - 1,
            ) ??
            0],
  );
}
