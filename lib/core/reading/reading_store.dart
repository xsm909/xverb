import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A place in a document's reading: a block, a character in it, and the words
/// that stood there.
///
/// **Words, not only numbers.** A block's number and an offset are exact for
/// the reading they were taken from, and a new version of the plugin that
/// reads the file may split it differently. The quote finds the place again
/// when the numbers no longer lead to it — see [ReadingDocument.settle].
@immutable
class ReadingAnchor {
  const ReadingAnchor(this.block, this.offset, this.quote);

  factory ReadingAnchor.fromJson(Map<String, dynamic> json) => ReadingAnchor(
    (json['block'] as num?)?.toInt() ?? 0,
    (json['offset'] as num?)?.toInt() ?? 0,
    json['quote'] as String? ?? '',
  );

  final int block;
  final int offset;
  final String quote;

  Map<String, Object> toJson() => {
    'block': block,
    'offset': offset,
    'quote': quote,
  };

  @override
  bool operator ==(Object other) =>
      other is ReadingAnchor &&
      other.block == block &&
      other.offset == offset &&
      other.quote == quote;

  @override
  int get hashCode => Object.hash(block, offset, quote);
}

/// A passage marked with a colour, and the note written to it if there is one.
@immutable
class Highlight {
  const Highlight({
    required this.id,
    required this.start,
    required this.end,
    required this.text,
    this.colour = 0,
    this.note = '',
    required this.made,
  });

  factory Highlight.fromJson(Map<String, dynamic> json) => Highlight(
    id: json['id'] as String? ?? '',
    start: ReadingAnchor.fromJson(Map<String, dynamic>.from(json['start'] as Map)),
    end: ReadingAnchor.fromJson(Map<String, dynamic>.from(json['end'] as Map)),
    text: json['text'] as String? ?? '',
    colour: (json['colour'] as num?)?.toInt() ?? 0,
    note: json['note'] as String? ?? '',
    made: DateTime.fromMillisecondsSinceEpoch(
      (json['made'] as num?)?.toInt() ?? 0,
    ),
  );

  final String id;

  /// Where it begins and where it ends — the end is one past the last
  /// character, in the block it ends in.
  final ReadingAnchor start;
  final ReadingAnchor end;

  /// The words marked, as they were read.
  final String text;

  /// Which of the marker colours, counted from nought.
  final int colour;

  final String note;
  final DateTime made;

  Highlight copyWith({
    ReadingAnchor? start,
    ReadingAnchor? end,
    int? colour,
    String? note,
  }) => Highlight(
    id: id,
    start: start ?? this.start,
    end: end ?? this.end,
    text: text,
    colour: colour ?? this.colour,
    note: note ?? this.note,
    made: made,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'start': start.toJson(),
    'end': end.toJson(),
    'text': text,
    'colour': colour,
    if (note.isNotEmpty) 'note': note,
    'made': made.millisecondsSinceEpoch,
  };
}

/// What is kept for one document: where its reader stopped, and what they
/// marked in it.
class ReadingDocument {
  ReadingDocument({
    required this.name,
    required this.size,
    this.place,
    List<Highlight>? highlights,
    DateTime? read,
  }) : highlights = highlights ?? [],
       read = read ?? DateTime.now();

  factory ReadingDocument.fromJson(Map<String, dynamic> json) =>
      ReadingDocument(
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? -1,
        place: json['place'] is Map
            ? ReadingAnchor.fromJson(
                Map<String, dynamic>.from(json['place'] as Map),
              )
            : null,
        highlights: [
          for (final h in (json['highlights'] as List? ?? const []))
            if (h is Map) Highlight.fromJson(Map<String, dynamic>.from(h)),
        ],
        read: DateTime.fromMillisecondsSinceEpoch(
          (json['read'] as num?)?.toInt() ?? 0,
        ),
      );

  final String name;
  final int size;
  ReadingAnchor? place;
  final List<Highlight> highlights;
  DateTime read;

  Map<String, Object> toJson() => {
    'name': name,
    'size': size,
    if (place != null) 'place': place!.toJson(),
    if (highlights.isNotEmpty)
      'highlights': [for (final h in highlights) h.toJson()],
    'read': read.millisecondsSinceEpoch,
  };

  /// [anchor] made to point at the text it was taken from, in a reading whose
  /// blocks' plain text is [blocks] — the same place if the words are still
  /// there, else where the quote is found nearest to it, else null.
  static ReadingAnchor? settle(ReadingAnchor anchor, List<String> blocks) {
    bool holds(int block, int offset) =>
        block >= 0 &&
        block < blocks.length &&
        offset >= 0 &&
        offset <= blocks[block].length &&
        blocks[block].startsWith(anchor.quote, offset);

    if (holds(anchor.block, anchor.offset)) return anchor;
    if (anchor.quote.isEmpty) {
      return anchor.block < blocks.length ? anchor : null;
    }
    // Outwards from where it was: the nearest block that has the words.
    for (var distance = 0; distance < blocks.length; distance++) {
      for (final block in {anchor.block - distance, anchor.block + distance}) {
        if (block < 0 || block >= blocks.length) continue;
        final at = blocks[block].indexOf(anchor.quote);
        if (at >= 0) return ReadingAnchor(block, at, anchor.quote);
      }
    }
    return null;
  }
}

/// Everything read and marked, kept by the application in one file.
///
/// **Keyed by where the file is, and found again by what it is.** The path is
/// the key; a document that has moved is found by its name and size, so a
/// book carried to another folder keeps its place and its marks.
class ReadingStore extends ChangeNotifier {
  ReadingStore._(this._file, this._documents);

  /// A store that writes nowhere, for tests and for the moment before the
  /// file has been read.
  ReadingStore.inMemory() : _file = null, _documents = {};

  final File? _file;
  final Map<String, ReadingDocument> _documents;
  Timer? _pending;

  /// How many documents are kept. The oldest read goes first.
  static const int keep = 1000;

  /// How long after a change the file is written: long enough that scrolling
  /// through a book is one write, not one a frame.
  static const Duration settle = Duration(seconds: 2);

  static Future<File> _where() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'reading.json'));
  }

  /// Reads what was written last time. A file that will not parse starts
  /// again — with the file, so what is read from now on is kept.
  static Future<ReadingStore> load() async {
    File? file;
    try {
      file = await _where();
      if (!await file.exists()) return ReadingStore._(file, {});
      final decoded = jsonDecode(await file.readAsString());
      final documents = <String, ReadingDocument>{};
      if (decoded is Map && decoded['documents'] is Map) {
        for (final entry in (decoded['documents'] as Map).entries) {
          if (entry.value is Map) {
            documents['${entry.key}'] = ReadingDocument.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
          }
        }
      }
      return ReadingStore._(file, documents);
    } on Object {
      return file == null ? ReadingStore.inMemory() : ReadingStore._(file, {});
    }
  }

  /// What is kept for the file at [key], found again by [name] and [size] if
  /// it has moved; null when it has never been read here.
  ReadingDocument? find(String key, String name, int size) {
    final found = _documents[key];
    if (found != null) return found;
    if (size < 0) return null;
    for (final entry in _documents.entries) {
      final document = entry.value;
      if (document.name == name && document.size == size) {
        // Moved: kept under its new place from now on.
        _documents.remove(entry.key);
        _documents[key] = document;
        _changed();
        return document;
      }
    }
    return null;
  }

  /// The record for [key], made when there is none.
  ReadingDocument open(String key, String name, int size) {
    final found = find(key, name, size) ??
        (_documents[key] = ReadingDocument(name: name, size: size));
    found.read = DateTime.now();
    return found;
  }

  void setPlace(ReadingDocument document, ReadingAnchor place) {
    if (document.place == place) return;
    document.place = place;
    _changed(quietly: true);
  }

  void addHighlight(ReadingDocument document, Highlight highlight) {
    document.highlights.add(highlight);
    _changed();
  }

  void replaceHighlight(ReadingDocument document, Highlight highlight) {
    final at = document.highlights.indexWhere((h) => h.id == highlight.id);
    if (at < 0) return;
    document.highlights[at] = highlight;
    _changed();
  }

  void removeHighlight(ReadingDocument document, String id) {
    document.highlights.removeWhere((h) => h.id == id);
    _changed();
  }

  /// [quietly]: a place moving as somebody scrolls is written down, but
  /// nothing on screen is waiting to hear about it.
  void _changed({bool quietly = false}) {
    if (!quietly) notifyListeners();
    if (_file == null) return;
    _pending?.cancel();
    _pending = Timer(settle, () => unawaited(save()));
  }

  /// Writes the file now: beside it first and moved into place, so a write
  /// cut short leaves the last good one rather than half of this one.
  Future<void> save() async {
    _pending?.cancel();
    _pending = null;
    final file = _file;
    if (file == null) return;
    if (_documents.length > keep) {
      final oldest = _documents.entries.toList()
        ..sort((a, b) => a.value.read.compareTo(b.value.read));
      for (final entry in oldest.take(_documents.length - keep)) {
        _documents.remove(entry.key);
      }
    }
    try {
      await file.parent.create(recursive: true);
      final draft = File('${file.path}.tmp');
      await draft.writeAsString(
        jsonEncode({
          'documents': {
            for (final entry in _documents.entries)
              entry.key: entry.value.toJson(),
          },
        }),
        flush: true,
      );
      await draft.rename(file.path);
    } on Object {
      // Not being able to write where a book was left is not worth an error
      // over somebody's reading.
    }
  }
}
