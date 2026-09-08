import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';

import '../../core/settings/appearance_settings.dart';
import '../motion.dart';
import '../plugins/plugin_table.dart' show appearanceOf;

/// What something says about itself when the pointer rests on it.
///
/// Item 68: one hint element, reused everywhere, arriving and leaving through
/// an animation. There was none — everything used Material's `Tooltip`, which
/// is a different application's idea of a hint: its own palette, its own
/// timing, its own corner radius, and a fade this application never asked
/// for.
///
/// This one is the application's: its own pair of colours, the type size the
/// interface is set in, and the same curves everything else moves on.
///
/// **The pair is its own and it is a note, not a shade of the palette** — light
/// yellow with dark blue on it. Until then the bubble was the panel's ink laid
/// a tenth over the *header's* fill and written in the panel's ink: a fill from
/// one place and an ink from another, which on some palettes came out as a
/// bubble you had to look for.
///
/// **It appears near the pointer and never under it.** A hint drawn where the
/// mouse is covers the very thing it is about, so it sits above what it
/// describes, or below it where there is no room above.
class Hint extends StatefulWidget {
  const Hint({
    super.key,
    required this.message,
    required this.child,
    this.wait = const Duration(milliseconds: 500),
  });

  /// What to say. Empty means there is nothing to say, and then this is not a
  /// hint at all — it is its child, with nothing watching the pointer.
  final String message;

  final Widget child;

  /// How long the pointer has to rest before it appears.
  ///
  /// Long enough that crossing a row of buttons does not set off five of them,
  /// short enough that somebody who stopped to ask is not left waiting.
  final Duration wait;

  @override
  State<Hint> createState() => _HintState();
}

class _HintState extends State<Hint> {
  OverlayEntry? _shown;
  Timer? _pending;

  /// Whether the bubble should be showing. The bubble watches this rather than
  /// being rebuilt, because an overlay entry that is taken away cannot animate
  /// on its way out — it is simply not there any more.
  final ValueNotifier<bool> _open = ValueNotifier(false);

  /// The wait for the leaving to finish before the entry is actually taken
  /// away. Cancelled if the pointer comes back, which is why the bubble is not
  /// rebuilt from nothing every time somebody crosses it twice.
  Timer? _removing;

  @override
  void dispose() {
    _pending?.cancel();
    _removing?.cancel();
    // Straight away here: there is nobody left to watch the animation, and an
    // overlay entry outliving the widget that put it there is a leak.
    _shown?.remove();
    _shown = null;
    _open.dispose();
    super.dispose();
  }

  void _give() {
    if (!mounted) return;
    // Coming back before it has finished going: keep the bubble that is there
    // and turn it round.
    _removing?.cancel();
    _removing = null;
    if (_shown != null) {
      _open.value = true;
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (box == null || !box.hasSize || overlay == null) return;

    final theme = appearanceOf(context, watch: false);
    final anchor = box.localToGlobal(Offset.zero) & box.size;

    final entry = OverlayEntry(
      builder: (context) => _HintBubble(
        message: widget.message,
        anchor: anchor,
        theme: theme,
        open: _open,
      ),
    );
    overlay.insert(entry);
    _shown = entry;
    _open.value = true;
  }

  /// **It goes the way it came**, which is rule number two: everything moves,
  /// and a hint moves quickly. It used to be removed from the overlay outright,
  /// so it arrived over a tenth of a second and vanished in one frame.
  void _take() {
    if (_shown == null) return;
    _open.value = false;

    // Scaled like everything else, so a speed of zero means it is simply gone
    // — and then there is nothing to wait for.
    final leaving = mounted
        ? appearanceOf(context, watch: false).animated(kHintLeaveDuration)
        : Duration.zero;
    if (leaving == Duration.zero) {
      _shown?.remove();
      _shown = null;
      return;
    }

    _removing?.cancel();
    _removing = Timer(leaving, () {
      _removing = null;
      _shown?.remove();
      _shown = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.message.isEmpty) return widget.child;

    // Said to the screen reader as well as drawn for the pointer. Material's
    // `Tooltip` did this much, and the buttons that gave theirs up for this one
    // must not have gone quiet in the swap: an icon with no word attached is a
    // button that only exists for people who can see it.
    return Semantics(
      label: widget.message,
      child: MouseRegion(
        onEnter: (_) {
          _pending?.cancel();
          _pending = Timer(widget.wait, _give);
        },
        onExit: (_) {
          _pending?.cancel();
          _take();
        },
        child: widget.child,
      ),
    );
  }
}

/// The bubble itself, which fades and rises into place.
///
/// Its own widget so it can animate on the way in: an overlay entry is built
/// once and cannot start an animation by existing.
class _HintBubble extends StatefulWidget {
  const _HintBubble({
    required this.message,
    required this.anchor,
    required this.theme,
    required this.open,
  });

  final String message;
  final Rect anchor;
  final AppearanceSettings theme;

  /// Turned off a moment before the entry is taken away, so the bubble has
  /// something to animate towards rather than disappearing between frames.
  final ValueListenable<bool> open;

  @override
  State<_HintBubble> createState() => _HintBubbleState();
}

class _HintBubbleState extends State<_HintBubble> {
  /// False for exactly one frame, so the arrival has something to move *from*.
  /// After that the notifier decides.
  bool _arrived = false;

  @override
  void initState() {
    super.initState();
    widget.open.addListener(_onOpen);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _arrived = true);
    });
  }

  void _onOpen() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.open.removeListener(_onOpen);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final ink = theme.hintForeground;

    // **Which way it drifts in, and nothing else.** The bubble's height is not
    // known until it has been laid out — it is one to three lines of a size the
    // user chooses — so where it *lands* is settled by [_HintPlacement], which
    // is handed the real thing. This is the tallest it could be, used only to
    // guess which way it will end up so the movement can point that way; guess
    // wrong and a few pixels of drift go the other way, which is all.
    //
    // It used to settle the position too, as `anchor.top - 30`. Thirty is the
    // height of nothing in particular: a bubble taller than that was drawn over
    // the row above the one it belongs to — reported on Settings → Fonts, where
    // the hint for *Interface font family* sat on top of *Font size*.
    final tallest = 3 * (theme.fontSize + 4) + 12;
    final above = widget.anchor.top - tallest - _hintGap >= _hintMargin;

    // Nought on the first frame and while it is going; one in between.
    final showing = _arrived && widget.open.value;
    final into = showing ? 1.0 : 0.0;
    // Going is shorter than coming — see [kHintLeaveDuration].
    final length = motionOf(
      context,
      widget.open.value ? kHintDuration : kHintLeaveDuration,
    );

    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _HintPlacement(widget.anchor),
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: into,
            duration: length,
            curve: showing ? kArrivingCurve : kLeavingCurve,
            child: AnimatedSlide(
              // A hand's width of movement, towards what it is about. The
              // movement says where it came from, which is the rule every other
              // animation here follows.
              offset: Offset(0, (1 - into) * (above ? 0.3 : -0.3)),
              duration: length,
              curve: showing ? kArrivingCurve : kLeavingCurve,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    // **Opaque, where every other surface takes the backdrop.**
                    // A hint is a note laid over the interface, and the thing
                    // showing through a translucent one is the very text it is
                    // covering: on the settings page over a see-through window
                    // the bubble and the two rows underneath it were legible
                    // as one another and none of them was readable. The
                    // backdrop is for surfaces you are meant to look *at*, and
                    // this is one you are meant to look *through* to nothing.
                    color: theme.hintBackground,
                    borderRadius: BorderRadius.circular(4),
                    // Not a third setting: the edge is the ink at a fifth, the
                    // way every other edge in the application is.
                    border: Border.all(color: ink.withValues(alpha: 0.18)),
                  ),
                  child: Text(
                    widget.message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ink,
                      fontSize: theme.fontSize - 1,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How far the bubble stands off the thing it is about, and how close it may
/// come to the edge of the window.
const double _hintGap = 8;
const double _hintMargin = 6;

/// Puts the bubble where it fits, knowing how big it actually is.
///
/// A layout delegate rather than arithmetic in `build`, because the height is
/// the thing that was being guessed at and it is only known here: the bubble is
/// one to three lines, at a size the user chooses, wrapped at 420 wide.
class _HintPlacement extends SingleChildLayoutDelegate {
  const _HintPlacement(this.anchor);

  /// What the hint is about, in the overlay's coordinates.
  final Rect anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Above the thing it is about and clear of it by a gap — never *on* it,
    // and never on whatever is above it either. Below when there is no room
    // above, which is the case near the top of the window.
    var top = anchor.top - childSize.height - _hintGap;
    if (top < _hintMargin) top = anchor.bottom + _hintGap;

    // Held inside the window on both axes: a hint half off the edge is half a
    // hint. The right-hand side needs the bubble's own width, which is the
    // other half of what the old arithmetic had no way of knowing.
    return Offset(
      _within(anchor.left, childSize.width, size.width),
      _within(top, childSize.height, size.height),
    );
  }

  /// [at], kept far enough inside [room] for something [extent] long.
  ///
  /// A bubble wider or taller than the room it is in gets the margin and no
  /// clamp — `clamp` throws when the low bound is above the high one, and a
  /// window narrower than a hint is a window, not a crash.
  static double _within(double at, double extent, double room) {
    final last = room - extent - _hintMargin;
    return last <= _hintMargin ? _hintMargin : at.clamp(_hintMargin, last);
  }

  @override
  bool shouldRelayout(_HintPlacement old) => old.anchor != anchor;
}
