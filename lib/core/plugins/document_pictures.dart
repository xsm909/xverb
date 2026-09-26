import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Size;

import '../sheet/plugin_sheet_source.dart' show SheetCall;

/// The pictures a rendered document stands on, fetched when they are reached.
///
/// A document names a picture in its own text — `![caption](picture:cover)` —
/// and whoever holds the pictures is asked for the bytes of the ones the
/// reader actually scrolls to. A book of two hundred illustrations costs its
/// text when it is opened, and each picture when it comes into view.
abstract class DocumentPictures {
  /// How big the picture at [ref] is in pixels, if the document said — so the
  /// room for it is kept before the bytes arrive and the text below does not
  /// jump when they do. Null for a picture of unknown size, or one this source
  /// does not hold.
  Size? sizeOf(String ref);

  /// Whether [ref] is one of this source's at all. A document may still link
  /// a picture on the web; that one is not fetched, and is shown by its
  /// caption.
  bool holds(String ref);

  /// The bytes, or null when they could not be had. Asked again for the same
  /// picture, the same answer — fetched once.
  Future<Uint8List?> load(String ref);
}

/// [DocumentPictures] a plugin keeps: the content says which pictures there
/// are and how big, and `document.picture` asks for one's bytes over the
/// plugin's own pipe, the way a sheet asks for rows.
///
/// ```json
/// {"kind": "markdown", "text": "…![Map](picture:p3)…",
///  "pictures": {"handle": "doc-2", "sizes": {"p3": [1200, 800]}, "ids": ["p3"]}}
/// ```
class PluginPictures implements DocumentPictures {
  PluginPictures(Map<String, dynamic> json, this._call)
    : _handle = '${json['handle'] ?? ''}',
      _sizes = {
        for (final entry in ((json['sizes'] as Map?) ?? const {}).entries)
          '${entry.key}': ?_size(entry.value),
      },
      _ids = {
        for (final id in (json['ids'] as List?) ?? const []) '$id',
        for (final id in ((json['sizes'] as Map?) ?? const {}).keys) '$id',
      };

  /// The scheme a document names a plugin's picture by.
  static const String scheme = 'picture:';

  /// How many bytes of fetched pictures are kept. A long book is read from
  /// front to back, and what was left behind is fetched again if the reader
  /// turns back — cheaper than holding a whole illustrated book in memory.
  static const int keepBytes = 64 << 20;

  final String _handle;
  final Map<String, Size> _sizes;
  final Set<String> _ids;
  final SheetCall? _call;

  final LinkedHashMap<String, Uint8List> _kept = LinkedHashMap();
  final Map<String, Future<Uint8List?>> _asked = {};
  int _keptBytes = 0;

  static Size? _size(Object? value) {
    if (value is! List || value.length < 2) return null;
    final width = value[0], height = value[1];
    if (width is! num || height is! num || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width.toDouble(), height.toDouble());
  }

  static String? _idOf(String ref) =>
      ref.startsWith(scheme) ? ref.substring(scheme.length) : null;

  @override
  bool holds(String ref) {
    final id = _idOf(ref);
    return id != null && _ids.contains(id);
  }

  @override
  Size? sizeOf(String ref) {
    final id = _idOf(ref);
    return id == null ? null : _sizes[id];
  }

  @override
  Future<Uint8List?> load(String ref) {
    final id = _idOf(ref);
    final call = _call;
    if (id == null || call == null || !_ids.contains(id)) {
      return Future.value(null);
    }
    final kept = _kept.remove(id);
    if (kept != null) {
      _kept[id] = kept;
      return Future.value(kept);
    }
    // A block body, not an arrow: `remove` hands back this very future, and
    // `whenComplete` waits on a future its callback returns — it would wait
    // on itself for ever.
    return _asked[id] ??= _fetch(call, id).whenComplete(() {
      _asked.remove(id);
    });
  }

  Future<Uint8List?> _fetch(SheetCall call, String id) async {
    try {
      final answer = await call('document.picture', {
        'handle': _handle,
        'id': id,
      });
      if (answer is! Map || answer['data'] is! String) return null;
      final bytes = base64Decode(answer['data'] as String);
      _keep(id, bytes);
      return bytes;
    } on Object {
      // A picture that could not be had is shown by its caption; the reading
      // goes on either way.
      return null;
    }
  }

  void _keep(String id, Uint8List bytes) {
    if (bytes.length > keepBytes) return;
    _kept[id] = bytes;
    _keptBytes += bytes.length;
    while (_keptBytes > keepBytes && _kept.isNotEmpty) {
      final oldest = _kept.keys.first;
      _keptBytes -= _kept.remove(oldest)!.length;
    }
  }
}
