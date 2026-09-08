import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// The folders every desktop gives a person: the desktop itself, their
/// documents, downloads, pictures, and whatever this system calls the one for
/// films.
///
/// **Asked of the machine, never composed.** `$HOME/Desktop` is right on macOS
/// and wrong nearly everywhere else: on Windows these move — a user with
/// OneDrive has had them moved already — and on Linux they are named in the
/// language of the desktop, so a session in another language really does keep
/// its files in a folder named in it. A menu entry that opens onto nothing is
/// worse than one line
/// fewer, so a folder that is not there is not offered — except on macOS, where
/// asking whether it is there is itself a question the user has to answer. See
/// [known].
///
/// **The name is the folder's own, and is not translated.** The row is what
/// you would see if you walked
/// into home and looked — which on Linux is already in the user's language,
/// because that is what the folder is called on the disk.
class UserFolders {
  const UserFolders._();

  /// The folders, in the order a menu should show them, and only those that
  /// exist. The label is the last part of the path — the folder's own name.
  static List<({String label, String path})> known() {
    final home = _home();
    if (home == null) return const [];

    final found = <({String label, String path})>[];
    void offer(String? path) {
      if (path == null || path.isEmpty) return;
      // **Not asked of the disk on macOS**, and that is not an optimisation.
      // Desktop, Documents, Downloads, Pictures and Movies are behind the
      // privacy fence there, and *looking* is enough to raise the prompt — so
      // the first build of this asked the user for permission to three folders
      // the moment the application started, before they had asked for
      // anything. The five are made by the system and are always there; the
      // check earns its keep on Windows and Linux, where any of them may
      // genuinely be absent, and neither system charges for the question.
      if (!Platform.isMacOS && !Directory(path).existsSync()) return;
      // A machine that has not moved anything answers the same path for two of
      // them only if something is wrong; a duplicate row is still a lie.
      if (found.any((f) => p.equals(f.path, path))) return;
      final name = p.basename(path);
      found.add((label: name.isEmpty ? path : name, path: path));
    }

    for (final folder in _Folder.values) {
      offer(_resolve(home, folder));
    }
    return found;
  }

  static String? _home() {
    final env = Platform.environment;
    if (!Platform.isWindows) return env['HOME'];
    final profile = env['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) return profile;
    final drive = env['HOMEDRIVE'];
    final path = env['HOMEPATH'];
    return drive != null && path != null ? '$drive$path' : null;
  }

  static String? _resolve(String home, _Folder folder) {
    if (Platform.isWindows) {
      return _windows(folder.knownFolderId) ?? p.join(home, folder.underHome);
    }
    if (Platform.isLinux) {
      return _xdg(home, folder.xdgKey) ?? p.join(home, folder.underHome);
    }
    return p.join(home, folder.underHome);
  }

  /// The path Windows itself has for one of its known folders.
  ///
  /// `SHGetKnownFolderPath` rather than `%USERPROFILE%\Desktop`, because the
  /// two stop agreeing the moment anything redirects them, and OneDrive
  /// redirects Desktop and Documents by default on a new machine.
  ///
  /// Returns null on any failure at all — a missing export, a refused call, a
  /// path that no longer exists — and the caller then falls back to the guess,
  /// which is right on a machine that has moved nothing.
  static String? _windows(String id) {
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final getPath = shell32.lookupFunction<
          Int32 Function(
            Pointer<Uint8>,
            Uint32,
            IntPtr,
            Pointer<Pointer<Utf16>>,
          ),
          int Function(
            Pointer<Uint8>,
            int,
            int,
            Pointer<Pointer<Utf16>>,
          )>('SHGetKnownFolderPath');
      final free = DynamicLibrary.open('ole32.dll').lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('CoTaskMemFree');

      final guid = _guid(id);
      final out = calloc<Pointer<Utf16>>();
      try {
        // S_OK, and no flags: this asks where the folder is, and asking
        // Windows to create it is not this menu's business.
        if (getPath(guid, 0, 0, out) != 0) return null;
        final path = out.value.toDartString();
        free(out.value.cast());
        return path;
      } finally {
        calloc.free(guid);
        calloc.free(out);
      }
    } on Object {
      return null;
    }
  }

  /// A `KNOWNFOLDERID` laid out the way Windows reads one: three little-endian
  /// numbers and then eight plain bytes, which is why it cannot simply be
  /// written out as sixteen bytes of the text.
  static Pointer<Uint8> _guid(String text) {
    final hex = text.replaceAll('-', '');
    final bytes = [
      for (var i = 0; i < 16; i++)
        int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
    ];
    final memory = calloc<Uint8>(16);
    final view = memory.asTypedList(16);
    view[0] = bytes[3];
    view[1] = bytes[2];
    view[2] = bytes[1];
    view[3] = bytes[0];
    view[4] = bytes[5];
    view[5] = bytes[4];
    view[6] = bytes[7];
    view[7] = bytes[6];
    for (var i = 8; i < 16; i++) {
      view[i] = bytes[i];
    }
    return memory;
  }

  /// What the desktop wrote in `user-dirs.dirs`, which is where a Linux session
  /// keeps the answer — `xdg-user-dir` reads this same file, and reading it
  /// costs no process.
  ///
  /// A line looks like `XDG_DESKTOP_DIR="$HOME/Desktop"`, with the folder
  /// named in whatever language the desktop was installed in.
  static String? _xdg(String home, String key) {
    final config = Platform.environment['XDG_CONFIG_HOME'] ??
        p.join(home, '.config');
    final file = File(p.join(config, 'user-dirs.dirs'));
    if (!file.existsSync()) return null;

    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('$key=')) continue;
      var value = trimmed.substring(key.length + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      value = value.replaceAll(r'$HOME', home).replaceAll(r'${HOME}', home);
      // The file says `XDG_DESKTOP_DIR="$HOME/"` for a desktop that has been
      // turned off, and that is home itself rather than a folder in it.
      return value.isEmpty || p.equals(value, home) ? null : value;
    }
    return null;
  }
}

/// The five, and the order they are offered in.
enum _Folder {
  desktop(
    fallback: 'Desktop',
    xdgKey: 'XDG_DESKTOP_DIR',
    knownFolderId: 'B4BFCC3A-DB2C-424C-B029-7FE99A87C641',
  ),
  downloads(
    fallback: 'Downloads',
    xdgKey: 'XDG_DOWNLOAD_DIR',
    knownFolderId: '374DE290-123F-4565-9164-39C4925E467B',
  ),
  documents(
    fallback: 'Documents',
    xdgKey: 'XDG_DOCUMENTS_DIR',
    knownFolderId: 'FDD39AD0-238F-46AF-ADB4-6C85480369C7',
  ),
  pictures(
    fallback: 'Pictures',
    xdgKey: 'XDG_PICTURES_DIR',
    knownFolderId: '33E28130-4E1E-4676-835A-98395C3BC3BB',
  ),
  /// **The one whose name is not the same on two systems.** macOS calls it
  /// Movies, Windows calls it Videos, and a Linux desktop calls it whatever
  /// `XDG_VIDEOS_DIR` says. Only the fallback differs — the id and the key each
  /// answer for their own platform anyway, and neither is ever read on the
  /// other one.
  videos(
    fallback: 'Videos',
    macFallback: 'Movies',
    xdgKey: 'XDG_VIDEOS_DIR',
    knownFolderId: '18989B1D-99B5-455B-841C-AB7C74E4DDFC',
  );

  const _Folder({
    required this.fallback,
    required this.xdgKey,
    required this.knownFolderId,
    this.macFallback,
  });

  /// What the folder is called under `$HOME` when nothing else answers. Right
  /// on macOS always, and on the other two only when nothing has been moved or
  /// translated — which is exactly when the guess is all there is.
  final String fallback;

  /// Where macOS parts company with the name Windows uses.
  final String? macFallback;

  String get underHome =>
      Platform.isMacOS ? (macFallback ?? fallback) : fallback;

  final String xdgKey;
  final String knownFolderId;
}
