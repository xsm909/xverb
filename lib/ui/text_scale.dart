import 'package:flutter/material.dart';

import '../core/settings/appearance_settings.dart';

/// [base] with every size in it multiplied by [factor], and every weight in it
/// moved [weightShift] steps along the nine.
///
/// This is how the chosen font size reaches the text the application does not
/// set itself: menus, dialogs, list tiles, buttons — everything that takes its
/// size from Material's text theme rather than from a number we wrote. The
/// interface weight setting travels the same road for the same reason, and as a
/// *shift* rather than a weight: the theme's own weights are a hierarchy — body
/// at 400, labels and titles a step above — and moving them together keeps it,
/// where writing one weight over all of them would flatten it. See
/// [AppearanceSettings.uiWeightShift].
///
/// Written out rather than done with `TextTheme.apply(fontSizeFactor:)`, which
/// asserts on any style whose `fontSize` is null and there are such styles in a
/// Material theme — the first cut used it and the application would not start.
/// A style with no size of its own has nothing to scale and is passed through
/// untouched, which is the whole of what `apply` refuses to do.
///
/// **Not enough on its own — see [scaledTypography].** `ThemeData.textTheme`
/// holds styles whose `fontSize` is null: the sizes live in the theme's
/// [Typography] and are merged in later, by `ThemeData.localize`. So scaling
/// the text theme alone scaled the handful of styles that happened to carry a
/// size and left the rest to be filled in, unscaled, afterwards — which is why
/// the settings form went on being drawn at 16 however far the slider was
/// dragged. Measured, in `text_scale_test`.
///
/// Public, and in a file of its own, because it is the one thing that has to be
/// *measured* rather than argued about: the test pumps a real `ListTile` under
/// a theme built this way and reads the size that came out.
TextTheme scaledTextTheme(TextTheme base, double factor, [int weightShift = 0]) {
  if (factor == 1 && weightShift == 0) return base;

  TextStyle? scale(TextStyle? style) {
    if (style == null) return null;
    final size = style.fontSize;
    return style.copyWith(
      fontSize: size == null || factor == 1 ? null : size * factor,
      // A style with no weight of its own is drawn at regular, so that is what
      // the shift is applied to. Leaving it null instead would have made the
      // setting reach some of the interface and not the rest, which is the
      // shape of the bug the font size setting took three goes to shake off.
      fontWeight: weightShift == 0
          ? null
          : shiftFontWeight(
              style.fontWeight ?? FontWeight.w400,
              weightShift,
            ),
    );
  }

  return base.copyWith(
    displayLarge: scale(base.displayLarge),
    displayMedium: scale(base.displayMedium),
    displaySmall: scale(base.displaySmall),
    headlineLarge: scale(base.headlineLarge),
    headlineMedium: scale(base.headlineMedium),
    headlineSmall: scale(base.headlineSmall),
    titleLarge: scale(base.titleLarge),
    titleMedium: scale(base.titleMedium),
    titleSmall: scale(base.titleSmall),
    bodyLarge: scale(base.bodyLarge),
    bodyMedium: scale(base.bodyMedium),
    bodySmall: scale(base.bodySmall),
    labelLarge: scale(base.labelLarge),
    labelMedium: scale(base.labelMedium),
    labelSmall: scale(base.labelSmall),
  );
}

/// [base] with the sizes in its geometry multiplied by [factor].
///
/// This is the one that works. A [Typography] carries the colours (`black`,
/// `white`) and the *geometry* — `englishLike`, `dense`, `tall` — and the
/// geometry is where the sizes are. `ThemeData.localize` picks whichever of the
/// three the locale calls for and merges it under the theme's text theme, so a
/// size that is not in the geometry is a size the application never sees.
///
/// Scaling here reaches every Material widget at once: list tiles, dialogs,
/// menus, buttons, text fields. Nothing has to opt in, and nothing that already
/// sets its own size is disturbed, because an explicit size still wins the
/// merge.
Typography scaledTypography(
  Typography base,
  double factor, [
  int weightShift = 0,
]) {
  if (factor == 1 && weightShift == 0) return base;

  return Typography.material2021(
    black: base.black,
    white: base.white,
    englishLike: scaledTextTheme(base.englishLike, factor, weightShift),
    dense: scaledTextTheme(base.dense, factor, weightShift),
    tall: scaledTextTheme(base.tall, factor, weightShift),
  );
}

/// The interface weight, reached from anywhere that draws a weight of its own.
///
/// Material's text follows the setting through the typography above without
/// anything opting in. A style that names its own weight — the menu strip at
/// w500, a dialog title at w600 — wins that merge, so those few places ask for
/// the shift explicitly and go on saying what they said: a step above the text
/// around them, wherever the slider has put it.
extension UiTextWeight on BuildContext {
  FontWeight uiWeight(FontWeight base) =>
      Theme.of(this).textTheme.uiWeightFor(base);
}

/// The shift the theme was built with, read back off the theme.
///
/// Taken from `bodyMedium`, which is the style the pivot was chosen from:
/// Material draws it at [AppearanceSettings.defaultUiWeight], so whatever it is
/// drawn at now *is* the shift. Reading it here rather than reaching for the
/// settings store keeps a call site to one lookup, and one that is already
/// rebuilt when the theme changes.
extension _ThemeWeightShift on TextTheme {
  FontWeight uiWeightFor(FontWeight base) {
    final body = bodyMedium?.fontWeight ?? FontWeight.w400;
    return shiftFontWeight(
      base,
      FontWeight.values.indexOf(body) -
          FontWeight.values.indexOf(FontWeight.w400),
    );
  }
}
