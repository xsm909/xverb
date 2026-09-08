import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

import 'native_icons.dart';

/// The Windows shell's own icon for a file or a folder.
///
/// Asked of the shell by *kind*, not by file: `SHGetFileInfoW` with
/// `SHGFI_USEFILEATTRIBUTES` answers from the extension alone and never touches
/// the disk, so a folder of ten thousand files costs one icon per extension
/// rather than ten thousand lookups. What that gives up is the icons a particular
/// file carries itself — a program's own picture, a shortcut's target — and those
/// are asked for by path, one at a time, because there is no other way to get them.
///
/// The caching and the keys are [NativeIcons]' job; this only fetches.
class WindowsIconSource implements NativeIconSource {
  const WindowsIconSource();

  @override
  Set<String> get ownIcon => const {'exe', 'lnk', 'ico', 'cur', 'msi', 'scr'};

  @override
  Future<ui.Image?> load(
    String nativePath, {
    required bool isDirectory,
    required bool byPath,
  }) =>
      _fromShell(nativePath, isDirectory: isDirectory, byPath: byPath);

  // --- The shell ------------------------------------------------------------

  static const int _shgfiIcon = 0x000000100;
  static const int _shgfiSmallIcon = 0x000000001;
  static const int _shgfiUseFileAttributes = 0x000000010;

  static const int _fileAttributeDirectory = 0x10;
  static const int _fileAttributeNormal = 0x80;

  static Future<ui.Image?> _fromShell(
    String nativePath, {
    required bool isDirectory,
    required bool byPath,
  }) async {
    final shell32 = DynamicLibrary.open('shell32.dll');
    final user32 = DynamicLibrary.open('user32.dll');
    final gdi32 = DynamicLibrary.open('gdi32.dll');

    final getFileInfo = shell32.lookupFunction<
        IntPtr Function(Pointer<Utf16>, Uint32, Pointer<_ShFileInfo>, Uint32,
            Uint32),
        int Function(Pointer<Utf16>, int, Pointer<_ShFileInfo>, int,
            int)>('SHGetFileInfoW');

    final path = nativePath.toNativeUtf16();
    final info = calloc<_ShFileInfo>();
    try {
      // Without USEFILEATTRIBUTES the shell goes to the disk to find out what the
      // path is; with it, the attributes below are taken at face value. Only the
      // handful of types that carry their own icon are asked about by path.
      final flags = _shgfiIcon |
          _shgfiSmallIcon |
          (byPath ? 0 : _shgfiUseFileAttributes);
      final attributes =
          isDirectory ? _fileAttributeDirectory : _fileAttributeNormal;

      final ok = getFileInfo(
        path,
        attributes,
        info,
        sizeOf<_ShFileInfo>(),
        flags,
      );
      if (ok == 0 || info.ref.hIcon == 0) return null;

      try {
        return await _iconToImage(info.ref.hIcon, user32, gdi32);
      } finally {
        user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'DestroyIcon',
        )(info.ref.hIcon);
      }
    } finally {
      calloc.free(path);
      calloc.free(info);
    }
  }

  /// Reads an `HICON`'s pixels out of GDI and hands them to the engine.
  ///
  /// The bits come back bottom-up and in BGRA, which is why the rows are copied
  /// in reverse and the format handed to the engine is `bgra8888` rather than a
  /// conversion being done by hand.
  static Future<ui.Image?> _iconToImage(
    int hIcon,
    DynamicLibrary user32,
    DynamicLibrary gdi32,
  ) async {
    final getIconInfo = user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<_IconInfo>),
        int Function(int, Pointer<_IconInfo>)>('GetIconInfo');
    final getObject = gdi32.lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<_Bitmap>),
        int Function(int, int, Pointer<_Bitmap>)>('GetObjectW');
    final getDC = user32.lookupFunction<IntPtr Function(IntPtr),
        int Function(int)>('GetDC');
    final releaseDC = user32.lookupFunction<Int32 Function(IntPtr, IntPtr),
        int Function(int, int)>('ReleaseDC');
    final getDIBits = gdi32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Uint32, Uint32, Pointer<Uint8>,
            Pointer<_BitmapInfoHeader>, Uint32),
        int Function(int, int, int, int, Pointer<Uint8>,
            Pointer<_BitmapInfoHeader>, int)>('GetDIBits');
    final deleteObject = gdi32.lookupFunction<Int32 Function(IntPtr),
        int Function(int)>('DeleteObject');

    final iconInfo = calloc<_IconInfo>();
    if (getIconInfo(hIcon, iconInfo) == 0) {
      calloc.free(iconInfo);
      return null;
    }

    final bitmap = calloc<_Bitmap>();
    final header = calloc<_BitmapInfoHeader>();
    final dc = getDC(0);
    try {
      if (getObject(iconInfo.ref.hbmColor, sizeOf<_Bitmap>(), bitmap) == 0) {
        return null;
      }
      final width = bitmap.ref.bmWidth;
      final height = bitmap.ref.bmHeight;
      if (width <= 0 || height <= 0) return null;

      header.ref
        ..biSize = sizeOf<_BitmapInfoHeader>()
        ..biWidth = width
        // Negative would ask for top-down rows, which not every driver honours;
        // asking bottom-up and turning them over here always works.
        ..biHeight = height
        ..biPlanes = 1
        ..biBitCount = 32
        ..biCompression = 0;

      final bytes = width * height * 4;
      final pixels = calloc<Uint8>(bytes);
      try {
        final scanned = getDIBits(
          dc,
          iconInfo.ref.hbmColor,
          0,
          height,
          pixels,
          header,
          0, // DIB_RGB_COLORS
        );
        if (scanned == 0) return null;

        final bottomUp = pixels.asTypedList(bytes);
        final rows = Uint8List(bytes);
        final stride = width * 4;
        for (var y = 0; y < height; y++) {
          final from = (height - 1 - y) * stride;
          rows.setRange(y * stride, y * stride + stride, bottomUp, from);
        }

        final completer = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          rows,
          width,
          height,
          ui.PixelFormat.bgra8888,
          completer.complete,
        );
        return await completer.future;
      } finally {
        calloc.free(pixels);
      }
    } finally {
      if (iconInfo.ref.hbmColor != 0) deleteObject(iconInfo.ref.hbmColor);
      if (iconInfo.ref.hbmMask != 0) deleteObject(iconInfo.ref.hbmMask);
      releaseDC(0, dc);
      calloc.free(iconInfo);
      calloc.free(bitmap);
      calloc.free(header);
    }
  }
}

/// `SHFILEINFOW`. The two strings are fixed-length arrays inside the struct, so
/// they are reserved as bytes rather than read — only the icon is wanted here.
final class _ShFileInfo extends Struct {
  @IntPtr()
  external int hIcon;

  @Int32()
  external int iIcon;

  @Uint32()
  external int dwAttributes;

  /// `szDisplayName[MAX_PATH]`, two bytes per character.
  @Array(520)
  external Array<Uint8> displayName;

  /// `szTypeName[80]`.
  @Array(160)
  external Array<Uint8> typeName;
}

/// `ICONINFO`.
final class _IconInfo extends Struct {
  @Int32()
  external int fIcon;

  @Uint32()
  external int xHotspot;

  @Uint32()
  external int yHotspot;

  @IntPtr()
  external int hbmMask;

  @IntPtr()
  external int hbmColor;
}

/// `BITMAP`.
final class _Bitmap extends Struct {
  @Int32()
  external int bmType;

  @Int32()
  external int bmWidth;

  @Int32()
  external int bmHeight;

  @Int32()
  external int bmWidthBytes;

  @Uint16()
  external int bmPlanes;

  @Uint16()
  external int bmBitsPixel;

  @IntPtr()
  external int bmBits;
}

/// `BITMAPINFOHEADER`.
final class _BitmapInfoHeader extends Struct {
  @Uint32()
  external int biSize;

  @Int32()
  external int biWidth;

  @Int32()
  external int biHeight;

  @Uint16()
  external int biPlanes;

  @Uint16()
  external int biBitCount;

  @Uint32()
  external int biCompression;

  @Uint32()
  external int biSizeImage;

  @Int32()
  external int biXPelsPerMeter;

  @Int32()
  external int biYPelsPerMeter;

  @Uint32()
  external int biClrUsed;

  @Uint32()
  external int biClrImportant;
}
