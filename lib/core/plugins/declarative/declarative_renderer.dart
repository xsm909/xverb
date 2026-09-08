import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../i18n/i18n.dart';
import '../../vfs/fs_registry.dart';
import '../../vfs/vfs_path.dart';
import '../viewer.dart';
import 'render_spec.dart';

/// Executes a [RenderSpec] against a file.
///
/// These are the primitives declarative plugins compose. Keeping the set small
/// and honest is the point: a declarative plugin can only ever do what is
/// implemented here, which is exactly why it is safe to ship and to load on
/// platforms where running plugin code is impossible.
class DeclarativeRenderer {
  const DeclarativeRenderer(this.fileSystems, {this.languageOf});

  final FileSystemRegistry fileSystems;

  /// What language a file of a given extension is written in, asked of
  /// whoever holds the grammars — which is the registry, and which is not
  /// something this file is allowed to know about.
  ///
  /// Only used for `syntax: auto`, and null in a build that has no grammars at
  /// all, which then colours nothing rather than guessing.
  final String Function(String extension, String name)? languageOf;

  Future<ViewerContent> render(VfsPath path, RenderSpec spec) async {
    if (!spec.isSupported) {
      return ViewerContent.error(
          tr('Unknown render kind "{kind}".', {'kind': spec.kind}));
    }

    // Sound is the one primitive that does not want the bytes. The machine's own
    // player opens the file itself — it has to, since it decodes as it goes and
    // an hour of music is not something to hold in memory — so what the content
    // carries is where the file is, and nothing is read here at all.
    if (spec.kind == 'audio') return _renderAudio(path, spec);

    final Uint8List bytes;
    try {
      bytes = await _read(path, spec.maxBytes);
    } on Object catch (e) {
      return ViewerContent.error('$e');
    }

    // One byte over the limit is how we detect there was more to read.
    final truncated = bytes.length > spec.maxBytes;
    final data = truncated
        ? Uint8List.sublistView(bytes, 0, spec.maxBytes)
        : bytes;

    switch (spec.kind) {
      case 'image':
        if (data.isEmpty) return ViewerContent.error(tr('The file is empty.'));
        if (truncated) {
          return ViewerContent.error(
            tr('Image is larger than {size} MB.',
                {'size': spec.maxBytes >> 20}),
          );
        }
        return ViewerContent(
          kind: ViewerContentKind.image,
          bytes: data,
          mimeType: _mimeFor(path),
        );

      case 'hex':
        return ViewerContent(
          kind: ViewerContentKind.text,
          text: _hexDump(data),
          truncated: truncated,
        );

      case 'markdown':
        return ViewerContent(
          kind: ViewerContentKind.markdown,
          text: _decode(data, spec.encoding),
          truncated: truncated,
        );

      case 'table':
        return _renderTable(_decode(data, spec.encoding), spec, truncated);

      case 'text':
      default:
        return _renderText(
          _decode(data, spec.encoding),
          spec,
          truncated,
          _languageFor(path, spec),
        );
    }
  }

  /// Where the sound is, as a local file the platform's player can open.
  ///
  /// A file on the disk is handed over as it stands. Anything else — inside an
  /// archive, on a server, served by a plugin — is copied out to the temporary
  /// directory first, because a player is given a path and cannot be given a
  /// stream that only this application knows how to read. The copy is left for
  /// the system to clear up, which is what a temporary directory is for.
  Future<ViewerContent> _renderAudio(VfsPath path, RenderSpec spec) async {
    if (path.scheme == VfsPath.localScheme) {
      return ViewerContent(
        kind: ViewerContentKind.audio,
        url: path.uri.toString(),
      );
    }

    try {
      final directory = Directory(
        p.join(Directory.systemTemp.path, 'xverb-sound'),
      );
      await directory.create(recursive: true);
      final copy = File(p.join(directory.path, path.name));
      final sink = copy.openWrite();
      var written = 0;
      try {
        await for (final chunk in fileSystems.resolve(path).openRead(path)) {
          written += chunk.length;
          if (written > spec.maxBytes) {
            return ViewerContent.error(
              tr('This sound is larger than {size} MB.',
                  {'size': spec.maxBytes >> 20}),
            );
          }
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      return ViewerContent(
        kind: ViewerContentKind.audio,
        url: Uri.file(copy.path, windows: Platform.isWindows).toString(),
      );
    } on Object catch (e) {
      return ViewerContent.error('$e');
    }
  }

  Future<Uint8List> _read(VfsPath path, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    // Ask for one extra byte so a file exactly at the limit is not reported
    // as truncated.
    await for (final chunk
        in fileSystems.resolve(path).openRead(path, start: 0, end: maxBytes + 1)) {
      builder.add(chunk);
      if (builder.length > maxBytes) break;
    }
    return builder.takeBytes();
  }

  /// The bytes as text, in whatever they turn out to be written in.
  ///
  /// [encoding] is what the plugin declared, and it is not always the truth —
  /// most of them declare nothing and take the default. So the bytes are asked
  /// first: a byte-order mark is definitive, and a file full of NULs at every
  /// other position is UTF-16 whatever anybody said.
  ///
  /// **Found the hard way.** A README written on Windows in UTF-16LE with no
  /// mark came out with a NUL between every letter. `#` stopped being a heading
  /// because what followed it was not a space, and a blank line stopped being
  /// blank because it held a NUL — so the whole file collapsed into one
  /// paragraph. It read as the markdown viewer being broken; it was the file
  /// being read as the wrong alphabet.
  static String _decode(Uint8List bytes, String encoding) =>
      _endings(_characters(bytes, encoding));

  /// Every line ending as `\n`.
  ///
  /// A file written on Windows ends its lines `\r\n` and one written on a Mac
  /// before OS X ends them `\r`. Left as they are, the `\r` is not a break to
  /// anything that splits on `\n` — it is an invisible character inside the
  /// line, and a whole file comes out as one line with holes in it. Xcode,
  /// open beside this one on the same file, showed the lines it has; this is
  /// how it knows them.
  static String _endings(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  static String _characters(Uint8List bytes, String encoding) {
    if (encoding == 'latin1' || encoding == 'iso-8859-1') {
      return latin1.decode(bytes, allowInvalid: true);
    }

    final wide = _utf16(bytes, encoding);
    if (wide != null) return wide;

    // Two-byte text whose pairing does not hold. One byte inserted into a
    // UTF-16 file — an editor that did not know what it was opening — shifts
    // everything after it by one, so the NULs change sides halfway through and
    // no single answer is right for the whole file. Read literally it is a row
    // of empty boxes, which tells nobody anything. The NULs are dropped and
    // what is left is read as text: the file is damaged, and this is the most
    // of it that can still be shown.
    if (_isMostlyNul(bytes)) {
      return const Utf8Decoder(allowMalformed: true)
          .convert(bytes.where((byte) => byte != 0).toList(growable: false));
    }

    // A UTF-8 mark is not part of the text and shows as a stray glyph.
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return const Utf8Decoder(allowMalformed: true)
          .convert(bytes.sublist(3));
    }
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }

  /// Whether a quarter of the bytes are NUL, which no text ever is.
  ///
  /// The quarter is the point: real two-byte Latin text is nearly half NUL, and
  /// text in an alphabet that needs the high byte — Cyrillic, Greek, anything
  /// past Latin-1 — has almost none, so this only catches what it is for.
  static bool _isMostlyNul(Uint8List bytes) {
    if (bytes.length < 8) return false;
    final sample = bytes.length < 512 ? bytes.length : 512;
    var nuls = 0;
    for (var i = 0; i < sample; i++) {
      if (bytes[i] == 0) nuls++;
    }
    return nuls * 4 > sample;
  }

  /// [bytes] as UTF-16, or null when they are not.
  ///
  /// Dart has no decoder for this, and does not need one: a string *is* UTF-16
  /// code units, so pairing the bytes up is the whole of it — surrogates
  /// included, because a pair that forms one is already correct.
  static String? _utf16(Uint8List bytes, String encoding) {
    if (bytes.length < 2) return null;

    // Plain ASCII line endings in front of two-byte text — what appending to
    // a UTF-16 file from a shell leaves behind. Read as UTF-16 they come out
    // as one Malayalam letter per pair, which is never what a file starts
    // with; read as what they are, they are the blank lines the file has.
    var prefix = 0;
    while (prefix + 1 < bytes.length &&
        (bytes[prefix] == 0x0D || bytes[prefix] == 0x0A) &&
        bytes[prefix + 1] != 0) {
      prefix++;
    }
    if (prefix > 0) {
      final rest = _utf16(Uint8List.sublistView(bytes, prefix), encoding);
      if (rest == null) return null;
      return String.fromCharCodes(bytes.sublist(0, prefix)) + rest;
    }

    final declared = encoding == 'utf-16' || encoding == 'utf-16le'
        ? true
        : encoding == 'utf-16be'
            ? false
            : null;

    var little = declared;
    var start = 0;

    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      little = true;
      start = 2;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      little = false;
      start = 2;
    } else if (little == null) {
      // No mark and nobody said. Counted rather than guessed: text in this
      // alphabet is mostly Latin, so one byte of every pair is zero. Half the
      // sample is a deliberately low bar — a file that is half NUL at every
      // other position is not UTF-8 that happens to look like this.
      final sample = bytes.length < 512 ? bytes.length : 512;
      var evens = 0;
      var odds = 0;
      for (var i = 0; i + 1 < sample; i += 2) {
        if (bytes[i] == 0) evens++;
        if (bytes[i + 1] == 0) odds++;
      }
      final pairs = sample ~/ 2;
      if (pairs < 4) return null;
      if (odds > pairs / 2 && odds > evens) {
        little = true;
      } else if (evens > pairs / 2 && evens > odds) {
        little = false;
      } else {
        return null;
      }
    }

    final units = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      units.add(little
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  /// Which language this file is to be coloured as: the one the viewer named,
  /// or — for `auto` — whichever grammar claims the extension.
  String _languageFor(VfsPath path, RenderSpec spec) {
    final asked = spec.syntax.toLowerCase();
    if (asked.isEmpty) return '';
    if (asked != 'auto') return asked;

    // The extension where there is one, and the whole name either way: a
    // `LICENSE` has no extension at all and a `.gitignore`'s is its name.
    final dot = path.name.lastIndexOf('.');
    final extension = dot > 0 && dot < path.name.length - 1
        ? path.name.substring(dot + 1).toLowerCase()
        : '';
    return languageOf?.call(extension, path.name) ?? '';
  }

  ViewerContent _renderText(
    String body,
    RenderSpec spec,
    bool truncated,
    String language,
  ) {
    if (spec.transform == 'json-pretty' && !truncated) {
      try {
        final pretty =
            const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
        // Said out loud, because the indenting on its own is invisible: a file
        // that arrived pretty-printed comes back looking exactly as it went
        // in. `language` is what the viewer colours by.
        return ViewerContent(
          kind: ViewerContentKind.text,
          text: pretty,
          language: 'json',
        );
      } on FormatException catch (e) {
        // Showing the raw text plus the parse error beats hiding the file.
        return ViewerContent(
          kind: ViewerContentKind.text,
          text: '// Not valid JSON: ${e.message}\n\n$body',
        );
      }
    }
    return ViewerContent(
      kind: ViewerContentKind.text,
      text: body,
      language: language.isEmpty ? null : language,
      truncated: truncated,
    );
  }

  ViewerContent _renderTable(String body, RenderSpec spec, bool truncated) {
    switch (spec.source) {
      case 'json':
        return _tableFromJson(body, spec);
      case 'lines':
        final lines = const LineSplitter().convert(body);
        final capped = lines.take(spec.maxRows).toList();
        return ViewerContent(
          kind: ViewerContentKind.table,
          columns: [
            const ListingColumn(label: '#', width: 56, align: ListingAlign.end),
            ListingColumn(
                label: tr('Line'), flex: 1, kind: ListingCellKind.mono),
          ],
          rows: [
            for (var i = 0; i < capped.length; i++)
              ListingRow.of(['${i + 1}', capped[i]]),
          ],
          truncated: truncated || lines.length > capped.length,
        );
      case 'tsv':
        return _tableFromSeparated(body, '\t', spec, truncated);
      case 'csv':
      default:
        final separator = spec.delimiter == 'auto'
            ? _sniffDelimiter(body)
            : (spec.delimiter.isEmpty ? ',' : spec.delimiter[0]);
        return _tableFromSeparated(body, separator, spec, truncated);
    }
  }

  ViewerContent _tableFromJson(String body, RenderSpec spec) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      return ViewerContent.error(
          tr('Not valid JSON: {error}', {'error': e.message}));
    }
    if (decoded is! List) {
      return ViewerContent.error(tr('Expected a JSON array at the top level.'));
    }

    final items = decoded.take(spec.maxRows).toList();
    if (items.isEmpty) {
      return const ViewerContent(kind: ViewerContentKind.table);
    }

    if (items.first is Map) {
      // Union of keys in first-seen order, so sparse records still line up.
      final columns = <String>[];
      for (final item in items) {
        if (item is! Map) continue;
        for (final key in item.keys) {
          final name = key.toString();
          if (!columns.contains(name)) columns.add(name);
        }
      }
      return ViewerContent(
        kind: ViewerContentKind.table,
        columns: ListingColumn.list(columns),
        rows: [
          for (final item in items)
            ListingRow.of([
              for (final column in columns)
                item is Map ? (item[column]?.toString() ?? '') : '',
            ]),
        ],
        truncated: decoded.length > items.length,
      );
    }

    if (items.first is List) {
      final width =
          items.fold<int>(0, (w, r) => r is List && r.length > w ? r.length : w);
      return ViewerContent(
        kind: ViewerContentKind.table,
        columns: ListingColumn.list([for (var i = 0; i < width; i++) '${i + 1}']),
        rows: [
          for (final item in items)
            ListingRow.of([
              for (var i = 0; i < width; i++)
                item is List && i < item.length
                    ? (item[i]?.toString() ?? '')
                    : '',
            ]),
        ],
        truncated: decoded.length > items.length,
      );
    }

    return ViewerContent(
      kind: ViewerContentKind.table,
      columns: ListingColumn.list([tr('Value')]),
      rows: [for (final item in items) ListingRow.of([item?.toString() ?? ''])],
      truncated: decoded.length > items.length,
    );
  }

  ViewerContent _tableFromSeparated(
    String body,
    String separator,
    RenderSpec spec,
    bool truncated,
  ) {
    final records = _parseSeparated(body, separator, spec.maxRows + 1);
    if (records.isEmpty) {
      return const ViewerContent(kind: ViewerContentKind.table);
    }

    final overflowed = records.length > spec.maxRows;
    final rows = overflowed ? records.sublist(0, spec.maxRows) : records;

    List<String> columns;
    List<List<String>> body_;
    if (spec.hasHeader) {
      columns = rows.first;
      body_ = rows.skip(1).toList();
    } else {
      final width = rows.fold<int>(0, (w, r) => r.length > w ? r.length : w);
      columns = [for (var i = 0; i < width; i++) '${i + 1}'];
      body_ = rows;
    }

    // Pad short records so every row matches the header width.
    for (final row in body_) {
      while (row.length < columns.length) {
        row.add('');
      }
    }

    return ViewerContent(
      kind: ViewerContentKind.table,
      columns: ListingColumn.list(columns),
      rows: [for (final row in body_) ListingRow.of(row)],
      truncated: truncated || overflowed,
    );
  }

  /// A small RFC 4180 reader: quoted fields, doubled quotes, embedded
  /// separators and newlines. Enough for real spreadsheets exported to CSV.
  static List<List<String>> _parseSeparated(
    String body,
    String separator,
    int maxRecords,
  ) {
    final records = <List<String>>[];
    var record = <String>[];
    final field = StringBuffer();
    var inQuotes = false;

    void endField() {
      record.add(field.toString());
      field.clear();
    }

    void endRecord() {
      endField();
      // Skip the blank record a trailing newline produces.
      if (record.length > 1 || record.first.isNotEmpty) records.add(record);
      record = <String>[];
    }

    for (var i = 0; i < body.length; i++) {
      final char = body[i];

      if (inQuotes) {
        if (char == '"') {
          if (i + 1 < body.length && body[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(char);
        }
        continue;
      }

      if (char == '"' && field.isEmpty) {
        inQuotes = true;
      } else if (char == separator) {
        endField();
      } else if (char == '\n') {
        endRecord();
        if (records.length >= maxRecords) return records;
      } else if (char != '\r') {
        field.write(char);
      }
    }

    if (field.isNotEmpty || record.isNotEmpty) endRecord();
    return records;
  }

  /// Picks whichever candidate appears most often on the first line.
  static String _sniffDelimiter(String body) {
    final newline = body.indexOf('\n');
    final line = newline < 0 ? body : body.substring(0, newline);

    var best = ',';
    var bestCount = 0;
    for (final candidate in [',', ';', '\t', '|']) {
      final count = candidate.allMatches(line).length;
      if (count > bestCount) {
        best = candidate;
        bestCount = count;
      }
    }
    return best;
  }

  static String _hexDump(Uint8List data) {
    final buffer = StringBuffer();
    for (var offset = 0; offset < data.length; offset += 16) {
      final end = (offset + 16).clamp(0, data.length);
      final chunk = data.sublist(offset, end);

      buffer.write(offset.toRadixString(16).padLeft(8, '0'));
      buffer.write('  ');
      for (var i = 0; i < 16; i++) {
        buffer.write(
          i < chunk.length ? chunk[i].toRadixString(16).padLeft(2, '0') : '  ',
        );
        buffer.write(' ');
      }
      buffer.write(' |');
      for (final byte in chunk) {
        buffer.writeCharCode(byte >= 32 && byte < 127 ? byte : 0x2E);
      }
      buffer.writeln('|');
    }
    return buffer.toString();
  }

  static String _mimeFor(VfsPath path) {
    final name = path.name.toLowerCase();
    final dot = name.lastIndexOf('.');
    return switch (dot < 0 ? '' : name.substring(dot + 1)) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      _ => 'image/png',
    };
  }
}
