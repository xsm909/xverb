import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../../core/settings/appearance_settings.dart';
import '../motion.dart';
import '../settings/settings_group.dart' show marked;
import '../plugins/plugin_table.dart' show appearanceOf;
import '../widgets/hint.dart';
import 'outline.dart';
import 'reading_link.dart';
import 'reading_colours.dart';

/// The table of contents of whatever is being read, drawn in a slide panel.
///
/// Two jobs and no others: **go somewhere**, and **say where I am**. It is not
/// an index of symbols and has no idea what any of these names mean — see
/// `outline.dart` for how little is known about them and why that is enough.
///
/// The keyboard is the point of it. Rule number one in this application is
/// that anything the mouse can reach the keyboard can reach: `Ctrl+Shift+O`
/// opens it, `Tab` steps into it and back out, the arrows walk and fold,
/// `Enter` jumps and gives the reading back the keyboard, `Ctrl+Enter` jumps
/// and stays, letters filter where they are typed, and Escape unwinds the
/// three states in order — filter, panel, viewer.
class StructurePanel extends StatefulWidget {
  const StructurePanel({
    super.key,
    required this.nodes,
    required this.link,
    required this.focusNode,
    required this.onLeave,
    required this.onClose,
    this.truncated = false,
  });

  /// The outline, in reading order, flat and with a depth on each node.
  final List<OutlineNode> nodes;

  /// Where the reading is, and how to move it.
  final ReadingLink link;

  /// The panel's own place in the focus order. Held by the page, because the
  /// page is what hands the keyboard back and forth.
  final FocusNode focusNode;

  /// Give the reading the keyboard back — `Tab`, and `Enter` after a jump.
  final VoidCallback onLeave;

  /// Put the panel away — Escape with no filter left to clear.
  final VoidCallback onClose;

  /// Whether the file was cut short at the viewer's byte limit, which makes
  /// the tree a tree of the first part of it. **Said out loud**: a table of
  /// contents covering two megabytes of nine is a table of contents that lies.
  final bool truncated;

  @override
  State<StructurePanel> createState() => _StructurePanelState();
}

class _StructurePanelState extends State<StructurePanel> {
  final ScrollController _scroll = ScrollController();

  /// Which nodes are folded, by their place in [StructurePanel.nodes].
  ///
  /// Not remembered between files: a set of indices means nothing in the next
  /// document, and "the third node was folded" is not a thing anybody meant.
  final Set<int> _folded = {};

  /// What has been typed to narrow the tree, and nothing else — there is no
  /// search box: the letters filter the tree in the panel itself.
  String _filter = '';

  /// Where the keyboard is in the tree, as a place in [_rows].
  int _cursor = 0;

  /// The nodes on show, in order, as places in [StructurePanel.nodes].
  List<int> _rows = const [];

  /// How tall a row is, kept from the last build.
  ///
  /// Read here rather than asked for again when a row has to be brought into
  /// view: that happens after the frame, and the settings cannot be *watched*
  /// from outside a build — which is an assertion, not a subtlety.
  double _height = 22;

  @override
  void initState() {
    super.initState();
    _fold();
    _rebuild();
    widget.link.addListener(_followed);
  }

  @override
  void didUpdateWidget(StructurePanel old) {
    super.didUpdateWidget(old);
    if (old.link != widget.link) {
      old.link.removeListener(_followed);
      widget.link.addListener(_followed);
    }
    if (!identical(old.nodes, widget.nodes)) {
      _filter = '';
      _fold();
      _rebuild();
      _cursor = 0;
    }
  }

  @override
  void dispose() {
    widget.link.removeListener(_followed);
    _scroll.dispose();
    super.dispose();
  }

  /// Unfolded down to the second level, folded below it.
  void _fold() {
    _folded
      ..clear()
      ..addAll([
        for (var i = 0; i < widget.nodes.length; i++)
          if (widget.nodes[i].depth >= 1 && _hasChildren(i)) i,
      ]);
  }

  bool _hasChildren(int i) =>
      i + 1 < widget.nodes.length &&
      widget.nodes[i + 1].depth > widget.nodes[i].depth;

  void _rebuild() => _rows = _visible();

  List<int> _visible() {
    final nodes = widget.nodes;
    if (_filter.isNotEmpty) {
      // A filtered tree ignores folding — hiding a match inside a folded
      // parent is the one thing a filter must never do. Ancestors come along
      // so a name is read in the place it belongs to.
      final wanted = _filter.toLowerCase();
      final keep = <int>{};
      for (var i = 0; i < nodes.length; i++) {
        if (!nodes[i].title.toLowerCase().contains(wanted)) continue;
        keep.add(i);
        var depth = nodes[i].depth;
        for (var up = i - 1; up >= 0 && depth > 0; up--) {
          if (nodes[up].depth < depth) {
            keep.add(up);
            depth = nodes[up].depth;
          }
        }
      }
      return keep.toList()..sort();
    }

    final rows = <int>[];
    var hide = 1 << 30;
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].depth > hide) continue;
      hide = 1 << 30;
      rows.add(i);
      if (_folded.contains(i)) hide = nodes[i].depth;
    }
    return rows;
  }

  // --- Following the reading -------------------------------------------------

  /// The innermost node the reading is standing in, or -1.
  ///
  /// A binary search over the line each node starts on, then a walk back out
  /// through whoever still holds that line: the deepest of them is where the
  /// reader is.
  int get _here {
    final nodes = widget.nodes;
    if (nodes.isEmpty) return -1;
    final at = widget.link.top;
    var low = 0;
    var high = nodes.length - 1;
    var found = -1;
    while (low <= high) {
      final middle = (low + high) ~/ 2;
      if (nodes[middle].line <= at) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    for (var i = found; i >= 0; i--) {
      if (nodes[i].holds(at)) return i;
    }
    return -1;
  }

  /// The reading moved: light up where it is, and bring that into view — but
  /// **only while the keyboard is not in the tree**. Somebody walking the tree
  /// with the arrows has said where they are looking, and a panel that scrolls
  /// out from under them because the reading moved is a panel arguing with its
  /// own user.
  void _followed() {
    if (!mounted) return;
    setState(() {});
    if (widget.focusNode.hasFocus) return;
    final at = _here;
    if (at < 0) return;
    final row = _rows.indexOf(at);
    if (row >= 0) _show(row);
  }

  // --- The keyboard ----------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;

    switch (key) {
      case LogicalKeyboardKey.escape:
        // Filter, then panel, then viewer — and the viewer's own Escape is
        // whatever is above this, which is why this one is ignored last.
        if (_filter.isNotEmpty) {
          setState(() {
            _filter = '';
            _rebuild();
          });
          return KeyEventResult.handled;
        }
        widget.onClose();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.tab:
        widget.onLeave();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowDown:
        _moveBy(1);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowUp:
        _moveBy(-1);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.pageDown:
        _moveBy(10);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.pageUp:
        _moveBy(-10);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.home:
        _moveTo(0);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.end:
        _moveTo(_rows.length - 1);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowRight:
        _unfold();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowLeft:
        _foldOrOut();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        // The two differ in one thing only: where the keyboard ends up. Which
        // is also what decides whether an unpinned panel goes away, because
        // the panel leaves when you return to the text and not before.
        _jump(stay: keys.isControlPressed || keys.isMetaPressed);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.backspace:
        if (_filter.isEmpty) return KeyEventResult.handled;
        setState(() {
          _filter = _filter.substring(0, _filter.length - 1);
          _rebuild();
          _cursor = 0;
        });
        return KeyEventResult.handled;
    }

    // Anything printable narrows the tree. Not while a modifier is down: that
    // is somebody's shortcut on its way somewhere else.
    final typed = event.character;
    if (typed != null &&
        typed.isNotEmpty &&
        !keys.isControlPressed &&
        !keys.isMetaPressed &&
        !keys.isAltPressed &&
        typed.codeUnitAt(0) >= 0x20) {
      setState(() {
        _filter += typed;
        _rebuild();
        _cursor = 0;
      });
      _show(0);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveBy(int by) => _moveTo(_cursor + by);

  void _moveTo(int row) {
    if (_rows.isEmpty) return;
    setState(() => _cursor = row.clamp(0, _rows.length - 1));
    _show(_cursor);
  }

  void _unfold() {
    if (_rows.isEmpty) return;
    final at = _rows[_cursor];
    if (!_hasChildren(at)) return;
    if (_folded.contains(at)) {
      setState(() {
        _folded.remove(at);
        _rebuild();
      });
      return;
    }
    _moveBy(1);
  }

  void _foldOrOut() {
    if (_rows.isEmpty) return;
    final at = _rows[_cursor];
    if (_hasChildren(at) && !_folded.contains(at)) {
      setState(() {
        _folded.add(at);
        _rebuild();
      });
      return;
    }
    // Out to whoever holds this one, which is the nearest row above it that
    // stands further out.
    for (var row = _cursor - 1; row >= 0; row--) {
      if (widget.nodes[_rows[row]].depth < widget.nodes[at].depth) {
        _moveTo(row);
        return;
      }
    }
  }

  void _jump({required bool stay}) {
    if (_rows.isEmpty) return;
    widget.link.goTo(widget.nodes[_rows[_cursor]].line);
    if (!stay) widget.onLeave();
  }

  /// Brings row [row] into view, if it is not already.
  void _show(int row) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _rows.isEmpty) return;
      final height = _height;
      final top = row * height;
      final position = _scroll.position;
      final viewport = position.viewportDimension;
      var target = position.pixels;
      if (top < position.pixels) {
        target = top;
      } else if (top + height > position.pixels + viewport) {
        target = top + height - viewport;
      }
      target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((target - position.pixels).abs() < 0.5) return;
      _scroll.animateTo(
        target,
        duration: motionOf(context, kOutlineRowDuration),
        curve: kArrivingCurve,
      );
    });
  }

  double _rowHeight(AppearanceSettings theme) => theme.chromeRowHeight;

  @override
  Widget build(BuildContext context) {
    final theme = appearanceOf(context);
    final ink =
        DefaultTextStyle.of(context).style.color ?? readingColours(context).ink;
    final height = _height = _rowHeight(theme);
    final here = _here;
    final hasKeyboard = widget.focusNode.hasFocus;

    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      onFocusChange: (_) => setState(() {}),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_filter.isNotEmpty || widget.truncated)
            _Remark(
              text: _filter.isNotEmpty
                  ? '${tr('Filter')}: $_filter'
                  : tr('The file was cut short — so is this.'),
              ink: ink,
              theme: theme,
            ),
          Expanded(
            child: _rows.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        tr('Nothing matches.'),
                        style: TextStyle(
                          color: ink.withValues(alpha: 0.6),
                          fontSize: theme.fontSize - 1,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    // Fixed rows, so bringing one into view is arithmetic
                    // rather than a search through what happens to be built.
                    itemExtent: height,
                    itemCount: _rows.length,
                    itemBuilder: (context, row) {
                      final at = _rows[row];
                      return _Row(
                        node: widget.nodes[at],
                        ink: ink,
                        theme: theme,
                        height: height,
                        folded: _folded.contains(at),
                        foldable: _hasChildren(at) && _filter.isEmpty,
                        // Where the keyboard stands, and where the reading is.
                        // Two different things, and they are drawn as two:
                        // one is a cursor, the other is a place.
                        cursor: row == _cursor && hasKeyboard,
                        reading: at == here,
                        filter: _filter,
                        onPressed: () {
                          setState(() => _cursor = row);
                          widget.focusNode.requestFocus();
                          widget.link.goTo(widget.nodes[at].line);
                        },
                        onFold: () => setState(() {
                          if (!_folded.remove(at)) _folded.add(at);
                          _rebuild();
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// A line of small print along the top of the tree — what is being filtered
/// on, or that the file itself was cut short.
class _Remark extends StatelessWidget {
  const _Remark({required this.text, required this.ink, required this.theme});

  final String text;
  final Color ink;
  final AppearanceSettings theme;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: ink.withValues(alpha: 0.65),
        fontSize: theme.fontSize - 2,
        fontStyle: FontStyle.italic,
      ),
    ),
  );
}

/// One node: what kind it is, what it is called, and how far in it sits.
///
/// **No line numbers.** They are what the panel is built on and not what
/// anybody is looking for; a column of them would take the width the names
/// need. A name that does not fit says the whole of itself under the pointer,
/// the way a branch does in the git tool.
class _Row extends StatelessWidget {
  const _Row({
    required this.node,
    required this.ink,
    required this.theme,
    required this.height,
    required this.folded,
    required this.foldable,
    required this.cursor,
    required this.reading,
    required this.filter,
    required this.onPressed,
    required this.onFold,
  });

  final OutlineNode node;
  final Color ink;
  final AppearanceSettings theme;
  final double height;
  final bool folded;
  final bool foldable;
  final bool cursor;
  final bool reading;

  /// What is being filtered for, so the row can say why it is one of the rows.
  ///
  /// **It matters more here than in most lists**, because a filtered tree keeps
  /// the ancestors of every match so a name is read in the place it belongs to
  /// — and an ancestor matched nothing. Without a mark, half the rows on screen
  /// are answers and half are scaffolding and there is no telling which.
  final String filter;

  final VoidCallback onPressed;
  final VoidCallback onFold;

  @override
  Widget build(BuildContext context) {
    final tint = _tintOf(node.kind, theme, ink);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onPressed,
        child: AnimatedContainer(
          duration: motionOf(context, kOutlineRowDuration),
          curve: kArrivingCurve,
          height: height,
          padding: EdgeInsets.only(left: 4 + node.depth * 12.0, right: 6),
          decoration: BoxDecoration(
            color: cursor
                ? theme.cursorColor.withValues(alpha: 0.45)
                : reading
                ? ink.withValues(alpha: 0.10)
                : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: foldable
                    ? GestureDetector(
                        onTap: onFold,
                        child: AnimatedRotation(
                          turns: folded ? 0 : 0.25,
                          duration: motionOf(context, kOutlineRowDuration),
                          curve: kArrivingCurve,
                          child: Icon(
                            Icons.chevron_right,
                            size: theme.fontSize,
                            color: ink.withValues(alpha: 0.7),
                          ),
                        ),
                      )
                    : null,
              ),
              Icon(_iconOf(node.kind), size: theme.fontSize, color: tint),
              const SizedBox(width: 6),
              Expanded(
                child: Hint(
                  message: node.title,
                  child: Text.rich(
                    marked(
                      node.title,
                      filter,
                      TextStyle(
                        color: ink.withValues(
                          alpha: reading || cursor ? 1 : 0.9,
                        ),
                        fontSize: theme.fontSize - 1,
                        fontWeight:
                            node.kind == OutlineKind.type ||
                                node.kind == OutlineKind.namespace ||
                                node.kind == OutlineKind.file
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                      theme.accentColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The picture for a kind. **Chosen here, by the host**, exactly as a colour
/// for a highlighting role is: what the grammar shipped is a word, and what a
/// word looks like is this application's business.
IconData _iconOf(OutlineKind kind) => switch (kind) {
  OutlineKind.namespace => Icons.workspaces_outlined,
  OutlineKind.type => Icons.data_object,
  // One mark for both, and the difference between them is where they sit:
  // a method is always drawn under the type that holds it. Two pictures
  // for one idea is a legend to learn for nothing.
  OutlineKind.function || OutlineKind.method => Icons.functions,
  OutlineKind.field => Icons.label_outline,
  OutlineKind.section => Icons.segment,
  OutlineKind.heading => Icons.title,
  OutlineKind.file => Icons.description_outlined,
  OutlineKind.hunk => Icons.notes_outlined,
};

/// And the colour, from the palette rather than added to it — the same three
/// the highlighting uses, meaning the same three things.
Color _tintOf(OutlineKind kind, AppearanceSettings theme, Color ink) =>
    switch (kind) {
      OutlineKind.namespace || OutlineKind.type => theme.directoryColor,
      OutlineKind.function || OutlineKind.method => ink.withValues(alpha: 0.75),
      OutlineKind.section || OutlineKind.heading => theme.accentColor,
      OutlineKind.file => theme.directoryColor,
      OutlineKind.field || OutlineKind.hunk => ink.withValues(alpha: 0.55),
    };

/// The way chrome outside a reading reaches the structure panel inside it.
///
/// The panel is held by whatever draws the content, so that a reading in a
/// side panel has one too. But the *viewer page* has furniture of its own that
/// has to reach it — a button in the title bar, and Escape, which closes the
/// panel before it closes the page. This is that reach, and nothing more: two
/// verbs and one fact.
///
/// A side panel passes none, and then the panel answers only to its keys.
class StructureHandle extends ChangeNotifier {
  VoidCallback? _toggle;
  VoidCallback? _close;
  bool _open = false;

  /// Whether the panel is out, for a button that wants to look pressed.
  bool get open => _open;

  bool _offered = false;

  /// Whether there is anything here to have a structure of. Said by the
  /// content view, because only it knows what it is drawing — a picture and a
  /// table never grow one, and a button for a panel that cannot open is a
  /// button that lies.
  bool get offered => _offered;

  void offer(bool can) {
    if (_offered == can) return;
    _offered = can;
    notifyListeners();
  }

  /// Which content view this handle currently speaks for.
  ///
  /// **A view's `dispose` always runs after its replacement's `initState`** —
  /// that is the ordinary order of things in Flutter, and the viewer's
  /// cross-fade widens it from the end of one frame to the length of a fade,
  /// with both readings mounted the whole time. So an unguarded `detach` in
  /// the departing view took the *arriving* one's wiring away with it, and the
  /// button and Ctrl+Shift+O then reached nobody.
  ///
  /// What that looked like: F3 on a Markdown file gave a structure, and the
  /// same file walked to through the film strip gave none — while a panel that
  /// was already out went on working, because that one is restored from the
  /// settings and never passes through here.
  Object? _owner;

  /// Wired by the content view when it is built. **The newest one wins**, and
  /// only the one that is still wired may unwire itself.
  void attach({
    required Object owner,
    required VoidCallback toggle,
    required VoidCallback close,
  }) {
    _owner = owner;
    _toggle = toggle;
    _close = close;
  }

  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _toggle = null;
    _close = null;
  }

  /// Whether [owner] is the reading this handle is speaking for — asked by a
  /// view before it says anything, so the one on its way out stays quiet.
  bool speaksFor(Object owner) => identical(_owner, owner);

  /// Said by the content view, so the chrome can follow.
  void report(bool open) {
    if (_open == open) return;
    _open = open;
    notifyListeners();
  }

  void toggle() => _toggle?.call();

  /// Answers Escape: true when there was a panel to put away.
  bool close() {
    if (!_open) return false;
    _close?.call();
    return true;
  }
}
