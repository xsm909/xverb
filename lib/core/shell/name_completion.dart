/// Growing a half-typed name in the command line into a whole one — what Tab
/// does there.
///
/// The rules are here rather than in the screen because they are entirely about
/// text and have nothing to do with a keyboard: given a line, a caret and the
/// names that exist, there is one right answer, and it can be checked without
/// building a window.
library;

import '../vfs/vfs_path.dart';

/// A word split at its last separator: the part that says where to look, and
/// the part that has to be matched there.
typedef TypedPath = ({String directory, String prefix});

/// A line and where the caret ended up in it.
class CompletedLine {
  const CompletedLine(this.text, this.caret);

  final String text;
  final int caret;
}

abstract final class NameCompletion {
  /// Where the word under [caret] begins.
  ///
  /// A space is the only separator. A quoted name holding one is found by the
  /// quote rather than by scanning, because a line being typed is as often
  /// half-quoted as not and guessing at the missing half is worse than taking
  /// the word plainly.
  static int wordStart(String text, int caret) {
    final quote = text.lastIndexOf('"', caret == 0 ? 0 : caret - 1);
    if (quote >= 0 && _isOpeningQuote(text, quote)) return quote;

    var start = caret;
    while (start > 0 && text[start - 1] != ' ') {
      start--;
    }
    return start;
  }

  /// The word under [caret], without the quote that may open it.
  static String wordAt(String text, int caret) {
    final word = text.substring(wordStart(text, caret), caret);
    return word.startsWith('"') ? word.substring(1) : word;
  }

  /// A word split at its last separator.
  ///
  /// `te` is a name in the folder on screen; `./te` and `/pro` and `sub/te` are
  /// names somewhere else, and the somewhere else has to be read before there
  /// is anything to offer. Both separators count: a path typed into a command
  /// line is as often written with a forward slash on Windows as not.
  static TypedPath splitPath(String word) {
    final at = word.lastIndexOf(RegExp(r'[/\\]'));
    if (at < 0) return (directory: '', prefix: word);
    return (
      directory: word.substring(0, at + 1),
      prefix: word.substring(at + 1),
    );
  }

  /// Where [typed] points, starting from [base] — the folder the panel is
  /// showing.
  ///
  /// A leading separator means the root of whatever [base] is on, which on
  /// Windows is the drive rather than the machine: someone in `E:\work` who
  /// types `/pro` means `E:\program…`, because that is the only root they can
  /// see. `.` and `..` walk the way they read, and a drive letter starts again
  /// from that drive.
  ///
  /// Returns null when the path walks up past a root, which is not a place.
  static VfsPath? directoryOf(VfsPath base, String typed) {
    final parts = typed.replaceAll(r'\', '/').split('/');
    var current = base;

    if (parts.isNotEmpty && _isDriveLetter(parts.first)) {
      current = VfsPath.local('${parts.first}\\');
      parts.removeAt(0);
    } else if (parts.isNotEmpty && parts.first.isEmpty) {
      current = base.root;
      parts.removeAt(0);
    }

    for (final part in parts) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        final up = current.parent;
        if (up == null) return null;
        current = up;
        continue;
      }
      current = current.child(part);
    }
    return current;
  }

  static bool _isDriveLetter(String part) =>
      part.length == 2 && part.endsWith(':');

  /// The names [prefix] could grow into, in the order Tab offers them.
  ///
  /// Case is ignored on the way in and kept on the way out: someone typing
  /// `doc` should reach `Documents`, and reach it spelled the way the disk
  /// spells it.
  static List<String> matching(String prefix, Iterable<String> names) {
    final lower = prefix.toLowerCase();
    return names.where((name) => name.toLowerCase().startsWith(lower)).toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// [text] with everything from [start] to [caret] replaced by [name].
  ///
  /// A name with a space in it is one argument only if it is quoted, and it is
  /// the shell that has to be convinced of that, not the eye. Any trailing
  /// separator is left outside the quotes: `"my files"\` is a path every shell
  /// reads, and `"my files\"` is one that cmd reads as an escaped quote.
  static CompletedLine replace(String text, int start, int caret, String name) {
    var body = name;
    var tail = '';
    if (body.endsWith('/') || body.endsWith(r'\')) {
      tail = body.substring(body.length - 1);
      body = body.substring(0, body.length - 1);
    }
    final written = body.contains(' ') ? '"$body"$tail' : '$body$tail';
    return CompletedLine(
      text.replaceRange(start, caret, written),
      start + written.length,
    );
  }

  /// Whether the quote at [at] opens a word rather than closing one — it does
  /// when what precedes it is a space or nothing at all.
  static bool _isOpeningQuote(String text, int at) =>
      at == 0 || text[at - 1] == ' ';
}
