import 'package:intl/intl.dart';
import 'package:mixlab/models/settings.dart';

NumberFormat? _moneyFormat;
String? _moneyCurrency;

double clampd(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// Rounds to the nearest [step]. A step <= 0 is a no-op.
double roundTo(double v, double step) =>
    step <= 0 ? v : (v / step).round() * step;

/// Rounds a percentage to 2 decimals, so reconstructed recipes don't show
/// 7.999999999 after a division round-trip.
double roundPercent(double v) => (v * 100).round() / 100;

/// Locale-tolerant, non-negative number parsing.
double? parseNum(String s) {
  final t = s.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  if (v == null || v.isNaN || v.isInfinite || v < 0) return null;
  return v;
}

const knownBrands = <String, String>{
  'TFA': 'The Flavor Apprentice',
  'TPA': 'The Flavor Apprentice',
  'CAP': 'Capella',
  'FW': 'Flavor West',
  'FA': 'FlavourArt',
  'LA': 'LorAnn',
  'INW': 'Inawera',
  'JF': 'Jungle Flavors',
  'MF': 'Medicine Flower',
  'RF': 'Real Flavors',
  'WF': 'Wonder Flavours',
  'VT': 'Vape Train',
  'HS': 'Hangsen',
  'FLV': 'Flavorah',
  'OOO': 'One On One',
  'PUR': 'Purilum',
  'CLY': 'Clyrolinx',
};

/// Splits a leading recognised brand shorthand off a combined name.
(String, String) splitBrand(String full) {
  final t = full.trim();
  final i = t.indexOf(' ');
  if (i <= 0) return ('', t);
  final head = t.substring(0, i).toUpperCase();
  if (!knownBrands.containsKey(head)) return ('', t);
  final rest = t.substring(i + 1).trim();
  return rest.isEmpty ? ('', t) : (head, rest);
}

/// Locale-correct currency formatting, falling back to a plain suffix for
/// codes intl does not recognise.

/// Snackbar timings. Plain confirmations vanish fast; anything with an undo
/// action stays long enough to actually click it.
const toastShort = Duration(milliseconds: 1500);
const toastUndo = Duration(seconds: 5);

String money(double v, Settings s) {
  if (_moneyCurrency != s.currency) {
    _moneyCurrency = s.currency;
    try {
      _moneyFormat = NumberFormat.simpleCurrency(name: s.currency);
    } catch (_) {
      _moneyFormat = null;
    }
  }
  final f = _moneyFormat;
  return f == null ? '${v.toStringAsFixed(2)} ${s.currency}' : f.format(v);
}

NumberFormat? _mlFormat;
String? _mlCurrency;

NumberFormat? _perMlFormat(String currency) {
  if (_mlCurrency != currency) {
    _mlCurrency = currency;
    try {
      _mlFormat = NumberFormat.decimalPatternDigits(decimalDigits: 3);
    } catch (_) {
      _mlFormat = null;
    }
  }
  return _mlFormat;
}

/// Per-mL figures keep three decimals — rounding to cents hides the
/// difference between ingredients — and carry the ISO code rather than the
/// locale symbol, because `$0.123` reads like a typo next to `$1.03`. The
/// symbol form stays on totals via [money]; this matches the per-mL style
/// `stock_history_page` and the cost-basis figures have always used.
String moneyPerMl(double v, Settings s) =>
    '${_perMlFormat(s.currency)?.format(v) ?? v.toStringAsFixed(3)} '
    '${s.currency}/mL';
