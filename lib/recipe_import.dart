import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/ingredient.dart';
import 'package:mixlab/models/recipe.dart';
import 'package:mixlab/models/units.dart';

/// One parsed ingredient line from pasted recipe text.
class ParsedLine {
  ParsedLine({
    required this.raw,
    required this.name,
    required this.brand,
    required this.percent,
  });

  final String raw;
  final String name;
  final String brand;
  final double percent;

  String get displayName => brand.isEmpty ? name : '$brand $name';
}

/// Result of parsing a pasted block of text.
class ParsedRecipe {
  ParsedRecipe({
    this.name,
    this.batchMl,
    this.nic,
    this.vgPercent,
    this.maxVg = false,
    List<ParsedLine>? lines,
    List<String>? ignored,
  }) : lines = lines ?? [],
       ignored = ignored ?? [];

  String? name;
  double? batchMl;
  double? nic;
  double? vgPercent;
  bool maxVg;

  final List<ParsedLine> lines;

  /// Lines that looked like content but could not be understood. Shown to
  /// the user rather than silently dropped.
  final List<String> ignored;

  double get totalPercent => lines.fold(0.0, (a, l) => a + l.percent);
  bool get isEmpty => lines.isEmpty;
}

/// Vendor spellings that appear in shared recipes but are not the key we
/// store under. Maps alias to the canonical key in [knownBrands].
const _brandAliases = <String, String>{
  'TPA': 'TFA',
  'THE FLAVOR APPRENTICE': 'TFA',
  'FLAVOUR ART': 'FA',
  'FLAVOURART': 'FA',
  'CAPELLA': 'CAP',
  'FLAVOR WEST': 'FW',
  'FLAVORWEST': 'FW',
  'LORANN': 'LA',
  'INAWERA': 'INW',
  'FLAVORAH': 'FLV',
  'REAL FLAVORS': 'RF',
  'ONE ON ONE': 'OOO',
  'WONDER FLAVOURS': 'WF',
  'MEDICINE FLOWER': 'MF',
  'JUNGLE FLAVORS': 'JF',
  'VAPE TRAIN': 'VT',
  'PURILUM': 'PUR',
};

/// Resolves a vendor token to a canonical brand key, or '' if unrecognised.
///
/// Aliases are checked before [knownBrands], because some aliases are also
/// keys in their own right — 'TPA' is a real vendor shorthand but we
/// normalise it to 'TFA' so both spellings match one inventory entry.
String canonicalBrand(String token) {
  final t = token.trim().toUpperCase().replaceAll('.', '');
  if (t.isEmpty) return '';
  final alias = _brandAliases[t];
  if (alias != null) return alias;
  if (knownBrands.containsKey(t)) return t;
  return '';
}

final _percentRe = RegExp(r'(\d+(?:[.,]\d+)?)\s*%');
final _bareNumRe = RegExp(r'^\d+(?:[.,]\d+)?$');
final _trailingNumRe = RegExp(r'(?:^|\s)(\d+(?:[.,]\d+)?)\s*$');
final _parenBrandRe = RegExp(r'[(\[]([^()\[\]]{1,24})[)\]]\s*$');
final _bulletRe = RegExp(r'^[-•*·]+\s+');
final _columnSplitRe = RegExp(r'\t|\s{2,}|\s*\|\s*');
final _maxVgRe = RegExp(r'max\s*-?\s*vg', caseSensitive: false);
final _mgRe = RegExp(r'(\d+(?:[.,]\d+)?)\s*mg\b', caseSensitive: false);
final _mlRe = RegExp(r'(\d+(?:[.,]\d+)?)\s*ml\b', caseSensitive: false);
final _vgRe = RegExp(r'(\d+(?:[.,]\d+)?)\s*%?\s*vg\b', caseSensitive: false);
final _pgRe = RegExp(r'(\d+(?:[.,]\d+)?)\s*%?\s*pg\b', caseSensitive: false);
final _ratioRe = RegExp(r'\b(\d{1,3})\s*/\s*(\d{1,3})\b');

double? _num(String? s) => s == null ? null : parseNum(s);

/// Structural lines — column headers, links, attribution. Only consulted
/// after a line has failed to parse as metadata or as an ingredient, so a
/// real ingredient containing one of these words is never discarded.
bool _isHeaderish(String lower) {
  const markers = [
    'ingredient',
    'flavor total',
    'flavour total',
    'total flavor',
    'total flavour',
    'vendor',
    'percentage',
    'amount',
    'steep',
    'shake',
    'http',
    'www.',
    'created by',
    'author',
    'copied',
    'notes:',
    'made by',
  ];
  final t = lower.trim();
  if (t.isEmpty) return true;
  for (final m in markers) {
    if (t.contains(m)) return true;
  }
  return false;
}

/// Reads recipe-level settings from a line. Returns true only when the line
/// is essentially pure metadata, so "Strawberry 8% (30ml bottle)" stays an
/// ingredient while "30ml, 70/30, 3mg" is consumed.
bool _readMeta(String line, ParsedRecipe out) {
  final lower = line.toLowerCase();
  var matched = false;

  // "70/30" or "70 / 30" — first number is conventionally VG in DIY.
  final ratio = _ratioRe.firstMatch(lower);
  if (ratio != null && (lower.contains('vg') || lower.contains('pg'))) {
    final a = _num(ratio.group(1));
    final b = _num(ratio.group(2));
    if (a != null && b != null) {
      final pgAt = lower.indexOf('pg');
      final vgAt = lower.indexOf('vg');
      // "30/70 PG/VG" puts VG second.
      final pgFirst = pgAt >= 0 && (vgAt < 0 || pgAt < vgAt);
      out.vgPercent ??= pgFirst ? b : a;
      matched = true;
    }
  }

  final vg = _vgRe.firstMatch(lower);
  if (vg != null) {
    out.vgPercent ??= _num(vg.group(1));
    matched = true;
  } else {
    final pg = _pgRe.firstMatch(lower);
    if (pg != null) {
      final p = _num(pg.group(1));
      if (p != null) out.vgPercent ??= 100 - p;
      matched = true;
    }
  }

  final mg = _mgRe.firstMatch(lower);
  if (mg != null) {
    out.nic ??= _num(mg.group(1));
    matched = true;
  }

  final ml = _mlRe.firstMatch(lower);
  if (ml != null) {
    out.batchMl ??= _num(ml.group(1));
    matched = true;
  }

  if (!matched) return false;

  // Consume the line only if nothing word-like is left over.
  final leftover = lower
      .replaceAll(_mgRe, ' ')
      .replaceAll(_mlRe, ' ')
      .replaceAll(_vgRe, ' ')
      .replaceAll(_pgRe, ' ')
      .replaceAll(_ratioRe, ' ')
      .replaceAll(RegExp(r'[^a-z]'), '');
  return leftover.length < 4;
}

/// Splits a brand out of a name, checking a trailing "(TPA)" style vendor
/// first and then a leading shorthand.
(String, String) _extractBrand(String text) {
  var s = text.trim();

  final paren = _parenBrandRe.firstMatch(s);
  if (paren != null) {
    final b = canonicalBrand(paren.group(1)!);
    if (b.isNotEmpty) {
      s = s.substring(0, paren.start).trim();
      return (b, s);
    }
  }

  final space = s.indexOf(RegExp(r'[\s\t]'));
  if (space > 0) {
    final b = canonicalBrand(s.substring(0, space));
    if (b.isNotEmpty) {
      final rest = s.substring(space + 1).trim();
      if (rest.isNotEmpty) return (b, rest);
    }
  }

  return ('', s);
}

String _cleanName(String s) => s
    .replaceAll(RegExp(r'^[\s\t|,;:-]+'), '')
    .replaceAll(RegExp(r'[\s\t|,;:-]+$'), '')
    .replaceAll(RegExp(r'\s{2,}'), ' ')
    .trim();

/// Attempts to read one ingredient line. Returns null if there is no usable
/// name-and-percentage pair.
ParsedLine? _tryIngredient(String line) {
  double? percent;
  var namePart = line;
  var brand = '';

  // Tab or multi-space columns, as produced by spreadsheets and the ELR
  // table view.
  final fields = line
      .split(_columnSplitRe)
      .map((f) => f.trim())
      .where((f) => f.isNotEmpty)
      .toList();

  if (fields.length >= 2) {
    var pctIndex = -1;
    for (var k = fields.length - 1; k >= 0; k--) {
      final f = fields[k];
      if (_percentRe.hasMatch(f) || _bareNumRe.hasMatch(f)) {
        percent = _num(
          _percentRe.firstMatch(f)?.group(1) ?? f.replaceAll('%', ''),
        );
        pctIndex = k;
        break;
      }
    }
    if (pctIndex >= 0) {
      final rest = [
        for (var k = 0; k < fields.length; k++)
          if (k != pctIndex) fields[k],
      ];
      // A short standalone field is very likely the vendor column.
      for (var k = rest.length - 1; k >= 0; k--) {
        final b = canonicalBrand(rest[k]);
        if (b.isNotEmpty && rest.length > 1) {
          brand = b;
          rest.removeAt(k);
          break;
        }
      }
      namePart = rest.join(' ');
    }
  }

  if (percent == null) {
    final m = _percentRe.firstMatch(line);
    if (m != null) {
      percent = _num(m.group(1));
      namePart = line.replaceRange(m.start, m.end, ' ');
    } else {
      final t = _trailingNumRe.firstMatch(line);
      if (t != null) {
        percent = _num(t.group(1));
        namePart = line.substring(0, t.start);
      }
    }
  }

  if (percent == null || percent <= 0) return null;

  if (brand.isEmpty) {
    final (b, n) = _extractBrand(namePart);
    brand = b;
    namePart = n;
  }

  final name = _cleanName(namePart);
  if (name.isEmpty) return null;

  return ParsedLine(
    raw: line.trim(),
    name: name,
    brand: brand,
    percent: percent,
  );
}

/// Parses pasted recipe text from ELR, AllTheFlavors, a spreadsheet, or a
/// forum post.
///
/// Each line is tried as max-VG marker, then metadata, then an ingredient,
/// and only then as a title or noise. That order matters: an ingredient
/// whose name happens to contain a header word like "vendor" must not be
/// mistaken for a column header, and a first line reading "Max VG" must not
/// be mistaken for the recipe title.
ParsedRecipe parseRecipeText(String input) {
  final out = ParsedRecipe();
  var sawIngredient = false;

  for (final original in input.split(RegExp(r'[\r\n]+'))) {
    var line = original.replaceAll('\u00a0', ' ').trim();
    if (line.isEmpty) continue;
    line = line.replaceFirst(_bulletRe, '').trim();
    if (line.isEmpty) continue;

    // Max VG, which may sit alone or alongside other metadata.
    if (_maxVgRe.hasMatch(line)) {
      out.maxVg = true;
      out.vgPercent ??= 100;
      final leftover = line
          .toLowerCase()
          .replaceAll(_maxVgRe, ' ')
          .replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (leftover.isEmpty) continue;
    }

    if (_readMeta(line, out)) continue;

    final parsed = _tryIngredient(line);
    if (parsed != null) {
      out.lines.add(parsed);
      sawIngredient = true;
      continue;
    }

    final lower = line.toLowerCase();

    // The first ordinary line before any ingredient is probably the title.
    if (!sawIngredient &&
        out.name == null &&
        !_isHeaderish(lower) &&
        line.length < 80) {
      out.name = line;
      continue;
    }

    if (!_isHeaderish(lower)) out.ignored.add(original.trim());
  }

  return out;
}

/// Renders a recipe as the plain text people actually paste to each other.
///
/// The output is deliberately in the dialect [parseRecipeText] reads, so a
/// recipe shared out of MixLab can be pasted straight back in — here or on
/// someone else's install — without losing the batch size, nicotine or
/// ratio. There is no MixLab-specific envelope: the point is that it drops
/// into a forum post or a message unchanged.
///
/// Bases are named in a comment rather than as data. A base is a bottle in
/// *this* inventory, so shipping its id would be meaningless elsewhere,
/// but which base a recipe was built around is worth telling a human.
String recipeToText(
  Recipe r, {
  String Function(String ingredientId)? nameOf,
  String? nicBaseName,
  String? pgName,
  String? vgName,
}) {
  final out = StringBuffer();
  final name = r.name.trim();
  out.writeln(name.isEmpty ? 'Untitled recipe' : name);
  out.writeln();

  for (final f in r.flavors) {
    final label = nameOf?.call(f.ingredientId) ?? f.name;
    out.writeln('${_fmtPercent(f.percent)}% $label');
  }
  if (r.flavors.isEmpty) out.writeln('(no flavors — base only)');
  out.writeln();

  // The metadata line the parser consumes whole.
  final bits = <String>[
    '${_fmtNumber(r.batchMl)}ml',
    if (r.baseMode == BaseMode.maxVg)
      'Max VG'
    else
      '${_fmtNumber(r.targetVgPercent)}/'
          '${_fmtNumber(100 - r.targetVgPercent)} VG/PG',
    '${_fmtNumber(r.targetNic)}mg',
  ];
  out.writeln(bits.join(', '));

  if (r.percentMode == PercentMode.byWeight) {
    out.writeln('Percentages are by weight.');
  }

  final bases = <String>[
    if (nicBaseName != null) 'nicotine $nicBaseName',
    if (pgName != null) 'PG $pgName',
    if (vgName != null) 'VG $vgName',
  ];
  if (bases.isNotEmpty) out.writeln('Mixed with: ${bases.join(', ')}.');

  final notes = r.notes.trim();
  if (notes.isNotEmpty) {
    out.writeln();
    out.writeln(notes);
  }

  return out.toString().trimRight();
}

/// Percentages keep two decimals at most, and drop a trailing '.0'.
String _fmtPercent(double v) {
  final r = roundPercent(v);
  return r == r.roundToDouble()
      ? r.toStringAsFixed(0)
      : r.toString().replaceFirst(RegExp(r'0+$'), '');
}

String _fmtNumber(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

String _normalize(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Finds the inventory ingredient a parsed line refers to, or null.
/// Tries exact brand+name, then name within the same brand, then a unique
/// name match across all concentrates.
Ingredient? matchParsedLine(ParsedLine line, Iterable<Ingredient> inventory) {
  final items = [
    for (final e in inventory)
      if (isConcentrate(e.kind)) e,
  ];
  final wantName = _normalize(line.name);
  final wantFull = _normalize(line.displayName);

  for (final e in items) {
    if (_normalize(e.displayName) == wantFull) return e;
  }
  if (line.brand.isNotEmpty) {
    for (final e in items) {
      if (e.brand == line.brand && _normalize(e.name) == wantName) return e;
    }
  }
  final byName = [
    for (final e in items)
      if (_normalize(e.name) == wantName) e,
  ];
  if (byName.length == 1) return byName.first;
  return null;
}
