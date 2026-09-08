import 'dart:async';

import 'package:flutter/widgets.dart';

import '../motion.dart';

/// One thing being looked at replacing another, **without a moment of neither**.
///
/// The plain cross-fade this replaces started the moment the new file's *bytes*
/// arrived — which is not the moment there is anything to draw. A photograph is
/// decoded after that, and until it is, the arriving view paints nothing: so
/// the old picture faded out into the page's own colour and the new one turned
/// up in it, with a moment of grey between them. The answer is to fade the new
/// picture in over the old one and only then take the old one away, which is
/// exactly what this does.
///
/// **So the new one is built where it will be shown, and kept invisible.** It
/// lays out, it decodes, it says when it can paint; only then does it fade up
/// over the old, and only when it is covering does the old leave the tree. At
/// no point is the page's background between two photographs.
///
/// **Walking fast is the case that decides the shape of it.** Holding an arrow
/// down offers files faster than they can be read, and a swap started for each
/// of them would be a stack of half-drawn pictures. So one swap runs at a time
/// and only the *newest* offer is kept: what you see while walking quickly is
/// the last picture that finished, and when you stop, the file you stopped on.

/// What an arriving view says about itself.
///
/// Both are dispatched by the view being *built*, and the swap only listens to
/// the one it is waiting for — see [ContentSwap].
sealed class ContentNotification extends Notification {
  const ContentNotification();
}

/// "I have nothing to show yet, and I will say when I do."
///
/// **Opt-in on purpose.** A view that says nothing is taken to be ready at
/// once, which is right for everything whose content is its text; only what
/// decodes — a photograph, a drawing, a model — has a wait worth covering, and
/// only that has to say so.
class ContentPending extends ContentNotification {
  const ContentPending();
}

/// "There is something in me to draw now."
class ContentPainted extends ContentNotification {
  const ContentPainted();
}

/// Whether the subtree reading this is the one arriving, rather than the one
/// on screen.
///
/// **What it is for is chrome, and it is [ContentSwap]'s other half.** Two
/// pictures crossing is one picture; two *toolbars* crossing is a toolbar
/// blinking, because the panel is translucent and two of them stacked are
/// darker than one. The arriving view therefore draws its picture and none of
/// its furniture, and the one being left keeps its own until it goes. The two
/// are identical and in the same place, so nothing about them changes on the
/// exchange.
class Arriving extends InheritedWidget {
  const Arriving({super.key, required this.arriving, required super.child});

  final bool arriving;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Arriving>()?.arriving ?? false;

  @override
  bool updateShouldNotify(Arriving old) => old.arriving != arriving;
}

class ContentSwap extends StatefulWidget {
  const ContentSwap({super.key, required this.child, this.duration});

  /// What to show. **Its key is what decides whether anything happens**: same
  /// key, no swap; a new key, a swap. Give it a key that changes when the
  /// content does and not when the file does — during a walk the file changes
  /// the moment the arrow is pressed, and the picture a good deal later.
  final Widget child;

  /// Left null this takes [kContentSwapDuration] at the speed the user set.
  final Duration? duration;

  /// How long a view that says nothing at all is given before it is taken to
  /// be ready. Two frames or so: long enough for [ContentPending] to arrive
  /// from the view's first frame, short enough that a page of text does not
  /// wait on a picture's account.
  static const Duration grace = Duration(milliseconds: 32);

  /// And how long one that *did* promise is waited for before the swap goes
  /// ahead regardless. Nothing should ever reach this — a view that cannot
  /// read its file says so with a message, which is something to draw — it is
  /// here so that a plugin that forgets to answer costs a slow swap rather
  /// than a page frozen on the file before it.
  static const Duration patience = Duration(seconds: 5);

  @override
  State<ContentSwap> createState() => _ContentSwapState();
}

class _ContentSwapState extends State<ContentSwap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(vsync: this);

  /// The one arriving, coming up over the one on screen — and **all the way
  /// up before the other one begins to leave**. Anything less and the two of
  /// them together are thinner than either was alone, which lets the page
  /// through in the middle: the very dip this file exists to remove.
  late final Animation<double> _arriving = CurvedAnimation(
    parent: _fade,
    curve: const Interval(0, _holds, curve: kArrivingCurve),
  );

  /// **The one being left holds its ground until the last of it, and then it
  /// goes — it does not simply stop being there.** Two pictures crossing at
  /// half opacity each are together dimmer than either was alone, so this
  /// stays at one for most of the exchange; but a photograph is only covered
  /// where the next one *is*, and a wide one followed by a tall one stands out
  /// on both sides of it. Taken away in one frame, those two edges vanish
  /// while the middle fades, and the difference is visible.
  late final Animation<double> _leaving = Tween<double>(begin: 1, end: 0)
      .animate(
        CurvedAnimation(parent: _fade, curve: const Interval(_holds, 1)),
      );

  /// How much of the exchange the one arriving spends coming up, and
  /// therefore how much of it the one being left spends at full strength. What
  /// fades out over the rest is only what the new one was never going to
  /// cover: a wide picture's two edges under a tall one.
  static const double _holds = 0.7;

  /// What is on screen, whole. Never taken away until something covers it.
  Widget? _shown;

  /// What is being prepared, and then faded up over [_shown].
  Widget? _next;

  /// Offered while a fade was running. Only the newest is kept: the ones
  /// passed over were never drawn, so nobody saw them go.
  Widget? _queued;

  /// Whether [_next] has said it needs a moment.
  bool _promised = false;
  Timer? _waiting;

  @override
  void initState() {
    super.initState();
    _shown = widget.child;
    _fade.addStatusListener((status) {
      if (status == AnimationStatus.completed) _arrived();
    });
  }

  @override
  void didUpdateWidget(ContentSwap old) {
    super.didUpdateWidget(old);
    if (widget.child.key != old.child.key) {
      _offer(widget.child);
      return;
    }
    // The same content, rebuilt for some other reason — a setting, a panel
    // opening. Whichever place is holding it takes the new widget, or the
    // rebuild would stop at this line.
    setState(() {
      if (_queued != null) {
        _queued = widget.child;
      } else if (_next != null) {
        _next = widget.child;
      } else {
        _shown = widget.child;
      }
    });
  }

  @override
  void dispose() {
    _waiting?.cancel();
    _fade.dispose();
    super.dispose();
  }

  void _offer(Widget child) {
    if (_fade.isAnimating) {
      setState(() => _queued = child);
      return;
    }
    setState(() {
      _next = child;
      _promised = false;
      _fade.value = 0;
    });
    _waiting?.cancel();
    _waiting = Timer(ContentSwap.grace, () {
      if (mounted && !_promised) _cover();
    });
  }

  /// The arriving view can draw: fade it up.
  void _cover() {
    _waiting?.cancel();
    _waiting = null;
    if (!mounted || _next == null || _fade.isAnimating) return;
    _fade.duration = widget.duration ?? motionOf(context, kContentSwapDuration);
    if (_fade.duration == Duration.zero) {
      _fade.value = 1;
      _arrived();
      return;
    }
    _fade.forward(from: 0);
  }

  /// It is covering: the one underneath can go, and anything offered while it
  /// was on its way starts now.
  void _arrived() {
    if (!mounted || _next == null) return;
    final queued = _queued;
    setState(() {
      _shown = _next;
      _next = null;
      _queued = null;
      _fade.value = 0;
    });
    if (queued != null) _offer(queued);
  }

  bool _heard(ContentNotification notice) {
    switch (notice) {
      case ContentPending():
        _promised = true;
        _waiting?.cancel();
        _waiting = Timer(ContentSwap.patience, _cover);
      case ContentPainted():
        _cover();
    }
    // Answered here: the page above has no business knowing which of its
    // viewers decodes and which does not.
    return true;
  }

  /// **The same shape for both slots, and that is not tidiness.** A child moves
  /// from the arriving slot to the shown one at the end of every swap, and an
  /// element only survives a move if the widget it lands under is of the same
  /// type with the same key. Give the two slots different wrappings and the
  /// picture that has just been decoded is thrown away and decoded again —
  /// which is the blink this whole file exists to remove.
  Widget _slot(Widget child, {required bool arriving}) => KeyedSubtree(
    key: child.key ?? const ValueKey('content'),
    child: NotificationListener<ContentNotification>(
      onNotification: arriving ? _heard : (_) => true,
      child: Arriving(
        arriving: arriving,
        child: FadeTransition(
          opacity: arriving ? _arriving : _leaving,
          child: child,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (_shown != null) _slot(_shown!, arriving: false),
      if (_next != null) _slot(_next!, arriving: true),
    ],
  );
}
