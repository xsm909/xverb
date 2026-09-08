import 'package:flutter/material.dart';

import '../../core/plugins/grammar.dart';
import '../../core/colour_contrast.dart';
import '../../core/settings/appearance_settings.dart';
import 'reading_colours.dart';

/// Colouring a file by the grammar its language shipped.
///
/// One scanner for every language, driven by [SyntaxGrammar] — see there for
/// why the dictionary is data and this is not. The shape is the JSON
/// highlighter's, because it earned it: a pure function from a string to runs,
/// with every awkward case a test that has no widget in it.
///
/// **Left to right in one pass, not a regular expression per line.** Two things
/// make that the only honest way. A `//` inside `"http://x"` is not a comment,
/// and only something that has already seen the quote knows that; and a block
/// comment or a triple-quoted string runs *through* newlines, so a line
/// examined on its own cannot say what it is inside. Regular expressions still
/// do the small work — a number, a section heading — where they are exact.

/// One run of the file: what it is, and the characters it covers.
///
/// The runs cover the source exactly once, in order, so joining them returns
/// the file. That is a test, and it is the one that matters: a highlighter that
/// quietly drops a character is worse than no highlighter.
typedef CodeRun = (CodeRole role, String text);

/// Splits [source] into runs according to [grammar].
///
/// Never rejects anything. A file that is half-written, truncated by the
/// viewer's own byte limit, or simply not the language it is named after still
/// comes back whole — plain where nothing better fits.
List<CodeRun> splitCode(String source, SyntaxGrammar grammar) {
  final runs = <CodeRun>[];
  final plain = StringBuffer();

  void flush() {
    if (plain.isEmpty) return;
    runs.add((CodeRole.plain, plain.toString()));
    plain.clear();
  }

  void add(CodeRole role, String text) {
    if (text.isEmpty) return;
    if (role == CodeRole.plain) {
      plain.write(text);
      return;
    }
    flush();
    // Neighbours of a kind are joined: spans cost a shaping pass each, and a
    // file is mostly punctuation and whitespace.
    if (runs.isNotEmpty && runs.last.$1 == role) {
      runs[runs.length - 1] = (role, runs.last.$2 + text);
    } else {
      runs.add((role, text));
    }
  }

  // Longest first, so `"""` is tried before `"` and `<!--` before `<`. Done
  // once here rather than at every character.
  final lineComments = [...grammar.lineComments]
    ..sort((a, b) => b.length.compareTo(a.length));
  final blockComments = [...grammar.blockComments]
    ..sort((a, b) => b.$1.length.compareTo(a.$1.length));
  final strings = [...grammar.strings]
    ..sort((a, b) => b.open.length.compareTo(a.open.length));

  final length = source.length;
  var i = 0;
  var freshLine = true;

  while (i < length) {
    final code = source.codeUnitAt(i);

    if (code == 0x0a) {
      add(CodeRole.plain, '\n');
      i++;
      freshLine = true;
      continue;
    }

    // What a line *is*, before what is in it: `#include`, `[Section]`, a key
    // before its `=`. Tried once per line, on the first thing that is not a
    // space.
    if (freshLine && _isSpace(code) == false) {
      freshLine = false;
      final rule = _lineRuleAt(source, i, grammar.linePatterns);
      if (rule != null) {
        add(rule.$1, source.substring(i, rule.$2));
        i = rule.$2;
        continue;
      }
    }

    final comment = _startsWithOne(source, i, lineComments);
    if (comment != null) {
      final end = _endOfLine(source, i);
      add(CodeRole.comment, source.substring(i, end));
      i = end;
      continue;
    }

    final block = _blockAt(source, i, blockComments);
    if (block != null) {
      final end = _find(source, block.$2, i + block.$1.length);
      add(CodeRole.comment, source.substring(i, end));
      i = end;
      continue;
    }

    final quote = _stringAt(source, i, strings);
    if (quote != null) {
      final end = _endOfString(source, i, quote);
      add(CodeRole.string, source.substring(i, end));
      i = end;
      continue;
    }

    if (grammar.numbers &&
        (_isDigit(code) ||
            (code == 0x2e &&
                i + 1 < length &&
                _isDigit(source.codeUnitAt(i + 1))))) {
      final end = _endOfNumber(source, i);
      add(CodeRole.number, source.substring(i, end));
      i = end;
      continue;
    }

    if (_isWordStart(code)) {
      var end = i + 1;
      while (end < length && _isWordPart(source.codeUnitAt(end))) {
        end++;
      }
      final word = source.substring(i, end);
      add(grammar.roleOfWord(word), word);
      i = end;
      continue;
    }

    if (_isSpace(code)) {
      add(CodeRole.plain, source[i]);
      i++;
      continue;
    }

    add(CodeRole.punctuation, source[i]);
    i++;
  }

  flush();
  return runs;
}

bool _isSpace(int code) => code == 0x20 || code == 0x09 || code == 0x0d;
bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

bool _isWordStart(int code) =>
    (code | 0x20) >= 0x61 && (code | 0x20) <= 0x7a ||
    code == 0x5f ||
    code == 0x24 ||
    // Anything above ASCII is a letter as far as this is concerned. A word in
    // an identifier is not this scanner's business to police, and a Cyrillic
    // name in a Python file is a name.
    code > 0x7f;

bool _isWordPart(int code) => _isWordStart(code) || _isDigit(code);

/// The first rule of [rules] that matches the rest of the line at [from].
(CodeRole, int)? _lineRuleAt(String source, int from, List<LineRule> rules) {
  if (rules.isEmpty) return null;
  final end = _endOfLine(source, from);
  final line = source.substring(from, end);
  for (final rule in rules) {
    final match = rule.match.matchAsPrefix(line);
    if (match != null && match.end > 0) {
      return (rule.role, from + match.end);
    }
  }
  return null;
}

String? _startsWithOne(String source, int at, List<String> tokens) {
  for (final token in tokens) {
    if (token.isNotEmpty && source.startsWith(token, at)) return token;
  }
  return null;
}

(String, String)? _blockAt(
  String source,
  int at,
  List<(String, String)> blocks,
) {
  for (final block in blocks) {
    if (block.$1.isNotEmpty && source.startsWith(block.$1, at)) return block;
  }
  return null;
}

StringRule? _stringAt(String source, int at, List<StringRule> rules) {
  for (final rule in rules) {
    if (rule.open.isNotEmpty && source.startsWith(rule.open, at)) return rule;
  }
  return null;
}

int _endOfLine(String source, int from) {
  final end = source.indexOf('\n', from);
  return end < 0 ? source.length : end;
}

/// Past [token] from [start], or the end of the file when it never comes.
///
/// An unterminated comment or string is a file being written, or one the viewer
/// cut short at its byte limit. It colours to the end rather than falling apart.
int _find(String source, String token, int start) {
  final end = source.indexOf(token, start);
  return end < 0 ? source.length : end + token.length;
}

int _endOfString(String source, int from, StringRule rule) {
  var i = from + rule.open.length;
  while (i < source.length) {
    if (rule.escape.isNotEmpty && source.startsWith(rule.escape, i)) {
      i += rule.escape.length + 1;
      continue;
    }
    if (!rule.multiline && source.codeUnitAt(i) == 0x0a) return i;
    if (source.startsWith(rule.close, i)) return i + rule.close.length;
    i++;
  }
  return source.length;
}

/// One number, in whatever form the language writes them.
///
/// Deliberately loose: `0xFF`, `1_000`, `3.14e-9`, `10f` are all one run. The
/// grammar does not describe numbers, because every language's rules for them
/// are fiddly, nearly the same, and never what anybody is looking at.
int _endOfNumber(String source, int from) {
  var i = from;
  while (i < source.length) {
    final code = source.codeUnitAt(i);
    if (_isDigit(code) ||
        code == 0x2e ||
        code == 0x5f ||
        (code | 0x20) >= 0x61 && (code | 0x20) <= 0x7a) {
      // The sign of an exponent belongs to the number; the one in `a-1` does
      // not, and the difference is the letter in front of it.
      if ((code | 0x20) == 0x65 || (code | 0x20) == 0x70) {
        final next = i + 1 < source.length ? source.codeUnitAt(i + 1) : 0;
        if (next == 0x2b || next == 0x2d) {
          i += 2;
          continue;
        }
      }
      i++;
      continue;
    }
    break;
  }
  return i;
}

/// The colours a file of code is drawn in.
///
/// **Taken from the palette, not added to it** — the rule JSON's colouring
/// already follows. A grammar names a role and the theme says what a role looks
/// like: the name colour for the words that hold a language together, the
/// marked colour for text, the accent for the atoms, and the panel's own
/// foreground, quietened, for what is not being read.
class CodeColours {
  const CodeColours({
    required this.keyword,
    required this.type,
    required this.string,
    required this.atom,
    required this.comment,
    required this.punctuation,
    required this.plain,
  });

  /// The hues come from the palette and the greys from the page.
  ///
  /// **That split is the decision**, taken on 2026-08-18 when the reading got
  /// a pair of colours of its own: plain text, punctuation and comments are the
  /// page's ink at three distances, so they follow the page — but the three
  /// words a reader picks a file out by keep hues of their own, because three
  /// hues answering to two knobs is a loss of control rather than a
  /// simplification.
  ///
  /// ## Where the three hues come from, since 1.0.0.410
  ///
  /// They were the directory colour, the marked colour and the accent, which
  /// worked while those were three independent choices. Under three seeds they
  /// are not: the directory and marked colours are *worked out from the
  /// accent*, and a page of code drawn in one hue at three lightnesses is a
  /// page where the keyword and the atom are the same word. Measured on the
  /// shipped palettes, Mint put its keywords 18 points a channel from its
  /// atoms — the same colour, for practical purposes.
  ///
  /// So a colour that was **pressed** is used, and a colour that was
  /// **derived** is replaced by a hue of its own: the accent turned a long way
  /// round the circle, far enough that no arithmetic on lightness can bring the
  /// two back together. It is the same division the appearance settings make:
  /// three seeds generate a spread, and pressing a colour takes it back.
  ///
  /// [theme] is whatever [appearanceOf] handed back, so the page's pair is
  /// already in it inside a reading and the panel's is outside one — see
  /// [ReadingColours.surface].
  factory CodeColours.of(AppearanceSettings theme) {
    final page = ReadingColours.surface(theme);

    /// [wanted] if somebody chose it, and otherwise the accent turned
    /// [degrees] round the circle at [wanted]'s own lightness.
    ///
    /// The lightness is kept because that is the part the derivation gets
    /// right: it is set against the paper, and a hue swapped in at the same
    /// lightness reads exactly as well. Only the hue moves.
    Color role(String key, Color wanted, double degrees) {
      final chosen = theme.isPressed(key);
      final colour = chosen
          ? wanted
          : HSLColor.fromColor(wanted)
              .withHue(
                (HSLColor.fromColor(theme.accentColor).hue + degrees) % 360,
              )
              .toColor();

      // **And then held to the page it is read on**, which is the rule every
      // colour here obeys and the one thing a swapped hue cannot be trusted
      // about: a yellow and a blue at the same lightness are nowhere near the
      // same
      // brightness, so the swap that keeps a colour legible on one palette
      // loses it on the next. Parchment's strings came out at 2.8:1 before
      // this line. [legibleInk] keeps the hue — the hue is the message — and
      // moves only what has to move.
      return legibleInk(colour, on: page.paper, fallback: page.ink);
    }

    final keyword = role('directoryColor', theme.directoryColor, -140);

    return CodeColours(
      keyword: keyword,
      // The same colour a step back. A type is a word of the language too,
      // and a second full colour for it would be a fourth hue on a page that
      // already has three.
      type: keyword.withValues(alpha: 0.78),
      string: role('markedColor', theme.markedColor, 140),
      // The accent itself, always — it is a seed, so there is nothing to
      // derive it from and nothing to spread it away from. Held to the page in
      // the same way, which it never was before: an accent chosen against the
      // listing had no reason to be legible on a reading somebody had painted
      // a different colour.
      atom: legibleInk(
        theme.accentColor,
        on: page.paper,
        fallback: page.ink,
      ),
      comment: page.faint,
      punctuation: page.muted,
      plain: page.ink,
    );
  }

  final Color keyword;
  final Color type;
  final Color string;
  final Color atom;
  final Color comment;
  final Color punctuation;
  final Color plain;

  Color colourOf(CodeRole role) => switch (role) {
        CodeRole.keyword => keyword,
        CodeRole.type || CodeRole.meta => type,
        CodeRole.string => string,
        CodeRole.number || CodeRole.constant => atom,
        CodeRole.comment => comment,
        CodeRole.punctuation => punctuation,
        CodeRole.plain => plain,
      };
}

/// Whether a role is one of the *words* — the ones a reader picks a page out
/// by, and the ones [codeSpans] will set in another weight if asked.
///
/// Keywords, types, strings and constants. Comments are left out on purpose:
/// they are drawn quiet because they are the part not being read, and a
/// heavier comment argues with that. Punctuation and plain text are
/// the page itself.
bool _isWord(CodeRole role) => switch (role) {
  CodeRole.keyword ||
  CodeRole.type ||
  CodeRole.meta ||
  CodeRole.string ||
  CodeRole.number ||
  CodeRole.constant => true,
  CodeRole.comment || CodeRole.punctuation || CodeRole.plain => false,
};

/// [source] as one span per run, drawn over [base].
///
/// [wordWeight] is the weight the coloured words are set in — **one weight for
/// all of them**: a weight per role would be four knobs nobody turns and a way
/// to make a page look assembled.
/// Null leaves every run at [base]'s own weight, which is what a page that has
/// not asked gets.
TextSpan codeSpans(
  String source,
  SyntaxGrammar grammar,
  TextStyle base,
  CodeColours colours, {
  FontWeight? wordWeight,
}) =>
    TextSpan(
      children: [
        for (final (role, text) in splitCode(source, grammar))
          TextSpan(
            text: text,
            style: base.copyWith(
              color: colours.colourOf(role),
              fontWeight: wordWeight != null && _isWord(role)
                  ? wordWeight
                  : base.fontWeight,
            ),
          ),
      ],
    );
