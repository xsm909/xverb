import 'package:flutter/material.dart';

import '../../core/plugins/viewer.dart';
import '../../core/settings/appearance_settings.dart';
import 'plugin_table.dart' show appearanceOf;
import 'row_drag.dart';

/// A page made of more than one thing, with a divider you can drag.
///
/// The shape Fork and every tool like it has: the branches down one side, the
/// log above, and what one commit touched with the difference itself below. A
/// view could only return one thing at a time before, and walking between them
/// meant losing sight of the list you had walked from — which is the whole
/// reason anybody looks at a log.
///
/// The divider's position is the *user's*, and it is kept here rather than sent
/// back to the plugin. A plugin says what the parts are worth relative to each
/// other; where somebody dragged the line is about this window on this screen,
/// and asking the plugin about it would put a round trip inside a drag.
class SplitView extends StatefulWidget {
  const SplitView({
    super.key,
    required this.content,
    required this.buildPart,
    this.focused = '',
    this.onFocus,
    this.onButton,
    this.onDropRows,
  });

  final ViewerContent content;

  /// Draws one part. Handed the part rather than its content so the builder can
  /// tell which one it is drawing — the same reason every event carries it.
  final Widget Function(ContentPart part) buildPart;

  /// Which part has the keyboard. Drawn with a mark down its edge, the way the
  /// panels say which of the two is active.
  final String focused;

  final void Function(String part)? onFocus;

  /// A tab was pressed. The ordinary button event, so a plugin answers tabs
  /// the way it answers everything else.
  final void Function(String buttonId, Map<String, Object?> values)? onButton;

  /// Rows were carried out of one part and let go over another. What that
  /// *means* is the plugin's — the host only knows they were moved.
  final void Function(String from, String to, List<int> rows)? onDropRows;

  @override
  State<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends State<SplitView> {
  /// Where each divider sits, as a fraction of the whole. Empty until the
  /// weights are read, and then the user's own.
  List<double>? _at;

  /// How thin a part may be dragged before it stops giving way. Small enough
  /// to get out of the way, large enough to grab hold of again.
  static const double _least = 44;

  /// The divider's own width. Wider than it looks: the line is one pixel and
  /// a one-pixel target is a target nobody hits.
  static const double _grip = 7;

  /// The narrowest a part can be and still be a column. Below this a listing
  /// shows a word and a half of every row and a difference shows the left
  /// margin of it, which is a picture of a page rather than a page.
  static const double _column = 260;

  List<double> _fractionsFor(List<ContentPart> parts) {
    final at = _at;
    if (at != null && at.length == parts.length) return at;

    final total = parts.fold<double>(
      0,
      (sum, part) => sum + (part.weight <= 0 ? 1 : part.weight),
    );
    return _at = [
      for (final part in parts) (part.weight <= 0 ? 1 : part.weight) / total,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = appearanceOf(context);
    final parts = widget.content.parts;
    if (parts.isEmpty) return const SizedBox.shrink();
    if (parts.length == 1) return widget.buildPart(parts.first);

    final fractions = _fractionsFor(parts);

    return LayoutBuilder(
      builder: (context, constraints) {
        // **Side by side, until side by side stops meaning anything.** A plugin
        // says what its parts are and which way they go, and it says it once —
        // it cannot know whether it was opened in half a window, on a narrow
        // screen, or beside a console somebody has just dragged up. Three
        // columns of a hundred points each are not three columns; they are one
        // unreadable one. So a row that cannot give its parts room to be
        // columns is drawn as a stack instead, which is the same page with the
        // same parts in the same order.
        final vertical = widget.content.direction == SplitDirection.vertical ||
            (constraints.maxWidth.isFinite &&
                constraints.maxWidth < _column * parts.length);
        final room = (vertical ? constraints.maxHeight : constraints.maxWidth) -
            _grip * (parts.length - 1);
        final sizes = [
          for (final fraction in fractions) (room * fraction).clamp(0.0, room),
        ];

        final children = <Widget>[];
        for (var i = 0; i < parts.length; i++) {
          if (i > 0) {
            children.add(_Divider(
              vertical: vertical,
              theme: theme,
              onDrag: (delta) => _drag(i - 1, delta, room),
            ));
          }
          children.add(SizedBox(
            width: vertical ? double.infinity : sizes[i],
            height: vertical ? sizes[i] : double.infinity,
            child: _Part(
              part: parts[i],
              theme: theme,
              isFocused: parts[i].id == widget.focused,
              onFocus: widget.onFocus,
              onButton: widget.onButton,
              onDropRows: widget.onDropRows,
              child: widget.buildPart(parts[i]),
            ),
          ));
        }

        return vertical
            ? Column(mainAxisSize: MainAxisSize.min, children: children)
            : Row(mainAxisSize: MainAxisSize.min, children: children);
      },
    );
  }

  /// Moves one divider, taking from one side and giving to the other.
  ///
  /// Only the two parts either side of it move. A drag that pushed everything
  /// along would rearrange parts the hand is nowhere near, which is the thing
  /// that makes a multi-part splitter feel broken.
  void _drag(int divider, double delta, double room) {
    if (room <= 0) return;
    final at = List<double>.from(_fractionsFor(widget.content.parts));
    final step = delta / room;
    final floor = _least / room;

    final before = at[divider] + step;
    final after = at[divider + 1] - step;
    if (before < floor || after < floor) return;

    at[divider] = before;
    at[divider + 1] = after;
    setState(() => _at = at);
  }
}

/// One part, with its own strip of a title and a mark when it has the keyboard.
class _Part extends StatelessWidget {
  const _Part({
    required this.part,
    required this.theme,
    required this.isFocused,
    required this.onFocus,
    required this.onButton,
    required this.onDropRows,
    required this.child,
  });

  final ContentPart part;
  final AppearanceSettings theme;
  final bool isFocused;
  final void Function(String part)? onFocus;
  final void Function(String buttonId, Map<String, Object?> values)? onButton;
  final void Function(String from, String to, List<int> rows)? onDropRows;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final title = part.title;

    // **A part that holds other parts does not take the keyboard.** Its own
    // detector sits over every one of them, so a press inside the list of
    // files was answered twice — once by the list, and then by the box holding
    // it — and the second answer won. The keyboard went to a part that draws
    // nothing, every arrow key was refused, and the files could be walked with
    // the mouse and with nothing else.
    final holdsOthers = part.content?.kind == ViewerContentKind.split;

    return GestureDetector(
      // Down rather than tap: a press that lands on a row has already been
      // claimed by the row, and the part it landed in is still the part the
      // keyboard should move to.
      behavior: HitTestBehavior.translucent,
      onPanDown: holdsOthers ? null : (_) => onFocus?.call(part.id),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              // The one part with the keyboard says so, in the same colour and
              // for the same reason the active panel's ring does.
              color: isFocused ? theme.accentColor : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Column(
          children: [
            // One strip, whether it carries a name or a row of tabs. Two
            // strips stacked would be two rows of the window spent saying
            // where you are, and a part is not usually that tall.
            if (title != null || part.tabs.isNotEmpty)
              Container(
                height: theme.chromeRowHeight,
                width: double.infinity,
                color: theme.effectiveHeaderBackground,
                child: part.tabs.isEmpty
                    ? _Title(title!, theme)
                    : _Tabs(part: part, theme: theme, onButton: onButton),
              ),
            Expanded(
              // **A part is where rows land.** Not the row under the pointer:
              // dropping onto a list means "into this list", and asking the
              // hand to find a particular row of it would be asking for
              // precision the gesture does not have and the meaning does not
              // need.
              child: onDropRows == null || holdsOthers
                  ? child
                  : DragTarget<RowDrag>(
                      onWillAcceptWithDetails: (details) =>
                          details.data.part != part.id &&
                          !details.data.isEmpty,
                      onAcceptWithDetails: (details) => onDropRows!(
                        details.data.part,
                        part.id,
                        details.data.rows,
                      ),
                      builder: (context, over, _) => DecoratedBox(
                        decoration: BoxDecoration(
                          // Only while something is actually over it, and in
                          // the accent, so "let go here" is the same colour as
                          // every other "this one" in the application.
                          color: over.isEmpty
                              ? null
                              : theme.accentColor.withValues(alpha: 0.12),
                          border: Border.all(
                            color: over.isEmpty
                                ? Colors.transparent
                                : theme.accentColor,
                            width: over.isEmpty ? 0 : 1.5,
                          ),
                        ),
                        child: child,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The strip at the head of a part — its name, or its row of tabs.
///
/// Drawn on the header's fill, so it is written in the header's ink. It took
/// the panel's until 2026-08-15, which on a light palette is a dark word on a
/// slate strip.
class _Title extends StatelessWidget {
  const _Title(this.text, this.theme);

  final String text;
  final AppearanceSettings theme;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.headerForeground.withValues(alpha: 0.8),
              fontSize: theme.fontSize - 1,
              fontWeight: theme.strongFontWeight.weight,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      );
}

/// The ways of looking at one part, in the strip its name would have used.
///
/// The one that is showing is marked with a rule along its bottom rather than
/// a box around it: a part is a few centimetres tall and a boxed tab spends
/// two of them on chrome. The title has not gone — it moves to the right of
/// the tabs, where it goes on saying which commit all three are about.
class _Tabs extends StatelessWidget {
  const _Tabs({required this.part, required this.theme, required this.onButton});

  final ContentPart part;
  final AppearanceSettings theme;
  final void Function(String buttonId, Map<String, Object?> values)? onButton;

  @override
  Widget build(BuildContext context) {
    final current = part.tab ?? part.tabs.first.id;
    final title = part.title;

    return Row(
      children: [
        for (final tab in part.tabs)
          _Tab(
            tab: tab,
            theme: theme,
            isCurrent: tab.id == current,
            onPressed: onButton == null ? null : () => onButton!(tab.id, const {}),
          ),
        if (title != null)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: theme.headerForeground.withValues(alpha: 0.6),
                  fontSize: theme.fontSize - 1,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Tab extends StatefulWidget {
  const _Tab({
    required this.tab,
    required this.theme,
    required this.isCurrent,
    required this.onPressed,
  });

  final ContentTab tab;
  final AppearanceSettings theme;
  final bool isCurrent;
  final VoidCallback? onPressed;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final ink = widget.isCurrent
        ? theme.headerForeground
        : theme.headerForeground.withValues(alpha: _over ? 0.85 : 0.6);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: widget.isCurrent ? theme.accentColor : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              Text(
                widget.tab.label,
                style: TextStyle(
                  color: ink,
                  fontSize: theme.fontSize - 1,
                  fontWeight: widget.isCurrent
                      ? theme.strongFontWeight.weight
                      : theme.fileFontWeight.weight,
                  decoration: TextDecoration.none,
                ),
              ),
              if (widget.tab.detail != null) ...[
                const SizedBox(width: 5),
                Text(
                  widget.tab.detail!,
                  style: TextStyle(
                    color: ink.withValues(alpha: ink.a * 0.7),
                    fontSize: theme.fontSize - 2,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatefulWidget {
  const _Divider({
    required this.vertical,
    required this.theme,
    required this.onDrag,
  });

  final bool vertical;
  final AppearanceSettings theme;
  final ValueChanged<double> onDrag;

  @override
  State<_Divider> createState() => _DividerState();
}

class _DividerState extends State<_Divider> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final line = widget.theme.panelForeground.withValues(alpha: _over ? 0.5 : 0.2);

    return MouseRegion(
      cursor: widget.vertical
          ? SystemMouseCursors.resizeRow
          : SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: widget.vertical
            ? (details) => widget.onDrag(details.delta.dy)
            : null,
        onHorizontalDragUpdate: widget.vertical
            ? null
            : (details) => widget.onDrag(details.delta.dx),
        child: SizedBox(
          width: widget.vertical ? double.infinity : _SplitViewState._grip,
          height: widget.vertical ? _SplitViewState._grip : double.infinity,
          child: Center(
            child: SizedBox(
              width: widget.vertical ? double.infinity : 1,
              height: widget.vertical ? 1 : double.infinity,
              child: ColoredBox(color: line),
            ),
          ),
        ),
      ),
    );
  }
}
