import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/plugins/viewer.dart';
import '../../core/vfs/file_entry.dart';
import '../../core/vfs/fs_registry.dart';
import '../../core/vfs/vfs_path.dart';
import '../sheet/sheet_thumbnail.dart';
import 'vector_view.dart';

/// A small copy of [path] from whichever of [viewers] can make one — what
/// [ThumbnailCache.askPlugin] is, wherever there are viewers to ask.
///
/// A viewer that draws its own is asked for it. **A viewer that reads a file
/// into a drawing needs no picture of its own**: it is asked for the drawing,
/// the one F3 would show, and the host paints it small — see
/// [vectorThumbnail]. That is what gives an SVG a face on the strip.
Future<Uint8List?> askViewers(
  Iterable<RegisteredViewer> viewers,
  VfsPath path,
  int pixels,
) async {
  for (final viewer in viewers) {
    final ask = viewer.thumbnail;
    if (ask != null) {
      final small = await ask(path, pixels);
      if (small != null && small.isNotEmpty) return small;
      continue;
    }
    // A sheet's reader gives a sheet, and the host draws its head small —
    // the rows it opens on, as a page. A CSV used to be a page of its raw
    // text here, commas and all; a workbook, a smear of its bytes.
    if (_readsSheets(viewer)) {
      final sheet = (await viewer.open(path)).sheet;
      if (sheet == null) continue;
      try {
        final small = await sheetThumbnail(sheet, pixels);
        if (small != null && small.isNotEmpty) return small;
      } finally {
        // A CSV source has begun counting the whole file; a thumbnail has
        // no use for the count.
        sheet.dispose();
      }
      continue;
    }
    if (viewer.spec.produces != 'drawing') continue;
    final drawing = (await viewer.open(path)).drawing;
    if (drawing == null || drawing.isEmpty) continue;
    final small = await vectorThumbnail(drawing, pixels);
    if (small != null && small.isNotEmpty) return small;
  }
  return null;
}

/// Whether [viewer] opens files as sheets: a plugin that says it produces
/// spreadsheets, or a declarative viewer whose table the host draws as one.
bool _readsSheets(RegisteredViewer viewer) {
  if (viewer.spec.produces == 'spreadsheet') return true;
  final render = viewer.spec.render;
  if (render == null) return false;
  final kind = render['kind'];
  final source = render['source'];
  return kind == 'sheet' ||
      (kind == 'table' && source != 'json' && source != 'lines');
}

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
/// - **a file over [maxBytes] is read no further than its first page** — a
///   thumbnail is not worth pulling a gigabyte through memory, and the page
///   the cell draws instead needs only [kPageBytes] of it;
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
  final Map<String, List<String>> _pages = {};
  final Map<String, Float32List> _densities = {};
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

  /// The first lines of a file that has no picture, if it is text: what the
  /// strip draws the page of it from. Null for a file that is not text, has
  /// not been read yet, or has been read and forgotten — see [pageLines].
  List<String>? pageOf(FileEntry entry) => _pages[keyOf(entry)];

  /// How dense the bytes of a file are along it, where it has no picture and
  /// is not text: what the strip draws instead of a page. Null otherwise, and
  /// for a file not read yet or read and forgotten — see [byteDensity].
  Float32List? densityOf(FileEntry entry) => _densities[keyOf(entry)];

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
    List<String>? page;
    Float32List? density;
    try {
      if (!_disposed && entry.size > 0) {
        final bytes = await _read(entry);
        if (bytes != null && bytes.isNotEmpty && !_disposed) {
          // Past [maxBytes] only the first page was read, which is no picture
          // of anything and is not offered to the decoder as one.
          if (entry.size <= maxBytes) {
            try {
              image = await _decode(entry, bytes);
            } on Object {
              // A file that will not decode is a file with no thumbnail, which
              // the strip already knows how to draw. It is not an error
              // anybody has to be told about.
              image = null;
            }
          }
          // **The same bytes, not a second read.** Everything a page is made
          // of was read already, to be offered to the decoder — and so is
          // everything the picture of a file that is not text is made of.
          if (image == null) {
            page = pageLines(bytes);
            if (page == null) density = byteDensity(bytes);
          }
        }
      }
    } on Object {
      // A file that cannot be read at all has neither, and the strip draws it
      // as a page with nothing written on it.
      image = null;
    } finally {
      _release();
    }

    _live.remove(key);
    if (_disposed) {
      image?.dispose();
      return null;
    }
    _remember(key, image, page, density);
    return image;
  }

  /// The file's bytes: all of them where it is small enough to be a
  /// thumbnail, and only its first [kPageBytes] where it is not — a log of
  /// half a gigabyte has a first page as much as a note does.
  Future<Uint8List?> _read(FileEntry entry) async {
    final whole = entry.size <= maxBytes;
    final provider = fileSystems.resolve(entry.path);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in provider.openRead(entry.path)) {
      builder.add(chunk);
      if (!whole && builder.length >= kPageBytes) break;
      // A file that grew since it was listed, or a provider that does not know
      // its own sizes. Stop rather than fill memory.
      if (builder.length > maxBytes) return null;
    }
    return builder.takeBytes();
  }

  Future<ui.Image?> _decode(FileEntry entry, Uint8List bytes) async {
    try {
      return await _fromBytes(bytes);
    } on Object {
      // The engine does not read this format on this machine. Whoever opens
      // the file may still be able to draw it, so ask them for a small copy
      // rather than putting a page of it in the cell.
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

  void _remember(
    String key,
    ui.Image? image,
    List<String>? page,
    Float32List? density,
  ) {
    _done[key] = image;
    if (page != null) _pages[key] = page;
    if (density != null) _densities[key] = density;
    _order.add(key);
    while (_order.length > keep) {
      final oldest = _order.removeAt(0);
      _done.remove(oldest)?.dispose();
      _pages.remove(oldest);
      _densities.remove(oldest);
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
    _pages.clear();
    _densities.clear();
    _order.clear();
  }
}

/// How much of a file the page drawn for it is made from: a few dozen lines of
/// anything, and on a file too big to be a thumbnail the only part read.
const int kPageBytes = 4096;

/// How many columns the picture of a file's bytes has — see [byteDensity].
const int kDensityColumns = 64;

/// How many bytes of each column are counted: enough for the count to mean
/// something, and few enough that the whole picture costs well under a
/// millisecond however big the file is.
const int kDensitySample = 1024;

/// The picture of a file that has no picture and is not text: how dense its
/// bytes are, from its start to its end.
///
/// **Each column is a stretch of the file**, and its height is the entropy of
/// the bytes counted there, as a fraction of the most that many bytes can
/// hold. Nothing where the file is one byte over and over — padding, a region
/// of nothing — and near the top where it is compressed or encrypted. So a zip
/// is a high even wall, a program a skyline of code, tables and gaps, and an
/// image of a disk mostly ground. It says something true about what is in the
/// file, which a square with its extension in it does not.
///
/// **The same bytes, not a second read** — see [ThumbnailCache]. A file too
/// big to be a thumbnail had only its first [kPageBytes] read, so its columns
/// are of those and go no further. Null for a file of nothing.
Float32List? byteDensity(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  // At least a byte a column, so a tiny file has fewer columns rather than
  // empty ones.
  final columns = math.min(kDensityColumns, bytes.length);
  final density = Float32List(columns);
  final counts = Int32List(256);
  for (var column = 0; column < columns; column++) {
    final start = bytes.length * column ~/ columns;
    final end = math.min(
      bytes.length * (column + 1) ~/ columns,
      start + kDensitySample,
    );
    final counted = end - start;
    counts.fillRange(0, 256, 0);
    for (var i = start; i < end; i++) {
      counts[bytes[i]]++;
    }
    var entropy = 0.0;
    for (final count in counts) {
      if (count == 0) continue;
      final share = count / counted;
      entropy -= share * math.log(share);
    }
    // Sixteen bytes can hold at most four bits each, not eight: measured
    // against what they could have held, a short column of noise is as full
    // as a long one.
    final most = math.log(math.min(256, counted));
    density[column] = most == 0 ? 0 : (entropy / most).clamp(0, 1).toDouble();
  }
  return density;
}

/// The first lines of [bytes], if they are text — what a cell with no picture
/// draws as a page of the file. Null where they are not.
///
/// **Text is decided by what is in it, not by the name.** A viewer that falls
/// back on everything walks folders of `.bin`, `.dat` and files with no
/// extension at all, and some of those are text and some are not. A byte of
/// nothing is the mark of one that is not — no encoding in use writes one
/// except UTF-16, and UTF-16 says so in its first two bytes — and control
/// characters past one in twenty are the other.
///
/// **Drawn is the test, not spelt.** Text that is not UTF-8 is most often an
/// eight-bit code page — a note written in Windows-1251 is the ordinary case
/// here — and no code page can be told from another by looking at it. So it is
/// read as Latin-1: the letters come out wrong and the page comes out right,
/// which at the size a page is drawn is the only part anybody sees.
List<String>? pageLines(Uint8List bytes, {int most = 40, int widest = 120}) {
  final head = bytes.length > kPageBytes
      ? Uint8List.sublistView(bytes, 0, kPageBytes)
      : bytes;
  final String text;
  if (head.length >= 2 &&
      ((head[0] == 0xFF && head[1] == 0xFE) ||
          (head[0] == 0xFE && head[1] == 0xFF))) {
    final little = head[0] == 0xFF;
    text = String.fromCharCodes([
      for (var i = 2; i + 1 < head.length; i += 2)
        little ? head[i] | head[i + 1] << 8 : head[i] << 8 | head[i + 1],
    ]);
  } else {
    if (head.contains(0)) return null;
    final start = head.length >= 3 &&
            head[0] == 0xEF &&
            head[1] == 0xBB &&
            head[2] == 0xBF
        ? 3
        : 0;
    final body = Uint8List.sublistView(head, start);
    final read = utf8.decode(body, allowMalformed: true);
    final broken = '�'.allMatches(read).length;
    text = broken * 20 > read.length ? latin1.decode(body) : read;
  }

  var controls = 0;
  for (final unit in text.codeUnits) {
    if (unit < 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0C &&
        unit != 0x0D) {
      controls++;
    }
  }
  if (controls * 20 > text.length) return null;

  final out = <String>[];
  for (final raw in text.split('\n')) {
    if (out.length == most) break;
    final line = (raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw)
        .replaceAll('\t', '    ');
    out.add(line.length > widest ? line.substring(0, widest) : line);
  }
  return out;
}
