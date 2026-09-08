import 'package:flutter/widgets.dart';

import '../motion.dart';

/// One thing replacing another **in the same instant**: the new one arrives
/// over the old, and the old is only taken away once it is covered.
///
/// **The difference from [FadeThrough], and why both exist.** That one fades
/// *through*: the old goes out, and only at the bottom is the new built. It has
/// to, because it hands the same builder one value at a time and two copies of
/// a reading would be two scrollables sharing one controller. The cost is a
/// moment with nothing on screen, and on a folder of photographs walked with
/// an arrow key that moment is a blink: one picture goes, and only then does
/// the next arrive.
///
/// Here both are in the tree at once, each with its own state and its own
/// controllers, so there is nothing to share and nothing to go dark.
///
/// **The old one does not fade with the new one**, and that is the whole trick.
/// Two things crossing at half opacity each are together dimmer than either was
/// alone — a dip in the middle, which is the blink again, drawn slowly. So the
/// one being left holds its full opacity until the last fifth, by which time
/// the one arriving has covered it.
class CrossFade extends StatelessWidget {
  const CrossFade({super.key, required this.child, this.duration});

  /// What to show. **Its key is what decides whether anything happens**: same
  /// key, no fade; a new key, a fade. Give it a key that changes when the
  /// content does and not when the file does — during a walk the file changes
  /// the moment the arrow is pressed, and the picture a good deal later.
  final Widget child;

  /// Left null this takes [kContentSwapDuration] at the speed the user set.
  final Duration? duration;

  /// How much of the fade the outgoing child spends at full opacity.
  static const double _holds = 0.2;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: duration ?? motionOf(context, kContentSwapDuration),
    switchInCurve: kArrivingCurve,
    // Read against a controller running from 1 down to 0: it stays at one
    // until the last fifth and only then lets go.
    switchOutCurve: const Interval(0, _holds),
    // Expanded rather than the default, which lays its children out loose and
    // would let a picture arrive at a different size than it leaves at.
    layoutBuilder: (current, previous) => Stack(
      fit: StackFit.expand,
      children: [...previous, ?current],
    ),
    child: child,
  );
}
