import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show kDoubleTapTimeout, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/platform/key_letters.dart';
import '../../core/plugins/view.dart' show ViewCommand, ViewMenuItem;
import '../../core/settings/appearance_settings.dart';
import '../../core/sheet/cell_range.dart';
import '../../core/sheet/sheet_copy.dart';
import '../../core/sheet/sheet_find.dart';
import '../../core/sheet/sheet_measure.dart';
import '../../core/sheet/sheet_sort.dart';
import '../../core/sheet/sheet_source.dart';
import '../../state/sheet_selection.dart';
import '../dialogs/common_dialogs.dart';
import '../notice.dart';
import '../viewer/diff_syntax.dart' show DiffColours;
import '../motion.dart';
import '../viewer/bottom_inset.dart';
import '../viewer/find_box.dart';
import '../plugins/plugin_table.dart' show appearanceOf;
import '../plugins/view_pill.dart';
import '../widgets/context_menu.dart';

/// A sheet: rows and columns of cells, read a screen at a time.
///
/// **Painted, not built.** One render object draws the cells that are on
/// screen and nothing else. A widget per cell would be fifty columns by sixty
/// rows relaid on every frame of a scroll, which is exactly the kind of work
/// that froze F3 on a big file before; here a scroll repaints, and a cell's
/// text is laid out once and kept while it stays near the screen.
///
/// The heading row and the row numbers are always there and never scroll
/// away. What is selected lives in a [SheetSelection] beside the view rather
/// than in it, so a source answering with fresh rows cannot lose it.
class SheetView extends StatefulWidget {
  const SheetView({
    super.key,
    required this.source,
    this.selection,
    this.isActive = true,
    bool? hasKeyboard,
  }) : hasKeyboard = hasKeyboard ?? isActive;

  final SheetSource source;

  /// Null for a sheet nothing outside drives, which then keeps its own.
  final SheetSelection? selection;

  /// Whether this is the thing being worked in. The outline of the active
  /// cell pales when it is not, as an inactive panel's cursor does.
  final bool isActive;

  /// Whether the keys are this sheet's. Only for the thing being worked in: a
  /// sheet previewed in the panel beside the one being typed in must not take
  /// the arrows away from it. When it has them, it has them *first* — before
  /// the panel's own Ctrl+A, Ctrl+C and Escape — and whatever it does not
  /// use goes on up to the panel as before.
  final bool hasKeyboard;

  @override
  State<SheetView> createState() => SheetViewState();
}

/// The widths a column may be given by fitting: never so narrow that a
/// number is cut, never so wide that one long cell takes the screen.
const int _minColumnChars = 4;
const int _maxColumnChars = 40;

/// Room either side of a cell's text.
const double _cellPadding = 6;

/// How close to a heading's edge the pointer has to be to take hold of it.
const double _edgeReach = 4;

/// How wide the sorting arrow at the right of a heading is to press.
const double _sortZone = 20;

/// How far Ctrl+arrow looks for the edge of the data before it gives up and
/// goes to the end. Every row it passes has to be read, and a column with no
/// gap in a million rows would be a million rows read for one key.
const int _edgeSearchRows = 50000;

/// The shapes a selection can be copied in.
enum SheetCopyFormat {
  /// Tab-separated, as a spreadsheet takes it back.
  tsv,
  json,

  /// With the header's names as its first line, when there is a header.
  csv,

  /// A table to paste into a document or a message.
  markdown,
}

/// What a press landed on.
sealed class _Hit {
  const _Hit();
}

class _CornerHit extends _Hit {
  const _CornerHit();
}

class _HeadingHit extends _Hit {
  const _HeadingHit(this.column);
  final int column;
}

class _GutterHit extends _Hit {
  const _GutterHit(this.row);
  final int row;
}

class _CellHit extends _Hit {
  const _CellHit(this.at);
  final CellAddress at;
}

/// What a drag started on, and so what it goes on extending.
enum _Drag { none, cells, columns, rows, resize }

/// Column widths the reader has given sheets, by file and page, for as long
/// as the application runs — so a file opened again is as it was left, and
/// a width dragged by hand is not undone by pressing F3 twice.
final LinkedHashMap<String, List<double>> _rememberedWidths = LinkedHashMap();

class SheetViewState extends State<SheetView> with TickerProviderStateMixin {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();
  SheetSelection? _own;
  final _TextCache _texts = _TextCache();

  /// The column widths as they stand, for a test to measure.
  @visibleForTesting
  List<double> get columnWidths => List.unmodifiable(_widths);

  /// How many rows and columns are frozen.
  @visibleForTesting
  (int, int) get frozenPanes => (_frozenRows, _frozenColumns);

  /// The column the rows are sorted by, and whether the order is still
  /// being worked out.
  @visibleForTesting
  (int?, bool) get sortState => (_sortColumn, _sorting);

  /// The middle of a cell, across the view, before any scrolling.
  @visibleForTesting
  Offset cellCentre(int row, int column) {
    final g = _geometry!;
    final r = g.cellRect(row, column);
    return Offset(g.gutter, g.head) + r.center;
  }

  /// The height of the heading row and the width of the row numbers.
  @visibleForTesting
  Size get frozen => Size(_geometry!.gutter, _geometry!.head);

  /// Where a column's right edge is, across the view, before any scrolling.
  @visibleForTesting
  double columnEdge(int column) {
    final g = _geometry!;
    return g.gutter + g.lefts[column + 1];
  }

  SheetSelection get selection =>
      widget.selection ?? (_own ??= SheetSelection());

  /// Column widths, in logical pixels. Fitted once from the first rows that
  /// arrive and left alone after that — a column that changed width as rows
  /// were scrolled past would move what somebody was reading.
  List<double> _widths = const [];
  bool _fitted = false;

  /// The selection's outline and the range being built, gliding from where
  /// they were to where the keyboard put them.
  late final AnimationController _glide = AnimationController(vsync: this);
  Rect? _activeFrom;
  Rect? _activeTo;
  Rect? _rangeFrom;
  Rect? _rangeTo;
  CellAddress? _lastActive;
  CellRange? _lastRange;

  /// A column being fitted eases to its width rather than jumping to it.
  late final AnimationController _ease = AnimationController(vsync: this);
  List<double>? _widthsFrom;
  List<double>? _widthsTo;

  /// A heading edge being dragged: which column, where the drag began, and
  /// the width it had then.
  int? _resizing;
  double _resizeStartX = 0;
  double _resizeStartWidth = 0;
  int _lastEdge = -1;
  CellAddress? _lastCell;
  DateTime? _lastCellAt;
  DateTime? _lastEdgeAt;
  MouseCursor _cursor = MouseCursor.defer;

  AppearanceSettings? _theme;
  _Geometry? _geometry;

  final FocusNode _node = FocusNode(debugLabel: 'sheet');
  _Drag _drag = _Drag.none;

  // --- Finding ---
  final TextEditingController _query = TextEditingController();
  final FocusNode _box = FocusNode(debugLabel: 'find in sheet');
  bool _finding = false;
  SheetSearch? _search;
  int _current = -1;

  /// Where the keyboard was when the search began, in the source's rows: the
  /// first match shown is the first one from there on, not from the top.
  CellAddress _findFrom = const CellAddress(0, 0);

  /// What was selected when the box was opened, in the source's rows — the
  /// search looks only there when [_inSelection] is on. Taken once: going
  /// to a match moves the selection, and the scope must not move with it.
  List<CellRange>? _scope;
  bool _inSelection = false;
  bool _filtered = false;
  Timer? _typing;

  // --- Sorting ---
  int? _sortColumn;
  bool _descending = false;
  bool _sorting = false;
  SheetSort? _sort;

  /// The rows of the source in the order they are shown, while sorted.
  Int32List? _order;

  /// Where each row of the source stands in [_order].
  Int32List? _rank;

  /// Where each row of the source stands on screen, built when first asked
  /// for after the rows shown change.
  Int32List? _positions;

  /// The rows fading in after a sort: a new order is a new picture, and it
  /// arrives rather than replacing the old one in a frame.
  late final AnimationController _arrive = AnimationController(
    vsync: this,
    value: 1,
  )..addListener(_repaint);

  /// The heading the pointer is over, which shows where to press to sort.
  int? _hoverHeading;

  /// Columns the reader has hidden, by number. A hidden column keeps its
  /// number and its width, and is drawn no wide at all — so nothing else has
  /// to learn that the columns on screen are not the columns of the file.
  final Set<int> _hidden = {};

  /// Whether the columns the file hides have been hidden here yet — once a
  /// sheet, so "Show all columns" is not undone by the next answer.
  int _fileHiddenFor = -1;

  /// The reader has asked to see the rows the file hides.
  bool _showHiddenRows = false;

  /// Rows at the top and columns at the left kept in place while the rest
  /// scrolls.
  int _frozenRows = 0;
  int _frozenColumns = 0;

  /// Where a point across the view is in the sheet: in the frozen part it
  /// stands still, anywhere else the scroll is added.
  double _contentX(double x) {
    final g = _geometry;
    if (g == null) return x;
    final inSheet = x - g.gutter;
    return inSheet < g.frozenWidth ? inSheet : inSheet + _scrollX;
  }

  double _contentY(double y) {
    final g = _geometry;
    if (g == null) return y;
    final inSheet = y - g.head;
    return inSheet < g.frozenHeight ? inSheet : inSheet + _scrollY;
  }

  /// The reverse of [_contentX] for a column's left edge.
  double _screenX(double contentX, int column) {
    final g = _geometry!;
    return g.gutter + contentX - (column < g.frozenColumns ? 0 : _scrollX);
  }

  /// The rows on screen, as rows of the source, while the filter is on; null
  /// when every row is shown in its own place. Everything the view draws or
  /// selects is counted in the rows it shows, and asks here which row of the
  /// file that is.
  List<int>? _shown;

  int get _viewRows => _shown?.length ?? widget.source.rowCount;

  int _toSource(int view) {
    final shown = _shown;
    if (shown == null) return view;
    return view >= 0 && view < shown.length ? shown[view] : view;
  }

  /// Where a row of the source is on screen, or where it would be — the row
  /// before which it would stand — when the filter hides it.
  int _toView(int row) {
    final shown = _shown;
    if (shown == null) return row;
    if (_order != null) {
      var positions = _positions;
      if (positions == null) {
        var size = 0;
        for (final r in shown) {
          if (r >= size) size = r + 1;
        }
        positions = _positions = Int32List(size)..fillRange(0, size, -1);
        for (var i = 0; i < shown.length; i++) {
          positions[shown[i]] = i;
        }
      }
      return row >= 0 && row < positions.length && positions[row] >= 0
          ? positions[row]
          : 0;
    }
    var lo = 0;
    var hi = shown.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (shown[mid] < row) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Bumped by every key, so a Ctrl+arrow still reading rows when the next
  /// key arrives knows it has been overtaken.
  int _jump = 0;

  @override
  void initState() {
    super.initState();
    widget.source.addListener(_onSource);
    selection.addListener(_onSelection);
    selection.isHidden = _hidden.contains;
    _glide.addListener(_repaint);
    _ease.addListener(_onEase);
    selection.resize(_viewRows, widget.source.columnCount);
    _takeKeyboard();
    // What the file hides is hidden from the first frame on, not only once
    // the source has something new to say.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSource());
  }

  /// Claims the keyboard once this is on screen, if it is the thing being
  /// worked in — after the frame, because a node cannot be focused before it
  /// is in the tree. The reason is [KeyboardScrollable]'s: a viewer opens
  /// inside the scope the panel was in, and `autofocus` alone lands nowhere.
  void _takeKeyboard() {
    if (!widget.hasKeyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.hasKeyboard && !_node.hasFocus) {
        _node.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(SheetView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.source != widget.source) {
      _rememberWidths(_keyFor(old.source, _shownSheet));
      old.source.removeListener(_onSource);
      widget.source.addListener(_onSource);
      _shownSheet = widget.source.sheetIndex;
      _forgetLayout();
      WidgetsBinding.instance.addPostFrameCallback((_) => _onSource());
    }
    if (old.selection != widget.selection) {
      (old.selection ?? _own)?.removeListener(_onSelection);
      selection.addListener(_onSelection);
      selection.isHidden = _hidden.contains;
    }
    selection.resize(_viewRows, widget.source.columnCount);
    if (widget.hasKeyboard && !_node.hasFocus) _takeKeyboard();
  }

  /// What this page's widths are remembered by, or null when the sheet is
  /// not a file.
  String? get _widthsKey => _keyFor(widget.source, _shownSheet);

  static String? _keyFor(SheetSource source, int sheet) {
    final identity = source.identity;
    return identity == null ? null : '$identity#$sheet';
  }

  /// Keeps this page's widths — asked before whatever is about to replace
  /// it, while the key still names the page they belong to.
  void _rememberWidths([String? key]) {
    key ??= _widthsKey;
    if (key == null || !_fitted || _widths.isEmpty) return;
    _rememberedWidths.remove(key);
    _rememberedWidths[key] = [..._widths];
    while (_rememberedWidths.length > 64) {
      _rememberedWidths.remove(_rememberedWidths.keys.first);
    }
  }

  void _forgetLayout() {
    if (_finding) _closeFind(refocus: false);
    _hidden.clear();
    _fileHiddenFor = -1;
    _showHiddenRows = false;
    _frozenRows = 0;
    _frozenColumns = 0;
    _sort?.cancel();
    _sort = null;
    _sortColumn = null;
    _sorting = false;
    _order = null;
    _rank = null;
    _shown = null;
    _positions = null;
    _widths = const [];
    _fitted = false;
    _texts.clear();
    selection.reset();
    if (_vertical.hasClients) _vertical.jumpTo(0);
    if (_horizontal.hasClients) _horizontal.jumpTo(0);
  }

  /// Shows the sheet [by] places along, wrapping at neither end — the last
  /// page of a workbook is its last page.
  void _stepSheet(int by) {
    final source = widget.source;
    final next = source.sheetIndex + by;
    if (next < 0 || next >= source.sheetTitles.length) return;
    unawaited(source.selectSheet(next));
  }

  @override
  void dispose() {
    _rememberWidths();
    _measureSoon?.cancel();
    _tally?.cancel();
    _settle?.cancel();
    _typing?.cancel();
    _search?.cancel();
    _search?.removeListener(_onFound);
    _sort?.cancel();
    _arrive.dispose();
    _query.dispose();
    _box.dispose();
    _node.dispose();
    widget.source.removeListener(_onSource);
    selection.removeListener(_onSelection);
    _own?.dispose();
    _glide.dispose();
    _ease.dispose();
    _vertical.dispose();
    _horizontal.dispose();
    _texts.clear();
    super.dispose();
  }

  int _shownSheet = 0;
  bool? _shownHeader;

  void _onSource() {
    if (!mounted) return;
    if (widget.source.sheetIndex != _shownSheet) {
      _rememberWidths();
      // Another page of the same file: nothing about the last one carries
      // over — not its widths, not what was selected, not where it was
      // scrolled to.
      _shownSheet = widget.source.sheetIndex;
      _forgetLayout();
    }
    final header = widget.source.hasHeader;
    if (_shownHeader != null && header != _shownHeader) {
      // Every row has moved by one: an order worked out for the old rows,
      // or matches found in them, would now point at their neighbours. The
      // widths go too, since the headings are different words now.
      if (_finding) _closeFind(refocus: false);
      _sort?.cancel();
      _sort = null;
      _sortColumn = null;
      _sorting = false;
      _order = null;
      _rank = null;
      _shown = null;
      _positions = null;
      _fitted = false;
    }
    _shownHeader = header;
    final fileHidden = widget.source.hiddenColumns;
    if (fileHidden.isNotEmpty && _fileHiddenFor != widget.source.sheetIndex) {
      _fileHiddenFor = widget.source.sheetIndex;
      _hidden.addAll(fileHidden);
    }
    if (!_showHiddenRows && widget.source.hiddenRows.isNotEmpty) {
      _refilter(_toSource(selection.active.row), reordered: true);
    }
    selection.resize(_viewRows, widget.source.columnCount);
    setState(() {});
  }

  CellAddress? _revealed;
  CellRange? _revealedRange;

  Timer? _settle;

  void _onSelection() {
    if (!mounted) return;
    setState(() {});
    _measureLater();
    if (widget.source.wantsSelection) {
      // Told once it has settled, the way a view is told where its cursor
      // came to rest: a drag across a hundred cells is one selection.
      _settle?.cancel();
      _settle = Timer(const Duration(milliseconds: 120), () {
        if (mounted) widget.source.selected(_selectionForPlugin());
      });
    }
    final s = selection;
    if (s.active == _revealed && s.current == _revealedRange) return;
    _revealed = s.active;
    _revealedRange = s.current;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  /// Scrolls the least it can to put the active cell on screen — along the
  /// axes that mean something: a whole column selected does not drag the
  /// view to a row, a whole row does not drag it sideways.
  ///
  /// A step to the next cell is a step; a jump of more than a screen glides,
  /// on the speed setting, so the eye can follow where it went.
  void _reveal() {
    final g = _geometry;
    final theme = _theme;
    if (!mounted || g == null || theme == null) return;
    final s = selection;
    final cell = g.cellRect(s.active.row, s.active.column);
    if (s.span != SheetSpan.columns &&
        s.span != SheetSpan.everything &&
        s.active.row >= g.frozenRows) {
      _bring(_vertical, cell.top, cell.bottom, theme, pinned: g.frozenHeight);
    }
    if (s.span != SheetSpan.rows &&
        s.span != SheetSpan.everything &&
        s.active.column >= g.frozenColumns) {
      _bring(_horizontal, cell.left, cell.right, theme, pinned: g.frozenWidth);
    }
  }

  void _bring(
    ScrollController controller,
    double start,
    double end,
    AppearanceSettings theme, {
    double pinned = 0,
  }) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final view = position.viewportDimension;
    final now = position.pixels;
    double? to;
    // What is frozen covers the first [pinned] of the view, so a cell is only
    // in sight below it.
    if (start - pinned < now) {
      to = start - pinned;
    } else if (end > now + view) {
      to = end - view;
    }
    if (to == null) return;
    to = to.clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((to - now).abs() > view && theme.animates) {
      controller.animateTo(
        to,
        duration: theme.animated(kCursorAnimationDuration * 2),
        curve: Curves.easeOutCubic,
      );
    } else {
      controller.jumpTo(to);
    }
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  void _onEase() {
    final from = _widthsFrom;
    final to = _widthsTo;
    if (from == null || to == null || !mounted) return;
    final t = Curves.easeOutCubic.transform(_ease.value);
    setState(() {
      _widths = [
        for (var i = 0; i < to.length; i++)
          ui.lerpDouble(i < from.length ? from[i] : to[i], to[i], t)!,
      ];
    });
  }

  /// The column widths fitted to what is in them — the headings and the rows
  /// already here, a hundred at most — within the two limits.
  List<double> _fit(AppearanceSettings theme, TextScaler scaler) {
    final source = widget.source;
    final digit = _charWidth(theme, scaler);
    final least = digit * _minColumnChars + _cellPadding * 2;
    final most = digit * _maxColumnChars + _cellPadding * 2;
    final names = source.columnNames;
    final sample = <List<Object?>>[];
    // A cell joined across columns is as wide as all of them, and is not a
    // reason to widen the first: a title over four columns would otherwise
    // make its first column as wide as the title.
    final wide = {
      for (final m in source.merges)
        if (m.right > m.left) (m.top, m.left),
    };
    for (var r = 0; r < math.min(100, source.rowCount); r++) {
      final row = source.rowAt(r);
      if (row == null) continue;
      if (wide.isEmpty) {
        sample.add(row);
        continue;
      }
      sample.add([
        for (var c = 0; c < row.length; c++)
          wide.contains((r, c)) ? null : row[c],
      ]);
    }

    final style = _cellStyle(theme);
    final heading = _nameStyle(theme);
    return [
      for (var c = 0; c < source.columnCount; c++)
        _widthOf(c, names, sample, style, heading, scaler, least, most, theme),
    ];
  }

  double _widthOf(
    int column,
    List<String>? names,
    List<List<Object?>> sample,
    TextStyle style,
    TextStyle heading,
    TextScaler scaler,
    double least,
    double most,
    AppearanceSettings theme,
  ) {
    var widest = 0.0;
    final name = names != null && column < names.length ? names[column] : '';
    widest = _measure('${columnLetters(column)}  $name', heading, scaler);
    for (final row in sample) {
      if (column >= row.length) continue;
      final text = _oneLine(row[column]);
      if (text.isEmpty) continue;
      // Past the cap the answer is the cap; a paragraph need not be measured.
      if (text.length > _maxColumnChars * 2) return most;
      widest = math.max(widest, _measure(text, style, scaler));
    }
    return (widest + _cellPadding * 2).clamp(least, most);
  }

  /// Fits one column again, easing to its new width. A double click on the
  /// edge of its heading.
  void fitColumn(int column) {
    final theme = _theme;
    if (theme == null || column >= _widths.length) return;
    final fitted = _fit(theme, MediaQuery.textScalerOf(context));
    if (column >= fitted.length) return;
    final to = [..._widths]..[column] = fitted[column];
    _easeTo(to, theme);
  }

  void _easeTo(List<double> to, AppearanceSettings theme) {
    if (!theme.animates) {
      setState(() => _widths = to);
      return;
    }
    _widthsFrom = _widths;
    _widthsTo = to;
    _ease
      ..duration = theme.animated(kColumnWidthDuration)
      ..forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = appearanceOf(context);
    final scaler = MediaQuery.textScalerOf(context);
    final source = widget.source;
    if (_theme != theme) {
      _theme = theme;
      _texts.clear();
    }

    if (source.rowCount == 0 &&
        !source.counting &&
        source.sheetTitles.length < 2 &&
        !_finding) {
      return _Message(
        theme: theme,
        text: source.error ?? tr('Nothing to show.'),
      );
    }

    // Widths wait for the first rows, so the sheet opens at the widths it
    // will keep rather than at guesses it then jumps from — or at the widths
    // it was left with, when it has been open before.
    if (!_fitted && source.rowCount > 0 && source.rowAt(0) != null) {
      final remembered = _rememberedWidths[_widthsKey ?? ''];
      _widths = remembered != null && remembered.length == source.columnCount
          ? [...remembered]
          : _fit(theme, scaler);
      _fitted = true;
    }
    if (_widths.length < source.columnCount) {
      final fitted = _fit(theme, scaler);
      _widths = [..._widths, ...fitted.skip(_widths.length)];
    }

    final geometry = _geometry = _Geometry(
      theme: theme,
      scaler: scaler,
      widths: _hidden.isEmpty
          ? _widths
          : [
              for (var c = 0; c < _widths.length; c++)
                _hidden.contains(c) ? 0.0 : _widths[c],
            ],
      rows: _viewRows,
      frozenRows: _frozenRows,
      frozenColumns: _frozenColumns,
    );
    _follow(geometry, theme);

    final t = Curves.easeOutCubic.transform(_glide.value);
    final active = _lerpRect(_activeFrom, _activeTo, t);
    final range = _lerpRect(_rangeFrom, _rangeTo, t);

    final search = _search;
    Widget grid(ViewportOffset vertical, ViewportOffset horizontal) => _Grid(
      source: source,
      rowAt: (view) => source.rowAt(_toSource(view)),
      sourceRow: _toSource,
      found: search == null || search.count == 0
          ? null
          : (view, column) => search.isMatch(_toSource(view), column),
      merges: _mergesOnScreen(),
      noteAt: source.notes.isEmpty
          ? null
          : (view, column) =>
                source.notes.containsKey((_toSource(view), column)),
      sortColumn: _sortColumn,
      descending: _descending,
      sorting: _sorting,
      hoverHeading: _hoverHeading,
      arriving: Curves.easeOut.transform(_arrive.value),
      selection: selection,
      geometry: geometry,
      theme: theme,
      scaler: scaler,
      texts: _texts,
      vertical: vertical,
      horizontal: horizontal,
      active: active,
      range: range,
      isActive: widget.isActive,
    );

    final scrolled = Scrollbar(
      controller: _vertical,
      child: Scrollable(
        controller: _vertical,
        axisDirection: AxisDirection.down,
        viewportBuilder: (context, vertical) => Scrollbar(
          controller: _horizontal,
          child: Scrollable(
            controller: _horizontal,
            axisDirection: AxisDirection.right,
            viewportBuilder: (context, horizontal) =>
                grid(vertical, horizontal),
          ),
        ),
      ),
    );

    return ExcludeFocus(
      // Not merely "does not ask for the keyboard" — cannot be given it, the
      // rule [KeyboardScrollable] writes down: a preview beside the panel
      // being worked in must never be the thing the arrows move.
      excluding: !widget.hasKeyboard,
      child: Focus(
        focusNode: _node,
        autofocus: widget.hasKeyboard,
        onKeyEvent: _onKey,
        // **No fill of its own.** The page or the panel under the sheet is
        // already painted, in whatever see-through the window has been given;
        // an opaque colour here put a solid slab over it, and the sheet was
        // the one thing in the window the setting did nothing to.
        // Stands clear of the strip of neighbours while it is up, but only
        // where there is something along the bottom to press — the pill of a
        // workbook's pages, which was under the strip, seen through a gap and
        // pressed through none. A sheet of one page lets the strip hang over
        // it like any other reading, and loses none of its height to it.
        child: AnimatedPadding(
          padding: EdgeInsets.only(
            bottom: source.sheetTitles.length > 1
                ? ViewerBottomInset.of(context)
                : 0,
          ),
          duration: motionOf(context, kFilmStripDuration),
          curve: kBothCurve,
          child: ColoredBox(
            color: const Color(0x00000000),
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      // Only the grid hears the pointer here: the pill and the find
                      // box float over it, and a press on either is not a press on
                      // the cell underneath.
                      Positioned.fill(
                        child: MouseRegion(
                          cursor: _cursor,
                          onHover: (event) => _hover(event.localPosition),
                          onExit: (_) {
                            _setCursor(MouseCursor.defer);
                            if (_hoverHeading != null) {
                              setState(() => _hoverHeading = null);
                            }
                          },
                          child: Listener(
                            onPointerDown: _down,
                            onPointerMove: _move,
                            onPointerUp: (_) => _endDrag(),
                            onPointerCancel: (_) => _endDrag(),
                            child: scrolled,
                          ),
                        ),
                      ),
                      if (_finding)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: _findBox(theme),
                        ),
                    ],
                  ),
                ),
                _statusLine(theme, source),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The joined cells, in the rows on screen. Joined across columns they
  /// stay joined whatever order the rows are in; joined across rows they
  /// mean something only while the rows are the file's own, in its order.
  List<CellRange> _mergesOnScreen() {
    final merges = widget.source.merges;
    if (merges.isEmpty) return const [];
    if (_shown == null) return merges;
    return [
      for (final m in merges)
        if (m.top == m.bottom)
          CellRange(
            top: _toView(m.top),
            left: m.left,
            bottom: _toView(m.top),
            right: m.right,
          ),
    ];
  }

  // --- The status line -------------------------------------------------

  SheetMeasure? _tally;
  SheetStats? _stats;
  bool _measuring = false;
  Timer? _measureSoon;

  /// Adds the selection up once it has stopped moving: a drag across a
  /// column of a million rows is one sum, not one per row it passed.
  void _measureLater() {
    _measureSoon?.cancel();
    _measureSoon = Timer(const Duration(milliseconds: 150), _measureNow);
  }

  Future<void> _measureNow() async {
    _tally?.cancel();
    final s = selection;
    if (!mounted) return;
    if (s.isSingleCell) {
      if (_stats != null || _measuring) {
        setState(() {
          _stats = null;
          _measuring = false;
        });
      }
      return;
    }
    final measure = _tally = SheetMeasure(
      widget.source,
      s.ranges,
      rowOf: _toSource,
      skipColumn: _hidden.isEmpty ? null : _hidden.contains,
    );
    setState(() => _measuring = true);
    final stats = await measure.run(s.rows, s.columns);
    if (!mounted || !identical(measure, _tally) || stats == null) return;
    setState(() {
      _stats = stats;
      _measuring = false;
    });
  }

  /// Under the sheet: which page, where the keyboard is and what the cell
  /// there says in full, and — for more than one cell — how many, and what
  /// the numbers among them come to.
  Widget _statusLine(AppearanceSettings theme, SheetSource source) {
    final s = selection;
    final ink = theme.headerForeground;
    final quiet = TextStyle(
      color: ink.withValues(alpha: 0.6),
      fontSize: theme.fontSize - 1,
      fontFamily: theme.uiFamily,
      decoration: TextDecoration.none,
    );
    final plain = quiet.copyWith(color: ink);
    final values = source.rowAt(_toSource(s.active.row));
    final column = s.active.column;
    final note = source.notes[(_toSource(s.active.row), column)];
    final cellText = values != null && column < values.length
        ? sheetText(values[column])
        : '';
    // A note on the cell is said after what the cell says: it is what a
    // spreadsheet shows when the pointer rests on the cell's corner.
    final value = note == null ? cellText : '$cellText  —  $note';
    final ranges = s.ranges;
    final where = s.isSingleCell
        ? s.active.label
        : [
            for (final r in ranges.take(3)) r.label(rows: s.rows),
            if (ranges.length > 3) '…',
          ].join(', ');

    final figures = <String>[];
    if (!s.isSingleCell) {
      figures.add(tr('{count} cells', {'count': _grouped(s.cellCount)}));
      final stats = _stats;
      if (_measuring) {
        figures.add('…');
      } else if (stats != null && stats.numbers > 0) {
        final more = stats.complete ? '' : '…';
        figures
          ..add(tr('Sum {value}', {'value': _figure(stats.sum) + more}))
          ..add(
            tr('Average {value}', {'value': _figure(stats.average!) + more}),
          )
          ..add(tr('Min {value}', {'value': _figure(stats.min!)}))
          ..add(tr('Max {value}', {'value': _figure(stats.max!)}))
          ..add(tr('Count {value}', {'value': _grouped(stats.numbers)}));
      }
    }
    final rows = source.rowCount;
    final counted = tr('{count} rows', {
      'count': '${source.counting ? '≥ ' : ''}${_grouped(rows)}',
    });

    return Container(
      height: theme.chromeRowHeight,
      decoration: BoxDecoration(
        color: theme.effectiveHeaderBackground,
        border: Border(top: BorderSide(color: theme.chromeRule)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          if (source.sheetTitles.length > 1) ...[
            _sheetPill(source, theme),
            const SizedBox(width: 8),
          ],
          Text(where, style: plain, maxLines: 1),
          const SizedBox(width: 12),
          // What the cell says gives way first, then the figures: a panel a
          // third of the window wide still shows where the keyboard is.
          Expanded(
            flex: 2,
            child: Text(
              _oneLine(value),
              style: quiet,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (figures.isNotEmpty)
            Flexible(
              flex: 3,
              child: Text(
                figures.join('   '),
                style: plain,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
          const SizedBox(width: 14),
          Text(counted, style: quiet, maxLines: 1),
        ],
      ),
    );
  }

  /// A figure for the status line, the way the application's language
  /// writes numbers: thousands apart, a decimal comma where that is the mark.
  String _figure(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return _grouped(value.round());
    }
    var text = value.toStringAsPrecision(10);
    if (text.contains('e')) return text;
    if (text.contains('.')) {
      text = text
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
    }
    final dot = text.indexOf('.');
    final whole = dot < 0 ? text : text.substring(0, dot);
    final rest = dot < 0 ? '' : text.substring(dot + 1);
    final sign = whole.startsWith('-') ? '-' : '';
    final grouped = _grouped(int.parse(whole.replaceFirst('-', '')));
    final mark =
        _commaLanguages.contains(activeLocalisation.code.split('-').first)
        ? ','
        : '.';
    return rest.isEmpty ? '$sign$grouped' : '$sign$grouped$mark$rest';
  }

  static const _commaLanguages = {
    'ru',
    'uk',
    'de',
    'fr',
    'es',
    'it',
    'fi',
    'nb',
  };

  static String _grouped(int value) {
    final digits = value.abs().toString();
    final out = StringBuffer(value < 0 ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write('\u202f');
      out.write(digits[i]);
    }
    return out.toString();
  }

  /// Which page of a workbook is shown, and the way to the others: the pill
  /// a git branch is chosen with, not a row of tabs — one thing that says
  /// where you are and opens the way to somewhere else.
  Widget _sheetPill(SheetSource source, AppearanceSettings theme) {
    final titles = source.sheetTitles;
    final at = source.sheetIndex.clamp(0, titles.length - 1);
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.effectiveHeaderBackground,
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6)],
        ),
        child: ViewPill(
          theme: theme,
          command: ViewCommand(
            id: 'sheet',
            label: titles[at],
            tooltip: tr('Sheet'),
            items: [
              for (var i = 0; i < titles.length; i++)
                ViewMenuItem(id: '$i', label: titles[i], checked: i == at),
            ],
          ),
          onPressed: (id) {
            final index = int.tryParse(id);
            if (index != null) unawaited(source.selectSheet(index));
            _node.requestFocus();
          },
        ),
      ),
    );
  }

  /// Starts the outline gliding when the selection moved, and only then — a
  /// sheet still counting grows a whole column taller many times a second, and
  /// that is not the keyboard going anywhere.
  void _follow(_Geometry g, AppearanceSettings theme) {
    final s = selection;
    // Inside a joined cell the outline goes round all of it, as a
    // spreadsheet's does: it is one cell to the reader.
    var activeRect = g.cellRect(s.active.row, s.active.column);
    for (final m in _mergesOnScreen()) {
      if (m.contains(s.active.row, s.active.column) &&
          m.right < g.widths.length) {
        activeRect = g.rangeRect(m);
        break;
      }
    }
    final current = s.current;
    final clamped = current.clampTo(s.rows, s.columns);
    final rangeRect = clamped == null ? null : g.rangeRect(clamped);

    final moved = _lastActive != s.active || _lastRange != current;
    _lastActive = s.active;
    _lastRange = current;
    if (!moved || _activeTo == null || !theme.animates) {
      _activeFrom = _activeTo = activeRect;
      _rangeFrom = _rangeTo = rangeRect;
      if (moved) _glide.value = 1;
      return;
    }
    final t = Curves.easeOutCubic.transform(_glide.value);
    _activeFrom = _lerpRect(_activeFrom, _activeTo, t);
    _rangeFrom = _lerpRect(_rangeFrom, _rangeTo, t) ?? rangeRect;
    _activeTo = activeRect;
    _rangeTo = rangeRect;
    _glide
      ..duration = theme.animated(kCursorAnimationDuration)
      ..forward(from: 0);
  }

  Rect? _lerpRect(Rect? a, Rect? b, double t) {
    if (a == null) return b;
    if (b == null) return null;
    return Rect.lerp(a, b, t);
  }

  /// Which heading edge is under [at], or null. The edge on a column's right,
  /// in the heading row only — anywhere else a press is a press on a cell.
  int? _edgeAt(Offset at) {
    final g = _geometry;
    if (g == null || at.dy > g.head || at.dx < g.gutter) return null;
    final x = _contentX(at.dx);
    for (var c = g.firstColumnAt(x - _edgeReach); c < g.widths.length; c++) {
      if (g.widths[c] <= 0) continue;
      final edge = g.lefts[c + 1];
      if ((edge - x).abs() <= _edgeReach) return c;
      if (edge > x + _edgeReach) break;
    }
    return null;
  }

  double get _scrollX => _horizontal.hasClients ? _horizontal.offset : 0;

  /// The arrow at the right of a heading, where a press sorts rather than
  /// selects.
  bool _inSortZone(Offset at, int column) {
    final g = _geometry;
    if (g == null || column >= g.widths.length) return false;
    final right = _screenX(g.lefts[column + 1], column);
    return at.dx <= right - _edgeReach && at.dx >= right - _sortZone;
  }

  void _hover(Offset at) {
    final hit = _hitAt(at);
    final heading = hit is _HeadingHit ? hit.column : null;
    if (heading != _hoverHeading) setState(() => _hoverHeading = heading);
    if (_resizing != null) return;
    _setCursor(
      _edgeAt(at) != null ? SystemMouseCursors.resizeColumn : MouseCursor.defer,
    );
  }

  void _setCursor(MouseCursor cursor) {
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  /// What is under [at], in the view's own coordinates.
  _Hit? _hitAt(Offset at) {
    final g = _geometry;
    if (g == null) return null;
    final inHead = at.dy < g.head;
    final inGutter = at.dx < g.gutter;
    if (inHead && inGutter) return const _CornerHit();
    final x = _contentX(at.dx);
    final y = _contentY(at.dy);
    final column = g.widths.isEmpty
        ? -1
        : x >= g.width
        ? g.widths.length - 1
        : g.firstColumnAt(math.max(0, x));
    final row = g.rows == 0
        ? -1
        : (y / g.rowHeight).floor().clamp(0, g.rows - 1);
    if (inHead) return column < 0 ? null : _HeadingHit(column);
    if (inGutter) return row < 0 ? null : _GutterHit(row);
    if (row < 0 || column < 0) return null;
    return _CellHit(CellAddress(row, column));
  }

  double get _scrollY => _vertical.hasClients ? _vertical.offset : 0;

  bool get _shiftHeld => HardwareKeyboard.instance.isShiftPressed;

  /// Ctrl on Windows and Linux, Cmd on the Mac — the key that adds to a
  /// selection everywhere else on each of them.
  bool get _addHeld {
    final keys = HardwareKeyboard.instance;
    return keys.isControlPressed || keys.isMetaPressed;
  }

  void _down(PointerDownEvent event) {
    if (widget.hasKeyboard && !_node.hasFocus) _node.requestFocus();
    // The other button asks what can be done with the selection. Pressed
    // outside it, it first moves there — the menu is about what it was
    // pressed on, not about something selected somewhere off screen.
    if (event.buttons & kSecondaryButton != 0) {
      final hit = _hitAt(event.localPosition);
      final s = selection;
      switch (hit) {
        case _CellHit(:final at) when !s.contains(at.row, at.column):
          s.moveTo(at);
        case _HeadingHit(:final column) when !s.coversColumn(column):
          s.pressColumn(column);
        case _GutterHit(:final row) when !s.coversRow(row):
          s.pressRow(row);
        default:
          break;
      }
      unawaited(_openMenu(at: event.position));
      return;
    }

    final edge = _edgeAt(event.localPosition);
    if (edge != null) {
      // Counted here rather than with a double-tap recogniser, which would
      // make every single press wait the double-tap window out.
      final now = DateTime.now();
      final was = _lastEdgeAt;
      if (edge == _lastEdge &&
          was != null &&
          now.difference(was) < kDoubleTapTimeout) {
        _lastEdge = -1;
        _lastEdgeAt = null;
        fitColumn(edge);
        return;
      }
      _lastEdge = edge;
      _lastEdgeAt = now;
      _resizing = edge;
      _drag = _Drag.resize;
      _resizeStartX = event.localPosition.dx;
      _resizeStartWidth = _widths[edge];
      return;
    }

    final hit = _hitAt(event.localPosition);
    final s = selection;
    final extend = _shiftHeld;
    final add = _addHeld && !extend;
    switch (hit) {
      case null:
        return;
      case _CornerHit():
        s.selectAll();
        _drag = _Drag.none;
      case _HeadingHit(:final column):
        if (_inSortZone(event.localPosition, column)) {
          _cycleSort(column);
          _drag = _Drag.none;
          return;
        }
        s.pressColumn(column, extend: extend, add: add);
        _drag = _Drag.columns;
      case _GutterHit(:final row):
        s.pressRow(row, extend: extend, add: add);
        _drag = _Drag.rows;
      case _CellHit(:final at):
        // Counted here, like a heading edge's: a double-tap recogniser would
        // make every single press wait the double-tap window out.
        final now = DateTime.now();
        final twice =
            at == _lastCell &&
            _lastCellAt != null &&
            now.difference(_lastCellAt!) < kDoubleTapTimeout;
        _lastCell = twice ? null : at;
        _lastCellAt = twice ? null : now;
        if (twice && !extend && !add) {
          unawaited(_activate());
          _drag = _Drag.none;
          return;
        }
        if (extend) {
          s.moveTo(at, extend: true);
        } else if (add) {
          s.startAnother(at);
        } else {
          s.moveTo(at);
        }
        _drag = _Drag.cells;
    }
  }

  void _move(PointerMoveEvent event) {
    switch (_drag) {
      case _Drag.none:
        return;
      case _Drag.resize:
        _resize(event);
      case _Drag.cells:
      case _Drag.columns:
      case _Drag.rows:
        _extendTo(event.localPosition);
    }
  }

  /// A drag carries the range to the cell under the pointer — along the rows
  /// or the columns only, when it began on a row number or a heading.
  void _extendTo(Offset at) {
    final g = _geometry;
    if (g == null || g.rows == 0 || g.widths.isEmpty) return;
    final x = _contentX(at.dx);
    final y = _contentY(at.dy);
    final column = x >= g.width
        ? g.widths.length - 1
        : g.firstColumnAt(math.max(0, x));
    final row = (y / g.rowHeight).floor().clamp(0, g.rows - 1);
    final s = selection;
    switch (_drag) {
      case _Drag.columns:
        s.pressColumn(column, extend: true);
      case _Drag.rows:
        s.pressRow(row, extend: true);
      default:
        s.moveTo(CellAddress(row, column), extend: true);
    }
  }

  void _endDrag() {
    _resizing = null;
    _drag = _Drag.none;
  }

  void _resize(PointerMoveEvent event) {
    final column = _resizing;
    if (column == null) return;
    final theme = _theme;
    if (theme == null) return;
    final least =
        _charWidth(theme, MediaQuery.textScalerOf(context)) + _cellPadding * 2;
    final width = math.max(
      least,
      _resizeStartWidth + event.localPosition.dx - _resizeStartX,
    );
    setState(() => _widths = [..._widths]..[column] = width);
  }

  // --- The keyboard -----------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final shift = keys.isShiftPressed;
    final alt = keys.isAltPressed;
    final command = keys.isControlPressed || keys.isMetaPressed;
    final s = selection;
    final key = event.logicalKey;
    _jump++;

    // While the find box has the keyboard only three keys are the sheet's;
    // everything else is typing, and the field has already had it.
    if (_box.hasFocus) {
      switch (key) {
        case LogicalKeyboardKey.escape:
          _closeFind();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
          _step(shift ? -1 : 1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.f3:
          _step(shift ? -1 : 1);
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    }

    // Enter means something only to a plugin that asked for it; otherwise it
    // is the page's, and goes on up.
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        widget.source.wantsActivate &&
        !command &&
        !alt) {
      unawaited(_activate());
      return KeyEventResult.handled;
    }

    // The menu key, and Shift+F10 where the keyboard has none: the same menu
    // the other button opens, under the cell the keyboard is on.
    if (key == LogicalKeyboardKey.contextMenu ||
        (key == LogicalKeyboardKey.f10 && shift && !command && !alt)) {
      unawaited(_openMenu());
      return KeyEventResult.handled;
    }

    // F3 walks the matches when there are some to walk; when there are none
    // it is the application's "view this" again, and goes on up.
    if (key == LogicalKeyboardKey.f3 && (_search?.count ?? 0) > 0) {
      _step(shift ? -1 : 1);
      return KeyEventResult.handled;
    }

    switch (key) {
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowRight:
        if (alt) return KeyEventResult.ignored;
        final (dr, dc) = switch (key) {
          LogicalKeyboardKey.arrowDown => (1, 0),
          LogicalKeyboardKey.arrowUp => (-1, 0),
          LogicalKeyboardKey.arrowLeft => (0, -1),
          _ => (0, 1),
        };
        if (command) {
          _toEdge(dr, dc, extend: shift);
        } else {
          s.moveBy(dr, dc, extend: shift);
        }

      case LogicalKeyboardKey.home:
        command ? s.sheetStart(extend: shift) : s.rowStart(extend: shift);
      case LogicalKeyboardKey.end:
        command ? s.sheetEnd(extend: shift) : s.rowEnd(extend: shift);

      case LogicalKeyboardKey.pageDown:
        // Ctrl+PgDn is the next sheet. A file of one sheet has none, but the
        // key is still this sheet's, not the panel's "into the folder", which
        // would take the reader somewhere else entirely.
        if (command) {
          _stepSheet(1);
          return KeyEventResult.handled;
        }
        alt ? s.pageRight(extend: shift) : s.pageDown(extend: shift);
      case LogicalKeyboardKey.pageUp:
        if (command) {
          _stepSheet(-1);
          return KeyEventResult.handled;
        }
        alt ? s.pageLeft(extend: shift) : s.pageUp(extend: shift);

      case LogicalKeyboardKey.space:
        if (shift && !command && !alt) {
          s.selectRows();
        } else if (_columnChord(command: command, alt: alt, shift: shift)) {
          s.selectColumns();
        } else if (!shift && !command && !alt) {
          // The panel's own key for picking something out, and the one a Mac
          // has where it has no Insert: the range so far is put aside.
          s.fixCurrent();
        } else {
          return KeyEventResult.ignored;
        }

      case LogicalKeyboardKey.insert:
        // Ctrl+Insert is the older copy, the one a commander's hand goes to.
        if (command && !alt) {
          unawaited(_copy(json: shift));
          return KeyEventResult.handled;
        }
        if (command || alt) return KeyEventResult.ignored;
        s.fixCurrent();

      case LogicalKeyboardKey.escape:
        // Escape undoes one thing at a time: a search first, then a
        // selection of more than one cell, and only then does it go on up
        // and do its next job, which is leaving.
        if (_finding) {
          _closeFind();
          return KeyEventResult.handled;
        }
        return s.collapse() ? KeyEventResult.handled : KeyEventResult.ignored;

      default:
        if (!command || alt) return KeyEventResult.ignored;
        switch (bindingLetter(event)) {
          case 'a':
            s.selectAll();
          case 'g':
            _goTo();
          case 'f':
            _openFind();
          // Tab-separated for a spreadsheet to take back; with Shift, JSON.
          // Either way the key is the sheet's — left to the panel it would
          // copy the files.
          case 'c':
            unawaited(_copy(json: shift));
          default:
            return KeyEventResult.ignored;
        }
    }
    return KeyEventResult.handled;
  }

  /// The column chord: Ctrl+Space where the system leaves it free, and
  /// Option+Space on the Mac — where Cmd+Space is Spotlight and Control+Space
  /// switches the keyboard's language, which a reader in two alphabets
  /// presses all day.
  bool _columnChord({
    required bool command,
    required bool alt,
    required bool shift,
  }) {
    if (shift) return false;
    if (defaultTargetPlatform == TargetPlatform.macOS) return alt && !command;
    return command && !alt;
  }

  /// Ctrl+arrow: to the edge of the data, as every spreadsheet has it. From a
  /// filled cell into filled ones it stops at the last filled one; from or
  /// into an empty one it stops at the next filled one; and where there is
  /// none it goes to the end.
  ///
  /// Rows it has not read yet are read on the way. See [_edgeSearchRows] for
  /// where that stops.
  Future<void> _toEdge(int dr, int dc, {required bool extend}) async {
    final ticket = _jump;
    final s = selection;
    final source = widget.source;
    final from = s.active;
    final rows = _viewRows;
    final columns = source.columnCount;
    if (rows == 0 || columns == 0) return;

    Future<bool?> filled(int row, int column) async {
      final at = _toSource(row);
      var values = source.rowAt(at);
      if (values == null) {
        await source.ensure(at, 256);
        if (ticket != _jump || !mounted) return null;
        values = source.rowAt(at);
        if (values == null) return false;
      }
      return column < values.length && sheetText(values[column]).isNotEmpty;
    }

    bool inside(int row, int column) =>
        row >= 0 && row < rows && column >= 0 && column < columns;

    var row = from.row;
    var column = from.column;
    if (!inside(row + dr, column + dc)) return;

    final here = await filled(row, column);
    final next = await filled(row + dr, column + dc);
    if (here == null || next == null) return;

    var steps = 0;
    if (here && next) {
      // Along the filled run to its last cell.
      while (inside(row + dr, column + dc)) {
        final more = await filled(row + dr, column + dc);
        if (more == null) return;
        if (!more) break;
        row += dr;
        column += dc;
        if (++steps > _edgeSearchRows) break;
      }
      if (steps > _edgeSearchRows) {
        row = dr > 0 ? rows - 1 : (dr < 0 ? 0 : row);
        column = dc > 0 ? columns - 1 : (dc < 0 ? 0 : column);
      }
    } else {
      // Over the gap to the next filled cell, or to the end.
      var found = false;
      while (inside(row + dr, column + dc)) {
        row += dr;
        column += dc;
        final there = await filled(row, column);
        if (there == null) return;
        if (there || ++steps > _edgeSearchRows) {
          found = there;
          break;
        }
      }
      if (!found) {
        row = dr > 0 ? rows - 1 : (dr < 0 ? 0 : row);
        column = dc > 0 ? columns - 1 : (dc < 0 ? 0 : column);
      }
    }
    if (ticket != _jump || !mounted) return;
    s.moveTo(CellAddress(row, column), extend: extend);
  }

  // --- The plugin behind the sheet ------------------------------------

  /// The selection as the plugin counts: rows of the file, the header row
  /// among them — wherever a sort or a filter has put them on screen.
  Map<String, Object?> _selectionForPlugin() {
    final s = selection;
    final offset = widget.source.hasHeader ? 1 : 0;
    final ranges = <Map<String, Object?>>[];
    var budget = 100000;
    for (final range in s.ranges) {
      final r = range.clampTo(s.rows, s.columns);
      if (r == null) continue;
      if (_shown == null || range.allRows || budget <= 0) {
        final json = range.toJson();
        if (!range.allRows) {
          json['top'] = r.top + offset;
          json['bottom'] = r.bottom + offset;
        }
        ranges.add(json);
        continue;
      }
      // Rows on screen that are not together in the file: one range for each
      // run of them that is.
      final rows = [
        for (var v = r.top; v <= r.bottom && budget-- > 0; v++) _toSource(v),
      ]..sort();
      var start = 0;
      for (var i = 1; i <= rows.length; i++) {
        if (i == rows.length || rows[i] != rows[i - 1] + 1) {
          ranges.add({
            'top': rows[start] + offset,
            'left': range.allColumns ? 0 : r.left,
            'bottom': rows[i - 1] + offset,
            'right': range.allColumns ? null : r.right,
          });
          start = i;
        }
      }
    }
    return {
      'active': {
        'row': _toSource(s.active.row) + offset,
        'column': s.active.column,
      },
      'ranges': ranges,
    };
  }

  /// What the plugin asked for when something it offered was used.
  void _carryOut(SheetAction? done) {
    if (!mounted || done == null) return;
    final copy = done.copy;
    if (copy != null) unawaited(Clipboard.setData(ClipboardData(text: copy)));
    final notice = done.notice;
    if (notice != null && notice.isNotEmpty) showNotice(context, notice);
  }

  /// Enter or a double click on the active cell, for a plugin that asked.
  Future<void> _activate() async {
    final source = widget.source;
    if (!source.wantsActivate) return;
    final s = selection;
    final offset = source.hasHeader ? 1 : 0;
    _carryOut(
      await source.activate(_toSource(s.active.row) + offset, s.active.column),
    );
  }

  // --- The menu -------------------------------------------------------

  /// What can be done with the selection: the host's own things, then the
  /// plugin's. At [at] in the window, or under the active cell when it was
  /// asked for from the keyboard.
  Future<void> _openMenu({Offset? at}) async {
    final g = _geometry;
    if (g == null) return;
    final s = selection;
    final source = widget.source;
    var position = at;
    if (position == null) {
      final box = context.findRenderObject();
      if (box is! RenderBox) return;
      final cell = g.cellRect(s.active.row, s.active.column);
      position = box.localToGlobal(
        Offset(
          _screenX(cell.left, s.active.column) + _cellPadding,
          g.head + cell.bottom - (s.active.row < g.frozenRows ? 0 : _scrollY),
        ),
      );
    }
    final column = s.active.column;
    final values = source.rowAt(_toSource(s.active.row));
    final value = values != null && column < values.length
        ? sheetText(values[column])
        : '';
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final sorted = _sortColumn == column;

    await showAppContextMenu(
      context: context,
      globalPosition: position,
      nodes: [
        MenuItem(
          tr('Copy'),
          icon: Icons.copy_outlined,
          shortcut: 'Ctrl+C',
          onSelected: () => unawaited(_copyAs(SheetCopyFormat.tsv)),
        ),
        MenuItem(
          tr('Copy as JSON'),
          shortcut: 'Ctrl+Shift+C',
          onSelected: () => unawaited(_copyAs(SheetCopyFormat.json)),
        ),
        MenuItem(
          tr('Copy as CSV'),
          onSelected: () => unawaited(_copyAs(SheetCopyFormat.csv)),
        ),
        MenuItem(
          tr('Copy as a Markdown table'),
          onSelected: () => unawaited(_copyAs(SheetCopyFormat.markdown)),
        ),
        const MenuSeparator(),
        MenuItem(
          tr('Select row'),
          shortcut: 'Shift+Space',
          onSelected: s.selectRows,
        ),
        MenuItem(
          tr('Select column'),
          shortcut: mac ? 'Alt+Space' : 'Ctrl+Space',
          onSelected: s.selectColumns,
        ),
        MenuItem(tr('Select all'), shortcut: 'Ctrl+A', onSelected: s.selectAll),
        const MenuSeparator(),
        MenuItem(
          tr('Sort ascending'),
          icon: Icons.arrow_upward,
          checked: sorted && !_descending,
          onSelected: () => unawaited(sortBy(column)),
        ),
        MenuItem(
          tr('Sort descending'),
          icon: Icons.arrow_downward,
          checked: sorted && _descending,
          onSelected: () => unawaited(sortBy(column, descending: true)),
        ),
        MenuItem(
          tr('As in the file'),
          enabled: _sortColumn != null,
          onSelected: () => unawaited(sortBy(null)),
        ),
        const MenuSeparator(),
        MenuItem(
          tr('Find this value'),
          icon: Icons.search,
          enabled: value.isNotEmpty,
          onSelected: () {
            _query.text = value;
            _openFind();
          },
        ),
        MenuItem(
          tr('Go to cell…'),
          shortcut: 'Ctrl+G',
          onSelected: () => unawaited(_goTo()),
        ),
        const MenuSeparator(),
        MenuItem(
          tr('Freeze up to here'),
          enabled: s.active.row > 0 || s.active.column > 0,
          onSelected: () => setState(() {
            _frozenRows = s.active.row;
            _frozenColumns = s.active.column;
          }),
        ),
        MenuItem(
          tr('Unfreeze'),
          enabled: _frozenRows > 0 || _frozenColumns > 0,
          onSelected: () => setState(() {
            _frozenRows = 0;
            _frozenColumns = 0;
          }),
        ),
        const MenuSeparator(),
        MenuItem(tr('Fit column width'), onSelected: () => fitColumn(column)),
        MenuItem(
          tr('Hide column'),
          // Never the last one shown: a sheet of nothing is no way back.
          enabled: _hidden.length + 1 < source.columnCount,
          onSelected: () => _hide(s),
        ),
        MenuItem(
          tr('Show all columns'),
          enabled: _hidden.isNotEmpty,
          onSelected: () => setState(_hidden.clear),
        ),
        if (source.hiddenRows.isNotEmpty)
          MenuItem(
            tr('Show hidden rows'),
            checked: _showHiddenRows,
            onSelected: () {
              setState(() => _showHiddenRows = !_showHiddenRows);
              _refilter(_toSource(s.active.row), reordered: true);
            },
          ),
        MenuItem(
          tr('First row is a header'),
          checked: source.hasHeader,
          onSelected: () => source.setHasHeader(!source.hasHeader),
        ),
        // Then what the plugin behind the sheet offers, named when the sheet
        // arrived — a menu is never made to wait for its rows.
        if (source.menuItems.isNotEmpty) const MenuSeparator(),
        for (final item in source.menuItems)
          MenuItem(
            item.label,
            enabled: item.enabled,
            onSelected: () async {
              final done = await source.press(item.id, _selectionForPlugin());
              _carryOut(done);
            },
          ),
      ],
    );
    if (mounted && widget.hasKeyboard && !_box.hasFocus) _node.requestFocus();
  }

  /// Hides the columns the range being built covers, or the one the keyboard
  /// is on — keeping at least one shown — and steps off them.
  void _hide(SheetSelection s) {
    final current = s.current.clampTo(s.rows, s.columns);
    final from = current?.left ?? s.active.column;
    final to = current?.right ?? s.active.column;
    final columns = widget.source.columnCount;
    setState(() {
      for (var c = from; c <= to; c++) {
        if (_hidden.length + 1 >= columns) break;
        _hidden.add(c);
      }
    });
    if (_hidden.contains(s.active.column)) {
      s.moveBy(0, 1);
      if (_hidden.contains(s.active.column)) s.moveBy(0, -1);
    }
    if (_finding) _restart();
  }

  // --- Sorting -------------------------------------------------------

  /// A press on a heading's arrow: as in the file, then up, then down, then
  /// as in the file again.
  void _cycleSort(int column) {
    if (_sortColumn != column) {
      unawaited(sortBy(column));
    } else if (!_descending) {
      unawaited(sortBy(column, descending: true));
    } else {
      unawaited(sortBy(null));
    }
  }

  /// Shows the rows sorted by [column], or as in the file when it is null.
  /// The keyboard stays on the row of the file it was on.
  Future<void> sortBy(int? column, {bool descending = false}) async {
    _sort?.cancel();
    final keep = _toSource(selection.active.row);
    if (column == null) {
      _sort = null;
      setState(() {
        _sortColumn = null;
        _sorting = false;
        _order = null;
        _rank = null;
      });
      _refilter(keep, reordered: true);
      _arriveNow();
      return;
    }
    final sort = _sort = SheetSort(
      widget.source,
      column,
      descending: descending,
    );
    setState(() {
      _sortColumn = column;
      _descending = descending;
      _sorting = true;
    });
    final order = await sort.run();
    if (!mounted || order == null || !identical(sort, _sort)) return;
    final rank = Int32List(order.length);
    for (var i = 0; i < order.length; i++) {
      rank[order[i]] = i;
    }
    setState(() {
      _order = order;
      _rank = rank;
      _sorting = false;
    });
    _refilter(keep, reordered: true);
    _arriveNow();
  }

  void _arriveNow() {
    final theme = _theme;
    if (theme == null || !theme.animates) return;
    _arrive
      ..duration = theme.animated(kColumnWidthDuration * 2)
      ..forward(from: 0);
  }

  // --- Finding --------------------------------------------------------

  /// Ctrl+F. Inside the selection when there is one worth searching —
  /// more than one cell — and the whole sheet otherwise; the box says which,
  /// and one press changes it.
  void _openFind() {
    final s = selection;
    _findFrom = CellAddress(_toSource(s.active.row), s.active.column);
    _scope = s.isSingleCell ? null : _scopeInSource();
    if (!_finding) _inSelection = _scope != null;
    setState(() => _finding = true);
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _finding) _box.requestFocus();
    });
    if (_query.text.isNotEmpty) _restart();
  }

  /// The selection in the source's own rows. With the filter off the two are
  /// the same; with it on, a range of rows on screen is not a range of rows
  /// of the file, and only the rows it touches are meant.
  List<CellRange>? _scopeInSource() {
    final s = selection;
    final out = <CellRange>[];
    for (final range in s.ranges) {
      final r = range.clampTo(s.rows, s.columns);
      if (r == null) continue;
      if (_shown == null) {
        out.add(
          range.allRows
              ? CellRange.columns(range.left, range.right)
              : CellRange(
                  top: r.top,
                  left: r.left,
                  bottom: r.bottom,
                  right: r.right,
                  allColumns: range.allColumns,
                ),
        );
      } else {
        for (var v = r.top; v <= r.bottom; v++) {
          final row = _toSource(v);
          out.add(
            CellRange(
              top: row,
              left: r.left,
              bottom: row,
              right: r.right,
              allColumns: range.allColumns,
            ),
          );
        }
      }
    }
    return out.isEmpty ? null : out;
  }

  void _closeFind({bool refocus = true}) {
    _typing?.cancel();
    _search?.cancel();
    _search?.removeListener(_onFound);
    final keep = _toSource(selection.active.row);
    setState(() {
      _finding = false;
      _search = null;
      _current = -1;
      _filtered = false;
    });
    // The filter comes off through [_refilter], which is what puts the
    // keyboard back on the row of the file it was on among all of them.
    _refilter(keep);
    if (refocus && widget.hasKeyboard) _node.requestFocus();
  }

  /// Typing waits a moment before it searches: every letter would otherwise
  /// start a pass over a million rows that the next letter throws away.
  void _typed(String _) {
    _typing?.cancel();
    _typing = Timer(const Duration(milliseconds: 180), _restart);
  }

  void _restart() {
    _search?.cancel();
    _search?.removeListener(_onFound);
    final text = _query.text;
    final search = text.isEmpty
        ? null
        : SheetSearch(
            widget.source,
            text,
            within: _inSelection ? _scope : null,
            skipColumns: _hidden.isEmpty ? null : Set.of(_hidden),
          );
    final keep = _toSource(selection.active.row);
    setState(() {
      _search = search;
      _current = -1;
    });
    _refilter(keep);
    if (search == null) return;
    search.addListener(_onFound);
    unawaited(search.run());
  }

  void _onFound() {
    final search = _search;
    if (!mounted || search == null) return;
    if (_filtered) _refilter(_toSource(selection.active.row));
    if (_current < 0 && search.count > 0) {
      // The first match from where the keyboard was, the moment there is
      // one — not when the whole sheet has been read.
      _current = search.indexFrom(_findFrom);
      _goToCurrent();
    }
    setState(() {});
  }

  void _step(int by) {
    final search = _search;
    if (search == null || search.count == 0) return;
    if (_current < 0) {
      final a = selection.active;
      _current = search.indexFrom(CellAddress(_toSource(a.row), a.column));
    } else {
      _current = (_current + by) % search.count;
      if (_current < 0) _current += search.count;
    }
    _goToCurrent();
    setState(() {});
  }

  void _goToCurrent() {
    final search = _search;
    if (search == null || _current < 0 || _current >= search.count) return;
    final found = search[_current];
    selection.moveTo(CellAddress(_toView(found.row), found.column));
  }

  void _toggleInSelection() {
    if (_scope == null) return;
    setState(() => _inSelection = !_inSelection);
    _restart();
    _box.requestFocus();
  }

  void _toggleFilter() {
    setState(() => _filtered = !_filtered);
    _refilter(_toSource(selection.active.row));
    _box.requestFocus();
  }

  /// Shows only the rows with a match in them, or every row again — keeping
  /// the keyboard on the row of the file it was on, wherever that row now
  /// stands.
  void _refilter(int keepRow, {bool reordered = false}) {
    final search = _search;
    final matching = _filtered && search != null ? search.matchingRows : null;
    final order = _order;
    final hidden = _showHiddenRows ? const <int>{} : widget.source.hiddenRows;
    final was = _shown;
    if (!reordered && hidden.isEmpty) {
      if (matching == null && order == null && was == null) return;
      if (matching != null && was != null && matching.length == was.length) {
        return;
      }
    }
    List<int>? next;
    if (order != null) {
      if (matching != null) {
        final rank = _rank!;
        next = [...matching]..sort((a, b) => rank[a] - rank[b]);
      } else {
        next = order;
      }
    } else {
      next = matching;
    }
    // Rows the file keeps hidden stay out of sight, as they do in the
    // program that hid them, until the reader asks to see them.
    if (hidden.isNotEmpty) {
      next = next == null
          ? [
              for (var r = 0; r < widget.source.rowCount; r++)
                if (!hidden.contains(r)) r,
            ]
          : [
              for (final r in next)
                if (!hidden.contains(r)) r,
            ];
    }
    _shown = next;
    _positions = null;
    final s = selection;
    s.resize(_viewRows, widget.source.columnCount);
    final view = _toView(keepRow).clamp(0, math.max(0, _viewRows - 1)).toInt();
    s.moveTo(CellAddress(view, s.active.column));
    setState(() {});
  }

  Widget _findBox(AppearanceSettings theme) {
    final search = _search;
    final String? note;
    if (search == null) {
      note = null;
    } else if (search.capped) {
      note = tr('Stopped at {count} matches.', {'count': SheetSearch.cap});
    } else if (!search.done) {
      note = tr('Searching…');
    } else {
      note = null;
    }
    return FindBox(
      query: _query,
      node: _box,
      theme: theme,
      matches: search?.count ?? 0,
      current: _current < 0 ? 0 : _current + 1,
      hint: tr('Find in this sheet'),
      note: note,
      options: [
        FindOption(
          label: tr('In the selection'),
          on: _inSelection,
          enabled: _scope != null,
          onPressed: _toggleInSelection,
        ),
        FindOption(
          label: tr('Only rows with matches'),
          on: _filtered,
          onPressed: _toggleFilter,
        ),
      ],
      onChanged: _typed,
      onStep: _step,
      onClose: _closeFind,
    );
  }

  // --- Copying -------------------------------------------------------

  /// The most cells one copy takes. A whole column of a million rows is well
  /// inside it; a million rows of fifty columns is a clipboard nobody wants.
  static const int _copyLimit = 2000000;

  /// Ctrl+C: the selection as tab-separated text, the way a spreadsheet
  /// copies it — or with Shift, as JSON.
  ///
  /// Several ranges copy as the rows and columns they cover between them, a
  /// cell no range holds left empty, which is the selection laid out as it
  /// stands on screen. Rows not read yet are read first.
  Future<void> _copy({required bool json}) =>
      _copyAs(json ? SheetCopyFormat.json : SheetCopyFormat.tsv);

  Future<void> _copyAs(SheetCopyFormat format) async {
    final (text, cells) = await _selectionText(format);
    if (!mounted) return;
    if (text == null) {
      if (cells > _copyLimit) {
        showNotice(
          context,
          tr('Too much to copy: {count} cells.', {'count': cells}),
        );
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showNotice(context, switch (format) {
      SheetCopyFormat.json => tr('Copied {count} cells as JSON.', {
        'count': cells,
      }),
      SheetCopyFormat.csv => tr('Copied {count} cells as CSV.', {
        'count': cells,
      }),
      SheetCopyFormat.markdown => tr('Copied {count} cells as a table.', {
        'count': cells,
      }),
      SheetCopyFormat.tsv => tr('Copied {count} cells.', {'count': cells}),
    });
  }

  /// What Ctrl+C (or with [json], Ctrl+Shift+C) would put on the clipboard.
  @visibleForTesting
  Future<String?> selectionAsText({required bool json}) async =>
      (await _selectionText(
        json ? SheetCopyFormat.json : SheetCopyFormat.tsv,
      )).$1;

  /// The selection in any of the shapes it can be copied in.
  @visibleForTesting
  Future<String?> selectionAs(SheetCopyFormat format) async =>
      (await _selectionText(format)).$1;

  /// The text, and how many cells it holds — the count and no text when there
  /// are too many to copy.
  Future<(String?, int)> _selectionText(SheetCopyFormat format) async {
    final s = selection;
    final source = widget.source;
    final ranges = [for (final r in s.ranges) ?r.clampTo(s.rows, s.columns)];
    if (ranges.isEmpty) return (null, 0);

    final rows = _union([for (final r in ranges) (r.top, r.bottom)]);
    // What is seen is what is copied: a hidden column stays out of it.
    final columns = _union([
      for (final r in ranges) (r.left, r.right),
    ]).where((c) => !_hidden.contains(c)).toList();
    final cells = rows.length * columns.length;
    if (cells > _copyLimit) return (null, cells);

    final single = ranges.length == 1;
    final grid = <List<Object?>>[];
    var at = 0;
    while (at < rows.length) {
      // Runs of consecutive rows of the file, read in one piece each.
      final first = _toSource(rows[at]);
      var length = 1;
      while (at + length < rows.length &&
          length < SheetSearch.step &&
          _toSource(rows[at + length]) == first + length) {
        length++;
      }
      final read = await source.readRows(first, length);
      if (!mounted) return (null, 0);
      for (var i = 0; i < length; i++) {
        final view = rows[at + i];
        final values = i < read.length ? read[i] : const <Object?>[];
        grid.add([
          for (final c in columns)
            (single || ranges.any((r) => r.contains(view, c))) &&
                    c < values.length
                ? values[c]
                : null,
        ]);
      }
      at += length;
    }

    final names = source.columnNames;
    final kinds = source.columnKinds;
    final picked = names == null
        ? null
        : [for (final c in columns) c < names.length ? names[c] : ''];
    final pickedKinds = [
      for (final c in columns)
        c < kinds.length ? kinds[c] : SheetColumnKind.text,
    ];
    final text = switch (format) {
      SheetCopyFormat.json => sheetJson(
        grid,
        names: picked,
        kinds: pickedKinds,
        decimalComma: source.decimalComma,
      ),
      SheetCopyFormat.csv => sheetCsv(grid, names: picked),
      SheetCopyFormat.markdown => sheetMarkdown(
        grid,
        names: picked ?? [for (final c in columns) columnLetters(c)],
        kinds: pickedKinds,
      ),
      SheetCopyFormat.tsv => sheetTsv(grid),
    };
    return (text, cells);
  }

  /// Every index the spans cover, once each, in order.
  static List<int> _union(List<(int, int)> spans) {
    spans.sort((a, b) => a.$1.compareTo(b.$1));
    final out = <int>[];
    var next = 0;
    for (final (from, to) in spans) {
      for (var i = math.max(from, next); i <= to; i++) {
        out.add(i);
      }
      if (to + 1 > next) next = to + 1;
    }
    return out;
  }

  /// Ctrl+G: a cell, a range, a column or a row, typed the way it is written.
  Future<void> _goTo() async {
    final String? typed;
    try {
      typed = await promptForText(
        context,
        title: tr('Go to'),
        hint: tr('C12, C2:D9, B:D or 40'),
        confirmLabel: 'Go',
      );
    } on ProviderNotFoundException {
      // Drawn somewhere with no desk to put a window on — a test, a harness.
      return;
    }
    if (!mounted || typed == null) return;
    final range = parseCellRange(typed);
    if (range != null) selection.select(range);
    _node.requestFocus();
  }
}

/// Where everything is, in the sheet's own coordinates: the cells start at
/// (0, 0) under the heading and right of the row numbers.
class _Geometry {
  _Geometry({
    required AppearanceSettings theme,
    required TextScaler scaler,
    required this.widths,
    required this.rows,
    int frozenRows = 0,
    int frozenColumns = 0,
  }) : rowHeight = theme.fontSize * 1.45 + theme.density.verticalPadding * 2,
       head = theme.chromeRowHeight,
       lefts = _prefix(widths),
       gutter = _gutterFor(rows, theme, scaler),
       frozenRows = frozenRows.clamp(0, rows),
       frozenColumns = frozenColumns.clamp(0, widths.length);

  final List<double> widths;
  final int rows;

  /// Rows at the top and columns at the left that stay where they are while
  /// the rest scrolls — frozen by the reader, from the menu.
  final int frozenRows;
  final int frozenColumns;

  double get frozenHeight => frozenRows * rowHeight;
  double get frozenWidth => lefts[frozenColumns];
  final double rowHeight;
  final double head;
  final double gutter;

  /// Where each column starts, and after the last one where the sheet ends.
  final List<double> lefts;

  double get width => lefts.last;
  double get height => rows * rowHeight;

  static List<double> _prefix(List<double> widths) {
    final out = List<double>.filled(widths.length + 1, 0);
    for (var i = 0; i < widths.length; i++) {
      out[i + 1] = out[i] + widths[i];
    }
    return out;
  }

  /// Wide enough for the largest row number, and never narrower than three
  /// digits, so a sheet counting from 12 to 999 does not shift sideways.
  static double _gutterFor(int rows, AppearanceSettings theme, TextScaler s) {
    final digits = math.max(3, '$rows'.length);
    return _charWidth(theme, s) * digits + _cellPadding * 2 + 4;
  }

  /// The first column whose right edge is past [x].
  int firstColumnAt(double x) {
    var lo = 0;
    var hi = widths.length - 1;
    if (hi < 0) return 0;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (lefts[mid + 1] <= x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  Rect cellRect(int row, int column) {
    if (column >= widths.length) return Rect.zero;
    return Rect.fromLTRB(
      lefts[column],
      row * rowHeight,
      lefts[column + 1],
      (row + 1) * rowHeight,
    );
  }

  Rect rangeRect(CellRange r) => Rect.fromLTRB(
    lefts[math.min(r.left, widths.length)],
    r.top * rowHeight,
    lefts[math.min(r.right + 1, widths.length)],
    (r.bottom + 1) * rowHeight,
  );
}

TextStyle _cellStyle(AppearanceSettings theme) => TextStyle(
  color: theme.panelForeground,
  fontSize: theme.fontSize,
  fontFamily: theme.fileFamily,
  fontWeight: theme.fileFontWeight.weight,
  fontFeatures: const [ui.FontFeature.tabularFigures()],
  decoration: TextDecoration.none,
);

TextStyle _nameStyle(AppearanceSettings theme) => TextStyle(
  color: theme.headerForeground,
  fontFamily: theme.uiFamily,
  fontSize: theme.fontSize - 1,
  fontWeight: theme.strongFontWeight.weight,
  decoration: TextDecoration.none,
);

TextStyle _letterStyle(AppearanceSettings theme) => TextStyle(
  color: theme.headerForeground.withValues(alpha: 0.5),
  fontFamily: theme.uiFamily,
  fontSize: theme.fontSize - 2,
  fontWeight: theme.fileFontWeight.weight,
  decoration: TextDecoration.none,
);

TextStyle _numberStyle(AppearanceSettings theme) => TextStyle(
  color: theme.headerForeground.withValues(alpha: 0.6),
  fontSize: theme.fontSize - 1,
  fontFamily: theme.fileFamily,
  fontWeight: theme.fileFontWeight.weight,
  fontFeatures: const [ui.FontFeature.tabularFigures()],
  decoration: TextDecoration.none,
);

double _charWidth(AppearanceSettings theme, TextScaler scaler) =>
    _measure('0000000000', _cellStyle(theme), scaler) / 10;

double _measure(String text, TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    textScaler: scaler,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// A cell's value as one line: a line end inside it shows as ↵ rather than
/// making the row taller or cutting the text at the break.
String _oneLine(Object? value) {
  final text = sheetText(value);
  if (!text.contains('\n') && !text.contains('\r')) return text;
  return text.replaceAll('\r\n', ' ↵ ').replaceAll(RegExp('[\r\n]'), ' ↵ ');
}

/// Laid-out text kept between frames, by cell.
///
/// A scroll moves the same few hundred cells a few pixels; laying their text
/// out again every frame is where the time would go. Kept while near the
/// screen, dropped oldest first.
class _TextCache {
  final Map<(int, int), _Laid> _laid = {};
  static const int _keep = 4000;

  TextPainter lay(
    (int, int) key,
    String text,
    TextStyle style,
    double width,
    TextScaler scaler,
  ) {
    final had = _laid.remove(key);
    if (had != null && had.text == text && had.width == width) {
      _laid[key] = had;
      return had.painter;
    }
    had?.painter.dispose();
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
      textScaler: scaler,
    )..layout(maxWidth: math.max(0, width));
    _laid[key] = _Laid(text, width, painter);
    while (_laid.length > _keep) {
      final oldest = _laid.keys.first;
      _laid.remove(oldest)!.painter.dispose();
    }
    return painter;
  }

  void clear() {
    for (final laid in _laid.values) {
      laid.painter.dispose();
    }
    _laid.clear();
  }
}

class _Laid {
  _Laid(this.text, this.width, this.painter);
  final String text;
  final double width;
  final TextPainter painter;
}

class _Grid extends LeafRenderObjectWidget {
  const _Grid({
    required this.source,
    required this.rowAt,
    required this.sourceRow,
    required this.found,
    required this.merges,
    required this.noteAt,
    required this.sortColumn,
    required this.descending,
    required this.sorting,
    required this.hoverHeading,
    required this.arriving,
    required this.selection,
    required this.geometry,
    required this.theme,
    required this.scaler,
    required this.texts,
    required this.vertical,
    required this.horizontal,
    required this.active,
    required this.range,
    required this.isActive,
  });

  final SheetSource source;

  /// The values of a row on screen — through the filter, when there is one.
  final List<Object?>? Function(int view) rowAt;

  /// Which row of the source a row on screen is: what its number says, and
  /// what its laid-out text is kept under.
  final int Function(int view) sourceRow;

  /// Whether a cell on screen is one the search found; null when there is no
  /// search.
  final bool Function(int view, int column)? found;

  /// Cells joined into one, in the rows on screen.
  final List<CellRange> merges;

  /// Whether a cell on screen carries a note; null when none does.
  final bool Function(int view, int column)? noteAt;

  /// The column the rows are sorted by, which way, and whether the sort is
  /// still being worked out — drawn as an arrow on its heading.
  final int? sortColumn;
  final bool descending;
  final bool sorting;

  /// The heading under the pointer: its arrow shows where a press sorts.
  final int? hoverHeading;

  /// How far a new order of rows has arrived, 0 to 1.
  final double arriving;

  final SheetSelection selection;
  final _Geometry geometry;
  final AppearanceSettings theme;
  final TextScaler scaler;
  final _TextCache texts;
  final ViewportOffset vertical;
  final ViewportOffset horizontal;
  final Rect? active;
  final Rect? range;
  final bool isActive;

  @override
  _RenderGrid createRenderObject(BuildContext context) => _RenderGrid(this);

  @override
  void updateRenderObject(BuildContext context, _RenderGrid render) {
    render.widget = this;
  }
}

class _RenderGrid extends RenderBox {
  _RenderGrid(this._widget);

  _Grid _widget;

  set widget(_Grid value) {
    final old = _widget;
    _widget = value;
    if (old.vertical != value.vertical || old.horizontal != value.horizontal) {
      if (attached) {
        old.vertical.removeListener(markNeedsPaint);
        old.horizontal.removeListener(markNeedsPaint);
        value.vertical.addListener(markNeedsPaint);
        value.horizontal.addListener(markNeedsPaint);
      }
    }
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _widget.vertical.addListener(markNeedsPaint);
    _widget.horizontal.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _widget.vertical.removeListener(markNeedsPaint);
    _widget.horizontal.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final g = _widget.geometry;
    final viewHeight = math.max(0.0, size.height - g.head);
    final viewWidth = math.max(0.0, size.width - g.gutter);
    _widget.vertical.applyViewportDimension(viewHeight);
    _widget.vertical.applyContentDimensions(
      0,
      math.max(0, g.height - viewHeight),
    );
    _widget.horizontal.applyViewportDimension(viewWidth);
    _widget.horizontal.applyContentDimensions(
      0,
      math.max(0, g.width - viewWidth),
    );
    _widget.selection
      ..visibleRows = math.max(
        1,
        ((viewHeight - g.frozenHeight) / g.rowHeight).floor(),
      )
      ..visibleColumns = math.max(
        1,
        g.firstColumnAt(_widget.horizontal.pixels + viewWidth) -
            g.firstColumnAt(_widget.horizontal.pixels),
      );
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final w = _widget;
    final g = w.geometry;
    final theme = w.theme;
    final sx = w.horizontal.pixels;
    final sy = w.vertical.pixels;
    final fh = g.frozenHeight;
    final fw = g.frozenWidth;
    final top = offset.dy + g.head;
    final left = offset.dx + g.gutter;
    final bottom = offset.dy + size.height;
    final right = offset.dx + size.width;

    // Rows and columns in two kinds each: the ones frozen in place, and the
    // ones that scroll under them.
    final firstRow = math.max(g.frozenRows, ((sy + fh) / g.rowHeight).floor());
    final lastRow = math.min(
      g.rows - 1,
      ((sy + size.height - g.head) / g.rowHeight).ceil(),
    );
    final firstCol = math.max(g.frozenColumns, g.firstColumnAt(sx + fw));
    final lastCol = math.min(
      g.widths.length - 1,
      g.firstColumnAt(sx + size.width - g.gutter),
    );
    final rowsFrozen = (0, g.frozenRows - 1);
    final rowsMoving = (firstRow, lastRow);
    final colsFrozen = (0, g.frozenColumns - 1);
    final colsMoving = (firstCol, lastCol);

    final looks = _Looks(theme, w.isActive);

    // --- the cells, a region at a time ---
    void region(
      (int, int) rows,
      (int, int) cols,
      double dx,
      double dy,
      Rect clip,
    ) {
      if (rows.$1 > rows.$2 || cols.$1 > cols.$2) return;
      if (clip.width <= 0 || clip.height <= 0) return;
      _paintCells(
        canvas,
        looks,
        rows,
        cols,
        offset + Offset(g.gutter - dx, g.head - dy),
        clip,
      );
    }

    region(
      rowsMoving,
      colsMoving,
      sx,
      sy,
      Rect.fromLTRB(left + fw, top + fh, right, bottom),
    );
    region(
      rowsFrozen,
      colsMoving,
      sx,
      0,
      Rect.fromLTRB(left + fw, top, right, math.min(bottom, top + fh)),
    );
    region(
      rowsMoving,
      colsFrozen,
      0,
      sy,
      Rect.fromLTRB(left, top + fh, math.min(right, left + fw), bottom),
    );
    region(
      rowsFrozen,
      colsFrozen,
      0,
      0,
      Rect.fromLTRB(
        left,
        top,
        math.min(right, left + fw),
        math.min(bottom, top + fh),
      ),
    );

    // --- the heading row ---
    final headRect = Rect.fromLTWH(
      left,
      offset.dy,
      size.width - g.gutter,
      g.head,
    );
    canvas.drawRect(headRect, Paint()..color = theme.effectiveHeaderBackground);
    _paintHeadings(
      canvas,
      looks,
      colsMoving,
      offset.dx + g.gutter - sx,
      offset.dy,
      Rect.fromLTRB(left + fw, offset.dy, right, top),
    );
    _paintHeadings(
      canvas,
      looks,
      colsFrozen,
      offset.dx + g.gutter,
      offset.dy,
      Rect.fromLTRB(left, offset.dy, math.min(right, left + fw), top),
    );

    // --- the row numbers ---
    final gutterRect = Rect.fromLTWH(
      offset.dx,
      top,
      g.gutter,
      size.height - g.head,
    );
    canvas.drawRect(
      gutterRect,
      Paint()..color = theme.effectiveHeaderBackground,
    );
    _paintNumbers(
      canvas,
      looks,
      rowsMoving,
      offset.dx,
      top - sy,
      Rect.fromLTRB(offset.dx, top + fh, left, bottom),
    );
    _paintNumbers(
      canvas,
      looks,
      rowsFrozen,
      offset.dx,
      top,
      Rect.fromLTRB(offset.dx, top, left, math.min(bottom, top + fh)),
    );

    // The edge of what is frozen, drawn like the edge of the headings.
    final edge = Paint()
      ..color = theme.chromeRule
      ..strokeWidth = 0;
    if (g.frozenRows > 0) {
      canvas.drawLine(
        Offset(offset.dx, top + fh),
        Offset(right, top + fh),
        edge,
      );
    }
    if (g.frozenColumns > 0) {
      canvas.drawLine(
        Offset(left + fw, offset.dy),
        Offset(left + fw, bottom),
        edge,
      );
    }

    // --- the corner, and the edges of what does not scroll ---
    canvas.drawRect(
      Rect.fromLTWH(offset.dx, offset.dy, g.gutter, g.head),
      Paint()..color = theme.effectiveHeaderBackground,
    );
    final rule = Paint()
      ..color = theme.chromeRule
      ..strokeWidth = 0;
    canvas.drawLine(
      Offset(offset.dx, offset.dy + g.head),
      Offset(offset.dx + size.width, offset.dy + g.head),
      rule,
    );
    canvas.drawLine(
      Offset(offset.dx + g.gutter, offset.dy),
      Offset(offset.dx + g.gutter, offset.dy + size.height),
      rule,
    );

    // Something has scrolled under an edge: a soft shadow says so.
    if (sy > 0) {
      _shade(
        canvas,
        Rect.fromLTWH(left, top + fh, size.width - g.gutter, 6),
        Alignment.topCenter,
        Alignment.bottomCenter,
      );
    }
    if (sx > 0) {
      _shade(
        canvas,
        Rect.fromLTWH(left + fw, top, 6, size.height - g.head),
        Alignment.centerLeft,
        Alignment.centerRight,
      );
    }
  }

  /// The cells of [rows] by [cols], drawn from [origin] — where cell (0, 0)
  /// would be — inside [clip]: the selection under the text, the grid, the
  /// text, what a search found, and the active cell's outline over it all.
  void _paintCells(
    Canvas canvas,
    _Looks looks,
    (int, int) rows,
    (int, int) cols,
    Offset origin,
    Rect clip,
  ) {
    final w = _widget;
    final g = w.geometry;
    final sel = w.selection;
    final kinds = w.source.columnKinds;
    canvas.save();
    canvas.clipRect(clip);

    for (final r in sel.fixed) {
      final c = r.clampTo(sel.rows, sel.columns);
      if (c != null) {
        canvas.drawRect(g.rangeRect(c).shift(origin), looks.selectionFill);
      }
    }
    final range = w.range;
    if (range != null && !sel.current.isSingleCell) {
      canvas.drawRect(range.shift(origin), looks.selectionFill);
    }

    // The joined cells in sight, and every cell they cover: the grid has no
    // lines inside one, and its text is its first cell's, across all of it.
    final merges = <CellRange>[
      for (final m in w.merges)
        if (m.bottom >= rows.$1 &&
            m.top <= rows.$2 &&
            m.right >= cols.$1 &&
            m.left <= cols.$2 &&
            m.right < g.widths.length)
          m,
    ];
    Rect mergeRect(CellRange m) => Rect.fromLTRB(
      origin.dx + g.lefts[m.left],
      origin.dy + m.top * g.rowHeight,
      origin.dx + g.lefts[m.right + 1],
      origin.dy + (m.bottom + 1) * g.rowHeight,
    );
    bool joined(int r, int c) => merges.any(
      (m) => r >= m.top && r <= m.bottom && c >= m.left && c <= m.right,
    );

    canvas.save();
    if (merges.isNotEmpty) {
      var lines = Path()..addRect(clip);
      for (final m in merges) {
        lines = Path.combine(
          PathOperation.difference,
          lines,
          Path()..addRect(mergeRect(m).deflate(0.75)),
        );
      }
      canvas.clipPath(lines);
    }
    for (var c = cols.$1; c <= cols.$2 + 1; c++) {
      final x = origin.dx + g.lefts[math.min(c, g.widths.length)];
      canvas.drawLine(
        Offset(x, clip.top),
        Offset(x, math.min(clip.bottom, origin.dy + g.height)),
        looks.gridLine,
      );
    }
    final end = math.min(clip.right, origin.dx + g.width);
    for (var r = rows.$1; r <= rows.$2 + 1; r++) {
      final y = origin.dy + r * g.rowHeight;
      canvas.drawLine(Offset(clip.left, y), Offset(end, y), looks.gridLine);
    }
    canvas.restore();

    final found = w.found;
    final noteAt = w.noteAt;
    // A new order of rows fades in rather than replacing the old one in a
    // frame: it is a different picture, and it should be seen arriving.
    final fading = w.arriving < 1;
    if (fading) {
      canvas.saveLayer(
        clip,
        Paint()..color = Color.fromRGBO(0, 0, 0, w.arriving.clamp(0, 1)),
      );
    }
    for (var r = rows.$1; r <= rows.$2; r++) {
      final values = w.rowAt(r);
      final key = w.sourceRow(r);
      final top = origin.dy + r * g.rowHeight;
      for (var c = cols.$1; c <= cols.$2; c++) {
        final left = origin.dx + g.lefts[c];
        final width = g.widths[c];
        if (width <= 0) continue;
        if (values == null) {
          // Not here yet: a faint bar where the text will be, never a
          // spinner over the whole sheet.
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                left + _cellPadding,
                top + g.rowHeight * 0.32,
                width * 0.45,
                g.rowHeight * 0.36,
              ),
              const Radius.circular(3),
            ),
            looks.placeholder,
          );
          continue;
        }
        if (found != null && found(r, c)) {
          canvas.drawRect(
            Rect.fromLTWH(left, top, width, g.rowHeight),
            looks.foundFill,
          );
        }
        if (noteAt != null && noteAt(r, c)) {
          // A note's mark in the cell's corner, where a spreadsheet puts it.
          canvas.drawPath(
            Path()
              ..moveTo(left + width - 7, top + 1)
              ..lineTo(left + width - 1, top + 1)
              ..lineTo(left + width - 1, top + 7)
              ..close(),
            looks.noteMark,
          );
        }
        if (merges.isNotEmpty && joined(r, c)) continue;
        if (c >= values.length) continue;
        final text = _oneLine(values[c]);
        if (text.isEmpty) continue;
        final room = width - _cellPadding * 2;
        final cell = values[c];
        final role = cell is SheetCell ? cell.role : null;
        final laid = w.texts.lay(
          (key, c),
          text,
          role == null ? looks.cell : (looks.roles[role] ?? looks.cell),
          room,
          w.scaler,
        );
        final kind = c < kinds.length ? kinds[c] : SheetColumnKind.text;
        final dx = switch (kind) {
          SheetColumnKind.number => left + width - _cellPadding - laid.width,
          SheetColumnKind.boolean => left + (width - laid.width) / 2,
          SheetColumnKind.text => left + _cellPadding,
        };
        laid.paint(canvas, Offset(dx, top + (g.rowHeight - laid.height) / 2));
      }
    }
    // A joined cell's text, laid across all of it and set in its middle
    // the way the column sets any other.
    for (final m in merges) {
      final values = w.rowAt(m.top);
      if (values == null || m.left >= values.length) continue;
      final text = _oneLine(values[m.left]);
      if (text.isEmpty) continue;
      final rect = mergeRect(m);
      final cell = values[m.left];
      final role = cell is SheetCell ? cell.role : null;
      final laid = w.texts.lay(
        (-10 - m.top, m.left),
        text,
        role == null ? looks.cell : (looks.roles[role] ?? looks.cell),
        rect.width - _cellPadding * 2,
        w.scaler,
      );
      final kind = m.left < kinds.length ? kinds[m.left] : SheetColumnKind.text;
      final dx = kind == SheetColumnKind.number
          ? rect.right - _cellPadding - laid.width
          : m.right > m.left
          ? rect.left + (rect.width - laid.width) / 2
          : rect.left + _cellPadding;
      canvas.save();
      canvas.clipRect(rect.intersect(clip));
      laid.paint(
        canvas,
        Offset(dx, rect.top + (rect.height - laid.height) / 2),
      );
      canvas.restore();
    }
    if (fading) canvas.restore();

    final active = w.active;
    if (active != null && g.rows > 0 && g.widths.isNotEmpty) {
      canvas.drawRect(active.shift(origin).deflate(1), looks.outline);
    }
    canvas.restore();
  }

  /// The headings of [cols], the first column's left edge at [x0].
  void _paintHeadings(
    Canvas canvas,
    _Looks looks,
    (int, int) cols,
    double x0,
    double y,
    Rect clip,
  ) {
    if (cols.$1 > cols.$2 || clip.width <= 0) return;
    final w = _widget;
    final g = w.geometry;
    final sel = w.selection;
    final theme = w.theme;
    final names = w.source.columnNames;
    canvas.save();
    canvas.clipRect(clip);
    for (var c = cols.$1; c <= cols.$2; c++) {
      final left = x0 + g.lefts[c];
      final width = g.widths[c];
      if (width <= 0) {
        // A hidden column leaves a mark where it was, so the reader can see
        // that something is there to be shown again.
        canvas.drawRect(
          Rect.fromLTWH(left - 1.5, y + 4, 3, g.head - 8),
          looks.touched,
        );
        continue;
      }
      final cell = Rect.fromLTWH(left, y, width, g.head);
      if (sel.coversColumn(c)) {
        canvas.drawRect(cell, looks.lit);
      } else if (sel.touchesColumn(c)) {
        canvas.drawRect(cell, looks.touched);
      }
      if (c == sel.active.column) {
        canvas.drawRect(
          Rect.fromLTWH(left, y + g.head - 2, width, 2),
          looks.marker,
        );
      }
      canvas.drawLine(
        Offset(left + width, y + 3),
        Offset(left + width, y + g.head - 3),
        looks.gridLine,
      );

      final label = columnLetters(c);
      final title = names != null && c < names.length ? names[c] : '';
      // The arrow a press sorts by: the sorted column's, in the accent, and
      // a faint one on the heading under the pointer to say it is there.
      final sorted = c == w.sortColumn;
      final arrow = sorted || c == w.hoverHeading;
      final room = width - _cellPadding * 2 - (arrow ? _sortZone - 4 : 0);
      if (arrow && width > _sortZone * 2) {
        // Keyed by its state as well as its column: the cache compares the
        // text, and the same arrow in another colour is the same text.
        final glyph = w.texts.lay(
          (sorted ? (w.sorting ? -5 : -4) : -3, c),
          sorted && w.descending ? '▼' : '▲',
          looks.letter.copyWith(
            color: sorted
                ? theme.accentColor.withValues(
                    alpha: w.sorting ? 0.45 : looks.strength,
                  )
                : theme.headerForeground.withValues(alpha: 0.3),
          ),
          _sortZone,
          w.scaler,
        );
        glyph.paint(
          canvas,
          Offset(
            left + width - _cellPadding - glyph.width,
            y + (g.head - glyph.height) / 2,
          ),
        );
      }
      if (title.isEmpty) {
        final laid = w.texts.lay((-1, c), label, looks.letter, room, w.scaler);
        laid.paint(
          canvas,
          Offset(
            left + (width - laid.width) / 2,
            y + (g.head - laid.height) / 2,
          ),
        );
      } else {
        final mark = w.texts.lay((-1, c), label, looks.letter, room, w.scaler);
        final gap = mark.width + _cellPadding;
        final laid = w.texts.lay(
          (-2, c),
          title,
          looks.name,
          room - gap,
          w.scaler,
        );
        mark.paint(
          canvas,
          Offset(left + _cellPadding, y + (g.head - mark.height) / 2),
        );
        laid.paint(
          canvas,
          Offset(left + _cellPadding + gap, y + (g.head - laid.height) / 2),
        );
      }
    }
    canvas.restore();
  }

  /// The row numbers of [rows], row 0's top at [y0].
  void _paintNumbers(
    Canvas canvas,
    _Looks looks,
    (int, int) rows,
    double x,
    double y0,
    Rect clip,
  ) {
    if (rows.$1 > rows.$2 || clip.height <= 0) return;
    final w = _widget;
    final g = w.geometry;
    final sel = w.selection;
    canvas.save();
    canvas.clipRect(clip);
    for (var r = rows.$1; r <= rows.$2; r++) {
      final top = y0 + r * g.rowHeight;
      final cell = Rect.fromLTWH(x, top, g.gutter, g.rowHeight);
      if (sel.coversRow(r)) {
        canvas.drawRect(cell, looks.lit);
      } else if (sel.touchesRow(r)) {
        canvas.drawRect(cell, looks.touched);
      }
      if (r == sel.active.row) {
        canvas.drawRect(
          Rect.fromLTWH(x + g.gutter - 2, top, 2, g.rowHeight),
          looks.marker,
        );
      }
      final laid = w.texts.lay(
        (w.sourceRow(r), -1),
        '${w.sourceRow(r) + 1}',
        looks.number,
        g.gutter - _cellPadding * 2,
        w.scaler,
      );
      laid.paint(
        canvas,
        Offset(
          x + g.gutter - _cellPadding - 2 - laid.width,
          top + (g.rowHeight - laid.height) / 2,
        ),
      );
    }
    canvas.restore();
  }

  void _shade(Canvas canvas, Rect rect, Alignment from, Alignment to) {
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: from,
          end: to,
          colors: [
            const Color(0xFF000000).withValues(alpha: 0.14),
            const Color(0x00000000),
          ],
        ).createShader(rect),
    );
  }
}

/// The paints and styles one frame of a sheet is drawn with, made once per
/// frame rather than once per cell.
class _Looks {
  _Looks(AppearanceSettings theme, bool active)
    : strength = active ? 1.0 : 0.55,
      cell = _cellStyle(theme),
      letter = _letterStyle(theme),
      name = _nameStyle(theme),
      number = _numberStyle(theme),
      gridLine = Paint()
        ..color = theme.panelForeground.withValues(alpha: 0.1)
        ..strokeWidth = 0,
      placeholder = Paint()
        ..color = theme.panelForeground.withValues(alpha: 0.06),
      // What a search found is marked the way a reading marks it: in the
      // colour a marked file wears. Not a colour of its own.
      foundFill = Paint()..color = theme.markedColor.withValues(alpha: 0.28),
      noteMark = Paint()..color = theme.markedColor {
    final accent = theme.accentColor;
    selectionFill = Paint()..color = accent.withValues(alpha: 0.16 * strength);
    lit = Paint()..color = accent.withValues(alpha: 0.32 * strength);
    touched = Paint()..color = accent.withValues(alpha: 0.14 * strength);
    marker = Paint()..color = accent.withValues(alpha: strength);
    outline = Paint()
      ..color = accent.withValues(alpha: strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    // What a cell *is*, as the file said it — described, and drawn from the
    // palette: a heading or a total in the strong weight, a quiet cell
    // quieter, an error in the red a diff marks what went.
    final strong = cell.copyWith(fontWeight: theme.strongFontWeight.weight);
    roles = {
      'strong': strong,
      'total': strong,
      'dim': cell.copyWith(color: theme.panelForeground.withValues(alpha: 0.5)),
      'accent': cell.copyWith(color: accent),
      'error': cell.copyWith(color: DiffColours.of(theme).removed),
    };
  }

  final double strength;
  final TextStyle cell;
  final TextStyle letter;
  final TextStyle name;
  final TextStyle number;
  final Paint gridLine;
  final Paint placeholder;
  final Paint foundFill;
  final Paint noteMark;
  late final Paint selectionFill;
  late final Paint lit;
  late final Paint touched;
  late final Paint marker;
  late final Paint outline;
  late final Map<String, TextStyle> roles;
}

class _Message extends StatelessWidget {
  const _Message({required this.theme, required this.text});

  final AppearanceSettings theme;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      text,
      style: TextStyle(
        color: theme.panelForeground.withValues(alpha: 0.6),
        fontSize: theme.fontSize,
        decoration: TextDecoration.none,
      ),
    ),
  );
}
