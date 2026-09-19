import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'sheet_source.dart';
import 'text_encoding.dart';

/// Reads bytes [start] to [end] of the file, or to its end when [end] is null.
typedef SheetByteReader = Stream<List<int>> Function(int start, int? end);

/// A CSV or TSV file as a [SheetSource], read by the host a piece at a time.
///
/// **The first screen does not wait for the file.** The head is read to decide
/// the encoding, the separator and whether there is a header; then one pass
/// runs through the whole file in the background noting where every
/// thirty-second record starts, and rows are cut out of the file between two
/// of those marks when they are asked for. The row count grows as the pass
/// goes, and a row the pass has already gone past can be shown at once.
///
/// Memory is the marks — one number per 32 rows — and a few hundred rows of
/// text kept for scrolling back; not the file. The declarative table this
/// replaces read four megabytes and stopped at 5 000 rows.
///
/// **One set of rules for both passes.** The pass that finds where records
/// start and the reading that splits a record into fields walk the same state
/// machine — a quote opens only at the start of a field, a doubled quote is a
/// quote, a line end inside quotes is part of the field. Two readers that
/// disagreed about one stray quote would put every row after it in the wrong
/// place.
class CsvSheetSource extends SheetSource {
  CsvSheetSource(
    this._read, {
    String? delimiter,
    bool? hasHeader,
    this.headBytes = 64 * 1024,
    String? identity,
  }) : _separator = delimiter,
       _forcedHeader = hasHeader {
    this.identity = identity;
    unawaited(_open());
  }

  final SheetByteReader _read;
  String? _separator;
  final bool? _forcedHeader;

  /// How much of the file is looked at to decide how to read it.
  final int headBytes;

  /// Every [stride]th record's start is noted.
  static const int stride = 32;

  /// Rows are fetched and kept in pieces of this many records.
  static const int chunkRecords = stride * 8;

  /// Pieces kept for scrolling back before the oldest is let go.
  static const int keptChunks = 48;

  /// The most read for one piece. A quote that is never closed makes the rest
  /// of the file one record, and that must not become one read of a gigabyte.
  static const int maxChunkBytes = 16 << 20;

  SheetEncoding _encoding = SheetEncoding.utf8;
  int _unit = 1;
  final List<int> _starts = [];
  int _records = 0;
  int? _end;
  bool _counting = true;
  String? _error;
  bool _hasHeader = false;
  int _columns = 0;
  List<String>? _names;
  List<SheetColumnKind> _kinds = const [];
  bool _decimalComma = false;
  bool _disposed = false;
  StreamSubscription<List<int>>? _pass;

  final LinkedHashMap<int, List<List<String>>> _chunks = LinkedHashMap();
  final Map<int, Future<void>> _loading = {};
  Completer<void>? _progress;

  /// The encoding the file was found to be in.
  SheetEncoding get encoding => _encoding;

  /// The separator in use.
  String get delimiter => _separator ?? ',';

  /// Records found so far, a header included.
  int get records => _records;

  @override
  int get rowCount => _records > _offset ? _records - _offset : 0;

  @override
  int get columnCount => _columns;

  @override
  bool get counting => _counting;

  @override
  String? get error => _error;

  @override
  bool get hasHeader => _hasHeader;

  @override
  List<String>? get columnNames => _hasHeader ? _names : null;

  @override
  List<SheetColumnKind> get columnKinds => _kinds;

  @override
  bool get decimalComma => _decimalComma;

  int get _offset => _hasHeader ? 1 : 0;

  @override
  void setHasHeader(bool value) {
    if (value == _hasHeader) return;
    _hasHeader = value;
    _rekind();
    notifyListeners();
  }

  @override
  List<Object?>? rowAt(int row) {
    if (row < 0) return null;
    final record = row + _offset;
    final chunk = record ~/ chunkRecords;
    final rows = _chunks.remove(chunk);
    if (rows == null) {
      unawaited(_load(chunk));
      return null;
    }
    _chunks[chunk] = rows; // most recently used goes to the back
    final at = record - chunk * chunkRecords;
    return at < rows.length ? rows[at] : const [];
  }

  @override
  Future<void> ensure(int from, int count) async {
    if (count <= 0) return;
    await _ready.future;
    final first = (from + _offset) ~/ chunkRecords;
    final last = (from + _offset + count - 1) ~/ chunkRecords;
    await Future.wait([for (var c = first; c <= last; c++) _load(c)]);
  }

  /// Read in one piece of the file, not a piece per 256 rows: going straight
  /// through a million rows a chunk at a time opened the file four thousand
  /// times, and the opening was most of the cost.
  @override
  Future<List<List<Object?>>> readRows(int from, int count) async {
    if (count <= 0 || from < 0) return const [];
    // Which record row [from] is depends on whether there is a header, and
    // that is not known until the head of the file has been read.
    await _ready.future;
    final firstRecord = from + _offset;
    final firstMark = firstRecord ~/ stride;
    final lastMark = (firstRecord + count + stride - 1) ~/ stride;
    while (!_disposed &&
        _error == null &&
        _counting &&
        _markAt(lastMark) == null) {
      await _nextProgress();
    }
    if (_disposed) return const [];
    final start = _markAt(firstMark);
    if (start == null) return const [];
    final end = _markAt(lastMark) ?? _end;
    if (end == null) return const [];
    final wanted = end - start;
    final List<int> bytes;
    try {
      bytes = await _collect(
        _read(
          start,
          start + (wanted > maxChunkBytes * 4 ? maxChunkBytes * 4 : wanted),
        ),
      );
    } on Object catch (e) {
      _fail('$e');
      return const [];
    }
    final text = decodeSheetText(
      bytes.length % _unit == 0 ? bytes : bytes.sublist(0, bytes.length - 1),
      _encoding,
    );
    final skip = firstRecord - firstMark * stride;
    final records = parseSeparated(text, delimiter, limit: skip + count);
    return records.length <= skip ? const [] : records.sublist(skip);
  }

  /// Resolves when the counting pass is over.
  Future<void> get counted async {
    while (_counting && !_disposed) {
      await _nextProgress();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_pass?.cancel());
    _progress?.complete();
    super.dispose();
  }

  /// Completes once the head has been read and the header decided — or the
  /// file has failed to open, which decides it too.
  final Completer<void> _ready = Completer<void>();

  Future<void> _open() async {
    try {
      await _openHead();
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  Future<void> _openHead() async {
    final List<int> head;
    try {
      head = await _collect(_read(0, headBytes));
    } on Object catch (e) {
      _fail('$e');
      return;
    }
    if (_disposed) return;

    final found = detectSheetEncoding(head);
    _encoding = found.encoding;
    _unit = _encoding.wide ? 2 : 1;
    final text = decodeSheetText(
      head.sublist(
        found.skip,
        head.length - (head.length - found.skip) % _unit,
      ),
      _encoding,
    );
    final complete = head.length < headBytes;
    _separator ??= sniffDelimiter(text);
    _decimalComma = _separator != ',';

    // The head's last record may be cut off; it is left out of the guessing.
    var sample = parseSeparated(text, _separator!);
    if (!complete && sample.length > 1) {
      sample = sample.sublist(0, sample.length - 1);
    }
    _hasHeader =
        _forcedHeader ?? guessHeader(sample, decimalComma: _decimalComma);
    _sample = sample;
    _rekind();

    _startPass(found.skip);
  }

  List<List<String>> _sample = const [];

  void _rekind() {
    final sample = _sample;
    final width = sample.fold<int>(0, (w, r) => r.length > w ? r.length : w);
    if (width > _columns) _columns = width;
    _names = sample.isEmpty
        ? null
        : [
            for (var c = 0; c < _columns; c++)
              c < sample.first.length ? sample.first[c] : '',
          ];
    _kinds = guessColumnKinds(
      sample.skip(_offset).take(500).toList(),
      _columns,
      decimalComma: _decimalComma,
    );
  }

  void _startPass(int skip) {
    final scanner = _Scanner(
      delimiter: _separator!.codeUnitAt(0),
      unit: _unit,
      bigEndian: _encoding == SheetEncoding.utf16be,
      offset: skip,
      starts: _starts,
    );
    var lastTold = 0;
    _pass = _read(skip, null).listen(
      (bytes) {
        scanner.feed(bytes);
        _records = scanner.records;
        // Told in steps, not per piece of the file: a listener redraws, and
        // a redraw per 64 KB is a redraw nobody could see.
        if (_records - lastTold >= chunkRecords || lastTold == 0) {
          lastTold = _records;
          _tell();
        }
      },
      onError: (Object e) => _fail('$e'),
      onDone: () {
        _records = scanner.records;
        _end = scanner.offset;
        _counting = false;
        _tell();
      },
      cancelOnError: true,
    );
  }

  void _tell() {
    if (_disposed) return;
    final waiting = _progress;
    _progress = null;
    waiting?.complete();
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _counting = false;
    _tell();
  }

  Future<void> _nextProgress() => (_progress ??= Completer<void>()).future;

  /// Byte offset of record [record]'s mark, once the pass has found it.
  int? _markAt(int mark) => mark < _starts.length ? _starts[mark] : null;

  Future<void> _load(int chunk) {
    if (_chunks.containsKey(chunk)) return Future.value();
    return _loading[chunk] ??= _fetch(chunk).whenComplete(() {
      _loading.remove(chunk);
    });
  }

  Future<void> _fetch(int chunk) async {
    const marks = chunkRecords ~/ stride;
    final firstMark = chunk * marks;

    // Wait for the pass to reach the end of this piece — or the end of the
    // file, which is the only way the last piece is ever finished.
    while (!_disposed &&
        _error == null &&
        _counting &&
        _markAt(firstMark + marks) == null) {
      await _nextProgress();
    }
    if (_disposed) return;
    final start = _markAt(firstMark);
    if (start == null) return; // past the end of the file
    final end = _markAt(firstMark + marks) ?? _end;
    if (end == null) return;

    final wanted = end - start;
    final List<int> bytes;
    try {
      bytes = await _collect(
        _read(start, start + (wanted > maxChunkBytes ? maxChunkBytes : wanted)),
      );
    } on Object catch (e) {
      _fail('$e');
      return;
    }
    if (_disposed) return;

    final text = decodeSheetText(
      bytes.length % _unit == 0 ? bytes : bytes.sublist(0, bytes.length - 1),
      _encoding,
    );
    final records = parseSeparated(text, delimiter, limit: chunkRecords);

    _chunks[chunk] = records;
    while (_chunks.length > keptChunks) {
      _chunks.remove(_chunks.keys.first);
    }
    final width = records.fold<int>(0, (w, r) => r.length > w ? r.length : w);
    if (width > _columns) {
      _columns = width;
      _rekind();
    }
    notifyListeners();
  }

  static Future<List<int>> _collect(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final piece in stream) {
      builder.add(piece);
    }
    return builder.takeBytes();
  }
}

const int _quote = 0x22;
const int _lf = 0x0A;
const int _cr = 0x0D;

// The four states of a field, shared by the scanner and the parser.
const int _fieldStart = 0;
const int _unquoted = 1;
const int _quoted = 2;
const int _quoteInQuoted = 3;

/// The pass that finds where records start, over bytes.
///
/// Knows nothing about fields beyond whether a quote is open, which is all a
/// line end needs to be told apart from one inside a field. A record starts at
/// the first character after a line end — so a line end with nothing after it
/// is not a record, and a blank line is one with nothing in it.
class _Scanner {
  _Scanner({
    required this.delimiter,
    required this.unit,
    required this.bigEndian,
    required this.offset,
    required this.starts,
  });

  final int delimiter;
  final int unit;
  final bool bigEndian;
  final List<int> starts;

  /// Byte offset of the next byte to be fed.
  int offset;
  int records = 0;

  int _state = _fieldStart;
  bool _atStart = true;
  bool _swallowLf = false;
  int? _half;

  void feed(List<int> piece) {
    // A character cut in two by where one piece of the file ended: its first
    // byte was kept back, and [offset] still points at it.
    final half = _half;
    _half = null;
    final bytes = half == null ? piece : [half, ...piece];

    var state = _state;
    var atStart = _atStart;
    var swallowLf = _swallowLf;
    var at = offset;
    final wide = unit == 2;
    var i = 0;

    final n = bytes.length;
    while (i < n) {
      final int u;
      if (wide) {
        if (i + 1 >= n) {
          _half = bytes[i];
          break;
        }
        u = bigEndian
            ? bytes[i] << 8 | bytes[i + 1]
            : bytes[i] | bytes[i + 1] << 8;
      } else {
        u = bytes[i];
      }

      if (atStart) {
        if (swallowLf && u == _lf) {
          swallowLf = false;
          i += unit;
          at += unit;
          continue;
        }
        swallowLf = false;
        if (records % _strideOf == 0) starts.add(at);
        records++;
        atStart = false;
        state = _fieldStart;
      }

      switch (state) {
        case _fieldStart:
          if (u == _quote) {
            state = _quoted;
          } else if (u == delimiter) {
          } else if (u == _lf) {
            atStart = true;
          } else if (u == _cr) {
            atStart = true;
            swallowLf = true;
          } else {
            state = _unquoted;
          }
        case _unquoted:
          if (u == delimiter) {
            state = _fieldStart;
          } else if (u == _lf) {
            atStart = true;
          } else if (u == _cr) {
            atStart = true;
            swallowLf = true;
          }
        case _quoted:
          if (u == _quote) state = _quoteInQuoted;
        case _quoteInQuoted:
          if (u == _quote) {
            state = _quoted;
          } else if (u == delimiter) {
            state = _fieldStart;
          } else if (u == _lf) {
            atStart = true;
          } else if (u == _cr) {
            atStart = true;
            swallowLf = true;
          } else {
            state = _unquoted;
          }
      }
      i += unit;
      at += unit;
    }

    _state = state;
    _atStart = atStart;
    _swallowLf = swallowLf;
    offset = at;
  }

  static const int _strideOf = CsvSheetSource.stride;
}

/// [text] split into records and fields, by the scanner's rules.
///
/// A blank line is a record with no fields; a line end at the very end of the
/// text makes no record after it. [limit] stops after that many records.
///
/// **Fields are cut out, not built up.** A field with no quotes in it is one
/// `substring`, and a quoted one a substring per run between doubled quotes.
/// Writing every character into a buffer one at a time was most of what a
/// search through a million rows spent its time on.
List<List<String>> parseSeparated(String text, String delimiter, {int? limit}) {
  final d = delimiter.codeUnitAt(0);
  final records = <List<String>>[];
  var record = <String>[];
  final n = text.length;
  var i = 0;

  while (i < n) {
    if (limit != null && records.length >= limit) return records;

    // The start of a record: a line end with nothing before it is a blank
    // line, which is a record with no fields.
    var u = text.codeUnitAt(i);
    if (u == _lf || u == _cr) {
      records.add(const <String>[]);
      i += (u == _cr && i + 1 < n && text.codeUnitAt(i + 1) == _lf) ? 2 : 1;
      continue;
    }

    record = <String>[];
    var ended = false;
    while (!ended) {
      // One field, starting at [i].
      String field;
      if (i < n && text.codeUnitAt(i) == _quote) {
        final parts = StringBuffer();
        var from = i + 1;
        i = from;
        var closed = false;
        while (i < n) {
          if (text.codeUnitAt(i) == _quote) {
            if (i + 1 < n && text.codeUnitAt(i + 1) == _quote) {
              parts
                ..write(text.substring(from, i))
                ..writeCharCode(_quote);
              i += 2;
              from = i;
              continue;
            }
            parts.write(text.substring(from, i));
            i++;
            closed = true;
            break;
          }
          i++;
        }
        if (!closed) parts.write(text.substring(from, i));
        // `"abc"def`: the quote closed early; the rest is kept as written.
        final rest = i;
        while (i < n) {
          u = text.codeUnitAt(i);
          if (u == d || u == _lf || u == _cr) break;
          i++;
        }
        if (i > rest) parts.write(text.substring(rest, i));
        field = parts.toString();
      } else {
        final from = i;
        while (i < n) {
          u = text.codeUnitAt(i);
          if (u == d || u == _lf || u == _cr) break;
          i++;
        }
        field = text.substring(from, i);
      }
      record.add(field);

      if (i >= n) {
        ended = true;
      } else {
        u = text.codeUnitAt(i);
        if (u == d) {
          i++;
          // A separator at the very end of the text or before a line end
          // leaves one more, empty, field.
          if (i >= n) {
            record.add('');
            ended = true;
          }
        } else {
          i += (u == _cr && i + 1 < n && text.codeUnitAt(i + 1) == _lf) ? 2 : 1;
          ended = true;
        }
      }
    }
    records.add(record);
  }
  return records;
}

/// The separator a file uses, from its head.
///
/// Each candidate is tried on the first twenty lines, and the one that splits
/// them into the same number of fields — more than one — the most often wins.
/// "Most often on the first line" was the old rule, and a header of three
/// words separated by semicolons with a comma in one of them fooled it.
String sniffDelimiter(String head) {
  var best = ',';
  var bestScore = 0;
  for (final candidate in const [',', ';', '\t', '|']) {
    final records = parseSeparated(head, candidate, limit: 20);
    if (records.isEmpty) continue;
    final counts = <int, int>{};
    for (final r in records) {
      if (r.length > 1) counts[r.length] = (counts[r.length] ?? 0) + 1;
    }
    if (counts.isEmpty) continue;
    final mode = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final score = mode.value * 1000 + mode.key;
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best;
}
