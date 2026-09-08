import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../state/window_stack.dart';
import '../widgets/hint.dart';

/// The chrome around one internal window: a title bar to drag it by, the two
/// buttons, and the eight resize grips.
///
/// The frame owns no geometry — it hands every gesture to the [DeskWindow], so
/// the window keeps its place across rebuilds.
class WindowFrame extends StatefulWidget {
  const WindowFrame({
    super.key,
    required this.window,
    required this.desk,
    required this.active,
    required this.fullScreen,
    required this.onFocus,
    required this.onClose,
    this.leaving = false,
  });

  final DeskWindow window;

  /// Size of the area windows live in. Drags are clamped to it.
  final Size desk;

  /// The front window. Only it carries the accent border and the keyboard.
  final bool active;

  /// Phone layout: the window fills the desk and loses its drag and resize
  /// gestures, since there is nowhere to drag it to.
  final bool fullScreen;

  final VoidCallback onFocus;
  final VoidCallback onClose;

  /// Answered, and on its way back to the row it came from. It is a picture of
  /// a window rather than a window — see [_WindowFrameState._contents].
  final bool leaving;

  static const double titleHeight = 30;

  /// Thickness of the invisible strips along the edges that resize the window.
  static const double _gripSize = 6;

  @override
  State<WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends State<WindowFrame> {
  /// A scope, not a plain node, and the difference is the whole of "windows
  /// have no default focus".
  ///
  /// A plain `Focus` took the keyboard for the frame itself. Key events travel
  /// *up* from whatever is focused, so nothing inside the window was ever on
  /// the path: a name field's `autofocus` lost the keyboard the moment the
  /// window became active, and `WindowForm`'s Enter binding sits below the
  /// frame and never saw the key — most plainly on a confirmation, where there
  /// is nothing to type into and Enter simply did nothing.
  ///
  /// A scope passes the keyboard to the autofocused control inside it, and
  /// hands it back to whatever had it last when the window is brought forward
  /// again.
  late final FocusScopeNode _focus = FocusScopeNode(
    debugLabel: 'window:${widget.window.id}',
  );

  /// Geometry the current drag started from, plus where the pointer was. Both
  /// are needed so a drag tracks the pointer exactly instead of accumulating
  /// per-event deltas, which drift once a clamp kicks in.
  Rect? _dragFrom;
  Offset _dragOrigin = Offset.zero;

  @override
  void initState() {
    super.initState();
    _takeKeyboard();
  }

  @override
  void didUpdateWidget(WindowFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _takeKeyboard();
  }

  /// Claims the keyboard for this window, after the frame is in the tree.
  ///
  /// The commander's own root focus holds it otherwise, so the front window
  /// has to ask. Asking from `initState` looked like it worked and did not:
  /// the scope has no parent yet at that point, and the route's scope ended up
  /// with the keyboard instead — which is why neither Escape nor the default
  /// button reached the window.
  ///
  /// Requesting focus on a *scope* is not the same as taking it: if something
  /// inside has autofocused, or had the keyboard before the window was sent to
  /// the back, the scope passes it straight on to that.
  void _takeKeyboard() {
    if (!widget.active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }

    // The default button. Handled here rather than under the contents so it
    // works on a window with nothing to type into — see DeskWindow.onSubmit.
    // A field that wants Enter has already handled it by now.
    final submit = widget.window.onSubmit;
    if (submit != null &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      submit();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // --- Gestures -----------------------------------------------------------

  void _startDrag(Offset globalPosition) {
    _dragFrom = widget.window.bounds;
    _dragOrigin = globalPosition;
  }

  void _moveTo(Offset globalPosition) {
    final from = _dragFrom;
    if (from == null) return;
    final delta = globalPosition - _dragOrigin;
    widget.window.place(
      Rect.fromLTWH(
        from.left + delta.dx,
        from.top + delta.dy,
        from.width,
        from.height,
      ),
      widget.desk,
    );
  }

  void _resizeTo(_Grip grip, Offset globalPosition) {
    final from = _dragFrom;
    if (from == null) return;
    final delta = globalPosition - _dragOrigin;
    final min = widget.window.minSize;

    // Each edge stops where it would push the opposite one past the minimum,
    // so a grip pulled too far parks instead of turning the window inside out.
    var left = from.left;
    var top = from.top;
    var right = from.right;
    var bottom = from.bottom;
    if (grip.left) left = (left + delta.dx).clamp(0.0, right - min.width);
    if (grip.right) {
      right = (right + delta.dx).clamp(left + min.width, widget.desk.width);
    }
    if (grip.top) top = (top + delta.dy).clamp(0.0, bottom - min.height);
    if (grip.bottom) {
      bottom = (bottom + delta.dy).clamp(top + min.height, widget.desk.height);
    }

    widget.window.place(Rect.fromLTRB(left, top, right, bottom), widget.desk);
  }

  // --- Painting -----------------------------------------------------------

  /// The window's contents, and the same instance again once the window has
  /// been answered.
  ///
  /// **A window on its way out is a picture of a window.** Its contents belong
  /// to whoever opened it, and that code has its result already — by the time
  /// the journey back to the row is half over it has usually disposed the
  /// controllers its builder closes over, and calling the builder again threw
  /// *"A ValueNotifier was used after being disposed"*. Handing back the very
  /// same widget instance is what stops that: Flutter compares by identity and
  /// leaves the subtree alone, so nothing under here is built again.
  ///
  /// The same idea as `_FrozenListing` in `file_panel.dart` — what animates
  /// away is the thing as it last was, not a live copy of something that has
  /// already ended.
  Widget? _built;

  Widget _contents() {
    if (widget.leaving && _built != null) return _built!;
    return _built = Builder(builder: widget.window.builder);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final window = widget.window;
    final square = widget.fullScreen || window.maximized;
    final shape = square
        ? BorderRadius.zero
        : const BorderRadius.all(Radius.circular(9));

    // The desk shows the panels — and, with a backdrop effect, the desktop
    // behind them. A window has to blot both out to stay readable, so it is
    // painted nearly solid and blurs whatever is left.
    final translucent = theme.backdrop != WindowBackdrop.opaque;
    final surface = translucent
        ? theme.effectiveWindowBackground.withValues(alpha: 0.9)
        : theme.effectiveWindowBackground;

    // The window's own contour, and the rule under its title bar: one colour,
    // and the accent's while the window has the keyboard.
    final edge = widget.active
        ? theme.accentColor.withValues(alpha: 0.75)
        : theme.panelForeground.withValues(alpha: 0.18);

    Widget body = DecoratedBox(
      decoration: BoxDecoration(color: surface, borderRadius: shape),
      // Transparent Material: the frame paints its own surface, but the
      // controls inside still need a Material ancestor for ink and text.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            _titleBar(theme, edge),
            // The contents get a handle on the window they are inside, which
            // is how a form registers its default button.
            Expanded(
              child: DeskWindowScope(window: window, child: _contents()),
            ),
          ],
        ),
      ),
    );

    if (translucent) {
      body = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: body,
      );
    }

    // Two nodes doing two jobs. The outer one only listens — it never takes
    // the keyboard, so it stays above whatever inside the window does, and
    // Escape reaches it however deep the focus has gone. The inner scope is
    // what hands the keyboard on to the control the window wants filled in.
    Widget frame = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: FocusScope(
        node: _focus,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: shape,
            boxShadow: square
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: widget.active ? 0.45 : 0.3,
                      ),
                      blurRadius: widget.active ? 26 : 14,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          // **In front of the window, not behind it.** As a background
          // decoration the contour was painted first and the title bar — an
          // opaque strip the full width of the window — went straight over the
          // top of it, so the frame began below the title instead of going
          // round it. Measured: orange at the left edge below the title,
          // nothing at all beside the title or above it.
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: shape,
              border: Border.all(color: edge),
            ),
            child: ClipRRect(borderRadius: shape, child: body),
          ),
        ),
      ),
    );

    if (!square && window.resizable) {
      frame = Stack(
        children: [
          Positioned.fill(child: frame),
          ..._grips(),
        ],
      );
    }

    // Anywhere in the window brings it forward; the press still reaches
    // whatever was clicked.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => widget.onFocus(),
      child: frame,
    );
  }

  Widget _titleBar(AppearanceSettings theme, Color edge) {
    final foreground = theme.effectiveWindowHeaderForeground.withValues(
      alpha: widget.active ? 1 : 0.65,
    );

    Widget label = Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Row(
        children: [
          if (widget.window.icon != null) ...[
            // The strip's own ink, not the accent: the strip is the cursor's
            // colour and the cursor is the user's to choose, so an accent mark
            // on it is one colour over another with nothing keeping them
            // apart — orange on orange, the first time somebody sets the
            // cursor to the accent.
            Icon(widget.window.icon, size: 14, color: foreground),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(
              widget.window.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: theme.scaled(12.5),
                fontWeight: theme.uiWeightFor(FontWeight.w600),
                color: foreground,
              ),
            ),
          ),
        ],
      ),
    );

    // Only the label strip drags. Wrapping the buttons too would put them
    // behind a double-tap recogniser, and every click on Close would then
    // wait out the double-tap timeout before anything happened.
    if (!widget.fullScreen) {
      label = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanDown: (d) => _startDrag(d.globalPosition),
        onPanUpdate: (d) => _moveTo(d.globalPosition),
        onDoubleTap: () => widget.window.toggleMaximized(widget.desk),
        child: label,
      );
    }

    return Container(
      height: WindowFrame.titleHeight,
      padding: const EdgeInsets.only(right: 2),
      decoration: BoxDecoration(
        color: theme.effectiveWindowHeaderBackground.withValues(
          alpha: theme.backdrop == WindowBackdrop.opaque ? 1 : 0.94,
        ),
        // The same colour as the contour round the window, and one pixel of
        // it. What divides the title from the form is the frame's own line
        // carried across, rather than a second hairline in a colour of its own
        // — it used to be `panelForeground` at 0.12, which measured 32,36,44
        // against the frame's 188,89,21.
        border: Border(bottom: BorderSide(color: edge)),
      ),
      child: Row(
        children: [
          Expanded(child: label),
          if (!widget.fullScreen)
            _FrameButton(
              icon: widget.window.maximized
                  ? Icons.filter_none_outlined
                  : Icons.crop_square,
              iconSize: widget.window.maximized ? 11 : 13,
              color: foreground,
              tooltip: widget.window.maximized ? tr('Restore') : tr('Maximise'),
              onPressed: () => widget.window.toggleMaximized(widget.desk),
            ),
          _FrameButton(
            icon: Icons.close,
            color: foreground,
            tooltip: tr('Close'),
            danger: true,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  /// The eight edge and corner strips. They sit inside the window, over the
  /// border, which is where the pointer expects to find them.
  List<Widget> _grips() {
    const thickness = WindowFrame._gripSize;
    const corner = thickness * 2;

    return [
      _grip(
        const _Grip(top: true),
        SystemMouseCursors.resizeUpDown,
        left: corner,
        right: corner,
        top: 0,
        height: thickness,
      ),
      _grip(
        const _Grip(bottom: true),
        SystemMouseCursors.resizeUpDown,
        left: corner,
        right: corner,
        bottom: 0,
        height: thickness,
      ),
      _grip(
        const _Grip(left: true),
        SystemMouseCursors.resizeLeftRight,
        top: corner,
        bottom: corner,
        left: 0,
        width: thickness,
      ),
      _grip(
        const _Grip(right: true),
        SystemMouseCursors.resizeLeftRight,
        top: corner,
        bottom: corner,
        right: 0,
        width: thickness,
      ),
      _grip(
        const _Grip(top: true, left: true),
        SystemMouseCursors.resizeUpLeft,
        top: 0,
        left: 0,
        width: corner,
        height: corner,
      ),
      _grip(
        const _Grip(top: true, right: true),
        SystemMouseCursors.resizeUpRight,
        top: 0,
        right: 0,
        width: corner,
        height: corner,
      ),
      _grip(
        const _Grip(bottom: true, left: true),
        SystemMouseCursors.resizeDownLeft,
        bottom: 0,
        left: 0,
        width: corner,
        height: corner,
      ),
      _grip(
        const _Grip(bottom: true, right: true),
        SystemMouseCursors.resizeDownRight,
        bottom: 0,
        right: 0,
        width: corner,
        height: corner,
      ),
    ];
  }

  Widget _grip(
    _Grip grip,
    MouseCursor cursor, {
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
  }) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanDown: (d) => _startDrag(d.globalPosition),
          onPanUpdate: (d) => _resizeTo(grip, d.globalPosition),
        ),
      ),
    );
  }
}

/// Which edges a resize drag moves.
class _Grip {
  const _Grip({
    this.left = false,
    this.top = false,
    this.right = false,
    this.bottom = false,
  });

  final bool left;
  final bool top;
  final bool right;
  final bool bottom;
}

/// A title-bar button, sized for the smaller internal title bar rather than the
/// application one.
class _FrameButton extends StatefulWidget {
  const _FrameButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 13,
    this.danger = false,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;

  /// Close gets the familiar red hover treatment.
  final bool danger;

  @override
  State<_FrameButton> createState() => _FrameButtonState();
}

class _FrameButtonState extends State<_FrameButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final background = !_hovered
        ? Colors.transparent
        : widget.danger
        ? const Color(0xFFC42B1C)
        : widget.color.withValues(alpha: 0.14);

    return Hint(
      message: widget.tooltip,
      wait: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 34,
            height: WindowFrame.titleHeight,
            alignment: Alignment.center,
            color: background,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hovered && widget.danger ? Colors.white : widget.color,
            ),
          ),
        ),
      ),
    );
  }
}
