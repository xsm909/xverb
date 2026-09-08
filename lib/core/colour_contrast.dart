/// **A colour is legible against what it was chosen against, and no further.**
///
/// A colour and the surface under it are chosen together, unless somebody has
/// deliberately set a pair that does not work. The palette
/// names a handful of inks — the marked colour, the panel's foreground — and
/// every one of them was picked against the *rows*. Borrowed for a strip, a
/// menu or a floating box in another colour, they can land anywhere, and on the
/// shipped palette one of them landed at 2.5:1.
///
/// So a borrowed ink is put through [legibleInk] where it is borrowed, and the
/// palette itself is left alone: what the user set is what the rows show.
library;

import 'package:flutter/widgets.dart';

/// The WCAG contrast between two opaque colours, as a ratio from 1 to 21.
double contrastRatio(Color a, Color b) {
  final one = a.computeLuminance();
  final other = b.computeLuminance();
  final lighter = one > other ? one : other;
  final darker = one > other ? other : one;
  return (lighter + 0.05) / (darker + 0.05);
}

/// The ratio small text is held to, and the one used everywhere here.
const double kReadableContrast = 4.5;

/// [wanted], if it can be read on [on]; otherwise the same hue taken to
/// whichever end [on] leaves free; otherwise [fallback].
///
/// **The hue is kept because the hue is the message.** The marked colour says
/// "something is marked" and the accent says "this is the one" — throwing them
/// away for a safe grey answers the contrast and loses the sentence. Only when
/// a hue has nowhere to go at either end — a colour set to the surface's own —
/// is [fallback] used, which is the surface's own ink and is legible by
/// construction.
Color legibleInk(Color wanted, {required Color on, required Color fallback}) {
  if (contrastRatio(wanted, on) >= kReadableContrast) return wanted;

  final lifted = HSLColor.fromColor(wanted)
      .withLightness(on.computeLuminance() <= 0.45 ? 0.94 : 0.12)
      .toColor();
  if (contrastRatio(lifted, on) >= kReadableContrast) return lifted;

  return fallback;
}

/// Black or white, whichever can be read on [on].
///
/// The last resort, for a surface with no ink of its own to fall back to.
///
/// **Measured, not thresholded.** This used to answer `luminance > 0.5 ? black
/// : white`, which is not the same question and gets a band of strong mid
/// colours wrong: the shipped accent, `#F97316`, sits at luminance 0.32 and so
/// was given white — 2.8:1, where black on the same orange is 7.4:1. A strong red
/// or green lands the same way. Both candidates are now tried and the better
/// one wins, which is what the sentence above always said this did.
Color inkFor(Color on) =>
    contrastRatio(const Color(0xFF000000), on) >=
        contrastRatio(const Color(0xFFFFFFFF), on)
    ? const Color(0xFF000000)
    : const Color(0xFFFFFFFF);
