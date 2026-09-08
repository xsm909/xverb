import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/settings/appearance_settings.dart';
import '../plugins/plugin_table.dart' show appearanceOf;
import '../widgets/keyboard_scrollable.dart';
import '../motion.dart';
import 'find_box.dart';
import 'markdown_view.dart' show splitLines;
import 'reading_link.dart';
import 'text_find.dart';
import 'pinned_surface.dart';
import 'sticky_lines.dart';
import '../../core/plugins/grammar.dart';

/// A file drawn as text, with somewhere to search it.
///
/// Everything a viewer shows as text comes through here — plain, coloured by a
/// grammar, formatted JSON, a diff — because the search has to work on all of
/// them or it is a search you have to think about first. What it is coloured
/// as arrives already built, as [spans]; this puts a mark through them.
///
/// **The box floats over the reading, and Escape puts it away.** The same
/// shape quick search has in a panel, for the same reason: a bar that pushes
/// the text down moves the line somebody was reading, and a search is a thing
/// you do *to* what is on screen.
class ReadableText extends StatefulWidget {
  const ReadableText({
    super.key,
    required this.body,
    required this.spans,
    required this.style,
    required this.hasKeyboard,
    this.truncated = false,
    this.grammar,
    this.language,
    this.link,
  });

  /// The characters, for the search to look through. Exactly what [spans]
  /// draws, or a match would land in the wrong place.
  final String body;

  /// How it is coloured. A function rather than a value, because the marks are
  /// laid over it and it is rebuilt as they move.
  final TextSpan Function() spans;

  final TextStyle style;

  /// Whether this is the thing being worked in. A preview beside the panel
  /// being typed in answers no keys at all.
  final bool hasKeyboard;

  /// Whether the file was cut short at the viewer's byte limit — said out loud
  /// in the search box, because a search that quietly covers the first two
  /// megabytes of nine is a search that lies.
  final bool truncated;

  /// What the file is written in, where anything has declared it.
  ///
  /// Two things come out of it, and neither is the colouring — that arrives
  /// already built as [spans]. It says which lines hold up the ones below them
  /// (item 70b): the roles it calls sticky, and its own existence, which is
  /// what says this is code and can be held up by its indentation. Null is the
  /// ordinary case and means no strip at all.
  final SyntaxGrammar? grammar;

  /// What the content said it was, where it said anything. Only one reading
  /// uses it: a **diff** has no grammar and is held up by its own file and
  /// hunk headers instead.
  final String? language;

  /// The line to whatever is standing beside the reading — the structure
  /// panel. It is told which line is at the top as the reader scrolls, and it
  /// asks for a line to be brought into view. Null wherever nothing is
  /// standing there, which is most places this is drawn.
  final ReadingLink? link;

  @override
  State<ReadableText> createState() => _ReadableTextState();
}

class _ReadableTextState extends State<ReadableText> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _box = FocusNode(debugLabel: 'find in text');
  final ScrollController _scroll = ScrollController();
  final ScrollController _across = ScrollController();

  /// The coloured text, cut into one span per line, and built **once**.
  ///
  /// **This is what stopped the reading being one paragraph.** Eight megabytes
  /// of text — the largest a viewer will read — is about eighty-five thousand
  /// lines, and handing all of it to a single `Text.rich` laid the whole file
  /// out before anything appeared: measured on 1.0.0.385, a 227 MB log froze
  /// the window for **3193 ms**, and a `TextPainter` given the same string in a
  /// test had not finished after ten minutes. The reading is now a list, so
  /// only the lines on screen are laid out at all.
  List<TextSpan> _spans = const [];

  /// Which file line each row belongs to, where each row starts in the file,
  /// and how many characters it holds. A row is a *screen* line: an ordinary
  /// file line is one row, and a very long one is carried over several.
  List<int> _rowLine = const [];
  List<int> _rowStart = const [];
  List<int> _rowLength = const [];

  /// The first row of each file line, for going to one.
  List<int> _lineFirstRow = const [];

  /// How tall one line is, and how wide the longest one is.
  ///
  /// Both measured once, and both are what let the list be exact rather than
  /// approximate: with one row per line and every row the same height, the line
  /// at the top of the viewport is a division, and the line a match is on is a
  /// multiplication. The paragraph had to be *asked* both questions, and could
  /// only answer once it had laid the whole file out.
  double _lineHeight = 0;
  double _widest = 0;

  bool _open = false;
  List<(int, int)> _matches = const [];
  int _current = 0;

  /// The file by lines, and where each one starts in it. Kept because the
  /// sticky strip asks both questions on every scroll, and splitting a
  /// megabyte per frame is not an answer.
  late List<String> _lines = splitLines(widget.body);
  late List<int> _lineStarts = _startsOf(_lines);

  /// The lines standing over what is on screen, outermost first.
  List<StickyLine> _sticky = const [];

  /// What holds a line up here, worked out from the grammar.
  StickyPlan get _plan {
    final language = widget.language?.toLowerCase();
    if (language == 'diff' || language == 'patch') return StickyPlan.diff;
    final grammar = widget.grammar;
    return grammar == null || grammar.isEmpty
        ? StickyPlan.none
        : StickyPlan.of(grammar);
  }

  /// The role of the first word of every line, read once and kept.
  ///
  /// Only asked for by a grammar that declares sticky roles — the indentation
  /// half needs no scanner at all, and a file nobody asked a question about
  /// should not pay for one.
  List<CodeRole>? _roles;

  List<CodeRole> _rolesOfLines() =>
      _roles ??= rolesOfLines(widget.body, widget.grammar!, _lines.length);

  static List<int> _startsOf(List<String> lines) {
    final starts = <int>[];
    var at = 0;
    for (final line in lines) {
      starts.add(at);
      at += line.length + 1;
    }
    return starts;
  }

  @override
  void initState() {
    super.initState();
    _cut(widget.spans());
    _attach(widget.link);
  }

  /// Answers the panel's "take me there".
  void _attach(ReadingLink? link) {
    link?.reveal = _goTo;
    if (link == null) return;
    // Say where the reading starts, once it exists: a panel opened over a file
    // nobody has scrolled yet still has to light up the first thing in it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureSticky();
    });
  }

  @override
  void didUpdateWidget(ReadableText old) {
    super.didUpdateWidget(old);
    if (old.link != widget.link) {
      if (old.link?.reveal == _goTo) old.link!.reveal = null;
      _attach(widget.link);
    }
    // A new file, or the same one read again: what was found was found in the
    // old text and the offsets mean nothing in this one.
    if (old.body != widget.body) {
      _lines = splitLines(widget.body);
      _lineStarts = _startsOf(_lines);
      _roles = null;
      _sticky = const [];
      _cut(widget.spans());
      _measured = false;
      _find(_query.text);
    } else if (old.style != widget.style || old.language != widget.language) {
      // The colouring or the type changed under the same text.
      _cut(widget.spans());
      _measured = false;
    }
  }

  /// Whether [_lineHeight] and [_widest] have been worked out for this text.
  bool _measured = false;

  /// Measures one row's height and how wide the widest one is, once.
  ///
  /// **Nothing long is ever laid out to find out how long it is.** The first
  /// cut measured the longest *line* with a `TextPainter`, which is exactly the
  /// mistake the whole list was built to stop: a minified file is one line of
  /// millions of characters — measured, a 5.5 MB HTML is **seventeen lines** —
  /// and laying that out to learn its width froze the application again.
  ///
  /// A **row**, though, is not a line: [_rowChars] caps one at eight hundred
  /// characters and carries the rest over. So the widest row can be laid out
  /// and measured for what it is, and that is what [widestRow] does — see there
  /// for why the estimate it replaced was wrong in both directions.
  void _measure(BuildContext context) {
    if (_measured) return;
    _measured = true;

    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    final painter = TextPainter(
      text: TextSpan(text: 'Xg', style: widget.style),
      textScaler: scaler,
      textDirection: direction,
      maxLines: 1,
    )..layout();
    _lineHeight = painter.height;
    painter.dispose();

    _widest = widestRow(
      spans: _spans,
      lengths: _rowLength,
      scaler: scaler,
      direction: direction,
    );
  }

  /// The most characters a row may hold before the line goes on to the next
  /// one.
  ///
  /// **Because a file's lines are not always short.** A minified page is one
  /// line of millions of characters — measured, a 5.5 MB HTML is seventeen
  /// lines — and one row holding all of it is the single enormous paragraph
  /// this list was built to stop, in a list. So a long line is carried over
  /// several rows, which reads as wrapping at a very wide column and keeps
  /// every row exactly one line high.
  ///
  /// Wider than any window anybody reads on, so an ordinary file never meets
  /// it and nothing about an ordinary file changes.
  static const int _rowChars = 800;

  /// The coloured text cut into rows, and what each row is.
  ///
  /// The tree arrives already coloured — by a grammar, by the JSON reader, by
  /// the diff reader — and cutting keeps every colour exactly where it was. It
  /// is done once rather than per keystroke: what a search marks is laid over
  /// **the row it is on**, in [_lineSpan], and never over the file.
  void _cut(TextSpan root) {
    final rows = <List<InlineSpan>>[<InlineSpan>[]];
    final rowLine = <int>[0];
    final rowStart = <int>[0];
    final rowLength = <int>[0];

    var line = 0;
    var at = 0;

    void nextRow({required bool newLine}) {
      if (newLine) {
        line++;
        at++; // the newline itself
      }
      rows.add(<InlineSpan>[]);
      rowLine.add(line);
      rowStart.add(at);
      rowLength.add(0);
    }

    void put(String text, TextStyle? style) {
      var from = 0;
      while (from < text.length) {
        final room = _rowChars - rowLength.last;
        if (room <= 0) {
          nextRow(newLine: false);
          continue;
        }
        final take = text.length - from < room ? text.length - from : room;
        rows.last.add(
          TextSpan(text: text.substring(from, from + take), style: style),
        );
        rowLength[rowLength.length - 1] += take;
        from += take;
        at += take;
      }
    }

    void walk(InlineSpan span, TextStyle? inherited) {
      if (span is! TextSpan) {
        rows.last.add(span);
        return;
      }
      final style = span.style == null
          ? inherited
          : (inherited?.merge(span.style) ?? span.style);

      final text = span.text;
      if (text != null && text.isNotEmpty) {
        var start = 0;
        while (true) {
          final hit = text.indexOf('\n', start);
          if (hit < 0) {
            if (start < text.length) put(text.substring(start), style);
            break;
          }
          if (hit > start) put(text.substring(start, hit), style);
          nextRow(newLine: true);
          start = hit + 1;
        }
      }

      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child, style);
      }
    }

    walk(root, null);

    // The root's own style stays *on the row* rather than being pushed into
    // every run of it. It is the style the whole reading is set in — the face,
    // the size, the weight — and a row that carries it is a row that can still
    // be asked what it is drawn in.
    _spans = [
      for (final row in rows) TextSpan(style: root.style, children: row),
    ];
    _rowLine = rowLine;
    _rowStart = rowStart;
    _rowLength = rowLength;

    // Where each *file* line begins among the rows, so a jump to a line is a
    // jump to a row.
    final first = List<int>.filled(_lines.length, 0);
    for (var row = rowLine.length - 1; row >= 0; row--) {
      final which = rowLine[row];
      if (which < first.length) first[which] = row;
    }
    _lineFirstRow = first;
  }

  // --- The strip that stands over the reading ------------------------------

  /// Whether a measurement is already booked for the coming frame.
  ///
  /// The same throttle the markdown reader uses, and for the same reason: a
  /// scroll says where it is *going* before anything has been laid out there,
  /// so measuring as the notification arrives reads the arrangement being
  /// left behind.
  bool _booked = false;

  void _onScroll() {
    if ((_plan.isEmpty && widget.link == null) || _booked) return;
    _booked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _booked = false;
      if (mounted) _measureSticky();
    });
  }

  void _measureSticky() {
    if (!_scroll.hasClients || _lineHeight <= 0) return;

    // Which line of the *file* is at the top of the viewport: which row the
    // scroll offset lands on, and which line that row belongs to. A division
    // and a lookup, where it used to be a question for the paragraph.
    if (_rowLine.isEmpty) return;
    final row = (_scroll.offset / _lineHeight).floor().clamp(
      0,
      _rowLine.length - 1,
    );
    final top = _rowLine[row];
    // The panel beside the reading wants this whether or not anything sticks.
    widget.link?.report(top);
    if (_plan.isEmpty) return;

    final chain = stickyChain(
      _lines,
      top,
      _plan,
      roleOfLine: (line) => _rolesOfLines()[line],
    );
    if (_sameChain(chain, _sticky)) return;
    setState(() => _sticky = chain);
  }

  /// One row, with whatever the search found **on that row** marked in it.
  ///
  /// The marks are laid over a row rather than over the file, which is what
  /// makes typing in the find box cheap: the whole text used to be walked and
  /// rebuilt on every keystroke, and eight megabytes of spans is not something
  /// to build between two letters. Here only the rows on screen are ever
  /// asked, and a row with nothing found on it is handed back untouched.
  TextSpan _lineSpan(int row, {required Color found, required Color here}) {
    final span = _spans[row];
    if (_matches.isEmpty || row >= _rowStart.length) return span;

    final start = _rowStart[row];
    final end = start + _rowLength[row];

    final mine = <(int, int)>[];
    var current = -1;
    for (var i = 0; i < _matches.length; i++) {
      final (at, to) = _matches[i];
      if (to <= start || at >= end) continue;
      if (i == _current) current = mine.length;
      mine.add((at - start, to - start));
    }
    if (mine.isEmpty) return span;

    return markMatches(
      span,
      mine,
      // -1 marks every one of them as *found* and none as *here*, which is the
      // truth on a line the current match is not on.
      current: current,
      found: found,
      here: here,
    );
  }

  /// The row a character offset falls on, by binary search over the starts.
  ///
  /// A row rather than a line, because that is what the list scrolls in: on a
  /// minified file one line is thousands of rows, and scrolling to its first
  /// would be scrolling to the top of the file.
  int _rowAt(int offset) {
    if (_rowStart.isEmpty) return 0;
    var low = 0;
    var high = _rowStart.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_rowStart[middle] <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  static bool _sameChain(List<StickyLine> a, List<StickyLine> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].index != b[i].index) return false;
    }
    return true;
  }

  @override
  void dispose() {
    if (widget.link?.reveal == _goTo) widget.link!.reveal = null;
    _query.dispose();
    _box.dispose();
    _scroll.dispose();
    _across.dispose();
    super.dispose();
  }

  void _openBox() {
    setState(() => _open = true);
    _box.requestFocus();
  }

  void _closeBox() {
    setState(() {
      _open = false;
      _matches = const [];
    });
  }

  void _find(String query) {
    setState(() {
      _matches = findAll(widget.body, query);
      _current = 0;
    });
    if (_matches.isNotEmpty) _showCurrent();
  }

  void _step(int by) {
    if (_matches.isEmpty) return;
    setState(() {
      _current = (_current + by) % _matches.length;
      if (_current < 0) _current += _matches.length;
    });
    _showCurrent();
  }

  /// Scrolls so the match being looked at is on screen.
  ///
  /// Asked of the paragraph itself rather than counted in lines: the text
  /// wraps, so the line a character is on is not the line it was written on,
  /// and only the thing that laid it out knows where it ended up.
  void _showCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _matches.isEmpty) return;
      if (_lineHeight <= 0) return;

      final row = _rowAt(_matches[_current].$1);
      final position = _scroll.position;
      // A third of the way down rather than at the very top: a match with
      // nothing above it is a match with no context.
      final target = (row * _lineHeight - position.viewportDimension / 3)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      _scroll.jumpTo(target);
    });
  }

  /// Brings [line] of the file to the top of the reading.
  ///
  /// **It glides.** Rule number two: nothing changes in one frame, and a
  /// document that teleported would leave the reader working out what they are
  /// now looking at. The search still jumps, because a match is *found* rather
  /// than gone to.
  ///
  /// Asked of the paragraph rather than counted in rows, for the reason
  /// everything else here is: the text wraps, so the line a character was
  /// written on is not the row it ended up in.
  void _goTo(int line) {
    // Straight away where the text is already laid out, which it is whenever
    // somebody is looking at it — and after the coming frame where it is not,
    // which is the case a panel opened over a file still being built.
    if (_jump(line)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jump(line);
    });
  }

  /// Does the travelling. False when there is nothing laid out to travel over.
  bool _jump(int line) {
    if (!_scroll.hasClients || _lineStarts.isEmpty || _lineHeight <= 0) {
      return false;
    }

    final at = line.clamp(0, _lineStarts.length - 1);
    // A line is a *file* line and the list scrolls in rows, so this is where
    // that line begins among them.
    final row = at < _lineFirstRow.length ? _lineFirstRow[at] : 0;
    final position = _scroll.position;
    // Exactly where the line is, and not a few pixels above it: the strip and
    // the panel both work out where the reader is from the scroll offset, and
    // four pixels of the line above is a different answer to the one just
    // jumped to.
    final target = (row * _lineHeight).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    widget.link?.report(at);
    if (!motionOn(context)) {
      _scroll.jumpTo(target);
      return true;
    }
    _scroll.animateTo(
      target,
      duration: motionOf(context, kOutlineJumpDuration),
      curve: kArrivingCurve,
    );
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final shift = keys.isShiftPressed;
    final key = event.logicalKey;

    // Ctrl+F everywhere, and Cmd+F on the Mac, which is what the hand there
    // reaches for.
    if ((keys.isControlPressed || keys.isMetaPressed) &&
        key == LogicalKeyboardKey.keyF) {
      _openBox();
      return KeyEventResult.handled;
    }
    // F3 walks the matches without going back to the box — the binding every
    // editor has had for thirty years, and the one this application's own F3
    // means "look at this", so it is free once you are already looking.
    if (key == LogicalKeyboardKey.f3 && _matches.isNotEmpty) {
      _step(shift ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (_open && key == LogicalKeyboardKey.escape) {
      _closeBox();
      return KeyEventResult.handled;
    }
    if (_open && (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter)) {
      _step(shift ? -1 : 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // Tolerant of there being no settings at all: this is drawn in tests and
    // previews with nothing above it, and a viewer that cannot build without
    // the whole application around it is a viewer nothing can check.
    final theme = appearanceOf(context);
    _measure(context);
    // What is found is marked in the colour a marked file is marked in; the one
    // being looked at wears the cursor's. Both from the palette, because a
    // search is not a new thing to have colours of its own.
    final found = theme.markedColor.withValues(alpha: 0.28);
    final here = theme.cursorColor.withValues(alpha: 0.55);

    // The panel behind it is the page; nothing is painted here. See the note
    // in `markdown_view` — the readings are translucent like everything else,
    // and a held line is told apart by its own surface.
    return Focus(
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: (_) {
                _onScroll();
                return false;
              },
              child: KeyboardScrollable(
                hasKeyboard: widget.hasKeyboard && !_open,
                controller: _scroll,
                // **A list of lines, not a paragraph.** Every row is one line
                // of the file and every row is the same height, so the list
                // lays out what is on screen and nothing else — and the two
                // questions everything here asks, *which line is at the top*
                // and *where is this line*, become arithmetic.
                //
                // It does not wrap, and it scrolls sideways instead. That is
                // what a viewer does — Lister has done it that way for thirty
                // years — and it is also what makes the row height one number
                // rather than a measurement per line.
                builder: (controller) => SelectionArea(
                  child: Scrollbar(
                    controller: _across,
                    child: LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        controller: _across,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox(
                          // **Never narrower than the window.**
                          //
                          // The box is as wide as the widest row, and the
                          // vertical scrollbar stands at the right edge of the
                          // *box*. So a reading narrower than the window put its
                          // scrollbar in the middle of it — reported with a
                          // screenshot on 2026-09-06, and a real fault of its
                          // own rather than of the measurement.
                          //
                          // It had always been there and the old estimate hid
                          // it: multiplying a character count by the width of an
                          // `M` overshot so far that the box was wider than the
                          // window almost whatever the file was. Measuring the
                          // rows for what they are took the padding away and
                          // left the fault showing.
                          //
                          // The floor is the viewport less the padding either
                          // side, so nothing scrolls sideways that need not.
                          width: math.max(
                            _widest,
                            constraints.maxWidth - 24,
                          ),
                          child: ListView.builder(
                            controller: controller,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            itemCount: _spans.length,
                            itemExtent: _lineHeight > 0 ? _lineHeight : null,
                            itemBuilder: (context, line) => Text.rich(
                              _lineSpan(line, found: found, here: here),
                              softWrap: false,
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_sticky.isNotEmpty)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _StickyLines(
                key: stickyLinesKey,
                lines: _sticky,
                style: widget.style,
                theme: theme,
              ),
            ),
          if (_open)
            Positioned(
              right: 12,
              bottom: 12,
              child: FindBox(
                query: _query,
                node: _box,
                theme: theme,
                matches: _matches.length,
                current: _matches.isEmpty ? 0 : _current + 1,
                truncated: widget.truncated,
                onChanged: _find,
                onStep: _step,
                onClose: _closeBox,
              ),
            ),
        ],
      ),
    );
  }
}

/// The box itself: what is being looked for, how many there are, and the way
/// through them.
/// Names the strip, so a test can ask what is standing in it.
const Key stickyLinesKey = Key('reading-sticky-lines');

/// The lines holding up what is on screen — item 70b.
///
/// Drawn in the reading's own face and at its own size, because it *is* the
/// reading: a strip in the interface's font over a page of code reads as a
/// toolbar that happens to contain source. The panel's own fill behind it, near
/// enough opaque that the text does not show through the words it is holding up.
class _StickyLines extends StatelessWidget {
  const _StickyLines({
    super.key,
    required this.lines,
    required this.style,
    required this.theme,
  });

  final List<StickyLine> lines;
  final TextStyle style;
  final AppearanceSettings theme;

  @override
  Widget build(BuildContext context) => pinnedSurface(
    context,
    held: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final line in lines)
          Padding(
            // The reading's own inset, so a held line sits exactly over the
            // line it came from rather than a few pixels off it.
            padding: const EdgeInsets.fromLTRB(12, 1, 12, 1),
            child: Text(
              line.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // **As it was written, in the face it was written in.** No
              // second styling: what is held is the line, and the only thing
              // that changed is that it stopped moving.
              style: style,
            ),
          ),
      ],
    ),
  );
}

/// How wide the widest row is, in pixels.
///
/// The code viewer used to scroll past its own end, and sometimes to stop two
/// hundred pixels short of it. Both halves of that are one bug, and it was the
/// estimate this replaces.
///
/// **What was wrong with it.** The width used to be the longest row's
/// *character count* multiplied by the width of an `M` in the reading's own
/// style. That is wrong in both directions and neither is small:
///
/// - `M` is about the widest glyph a proportional face has, so a line of
///   spaces, `i`s and `l`s was given two or three times the room it needs — and
///   the reading scrolled off the end of itself into blank space.
/// - The style measured was the *root's*, and a row is not written in it. A
///   keyword is bold and a bold glyph is wider; CJK is wider again. So a line
///   of those came out narrower than it is, and its last stretch could not be
///   reached at all — clipped inside a box too small to hold it.
///
/// **A row can simply be measured, because a row is not a line.** [_rowChars]
/// caps one at eight hundred characters and carries the rest over, so laying
/// one out costs nothing whatever the file is. The rows are measured as the
/// spans they will be drawn as, so the bold and the wide glyphs are in the
/// answer rather than outside it.
///
/// **Which rows.** Only the longest few by character count, because measuring
/// every row of a large file is the freeze all over again. That is a
/// heuristic — thirty narrow characters can be wider than thirty-two spaces —
/// so [_widestCandidates] of them are measured rather than one, and the widest
/// wins. A row that is *nearly* the longest and holds wider glyphs is therefore
/// caught, which is the case that matters.
@visibleForTesting
double widestRow({
  required List<TextSpan> spans,
  required List<int> lengths,
  required TextScaler scaler,
  required TextDirection direction,
}) {
  if (spans.isEmpty || lengths.isEmpty) return 0;

  // One pass for the longest, and a second for everything near it. Sorting
  // would be simpler and is a bad idea: a 227 MB log is millions of rows.
  var longest = 0;
  for (final length in lengths) {
    if (length > longest) longest = length;
  }
  if (longest == 0) return 0;

  var widest = 0.0;
  var measured = 0;
  for (var row = 0; row < lengths.length && row < spans.length; row++) {
    if (lengths[row] < longest - _widestSlack) continue;
    final painter = TextPainter(
      text: spans[row],
      textScaler: scaler,
      textDirection: direction,
      maxLines: 1,
    )..layout();
    if (painter.width > widest) widest = painter.width;
    painter.dispose();
    if (++measured >= _widestCandidates) break;
  }

  // A little over, deliberately, and only a little: the last glyph of the
  // widest row must not sit against the edge of the box that holds it, and
  // anything more than that is the empty space this was reported for.
  return widest == 0 ? 0 : widest + 8;
}

/// How many of the longest rows are laid out to find the widest.
const int _widestCandidates = 32;

/// How much shorter than the longest a row may be and still be measured.
///
/// In characters. Wide enough that a row of CJK a few characters short of the
/// longest is still a candidate — it is very likely the wider of the two —
/// and narrow enough that an ordinary file offers a handful rather than all of
/// them.
const int _widestSlack = 16;
