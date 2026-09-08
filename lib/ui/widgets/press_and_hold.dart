import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// The right button, doing two things depending on how long it is held.
///
/// A short click opens the app's own menu, which is the one worth having: it
/// is searchable, it is keyboard-driven, and it lists what this app can do.
/// Holding gives the desktop's menu instead, for the times the answer is an
/// archiver or a version control client — things a file manager should reach
/// rather than reimplement.
///
/// The hold is shown while it happens. A gesture that only pays off after a
/// second and a half is indistinguishable from a wedged application unless
/// something says otherwise, so a ring fills under the pointer and the menu
/// opens when it closes.
/// The devices for which holding is a stand-in for the right button.
///
/// A finger and a stylus have no second button, so a hold is the only way they
/// can ask for a menu. A mouse has one already — and on the desktop a held left
/// button is the beginning of a drag, so a long-press recogniser that answers
/// to a mouse takes the gesture away from dragging and pops a menu nobody asked
/// for. Holding the button on a row for half a second did exactly that.
///
/// Set on the detector rather than the callback, because that is where Flutter
/// puts it: any detector mixing a hold with a mouse gesture has to be split in
/// two so the mouse half keeps every device.
const Set<PointerDeviceKind> kMenuHoldDevices = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

class PressAndHold extends StatefulWidget {
  const PressAndHold({
    super.key,
    required this.child,
    required this.onMenu,
    this.onHold,
    this.behavior = HitTestBehavior.deferToChild,
  });

  final Widget child;

  /// A press that ended before [holdDuration]. The offset is global.
  final ValueChanged<Offset> onMenu;

  /// The press was held long enough. Null means there is nothing to hold for,
  /// and the press behaves as a plain click — no ring, no waiting.
  final ValueChanged<Offset>? onHold;

  final HitTestBehavior behavior;

  /// Long enough to be deliberate, short enough not to feel broken.
  ///
  /// A second and a half was both: nobody holds a button that long by
  /// accident, and nobody waits that long on purpose either.
  static const Duration holdDuration = Duration(milliseconds: 600);

  @override
  State<PressAndHold> createState() => _PressAndHoldState();
}

class _PressAndHoldState extends State<PressAndHold>
    with SingleTickerProviderStateMixin {
  /// Built in [initState], not lazily.
  ///
  /// As a `late final` initialiser it was created by whoever touched it first,
  /// and for a row nobody ever pressed that was `dispose` — where making a
  /// ticker needs a `TickerMode` that is no longer reachable, so scrolling a
  /// listing far enough threw.
  late final AnimationController _progress;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(
      vsync: this,
      duration: PressAndHold.holdDuration,
    );
  }

  OverlayEntry? _ring;
  Offset _origin = Offset.zero;

  /// Set once the hold has paid off, so the release that follows does not then
  /// open the app's menu on top of the one the shell just showed.
  bool _held = false;

  @override
  void dispose() {
    _removeRing();
    _progress.dispose();
    super.dispose();
  }

  void _down(Offset globalPosition) {
    _origin = globalPosition;
    _held = false;

    if (widget.onHold == null) return;

    _showRing();
    _progress
      ..stop()
      ..value = 0
      ..forward().then((_) {
        if (!mounted || _ring == null) return;
        _held = true;
        _removeRing();
        widget.onHold!(_origin);
      });
  }

  void _up() {
    if (_held) {
      _held = false;
      return;
    }
    _cancel();
    widget.onMenu(_origin);
  }

  void _cancel() {
    _progress.stop();
    _removeRing();
  }

  void _showRing() {
    _removeRing();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    final entry = OverlayEntry(
      builder: (context) => _HoldRing(origin: _origin, progress: _progress),
    );
    _ring = entry;
    overlay.insert(entry);
  }

  void _removeRing() {
    _ring?.remove();
    _ring = null;
  }

  /// Which pointer is being held, so a second one does not end the first.
  int? _pointer;

  void _pointerDown(PointerDownEvent event) {
    if (event.buttons != kSecondaryButton || _pointer != null) return;
    _pointer = event.pointer;
    _down(event.position);
  }

  void _pointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _up();
  }

  void _pointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _cancel();
  }

  /// A press that wanders off is a drag, not a menu.
  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _origin).distance <= kTouchSlop) return;
    _pointer = null;
    _cancel();
  }

  @override
  Widget build(BuildContext context) {
    // Raw pointer events rather than a gesture, because the gesture arena is
    // the wrong shape for this: holding the button lets a long-press
    // recogniser elsewhere in the tree claim the pointer, which cancels the
    // tap and takes the hold with it. Nothing arbitrates a Listener.
    return Listener(
      behavior: widget.behavior == HitTestBehavior.deferToChild
          ? HitTestBehavior.deferToChild
          : widget.behavior,
      onPointerDown: _pointerDown,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerCancel,
      onPointerMove: _pointerMove,
      child: GestureDetector(
        behavior: widget.behavior,
        // Claims the right button in the arena without doing anything with it.
        // The Listener above does the work, but a Listener arbitrates nothing,
        // so without this an ancestor's own secondary handler — the panel
        // background's, under every row — fires as well and the menu is asked
        // for twice.
        //
        // Every device kind: this is the mouse's own claim, and it is the one
        // half of this widget that a mouse is supposed to reach.
        onSecondaryTapDown: (_) {},
        child: GestureDetector(
          behavior: widget.behavior,
          // A finger has no second button, so it holds for the app's menu the
          // way it always has. The system menu stays a mouse gesture.
          supportedDevices: kMenuHoldDevices,
          onLongPressStart: (details) => widget.onMenu(details.globalPosition),
          child: widget.child,
        ),
      ),
    );
  }
}

/// The filling ring under the pointer.
class _HoldRing extends StatelessWidget {
  const _HoldRing({required this.origin, required this.progress});

  final Offset origin;
  final Animation<double> progress;

  static const double _size = 34;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;

    return Positioned(
      left: origin.dx - _size / 2,
      top: origin.dy - _size / 2,
      width: _size,
      height: _size,
      // Never in the way of the pointer it is drawn under.
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: progress,
          builder: (context, _) => CircularProgressIndicator(
            value: progress.value,
            strokeWidth: 3,
            color: accent,
            backgroundColor: accent.withValues(alpha: 0.25),
          ),
        ),
      ),
    );
  }
}
