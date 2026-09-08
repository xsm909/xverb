import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/avatars.dart';
import '../../core/plugins/viewer.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../state/panel_attachment.dart';
import '../motion.dart';
import '../../state/listing_cursor.dart';
import '../widgets/listing_motion.dart';
import '../widgets/press_and_hold.dart';
import 'row_drag.dart';
import '../viewer/diff_syntax.dart';
import 'commit_graph.dart';
import 'plugin_icons.dart';
import '../widgets/hint.dart';
import '../viewer/reading_colours.dart';
import '../picture_filter.dart';

/// Moves a table's cursor with the keys a listing has always answered to.
///
/// Lives beside the table rather than in either place that calls it, because
/// both places call it for the same reason and a panel and a full-screen page
/// disagreeing about what Home does would be two tables, not one. Returns true
/// when the key was used, so everything it does not want goes on to the
/// application's own bindings — Tab and the function row never stop working.
///
/// This is *not* the `keys` contribution. A plugin that declared `keys` has
/// already been offered the key by the time this runs: what it wants is its
/// own, and what it leaves is a listing being read, which is the host's.
bool driveTable(
  PanelAttachment? attachment,
  LogicalKeyboardKey key, {
  bool shift = false,
  bool acrossParts = false,
}) {
  if (attachment == null) return false;

  // Tab walks from one part of a split to the next. Only where the host has a
  // Tab to spare: in a panel it belongs to the application, and a view that
  // could swallow it would be a view that can strand the keyboard.
  if (acrossParts && key == LogicalKeyboardKey.tab) {
    return attachment.focusNextPart(backwards: shift);
  }

  if (attachment.contentOfPart(attachment.focusedPart)?.kind !=
      ViewerContentKind.table) {
    return false;
  }

  final cursor = attachment.listingCursor;
  if (cursor.count == 0) return false;

  switch (key) {
    case LogicalKeyboardKey.arrowDown:
      cursor.move(1);
    case LogicalKeyboardKey.arrowUp:
      cursor.move(-1);
    case LogicalKeyboardKey.pageDown:
      cursor.move(cursor.pageStep);
    case LogicalKeyboardKey.pageUp:
      cursor.move(-cursor.pageStep);
    case LogicalKeyboardKey.home:
      cursor.moveTo(0);
    case LogicalKeyboardKey.end:
      cursor.moveTo(cursor.count - 1);
    // The panel's own key for picking a row out, in a plugin's listing. Marks
    // and steps down, so a run of files is picked out with one finger held —
    // and Shift+Insert, like the panel, marks without moving.
    case LogicalKeyboardKey.insert:
      if (!attachment.isInteractive) return false;
      cursor.toggleMark(cursor.index);
      if (!shift) cursor.move(1);

    case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
      // A table being read rather than worked in has nothing to open, and a
      // key that silently does nothing is worse than one that falls through.
      if (!attachment.isInteractive) return false;
      unawaited(
        attachment.activate(cursor.index, part: attachment.focusedPart),
      );
    default:
      return false;
  }
  return true;
}

/// The palette, with a default for a harness that has no settings above it.
///
/// Plugin content is pumped on its own in tests and is reached from three
/// different pages, and colours are not worth a crash on the way to drawing a
/// file.
///
/// **Inside a reading it hands back the reading's pair** in place of the
/// panel's, and that one substitution is what gave the page its own colours
/// without threading a second palette through forty call sites. Every widget
/// that draws content — a table, a graph, a form, the line between two panes —
/// asks this one function what it is drawing on; so the page says once that the
/// surface is its own ([ReadingSurface]) and they all draw on it. Nothing here
/// is being lied to: `panelBackground` has always meant *the surface under
/// this*, and under a page that is the page.
///
/// The chrome does **not** come through here — the viewer's title bar and its
/// status strip read the store directly and go on using the header's colours,
/// which is what they are for.
AppearanceSettings appearanceOf(BuildContext context, {bool watch = true}) {
  final AppearanceSettings base;
  try {
    final store = watch
        ? context.watch<SettingsStore>()
        : context.read<SettingsStore>();
    base = store.appearance;
  } on ProviderNotFoundException {
    return const AppearanceSettings();
  }
  // Depended on while building, merely read outside one: the two callers that
  // pass `watch: false` are a scroll callback and a hint's timer, and neither
  // is a place to be registering a rebuild.
  final surface = watch
      ? context.dependOnInheritedWidgetOfExactType<ReadingSurface>()
      : context.getInheritedWidgetOfExactType<ReadingSurface>();
  if (surface == null) return base;
  return base.copyWith(
    panelBackground: surface.colours.paper,
    panelForeground: surface.colours.ink,
  );
}

/// A table drawn the way this application draws a listing.
///
/// It used to be Material's `DataTable`, which meant a plugin's table had no
/// column widths, no alignment, no cursor, no keyboard and none of the panel's
/// look — while a real listing sat three feet away in the next panel. This is
/// that listing, for content a plugin sends.
class PluginTable extends StatefulWidget {
  const PluginTable({
    super.key,
    required this.content,
    this.cursor,
    this.onActivateRow,
    this.onMarkRow,
    this.isActive = true,
    this.part = '',
    this.canDrag = false,
  });

  final ViewerContent content;

  /// Where the keyboard is. Null for a table nothing drives — a file being
  /// viewed, a command's answer — which then keeps a cursor of its own so the
  /// mouse still has somewhere to put it.
  final ListingCursor? cursor;

  final void Function(int row)? onActivateRow;

  /// The secondary press, with where it landed: a view may answer it with a
  /// menu, and a menu has to be drawn where the finger is.
  final void Function(int row, Offset at)? onMarkRow;

  /// Whether this table is the thing being worked in. Dims the cursor when it
  /// is not, exactly as an inactive panel's does.
  final bool isActive;

  /// Which part of a split it is, for the rows it hands to a drag. Empty when
  /// the content is not a split, and then nothing can be dragged anywhere:
  /// there is no other part for them to go to.
  final String part;

  /// Whether its rows can be picked up and carried to another part.
  final bool canDrag;

  @override
  State<PluginTable> createState() => _PluginTableState();
}

class _PluginTableState extends State<PluginTable>
    with SingleTickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  ListingCursor? _own;

  /// The same mark the panels slide, on the same two settings. A cursor that
  /// slides in a panel and cuts in the table beside it reads as two programs
  /// sharing a window.
  late final CursorSlide _slide = CursorSlide(this);

  ListingCursor get _cursor => widget.cursor ?? (_own ??= ListingCursor());

  /// The row a click landed on, for as long as a second click on it would be
  /// the other half of a double one. Counted here rather than with
  /// `onDoubleTap` for the reason the file listing writes down: a detector
  /// carrying both makes every single tap wait the double-tap window out.
  int _armed = -1;
  DateTime? _armedAt;

  @override
  void initState() {
    super.initState();
    _cursor.resize(widget.content.rows.length);
    _cursor.addListener(_onCursor);
  }

  @override
  void didUpdateWidget(PluginTable old) {
    super.didUpdateWidget(old);
    if (old.cursor != widget.cursor) {
      old.cursor?.removeListener(_onCursor);
      _cursor.addListener(_onCursor);
    }
    if (old.content != widget.content) {
      _cursor.resize(widget.content.rows.length);
    }
  }

  @override
  void dispose() {
    _cursor.removeListener(_onCursor);
    _own?.dispose();
    _slide.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onCursor() {
    if (mounted) setState(_revealCursor);
  }

  /// Scrolls the least it can to put the cursor on screen — the same rule the
  /// file listing follows, so a table and a listing answer the arrow keys
  /// alike.
  void _revealCursor() {
    if (!_scroll.hasClients) return;
    final height = _rowHeight(appearanceOf(context, watch: false));
    final top = _cursor.index * height;
    final bottom = top + height;
    final view = _scroll.position;
    if (top < view.pixels) {
      _scroll.jumpTo(top.clamp(0, view.maxScrollExtent));
    } else if (bottom > view.pixels + view.viewportDimension) {
      _scroll.jumpTo(
        (bottom - view.viewportDimension).clamp(0, view.maxScrollExtent),
      );
    }
  }

  double _rowHeight(AppearanceSettings theme) =>
      theme.fontSize * 1.45 + theme.density.verticalPadding * 2;

  /// A click puts the cursor here; opening takes a second one close behind it.
  bool _completesDoubleClick(int index) {
    final now = DateTime.now();
    final was = _armedAt;
    if (index == _armed &&
        was != null &&
        now.difference(was) < kDoubleTapTimeout) {
      _armed = -1;
      _armedAt = null;
      return true;
    }
    _armed = index;
    _armedAt = now;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = appearanceOf(context);
    final content = widget.content;
    final rowHeight = _rowHeight(theme);
    final columns = _columnsOf(content);

    return LayoutBuilder(
      builder: (context, constraints) {
        _cursor.visibleRows = (constraints.maxHeight / rowHeight).floor().clamp(
          1,
          1 << 20,
        );
        final lanes = _lanesIn(content);
        final widths = _widthsFor(
          columns,
          constraints.maxWidth,
          theme,
          content,
        );

        // The same two settings the panels answer, read the same way: with
        // either off, nothing below is built at all — which is what makes
        // "off" mean off rather than "the same machinery, at no distance".
        final sliding = theme.animates && theme.animateFileListCursor;
        final lively = theme.animates && theme.animateLiveFileList;
        _slide.follow(
          _cursor.index,
          content,
          rowHeight,
          _scroll.hasClients ? _scroll.position.pixels : 0,
          sliding: sliding,
          length: theme.animated(kCursorAnimationDuration),
        );

        // Which column the row is *about*, and the only one that moves. In a
        // log it is the subject, in a list of files the path — and in both it
        // is the column that stretches, because a column that stretches is
        // the one the row is for. A date that leaned with it would stop the
        // columns being columns, which is the panel's own rule about its size
        // and its date.
        final leaning = columns.indexWhere((column) => column.isFlexible);

        final list = Scrollbar(
          controller: _scroll,
          child: ListView.builder(
            controller: _scroll,
            itemExtent: rowHeight,
            itemCount: content.rows.length,
            itemBuilder: (context, index) {
              final isCursor = index == _cursor.index;
              final drawn = _Row(
                row: content.rows[index],
                columns: columns,
                widths: widths,
                lanes: lanes,
                isMarked: _cursor.isMarked(index),
                height: rowHeight,
                theme: theme,
                isCursor: isCursor,
                isActive: widget.isActive,
                lively: lively,
                leaning: leaning,
                cursorMoving: _slide.progressFor(
                  index,
                  isCursor: isCursor,
                  sliding: sliding,
                ),
                // With the mark sliding underneath, a row painting its own
                // would be a second cursor, sitting still.
                paintCursorFill: !sliding,
                striped: theme.alternateRowShading && index.isOdd,
                onTap: () {
                  // The mouse's half of picking rows out, and the two
                  // shortcuts every listing on every desktop already uses:
                  // one row with Ctrl, a run of them with Shift. Neither
                  // opens anything — picking out and opening are different
                  // answers to the same click, and the modifier is which.
                  final keys = HardwareKeyboard.instance;
                  if (keys.isControlPressed || keys.isMetaPressed) {
                    _cursor.toggleMark(index);
                    _cursor.moveTo(index);
                    return;
                  }
                  if (keys.isShiftPressed) {
                    _cursor.markRange(_cursor.index, index);
                    _cursor.moveTo(index);
                    return;
                  }
                  // A plain click is "this one, and only this one". Leaving
                  // nine other rows picked out behind a click that said
                  // nothing about them is how a selection gets acted on by
                  // surprise.
                  _cursor.clearMarks();
                  _cursor.moveTo(index);
                  if (_completesDoubleClick(index)) {
                    widget.onActivateRow?.call(index);
                  }
                },
                onMenu: widget.onMarkRow == null
                    ? null
                    : (at) {
                        _cursor.moveTo(index);
                        widget.onMarkRow!(index, at);
                      },
              );

              if (!widget.canDrag || widget.part.isEmpty) return drawn;

              // What is carried is what is picked out, and the row under the
              // hand when nothing is — the same rule the keys and the menu
              // follow, so a drag never means something a press would not.
              final carried = _cursor.isMarked(index)
                  ? _cursor.marked
                  : <int>[index];
              return Draggable<RowDrag>(
                data: RowDrag(part: widget.part, rows: carried),
                dragAnchorStrategy: pointerDragAnchorStrategy,
                feedback: _Carried(count: carried.length, theme: theme),
                // The row stays where it is, drawn dimmer: it has not gone
                // anywhere yet, and a hole in the list where the hand is would
                // be the list answering before the plugin did.
                childWhenDragging: Opacity(opacity: 0.4, child: drawn),
                child: drawn,
              );
            },
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(columns: columns, widths: widths, theme: theme),
            Expanded(
              child: !sliding || content.rows.isEmpty
                  ? list
                  : ClipRect(
                      child: Stack(
                        children: [
                          // Under the rows, not over them: the rows are
                          // transparent where they are not striped, so the
                          // mark shows through the one it is on.
                          CursorMark(
                            slide: _slide,
                            index: _cursor.index,
                            rowHeight: rowHeight,
                            scroll: _scroll,
                            colour: theme.cursorColor.withValues(
                              alpha: widget.isActive ? 1.0 : 0.35,
                            ),
                          ),
                          list,
                        ],
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// The columns as declared, or one per cell when a plugin sent rows and no
  /// header at all — which is a table too, and refusing to draw it would be
  /// this widget being stricter than the one it replaces.
  List<ListingColumn> _columnsOf(ViewerContent content) {
    if (content.columns.isNotEmpty) return content.columns;
    final width = content.rows.fold<int>(
      0,
      (widest, row) => row.cells.length > widest ? row.cells.length : widest,
    );
    return [
      for (var i = 0; i < width; i++) const ListingColumn(label: '', flex: 1),
    ];
  }

  /// What each column gets, in pixels.
  ///
  /// The fixed ones take theirs first and the rest share what is left, which
  /// is the arrangement that lets a git log say the one thing a grid of text
  /// cannot: the graph must not stretch, the subject must, and the date must
  /// not wrap.
  List<double> _widthsFor(
    List<ListingColumn> columns,
    double available,
    AppearanceSettings theme,
    ViewerContent content,
  ) {
    final room = available - _padding * 2 - _gap * (columns.length - 1);
    var fixed = 0.0;
    var flex = 0;
    for (final column in columns) {
      if (column.isFlexible) {
        flex += column.flex;
      } else {
        fixed += _fixedWidth(column, theme, content);
      }
    }

    final free = room - fixed;
    return [
      for (final column in columns)
        if (!column.isFlexible)
          _fixedWidth(column, theme, content)
        else
          // A minimum, so a narrow panel gives up on the fixed columns rather
          // than squeezing every flexible one to nothing.
          (free <= 0 ? _minFlex : (free * column.flex / flex)).clamp(
            _minFlex,
            double.infinity,
          ),
    ];
  }

  double _fixedWidth(
    ListingColumn column,
    AppearanceSettings theme,
    ViewerContent content,
  ) {
    if (column.width != null) return theme.scaled(column.width!);
    // A braid is as wide as its widest row, which is a fact about the whole
    // table rather than about the column — and one the plugin should not have
    // to work out in pixels when it already knows it in lanes.
    if (column.kind == ListingCellKind.graph) {
      return CommitGraph.widthFor(theme, _lanesIn(content));
    }
    return theme.scaled(_defaultWidth(column.kind));
  }

  int _lanesIn(ViewerContent content) {
    var widest = 1;
    for (final row in content.rows) {
      final lanes = row.graph?.width ?? 0;
      if (lanes > widest) widest = lanes;
    }
    // Past this the column is full: it squeezes the lanes to fit as many as
    // it can, and beyond that it clips rather than eating the subject, which
    // is what a log is read for.
    return widest > CommitGraph.mostLanes ? CommitGraph.mostLanes : widest;
  }

  static double _defaultWidth(ListingCellKind kind) => switch (kind) {
    ListingCellKind.icon => 26,
    ListingCellKind.mono => 84,
    _ => 96,
  };

  static const double _padding = 6;
  static const double _gap = 8;
  static const double _minFlex = 36;
}

/// What the hand carries: how many rows, and nothing about what they are.
///
/// A pill rather than a copy of the rows. Half a listing dragged under the
/// pointer is unreadable at any size, and what the eye actually needs on the
/// way across is the count — one file or nine, and did it pick up the marks.
class _Carried extends StatelessWidget {
  const _Carried({required this.count, required this.theme});

  final int count;
  final AppearanceSettings theme;

  @override
  Widget build(BuildContext context) {
    final ink = legibleOn(theme.accentColor, theme);
    return Transform.translate(
      // Off the pointer, so the pill is beside the hand rather than under it.
      offset: const Offset(12, 8),
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: ShapeDecoration(
            color: theme.accentColor,
            shape: const StadiumBorder(),
          ),
          child: Text(
            count == 1 ? tr('1 file') : '$count ${tr('files')}',
            style: TextStyle(
              color: ink,
              fontSize: theme.fontSize - 1,
              fontWeight: theme.strongFontWeight.weight,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// The strip of column names, in the same shape the file panel's is.
class _Header extends StatelessWidget {
  const _Header({
    required this.columns,
    required this.widths,
    required this.theme,
  });

  final List<ListingColumn> columns;
  final List<double> widths;
  final AppearanceSettings theme;

  @override
  Widget build(BuildContext context) {
    // A table whose columns are all unnamed has no header worth a row of the
    // window — a plugin that sent rows and nothing else meant a plain list.
    if (columns.every((column) => column.label.isEmpty)) {
      return const SizedBox.shrink();
    }

    // The header's own ink: this row is drawn on the header's fill, and the
    // panel's ink was the wrong one for it — the same mistake the listing's own
    // column headings had before item 24, and reported here of the git tool.
    final style = TextStyle(
      color: theme.headerForeground.withValues(alpha: 0.7),
      fontSize: theme.fontSize - 1,
      fontWeight: theme.strongFontWeight.weight,
      decoration: TextDecoration.none,
    );

    return Container(
      height: theme.chromeRowHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: _PluginTableState._padding,
      ),
      decoration: BoxDecoration(
        color: theme.effectiveHeaderBackground,
        border: Border(
          bottom: BorderSide(
            color: theme.headerForeground.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++) ...[
            if (i > 0) const SizedBox(width: _PluginTableState._gap),
            SizedBox(
              width: widths[i],
              child: Text(
                columns[i].label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: _textAlign(columns[i].align),
                style: style,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

TextAlign _textAlign(ListingAlign align) => switch (align) {
  ListingAlign.start => TextAlign.left,
  ListingAlign.end => TextAlign.right,
  ListingAlign.centre => TextAlign.center,
};

class _Row extends StatelessWidget {
  const _Row({
    required this.row,
    required this.columns,
    required this.widths,
    required this.lanes,
    required this.isMarked,
    required this.height,
    required this.theme,
    required this.isCursor,
    required this.isActive,
    required this.lively,
    required this.leaning,
    required this.cursorMoving,
    required this.paintCursorFill,
    required this.striped,
    required this.onTap,
    required this.onMenu,
  });

  final ListingRow row;
  final List<ListingColumn> columns;
  final List<double> widths;

  /// How many lanes the graph column holds, the widest row's. The braid of
  /// every row is drawn to one scale or the lines would not meet across rows.
  final int lanes;

  /// Whether this row is picked out. Drawn in the palette's own marked colour,
  /// which is the colour it has meant in the panels since before any of this.
  final bool isMarked;

  /// The row's own height, which the braid needs and text does not: a picture
  /// that spans the row has to be told how tall the row is, and a line of text
  /// is as tall as it is.
  final double height;

  final AppearanceSettings theme;
  final bool isCursor;
  final bool isActive;

  /// Whether the rows answer the pointer at all. With it false no row builds
  /// a `MouseRegion` and no row holds a ticker — a row is the row it was
  /// before any of this existed.
  final bool lively;

  /// Which column leans, or -1 for none. The one the row is about.
  final int leaning;

  /// How far this row is into being the cursor, or null when the mark is not
  /// moving. The *mark's* own progress, so the lean and the slide are one
  /// movement rather than two timings that disagree.
  final Animation<double>? cursorMoving;

  /// Whether this row paints the cursor's fill itself. False while the mark
  /// slides underneath, or there would be two cursors and one of them still.
  final bool paintCursorFill;

  final bool striped;
  final VoidCallback onTap;

  /// Where the press landed, in the window's own coordinates.
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) {
    final moving = cursorMoving;
    final plain = _roleColour();
    // The mark is on its way onto this row or off it, so the text is on its
    // way too — at the same rate, off the same curve.
    final colour = !(isActive && theme.invertCursorText)
        ? plain
        : moving == null
        ? (isCursor ? theme.cursorForeground : plain)
        : Color.lerp(plain, theme.cursorForeground, moving.value)!;

    // How far this row is into being read *on* the cursor rather than on the
    // panel. The text has always answered it; a chip is text with a box round
    // it, and a box in the palette's own accent sitting on a cursor in the
    // palette's own accent is a chip nobody can see — which is what a dark
    // theme showed first.
    final inverted = !(isActive && theme.invertCursorText)
        ? 0.0
        : moving == null
        ? (isCursor ? 1.0 : 0.0)
        : moving.value;

    // Picked out is a *fill*, not a colour of writing. A marked row that
    // differed only in the colour of its text was a difference nobody saw
    // across a column of file names, and what is about to happen to ten files
    // has to be visible at a glance.
    final background = isCursor && paintCursorFill
        ? theme.cursorColor.withValues(alpha: isActive ? 1.0 : 0.35)
        : isMarked
        ? theme.markedColor.withValues(alpha: 0.22)
        : striped
        ? theme.alternateRowColor
        : Colors.transparent;

    // What a chip is actually sitting on, which decides what can be read on
    // it: the cursor's own fill where the cursor is, the stripe where the row
    // is striped, and the panel underneath either.
    final backdrop = background.a == 0
        ? theme.panelBackground
        : Color.alphaBlend(background, theme.panelBackground);

    final style = TextStyle(
      color: colour,
      fontSize: theme.fontSize,
      fontFamily: theme.fileFamily,
      fontWeight: _roleWeight().weight,
      decoration: TextDecoration.none,
    );

    Widget body(double lean, double scale) => Container(
      color: background,
      padding: const EdgeInsets.symmetric(
        horizontal: _PluginTableState._padding,
      ),
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++) ...[
            if (i > 0)
              SizedBox(
                width: _PluginTableState._gap,
                // The setting has existed since the appearance tab was built
                // and nothing has ever drawn it. A table of columns is where
                // a grid line is worth having, so this is where it lands.
                child: theme.showGridLines && !isCursor
                    ? Center(
                        child: SizedBox(
                          width: 1,
                          child: ColoredBox(
                            color: theme.panelForeground.withValues(
                              alpha: 0.12,
                            ),
                          ),
                        ),
                      )
                    : null,
              ),
            SizedBox(
              width: widths[i],
              child: i != leaning
                  ? _Cell(
                      cell: row.cellAt(i),
                      column: columns[i],
                      graph: row.graph,
                      lanes: lanes,
                      height: height,
                      onCursor: isCursor && isActive,
                      theme: theme,
                      style: style,
                      colour: colour,
                      inverted: inverted,
                      backdrop: backdrop,
                    )
                  // The one column that answers: the lean is taken out of its
                  // own width, and the scale is painted rather than laid out,
                  // so neither can push the columns beside it along.
                  //
                  // Painted rather than laid out is exactly why it has to be
                  // clipped: a subject long enough to fill its column paints
                  // over the author's when it grows, and a column that lends
                  // its room to the one beside it for a fifth of a second is
                  // not a column.
                  : ClipRect(
                      child: Padding(
                        padding: EdgeInsets.only(left: lean),
                        child: Transform.scale(
                          scale: scale,
                          alignment: Alignment.centerLeft,
                          child: _Cell(
                            cell: row.cellAt(i),
                            column: columns[i],
                            graph: row.graph,
                            lanes: lanes,
                            height: height,
                            onCursor: isCursor && isActive,
                            theme: theme,
                            style: style,
                            colour: colour,
                            inverted: inverted,
                            backdrop: backdrop,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ],
      ),
    );

    Widget content = lively && leaning >= 0
        ? LivelyRow(
            theme: theme,
            isCursor: isCursor,
            cursorMoving: cursorMoving,
            builder: body,
          )
        : body(0, 1);

    content = GestureDetector(onTap: onTap, child: content);
    if (onMenu != null) {
      content = PressAndHold(
        onMenu: onMenu!,
        behavior: HitTestBehavior.opaque,
        child: content,
      );
    }
    return content;
  }

  Color _roleColour() {
    // Picked out beats what the row *is*: a marked row is about what is going
    // to happen to it, and that is the more recent fact.
    if (isMarked) return theme.markedColor;
    return switch (row.role) {
      ListingRowRole.accent => theme.accentColor,
      ListingRowRole.dim => theme.panelForeground.withValues(alpha: 0.5),
      // A fifth lighter. Enough to say "not written down yet" and not so
      // much that it reads as unavailable.
      ListingRowRole.pending => theme.panelForeground.withValues(alpha: 0.8),
      _ => theme.panelForeground,
    };
  }

  FontWeightSpec _roleWeight() => switch (row.role) {
    ListingRowRole.strong => theme.strongFontWeight,
    _ => theme.fileFontWeight,
  };
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.cell,
    required this.column,
    required this.graph,
    required this.lanes,
    required this.height,
    required this.onCursor,
    required this.theme,
    required this.style,
    required this.colour,
    this.inverted = 0.0,
    this.backdrop = const Color(0xFF0B2A5B),
  });

  final ListingCell cell;
  final ListingColumn column;

  /// The row's braid, for the one column that draws it.
  final ListingGraph? graph;

  /// How many lanes the column holds; the braid's scale comes off it.
  final int lanes;

  final double height;
  final bool onCursor;
  final AppearanceSettings theme;
  final TextStyle style;
  final Color colour;

  /// How far this row is into being drawn on the cursor rather than on the
  /// panel, with the setting that inverts the text on. 0 on every row that is
  /// not the cursor, and on every row at all when the setting is off.
  final double inverted;

  /// What this row is drawn on, the cursor's fill included. A chip is opaque
  /// enough to need it: what can be read on a chip depends on what the chip
  /// itself is standing on.
  final Color backdrop;

  @override
  Widget build(BuildContext context) {
    if (column.kind == ListingCellKind.graph) {
      final braid = graph;
      if (braid == null || braid.isEmpty) return const SizedBox.shrink();
      return SizedBox(
        height: height,
        child: CommitGraph(
          graph: braid,
          theme: theme,
          onCursor: onCursor,
          lanes: lanes,
        ),
      );
    }

    if (column.kind == ListingCellKind.avatar) {
      if (cell.text.isEmpty) return const SizedBox.shrink();
      return Row(
        children: [
          _Face(
            name: cell.text,
            email: cell.email,
            theme: theme,
            onCursor: onCursor,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              cell.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      );
    }

    if (column.kind == ListingCellKind.icon) {
      if (cell.icon == null && cell.text.isEmpty) {
        return const SizedBox.shrink();
      }
      return cell.icon != null
          ? Hint(
              // The word the mark stands for, for anybody who has not learnt
              // the marks yet. A glyph that cannot be asked what it means is a
              // glyph that has to be guessed at.
              message: cell.text.isEmpty ? cell.icon! : cell.text,
              wait: const Duration(milliseconds: 600),
              child: Icon(
                pluginIcon(cell.icon),
                size: theme.fontSize + 2,
                color: onCursor
                    ? colour
                    : pluginIconColour(
                            cell.icon,
                            DiffColours.of(theme),
                            colour,
                          ) ??
                          colour,
              ),
            )
          : Text(
              cell.text,
              textAlign: TextAlign.center,
              maxLines: 1,
              style: style,
            );
    }

    // A path written short: the first folder, an ellipsis, the name. Wrapped
    // in a hint carrying the whole of it — see [ListingCellKind.path] and
    // [shortPath].
    if (column.kind == ListingCellKind.path && cell.text.isNotEmpty) {
      return LayoutBuilder(
        builder: (context, room) {
          final whole = cell.text;
          final short = shortPath(whole, style, room.maxWidth);
          final drawn = Text(
            short,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: _textAlign(column.align),
            style: style,
          );
          return short == whole
              ? drawn
              : Hint(message: whole, child: drawn);
        },
      );
    }

    final text = cell.text.isEmpty && cell.chips.isEmpty
        ? null
        : Text(
            cell.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: _textAlign(column.align),
            style: column.kind == ListingCellKind.mono
                ? style.copyWith(fontFamily: 'monospace')
                : style,
          );

    if (cell.chips.isEmpty) return text ?? const SizedBox.shrink();

    // A commit can be the tip of five branches at once, and five pills at
    // their natural width are wider than any column they will ever be in. They
    // lie on top of each other instead — see [_ChipStack].
    return _ChipStack(
      chips: cell.chips,
      theme: theme,
      inverted: inverted,
      backdrop: backdrop,
      onCursor: onCursor,
      height: height,
      text: text,
    );
  }
}

/// The chips of one row, stacked, and fanned out when they are being looked at.
///
/// They lie in a stack, one on the next with a step of 30px, and fan out over
/// the text under the pointer — and on the row picked out, but only while that
/// selection is the live one; working in another list, they gather back into
/// the stack.
///
/// Two things follow from that and neither is decoration. **Stacked, a row
/// costs the same width whatever it is the tip of** — the column stops being
/// hostage to whichever commit five branches happen to point at. And **fanned
/// out they cover the subject rather than pushing it**: the text is where it
/// was a moment ago, so nothing under the pointer moves as they open.
///
/// The cursor opens them only while the list holds the keyboard. A row picked
/// out in a list nobody is working in is not the row being read, and five open
/// pills over a subject nobody asked about is noise.
class _ChipStack extends StatefulWidget {
  const _ChipStack({
    required this.chips,
    required this.theme,
    required this.inverted,
    required this.backdrop,
    required this.onCursor,
    required this.height,
    required this.text,
  });

  final List<ListingChip> chips;
  final AppearanceSettings theme;
  final double inverted;
  final Color backdrop;

  /// Whether this row is the cursor's *and* the list has the keyboard.
  final bool onCursor;

  /// The row's own height. **Given rather than found:** everything in the
  /// stack is positioned, so the stack has nothing to take a height from, and
  /// a strip no pixels tall is a strip the pointer never enters.
  final double height;

  final Widget? text;

  @override
  State<_ChipStack> createState() => _ChipStackState();
}

class _ChipStackState extends State<_ChipStack> {
  bool _hovered = false;

  /// The fan drawn *outside* the row, for when it will not fit inside it.
  ///
  /// **A fan under the pointer may spread anywhere, vertically included, and
  /// that is what needed an overlay.** A row
  /// is one line tall and clips what leaves it, so five branches on a narrow
  /// column fanned into a strip that was cut off at the column's edge: the
  /// chips furthest along, which are the ones somebody is hovering to read,
  /// were the ones that disappeared. Wrapped into rows over the listing, every
  /// one of them is there.
  ///
  /// Only when it is needed. A fan that fits stays in the row, where it costs
  /// no overlay and cannot be somewhere the row is not.
  OverlayEntry? _fanned;

  @override
  void dispose() {
    _takeFan();
    super.dispose();
  }

  void _giveFan(List<double> widths, double room) {
    if (_fanned != null || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (box == null || !box.hasSize || overlay == null) return;

    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final entry = OverlayEntry(
      builder: (context) => _FannedChips(
        chips: widget.chips,
        widths: widths,
        room: room,
        anchor: anchor,
        height: widget.height,
        theme: widget.theme,
        inverted: widget.inverted,
        backdrop: widget.backdrop,
      ),
    );
    overlay.insert(entry);
    _fanned = entry;
  }

  void _takeFan() {
    _fanned?.remove();
    _fanned = null;
  }

  /// How wide one chip wants to be: its label, plus the room the pill takes
  /// either side of it.
  ///
  /// Measured rather than laid out, because the positions have to be known
  /// before anything is placed — a stack has no row to ask.
  double _widthOf(BuildContext context, ListingChip chip, TextStyle label) =>
      _Chip.roomFor(context, chip.text, label);

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final label = TextStyle(
      fontSize: theme.fontSize - 2,
      fontWeight: theme.strongFontWeight.weight,
    );
    return LayoutBuilder(
      builder: (context, room) => _stack(context, label, room.maxWidth),
    );
  }

  /// How far apart to lay the stack so the chip on top is whole.
  ///
  /// [kChipStackStep] when there is room for it, and as much less as it takes
  /// otherwise — down to [_minimumStep], below which a stack stops reading as
  /// several things at all. Only if even that will not do does the name on top
  /// get cut, and then it is genuinely too long for the column rather than
  /// merely standing too far along.
  static double _stepFor(List<double> widths, double room) {
    if (widths.length < 2 || !room.isFinite) return kChipStackStep;
    final spare = room - widths.last;
    if (spare >= kChipStackStep * (widths.length - 1)) return kChipStackStep;
    final squeezed = spare / (widths.length - 1);
    return squeezed < _minimumStep ? _minimumStep : squeezed;
  }

  /// Enough of a chip to see that there is one. Below this a stack of five
  /// reads as a smudge with a pill on it.
  static const double _minimumStep = 8;

  Widget _stack(BuildContext context, TextStyle label, double room) {
    final theme = widget.theme;
    // **Never wider than the room there is.** A branch name longer than its
    // own column has to be cut somewhere, and inside its pill is where it can
    // still be asked what it says — the hint in [_Chip] fires on exactly that.
    final ceiling = room.isFinite ? room : double.maxFinite;
    final widths = [
      for (final chip in widget.chips)
        _widthOf(context, chip, label) < ceiling
            ? _widthOf(context, chip, label)
            : ceiling,
    ];

    // **The step gives way before the name does.** They are to be shown whole
    // wherever they fit — the stack exists so that nothing has to be cut — and
    // the stack was doing the opposite. Each
    // chip was placed a fixed 30px further along and then clipped at the edge
    // of the cell, so the one on top — the only one you can read at all —
    // lost exactly as much of itself as the stack was deep. Squeezing the step
    // costs a sliver of the chips underneath, which are there to say *how
    // many*; cutting the top one costs the name, which is the whole point.
    final step = _stepFor(widths, room);

    // Where each one sits, stacked and fanned out. The last is whole in both:
    // stacked, it is the one on top; fanned out, it is the one at the end.
    final stacked = <double>[];
    final opened = <double>[];
    var at = 0.0;
    for (var i = 0; i < widths.length; i++) {
      stacked.add(i * step);
      opened.add(at);
      at += widths[i] + 4;
    }
    final stackedWidth = widths.isEmpty ? 0.0 : stacked.last + widths.last;
    final openedWidth = at == 0 ? 0.0 : at - 4;

    final open = _hovered || widget.onCursor;

    // **Out of the row only where the row cannot hold it.** Decided here, where
    // the widths and the room are already known, and acted on after the frame:
    // an overlay inserted during a build is a build inside a build.
    final overflows = open && _hovered && openedWidth > room && room.isFinite;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (overflows) {
        _giveFan(widths, room);
      } else {
        _takeFan();
      }
    });

    return SizedBox(
      height: widget.height,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) {
          _takeFan();
          setState(() => _hovered = false);
        },
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: open ? 1 : 0),
          duration: motionOf(context, kChipSpreadDuration),
          curve: open ? kArrivingCurve : kLeavingCurve,
          builder: (context, spread, _) => ClipRect(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Under them, and it does not move: the pills open *over* the
                // subject, so the line being read stays where the eye left it.
                if (widget.text != null)
                  Positioned.fill(
                    left: stackedWidth + 6,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: widget.text,
                    ),
                  ),
                // **While the fan is out of the row, the row draws none of
                // them.** It used to draw the stack underneath, which is one
                // chip drawn twice — the overlay's first line lies exactly
                // over the row, so an orange pill came out with a second
                // orange pill half behind it and a name nobody could read.
                // Measured: every chip was found twice.
                if (!overflows)
                  for (var i = 0; i < widget.chips.length; i++)
                    Positioned(
                      left: stacked[i] + (opened[i] - stacked[i]) * spread,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: SizedBox(
                          width: widths[i],
                          child: _Chip(
                            chip: widget.chips[i],
                            theme: theme,
                            inverted: widget.inverted,
                            backdrop: widget.backdrop,
                          ),
                        ),
                      ),
                    ),
                // Nothing to see, and something to measure: the stack is as wide
                // as it has grown, so the row gives it that much and no more.
                SizedBox(
                  width: overflows
                      ? stackedWidth
                      : stackedWidth + (openedWidth - stackedWidth) * spread,
                  height: widget.height,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The chips of one row, fanned out over the listing because the row is too
/// narrow to hold them side by side.
///
/// **Wrapped into rows rather than run off the edge.** The rule the fan inside
/// the row keeps — the last one whole, the rest opening out from under it —
/// stops meaning anything once the strip is wider than the column: what it
/// produces then is the first two chips and a cut. So out here they wrap, as
/// many to a line as the column holds, and the block grows *downwards* from
/// the row, because a fan under the pointer is allowed to spread anywhere.
///
/// Its own widget so it can arrive rather than appear: an overlay entry is
/// built once and cannot start an animation by existing. The same reason
/// [Hint]'s bubble is one.
class _FannedChips extends StatefulWidget {
  const _FannedChips({
    required this.chips,
    required this.widths,
    required this.room,
    required this.anchor,
    required this.height,
    required this.theme,
    required this.inverted,
    required this.backdrop,
  });

  final List<ListingChip> chips;
  final List<double> widths;

  /// How wide the column is, which is how wide a line of the fan may be.
  final double room;

  /// Where the stack sits on the screen, so the fan opens from it.
  final Rect anchor;

  final double height;
  final AppearanceSettings theme;
  final double inverted;
  final Color backdrop;

  @override
  State<_FannedChips> createState() => _FannedChipsState();
}

class _FannedChipsState extends State<_FannedChips>
    with SingleTickerProviderStateMixin {
  late final AnimationController _arrive = AnimationController(
    vsync: this,
    duration: motionOf(context, kChipSpreadDuration),
  )..forward();

  @override
  void dispose() {
    _arrive.dispose();
    super.dispose();
  }

  /// The chips in lines, each line as full as the column allows.
  List<List<int>> get _lines {
    final lines = <List<int>>[];
    var line = <int>[];
    var used = 0.0;
    for (var i = 0; i < widget.chips.length; i++) {
      final width = widget.widths[i] + 4;
      if (line.isNotEmpty && used + width > widget.room) {
        lines.add(line);
        line = <int>[];
        used = 0;
      }
      line.add(i);
      used += width;
    }
    if (line.isNotEmpty) lines.add(line);
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final tall = lines.length * widget.height;
    // Downwards from the row unless there is no room below, and then upwards:
    // a fan that opened off the bottom of the window would be a fan nobody can
    // read, which is the thing this exists to stop.
    final below = MediaQuery.sizeOf(context).height - widget.anchor.bottom;
    final top = below >= tall
        ? widget.anchor.top
        : widget.anchor.bottom - tall;

    return Positioned(
      left: widget.anchor.left,
      top: top,
      width: widget.room,
      height: tall,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _arrive,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final line in lines)
                SizedBox(
                  height: widget.height,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final i in line) ...[
                        SizedBox(
                          width: widget.widths[i],
                          child: _Chip(
                            chip: widget.chips[i],
                            theme: widget.theme,
                            inverted: widget.inverted,
                            backdrop: widget.backdrop,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Whoever did it, as a ring with their initials in it.
///
/// **Not a photograph.** A face lives on a server, and a log that opened a
/// connection because it drew a row would be a log that hangs on a repository
/// you walked past — the rule the whole git tool is built on. Initials are
/// what the repository already knows, and two letters are enough to tell one
/// regular contributor from another down a column.
/// One letter from each of the first two words, or the first two letters of a
/// single one. `xsm909` gives `XS`; `Sergey Smirnov` gives `SS`.
///
/// Its own name because it is a decision — where the letters come from — and a
/// decision nothing can check is a decision that drifts.
String initialsOf(String name) {
  final words = name
      .split(RegExp(r'[\s._-]+'))
      .where((word) => word.isNotEmpty)
      .toList();
  if (words.isEmpty) return '';
  if (words.length == 1) {
    final word = words.first;
    return (word.length == 1 ? word : word.substring(0, 2)).toUpperCase();
  }
  return (words[0][0] + words[1][0]).toUpperCase();
}

class _Face extends StatefulWidget {
  const _Face({
    required this.name,
    required this.email,
    required this.theme,
    required this.onCursor,
  });

  final String name;

  /// Given only when the plugin's user has asked for pictures. Without it
  /// nothing leaves the machine and the ring carries the initials.
  final String? email;

  final AppearanceSettings theme;
  final bool onCursor;

  @override
  State<_Face> createState() => _FaceState();
}

class _FaceState extends State<_Face> {
  StreamSubscription<void>? _listening;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(_Face old) {
    super.didUpdateWidget(old);
    if (old.email != widget.email) _ask();
  }

  @override
  void dispose() {
    _listening?.cancel();
    super.dispose();
  }

  /// Asks for the picture, and listens for it. **Nothing waits**: the ring is
  /// drawn this frame with the initials in it, and swapped for a face if one
  /// ever arrives.
  void _ask() {
    final email = widget.email;
    if (email == null || email.isEmpty) return;
    if (AvatarStore.instance.cached(email) != null) return;

    AvatarStore.instance.want(email);
    _listening ??= AvatarStore.instance.changed.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final size = theme.fontSize + 6;
    final ink = widget.onCursor
        ? theme.cursorForeground
        : theme.panelForeground;
    final email = widget.email;
    final face = email == null || email.isEmpty
        ? null
        : AvatarStore.instance.cached(email);

    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // The ring is the accent, and the cursor's own ink where it lies on
          // the cursor: an accent ring on the accent fill is a ring nobody
          // can see. It stays around a picture too, so a column of these reads
          // as one thing whether or not the people in it have faces.
          border: Border.all(
            color: widget.onCursor ? ink : theme.accentColor,
            width: 1.2,
          ),
        ),
        child: ClipOval(
          child: face != null
              ? Image.file(
                  face,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  filterQuality: pictureSmoothing,
                  errorBuilder: (context, _, _) => _initials(theme, ink),
                )
              : _initials(theme, ink),
        ),
      ),
    );
  }

  Widget _initials(AppearanceSettings theme, Color ink) => Center(
    child: Text(
      initialsOf(widget.name),
      maxLines: 1,
      style: TextStyle(
        color: ink,
        fontSize: theme.fontSize - 4,
        fontWeight: theme.strongFontWeight.weight,
        decoration: TextDecoration.none,
        height: 1,
      ),
    ),
  );
}

/// The ink a small bold word can be read in on [fill].
///
/// Public because the node canvas asks the same question of a node's own fill,
/// and two answers to "what can be read on this" is one of them being wrong.
///
/// Worked out rather than declared, and worked out **from the palette**: the
/// panel's own two colours are tried first and the one further from the fill
/// wins, because a chip belongs to the panel and ought to be written in the
/// panel's colours. Nothing here knows what a branch is or which way round the
/// theme is — repaint either and the answer changes with it.
Color legibleOn(Color fill, AppearanceSettings theme) {
  final dark = fill.computeLuminance() <= 0.45;
  final foreground = theme.panelForeground;
  final background = theme.panelBackground;

  double against(Color ink) {
    final one = ink.computeLuminance();
    final other = fill.computeLuminance();
    final lighter = one > other ? one : other;
    final darker = one > other ? other : one;
    return (lighter + 0.05) / (darker + 0.05);
  }

  final own = against(foreground) >= against(background)
      ? foreground
      : background;
  // 4.5:1 is the ratio small text is held to. Anything above it reads.
  if (against(own) >= 4.5) return own;

  // Neither of them reads on this fill — a mid-grey panel, or a chip in a
  // colour close to both. Keep the palette's own hue and take its lightness to
  // the end the fill leaves free: light writing on a dark pill, dark on a
  // light one, and never a colour from outside the theme.
  return HSLColor.fromColor(own).withLightness(dark ? 0.94 : 0.12).toColor();
}

/// A branch, a tag, or whatever else labels a row rather than fills it.
///
/// The colours come out of the palette rather than out of the plugin. A chip
/// says what it *is* — `head`, `branch`, `remote`, `tag` — and the four shelves
/// of the palette answer for how that looks, which is the rule every colour in
/// this application follows.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.chip,
    required this.theme,
    required this.backdrop,
    this.inverted = 0.0,
  });

  final ListingChip chip;
  final AppearanceSettings theme;

  /// How far the row under it has gone over to the cursor's own ink — see
  /// `_Cell.inverted`. A chip goes with it: the row said the text under the
  /// cursor is read in one colour, and a chip is text.
  final double inverted;

  /// What the row it is on is drawn on — see `_Cell.backdrop`.
  final Color backdrop;

  @override
  Widget build(BuildContext context) {
    // **Every one of them opaque.**
    // `remote` had no case of its own and fell through to a fill at 0.6 — and
    // `origin/…` is the commonest chip in any log, so most of them showed the
    // row through themselves, which is worst exactly where they are meant to
    // be read: fanned out over the subject.
    final own = switch (chip.kind) {
      'head' => theme.accentColor,
      'branch' => theme.directoryColor,
      'tag' => theme.markedColor,
      // A remote ref is a branch somebody else is on. The interface's own ink,
      // at full strength, so it reads as a name rather than as one of the
      // three that mean something.
      _ => theme.panelForeground,
    };

    final fill = Color.lerp(own, theme.cursorForeground, inverted)!;

    // And the name on it in whichever ink can be read there — worked out, not
    // declared, because the pill is a palette colour, the thing under it is
    // another, and no rule written by hand survives a user repainting either.
    // The colour it is *seen* as is what decides: a chip at less than full
    // alpha shows the row through itself, cursor and all.
    final on = legibleOn(Color.alphaBlend(fill, backdrop), theme);

    final label = TextStyle(
      color: on,
      fontSize: theme.fontSize - 2,
      fontWeight: theme.strongFontWeight.weight,
      decoration: TextDecoration.none,
    );

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: side, vertical: 1),
      decoration: ShapeDecoration(
        color: fill,
        // A pill, like the branch in the path bar above it: two things that
        // both name a branch and are shaped differently are two things.
        //
        // **With an edge round it**, or two chips of a colour run together —
        // and it is the price
        // of making them opaque rather than a defect of its own. Two `remote`
        // pills of the same ink, lying eight pixels apart in a stack, have
        // nothing to say where one ends; the translucent fills used to leave a
        // darker band by accident, and that seam went with the transparency.
        //
        // The row's own backdrop is the honest colour for it: the edge exists
        // to say *the row shows through here*, and that stays true whatever the
        // user repaints. Which also means it is invisible on a chip standing
        // alone, where there is nothing to tell apart — the line appears
        // exactly where two of them meet.
        //
        // Drawn always rather than only where they overlap: the same edge
        // either way, cheaper than working out who covers whom, and it cannot
        // fall out of step with the positions. Inside the pill, so nothing
        // moves by two pixels for having one.
        shape: StadiumBorder(
          side: BorderSide(color: backdrop, width: edge),
        ),
      ),
      child: Text(
        chip.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: label,
      ),
    );

    // A branch name is longer than the room a log has for it, so most of these
    // are cut — and a cut name is a name the reader cannot check. The mouse
    // asks for the rest of it, and only where there *is* a rest: a tooltip on
    // a chip that is already whole says nothing and covers the row below.
    return LayoutBuilder(
      builder: (context, room) => _fits(context, label, room.maxWidth)
          ? pill
          : Hint(
              message: chip.text,
              wait: const Duration(milliseconds: 600),
              child: pill,
            ),
    );
  }

  /// What the pill takes either side of the name — asked of the same constant
  /// the padding is made from, so the measurement cannot drift from the shape.
  static const double side = 7;

  /// The line round the pill, in logical pixels.
  ///
  /// **It is not decoration as far as the arithmetic goes.** A `ShapeDecoration`
  /// insets its child by the border's width, so a pill measured at exactly the
  /// text plus its padding hands the text two pixels less than it needs — and
  /// `TextOverflow.ellipsis` then cuts *every* name, `main` included, which is
  /// the opposite of what the stack was built for. Counted here and counted in
  /// [_ChipStackState._widthOf], which is the only place the two can agree.
  static const double edge = 1;

  /// The room one pill needs to show [text] whole: the text, the padding
  /// either side of it, and the line round the outside.
  ///
  /// **Measured with the style the text will actually be drawn in**, which is
  /// not the one handed in. A `Text` merges its style with whatever
  /// `DefaultTextStyle` is in force, so a bare `TextStyle` laid out on its own
  /// is a different font from the one that reaches the screen — and a pill
  /// measured that way is a pill the name does not fit. Every chip came out
  /// ellipsised, `main` included, which is the opposite of what a stack is for.
  static double roomFor(BuildContext context, String text, TextStyle label) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(label)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    // **And a pixel of slack.** Laying out at exactly the width the painter
    // reported still truncates: the paragraph and the box agree to the tenth
    // and the ellipsis fires anyway. A pixel costs nothing and is the
    // difference between a whole name and `m…`.
    return width + side * 2 + edge * 2 + slack;
  }

  /// See [roomFor].
  static const double slack = 1;

  /// Whether the whole name is on screen at [room] wide.
  bool _fits(BuildContext context, TextStyle label, double room) {
    if (!room.isFinite) return true;
    final painter = TextPainter(
      text: TextSpan(text: chip.text, style: label),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + side * 2 + edge * 2 + slack <= room;
  }
}


/// A path cut to fit [room], as `<first folder>…<name>`.
///
/// Only as much as it has to be: a path that fits is left alone, and one that
/// does not loses its middle rather than its end — the name is the half
/// anybody is looking for, and an ordinary ellipsis throws exactly that away.
/// When even the two ends will not fit, the name alone is what survives.
String shortPath(String whole, TextStyle style, double room) {
  if (room.isInfinite || _widthOf(whole, style) <= room) return whole;

  // Whichever separator this path is written with — a plugin on Windows says
  // one thing and git says the other, and both turn up in the same list.
  final cut = whole.contains('/') ? '/' : r'\';
  final parts = whole.split(cut).where((part) => part.isNotEmpty).toList();
  if (parts.length < 2) return whole;

  final name = parts.last;
  final first = parts.first;
  final both = '$first$cut…$cut$name';
  if (_widthOf(both, style) <= room) return both;

  final ending = '…$cut$name';
  return _widthOf(ending, style) <= room ? ending : name;
}

double _widthOf(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter.width;
}
