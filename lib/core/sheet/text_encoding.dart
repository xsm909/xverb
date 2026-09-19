import 'dart:convert';

/// How the bytes of a separated-values file are to be read.
///
/// Decided once, from the head of the file, because a paged source reads the
/// file in pieces and every piece has to be read the same way. Separators,
/// quotes and line ends are ASCII in every one of these, which is what lets a
/// piece be cut out at a line end and decoded on its own.
enum SheetEncoding {
  utf8,
  utf16le,
  utf16be,

  /// Windows-1251: what a Russian Excel writes when told "CSV". Not UTF-8,
  /// no mark, semicolons and a decimal comma — the most common CSV there is
  /// on the machines this application is used on, and the one a UTF-8 reader
  /// turns into a column of question marks.
  windows1251,
  latin1;

  /// Two bytes a character.
  bool get wide => this == utf16le || this == utf16be;
}

/// What [head] — the first few tens of kilobytes — says the file is written
/// in, and how many bytes of mark come before the text.
({SheetEncoding encoding, int skip}) detectSheetEncoding(List<int> head) {
  if (head.length >= 3 &&
      head[0] == 0xEF &&
      head[1] == 0xBB &&
      head[2] == 0xBF) {
    return (encoding: SheetEncoding.utf8, skip: 3);
  }
  if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xFE) {
    return (encoding: SheetEncoding.utf16le, skip: 2);
  }
  if (head.length >= 2 && head[0] == 0xFE && head[1] == 0xFF) {
    return (encoding: SheetEncoding.utf16be, skip: 2);
  }

  // Two-byte text with no mark. Every alphabet from Latin to Arabic lives
  // below U+0800, so one side of each pair is a byte under 8 — a NUL for
  // Latin, 04 for Cyrillic — and which side says which end comes first.
  // Counting NULs alone found Latin and missed Cyrillic, which is the text
  // most likely to be here. One-byte text almost never has control bytes.
  final pairs = (head.length < 4096 ? head.length : 4096) >> 1;
  if (pairs >= 2) {
    var lowOdd = 0;
    var lowEven = 0;
    for (var i = 0; i < pairs * 2; i += 2) {
      if (head[i] < 8) lowEven++;
      if (head[i + 1] < 8) lowOdd++;
    }
    if (lowOdd * 10 >= pairs * 9 && lowEven * 10 < pairs * 9) {
      return (encoding: SheetEncoding.utf16le, skip: 0);
    }
    if (lowEven * 10 >= pairs * 9 && lowOdd * 10 < pairs * 9) {
      return (encoding: SheetEncoding.utf16be, skip: 0);
    }
  }

  if (_isUtf8(head)) return (encoding: SheetEncoding.utf8, skip: 0);

  // Not UTF-8, so one byte a letter, and the question is which alphabet. In
  // Cyrillic nearly every letter is a high byte; in Western text with a few
  // accents nearly none are. A third is far from both.
  var high = 0;
  var letters = 0;
  for (final byte in head) {
    if (byte >= 0xC0 || byte == 0xA8 || byte == 0xB8) {
      high++;
      letters++;
    } else if ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A) {
      letters++;
    }
  }
  return (
    encoding: high * 3 > letters
        ? SheetEncoding.windows1251
        : SheetEncoding.latin1,
    skip: 0,
  );
}

/// Whether [bytes] are well-formed UTF-8, allowing a sequence cut off at the
/// end — the head of a file is cut wherever the read stopped.
bool _isUtf8(List<int> bytes) {
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    final int follow;
    if (b < 0x80) {
      i++;
      continue;
    } else if (b >= 0xC2 && b <= 0xDF) {
      follow = 1;
    } else if (b >= 0xE0 && b <= 0xEF) {
      follow = 2;
    } else if (b >= 0xF0 && b <= 0xF4) {
      follow = 3;
    } else {
      return false;
    }
    for (var k = 1; k <= follow; k++) {
      if (i + k >= bytes.length) return true;
      if (bytes[i + k] & 0xC0 != 0x80) return false;
    }
    i += follow + 1;
  }
  return true;
}

/// [bytes] as text in [encoding]. Malformed bytes are replaced, never fatal.
String decodeSheetText(List<int> bytes, SheetEncoding encoding) {
  switch (encoding) {
    case SheetEncoding.utf8:
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    case SheetEncoding.latin1:
      return latin1.decode(bytes, allowInvalid: true);
    case SheetEncoding.windows1251:
      final units = List<int>.filled(bytes.length, 0);
      for (var i = 0; i < bytes.length; i++) {
        final b = bytes[i];
        units[i] = b < 0x80
            ? b
            : b >= 0xC0
            ? 0x0410 + (b - 0xC0)
            : _cp1251High[b - 0x80];
      }
      return String.fromCharCodes(units);
    case SheetEncoding.utf16le:
    case SheetEncoding.utf16be:
      final le = encoding == SheetEncoding.utf16le;
      final units = List<int>.filled(bytes.length >> 1, 0);
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        units[i >> 1] = le
            ? bytes[i] | bytes[i + 1] << 8
            : bytes[i] << 8 | bytes[i + 1];
      }
      return String.fromCharCodes(units);
  }
}

/// Windows-1251 from 0x80 to 0xBF; from 0xC0 up it is the Cyrillic capital A
/// (U+0410) to small ya (U+044F), in order.
/// 0x98 is not assigned and reads as the replacement character.
const _cp1251High = <int>[
  0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
  0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
  0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
  0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
  0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
  0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
];
