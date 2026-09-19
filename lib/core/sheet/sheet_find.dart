import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'cell_range.dart';
import 'sheet_source.dart';

/// A search through a sheet, over every row there is — not only the ones on
/// screen, and not only the ones already read.
///
/// **It reads the sheet as it goes.** A million-row file has most of its rows
/// nowhere in memory, so the search asks the source for them a piece at a time,
/// the same way scrolling does, and the listeners hear after every piece: the
/// count in the box climbs while it runs, and the first match is shown the
/// moment it is found rather than when the last row has been looked at.
///
/// A cell matches when the text it is *shown* as holds the query, whatever the
/// case — the formatted "1 250,50 ₽", not the number behind it, because the
/// reader searches for what they can see.
class SheetSearch extends ChangeNotifier {
  SheetSearch(
    this.source,
    String query, {
    List<CellRange>? within,
    this.skipColumns,
  }) : query = query.toLowerCase(),
       _ranges = within;

  /// Columns not to look in — the ones the reader has hidden.
  final Set<int>? skipColumns;

  final SheetSource source;

  /// What is looked for, folded to lower case.
  final String query;

  /// Only these, when the search was asked for inside a selection. In the
  /// source's own rows.
  final List<CellRange>? _ranges;

  /// Past this many the search stops and says so: a search for "1" in a
  /// million numbers finds everything, and a list of everything helps nobody.
  static const int cap = 100000;

  /// Rows read at once.
  static const int step = 4096;

  final List<int> _rows = [];
  final List<int> _columns = [];
  final HashSet<int> _keys = HashSet();
  bool _done = false;
  bool _capped = false;
  bool _cancelled = false;

  int get count => _rows.length;
  bool get done => _done;

  /// Stopped at [cap] with more of the sheet still to read.
  bool get capped => _capped;

  /// The [index]th match, in reading order: along each row, then down.
  CellAddress operator [](int index) =>
      CellAddress(_rows[index], _columns[index]);

  bool isMatch(int row, int column) => _keys.contains(_key(row, column));

  /// The rows with a match in them, each once, top to bottom — what the
  /// filter shows.
  List<int> get matchingRows {
    final out = <int>[];
    for (final row in _rows) {
      if (out.isEmpty || out.last != row) out.add(row);
    }
    return out;
  }

  /// The first match at [at] or after it, in reading order — where F3 goes
  /// from wherever the keyboard is. Wraps to the first when there is none.
  int indexFrom(CellAddress at) {
    var lo = 0;
    var hi = _rows.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final r = _rows[mid];
      if (r < at.row || (r == at.row && _columns[mid] < at.column)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < _rows.length ? lo : 0;
  }

  void cancel() => _cancelled = true;

  static int _key(int row, int column) => row * 65536 + column;

  /// Runs the search to the end of the sheet, or until it is cancelled.
  Future<void> run() async {
    if (query.isEmpty) {
      _done = true;
      notifyListeners();
      return;
    }
    final within = _ranges;
    final skip = skipColumns;
    var from = 0;
    var last = -1; // no end but the sheet's
    if (within != null && within.isNotEmpty) {
      from = within.map((r) => r.allRows ? 0 : r.top).reduce(math.min);
      if (!within.any((r) => r.allRows)) {
        last = within.map((r) => r.bottom).reduce(math.max);
      }
    }

    while (!_cancelled) {
      if (last >= 0 && from > last) break;
      if (from >= source.rowCount && !source.counting) break;
      final rows = await source.readRows(from, step);
      if (_cancelled) return;
      if (rows.isEmpty) {
        // Nothing more has arrived: a source that failed, or a count that has
        // not reached this far and is no longer counting.
        if (!source.counting || source.error != null) break;
        continue;
      }
      var end = from + rows.length;
      if (last >= 0 && end > last + 1) end = last + 1;
      for (var row = from; row < end; row++) {
        final values = rows[row - from];
        for (var column = 0; column < values.length; column++) {
          if (skip != null && skip.contains(column)) continue;
          if (within != null && !within.any((r) => r.contains(row, column))) {
            continue;
          }
          final text = sheetText(values[column]);
          if (text.length < query.length) continue;
          if (!text.toLowerCase().contains(query)) continue;
          _rows.add(row);
          _columns.add(column);
          _keys.add(_key(row, column));
          if (_rows.length >= cap) {
            _capped = true;
            _done = true;
            notifyListeners();
            return;
          }
        }
      }
      from = end;
      notifyListeners();
    }
    if (_cancelled) return;
    _done = true;
    notifyListeners();
  }
}
