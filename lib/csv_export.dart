import 'package:mixlab/models/enums.dart';

import 'state.dart';

/// Hand-rolled CSV for one [value].
///
/// RFC 4180 would have every field quoted; spreadsheet users do not in
/// fact want quotes around everything, and no spreadsheet misreads an
/// unquoted field that contains none of the special characters. Quote only
/// when the value forces it: a separator, a quote, or a line break. The
/// one thing not negotiable is doubling embedded quotes — a name like
/// `5" round` unquoted would break the row.
String csvField(Object? value) {
  final s = switch (value) {
    null => '',
    double v => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString(),
    _ => value.toString(),
  };
  // A leading '=' or '+' would execute as a formula in Excel, so those get
  // quoted even without a separator present — the name "=1+1" is data, not
  // arithmetic somebody else's spreadsheet should perform.
  final needsQuoting =
      s.contains(',') ||
      s.contains('"') ||
      s.contains('\n') ||
      s.startsWith('=') ||
      s.startsWith('+') ||
      s.startsWith('-') && s.length > 1 && double.tryParse(s) == null;
  return needsQuoting ? '"${s.replaceAll('"', '""')}"' : s;
}

/// One CSV row. Fields containing separators are quoted per [csvField].
String csvRow(List<Object?> fields) => fields.map(csvField).join(',');

/// The whole state as three CSV blocks in one document, with a header line
/// before each. One file rather than three: the export menu already has a
/// JSON button, and three more entries for three more files is the kind of
/// thing that stops being maintainable the first time a fourth table
/// appears.
///
/// The `#` block headers are for a human skimming the file in an editor —
/// no spreadsheet treats them as comments, so they arrive as one-field
/// rows. That is the accepted trade for one file instead of three; within
/// a block, every data row has exactly the header's field count.
///
/// Numbers are written unrounded — the point of a spreadsheet export is
/// doing arithmetic this app does not — and stock is the live derived
/// figure, matching what the inventory screen shows.
String exportCsv({required AppState appState}) {
  final ingredients = appState.ingredients;
  final recipes = appState.recipes;
  final mixLog = appState.mixLog;
  final out = StringBuffer();

  out.writeln('# MixLab inventory');
  out.writeln(
    csvRow([
      'brand',
      'name',
      'kind',
      'nicotine (mg/mL)',
      'carrier VG %',
      'density (g/mL)',
      'stock (mL)',
      'stock (g)',
      'bottle size (mL)',
      'bottle cost (${appState.settings.currency})',
      'cost per mL (${appState.settings.currency})',
      'stock value (${appState.settings.currency})',
    ]),
  );
  for (final e in ingredients) {
    out.writeln(
      csvRow([
        e.brand,
        e.name,
        kindLabel(e.kind),
        e.nicMgPerMl,
        e.carrierVg * 100,
        e.density,
        e.stockMl,
        e.stockGrams,
        e.bottleSizeMl,
        e.bottleCost,
        e.costPerMl,
        e.stockValue,
      ]),
    );
  }

  out.writeln();
  out.writeln('# MixLab recipes');
  out.writeln(
    csvRow([
      'name',
      'batch (mL)',
      'nicotine (mg/mL)',
      'VG %',
      'base mode',
      'flavor %',
      'flavor count',
      'times mixed',
      'favorite',
      'tags',
    ]),
  );
  for (final r in recipes) {
    out.writeln(
      csvRow([
        r.name,
        r.batchMl,
        r.targetNic,
        r.baseMode == BaseMode.maxVg ? null : r.targetVgPercent,
        baseModeLabel(r.baseMode),
        r.totalFlavorPercent,
        r.flavors.length,
        appState.mixCountForRecipe(r.id),
        r.favorite ? 'yes' : 'no',
        r.tags.join(' '),
      ]),
    );
  }

  out.writeln();
  out.writeln('# MixLab mix history');
  out.writeln(
    csvRow([
      'date',
      'label',
      'batch (mL)',
      'target nicotine (mg/mL)',
      'actual nicotine (mg/mL)',
      'actual VG %',
      'juice cost',
      'hardware cost',
      'total cost',
      'rating',
      'tasting notes',
    ]),
  );
  for (final l in mixLog) {
    out.writeln(
      csvRow([
        l.mixedAt.toIso8601String(),
        l.label,
        l.batchMl,
        l.targetNic,
        l.actualNic,
        l.actualVgPercent,
        l.totalCost,
        l.hardwareCost,
        l.grandTotalCost,
        l.rating ?? '',
        l.tastingNotes,
      ]),
    );
  }

  return out.toString();
}
