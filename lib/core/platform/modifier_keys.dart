import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

/// Whether a modifier is held *right now*, asked of the platform rather than
/// worked out from the key events that arrived.
///
/// Which matters for exactly one key. On Windows a lone Alt press is a system
/// key: Windows uses it to toggle menu-bar activation, and the presses arrive at
/// the application every *other* time — press, nothing, press. Anything counting
/// downs and ups therefore lights up on the first press, stays dark on the
/// second, and lights up on the third, which is precisely what was reported of
/// the menu letters. No widget test can reproduce it, because what goes missing
/// goes missing below Flutter.
///
/// `GetAsyncKeyState` reads the keyboard itself and does not care which events
/// were delivered. Everywhere else the framework's own view is right, and is used.
class ModifierKeys {
  const ModifierKeys._();

  /// `VK_MENU` — either Alt key.
  static const int _vkMenu = 0x12;

  /// `VK_CONTROL` — either Control key.
  static const int _vkControl = 0x11;

  /// The high bit of the answer means "down at this moment"; the low bit only
  /// says it has been pressed since the last time anyone asked, which is not the
  /// question.
  static const int _downMask = 0x8000;

  static int Function(int)? _getAsyncKeyState;
  static bool _lookedUp = false;

  static int Function(int)? get _lookup {
    if (_lookedUp) return _getAsyncKeyState;
    _lookedUp = true;
    if (!Platform.isWindows) return null;
    try {
      _getAsyncKeyState = DynamicLibrary.open('user32.dll')
          .lookupFunction<Int16 Function(Int32), int Function(int)>(
        'GetAsyncKeyState',
      );
    } on Object {
      _getAsyncKeyState = null;
    }
    return _getAsyncKeyState;
  }

  static bool _isDown(int virtualKey) {
    final call = _lookup;
    if (call == null) return false;
    try {
      return call(virtualKey) & _downMask != 0;
    } on Object {
      return false;
    }
  }

  /// Stands in for the keyboard under a test, which cannot hold a key down on
  /// the real one — and asking the real one would answer about whoever is at the
  /// machine running the suite.
  static bool Function()? debugAltAlone;

  /// Alt held, with Control *not* held.
  ///
  /// The two together are AltGr on a great many layouts, and there is nothing to
  /// show for a chord that composes a character rather than opening a menu.
  static bool get altAlone {
    final pretend = debugAltAlone;
    if (pretend != null) return pretend();

    if (Platform.isWindows && _lookup != null) {
      return _isDown(_vkMenu) && !_isDown(_vkControl);
    }
    final keys = HardwareKeyboard.instance;
    return keys.isAltPressed && !keys.isControlPressed;
  }
}
