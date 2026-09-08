import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Something you read, that the arrow keys move.
///
/// **A page nobody can scroll without a mouse is a page this application does
/// not get to have.** Text and Markdown are the two things it draws that are
/// longer than the window and have no rows to put a cursor on, and for a long
/// time the only way down either of them was the wheel — which is the one rule
/// here that is not negotiable.
///
/// It takes the keyboard only when it is the thing being worked in. A preview
/// in the panel *beside* the one being typed in must not take the arrows away
/// from that panel: it is there to be glanced at, and the keyboard belongs to
/// whoever is working.
class KeyboardScrollable extends StatefulWidget {
  const KeyboardScrollable({
    super.key,
    required this.builder,
    required this.hasKeyboard,
    this.controller,
  });

  /// Draws the thing, given the controller that scrolls it.
  final Widget Function(ScrollController controller) builder;

  final bool hasKeyboard;

  /// A controller from outside, for when something else has to scroll this
  /// too — a search jumping to what it found. Left null this owns its own,
  /// which is what everything that is only read wants.
  final ScrollController? controller;

  /// A line, in logical pixels. Not a text line: this scrolls things whose
  /// lines are all different heights — a heading, a rule, a table — and a
  /// third of a finger's width is what the arrow keys move in every reader.
  static const double lineStep = 48;

  @override
  State<KeyboardScrollable> createState() => _KeyboardScrollableState();
}

class _KeyboardScrollableState extends State<KeyboardScrollable> {
  final ScrollController _own = ScrollController();
  final FocusNode _node = FocusNode(debugLabel: 'reading');

  ScrollController get _scroll => widget.controller ?? _own;

  @override
  void initState() {
    super.initState();
    // **Taken, not asked for.** `autofocus` only lands where nothing else in
    // the scope holds the keyboard, and something always does: a viewer is not
    // a route, so it opens inside the scope the panel F3 was pressed in and
    // that panel keeps what it has. The reading then answered no keys at all
    // until a click moved the focus by hand — which is how "the keyboard does
    // nothing in a viewer" survived two rounds of tests that pump this on its
    // own, where there is nobody to take it from.
    _takeIt();
  }

  @override
  void didUpdateWidget(KeyboardScrollable old) {
    super.didUpdateWidget(old);
    // After the frame, not during it. On the way *in* — a panel that has just
    // been handed the keyboard — the [ExcludeFocus] below is still excluding
    // when this runs, and a node that cannot take focus refuses it in silence:
    // the panel then answered no keys at all, exactly the failure this widget
    // was written to document.
    if (widget.hasKeyboard && !_node.hasFocus) _takeIt();
  }

  /// Claims the keyboard once this is on screen, if it is the thing being
  /// worked in. After the frame, because a node cannot be focused before it is
  /// attached to the tree.
  void _takeIt() {
    if (!widget.hasKeyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.hasKeyboard && !_node.hasFocus) {
        _node.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _node.dispose();
    // Only the one it made itself: a controller handed in belongs to whoever
    // handed it in, and disposing it here would take it out from under them.
    _own.dispose();
    super.dispose();
  }

  /// Moves by [by], or to an end when [to] is given.
  void _move(double by, {double? to}) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final target = (to ?? position.pixels + by)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    _scroll.jumpTo(target);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_scroll.hasClients) return KeyEventResult.ignored;

    final page = _scroll.position.viewportDimension;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(KeyboardScrollable.lineStep);
      case LogicalKeyboardKey.arrowUp:
        _move(-KeyboardScrollable.lineStep);
      // A page less a line, so the line you were reading is still on screen
      // when the next one arrives. Every reader ever written does this.
      case LogicalKeyboardKey.pageDown:
      case LogicalKeyboardKey.space:
        _move(page - KeyboardScrollable.lineStep);
      case LogicalKeyboardKey.pageUp:
        _move(-(page - KeyboardScrollable.lineStep));
      case LogicalKeyboardKey.home:
        _move(0, to: 0);
      case LogicalKeyboardKey.end:
        _move(0, to: double.maxFinite);
      default:
        // Everything else belongs to whatever is above: the function row, Tab,
        // Escape. A reader that swallowed those would be a reader you cannot
        // get out of.
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
        // Not merely "does not ask for the keyboard" — **cannot be given it.**
        // A `Scrollable` answers the arrow keys itself the moment it holds the
        // focus, so a preview beside the panel being worked in would take them
        // the first time anything let go of them. Left to the framework it is
        // a race, and a race about which of two things the arrow keys move is
        // one nobody can be asked to reason about.
        excluding: !widget.hasKeyboard,
        child: Focus(
          focusNode: _node,
          autofocus: widget.hasKeyboard,
          onKeyEvent: _onKey,
          child: widget.builder(_scroll),
        ),
      );
}
