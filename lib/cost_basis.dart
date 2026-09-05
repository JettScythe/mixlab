import 'package:mixlab/models/enums.dart';
import 'package:mixlab/models/ledger.dart';
import 'package:mixlab/models/mix.dart';

/// Cost attributed to one withdrawal from stock.
class CostDraw {
  CostDraw({
    required this.volumeMl,
    required this.cost,
    required this.shortfallMl,
  });

  final double volumeMl;
  final double cost;

  /// Volume drawn beyond what the ledger held, priced at the last known
  /// rate.
  final double shortfallMl;

  bool get estimated => shortfallMl > 1e-9;
}

/// Everything derived from replaying the stock ledger.
class CostReplay {
  CostReplay({
    required this.stockMl,
    required this.basisPerMl,
    required this.stockValue,
    required this.draws,
  });

  final Map<String, double> stockMl;
  final Map<String, double> basisPerMl;
  final Map<String, double> stockValue;

  /// Keyed by [mixDrawKey] or [adjustDrawKey].
  final Map<String, CostDraw> draws;
}

String mixDrawKey(String logId, int lineIndex) => 'm:$logId#$lineIndex';
String adjustDrawKey(String adjustmentId) => 'a:$adjustmentId';

class _Layer {
  _Layer(this.volumeMl, this.costPerMl);
  double volumeMl;
  final double costPerMl;
}

/// Per-ingredient running book of price layers.
class _Book {
  _Book(this.basis);

  final CostBasis basis;
  final List<_Layer> layers = [];

  /// Last price we saw stock enter at. Used to price withdrawals that
  /// exceed the ledger, so a negative balance still has a defensible cost
  /// rather than silently costing nothing.
  double lastRate = 0;

  /// Volume withdrawn beyond what was available.
  double deficitMl = 0;

  /// Rate the outstanding deficit was actually charged out at. Held
  /// separately from [lastRate] because a later purchase at a new price
  /// must not retroactively re-value liquid already charged to a mix.
  /// Volume-weighted when deficits accrue at different rates.
  double deficitRate = 0;

  void add(double ml, double rate) {
    if (ml <= 0) return;

    // An addition first cancels any deficit — that liquid was already
    // charged out at deficitRate when it was withdrawn. Settle that at the
    // old rate *before* adopting the new one, or the unpaid remainder gets
    // valued at a price it was never charged at.
    if (deficitMl > 0) {
      final payback = ml < deficitMl ? ml : deficitMl;
      deficitMl -= payback;
      ml -= payback;
      if (deficitMl <= 1e-12) {
        deficitMl = 0;
        deficitRate = 0;
      }
      if (ml <= 1e-12) {
        if (rate > 0) lastRate = rate;
        return;
      }
    }

    if (rate > 0) lastRate = rate;

    layers.add(_Layer(ml, rate));

    // Moving average is FIFO with the layers blended after every addition.
    if (basis == CostBasis.movingAverage && layers.length > 1) {
      var v = 0.0, c = 0.0;
      for (final l in layers) {
        v += l.volumeMl;
        c += l.volumeMl * l.costPerMl;
      }
      layers
        ..clear()
        ..add(_Layer(v, v > 1e-12 ? c / v : lastRate));
    }
  }

  CostDraw draw(double ml) {
    if (ml <= 0) {
      return CostDraw(volumeMl: 0, cost: 0, shortfallMl: 0);
    }
    var need = ml;
    var cost = 0.0;

    while (need > 1e-12 && layers.isNotEmpty) {
      final l = layers.first;
      final take = need < l.volumeMl ? need : l.volumeMl;
      cost += take * l.costPerMl;
      l.volumeMl -= take;
      need -= take;
      if (l.volumeMl <= 1e-12) layers.removeAt(0);
    }

    var shortfall = 0.0;
    if (need > 1e-12) {
      // Nothing left to draw from. Assume the last price we knew, and
      // remember it — the deficit stays valued at what it was charged.
      cost += need * lastRate;
      deficitRate = deficitMl > 0
          ? (deficitMl * deficitRate + need * lastRate) / (deficitMl + need)
          : lastRate;
      deficitMl += need;
      shortfall = need;
    }

    return CostDraw(volumeMl: ml, cost: cost, shortfallMl: shortfall);
  }

  double get volumeMl {
    var v = 0.0;
    for (final l in layers) {
      v += l.volumeMl;
    }
    return v - deficitMl;
  }

  double get value {
    var c = 0.0;
    for (final l in layers) {
      c += l.volumeMl * l.costPerMl;
    }
    // A deficit carries negative value at the rate it was charged out at,
    // so value and volume stay consistent with each other. Using the
    // current rate instead would move the value of stock already spent
    // every time you restock at a new price.
    return c - deficitMl * deficitRate;
  }

  double get basisPerMl {
    final v = volumeMl;
    return v.abs() > 1e-12 ? value / v : lastRate;
  }
}

class _Event {
  _Event({
    required this.at,
    required this.ingredientId,
    required this.deltaMl,
    required this.tiebreak,
    this.rate = 0,
    this.drawKey,
  });

  final DateTime at;
  final String ingredientId;
  final double deltaMl;
  final double rate;
  final String? drawKey;

  /// Keeps the ordering deterministic when timestamps collide, which
  /// matters because FIFO results depend on sequence.
  final String tiebreak;
}

/// Replays the whole ledger and derives stock, cost basis and the cost of
/// every withdrawal.
///
/// Retroactive by construction: changing [basis], inserting a backdated
/// purchase, or removing an old mix all change the result, because nothing
/// is cached between runs.
///
/// O(n log n) in the number of ledger events, run eagerly after every
/// mutation. At personal-stash scale that is a few hundred events.
CostReplay replayCosts({
  required List<Purchase> purchases,
  required List<StockAdjustment> adjustments,
  required List<MixLog> mixLog,
  required CostBasis basis,
}) {
  final events = <_Event>[];

  for (final p in purchases) {
    events.add(
      _Event(
        at: p.at,
        ingredientId: p.ingredientId,
        deltaMl: p.volumeMl,
        rate: p.volumeMl > 0 ? p.totalCost / p.volumeMl : 0,
        tiebreak: 'p${p.id}',
      ),
    );
  }

  for (final a in adjustments) {
    events.add(
      _Event(
        at: a.at,
        ingredientId: a.ingredientId,
        deltaMl: a.deltaMl,
        rate: a.costPerMl,
        drawKey: a.deltaMl < 0 ? adjustDrawKey(a.id) : null,
        tiebreak: 'a${a.id}',
      ),
    );
  }

  for (final l in mixLog) {
    for (var i = 0; i < l.lines.length; i++) {
      final line = l.lines[i];
      final id = line.ingredientId;
      if (id == null || line.requestedMl <= 0) continue;
      events.add(
        _Event(
          at: l.mixedAt,
          ingredientId: id,
          deltaMl: -line.requestedMl,
          drawKey: mixDrawKey(l.id, i),
          tiebreak: 'm${l.id}#$i',
        ),
      );
    }
  }

  events.sort((x, y) {
    final t = x.at.compareTo(y.at);
    return t != 0 ? t : x.tiebreak.compareTo(y.tiebreak);
  });

  final books = <String, _Book>{};
  final draws = <String, CostDraw>{};

  for (final e in events) {
    final book = books.putIfAbsent(e.ingredientId, () => _Book(basis));
    if (e.deltaMl >= 0) {
      book.add(e.deltaMl, e.rate);
    } else {
      final d = book.draw(-e.deltaMl);
      final key = e.drawKey;
      if (key != null) draws[key] = d;
    }
  }

  return CostReplay(
    stockMl: {for (final e in books.entries) e.key: e.value.volumeMl},
    basisPerMl: {for (final e in books.entries) e.key: e.value.basisPerMl},
    stockValue: {for (final e in books.entries) e.key: e.value.value},
    draws: draws,
  );
}
