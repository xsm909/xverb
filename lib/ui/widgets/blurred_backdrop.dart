import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../core/settings/appearance_settings.dart';

/// The one blur in the application: a translucent surface with the window
/// behind it softened, used by the context menu and by [SlidePanel].
///
/// It lives on its own because two blurs that look alike and behave differently
/// is exactly the thing this application avoids. Everything a caller has to get
/// right — the number of passes, the clipping — is written down here rather than
/// rediscovered at each call site.

/// Applies [BackdropFilter] [passes] times over. Each pass blurs everything
/// painted below it, including what the previous pass just drew.
///
/// **Clip it.** A [BackdropFilter] blurs the whole layer it sits in, so a
/// rounded surface must put this inside a [ClipRRect] (or a [ClipPath]) of its
/// own shape; without one the blur shows outside the corners.
Widget blurredBackdrop({
  required double sigma,
  required int passes,
  required Widget child,
}) {
  if (sigma <= 0) return child;

  var result = child;
  for (var i = 0; i < passes; i++) {
    result = BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: result,
    );
  }
  return result;
}

/// How many blur passes a surface needs before the blur is actually visible.
///
/// On a translucent window most of what shows through a menu or a panel is the
/// desktop, blurred and composited by the operating system *behind* the window
/// — no filter inside Flutter can touch that. What Flutter can blur is only
/// what it painted itself, and with the panels at, say, 20% opacity that is one
/// fifth of the image. A single pass then draws a blurred layer that is 80%
/// see-through, which reads as "the blur is broken". Repeating it compounds the
/// coverage.
int blurPassesFor(AppearanceSettings appearance, {required double sigma}) {
  if (appearance.backdrop == WindowBackdrop.opaque) return 1;
  if (sigma <= 0) return 1;

  final coverage = appearance.panelOpacity;
  if (coverage >= 0.8) return 1;
  if (coverage >= 0.5) return 2;
  return 3;
}
