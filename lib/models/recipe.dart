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
    this.nicId,
    this.pgId,
    this.vgId,
    this.favorite = false,
    List<String>? tags,
    this.updatedAt,
    List<RecipeFlavor>? flavors,
  }) : tags = [],
       flavors = flavors ?? [] {
    // Normalise at construction, not in a setter: every path that builds a
    // recipe — editor, import, merge, restore — gets the same guarantees
    // (trimmed, lowercased, deduplicated) without having to remember to
    // call setTags. A tag saved with a leading space is a tag that will
    // never match its own filter, and the whitespace compounds on every
    // round trip through 'join(', ')' + split(',').
    setTags(tags ?? const []);
  }

  final String id;
  String name;
  String notes;
  double batchMl;
  double targetNic;
  double targetVgPercent;

  /// Which bottles this recipe is mixed from.
  ///
  /// A recipe recording 3 mg/mL says nothing about *which* base delivers
  /// it, and the answer changes the mix: a 100 mg/mL VG base and a
  /// 250 mg/mL PG base need different volumes and drag the ratio in
  /// opposite directions. Null means "no preference" — the caller falls
  /// back to whatever is selected, which is how every recipe behaved
  /// before these existed.
  String? nicId;
  String? pgId;
  String? vgId;

  /// Pinned to the top of the library. Presentation only — it never
  /// affects a mix — but it syncs, because pinning on one device and not
  /// finding it pinned on the other reads as the pin being lost.
  bool favorite;

  /// Free-form labels, lowercased and deduplicated on assignment through
  /// [setTags]. Searched case-insensitively.
  final List<String> tags;

  /// Replaces the tag list with [tags], normalised: trimmed, lowercased,
  /// empty entries dropped, duplicates collapsed, order preserved.
  void setTags(Iterable<String> tags) {
    this.tags
      ..clear()
      ..addAll({
        for (final t in tags)
          if (t.trim().isNotEmpty) t.trim().toLowerCase(),
      });
  }

  /// True when [tag] is one of this recipe's tags. [tag] is expected
  /// lowercase, as produced by [setTags]. Substring search lives in the
  /// search box; a filter fed from the actual tag set means an exact hit,
  /// or selecting 'fruit' also pulls in 'fruit punch'.
  bool hasTag(String tag) => tags.contains(tag);

  /// Last modification, used for last-write-wins merging. Null means the
  /// record predates sync tracking.
  DateTime? updatedAt;

  /// Original paste-dialect text for a recipe parsed from the starter
  /// library. Not persisted — a null here means the recipe came from
  /// anywhere else.
  String? sourceText;

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
    'nicId': nicId,
    'pgId': pgId,
    'vgId': vgId,
    'favorite': favorite,
    'tags': tags.toList(),
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
    // Absent on pre-v12 recipes, which is exactly the "no preference"
    // case, so no migration is needed to read them.
    nicId: j['nicId'] as String?,
    pgId: j['pgId'] as String?,
    vgId: j['vgId'] as String?,
    // Absent on pre-v13 recipes. Present-but-wrong types degrade to the
    // defaults like every other field.
    favorite: j['favorite'] is bool ? j['favorite'] as bool : false,
    tags: [
      for (final t in (j['tags'] as List? ?? const []))
        if (t is String) t,
    ],
    flavors: [
      for (final f in (j['flavors'] as List? ?? const []))
        RecipeFlavor.fromJson(f as Map<String, dynamic>),
    ],
  );
}
