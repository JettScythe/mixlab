import 'dart:convert';

import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/ingredient.dart';
import 'package:mixlab/models/ledger.dart';
import 'package:mixlab/models/mix.dart';
import 'package:mixlab/models/recipe.dart';
import 'package:mixlab/models/settings.dart';
import 'package:mixlab/models/units.dart';

/// Marker written into every export. Checked before a file is allowed to
/// touch stored data, so picking the wrong `.json` fails loudly instead of
/// quietly restoring nothing over everything.
const backupAppMarker = 'mixlab';

/// Decodes and vets a backup envelope. Throws [FormatException] unless the
/// file is recognisably a MixLab export this build can read. Returns the
/// decoded object and its schema version.
///
/// Every export MixLab has ever written carries the marker, so a missing
/// one means the file is not ours.
(Map<String, dynamic>, int) decodeBackup(
  String rawJson, {
  required int currentSchema,
}) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Not an object at the top level.');
  }
  if (decoded['app'] != backupAppMarker) {
    throw const FormatException(
      'That file is not a MixLab backup. Export one from '
      'Settings on the other device.',
    );
  }
  final schema = (decoded['schema'] as num?)?.toInt() ?? 1;
  if (schema > currentSchema) {
    throw FormatException(
      'That backup is schema v$schema, newer than this build '
      '(v$currentSchema). Update first.',
    );
  }
  return (decoded, schema);
}

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
    this.matchedByName = 0,
    this.refusedByName = 0,
  });

  final List<MergeItem> items;

  /// Ingredients the other device knew under a different id, resolved to
  /// an existing local one by brand and name. Surfaced so the review can
  /// say why an expected "add" is missing.
  final int matchedByName;

  /// Ingredients that share a local record's brand and name but describe a
  /// different bottle — a different kind, nicotine strength or carrier —
  /// so they were left as separate records. Surfaced for the opposite
  /// reason to [matchedByName]: without it, a refusal is indistinguishable
  /// from an ordinary add and the user is left with a duplicate-looking
  /// entry and no explanation.
  final int refusedByName;

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
///
/// [baseLabel] renders a base pin as something a person can judge. It is
/// resolved against the local inventory, which works because the incoming
/// pins have already been rewritten through the alias map by the time a
/// diff is taken.
String _recipeDiff(
  Recipe local,
  Recipe remote, {
  required String Function(String? id) baseLabel,
}) {
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
  // Only meaningful outside max VG, where the target is not consulted.
  if (remote.baseMode != BaseMode.maxVg &&
      (local.targetVgPercent - remote.targetVgPercent).abs() > 1e-9) {
    bits.add(
      '${_fmtPct(remote.targetVgPercent)}/'
      '${_fmtPct(100 - remote.targetVgPercent)} VG/PG',
    );
  }
  if (local.percentMode != remote.percentMode) {
    bits.add(percentModeLabel(remote.percentMode).toLowerCase());
  }
  if (local.baseMode != remote.baseMode) {
    bits.add(baseModeLabel(remote.baseMode).toLowerCase());
  }
  // A pin change is invisible in every field above, and 'no visible
  // difference' is the sentinel that drops an item from the plan — so
  // without this a recipe repinned to a 250 mg/mL base would never
  // propagate, and the pin would look like it simply did not sync.
  //
  // The incoming bottle is named rather than counted: this is the one
  // recipe field that changes the dose, so "nicotine base" alone gives the
  // user nothing to accept or decline on.
  for (final (label, a, b) in [
    ('nicotine', local.nicId, remote.nicId),
    ('PG', local.pgId, remote.pgId),
    ('VG', local.vgId, remote.vgId),
  ]) {
    if (a != b) bits.add('$label base → ${baseLabel(b)}');
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
  if ((local.nicMgPerMl - remote.nicMgPerMl).abs() > 1e-9) {
    bits.add('${_fmtPct(remote.nicMgPerMl)} mg/mL');
  } else if (local.nicStrength != remote.nicStrength ||
      local.nicUnit != remote.nicUnit) {
    // Same dose, different bookkeeping — worth saying, not worth a number.
    bits.add('strength recorded differently');
  }
  // Carrier and salt are now identity-critical for the name-based dedup,
  // so an edit to either must be visible: 'no visible difference' drops
  // the item, and the change would never sync at all.
  if ((local.carrierVg - remote.carrierVg).abs() > 1e-9) {
    bits.add('carrier ${_fmtPct(remote.carrierVg * 100)}% VG');
  }
  if (local.nicIsSalt != remote.nicIsSalt) {
    bits.add(remote.nicIsSalt ? 'now salt' : 'no longer salt');
  }
  return bits.isEmpty ? 'no visible difference' : bits.join(' • ');
}

/// Synthesises the opening-balance adjustments a pre-v9 payload is
/// missing, so its ingredient-held stock survives into the ledger.
///
/// Mirrors the v9 migration in [AppState] deliberately, ids included: the
/// same data brought forward by either route must produce the same
/// records, or upgrading the other device would double its stock.
List<Map<String, dynamic>> _openingBalancesFor({
  required List<Map<String, dynamic>> ingredients,
  required List<dynamic> purchases,
  required List<dynamic> mixLog,
}) {
  final replayed = <String, double>{};
  for (final e in purchases) {
    final p = e as Map<String, dynamic>;
    final id = p['ingredientId'] as String?;
    if (id == null) continue;
    replayed[id] =
        (replayed[id] ?? 0) + ((p['volumeMl'] as num?)?.toDouble() ?? 0);
  }
  for (final e in mixLog) {
    for (final line
        in ((e as Map<String, dynamic>)['lines'] as List? ?? const [])) {
      final m = line as Map<String, dynamic>;
      final id = m['ingredientId'] as String?;
      if (id == null) continue;
      replayed[id] =
          (replayed[id] ?? 0) - ((m['requestedMl'] as num?)?.toDouble() ?? 0);
    }
  }

  final now = DateTime.now().toIso8601String();
  final out = <Map<String, dynamic>>[];
  for (final j in ingredients) {
    final id = j['id'] as String?;
    if (id == null) continue;
    final delta =
        ((j['stockMl'] as num?)?.toDouble() ?? 0) - (replayed[id] ?? 0);
    if (delta.abs() < 1e-9) continue;

    // Carry the cost basis across so per-mL figures do not reset to zero.
    final avg = (j['avgCostPerMl'] as num?)?.toDouble() ?? 0;
    final size = (j['bottleSizeMl'] as num?)?.toDouble() ?? 0;
    final price = (j['bottleCost'] as num?)?.toDouble() ?? 0;
    final basis = avg > 0 ? avg : (size > 0 ? price / size : 0.0);

    out.add({
      'id': 'opening-$id',
      'ingredientId': id,
      'ingredientName': j['name'] ?? '',
      'at': now,
      'deltaMl': delta,
      'reason': AdjustReason.opening.index,
      'costPerMl': delta > 0 ? basis : 0,
      'note': 'Opening balance, carried in from a pre-ledger backup.',
    });
  }
  return out;
}

/// True when [remote] is plausibly the same physical bottle as [local],
/// beyond merely sharing a label.
///
/// Brand and name have already matched by the time this is called. What is
/// checked here is everything that would change how the bottle is *mixed*:
/// aliasing hands the remote record to last-write-wins against the local
/// one, so a disagreement is not a duplicate to be fused — it is two
/// different products that happen to be typed the same way, and merging
/// them would silently redefine what the local bottle contains.
///
/// Both sides are compared as parsed [Ingredient]s on purpose. Reading the
/// raw JSON here instead would let this gate and the apply that follows it
/// disagree about what the payload says — [Ingredient.fromJson] defaults a
/// missing unit to mg/mL and repairs a non-positive density, and a gate
/// with its own defaults would fuse records the apply then reads
/// differently, which is the failure it exists to prevent.
bool _sameBottle(Ingredient local, Ingredient remote) {
  if (remote.kind != local.kind) return false;

  // Nicotine strength is the one number where being wrong is a dosing
  // error rather than an inconvenience, so it is compared in the unit the
  // mixing math actually uses.
  if ((remote.nicMgPerMl - local.nicMgPerMl).abs() > 1e-6) return false;

  // Carrier drives density, and density drives every weight on screen.
  if ((remote.carrierVg - local.carrierVg).abs() > 1e-6) return false;

  return true;
}

/// Rewrites every reference to a remote ingredient id that resolves to a
/// different local id for the same bottle.
///
/// Aliasing the ingredient alone is not enough: a recipe, mix line,
/// purchase or adjustment that still points at the remote id would arrive
/// dangling, so the remap has to reach every record that names one.
///
/// The adjustment and purchase *record* ids are deliberately untouched.
/// They identify the event, not the ingredient, and rewriting them would
/// either collide two devices' independent restocks or break idempotency.
void _applyIngredientAliases(
  Map<String, String> aliases, {
  required List<Map<String, dynamic>> ingredients,
  required List<Map<String, dynamic>> recipes,
  required List<Map<String, dynamic>> mixLog,
  required List<Map<String, dynamic>> purchases,
  required List<Map<String, dynamic>> adjustments,
}) {
  if (aliases.isEmpty) return;

  for (final j in ingredients) {
    final to = aliases[j['id']];
    if (to != null) j['id'] = to;
  }
  for (final r in recipes) {
    for (final f in (r['flavors'] as List? ?? const [])) {
      final m = f as Map<String, dynamic>;
      final to = aliases[m['ingredientId']];
      if (to != null) m['ingredientId'] = to;
    }
    // Since v12 a recipe also names the bases it is mixed from. Leaving
    // these pointing at the remote id would land the recipe pinned to a
    // bottle this device has never stored, and [AppState.baseFor] would
    // quietly fall back to the first of each kind — the exact silent
    // substitution the pins exist to prevent.
    for (final k in const ['nicId', 'pgId', 'vgId']) {
      final to = aliases[r[k]];
      if (to != null) r[k] = to;
    }
  }
  for (final l in mixLog) {
    for (final line in (l['lines'] as List? ?? const [])) {
      final m = line as Map<String, dynamic>;
      final to = aliases[m['ingredientId']];
      if (to != null) m['ingredientId'] = to;
    }
  }
  for (final e in [...purchases, ...adjustments]) {
    final to = aliases[e['ingredientId']];
    if (to != null) e['ingredientId'] = to;
  }
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
///
/// Backups older than [currentSchema] are brought forward first, exactly
/// as a restore would. Merging is a peer-to-peer path, so the other device
/// may simply be running an older build.
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
  final (decoded, schema) = decodeBackup(rawJson, currentSchema: currentSchema);

  final rawIngredients = [
    for (final e in (decoded['ingredients'] as List? ?? const []))
      e as Map<String, dynamic>,
  ];
  final rawRecipes = [
    for (final e in (decoded['recipes'] as List? ?? const []))
      e as Map<String, dynamic>,
  ];
  final rawMixLog = [
    for (final e in (decoded['mixLog'] as List? ?? const []))
      e as Map<String, dynamic>,
  ];
  final rawPurchases = [
    for (final e in (decoded['purchases'] as List? ?? const []))
      e as Map<String, dynamic>,
  ];
  final rawAdjustments = [
    for (final e in (decoded['adjustments'] as List? ?? const []))
      e as Map<String, dynamic>,
  ];

  // Pre-v2 exports keep the vendor glued to the front of the name. Split
  // it here or the same bottle arrives as a second, differently-named
  // ingredient.
  if (schema < 2) {
    for (final j in rawIngredients) {
      if (((j['brand'] as String?) ?? '').isNotEmpty) continue;
      final (b, n) = splitBrand(j['name'] as String? ?? '');
      j['brand'] = b;
      j['name'] = n;
    }
  }

  // Pre-v9 exports carry stock on the ingredient rather than in a ledger.
  // Stock here is derived purely from ledger events, so without opening
  // balances the other device's entire inventory would merge in at zero.
  // The ids match what their own v9 migration will mint, so if they later
  // upgrade and re-export, these dedupe instead of doubling.
  if (schema < 9) {
    rawAdjustments.addAll(
      _openingBalancesFor(
        ingredients: rawIngredients,
        purchases: rawPurchases,
        mixLog: rawMixLog,
      ),
    );
  }

  // Two installs that each typed in "TFA Strawberry (Ripe)" minted
  // independent ids for the same bottle, so an id-only merge adds a
  // duplicate and splits its stock across two entries. Match the leftovers
  // on brand + name and rewrite the incoming references to point at the
  // local record.
  //
  // Only ids absent locally are considered: an id present on both sides is
  // already the same record by definition, and a rename must not be
  // second-guessed into a merge with some other bottle.
  final localById = {for (final e in ingredients) e.id: e};
  final localByName = <String, Ingredient>{};
  for (final e in ingredients) {
    localByName.putIfAbsent(e.dedupKey, () => e);
  }

  final aliases = <String, String>{};

  // A local record the remote payload already carries *by id* is spoken
  // for: aliasing a second remote record onto it would put two entries
  // with the same id in the plan, and the apply would then resolve them in
  // list order rather than by timestamp. Claim those up front.
  final claimed = <String>{
    for (final j in rawIngredients)
      if (j['id'] case final String id when localById.containsKey(id)) id,
  };

  // Labels that matched a local record but described a different bottle.
  // Counted so the preview can say why a duplicate-looking entry is still
  // arriving as an add, rather than leaving the user to guess.
  var refusedByName = 0;

  for (final j in rawIngredients) {
    final id = j['id'] as String?;
    if (id == null || localById.containsKey(id)) continue;
    final key = Ingredient.dedupKeyFor(
      (j['brand'] as String?) ?? '',
      (j['name'] as String?) ?? '',
    );
    if (key == '|') continue; // nothing to match on
    final match = localByName[key];
    // One local record can absorb only one remote id, or two remote
    // duplicates would both alias onto it and collide.
    if (match == null || claimed.contains(match.id)) continue;
    // A shared label is not a shared bottle. Aliasing feeds the remote
    // record into last-write-wins against the local one, so a mismatch
    // here would let a newer edit redefine what is physically in the
    // bottle — a 100 mg/mL base overwriting a 250 mg/mL one is a 2.5x
    // dosing error with nothing on screen to say so.
    if (!_sameBottle(match, Ingredient.fromJson(j))) {
      refusedByName++;
      continue;
    }
    claimed.add(match.id);
    aliases[id] = match.id;
  }

  _applyIngredientAliases(
    aliases,
    ingredients: rawIngredients,
    recipes: rawRecipes,
    mixLog: rawMixLog,
    purchases: rawPurchases,
    adjustments: rawAdjustments,
  );

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
    raw: rawIngredients,
    local: localById,
    parse: Ingredient.fromJson,
    labelOf: (e) => e.displayName,
    stampOf: (e) => e.syncStamp,
    diff: _ingredientDiff,
  );

  consider<Recipe>(
    type: RecordType.recipe,
    raw: rawRecipes,
    local: {for (final e in recipes) e.id: e},
    parse: Recipe.fromJson,
    labelOf: (e) => e.name,
    stampOf: (e) => e.syncStamp,
    diff: (a, b) => _recipeDiff(
      a,
      b,
      baseLabel: (id) {
        if (id == null) return 'none';
        final e = localById[id];
        if (e == null) return 'a bottle you do not have';
        return e.kind == IngredientKind.nicotine && e.nicMgPerMl > 0
            ? '${e.displayName} (${_fmtPct(e.nicMgPerMl)} mg/mL)'
            : e.displayName;
      },
    ),
  );

  consider<MixLog>(
    type: RecordType.mixLog,
    raw: rawMixLog,
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
    raw: rawPurchases,
    local: {for (final e in purchases) e.id: e},
    parse: Purchase.fromJson,
    labelOf: (e) => '${e.ingredientName} +${e.volumeMl.toStringAsFixed(0)} mL',
    stampOf: (e) => e.syncStamp,
    diff: (a, b) => 'no visible difference',
    appendOnly: true,
  );

  consider<StockAdjustment>(
    type: RecordType.adjustment,
    raw: rawAdjustments,
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
    matchedByName: aliases.length,
    refusedByName: refusedByName,
  );
}
