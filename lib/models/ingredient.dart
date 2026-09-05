import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/settings.dart';
import 'package:mixlab/models/units.dart';

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
    this.updatedAt,
  });

  final String id;
  String name;
  String brand;
  IngredientKind kind;
  double density;
  double bottleSizeMl;
  double bottleCost;
  DateTime? updatedAt;

  /// Current cost basis per mL, derived by replaying the ledger under the
  /// configured [CostBasis]. Zero when there is no ledger history.
  double avgCostPerMl;

  /// Value of the stock actually on hand. Under FIFO this is the sum of
  /// remaining layers, which is not always [stockMl] times [costPerMl].
  double stockValue = 0;

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
  DateTime get syncStamp => updatedAt ?? beforeSync;

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
    'updatedAt': updatedAt?.toIso8601String(),
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
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
  );
}
