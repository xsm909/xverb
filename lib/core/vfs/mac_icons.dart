import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'native_icons.dart';

/// The icon macOS itself would draw, fetched through the runner.
///
/// A channel rather than FFI, because `NSWorkspace` is Objective-C and Swift
/// and there is nothing to bind to from Dart. The runner is handed a kind and
/// answers with PNG bytes; the engine decodes them.
///
/// The same shape as the Windows side: asked by *kind* — an extension, or
/// "a folder" — so a listing costs one lookup per extension rather than one per
/// row, and only the bundles are asked about by path, because a bundle's icon
/// is its own.
class MacIconSource implements NativeIconSource {
  const MacIconSource();

  static const MethodChannel _channel = MethodChannel('xverb/shell');

  /// Asked for at twice the size it is drawn at, or it is soft on a retina
  /// screen. Flutter scales it down, which costs nothing.
  static const int pixels = 32;

  /// A bundle is a directory whose icon belongs to it rather than to folders in
  /// general: an application is a folder, and drawing it as one would be wrong
  /// in the one place people most expect an icon to be right.
  @override
  Set<String> get ownIcon => const {
    'app',
    'framework',
    'bundle',
    'prefpane',
    'workflow',
    'icns',
  };

  @override
  Future<ui.Image?> load(
    String nativePath, {
    required bool isDirectory,
    required bool byPath,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>('fileIcon', {
      'path': nativePath,
      'byPath': byPath,
      'isDirectory': isDirectory,
      'pixels': pixels,
    });
    if (bytes == null || bytes.isEmpty) return null;

    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }
}
