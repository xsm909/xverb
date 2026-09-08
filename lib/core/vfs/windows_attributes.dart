import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The Windows file attribute bits, which `dart:io` does not expose.
///
/// Hidden is an *attribute* on Windows, not a naming convention, so without
/// reading it the "show hidden files" switch does nothing there. `C:\` alone
/// has nine entries the desktop keeps out of sight — the page file, the swap
/// file, the recycle bin, `System Volume Information`, and the
/// `Documents and Settings` junction that cannot even be opened.
class WindowsAttributes {
  const WindowsAttributes._();

  static const int hidden = 0x2;
  static const int system = 0x4;
  static const int directory = 0x10;
  static const int reparsePoint = 0x400;

  /// What `GetFileAttributesW` answers when it cannot tell — the path is gone,
  /// or reading its metadata is not allowed.
  static const int invalid = 0xFFFFFFFF;

  /// Looked up once and kept: this is called for every entry in every listing,
  /// and `lookupFunction` walks the export table each time it is asked.
  static int Function(Pointer<Utf16>)? _getFileAttributes;
  static bool _lookedUp = false;

  static int Function(Pointer<Utf16>)? get _lookup {
    if (_lookedUp) return _getFileAttributes;
    _lookedUp = true;
    if (!Platform.isWindows) return null;
    try {
      _getFileAttributes = DynamicLibrary.open('kernel32.dll').lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)>('GetFileAttributesW');
    } on Object {
      _getFileAttributes = null;
    }
    return _getFileAttributes;
  }

  /// Attribute bits for [nativePath], or [invalid] off Windows and whenever the
  /// call cannot answer.
  static int of(String nativePath) {
    final call = _lookup;
    if (call == null) return invalid;

    final native = nativePath.toNativeUtf16();
    try {
      return call(native);
    } on Object {
      return invalid;
    } finally {
      calloc.free(native);
    }
  }

  /// True when Windows marks this path hidden. False for everything it cannot
  /// answer about: an entry is better shown than silently dropped.
  static bool isHidden(String nativePath) {
    final bits = of(nativePath);
    return bits != invalid && bits & hidden != 0;
  }

  /// True when this is a folder that is really a redirect to another one — a
  /// junction, or a directory symlink.
  ///
  /// Windows keeps a set of these for programs written before Vista:
  /// `C:\Documents and Settings` pointing at `C:\Users`, and inside every
  /// profile `Application Data`, `My Documents`, `Start Menu` and the rest.
  /// Every one of them denies Everyone the right to list it — deliberately, so
  /// that old software walking the tree stops at the door instead of walking
  /// the same files twice.
  static bool isDirectoryLink(String nativePath) {
    final bits = of(nativePath);
    return bits != invalid &&
        bits & directory != 0 &&
        bits & reparsePoint != 0;
  }
}
