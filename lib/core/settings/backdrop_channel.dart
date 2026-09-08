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

  /// Only the Windows runner carries the native half.
  static bool get isAvailable => Platform.isWindows;

  /// Applies [accent], tinted with [color]. Returns false if the native side
  /// refused, in which case the caller should fall back.
  static Future<bool> setAccent(
    WindowAccent accent, {
    required Color color,
    required bool dark,
  }) async {
    if (!isAvailable) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('setAccent', {
        'state': accent.state,
        'color': color.toARGB32(),
        'dark': dark,
      });
      return ok ?? false;
    } on Object {
      // A missing channel or an old Windows is a fallback, not a crash.
      return false;
    }
  }
}
