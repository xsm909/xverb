import '../../core/plugins/grammar.dart';
import 'code_syntax.dart';

/// Which lines of a file hold up the ones below them.
///
/// Item 70b: sections hold — for ini and yaml, and for code.
/// Two mechanisms, not either, because the two kinds of file say "this is the
/// part you are in" in two different ways:
///
/// - **By the grammar's roles**, for the flat formats. A `[Section]` is already
///   marked `meta` when the file is coloured, so which role sticks is one more
///   thing a grammar declares — see [SyntaxGrammar.sticky]. Nothing is guessed
///   and nothing is built in.
/// - **By indentation**, for code. A line is a heading of what follows while
///   the lines under it are indented deeper, which is the honest way to get
///   VS Code's stack of enclosing scopes without a parser — and it covers
///   Python, C++ and YAML on its own.
class StickyPlan {
  const StickyPlan({
    this.roles = const {},
    this.byIndent = false,
    this.byDiff = false,
  });

  /// Nothing sticks. What a file with no grammar behind it gets.
  static const StickyPlan none = StickyPlan();

  /// What a grammar asks for: its own sticky roles, and indentation besides.
  ///
  /// Both together on purpose. A YAML file has no `meta` line to declare and is
  /// held up entirely by its shape; an INI file has sections and no indentation
  /// at all; a Python file has both a decorator and a body. Whichever mechanism
  /// has something to say, says it.
  factory StickyPlan.of(SyntaxGrammar grammar) =>
      StickyPlan(roles: grammar.sticky, byIndent: true);

  final Set<CodeRole> roles;
  final bool byIndent;

  /// A unified diff, which is neither of the other two: it has no grammar and
  /// no indentation, and what holds a line up is **which file and which hunk
  /// it is in**. Reading a diff is the one place a reader is most often lost —
  /// four hundred lines in, the name of the file went past long ago.
  final bool byDiff;

  /// What a diff is held up by. Its own factory because a diff has no grammar
  /// to ask: the shape is in the format itself.
  static const StickyPlan diff = StickyPlan(byDiff: true);

  bool get isEmpty => roles.isEmpty && !byIndent && !byDiff;

  /// How many lines may stand at the top before they *are* the page.
  ///
  /// VS Code caps it and so does the markdown reader, for the same reason:
  /// five levels of heading over a document is a document read through a
  /// letterbox. Worth measuring again if anyone raises it.
  static const int deepest = 3;
}

/// One line standing over the reading.
class StickyLine {
  const StickyLine(this.index, this.text, this.indent);

  /// Which line of the file it is, counted from zero.
  final int index;

  final String text;

  /// How far in it starts, in characters. What the strip indents by, so a
  /// chain reads as a chain rather than as lines that happen to be stacked.
  final int indent;
}

/// How far into [line] the first character that is not a space sits.
///
/// A tab counts as one, which is a lie about the width and the truth about the
/// depth: what matters here is only whether one line is further in than
/// another, and mixing the two in one file is already a file that will not line
/// up in anybody's editor.
int indentOf(String line) {
  var i = 0;
  while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
    i++;
  }
  return i;
}

/// Whether a line has anything on it at all.
bool _blank(String line) => line.trim().isEmpty;

/// The chain of lines standing over [top], outermost first.
///
/// [roleOfLine] answers what the grammar made of a line's first word, or null
/// where that is not being asked. Given rather than worked out here so the
/// scanner runs once over the file rather than once per scroll.
List<StickyLine> stickyChain(
  List<String> lines,
  int top,
  StickyPlan plan, {
  CodeRole? Function(int index)? roleOfLine,
}) {
  if (plan.isEmpty || top <= 0 || top >= lines.length) return const [];

  final chain = <StickyLine>[];

  // A diff: the file, and the hunk inside it. Both are lines of the file
  // itself, so what stands over the reading is what was written there.
  if (plan.byDiff) {
    for (var i = top - 1; i >= 0 && chain.length < 2; i--) {
      final line = lines[i];
      final hunk = line.startsWith('@@');
      final file = line.startsWith('diff --git ') || line.startsWith('+++ ');
      if (!hunk && !file) continue;
      if (hunk && chain.isNotEmpty) continue;
      chain.add(StickyLine(i, line.trimRight(), 0));
      // Past the file's own header there is nothing else holding this line up.
      if (file) break;
    }
    return chain.reversed.toList();
  }

  // The nearest line above whose role the grammar calls sticky. Flat by
  // nature: a section heading has nothing above it but another section, and
  // showing both would say the file is nested when it is not.
  if (plan.roles.isNotEmpty && roleOfLine != null) {
    for (var i = top - 1; i >= 0; i--) {
      if (plan.roles.contains(roleOfLine(i))) {
        chain.add(StickyLine(i, lines[i].trimRight(), indentOf(lines[i])));
        break;
      }
    }
  }

  if (plan.byIndent) {
    // Backwards from the top line, taking each line that starts further out
    // than the last one taken — the enclosing scopes, without a parser.
    //
    // Blank lines are skipped rather than ending the walk: an empty line
    // inside a function is not the end of the function. A line at the very
    // margin ends it, being enclosed by nothing.
    var depth = _blank(lines[top]) ? 1 << 30 : indentOf(lines[top]);
    final byIndent = <StickyLine>[];
    for (var i = top - 1; i >= 0; i--) {
      final line = lines[i];
      if (_blank(line)) continue;
      final indent = indentOf(line);
      if (indent >= depth) continue;
      byIndent.insert(0, StickyLine(i, line.trimRight(), indent));
      depth = indent;
      if (indent == 0) break;
    }
    // A file that is flat — every line at the margin — has nothing enclosing
    // anything, and the walk above finds nothing to keep. That is the answer,
    // not a gap: plain text gets no strip.
    for (final line in byIndent) {
      if (!chain.any((kept) => kept.index == line.index)) chain.add(line);
    }
  }

  chain.sort((a, b) => a.index.compareTo(b.index));
  return chain.length > StickyPlan.deepest
      ? chain.sublist(chain.length - StickyPlan.deepest)
      : chain;
}

/// The role of the first thing written on each line, one entry per line.
///
/// Worked out in one pass over the file rather than per scroll: the scanner
/// reads left to right and a role can depend on what came before it — a `#`
/// inside a string is not a comment — so there is no asking about one line on
/// its own anyway.
List<CodeRole> rolesOfLines(String source, SyntaxGrammar grammar, int lines) {
  final roles = List<CodeRole>.filled(lines, CodeRole.plain);
  final settled = List<bool>.filled(lines, false);
  var line = 0;

  for (final (role, text) in splitCode(source, grammar)) {
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (c == '\n') {
        line++;
        if (line >= lines) return roles;
        continue;
      }
      if (settled[line] || c == ' ' || c == '\t' || c == '\r') continue;
      roles[line] = role;
      settled[line] = true;
    }
  }
  return roles;
}
