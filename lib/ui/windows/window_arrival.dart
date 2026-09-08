import 'package:flutter/widgets.dart';

import '../../core/settings/appearance_settings.dart';
import '../motion.dart';

/// A window growing out of the row the cursor was on, and going back into it.
///
/// **What travels is a rectangle.** The window starts as a bar of exactly the
/// cursor row's width and height, and turns into the dialog on the way across
/// the desk — so what the eye follows is the row opening into the question
/// about it. Growing from a point would have said "something appeared near
/// there", which is weaker and less true. Closing is the same journey
/// backwards.
///
/// Two ways of saying it, and the setting chooses — see [WindowArriveMotion].
/// The window arrives whole and fades in, or its title bar arrives first and
/// the form unfolds out from under it. One controller and one length either
/// way: two animations describing one event must not have two timings.
///
/// The cursor stays where it is throughout. The listing draws its own mark and
/// nothing here touches it — a window flying out of a panel must not cost the
/// reader their place in it.
class WindowArrival extends StatefulWidget {
  const WindowArrival({
    super.key,
    required this.from,
    required this.bounds,
    required this.head,
    required this.motion,
    required this.leaving,
    required this.onLeft,
    required this.child,
  });

  /// Where the window comes out of, in the layer's own coordinates. Null when
  /// nothing could say — a plugin opening a window by itself — and then it
  /// arrives about its own centre at [kWindowArriveScale], which claims
  /// nothing about where it came from.
  final Rect? from;

  /// Where the window settles, in the same coordinates. The child is laid out
  /// at this size throughout: the movement is a transform and a clip, so
  /// nothing inside the window is asked to lay itself out at a size it will
  /// never be at.
  final Rect bounds;

  /// Height of the window's title strip — what the row turns into.
  final double head;

  /// Which of the two journeys this is — see [WindowArriveMotion].
  final WindowArriveMotion motion;

  /// Whether this window has been answered and is on its way back.
  final bool leaving;

  /// Called once the journey back is over, so the layer can stop drawing it.
  final VoidCallback onLeft;

  final Widget child;

  @override
  State<WindowArrival> createState() => _WindowArrivalState();
}

class _WindowArrivalState extends State<WindowArrival>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: kWindowArriveDuration),
  );

  bool _started = false;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && widget.leaving) _leave();
    });
  }

  /// Tells the layer to stop drawing this window — once, and never inside a
  /// build.
  ///
  /// Both of those were paid for. Setting the controller where it already is
  /// reports `dismissed` a second time, and the arrival at zero length reports
  /// it from inside `didChangeDependencies` — where the answer went straight
  /// into `notifyListeners` and Flutter refused: *"setState() or
  /// markNeedsBuild() called during build"*.
  void _leave() {
    if (_left) return;
    _left = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onLeft());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here rather than in initState: the length comes from the settings, and
    // those are read from the tree.
    _sync();
  }

  @override
  void didUpdateWidget(WindowArrival old) {
    super.didUpdateWidget(old);
    if (old.leaving != widget.leaving) _sync();
  }

  void _sync() {
    final length = motionOf(context, kWindowArriveDuration);
    _controller.duration = length;

    if (widget.leaving) {
      if (length == Duration.zero) {
        // Off means off, not a one-millisecond version of it: no controller
        // run at all, and the window is gone in the frame it was closed in.
        _leave();
        return;
      }
      // A window closed the moment it opened has nothing to reverse —
      // `reverse()` from zero is already dismissed and it would stay on the
      // desk for ever. It was open: start from open.
      if (!_started) {
        _started = true;
        _controller.value = 1;
      }
      _controller.reverse();
      return;
    }

    if (length == Duration.zero) {
      _controller.value = 1;
      _started = true;
    } else if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Where the journey starts, in the child's own coordinates.
  ///
  /// The row it was asked at — or, when nothing could say, a smaller copy of
  /// the thing that is about to travel, in its own place, which claims no
  /// journey that was not made.
  Rect _from(Rect target) {
    final origin = widget.from;
    if (origin != null) return origin.shift(-widget.bounds.topLeft);
    return Rect.fromCenter(
      center: target.center,
      width: target.width * kWindowArriveScale,
      height: target.height * kWindowArriveScale,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final bounds = widget.bounds;
        final t = _controller.value;
        final curve = widget.leaving ? kLeavingCurve : kArrivingCurve;
        final unfolds = widget.motion == WindowArriveMotion.unfold;

        // What travels, and so what the transform is measured against.
        // Unfolding, it is the title strip; whole, it is the window itself.
        final travels = unfolds
            ? Rect.fromLTWH(0, 0, bounds.width, widget.head)
            : Rect.fromLTWH(0, 0, bounds.width, bounds.height);

        final Rect landed;
        final double shown;
        final double fade;

        if (!unfolds) {
          // One act: the row's rectangle becomes the whole window, everything
          // in it arriving together — and it fades, because a window squashed
          // into the height of one row has its buttons on top of its title and
          // is not a thing to be shown.
          final e = curve.transform(t.clamp(0, 1));
          landed = Rect.lerp(_from(travels), travels, e)!;
          shown = bounds.height;
          fade = e;
        } else if (t <= kWindowUnfoldAt) {
          // Act one: the row travels and becomes the title bar. The whole
          // window is transformed so that its title strip lands on the
          // travelling rectangle, and the clip keeps only that strip — the
          // form is along for the ride, squashed and hidden, until it has
          // somewhere to be. No fade: the strip is the cursor's own colour and
          // begins life indistinguishable from the cursor.
          final e = curve.transform((t / kWindowUnfoldAt).clamp(0, 1));
          landed = Rect.lerp(_from(travels), travels, e)!;
          shown = widget.head;
          fade = 1;
        } else {
          // Act two: the transform is done with, and the clip opens downwards.
          // Unfolded rather than scaled, because a form stretched out of a
          // strip is a claim that the buttons grew, and they did not: they
          // were always that size and there was not yet room for them.
          final e = curve.transform(
            ((t - kWindowUnfoldAt) / (1 - kWindowUnfoldAt)).clamp(0, 1),
          );
          landed = travels;
          shown = widget.head + (bounds.height - widget.head) * e;
          fade = 1;
        }

        // **The clip is let out once the window has arrived.**
        //
        // It is a square the size of the window, and while it stayed tight it
        // cut the window's own shadow off at its edges: no halo anywhere, and a
        // hard grey wedge in each corner where the shadow filled the space
        // outside the rounding and was then squared off. It showed on the
        // modals first and was every internal window. Measured at 8x from the
        // running application, which is what showed the wedge to be square
        // outside and rounded inside, and so a clip rather than a missing
        // round.
        //
        // **Let out rather than taken away**, and that is not tidiness: a
        // wrapper that comes and goes changes the shape of the tree under it,
        // Flutter rebuilds the subtree, and the window loses the keyboard the
        // moment it lands — measured too, by two focus tests that went red the
        // first time this was written as "no clip at rest".
        final settled = shown >= bounds.height - 0.01;
        final clip = Rect.fromLTRB(
          -kWindowShadowRoom,
          -kWindowShadowRoom,
          bounds.width + kWindowShadowRoom,
          shown + (settled ? kWindowShadowRoom : 0),
        );

        // The clip goes **inside** the transform, in the window's own
        // coordinates. Outside it would be measured in the parent's, where the
        // travelling bar is not — over the cursor row, halfway across the desk
        // — and the whole of act one would be clipped away.
        return Opacity(
          opacity: fade.clamp(0.0, 1.0),
          child: Transform(
            alignment: Alignment.topLeft,
            transform: Matrix4.identity()
              ..translateByDouble(landed.left, landed.top, 0, 1)
              ..scaleByDouble(
                travels.width == 0 ? 1.0 : landed.width / travels.width,
                travels.height == 0 ? 1.0 : landed.height / travels.height,
                1,
                1,
              ),
            child: ClipRect(clipper: _Unfolded(clip), child: child),
          ),
        );
      },
    );
  }
}

/// How far outside itself a window is allowed to paint once it has arrived:
/// its shadow, and nothing else. A 26-pixel blur dropped 8 down, with room to
/// spare — see `WindowFrame`.
const double kWindowShadowRoom = 60;

/// How much of the window there is room for yet, measured from its top.
///
/// A clipper rather than a `SizedBox`: the window is laid out at its full size
/// from the first frame — every control already where it will be — and this
/// only says how much of it has been let out.
class _Unfolded extends CustomClipper<Rect> {
  const _Unfolded(this.rect);

  final Rect rect;

  @override
  Rect getClip(Size size) => rect;

  @override
  bool shouldReclip(_Unfolded old) => old.rect != rect;
}
