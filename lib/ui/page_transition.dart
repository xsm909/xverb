import 'package:flutter/material.dart';

import 'motion.dart';

/// The transition between full-window pages: settings, the viewer, a plugin's
/// own page.
///
/// **Why this is not Material's own.** The zoom transition Flutter puts on
/// Windows and Linux by default, and the Cupertino slide it puts on macOS, are
/// both written for an application that is opaque. This one is not: with any
/// backdrop but [WindowBackdrop.opaque] every page is painted at
/// `panelOpacity`, so something always shows through it. What is *meant* to
/// show through is the window's backdrop — the acrylic, the wallpaper. During a
/// push it is not, because a route below goes on painting until the transition
/// ends, so for the whole animation the see-through part is filled by the
/// panels instead.
///
/// That one fact is the whole of what looked like three separate stages on
/// Windows. Material's zoom covers the route below with a scrim of
/// `colorScheme.surface` at 60% — that is the "goes pale" — and then drops both
/// the scrim and the route below on the last frame, so the backdrop arrives all
/// at once at the end and reads as a third act. macOS hid nothing at all:
/// Cupertino slides the page in over a route still painted at full strength,
/// which is why the arriving screen did not look as though it lived in its own
/// slide.
///
/// So the route below is faded out here, early and on its own, and no scrim is
/// painted over it. By the time the incoming page is legible there is nothing
/// behind it but the backdrop, which is what it is translucent for. The zoom
/// itself is kept — the scales are Material's — because the shape of the
/// movement was never the problem.
///
/// The two fades barely overlap, and deliberately. Two translucent pages
/// cross-fading show through each other, and a listing read through a settings
/// screen is worse than either.
///
/// Snapshotting is not used. It rasterises the route for the length of the
/// animation, and a raster has nothing behind it for a backdrop filter to
/// sample or for a native backdrop to reach through.
class BackdropPageTransitionsBuilder extends PageTransitionsBuilder {
  const BackdropPageTransitionsBuilder();

  /// Material's own entering scale, kept.
  static final Animatable<double> _enterScale =
      Tween<double>(begin: 0.85, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutCubic));

  /// Late, and over a long enough stretch to be a fade. Material's runs across
  /// an eighth of the animation, which is not a fade but a cut with a ramp in
  /// front of it — the "content appears all at once" half of the report.
  static final Animatable<double> _enterFade = CurveTween(
    curve: const Interval(0.35, 0.9, curve: Curves.easeOut),
  );

  /// Material's own scale for the route being covered, kept.
  static final Animatable<double> _belowScale =
      Tween<double>(begin: 1.0, end: 1.1)
          .chain(CurveTween(curve: Curves.easeInCubic));

  /// Gone before the page above is readable. This is the part Material leaves
  /// out and the part that makes the difference.
  static final Animatable<double> _belowFade =
      Tween<double>(begin: 1.0, end: 0.0)
          .chain(CurveTween(curve: const Interval(0.0, 0.4, curve: Curves.easeIn)));

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Both, on every route: `animation` is this page arriving or leaving, and
    // `secondaryAnimation` is a page arriving over the top of it. A pop runs
    // each of them backwards, so nothing here needs a direction of its own.
    return FadeTransition(
      opacity: _belowFade.animate(secondaryAnimation),
      child: ScaleTransition(
        scale: _belowScale.animate(secondaryAnimation),
        child: FadeTransition(
          opacity: _enterFade.animate(animation),
          child: ScaleTransition(
            scale: _enterScale.animate(animation),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A page route that takes as long as the settings say a page takes.
///
/// Every full-window page goes through here rather than through
/// `MaterialPageRoute` directly. A route is the one animated thing that cannot
/// read the setting for itself: its length is asked for once, by the navigator,
/// before anything of it is built — so the length is fetched at the push, where
/// there is still a context to fetch it from.
///
/// At [AnimationSpeed.off] this is [Duration.zero] and the navigator does no
/// transition at all: the page is simply there, which is what off means.
class MotionPageRoute<T> extends MaterialPageRoute<T> {
  MotionPageRoute({required super.builder, required this.duration, super.settings});

  /// Taken from the context that pushed the route.
  MotionPageRoute.of(
    BuildContext context, {
    required WidgetBuilder builder,
    RouteSettings? settings,
  }) : this(
         builder: builder,
         duration: motionOf(context, kPageAnimationDuration),
         settings: settings,
       );

  final Duration duration;

  @override
  Duration get transitionDuration => duration;

  @override
  Duration get reverseTransitionDuration => duration;
}

/// One transition on every platform.
///
/// The PC session is the standard the rest is held against, and the phones are
/// a by-product — so rather than let each platform keep its own default and
/// have three answers to the same question, they all get the desktop's.
const PageTransitionsTheme kPageTransitions = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.windows: BackdropPageTransitionsBuilder(),
    TargetPlatform.linux: BackdropPageTransitionsBuilder(),
    TargetPlatform.macOS: BackdropPageTransitionsBuilder(),
    TargetPlatform.android: BackdropPageTransitionsBuilder(),
    TargetPlatform.iOS: BackdropPageTransitionsBuilder(),
    TargetPlatform.fuchsia: BackdropPageTransitionsBuilder(),
  },
);
