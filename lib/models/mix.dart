import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/ingredient.dart';

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
  double cost;

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
    this.updatedAt,
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
  double totalCost;

  /// Bottles and consumables at mix time. Separate from [totalCost] so the
  /// juice cost stays comparable across batches.
  final double hardwareCost;

  final List<MixLogLine> lines;
  final bool weighed;

  /// 1-5, or null if never rated.
  final int? rating;
  final String tastingNotes;
  final DateTime? ratedAt;

  /// True when this mix drew more than the ledger had, so part of its cost
  /// was assumed from the last known price.
  bool costEstimated = false;

  /// Last modification, used for last-write-wins merging. Null means the
  /// record predates sync tracking.
  DateTime? updatedAt;

  DateTime get syncStamp => updatedAt ?? beforeSync;
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
    DateTime? updatedAt,
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
    updatedAt: updatedAt ?? this.updatedAt,
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
    'updatedAt': updatedAt?.toIso8601String(),
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
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
    lines: [
      for (final l in (j['lines'] as List? ?? const []))
        MixLogLine.fromJson(l as Map<String, dynamic>),
    ],
  );
}

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
