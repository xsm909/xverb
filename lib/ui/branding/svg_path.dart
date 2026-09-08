import 'package:flutter/painting.dart';

/// Turns an SVG `d` attribute into a [Path].
///
/// **Enough of SVG to draw the mark, and no more.** The application's icon
/// arrived as one path — see [AppMarkPainter.outline] — and keeping it as the
/// string it came as means replacing the mark is replacing one constant. The
/// alternative was translating it into canvas calls by hand, and a translation
/// is a copy that can be wrong.
///
/// **What it understands**, which is exactly what that drawing uses: `M`/`m`
/// move, `L`/`l` line, `H`/`h` and `V`/`v` the two straight ones, `C`/`c`
/// cubic, and `Z`/`z` close. Capitals are absolute and lower case relative, as
/// they always are.
///
/// **What it does not**, deliberately: arcs, quadratics and the smooth
/// shorthands. A parser that half-understands an arc draws something plausible
/// and wrong, and a mark drawn wrong is worse than a mark that would not load —
/// so an unknown command throws rather than being skipped, and it throws while
/// somebody is looking at the drawing rather than three releases later.
Path parseSvgPath(String d) {
  final path = Path();
  final tokens = _Reader(d);

  var x = 0.0;
  var y = 0.0;
  // Where the current subpath began, which is where `Z` returns to.
  var startX = 0.0;
  var startY = 0.0;
  String? command;

  while (true) {
    final next = tokens.command();
    if (next != null) command = next;
    final current = command;
    if (current == null) break;
    if (tokens.done && current != 'Z' && current != 'z') break;

    final relative = current == current.toLowerCase();
    switch (current.toUpperCase()) {
      case 'M':
        x = tokens.number() + (relative ? x : 0);
        y = tokens.number() + (relative ? y : 0);
        path.moveTo(x, y);
        startX = x;
        startY = y;
        // **A second pair after a move is a line, not another move.** That is
        // the SVG rule and it is the one everybody's hand-written parser gets
        // wrong; the drawing does not rely on it, and it costs two words to be
        // right about anyway.
        command = relative ? 'l' : 'L';

      case 'L':
        x = tokens.number() + (relative ? x : 0);
        y = tokens.number() + (relative ? y : 0);
        path.lineTo(x, y);

      case 'H':
        x = tokens.number() + (relative ? x : 0);
        path.lineTo(x, y);

      case 'V':
        y = tokens.number() + (relative ? y : 0);
        path.lineTo(x, y);

      case 'C':
        final originX = relative ? x : 0.0;
        final originY = relative ? y : 0.0;
        final x1 = tokens.number() + originX;
        final y1 = tokens.number() + originY;
        final x2 = tokens.number() + originX;
        final y2 = tokens.number() + originY;
        x = tokens.number() + originX;
        y = tokens.number() + originY;
        path.cubicTo(x1, y1, x2, y2, x, y);

      case 'Z':
        path.close();
        x = startX;
        y = startY;

      default:
        throw FormatException('The path command "$command" is not understood.');
    }

    if (tokens.done) break;
  }

  return path;
}

/// Walks the `d` string, handing out commands and numbers.
///
/// SVG lets numbers run together in every way that is unambiguous — `10-5` is
/// two of them, `.5.5` is two of them — so this reads a number by its own rules
/// rather than by splitting on anything.
class _Reader {
  _Reader(this.text);

  final String text;
  int at = 0;

  bool get done {
    _skip();
    return at >= text.length;
  }

  void _skip() {
    while (at < text.length) {
      final c = text.codeUnitAt(at);
      // Space, tab, newline, carriage return, comma.
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x2C) {
        at++;
      } else {
        return;
      }
    }
  }

  /// The next command letter, or null where a run of numbers continues the one
  /// before — `c` followed by twelve numbers is four curves.
  String? command() {
    _skip();
    if (at >= text.length) return null;
    final c = text[at];
    if (RegExp('[A-Za-z]').hasMatch(c)) {
      at++;
      return c;
    }
    return null;
  }

  double number() {
    _skip();
    final start = at;
    if (at < text.length && (text[at] == '-' || text[at] == '+')) at++;
    while (at < text.length) {
      final c = text[at];
      if ((c.codeUnitAt(0) ^ 0x30) <= 9 || c == '.') {
        at++;
      } else if (c == 'e' || c == 'E') {
        at++;
        if (at < text.length && (text[at] == '-' || text[at] == '+')) at++;
      } else {
        break;
      }
    }
    final text_ = text.substring(start, at);
    final value = double.tryParse(text_);
    if (value == null) {
      throw FormatException('"$text_" is not a number, at $start.');
    }
    return value;
  }
}
