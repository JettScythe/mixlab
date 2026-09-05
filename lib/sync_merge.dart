import 'dart:convert';

import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/ingredient.dart';
import 'package:mixlab/models/ledger.dart';
import 'package:mixlab/models/mix.dart';
import 'package:mixlab/models/recipe.dart';
import 'package:mixlab/models/settings.dart';

enum MergeAction { add, update, delete }

String mergeActionLabel(MergeAction a) => switch (a) {
  MergeAction.add => 'Add',
  MergeAction.update => 'Update',
  MergeAction.delete => 'Delete',
};

/// One proposed change, reviewable before it is applied.
class MergeItem {
  MergeItem({
    required this.type,
    required this.id,
    required this.label,
    required this.action,
    required this.detail,
    this.incoming,
    this.accept = true,
  });

  final RecordType type;
  final String id;
  final String label;
  final MergeAction action;

  /// Human-readable summary of what changes, so review is meaningful.
  final String detail;

  /// The decoded record to apply. Null for deletions.
  final Object? incoming;

  bool accept;
}

/// Everything a merge would do, before it does any of it.
class MergePlan {
  MergePlan({
    required this.items,
    required this.tombstones,
    this.incomingSettings,
    this.settingsDetail = '',
    this.remoteDevice = '',
    this.exportedAt,
  });

  final List<MergeItem> items;

  /// Tombstones from the other side, folded in regardless of item choices
  /// so a delete cannot be half-applied.
  final List<Tombstone> tombstones;

  final Settings? incomingSettings;
  final String settingsDetail;
  bool acceptSettings = false;

  final String remoteDevice;
  final DateTime? exportedAt;

  bool get isEmpty => items.isEmpty && incomingSettings == null;

  int countOf(MergeAction a) =>
      items.where((i) => i.action == a && i.accept).length;

  List<MergeItem> ofType(RecordType t) => [
    for (final i in items)
      if (i.type == t) i,
  ];
}

String _fmtPct(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// Short description of how two recipes differ, for the preview.
String _recipeDiff(Recipe local, Recipe remote) {
  final bits = <String>[];
  if (local.name != remote.name) bits.add('renamed to "${remote.name}"');
  if (local.notes != remote.notes) bits.add('notes changed');
  if (local.flavors.length != remote.flavors.length) {
    bits.add('${local.flavors.length} → ${remote.flavors.length} ingredients');
  } else {
    final changed = <String>[];
    for (var i = 0; i < local.flavors.length; i++) {
      final a = local.flavors[i];
      final b = remote.flavors[i];
      if (a.ingredientId != b.ingredientId) {
        changed.add(b.name);
      } else if ((a.percent - b.percent).abs() > 1e-9) {
        changed.add(
          '${b.name} ${_fmtPct(a.percent)}% → ${_fmtPct(b.percent)}%',
        );
      }
    }
    if (changed.isNotEmpty) bits.add(changed.take(3).join(', '));
  }
  if ((local.batchMl - remote.batchMl).abs() > 1e-9) {
    bits.add('batch ${_fmtPct(remote.batchMl)} mL');
  }
  if ((local.targetNic - remote.targetNic).abs() > 1e-9) {
    bits.add('nic ${_fmtPct(remote.targetNic)} mg');
  }
  if (local.percentMode != remote.percentMode) {
    bits.add(percentModeLabel(remote.percentMode).toLowerCase());
  }
  if (local.baseMode != remote.baseMode) {
    bits.add(baseModeLabel(remote.baseMode).toLowerCase());
  }
  return bits.isEmpty ? 'no visible difference' : bits.join(' • ');
}

String _ingredientDiff(Ingredient local, Ingredient remote) {
  final bits = <String>[];
  if (local.displayName != remote.displayName) {
    bits.add('renamed to "${remote.displayName}"');
  }
  if ((local.density - remote.density).abs() > 1e-9) {
    bits.add('density ${remote.density.toStringAsFixed(3)}');
  }
  if ((local.bottleCost - remote.bottleCost).abs() > 1e-9 ||
      (local.bottleSizeMl - remote.bottleSizeMl).abs() > 1e-9) {
    bits.add('price changed');
  }
  if (local.kind != remote.kind) bits.add('now ${kindLabel(remote.kind)}');
  if (local.notes != remote.notes) bits.add('notes changed');
  if (local.nicStrength != remote.nicStrength ||
      local.nicUnit != remote.nicUnit) {
    bits.add('strength changed');
  }
  return bits.isEmpty ? 'no visible difference' : bits.join(' • ');
}

/// Builds a merge plan from a backup produced by another device.
///
/// Rules, in order of precedence:
///   1. A tombstone newer than a record's `updatedAt` wins — deletions
///      propagate rather than being undone by a stale copy.
///   2. Records absent locally are added.
///   3. Records present on both sides resolve last-write-wins.
///   4. Records absent remotely are kept. Absence is not deletion; only a
///      tombstone deletes.
///
/// Ledger events (purchases, adjustments) are append-only, so they only
/// ever add. Mix logs can be edited via ratings, so they can update too.
MergePlan buildMergePlan({
  required String rawJson,
  required List<Ingredient> ingredients,
  required List<Recipe> recipes,
  required List<MixLog> mixLog,
  required List<Purchase> purchases,
  required List<StockAdjustment> adjustments,
  required List<Tombstone> tombstones,
  required Settings settings,
  required int currentSchema,
}) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Not an object at the top level.');
  }
  final schema = (decoded['schema'] as num?)?.toInt() ?? 1;
  if (schema > currentSchema) {
    throw FormatException(
      'That backup is schema v$schema, newer than this build '
      '(v$currentSchema). Update first.',
    );
  }

  final items = <MergeItem>[];

  // Tombstones from both sides, keyed so the newest deletion wins.
  final graves = <String, Tombstone>{for (final t in tombstones) t.key: t};
  final incomingGraves = <Tombstone>[];
  for (final e in (decoded['tombstones'] as List? ?? const [])) {
    final t = Tombstone.fromJson(e as Map<String, dynamic>);
    incomingGraves.add(t);
    final existing = graves[t.key];
    if (existing == null || t.deletedAt.isAfter(existing.deletedAt)) {
      graves[t.key] = t;
    }
  }

  bool buried(RecordType type, String id, DateTime stamp) {
    final t = graves['${type.index}:$id'];
    return t != null && t.deletedAt.isAfter(stamp);
  }

  void consider<T>({
    required RecordType type,
    required List<dynamic> raw,
    required Map<String, T> local,
    required T Function(Map<String, dynamic>) parse,
    required String Function(T) labelOf,
    required DateTime Function(T) stampOf,
    required String Function(T local, T remote) diff,
    bool appendOnly = false,
  }) {
    for (final e in raw) {
      final remote = parse(e as Map<String, dynamic>);
      final id = (e['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      if (buried(type, id, stampOf(remote))) continue;

      final mine = local[id];
      if (mine == null) {
        items.add(
          MergeItem(
            type: type,
            id: id,
            label: labelOf(remote),
            action: MergeAction.add,
            detail: appendOnly ? 'not on this device' : 'new here',
            incoming: remote,
          ),
        );
        continue;
      }
      if (appendOnly) continue; // already have it; events never change

      final theirs = stampOf(remote);
      final ours = stampOf(mine);
      if (!theirs.isAfter(ours)) continue; // ours is newer or equal

      final detail = diff(mine, remote);
      if (detail == 'no visible difference') continue;

      items.add(
        MergeItem(
          type: type,
          id: id,
          label: labelOf(mine),
          action: MergeAction.update,
          detail: detail,
          incoming: remote,
        ),
      );
    }
  }

  consider<Ingredient>(
    type: RecordType.ingredient,
    raw: decoded['ingredients'] as List? ?? const [],
    local: {for (final e in ingredients) e.id: e},
    parse: Ingredient.fromJson,
    labelOf: (e) => e.displayName,
    stampOf: (e) => e.syncStamp,
    diff: _ingredientDiff,
  );

  consider<Recipe>(
    type: RecordType.recipe,
    raw: decoded['recipes'] as List? ?? const [],
    local: {for (final e in recipes) e.id: e},
    parse: Recipe.fromJson,
    labelOf: (e) => e.name,
    stampOf: (e) => e.syncStamp,
    diff: _recipeDiff,
  );

  consider<MixLog>(
    type: RecordType.mixLog,
    raw: decoded['mixLog'] as List? ?? const [],
    local: {for (final e in mixLog) e.id: e},
    parse: MixLog.fromJson,
    labelOf: (e) => e.label,
    stampOf: (e) => e.syncStamp,
    diff: (a, b) {
      final bits = <String>[];
      if (a.rating != b.rating) bits.add('rated ${b.rating ?? '—'}');
      if (a.tastingNotes != b.tastingNotes) bits.add('notes changed');
      return bits.isEmpty ? 'no visible difference' : bits.join(' • ');
    },
  );

  consider<Purchase>(
    type: RecordType.purchase,
    raw: decoded['purchases'] as List? ?? const [],
    local: {for (final e in purchases) e.id: e},
    parse: Purchase.fromJson,
    labelOf: (e) => '${e.ingredientName} +${e.volumeMl.toStringAsFixed(0)} mL',
    stampOf: (e) => e.syncStamp,
    diff: (a, b) => 'no visible difference',
    appendOnly: true,
  );

  consider<StockAdjustment>(
    type: RecordType.adjustment,
    raw: decoded['adjustments'] as List? ?? const [],
    local: {for (final e in adjustments) e.id: e},
    parse: StockAdjustment.fromJson,
    labelOf: (e) =>
        '${e.ingredientName} ${e.deltaMl >= 0 ? '+' : ''}'
        '${e.deltaMl.toStringAsFixed(1)} mL',
    stampOf: (e) => e.syncStamp,
    diff: (a, b) => 'no visible difference',
    appendOnly: true,
  );

  // Deletions the other side made that we still hold.
  void proposeDeletes<T>(
    RecordType type,
    Map<String, T> local,
    String Function(T) labelOf,
    DateTime Function(T) stampOf,
  ) {
    for (final t in incomingGraves) {
      if (t.type != type) continue;
      final mine = local[t.recordId];
      if (mine == null) continue;
      if (!t.deletedAt.isAfter(stampOf(mine))) continue;
      items.add(
        MergeItem(
          type: type,
          id: t.recordId,
          label: labelOf(mine),
          action: MergeAction.delete,
          detail: 'deleted on the other device',
        ),
      );
    }
  }

  proposeDeletes<Ingredient>(
    RecordType.ingredient,
    {for (final e in ingredients) e.id: e},
    (e) => e.displayName,
    (e) => e.syncStamp,
  );
  proposeDeletes<Recipe>(
    RecordType.recipe,
    {for (final e in recipes) e.id: e},
    (e) => e.name,
    (e) => e.syncStamp,
  );
  proposeDeletes<MixLog>(
    RecordType.mixLog,
    {for (final e in mixLog) e.id: e},
    (e) => e.label,
    (e) => e.syncStamp,
  );
  proposeDeletes<Purchase>(
    RecordType.purchase,
    {for (final e in purchases) e.id: e},
    (e) => e.ingredientName,
    (e) => e.syncStamp,
  );
  proposeDeletes<StockAdjustment>(
    RecordType.adjustment,
    {for (final e in adjustments) e.id: e},
    (e) => e.ingredientName,
    (e) => e.syncStamp,
  );

  // Settings are a singleton, so only offered when strictly newer.
  Settings? incomingSettings;
  var settingsDetail = '';
  final rawSettings = decoded['settings'];
  if (rawSettings is Map<String, dynamic>) {
    final theirs = Settings.fromJson(rawSettings);
    if (theirs.syncStamp.isAfter(settings.syncStamp)) {
      incomingSettings = theirs;
      final bits = <String>[];
      if (theirs.currency != settings.currency) {
        bits.add('currency ${theirs.currency}');
      }
      if (theirs.scaleResolution != settings.scaleResolution) {
        bits.add('scale ${theirs.scaleResolution} g');
      }
      if (theirs.includeHardware != settings.includeHardware) {
        bits.add('hardware costs ${theirs.includeHardware ? 'on' : 'off'}');
      }
      settingsDetail = bits.isEmpty ? 'minor changes' : bits.join(' • ');
    }
  }

  return MergePlan(
    items: items,
    tombstones: incomingGraves,
    incomingSettings: incomingSettings,
    settingsDetail: settingsDetail,
    remoteDevice: decoded['deviceId'] as String? ?? 'unknown device',
    exportedAt: DateTime.tryParse(decoded['exportedAt'] as String? ?? ''),
  );
}
