import 'dart:io';

import '../i18n/i18n.dart';
import 'package:flutter/services.dart';

/// Opens the desktop's own context menu for a file — the one with the
/// archiver, the version control client and "Open with" in it.
///
/// The app does not reproduce any of that. It says which file and where, and
/// the shell builds the menu, fills it with whatever the machine has installed
/// and runs whatever is chosen. Which is the point: a file manager that
/// reimplemented that menu would be permanently a subset of it.
class SystemMenu {
  const SystemMenu._();

  static const MethodChannel _channel = MethodChannel('xverb/shell');

  /// Only the Windows runner carries the native half so far.
  static bool get isSupported => Platform.isWindows;

  /// Shows the menu for [nativePath] at a screen position, and returns once
  /// the user has picked something or dismissed it.
  ///
  /// Returns an error message if the shell would not produce a menu, or null
  /// when it did — including when nothing was picked, which is an ordinary
  /// outcome rather than a failure.
  static Future<String?> show(
    String nativePath, {
    required int x,
    required int y,
  }) async {
    if (!isSupported) return tr('The system menu is not available here.');

    try {
      await _channel.invokeMethod<void>('showContextMenu', {
        'path': nativePath,
        'x': x,
        'y': y,
      });
      return null;
    } on PlatformException catch (e) {
      return e.message ?? tr('The shell would not open a menu here.');
    } on MissingPluginException {
      return tr('This build has no system menu support.');
    } on Object catch (e) {
      return '$e';
    }
  }
}
