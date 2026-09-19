import 'package:flutter/foundation.dart';

import '../core/sheet/cell_range.dart';

/// Which kind of thing the range being built is made of.
///
/// Shift+Space turns the range into whole rows, and a Shift+arrow after it has
/// to go on adding rows rather than falling back to cells — so the kind is
/// kept, not worked out afresh from the range each time.
enum SheetSpan { cells, rows, columns, everything }

/// What is selected in a sheet, kept outside the widget that draws it.
///
/// The [ListingCursor] reason, one dimension up: a source answers with fresh
/// rows as the view scrolls and the grid is rebuilt from them, so a selection
/// living in the grid's state would be lost to every chunk that arrived. And
/// the keys reach the commander screen or the full-screen page first, neither
/// of which can see inside a widget.
///
/// **A selection is ranges, never cells.** A selected column of a million rows
/// is one rectangle; a set of the cells in it would be a million entries built
/// to answer "is this one selected" for the forty on screen.
///
/// Two kinds of range are kept. [fixed] are the ones already put aside — by
/// Insert, or by a press with Ctrl that starts another — and the *current* one
/// runs from [anchor] to [active] and is what Shift and the arrows change.
class SheetSelection extends ChangeNotifier {
  int _rows = 0;
  int _columns = 0;

  CellAddress _active = const CellAddress(0, 0);
  CellAddress _anchor = const CellAddress(0, 0);
  SheetSpan _span = SheetSpan.cells;
  final List<CellRange> _fixed = [];

  /// How many rows the sheet has, as far as is known.
  int get rows => _rows;

  int get columns => _columns;

  /// The cell the keyboard is on: the one outlined, and the one a heading is
  /// lit for.
  CellAddress get active => _active;

  /// Where Shift measures from.
  CellAddress get anchor => _anchor;

  SheetSpan get span => _span;

  /// How many rows and columns fit on screen, told by whoever draws them —
  /// Page Down has no idea how tall the window is.
  int visibleRows = 20;
  int visibleColumns = 6;

  /// Columns the reader has hidden. The keyboard steps over them: a hidden
  /// column is one nobody is to find themselves standing in.
  bool Function(int column)? isHidden;

  /// The range being built.
  CellRange get current => switch (_span) {
    SheetSpan.cells => CellRange.between(_anchor, _active),
    SheetSpan.rows => CellRange.rows(_anchor.row, _active.row),
    SheetSpan.columns => CellRange.columns(_anchor.column, _active.column),
    SheetSpan.everything => CellRange.everything,
  };

  /// The ranges put aside, oldest first.
  List<CellRange> get fixed => List.unmodifiable(_fixed);

  /// Everything selected, the range being built last.
  List<CellRange> get ranges => [..._fixed, current];

  /// One cell and nothing else — the state Escape brings a selection back to,
  /// and the one where Escape has nothing left to do here.
  bool get isSingleCell => _fixed.isEmpty && current.isSingleCell;

  bool contains(int row, int column) {
    if (current.contains(row, column)) return true;
    for (final range in _fixed) {
      if (range.contains(row, column)) return true;
    }
    return false;
  }

  /// Whether any selected range covers some of this row — what lights a row
  /// number.
  bool touchesRow(int row) => ranges.any((r) => r.containsRow(row));

  bool touchesColumn(int column) => ranges.any((r) => r.containsColumn(column));

  /// A heading is lit fully when its whole column is selected, not just a part.
  bool coversColumn(int column) =>
      ranges.any((r) => r.allRows && r.containsColumn(column));

  bool coversRow(int row) =>
      ranges.any((r) => r.allColumns && r.containsRow(row));

  /// How many cells are selected, each counted once however many ranges hold
  /// it — two ranges laid over each other are not twice the cells.
  int get cellCount =>
      _unionArea([for (final r in ranges) ?r.clampTo(_rows, _columns)]);

  /// The sheet is this big now. A sheet still counting its rows calls this
  /// again and again, and nothing selected may move while it does.
  void resize(int rows, int columns) {
    if (rows == _rows && columns == _columns) return;
    _rows = rows < 0 ? 0 : rows;
    _columns = columns < 0 ? 0 : columns;
    _active = _clamp(_active);
    _anchor = _clamp(_anchor);
    _fixed.removeWhere((r) => r.clampTo(_rows, _columns) == null);
    notifyListeners();
  }

  /// Back to one cell at the top left, nothing put aside — a different sheet.
  void reset() {
    _active = const CellAddress(0, 0);
    _anchor = _active;
    _span = SheetSpan.cells;
    _fixed.clear();
    notifyListeners();
  }

  /// Puts the keyboard on [to]. With [extend] the anchor stays and the range
  /// grows to meet it, in whatever it is made of — rows stay rows. Without,
  /// the range becomes that one cell; what was put aside stays put aside,
  /// which is how a second range is started somewhere else.
  void moveTo(CellAddress to, {bool extend = false}) {
    final next = _clamp(to);
    if (extend) {
      if (next == _active) return;
      _active = next;
    } else {
      if (next == _active && _anchor == next && _span == SheetSpan.cells) {
        return;
      }
      _active = next;
      _anchor = next;
      _span = SheetSpan.cells;
    }
    notifyListeners();
  }

  void moveBy(int rows, int columns, {bool extend = false}) => moveTo(
    CellAddress(_active.row + rows, _shown(_active.column, columns)),
    extend: extend,
  );

  /// [by] columns along from [from], counting only the ones not hidden —
  /// and not past the last one that is not.
  int _shown(int from, int by) {
    final hidden = isHidden;
    if (hidden == null || by == 0) return from + by;
    final step = by > 0 ? 1 : -1;
    var at = from;
    var left = by.abs();
    while (left > 0) {
      var next = at + step;
      while (next >= 0 && next < _columns && hidden(next)) {
        next += step;
      }
      if (next < 0 || next >= _columns) break;
      at = next;
      left--;
    }
    return at;
  }

  void pageDown({bool extend = false}) =>
      moveBy(_page(visibleRows), 0, extend: extend);

  void pageUp({bool extend = false}) =>
      moveBy(-_page(visibleRows), 0, extend: extend);

  void pageRight({bool extend = false}) =>
      moveBy(0, _page(visibleColumns), extend: extend);

  void pageLeft({bool extend = false}) =>
      moveBy(0, -_page(visibleColumns), extend: extend);

  void rowStart({bool extend = false}) => moveTo(
    CellAddress(_active.row, _shown(0 - 1, 1).clamp(0, _columns)),
    extend: extend,
  );

  void rowEnd({bool extend = false}) => moveTo(
    CellAddress(_active.row, _shown(_columns, -1).clamp(0, _columns)),
    extend: extend,
  );

  void sheetStart({bool extend = false}) =>
      moveTo(const CellAddress(0, 0), extend: extend);

  void sheetEnd({bool extend = false}) =>
      moveTo(CellAddress(_rows - 1, _columns - 1), extend: extend);

  /// Shift+Space: the rows the range covers, whole.
  void selectRows() {
    final range = current.clampTo(_rows, _columns);
    if (range == null) return;
    _anchor = CellAddress(range.top, _active.column);
    _active = CellAddress(range.bottom, _active.column);
    if (_span == SheetSpan.columns) _span = SheetSpan.everything;
    if (_span == SheetSpan.cells) _span = SheetSpan.rows;
    notifyListeners();
  }

  /// Ctrl+Space (⌥Space on the Mac): the columns the range covers, whole.
  void selectColumns() {
    final range = current.clampTo(_rows, _columns);
    if (range == null) return;
    _anchor = CellAddress(_active.row, range.left);
    _active = CellAddress(_active.row, range.right);
    if (_span == SheetSpan.rows) _span = SheetSpan.everything;
    if (_span == SheetSpan.cells) _span = SheetSpan.columns;
    notifyListeners();
  }

  /// Ctrl+A. What was put aside goes: all of it is already in "everything".
  void selectAll() {
    if (_span == SheetSpan.everything && _fixed.isEmpty) return;
    _fixed.clear();
    _span = SheetSpan.everything;
    notifyListeners();
  }

  /// A press on a column heading. [extend] (Shift) reaches from the anchor's
  /// column; [add] (Ctrl) puts the range so far aside first.
  void pressColumn(int column, {bool extend = false, bool add = false}) {
    if (_rows == 0 || column < 0 || column >= _columns) return;
    if (add) _putAside();
    if (extend && _span == SheetSpan.columns) {
      _active = CellAddress(_active.row, column);
    } else {
      _anchor = CellAddress(_keptRow, extend ? _anchor.column : column);
      _active = CellAddress(_keptRow, column);
      _span = SheetSpan.columns;
    }
    notifyListeners();
  }

  /// A press on a row number, as [pressColumn] is on a heading.
  void pressRow(int row, {bool extend = false, bool add = false}) {
    if (_columns == 0 || row < 0 || row >= _rows) return;
    if (add) _putAside();
    if (extend && _span == SheetSpan.rows) {
      _active = CellAddress(row, _active.column);
    } else {
      _anchor = CellAddress(extend ? _anchor.row : row, _active.column);
      _active = CellAddress(row, _active.column);
      _span = SheetSpan.rows;
    }
    notifyListeners();
  }

  /// A press on a cell with Ctrl: what was being built is put aside and a new
  /// range starts here, to be dragged out from.
  void startAnother(CellAddress at) {
    _putAside();
    _active = _clamp(at);
    _anchor = _active;
    _span = SheetSpan.cells;
    notifyListeners();
  }

  /// Insert: the range being built is put aside as it is, and building starts
  /// again from the cell the keyboard is on. A range that is only that cell
  /// is put aside too — it is how one cell is picked out and the next one
  /// gone to.
  void fixCurrent() {
    _putAside();
    _anchor = _active;
    _span = SheetSpan.cells;
    notifyListeners();
  }

  /// Escape's first job: back to the one cell the keyboard is on. False when
  /// that is already all there is, so the key goes on to its next job.
  bool collapse() {
    if (isSingleCell) return false;
    _fixed.clear();
    _anchor = _active;
    _span = SheetSpan.cells;
    notifyListeners();
    return true;
  }

  /// A range typed into *Go to*, or found by a search. Replaces what was
  /// selected; the keyboard lands on its top left.
  void select(CellRange range) {
    _fixed.clear();
    if (range.isEverything) {
      _span = SheetSpan.everything;
    } else if (range.allRows) {
      _span = SheetSpan.columns;
      _anchor = _clamp(CellAddress(_keptRow, range.left));
      _active = _clamp(CellAddress(_keptRow, range.right));
    } else if (range.allColumns) {
      _span = SheetSpan.rows;
      _anchor = _clamp(CellAddress(range.top, 0));
      _active = _clamp(CellAddress(range.bottom, 0));
    } else {
      _span = SheetSpan.cells;
      _anchor = _clamp(CellAddress(range.bottom, range.right));
      _active = _clamp(CellAddress(range.top, range.left));
    }
    notifyListeners();
  }

  /// What a plugin is told when the selection settles.
  Map<String, Object?> toJson() => {
    'active': {'row': _active.row, 'column': _active.column},
    'ranges': [for (final r in ranges) r.toJson()],
  };

  /// The row the keyboard stays on when a whole column is taken — the one it
  /// was on, so pressing a heading does not throw the view back to the top.
  int get _keptRow => _active.row;

  int _page(int visible) => visible > 1 ? visible - 1 : 1;

  CellAddress _clamp(CellAddress at) {
    final row = _rows == 0 ? 0 : at.row.clamp(0, _rows - 1);
    final column = _columns == 0 ? 0 : at.column.clamp(0, _columns - 1);
    if (row == at.row && column == at.column) return at;
    return CellAddress(row, column);
  }

  /// Puts the range being built aside — unless it is already inside one
  /// that is. After Insert the range is the one cell the keyboard is on, and
  /// that cell is usually in what was just put aside; a Ctrl+press after it
  /// would put the cell aside a second time and draw it twice as strong.
  void _putAside() {
    final range = current;
    if (_fixed.any((r) => r.covers(range))) return;
    _fixed.add(range);
  }
}

/// The area a handful of rectangles cover together.
///
/// Cut along every edge any of them has, then count each piece once if any
/// rectangle holds it. A selection is a few ranges, so the pieces are few; a
/// sweep line would be faster and would be written for nobody.
int _unionArea(List<CellRange> ranges) {
  if (ranges.isEmpty) return 0;
  if (ranges.length == 1) {
    final r = ranges.first;
    return (r.bottom - r.top + 1) * (r.right - r.left + 1);
  }
  final ys = <int>{
    for (final r in ranges) ...[r.top, r.bottom + 1],
  }.toList()..sort();
  final xs = <int>{
    for (final r in ranges) ...[r.left, r.right + 1],
  }.toList()..sort();
  var area = 0;
  for (var i = 0; i + 1 < ys.length; i++) {
    for (var j = 0; j + 1 < xs.length; j++) {
      final y = ys[i];
      final x = xs[j];
      if (ranges.any((r) => r.contains(y, x))) {
        area += (ys[i + 1] - y) * (xs[j + 1] - x);
      }
    }
  }
  return area;
}
