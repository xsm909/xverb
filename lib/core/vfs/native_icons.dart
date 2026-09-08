import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

import 'mac_icons.dart';
import 'windows_icons.dart';

/// What a desktop has to answer for the panels to draw its own icons.
abstract interface class NativeIconSource {
  /// Extensions whose icon belongs to the individual file rather than to its
  /// kind — a program's own picture, a shortcut's target, a bundle.
  ///
  /// Kept short on purpose: every entry on it is a disk touch per row.
  Set<String> get ownIcon;

  /// The icon for [nativePath], or null when the desktop has none to give.
  ///
  /// [byPath] asks about that one file; without it the question is about the
  /// *kind*, which is what makes a folder of ten thousand files cost one
  /// lookup per extension. [isDirectory] is passed in rather than looked up,
  /// because the point of this is not to go near the disk.
  Future<ui.Image?> load(
    String nativePath, {
    required bool isDirectory,
    required bool byPath,
  });
}

/// The desktop's own icon for a file or a folder.
///
/// Two implementations behind one door: Windows asks the shell through FFI,
/// macOS asks the workspace through the runner's own channel. What is the same
/// on both — the caching, the keys, and the rule about which files carry their
/// own picture — lives here, so neither platform can quietly answer a different
/// question from the other.
///
/// Everything is cached for the life of the process. An icon is a handful of
/// kilobytes and the set of extensions in front of a person is small.
class NativeIcons {
  const NativeIcons._();

  /// The source for this desktop, or null where there is none.
  ///
  /// Replaceable so that a test can stand something predictable in its place:
  /// what the real one returns is whatever happens to be installed on the
  /// machine running the suite.
  static NativeIconSource? source = Platform.isWindows
      ? const WindowsIconSource()
      : Platform.isMacOS
      ? const MacIconSource()
      : null;

  static bool get isSupported => source != null;

  static final Map<String, Future<ui.Image?>> _cache = {};

  /// What has already been loaded, for a row that must draw this frame.
  ///
  /// A `FutureBuilder` per row would rebuild the whole listing on every scroll;
  /// the rows read this, and ask [of] once when it is empty.
  static final Map<String, ui.Image> ready = {};

  /// What two entries have to agree on to share an icon.
  ///
  /// The own-icon test comes before the directory one, because a bundle is a
  /// directory whose icon is its own — an application on macOS is a folder.
  static String cacheKeyFor(String nativePath, {required bool isDirectory}) {
    final extension = p.extension(nativePath).toLowerCase();
    final bare = extension.replaceFirst('.', '');
    if (bare.isNotEmpty && (source?.ownIcon.contains(bare) ?? false)) {
      return nativePath.toLowerCase();
    }
    if (isDirectory) return '<dir>';
    return extension.isEmpty ? '<file>' : extension;
  }

  /// The icon for [nativePath], or null when there is none to be had.
  static Future<ui.Image?> of(String nativePath, {required bool isDirectory}) {
    final from = source;
    if (from == null) return Future.value(null);

    final key = cacheKeyFor(nativePath, isDirectory: isDirectory);
    return _cache.putIfAbsent(
      key,
      () => _load(
        from,
        nativePath,
        isDirectory: isDirectory,
        key: key,
        byPath: key == nativePath.toLowerCase(),
      ),
    );
  }

  /// Forgets everything. For a test, and for a change of icon size.
  static void clear() {
    _cache.clear();
    ready.clear();
  }

  static Future<ui.Image?> _load(
    NativeIconSource from,
    String nativePath, {
    required bool isDirectory,
    required String key,
    required bool byPath,
  }) async {
    try {
      final image = await from.load(
        nativePath,
        isDirectory: isDirectory,
        byPath: byPath,
      );
      if (image != null) ready[key] = image;
      return image;
    } on Object {
      // A missing icon is not worth a broken listing; the built-in one stands
      // in, and that is the whole handling this needs.
      return null;
    }
  }
}
