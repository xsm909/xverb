import 'package:flutter/widgets.dart';

import '../motion.dart';

/// One thing replacing another in the same place, without a blink.
///
/// **Rule number two: nothing happens without animation.** A panel that swaps
/// its contents in a single frame reads as a fault — the eye is very good at
/// noticing that something changed and very bad at seeing *what*. Fading the
/// old out and the new in says "this is now that", and costs a fifth of a
/// second nobody is waiting on.
///
/// It fades **through**, not across: the old content is shown until the fade
/// reaches the bottom, and only then is the new content built. Two copies alive
/// at once is what a cross-fade means, and two copies of a reading is two
/// scrollables sharing one [ScrollController] — which Flutter refuses outright.
/// This way there is only ever one child in the tree.
class FadeThrough<T> extends StatefulWidget {
  const FadeThrough({
    super.key,
    required this.data,
    required this.builder,
    this.onSwap,
    this.duration,
  });

  /// What is being shown. When this changes — by `==` — the fade runs.
  final T data;

  /// Draws whatever is being shown *now*, which during the first half of a
  /// change is still the previous value.
  final Widget Function(BuildContext context, T data) builder;

  /// Called at the bottom of the fade, as the new value goes in. Where a
  /// reading resets its scroll: arriving halfway down the next thing is not
  /// arriving at it.
  final VoidCallback? onSwap;

  /// Left null this takes [kContentSwapDuration], scaled to the speed the user
  /// has set — which is the right answer everywhere until something proves
  /// otherwise.
  final Duration? duration;

  @override
  State<FadeThrough<T>> createState() => _FadeThroughState<T>();
}

class _FadeThroughState<T> extends State<FadeThrough<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    value: 1,
  );

  /// What is on screen, which lags [FadeThrough.data] by half a fade.
  late T _shown = widget.data;

  Duration get _half {
    final whole = widget.duration ?? motionOf(context, kContentSwapDuration);
    return whole ~/ 2;
  }

  @override
  void didUpdateWidget(FadeThrough<T> old) {
    super.didUpdateWidget(old);
    if (widget.data == old.data) return;

    final half = _half;
    if (half == Duration.zero) {
      // Animation is off. Not "instant anyway": off means off, and a fade
      // running at zero length would still cost a rebuild for nothing.
      setState(() => _shown = widget.data);
      widget.onSwap?.call();
      return;
    }

    _fade.duration = half;
    _fade.reverse().then((_) {
      if (!mounted) return;
      setState(() => _shown = widget.data);
      widget.onSwap?.call();
      _fade.forward();
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade.drive(CurveTween(curve: kBothCurve)),
      child: widget.builder(context, _shown),
    );
  }
}
