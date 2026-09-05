import 'package:flutter/material.dart';
import 'package:mixlab/models/enums.dart';

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
    this.updatedAt,
  });

  final String id;
  final String ingredientId;
  final String ingredientName;
  final DateTime at;
  final double volumeMl;
  final double cost;
  DateTime? updatedAt;

  /// Share of an order's shipping attributed to this item.
  final double shippingCost;

  /// Retained from the pre-ledger model so old backups round-trip.
  /// No longer consulted — undo works by replay.
  final double prevStockMl;
  final double prevCostPerMl;
  final double prevAvgCostPerMl;

  double get totalCost => cost + shippingCost;
  double get costPerMl => volumeMl > 0 ? totalCost / volumeMl : 0;
  DateTime get syncStamp => updatedAt ?? beforeSync;

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
    'updatedAt': updatedAt?.toIso8601String(),
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
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
  );
}

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
    this.updatedAt,
  });

  final String id;
  final String ingredientId;
  final String ingredientName;
  final DateTime at;
  final double deltaMl;
  final AdjustReason reason;
  DateTime? updatedAt;

  /// Cost basis for stock added this way. Only meaningful when [deltaMl] is
  /// positive; lets an opening balance carry its original price.
  final double costPerMl;

  final String note;
  DateTime get syncStamp => updatedAt ?? beforeSync;

  Map<String, dynamic> toJson() => {
    'id': id,
    'ingredientId': ingredientId,
    'ingredientName': ingredientName,
    'at': at.toIso8601String(),
    'deltaMl': deltaMl,
    'reason': reason.index,
    'costPerMl': costPerMl,
    'note': note,
    'updatedAt': updatedAt?.toIso8601String(),
  };

  factory StockAdjustment.fromJson(Map<String, dynamic> j) => StockAdjustment(
    id: j['id'] as String,
    ingredientId: j['ingredientId'] as String,
    ingredientName: j['ingredientName'] as String? ?? '',
    at:
        DateTime.tryParse(j['at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    deltaMl: (j['deltaMl'] as num?)?.toDouble() ?? 0,
    reason: enumFromIndex(
      AdjustReason.values,
      j['reason'],
      AdjustReason.correction,
    ),
    costPerMl: (j['costPerMl'] as num?)?.toDouble() ?? 0,
    note: j['note'] as String? ?? '',
    updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
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

/// Marks a deleted record so a merge does not resurrect it.
///
/// Without these, syncing from a device that still has the record would
/// silently bring it back, because "absent" and "deleted" are
/// indistinguishable in a plain union.
class Tombstone {
  Tombstone({
    required this.type,
    required this.recordId,
    required this.deletedAt,
    this.label = '',
  });

  final RecordType type;
  final String recordId;
  final DateTime deletedAt;

  /// Kept for the merge preview, so a deletion reads as something other
  /// than an opaque id.
  final String label;

  String get key => '${type.index}:$recordId';

  Map<String, dynamic> toJson() => {
    'type': type.index,
    'recordId': recordId,
    'deletedAt': deletedAt.toIso8601String(),
    'label': label,
  };

  factory Tombstone.fromJson(Map<String, dynamic> j) => Tombstone(
    type: enumFromIndex(RecordType.values, j['type'], RecordType.ingredient),
    recordId: j['recordId'] as String,
    deletedAt:
        DateTime.tryParse(j['deletedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    label: j['label'] as String? ?? '',
  );
}
