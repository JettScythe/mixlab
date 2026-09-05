import 'package:flutter/material.dart' show IconData, Icons;

enum IngredientKind { pg, vg, nicotine, flavor, additive, thinner }

enum BaseMode { ratio, maxVg }

enum NicUnit { perMl, perGram }

enum RecordType { ingredient, recipe, mixLog, purchase, adjustment }

enum PercentMode { byVolume, byWeight }

enum AdjustReason {
  opening,
  correction,
  spill,
  evaporation,
  gift,
  disposal,
  other,
}

enum CostBasis { movingAverage, fifo }

final beforeSync = DateTime.fromMillisecondsSinceEpoch(0);

/// Unknown indices from a newer build degrade to [IngredientKind.flavor].
IngredientKind kindFromIndex(int i) =>
    (i >= 0 && i < IngredientKind.values.length)
    ? IngredientKind.values[i]
    : IngredientKind.flavor;

/// Reads an enum index from stored JSON without ever throwing.
///
/// Corrupt or hand-edited data must degrade to the default, not take down
/// the whole load with a RangeError — every other field in these models
/// already tolerates rubbish.
T enumFromIndex<T>(List<T> values, Object? raw, T fallback) {
  final i = (raw as num?)?.toInt();
  if (i == null || i < 0 || i >= values.length) return fallback;
  return values[i];
}

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

/// How the cost of stock drawn from inventory is determined.

String costBasisLabel(CostBasis b) => switch (b) {
  CostBasis.movingAverage => 'Moving average',
  CostBasis.fifo => 'FIFO',
};

String costBasisHint(CostBasis b) => switch (b) {
  CostBasis.movingAverage =>
    'Everything in the bottle is blended to one price. Restocking at a '
        'new price shifts the whole balance.',
  CostBasis.fifo =>
    'Oldest stock is used first. A mix costs what that specific liquid '
        'cost, so the cheap bottle runs out before prices rise.',
};

/// How the PG/VG base is allocated.

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

/// Record families that participate in sync.

String recordTypeLabel(RecordType t) => switch (t) {
  RecordType.ingredient => 'Ingredient',
  RecordType.recipe => 'Recipe',
  RecordType.mixLog => 'Mix',
  RecordType.purchase => 'Restock',
  RecordType.adjustment => 'Adjustment',
};

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
