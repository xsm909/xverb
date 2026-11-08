import 'dart:io';

import 'package:flutter/services.dart';

/// The Windows accent states `SetWindowCompositionAttribute` understands.
///
/// Only the three the app can ask for are listed; the rest are gradients that
/// look nothing like a backdrop.
enum WindowAccent {
  /// No effect. The window paints whatever Flutter painted, opaquely.
  disabled(0),

  /// Fully see-through with no blur.
  transparentGradient(2),

  /// The legacy blur-behind.
  blurBehind(3),

  /// Real acrylic: a blurred, tinted, noisy backdrop. `flutter_acrylic` cannot
  /// reach this any more — from build 22523 it routes acrylic to a DWM system
  /// backdrop, which will not paint on a frameless window.
  acrylicBlurBehind(4);

  const WindowAccent(this.state);

  /// The ACCENT_STATE value passed to the native side.
  final int state;
}

/// Talks to the runner's own backdrop channel (`windows/runner/backdrop.cpp`).
///
/// `flutter_acrylic` blanks the window with ACCENT_DISABLED before every effect
/// it sets, and DWM composes a frame from that intermediate state — so every
/// re-apply flashes. This channel writes the accent once. Everything falls back
/// to `flutter_acrylic` if the native side is not there.
class BackdropChannel {
  const BackdropChannel._();

  static const MethodChannel _channel = MethodChannel('xverb/backdrop');

  /// Only the Windows runner carries the native half **of the accent**.
  static bool get isAvailable => Platform.isWindows;

  /// Whether the runner carries the window's own layer of the fade — its
  /// glass, its edge and its shadow.
  ///
  /// Both desktops do; the Mac answers the same `inactiveOpacity` call on the
  /// same channel. Linux has no native half at all, so there the interface
  /// fades by the whole figure, which is the most Dart can do on its own.
  static bool get fadesWholeWindow => Platform.isWindows || Platform.isMacOS;

  /// Whether the runner carries the **drawing's** layer as well, so the
  /// interface must not fade in the widget tree at all.
  ///
  /// Only the Mac: there the Flutter view is a subview of the glass and can be
  /// faded by itself, per window, which is exact. A layered window on Windows
  /// is one alpha for everything in it, with nothing to aim at the drawing
  /// alone, so that half is Flutter's there.
  static bool get fadesTheDrawing => Platform.isMacOS;

  /// Applies [accent], tinted with [color]. Returns false if the native side
  /// refused, in which case the caller should fall back.
  static Future<bool> setAccent(
    WindowAccent accent, {
    required Color color,
    required bool dark,
    int? handle,
  }) async {
    if (!isAvailable) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setAccent', {
        'state': accent.state,
        'color': color.toARGB32(),
        'dark': dark,
        // A detached view's window, by its address; none is the first one.
        'handle': ?handle,
      });
      return ok ?? false;
    } on Object {
      // A missing channel or an old Windows is a fallback, not a crash.
      return false;
    }
  }

  /// How see-through a window is while another one has the focus, and how long
  /// it takes to get there.
  ///
  /// **Two figures, not one** — see [kWindowShareOfTheFade] for why and for the
  /// arithmetic, which is Dart's. [glass] is the window itself, its edge and
  /// its shadow with it; [drawing] is the interface, on top of that, and the
  /// two multiply to what the setting asks for. On Windows it is the
  /// layered-window alpha and only [glass] can be applied; on macOS the
  /// window's `alphaValue` and the Flutter view's take one each.
  static Future<void> setInactiveOpacity(
    double glass,
    double drawing,
    Duration fade,
  ) async {
    if (!fadesWholeWindow) return;
    try {
      await _channel.invokeMethod<void>('inactiveOpacity', {
        'value': glass,
        'content': drawing,
        'ms': fade.inMilliseconds,
      });
    } on Object {
      // Nothing to fall back to; the window simply stays solid.
    }
  }
}
