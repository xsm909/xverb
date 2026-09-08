import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart' as acrylic;
import 'package:window_manager/window_manager.dart';

import '../version.dart';
import 'appearance_settings.dart';
import 'backdrop_channel.dart';
import 'window_log.dart';

/// Owns the native window: the frameless setup our own title bar needs, and
/// the desktop backdrop effect.
///
/// Every method is a no-op away from desktop, so callers never have to guard.
class WindowService {
  const WindowService._();

  /// Windows, macOS and Linux have a window to manage; mobile does not.
  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Every desktop draws our buttons, none draws its own.
  ///
  /// macOS will keep its traffic lights over a hidden title bar, and used to:
  /// the bar left a gap for them and drew nothing there. One app with two
  /// sets of window buttons in two styles, depending on which machine it was
  /// running on, is the thing a custom title bar exists to avoid.
  static bool get drawsOwnButtons => isSupported;

  static bool _revealed = false;

  /// Called before `runApp`. Configures the window but deliberately leaves it
  /// hidden — [revealAfterFirstFrame] finishes the job.
  static Future<void> initialize(AppearanceSettings appearance) async {
    if (!isSupported) return;

    await WindowLog.start();
    WindowLog.write('initialize, backdrop=${appearance.backdrop.name}');

    await windowManager.ensureInitialized();
    await acrylic.Window.initialize();

    // **The close button asks rather than acts.** See [preventClose]: without
    // this the button on the title bar took the process down where it stood,
    // and everything held in memory until the way out was held until nothing.
    await windowManager.setPreventClose(true);

    const options = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(640, 420),
      center: true,
      title: kAppTitle,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Color(0x00000000),
    );

    await windowManager.waitUntilReadyToShow(options, () async {
      // No native buttons anywhere: ours are the only ones.
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: !drawsOwnButtons,
      );
    });

    // A hidden window that never gets revealed is far worse than a missing
    // blur, so show it regardless if the first frame never arrives.
    Future<void>.delayed(const Duration(seconds: 4), () async {
      if (_revealed) return;
      WindowLog.write('no first frame after 4s; showing anyway');
      await _reveal(appearance);
    });
  }

  /// Applies the backdrop once Flutter has painted, then shows the window.
  ///
  /// Order matters and cost us several confusing sessions: setting the effect
  /// before the first frame is a race. Flutter creating and painting its
  /// surface resets the window's composition attribute, so whether the acrylic
  /// survived depended on which finished first — the symptom being that a
  /// restart sometimes fixed it and sometimes broke it. Painting first and
  /// applying afterwards is deterministic, and keeping the window hidden until
  /// then also removes the startup flash.
  static Future<void> revealAfterFirstFrame(AppearanceSettings appearance) =>
      _reveal(appearance);

  static Future<void> _reveal(AppearanceSettings appearance) async {
    if (!isSupported || _revealed) return;
    _revealed = true;

    await applyBackdrop(appearance, reason: 'first frame');
    await windowManager.show();
    await windowManager.focus();
    WindowLog.write('window shown');
  }

  /// Applies the chosen backdrop. Effects a platform cannot honour fall back
  /// to a plain opaque window rather than failing.
  ///
  /// Windows goes through [BackdropChannel] — the runner's own call to
  /// `SetWindowCompositionAttribute` — and everywhere else through
  /// `flutter_acrylic`. Setting the DWM Windows 11 backdrop directly looked
  /// like the better route and is not: what makes a Flutter window see-through
  /// at all is the legacy composition attribute, and turning that off to let
  /// DWM take over simply leaves an opaque window with an invisible backdrop
  /// behind it.
  /// The effect currently believed to be on the window.
  static acrylic.WindowEffect? _current;

  /// Re-applies the backdrop on a window that is already up.
  ///
  /// On Windows this is now just an apply: our own channel writes the accent in
  /// one call, so re-asserting it is invisible. Elsewhere `flutter_acrylic`
  /// still needs a genuine change of effect blanked first, because switching
  /// straight from one to another does not take until a restart. Re-asserting
  /// the same effect must *not* blank, because if the second call is
  /// interrupted the window is left disabled — a repair that breaks the thing
  /// it repairs.
  static Future<void> reapplyBackdrop(
    AppearanceSettings appearance, {
    String reason = 'reapply',
  }) async {
    if (!isSupported) return;

    if (!BackdropChannel.isAvailable) {
      final target = _effectFor(appearance);
      final changing = _current != null && _current != target;
      if (changing && target != acrylic.WindowEffect.disabled) {
        await _setEffect(appearance, acrylic.WindowEffect.disabled,
            reason: '$reason:clear');
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
    await applyBackdrop(appearance, reason: reason);
  }

  static acrylic.WindowEffect _effectFor(AppearanceSettings appearance) =>
      switch (appearance.backdrop) {
        WindowBackdrop.opaque => acrylic.WindowEffect.disabled,
        WindowBackdrop.acrylic => _blurBehind,
        // Mica is a DWM material and shares acrylic's problem below, so on
        // Windows it can only be the same blur. Elsewhere the package's own
        // acrylic is the closest thing.
        WindowBackdrop.mica =>
          Platform.isWindows ? _blurBehind : acrylic.WindowEffect.acrylic,
        WindowBackdrop.transparent => acrylic.WindowEffect.transparent,
      };

  /// The package's nearest equivalent, used off Windows and as the fallback if
  /// our own channel is unreachable.
  static acrylic.WindowEffect get _blurBehind => Platform.isWindows
      ? acrylic.WindowEffect.aero
      : acrylic.WindowEffect.acrylic;

  static Future<void> applyBackdrop(
    AppearanceSettings appearance, {
    String reason = 'apply',
  }) async {
    if (!isSupported) return;

    await _setEffect(appearance, _effectFor(appearance), reason: reason);
  }

  /// The accent our own channel writes.
  ///
  /// Both blurring backdrops ask for real acrylic, and [WindowAccent.blurBehind]
  /// is deliberately never asked for. It is the effect this app used to run on,
  /// and it is why the backdrop looked like it had never come on: Windows 11 no
  /// longer honours it. Measured on build 26200, flipping the screen behind an
  /// untouched window between white and black and sampling inside it — mean
  /// brightness over white minus the same over black:
  ///
  /// | accent | delta |
  /// | --- | --- |
  /// | `acrylicBlurBehind` | 35 |
  /// | `blurBehind` | 7 |
  /// | `disabled` (control) | 0 |
  ///
  /// Mica is a DWM material, and DWM will not paint one on a window whose frame
  /// we removed in order to draw our own title bar, so on Windows it can only
  /// be the same acrylic.
  static WindowAccent _accentFor(AppearanceSettings appearance) =>
      switch (appearance.backdrop) {
        WindowBackdrop.opaque => WindowAccent.disabled,
        WindowBackdrop.acrylic ||
        WindowBackdrop.mica =>
          WindowAccent.acrylicBlurBehind,
        WindowBackdrop.transparent => WindowAccent.transparentGradient,
      };

  /// The colour handed to the accent.
  ///
  /// Only a whisper of tint on the blurring backdrops. Acrylic already lays
  /// down a luminosity layer of its own, and the panels on top carry the
  /// user's own [AppearanceSettings.panelOpacity] — tinting hard here as well
  /// darkened all three together into a flat slab, which is what "the acrylic
  /// never came on" looked like even once the effect was demonstrably
  /// blurring. Transparent means transparent, so it gets nothing.
  static Color _tintFor(AppearanceSettings appearance) =>
      switch (appearance.backdrop) {
        WindowBackdrop.opaque => appearance.panelBackground,
        WindowBackdrop.acrylic ||
        WindowBackdrop.mica =>
          appearance.panelBackground.withValues(alpha: 0.15),
        WindowBackdrop.transparent =>
          appearance.panelBackground.withValues(alpha: 0),
      };

  static Future<void> _setEffect(
    AppearanceSettings appearance,
    acrylic.WindowEffect effect, {
    required String reason,
  }) async {
    // Our own channel first: it writes the accent once, where the package
    // blanks the window with ACCENT_DISABLED before every effect it sets and
    // so flashes on every re-apply.
    if (BackdropChannel.isAvailable) {
      final accent = effect == acrylic.WindowEffect.disabled
          ? WindowAccent.disabled
          : _accentFor(appearance);
      final ok = await BackdropChannel.setAccent(
        accent,
        color: _tintFor(appearance),
        dark: appearance.darkChrome,
      );
      if (ok) {
        _current = effect;
        WindowLog.write('$reason -> ${accent.name} ok (native)');
        return;
      }
      WindowLog.write('$reason -> native channel unavailable, falling back');
    }

    // Linux asks the window for nothing, and this is the whole of the reason.
    //
    // `flutter_acrylic` paints the backdrop on Linux itself, in a GTK `draw`
    // handler, with one `cairo_paint()` across the whole window surface. A GTK
    // window is larger than the application in it: it carries a client-side
    // decoration margin — 45 pixels a side on GNOME, and `xprop
    // _GTK_FRAME_EXTENTS` will say so — which exists to hold the drop shadow
    // and is meant to stay empty. Painting over it puts a band right around
    // the application: white where the effect is `disabled`, which on Linux is
    // a hardcoded opaque white rather than "leave the window alone"; the panel
    // colour where it is `solid`; a translucent haze where it blurs. Every
    // backdrop had that band, and it was reported as three separate bugs.
    //
    // Not painting leaves the margin as GTK intends it, and the window is then
    // exactly what Flutter draws: opaque where the [Scaffold] is opaque,
    // see-through where it is not — which is what each backdrop here means in
    // the first place. The blur is what is genuinely given up, and the package
    // could not do it on Linux anyway: its plugin answers anything but
    // `disabled`, `solid` and `transparent` with an error.
    if (Platform.isLinux) {
      _current = effect;
      WindowLog.write('$reason -> ${effect.name} (Linux: left to Flutter)');
      return;
    }

    try {
      await acrylic.Window.setEffect(
        effect: effect,
        color: _tintFor(appearance),
        dark: appearance.darkChrome,
      );
      _current = effect;
      WindowLog.write('$reason -> ${effect.name} ok');
    } on Object catch (e) {
      // An unsupported effect must not take the app down with it.
      WindowLog.write('$reason -> ${effect.name} FAILED: $e');
    }
  }

  static Future<bool> isMaximized() async =>
      isSupported && await windowManager.isMaximized();

  static Future<void> minimize() async {
    if (isSupported) await windowManager.minimize();
  }

  static Future<void> toggleMaximize() async {
    if (!isSupported) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  /// Asks the window to close, which is not the same as closing it.
  ///
  /// **The application is told first.** With [preventClose] set, this raises
  /// `onWindowClose` and stops there; whoever is listening writes down what it
  /// owes and then calls [destroy]. Before that, the button on the title bar
  /// tore the process down where it stood, and everything kept in memory until
  /// the way out — the folder history above all — was kept until nothing.
  static Future<void> close() async {
    if (isSupported) await windowManager.close();
  }

  /// Closes it for real, once whoever was asked has finished.
  static Future<void> destroy() async {
    if (isSupported) await windowManager.destroy();
  }

  /// Makes [close] an *ask* rather than an act.
  ///
  /// Set once at start-up. **Everything that follows must be sure to call
  /// [destroy]**, because a window that asks and is never answered is a window
  /// nobody can close.
  static Future<void> preventClose() async {
    if (isSupported) await windowManager.setPreventClose(true);
  }

  static Future<void> startDragging() async {
    if (isSupported) await windowManager.startDragging();
  }
}
