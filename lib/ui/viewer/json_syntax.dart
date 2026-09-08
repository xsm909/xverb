import 'package:flutter/material.dart';

import '../../core/settings/appearance_settings.dart';
import 'code_syntax.dart';
import 'reading_colours.dart';

/// Colouring a JSON document the viewer has already laid out.
///
/// Formatting it was never the hard half. A file that arrives pretty-printed
/// looks the same after the viewer has re-indented it, so the transform read as
/// having done nothing: formatted and unformatted came out barely different.
/// What tells the two apart is colour, and colour is what this file adds.
///
/// Split from the viewer page because it is the one part of this worth
/// measuring on its own: a tokeniser is a pure function of a string, and every
/// awkward case — an escaped quote, a key that is not followed by a colon, a
/// file that stops mid-string — is a test with no widget in it.

/// What a run of characters in a JSON document is.
///
/// [key] and [string] are the same token to a parser and different things to a
/// reader, which is the whole reason a listing of a file is worth colouring:
/// the names are the shape of the document and the values are the contents.
enum JsonPart { key, string, number, literal, punctuation, plain }

/// One run of the document: what it is, and the characters it covers.
///
/// The runs cover the source exactly once, in order, so joining them back
/// together returns the file — which is what the widget test checks, because a
/// highlighter that quietly drops a character is worse than no highlighter.
typedef JsonRun = (JsonPart part, String text);

/// Splits [source] into runs.
///
/// Not a parser and deliberately not: it never rejects anything. Whatever the
/// file turns out to be — half-written, truncated by the viewer's own byte
/// limit, or not JSON at all — every character comes back in a run, plain if
/// nothing better fits.
List<JsonRun> splitJson(String source) {
  final runs = <JsonRun>[];
  final plain = StringBuffer();

  void flush() {
    if (plain.isEmpty) return;
    runs.add((JsonPart.plain, plain.toString()));
    plain.clear();
  }

  void add(JsonPart part, String text) {
    flush();
    // Neighbours of the same kind are joined, so `}, {` is one span rather
    // than four — spans cost a shaping pass each and a large file is mostly
    // punctuation and whitespace.
    if (runs.isNotEmpty && runs.last.$1 == part) {
      runs[runs.length - 1] = (part, runs.last.$2 + text);
    } else {
      runs.add((part, text));
    }
  }

  var i = 0;
  while (i < source.length) {
    final c = source[i];

    if (c == '"') {
      final end = _endOfString(source, i);
      // A string followed by a colon is a name, whatever depth it is at. This
      // is the one place the colouring reads ahead, and it reads past spaces
      // only — a newline between a name and its colon is not JSON anybody
      // writes, and treating it as a value there costs one wrong colour.
      add(_colonFollows(source, end) ? JsonPart.key : JsonPart.string,
          source.substring(i, end));
      i = end;
      continue;
    }

    if (_startsNumber(source, i)) {
      final end = _endOfNumber(source, i);
      add(JsonPart.number, source.substring(i, end));
      i = end;
      continue;
    }

    if (_isLetter(c)) {
      final end = _endOfWord(source, i);
      final word = source.substring(i, end);
      add(
        word == 'true' || word == 'false' || word == 'null'
            ? JsonPart.literal
            : JsonPart.plain,
        word,
      );
      i = end;
      continue;
    }

    if (_punctuation.contains(c)) {
      add(JsonPart.punctuation, c);
      i++;
      continue;
    }

    plain.write(c);
    i++;
  }

  flush();
  return runs;
}

const String _punctuation = '{}[],:';

/// One past the closing quote of the string opening at [start].
///
/// An unterminated string runs to the end of the source rather than throwing:
/// the viewer truncates long files at a byte count, which cuts strings in half
/// as a matter of course.
int _endOfString(String source, int start) {
  var i = start + 1;
  while (i < source.length) {
    final c = source[i];
    if (c == r'\') {
      // The escape takes the next character with it, so `\"` does not close
      // the string and `\\` does not swallow the quote after it.
      i += 2;
      continue;
    }
    if (c == '"') return i + 1;
    i++;
  }
  return source.length;
}

bool _colonFollows(String source, int from) {
  for (var i = from; i < source.length; i++) {
    final c = source[i];
    if (c == ' ' || c == '\t') continue;
    return c == ':';
  }
  return false;
}

bool _startsNumber(String source, int i) {
  final c = source[i];
  if (_isDigit(c)) return true;
  // A lone minus is not a number, and a minus inside a word is not either —
  // both would take the colour off whatever follows them.
  return c == '-' && i + 1 < source.length && _isDigit(source[i + 1]);
}

int _endOfNumber(String source, int start) {
  var i = start + 1;
  while (i < source.length) {
    final c = source[i];
    if (_isDigit(c) || c == '.' || c == 'e' || c == 'E') {
      i++;
      continue;
    }
    // A sign only belongs to a number directly after its exponent.
    final previous = source[i - 1];
    if ((c == '+' || c == '-') && (previous == 'e' || previous == 'E')) {
      i++;
      continue;
    }
    break;
  }
  return i;
}

int _endOfWord(String source, int start) {
  var i = start;
  while (i < source.length && _isLetter(source[i])) {
    i++;
  }
  return i;
}

bool _isDigit(String c) {
  final code = c.codeUnitAt(0);
  return code >= 0x30 && code <= 0x39;
}

bool _isLetter(String c) {
  final code = c.codeUnitAt(0) | 0x20;
  return code >= 0x61 && code <= 0x7a;
}

/// The colours a JSON document is drawn in.
///
/// **Taken from the palette, not added to it.** A new colour in this
/// application is a thing you press in the appearance preview, and there is
/// nothing in a preview to press for "the colour of a number in a file" — so
/// these are the panel's own colours, used for what they already mean: the
/// name colour for names, the marked colour for the text of the file, the
/// accent for the atoms, and the panel's foreground, quietened, for the
/// brackets that hold it together.
class JsonColours {
  const JsonColours({
    required this.key,
    required this.string,
    required this.atom,
    required this.punctuation,
    required this.plain,
  });

  /// Hues from the palette, greys from the page — see [CodeColours.of] for
  /// why the two come from different places, and for why a derived hue is
  /// spread and a pressed one is not.
  ///
  /// **Taken from [CodeColours] rather than worked out again**, so a key, a
  /// string and a number are the same three colours in a `.json` as they are in
  /// a `.dart`. They were the same three by coincidence — both lists read the
  /// same three settings — and the moment one of them learned to spread a
  /// derived hue, the coincidence would have ended without anyone noticing.
  factory JsonColours.of(AppearanceSettings theme) {
    final page = ReadingColours.surface(theme);
    final code = CodeColours.of(theme);
    return JsonColours(
      key: code.keyword,
      string: code.string,
      atom: code.atom,
      punctuation: page.muted,
      plain: page.ink,
    );
  }

  final Color key;
  final Color string;
  final Color atom;
  final Color punctuation;
  final Color plain;

  Color colourOf(JsonPart part) => switch (part) {
        JsonPart.key => key,
        JsonPart.string => string,
        JsonPart.number || JsonPart.literal => atom,
        JsonPart.punctuation => punctuation,
        JsonPart.plain => plain,
      };
}

/// [source] as one span per run, drawn over [base].
TextSpan jsonSpans(String source, TextStyle base, JsonColours colours) {
  return TextSpan(
    children: [
      for (final (part, text) in splitJson(source))
        TextSpan(text: text, style: base.copyWith(color: colours.colourOf(part))),
    ],
  );
}
