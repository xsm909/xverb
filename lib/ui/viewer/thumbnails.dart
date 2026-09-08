import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/vfs/file_entry.dart';
import '../../core/vfs/fs_registry.dart';

/// Small pictures of files, for the strip along the bottom of a viewer.
///
/// **The engine makes them, at the size they are wanted.**
/// `instantiateImageCodec` takes a `targetWidth`, and a decoder given one
/// decodes *to* it rather than decoding the whole picture and throwing the
/// pixels away — so a 24-megapixel photograph costs about what a small one
/// does. Shrinking a full-size `ui.Image` afterwards would be the same work
/// plus the memory, which is the mistake this class exists to not make.
///
/// **And where it cannot, the plugin is asked.** The engine reads what the
/// machine's own decoder reads, and the two machines do not agree — png, jpeg,
/// gif and bmp everywhere; tiff and heic on both; tga and psd on macOS only;
/// xcf nowhere. What it refuses used to get a name in the cell instead of a
/// picture. A viewer that reads the format anyway can now be asked for a small
/// copy — [askPlugin] — and most of those formats carry a cheap preview inside
/// them for exactly this.
///
/// **In that order, and never the other way round.** The engine costs no
/// process and no pipe and decodes straight to the size wanted; the plugin
/// costs both and has to do real work. So it is asked second, and only about a
/// file the engine has already refused.
///
/// Three things keep a fast scroll from bringing the application down:
///
/// - **at most [_atOnce] decodes are in flight**, so flying along a folder of
///   five hundred files queues rather than forks;
/// - **a file over [maxBytes] is not read at all** — a thumbnail is not worth
///   pulling a gigabyte through memory, and the cell says the name instead;
/// - **a refusal is remembered.** A file that cannot be decoded is asked once
///   and never again, which matters because failure is the slow answer.
class ThumbnailCache {
  ThumbnailCache({
    required this.fileSystems,
    this.askPlugin,
    this.pixels = 128,
    this.keep = 240,
  });

  final FileSystemRegistry fileSystems;

  /// Who to ask for a small copy of a file the engine will not decode, and how
  /// wide to ask for. Null where there is nobody to ask, which is every caller
  /// that does not have the plugins to hand — a test, a preview.
  final Future<Uint8List?> Function(FileEntry entry, int pixels)? askPlugin;

  /// How wide a thumbnail is decoded, in device pixels. Wider than any cell so
  /// the same picture serves a larger row without being read twice.
  final int pixels;

  /// Above this a file is left alone. A thumbnail is a convenience, and no
  /// convenience is worth reading 64 MB for.
  static const int maxBytes = 64 * 1024 * 1024;

  /// How many files are being read and decoded at any moment.
  ///
  /// Fewer on Linux, because a decode there costs the whole picture in memory
  /// for as long as it takes to shrink it — see [_fromBytes]. Four
  /// hundred-megapixel photographs at once is not a queue, it is a swap file.
  int get _atOnce => Platform.isLinux ? 2 : 4;

  /// How many are kept. A strip shows a dozen; this holds a long walk through
  /// a folder without letting a folder of thousands grow without bound. Only a
  /// test ever sets it: a cache of three makes eviction happen in a folder of
  /// eight rather than in one of hundreds.
  final int keep;

  final Map<String, Future<ui.Image?>> _live = {};
  final Map<String, ui.Image?> _done = {};
  final List<String> _order = [];
  int _running = 0;
  final List<Completer<void>> _waiting = [];
  bool _disposed = false;

  /// What identifies a picture: where it is, how big, and when it was written.
  /// A file replaced under the same name gets a new thumbnail rather than the
  /// old one.
  static String keyOf(FileEntry entry) =>
      '${entry.path}\x00${entry.size}\x00'
      '${entry.modified?.millisecondsSinceEpoch ?? 0}';

  /// How big the picture is, if it is already here. **A size rather than the
  /// picture**, because measuring is what the strip does with it and a
  /// `ui.Image` handed out for measuring is a `ui.Image` somebody will
  /// eventually paint — see [take] for why that is the whole of this class's
  /// one dangerous edge.
  ui.Size? sizeOf(FileEntry entry) {
    final image = _done[keyOf(entry)];
    return image == null
        ? null
        : ui.Size(image.width.toDouble(), image.height.toDouble());
  }

  /// The thumbnail to *draw*, if it is already here: a handle of the caller's
  /// own, which the caller disposes.
  ///
  /// **A copy, and the reason is the one defect this class has ever had.** The
  /// cache keeps [keep] pictures and disposes the rest — and a disposed
  /// `ui.Image` is not a blank one, it is a dead handle. While what it handed
  /// out *was* its own copy, the cell still holding one went on asking the
  /// engine to draw a picture that was gone: an assertion in a debug build,
  /// and in the build he runs an empty frame where a photograph had been. He
  /// found a block of two dozen of them in the middle of a folder of hundreds
  /// — the ones decoded earliest, which are the ones evicted first.
  ///
  /// `clone` is what this is for: the pixels live until the last handle to
  /// them is disposed, and the cache's own copy is no longer the only one.
  ui.Image? take(FileEntry entry) => _done[keyOf(entry)]?.clone();

  /// Whether this file has already been tried and refused.
  bool refused(FileEntry entry) {
    final key = keyOf(entry);
    return _done.containsKey(key) && _done[key] == null;
  }

  /// Asks for one. Safe to call again for the same file: the second caller
  /// waits on the first request rather than starting a second.
  ///
  /// What comes back is the caller's own handle, as [take] explains — and it
  /// is taken *after* the wait, from what the cache holds by then, so that two
  /// callers waiting on one decode do not come away sharing a copy.
  Future<ui.Image?> of(FileEntry entry) async {
    final key = keyOf(entry);
    if (!_done.containsKey(key)) {
      await (_live[key] ??= _make(entry, key));
    }
    return _done[key]?.clone();
  }

  Future<ui.Image?> _make(FileEntry entry, String key) async {
    await _slot();
    ui.Image? image;
    try {
      if (!_disposed && entry.size <= maxBytes && entry.size > 0) {
        image = await _decode(entry);
      }
    } on Object {
      // A file that will not decode is a file with no thumbnail, which the
      // strip already knows how to draw. It is not an error anybody has to
      // be told about.
      image = null;
    } finally {
      _release();
    }

    _live.remove(key);
    if (_disposed) {
      image?.dispose();
      return null;
    }
    _remember(key, image);
    return image;
  }

  Future<ui.Image?> _decode(FileEntry entry) async {
    final provider = fileSystems.resolve(entry.path);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in provider.openRead(entry.path)) {
      builder.add(chunk);
      // A file that grew since it was listed, or a provider that does not know
      // its own sizes. Stop rather than fill memory.
      if (builder.length > maxBytes) return null;
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty || _disposed) return null;

    try {
      return await _fromBytes(bytes);
    } on Object {
      // The engine does not read this format on this machine. Whoever opens
      // the file may still be able to draw it, so ask them for a small copy
      // rather than putting a name in the cell.
      final ask = askPlugin;
      if (ask == null || _disposed) rethrow;
      final small = await ask(entry, pixels);
      if (small == null || small.isEmpty || _disposed) return null;
      return _fromBytes(small);
    }
  }

  /// Decodes one picture, thumbnail-sized.
  ///
  /// `targetWidth` is the whole point of doing it this way — the decoder
  /// resizes as it reads, so a 24-megapixel photograph costs about what a
  /// small one does. On Linux it is also where the picture is lost: Impeller
  /// does that resize on the GPU, and on the `nouveau` driver what comes back
  /// is a grey block, a shred of the picture, or a piece of some other
  /// texture. Measured with the same file at the same size: `targetWidth`
  /// under the picture's own width is corrupt, `targetWidth` above it — where
  /// no resize happens — is clean, and so is shrinking it here afterwards.
  ///
  /// So Linux reads the whole picture and shrinks it with a draw of its own,
  /// which is a plain rendering and comes out right. It costs the full picture
  /// in memory until the small one exists, which is why [_atOnce] is lower
  /// there; the cache itself still only ever holds thumbnails.
  Future<ui.Image> _fromBytes(Uint8List bytes) async {
    if (!Platform.isLinux) {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: pixels);
      try {
        final frame = await codec.getNextFrame();
        return frame.image;
      } finally {
        codec.dispose();
      }
    }

    final codec = await ui.instantiateImageCodec(bytes);
    ui.Image full;
    try {
      full = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    // Already small enough: the engine would have stretched it up to the
    // thumbnail width, and a stretched thumbnail is a blurred one.
    if (full.width <= pixels) return full;
    try {
      return await _shrink(full);
    } finally {
      full.dispose();
    }
  }

  /// Draws [full] into a thumbnail-sized picture of its own.
  ///
  /// [ui.FilterQuality.low] rather than anything smoother, for the same reason
  /// the rest of the interface uses it on Linux: see `ui/picture_filter.dart`.
  Future<ui.Image> _shrink(ui.Image full) async {
    final height = (full.height * pixels / full.width).round().clamp(1, pixels * 8);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      full,
      ui.Rect.fromLTWH(0, 0, full.width.toDouble(), full.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, pixels.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(pixels, height);
    } finally {
      picture.dispose();
    }
  }

  void _remember(String key, ui.Image? image) {
    _done[key] = image;
    _order.add(key);
    while (_order.length > keep) {
      final oldest = _order.removeAt(0);
      _done.remove(oldest)?.dispose();
    }
  }

  /// Waits for one of the [_atOnce] places to come free.
  Future<void> _slot() async {
    if (_running < _atOnce) {
      _running++;
      return;
    }
    final waiting = Completer<void>();
    _waiting.add(waiting);
    return waiting.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
      return;
    }
    _running--;
  }

  void dispose() {
    _disposed = true;
    for (final image in _done.values) {
      image?.dispose();
    }
    _done.clear();
    _order.clear();
  }
}
