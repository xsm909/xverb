import 'dart:ffi';
import 'dart:io';

import '../i18n/i18n.dart';
import 'package:ffi/ffi.dart';

/// What kind of device a drive letter refers to.
enum WindowsDriveKind { unknown, removable, fixed, network, optical, ramDisk }

/// One mounted drive letter.
class WindowsDrive {
  const WindowsDrive(this.letter, this.kind);

  /// Drive letter without the colon, e.g. `C`.
  final String letter;
  final WindowsDriveKind kind;

  String get root => '$letter:\\';

  /// Network drives may be disconnected, in which case touching them blocks.
  bool get mayBeSlow =>
      kind == WindowsDriveKind.network || kind == WindowsDriveKind.optical;

  String get description => switch (kind) {
        WindowsDriveKind.removable => tr('Removable drive'),
        WindowsDriveKind.fixed => tr('Local disk'),
        WindowsDriveKind.network => tr('Network drive'),
        WindowsDriveKind.optical => tr('Optical drive'),
        WindowsDriveKind.ramDisk => tr('RAM disk'),
        WindowsDriveKind.unknown => tr('Drive'),
      };
}

/// Lists mounted drives from the Windows API rather than by probing.
///
/// Probing `A:` through `Z:` with `existsSync` looks harmless and is not: a
/// disconnected network drive or an empty optical drive makes each call block
/// for as long as the redirector's timeout, freezing whatever awaited it.
/// `GetLogicalDrives` is a bitmask read with no I/O at all.
class WindowsDrives {
  const WindowsDrives._();

  static DynamicLibrary? _kernel32;

  static DynamicLibrary get _library =>
      _kernel32 ??= DynamicLibrary.open('kernel32.dll');

  /// Mounted drives, or an empty list off Windows and if the call fails.
  static List<WindowsDrive> list() {
    if (!Platform.isWindows) return const [];

    try {
      final mask = _library.lookupFunction<Uint32 Function(), int Function()>(
        'GetLogicalDrives',
      )();
      if (mask == 0) return const [];

      final driveType = _library.lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)>('GetDriveTypeW');

      final drives = <WindowsDrive>[];
      for (var i = 0; i < 26; i++) {
        if (mask & (1 << i) == 0) continue;
        final letter = String.fromCharCode('A'.codeUnitAt(0) + i);

        // GetDriveTypeW reads the mount table; it does not touch the device.
        final path = '$letter:\\'.toNativeUtf16();
        try {
          drives.add(WindowsDrive(letter, _kindOf(driveType(path))));
        } finally {
          calloc.free(path);
        }
      }
      return drives;
    } on Object {
      return const [];
    }
  }

  static WindowsDriveKind _kindOf(int type) => switch (type) {
        2 => WindowsDriveKind.removable,
        3 => WindowsDriveKind.fixed,
        4 => WindowsDriveKind.network,
        5 => WindowsDriveKind.optical,
        6 => WindowsDriveKind.ramDisk,
        _ => WindowsDriveKind.unknown,
      };
}
