import 'package:mixlab/models/enums.dart';

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
    this.updatedAt,
    List<RecipeFlavor>? flavors,
  }) : flavors = flavors ?? [];

  final String id;
  String name;
  String notes;
  double batchMl;
  double targetNic;
  double targetVgPercent;

  /// Last modification, used for last-write-wins merging. Null means the
  /// record predates sync tracking.
  DateTime? updatedAt;

  DateTime get syncStamp => updatedAt ?? beforeSync;

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
    'updatedAt': updatedAt?.toIso8601String(),
  };

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
    id: j['id'] as String,
    name: j['name'] as String,
    notes: j['notes'] as String? ?? '',
    batchMl: (j['batchMl'] as num?)?.toDouble() ?? 30,
    targetNic: (j['targetNic'] as num?)?.toDouble() ?? 0,
    targetVgPercent: (j['targetVgPercent'] as num?)?.toDouble() ?? 70,
    percentMode: enumFromIndex(
      PercentMode.values,
      j['percentMode'],
      PercentMode.byVolume,
    ),
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
    baseMode: enumFromIndex(BaseMode.values, j['baseMode'], BaseMode.ratio),
    flavors: [
      for (final f in (j['flavors'] as List? ?? const []))
        RecipeFlavor.fromJson(f as Map<String, dynamic>),
    ],
  );
}
