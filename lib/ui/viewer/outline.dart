/// What is in a file, roughly, so somebody can jump about in it.
///
/// **Deliberately approximate, and the error budget decides everything here.**
/// A wrong line number is unacceptable — so a line is taken straight from the
/// scan and never worked out. A junk node is expensive — forty of the same one
/// kill the panel. A missed node is cheap — the reader scrolls. Which gives one
/// rule the rest follows from: *when in doubt, do not show it.*
///
/// This is not an index of symbols, not "go to definition", and cannot become
/// either. What it costs is one walk over what the colouring already produced;
/// what a real one costs is a language server per language, which is the
/// bargain we are not making.
///
/// The nesting comes from whatever the grammar declared — see [BlockNesting] —
/// and the naming from three rules with no regular expression in them:
///
/// 1. a **declaring word** at the head of the block names what follows it;
/// 2. an identifier standing directly in front of a **balanced `(`** is a
///    function or a method;
/// 3. anything else is **transparent**: it is not shown, and its children rise
///    to its parent. That single line is what removes every `if`, `for`,
///    `while`, lambda and brace-opening macro from the tree.
///
/// **Measured before it was decided, on 2026-08-16**, because the question was
/// whether this belongs in an isolate. On the test VM — which is the slow end,
/// being unoptimised — a file of Dart took 71 ms at half a megabyte, 248 ms at
/// two, and 905 ms at eight; two megabytes of JSON took 136 ms. The text
/// viewer stops reading at two megabytes, so the honest worst case is a
/// quarter of a second, once, when the panel is opened.
///
/// So: **no isolate.** It is worked out after the frame that opened the panel
/// rather than during it, which is where the pause belongs; an isolate would
/// buy a fraction of a second back and cost a copy of the file, a grammar that
/// cannot be sent as it stands (its line patterns are compiled expressions),
/// and a second way for the answer to arrive late. Worth measuring again if
/// the viewer's limit is ever raised.
library;

import '../../core/plugins/grammar.dart';
import 'code_syntax.dart';
import 'diff_syntax.dart';
import 'json_syntax.dart';
import 'markdown_view.dart' show splitLines;
import 'sticky_lines.dart' show indentOf, rolesOfLines;

/// What a node is, as a role. **Never an icon and never a colour** — the panel
/// picks those out of its own set, exactly as the colouring picks a colour for
/// a [CodeRole].
enum OutlineKind {
  namespace,

  /// A class, struct, enum, interface, union — a declared type.
  ///
  /// Not called `class`, which Dart will not let an enum say.
  type,

  function,
  method,

  /// A leaf that holds a value rather than more structure: a key in a JSON
  /// document.
  field,

  /// A part of a flat file — `[Section]` in an INI file, a key in YAML.
  section,

  /// A markdown heading.
  heading,

  /// One file of a diff.
  file,

  /// One `@@` of a diff.
  hunk,
}

/// One entry in the outline.
///
/// A flat list with a depth on each entry rather than nested objects: the panel
/// draws whatever is unfolded with a `ListView.builder`, and "where am I" is a
/// binary search over [line].
class OutlineNode {
  const OutlineNode({
    required this.line,
    required this.endLine,
    required this.depth,
    required this.title,
    required this.kind,
  });

  /// The line the node leads to, counted from zero. **Taken from the scan**,
  /// never derived — the one error this cannot afford.
  final int line;

  /// The last line of what it covers, for saying where the reading is.
  final int endLine;

  /// How many visible nodes enclose it. A transparent block adds nothing,
  /// which is how its children come to stand under its parent.
  final int depth;

  final String title;
  final OutlineKind kind;

  /// Whether [at] falls inside what this node covers.
  bool holds(int at) => at >= line && at <= endLine;

  @override
  String toString() =>
      '${'  ' * depth}${kind.name} $title '
      '(${line + 1}..${endLine + 1})';
}

/// Deeper than this is not navigation — a lambda inside a method inside a class
/// is where somebody is already reading, not somewhere they are going.
const int kOutlineDeepest = 4;

/// A block shorter than this gives no node.
const int kOutlineShortestBlock = 3;

/// The most nodes any file may produce. Minified JSON offers hundreds of
/// thousands; a panel is not a place to put them.
const int kOutlineMostNodes = 5000;

/// The longest a title may be. A multi-line signature collapses to one line
/// and is cut here, which is a name rather than a declaration — the panel is
/// for finding the thing, not for reading it.
const int kOutlineLongestTitle = 120;

/// The outline of [source], however this file is best read.
///
/// [grammar] is what the language declared, [language] the hint the content
/// carried, [markdown] whether it is being *drawn* as markdown rather than as
/// text. Everything returns a list, and an empty one is an ordinary answer: a
/// file nothing can say anything about gets no panel at all.
List<OutlineNode> outlineOf(
  String source, {
  SyntaxGrammar? grammar,
  String? language,
  bool markdown = false,
}) {
  if (source.isEmpty) return const [];
  if (markdown) return markdownOutline(source);
  switch (language?.toLowerCase()) {
    case 'json':
    case 'jsonc':
      return jsonOutline(source);
    case 'diff':
    case 'patch':
      return diffOutline(source);
    case 'markdown':
    case 'md':
      return markdownOutline(source);
  }
  if (grammar == null) return const [];
  return codeOutline(source, grammar);
}

// --- Code -------------------------------------------------------------------

/// The outline of a file of code, by whichever mechanism its grammar declared.
List<OutlineNode> codeOutline(String source, SyntaxGrammar grammar) {
  switch (grammar.blocks) {
    case BlockNesting.braces:
      // **Braces that did not add up fall back to indentation, silently.** An
      // `#ifdef` that opens a block and closes it in the other branch is
      // ordinary C, and an outline has no right to fall over: an approximate
      // tree beats an empty one.
      return _byBraces(source, grammar) ??
          _byIndent(source, grammar, allowCall: true);
    case BlockNesting.indent:
      // No call rule here. In a brace language `if (x)` is caught by the
      // keyword in front of the bracket, but `with open(path):` and
      // `while ready(x):` are not, and a panel full of `open` is exactly the
      // repeated junk the budget calls fatal. Python says `def`; that is
      // enough.
      return _byIndent(source, grammar, allowCall: false);
    case BlockNesting.none:
      return _byRoles(source, grammar);
  }
}

/// One block being read: what it will be called, and where it began.
class _Open {
  _Open({
    required this.line,
    required this.depth,
    required this.indent,
    this.title,
    this.kind = OutlineKind.function,
    this.resume,
  });

  final int line;

  /// How many visible nodes enclose this one.
  final int depth;

  /// Only the indentation mechanism uses it.
  final int indent;

  /// Null for a transparent block — one that is not shown, and whose children
  /// stand under its parent instead.
  final String? title;
  final OutlineKind kind;

  /// The header to carry on with once this block closes, for a brace that was
  /// inside a bracket and therefore part of a signature. Null everywhere else,
  /// where a closing brace ends the sentence.
  final String? resume;

  bool get visible => title != null;

  /// The depth anything inside this block gets.
  int get inside => visible ? depth + 1 : depth;
}

/// Nesting by braces, counted in the colouring's own pass.
///
/// Returns null when the braces did not add up — an unbalanced file is not
/// this function's to guess at, and the caller falls back to indentation.
///
/// It walks what [splitCode] produced rather than the characters of the file,
/// which is what makes it honest without a parser: a `{` inside a string or a
/// comment is inside a run that is a string or a comment, and is never seen
/// here at all.
List<OutlineNode>? _byBraces(String source, SyntaxGrammar grammar) {
  final nodes = <OutlineNode>[];
  final open = <_Open>[];
  final header = StringBuffer();
  var line = 0;

  /// How many brackets are open where the scan stands.
  ///
  /// It is here for one thing: **a `{` inside a bracket is part of the
  /// signature, not a block of its own.** Dart writes its named parameters
  /// that way, so `AppearanceSettings copyWith({...}) {` used to lose its
  /// header at the first brace and every constructor and `copyWith` in the
  /// application went missing. Kept, the header comes back and the method is
  /// named by the bracket in front of it, as it should be.
  var brackets = 0;

  void space() {
    if (header.isNotEmpty && !header.toString().endsWith(' ')) {
      header.write(' ');
    }
  }

  /// Whether the scan is on a line that is about the file rather than in it —
  /// `#pragma comment(lib, "shlwapi.lib")`, which carries no `;` and used to
  /// hand its own words to the `namespace {` on the line below.
  var directive = false;

  for (final (role, text) in splitCode(source, grammar)) {
    // A comment is whitespace as far as a header is concerned, and its braces
    // are not braces at all.
    if (role == CodeRole.comment) {
      line += _newlines(text);
      space();
      continue;
    }
    if (role == CodeRole.meta) {
      line += _newlines(text);
      header.clear();
      directive = true;
      continue;
    }
    // A string keeps its place in the header — `extern "C" {` is a header with
    // a string in it — but never breaks a line and never opens a block.
    if (role == CodeRole.string) {
      line += _newlines(text);
      header.write(text.replaceAll('\n', ' '));
      continue;
    }

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      switch (c) {
        case '\n':
          line++;
          // A header runs on across lines — that is what carries a multi-line
          // signature or a template — but only while the language has a `;` to
          // end it and no bracket is standing open. A shell has neither: there
          // a line **is** the sentence.
          if (directive || (grammar.statementsEndAtLine && brackets == 0)) {
            header.clear();
            directive = false;
          } else {
            space();
          }
        case '(':
          brackets++;
          header.write(c);
        case ')':
          if (brackets > 0) brackets--;
          header.write(c);
        case '{':
          final named = _nameOf(header.toString(), grammar, allowCall: true);
          final depth = open.isEmpty ? 0 : open.last.inside;
          open.add(
            _Open(
              line: line,
              depth: depth,
              indent: 0,
              title: named?.$1,
              kind: named == null
                  ? OutlineKind.function
                  : _settle(named.$2, open),
              resume: brackets > 0 ? header.toString() : null,
            ),
          );
          header.clear();
        case '}':
          // A closing brace with nothing open is a file this cannot read.
          if (open.isEmpty) return null;
          final block = open.removeLast();
          _emit(nodes, block, line);
          header.clear();
          if (block.resume != null) header.write(block.resume);
        case ';':
          header.clear();
          // A statement has ended; whatever bracket was thought to be open was
          // never closed, and carrying it further would only spread the error.
          brackets = 0;
        case ' ':
        case '\t':
        case '\r':
          space();
        default:
          header.write(c);
      }
    }
  }

  if (open.isNotEmpty) return null;
  return _ordered(nodes);
}

/// Nesting by indentation — Python and YAML, and the way out when braces fail.
///
/// Every line that has anything on it opens a region, and a region that turns
/// out to be one or two lines long is dropped by the noise filter. So there is
/// no separate question of "is this line a heading": a statement is a region a
/// line long, and the filter answers it.
List<OutlineNode> _byIndent(
  String source,
  SyntaxGrammar grammar, {
  required bool allowCall,
}) {
  final lines = splitLines(source);
  final roles = rolesOfLines(source, grammar, lines.length);
  final nodes = <OutlineNode>[];
  final open = <_Open>[];
  var last = 0;

  for (var i = 0; i < lines.length; i++) {
    final text = lines[i];
    if (text.trim().isEmpty || roles[i] == CodeRole.comment) continue;
    final indent = indentOf(text);

    while (open.isNotEmpty && indent <= open.last.indent) {
      _close(nodes, open.removeLast(), last);
    }

    final named = _nameOfLine(text, roles[i], grammar, allowCall: allowCall);
    final depth = open.isEmpty ? 0 : open.last.inside;
    open.add(
      _Open(
        line: i,
        depth: depth,
        indent: indent,
        title: named?.$1,
        kind: named == null ? OutlineKind.function : _settle(named.$2, open),
      ),
    );
    last = i;
  }

  while (open.isNotEmpty) {
    _close(nodes, open.removeLast(), last);
  }
  return _ordered(nodes);
}

/// A flat file, held together by the roles its own lines carry — or by the
/// patterns its grammar named.
///
/// INI and TOML: a section runs until the next one, and nothing nests. SQL and
/// a Dockerfile have no section marker to colour, so their grammars name the
/// lines by pattern instead — see [OutlineRule], which is the door the
/// specification left open for exactly this.
List<OutlineNode> _byRoles(String source, SyntaxGrammar grammar) {
  if (grammar.outlineRoles.isEmpty && grammar.outlinePatterns.isEmpty) {
    return const [];
  }
  final lines = splitLines(source);
  final roles = rolesOfLines(source, grammar, lines.length);
  final found = <(int, String, OutlineKind)>[];

  for (var i = 0; i < lines.length; i++) {
    if (found.length >= kOutlineMostNodes) break;
    // A comment is never a heading, whatever it says inside itself.
    if (roles[i] == CodeRole.comment) continue;

    if (grammar.outlineRoles.contains(roles[i])) {
      final title = _lineTitle(lines[i], roles[i]);
      if (title.isNotEmpty) {
        found.add((i, title, OutlineKind.section));
        continue;
      }
    }

    final named = _byPattern(lines[i], grammar);
    if (named != null) found.add((i, named.$1, named.$2));
  }

  // One section runs to the line before the next one. Nothing nests: a flat
  // file that pretended to would be saying something about itself that is not
  // true.
  return [
    for (var i = 0; i < found.length; i++)
      OutlineNode(
        line: found[i].$1,
        endLine: i + 1 < found.length ? found[i + 1].$1 - 1 : lines.length - 1,
        depth: 0,
        title: found[i].$2,
        kind: found[i].$3,
      ),
  ];
}

/// What a grammar's own patterns make of a line, or null.
(String, OutlineKind)? _byPattern(String line, SyntaxGrammar grammar) {
  if (grammar.outlinePatterns.isEmpty) return null;
  final text = line.trimLeft();
  for (final rule in grammar.outlinePatterns) {
    final match = rule.match.matchAsPrefix(text);
    if (match == null) continue;
    final name = rule.name <= match.groupCount ? match.group(rule.name) : null;
    final title = _short(name ?? match.group(0) ?? '');
    if (title.isEmpty) continue;
    return (title, _kindNamed(rule.kind));
  }
  return null;
}

/// A kind by the name a grammar used for it. Anything it has not heard of is a
/// section, which is the neutral answer — a newer grammar still draws on an
/// older application.
OutlineKind _kindNamed(String name) => switch (name) {
      'namespace' => OutlineKind.namespace,
      'type' || 'class' => OutlineKind.type,
      'function' => OutlineKind.function,
      'method' => OutlineKind.method,
      'field' => OutlineKind.field,
      'heading' => OutlineKind.heading,
      _ => OutlineKind.section,
    };

/// Closes a region of an indented file.
///
/// A section of a data file has to hold something to be worth a line in the
/// panel; a declaration is worth one whatever its size, and the shorter
/// measure is what makes a two-line `def` a function rather than nothing.
void _close(List<OutlineNode> nodes, _Open block, int endLine) => _emit(
  nodes,
  block,
  endLine,
  shortest: block.kind == OutlineKind.section
      ? kOutlineShortestBlock
      : kOutlineShortestBlock - 1,
);

/// Adds [block] to [nodes] if it survives the two noise filters.
///
/// [shortest] is how many lines it has to cover to be worth a node, and it is
/// not the same number everywhere. A brace language spends a line on the `}`,
/// so three lines there is a header and one line of work — which is exactly
/// what two lines is in a file nested by its indentation. A `def` written over
/// two lines is a function, and the acceptance asks for every one of them.
void _emit(
  List<OutlineNode> nodes,
  _Open block,
  int endLine, {
  int shortest = kOutlineShortestBlock,
}) {
  if (!block.visible) return;
  if (nodes.length >= kOutlineMostNodes) return;
  if (block.depth >= kOutlineDeepest) return;
  final end = endLine < block.line ? block.line : endLine;
  if (end - block.line + 1 < shortest) return;
  nodes.add(
    OutlineNode(
      line: block.line,
      endLine: end,
      depth: block.depth,
      title: block.title!,
      kind: block.kind,
    ),
  );
}

/// A function inside a type is a method. Decided where the block opens, from
/// what is standing over it.
OutlineKind _settle(OutlineKind kind, List<_Open> open) {
  if (kind != OutlineKind.function) return kind;
  for (var i = open.length - 1; i >= 0; i--) {
    if (!open[i].visible) continue;
    return open[i].kind == OutlineKind.type
        ? OutlineKind.method
        : OutlineKind.function;
  }
  return OutlineKind.function;
}

/// Blocks close from the inside out, so they arrive backwards. Reading order
/// is the line they open on, and a node inside another on the same line comes
/// after it.
List<OutlineNode> _ordered(List<OutlineNode> nodes) {
  nodes.sort((a, b) {
    final byLine = a.line.compareTo(b.line);
    return byLine != 0 ? byLine : a.depth.compareTo(b.depth);
  });
  return nodes;
}

int _newlines(String text) {
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0a) count++;
  }
  return count;
}

// --- The three naming rules -------------------------------------------------

/// What a line of an indented file declares, or null for a transparent one.
(String, OutlineKind)? _nameOfLine(
  String text,
  CodeRole role,
  SyntaxGrammar grammar, {
  required bool allowCall,
}) {
  // A line whose role is structure in its own right — a YAML key, an INI
  // section. Asked first, because such a file has no declaring words at all.
  if (grammar.outlineRoles.contains(role)) {
    final title = _lineTitle(text, role);
    if (title.isNotEmpty) return (title, OutlineKind.section);
  }
  // The block-opening colon is not part of the header, and neither is a
  // trailing brace on a line of C.
  var header = text.trim();
  if (header.endsWith('{')) header = header.substring(0, header.length - 1);
  if (header.endsWith(':')) header = header.substring(0, header.length - 1);
  return _nameOf(header, grammar, allowCall: allowCall);
}

/// What a block header declares, or null when it declares nothing.
///
/// The whole of rules one and two, and the only place either is written down.
(String, OutlineKind)? _nameOf(
  String header,
  SyntaxGrammar grammar, {
  required bool allowCall,
}) {
  final words = _wordsOf(header);
  if (words.isEmpty) return null;

  // Rule one: a declaring word, and the name is the next word that is not
  // itself a word of the language. Looked for ahead of the first `(` or `=`,
  // so `template <typename T> class Foo` and `public abstract class Foo` both
  // work, and what is inside a call or an initialiser is not mistaken for a
  // declaration.
  final stop = _firstOf(header, '(=');
  for (final word in words) {
    if (word.$2 >= stop) break;
    if (!_declares(grammar, word.$1)) continue;
    final name = _nameAfter(header, word.$3, grammar);
    // `struct {` with no name after it declares nothing anybody can navigate
    // to. Transparent, and its children rise.
    return name == null ? null : (name, _kindOfWord(grammar, word.$1));
  }

  if (!allowCall) return null;

  // Rule two: an identifier standing **directly** in front of a bracket that
  // is closed by the time the block opens.
  //
  // Both halves earn their place. Without the balance, `setState(() {` is a
  // function called `setState` and every rebuild in the file is a node.
  // Without the adjacency, `builder: (context) {` is a function called
  // `builder`. And a keyword in front of the bracket is `if`, `for`, `while`,
  // `switch`, `catch` — the blocks the panel exists to leave out.
  if (_depthOfBrackets(header) != 0) return null;
  final bracket = header.indexOf('(');
  if (bracket < 0) return null;
  for (var i = words.length - 1; i >= 0; i--) {
    final (word, start, end) = words[i];
    if (start >= bracket) continue;
    if (header.substring(end, bracket).trim().isNotEmpty) return null;
    if (grammar.roleOfWord(word) == CodeRole.keyword) return null;
    if (!_meaningful(word)) return null;
    return (_short(word), OutlineKind.function);
  }
  return null;
}

/// The name a declaring word gives, taken as **a token rather than a word**.
///
/// `Get-Thing` in PowerShell and `a::b` in C++ are one name each and three
/// identifiers each, so the name is read as the run of characters up to what
/// ends it. Words of the language on the way are stepped over, which is what
/// makes `enum class Color` and `public sealed class Door` come out right.
String? _nameAfter(String header, int from, SyntaxGrammar grammar) {
  var i = from;
  while (i < header.length) {
    while (i < header.length && (header[i] == ' ' || header[i] == '\t')) {
      i++;
    }
    if (i >= header.length) return null;
    final start = i;
    while (i < header.length && !_endsAName.contains(header[i])) {
      i++;
    }
    final token = header.substring(start, i);
    if (token.isEmpty) {
      // A bracket or an `=` where a name should be: this is a call or an
      // assignment, and nothing is being declared.
      if ('({=<'.contains(header[i])) return null;
      i++;
      continue;
    }
    if (_declares(grammar, token) ||
        grammar.roleOfWord(token) == CodeRole.keyword) {
      continue;
    }
    return _meaningful(token) ? _short(token) : null;
  }
  return null;
}

const String _endsAName = ' \t(){}<>,;:=';

/// Whether a name is worth showing: `$` in `x=$(cmd)` is a word to the
/// scanner and nothing to a reader.
bool _meaningful(String word) {
  for (var i = 0; i < word.length; i++) {
    final code = word.codeUnitAt(i);
    if ((code | 0x20) >= 0x61 && (code | 0x20) <= 0x7a) return true;
    if (code >= 0x30 && code <= 0x39) return true;
    if (code > 0x7f) return true;
  }
  return false;
}

bool _declares(SyntaxGrammar grammar, String word) => grammar.declares.contains(
  grammar.caseSensitive ? word : word.toLowerCase(),
);

/// Which kind a declaring word makes. **The host's mapping, not the
/// grammar's** — a grammar lists words, the way it lists roles, and never says
/// what anything looks like.
OutlineKind _kindOfWord(SyntaxGrammar grammar, String word) =>
    switch (word.toLowerCase()) {
      'namespace' || 'module' || 'package' => OutlineKind.namespace,
      'def' ||
      'fn' ||
      'func' ||
      'function' ||
      'sub' ||
      'proc' => OutlineKind.function,
      _ => OutlineKind.type,
    };

/// The words of a header, with where each one sits in it.
List<(String, int, int)> _wordsOf(String header) {
  final words = <(String, int, int)>[];
  var i = 0;
  while (i < header.length) {
    if (!_isWordStart(header.codeUnitAt(i))) {
      i++;
      continue;
    }
    var end = i + 1;
    while (end < header.length && _isWordPart(header.codeUnitAt(end))) {
      end++;
    }
    words.add((header.substring(i, end), i, end));
    i = end;
  }
  return words;
}

bool _isWordStart(int code) =>
    (code | 0x20) >= 0x61 && (code | 0x20) <= 0x7a ||
    code == 0x5f ||
    code == 0x24 ||
    code > 0x7f;

bool _isWordPart(int code) =>
    _isWordStart(code) || (code >= 0x30 && code <= 0x39);

/// Where the first of [any] appears in [header], or its length.
int _firstOf(String header, String any) {
  for (var i = 0; i < header.length; i++) {
    if (any.contains(header[i])) return i;
  }
  return header.length;
}

/// How many brackets are still open at the end of [header].
int _depthOfBrackets(String header) {
  var depth = 0;
  for (var i = 0; i < header.length; i++) {
    if (header[i] == '(') depth++;
    if (header[i] == ')') depth--;
  }
  return depth;
}

/// The name a flat file's line carries.
///
/// A section marker is kept whole — `[core]` is what the file calls it. A key
/// is cut at its value, because `image: postgres:15` is a key called `image`.
String _lineTitle(String line, CodeRole role) {
  final text = line.trim();
  if (role == CodeRole.meta) return _short(text);
  final cut = _firstOf(text, ':=');
  return _short(cut < text.length ? text.substring(0, cut) : text);
}

/// One line of it, spaces collapsed, and not longer than the panel can use.
String _short(String text) {
  final one = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  return one.length <= kOutlineLongestTitle
      ? one
      : '${one.substring(0, kOutlineLongestTitle - 1)}…';
}

// --- The three sources that are not a grammar -------------------------------

/// The keys of a JSON document, as a tree.
///
/// Read off what [splitJson] already produced, which is what tells a name from
/// a value — the one thing a reader of JSON needs and the one thing a scanner
/// of it can say for certain.
List<OutlineNode> jsonOutline(String source) {
  final nodes = <OutlineNode>[];
  final open = <_Open>[];
  var line = 0;
  (String, int)? pending;

  void leaf() {
    final key = pending;
    pending = null;
    if (key == null) return;
    if (nodes.length >= kOutlineMostNodes) return;
    final depth = open.isEmpty ? 0 : open.last.inside;
    if (depth >= kOutlineDeepest) return;
    nodes.add(
      OutlineNode(
        line: key.$2,
        endLine: line,
        depth: depth,
        title: key.$1,
        kind: OutlineKind.field,
      ),
    );
  }

  for (final (part, text) in splitJson(source)) {
    switch (part) {
      case JsonPart.key:
        leaf();
        pending = (_unquote(text), line);
        line += _newlines(text);
      case JsonPart.string:
      case JsonPart.number:
      case JsonPart.literal:
        // A value settles whatever key was waiting for it.
        leaf();
        line += _newlines(text);
      case JsonPart.plain:
        line += _newlines(text);
      case JsonPart.punctuation:
        for (var i = 0; i < text.length; i++) {
          switch (text[i]) {
            case '{':
            case '[':
              final key = pending;
              pending = null;
              final depth = open.isEmpty ? 0 : open.last.inside;
              open.add(
                _Open(
                  line: key?.$2 ?? line,
                  depth: depth,
                  indent: 0,
                  // A container with no key of its own — the document itself,
                  // or one item of an array — is transparent, and its keys
                  // stand where it stood.
                  title: key?.$1,
                  kind: OutlineKind.section,
                ),
              );
            case '}':
            case ']':
              leaf();
              if (open.isEmpty) break;
              final block = open.removeLast();
              if (block.visible &&
                  block.depth < kOutlineDeepest &&
                  nodes.length < kOutlineMostNodes) {
                nodes.add(
                  OutlineNode(
                    line: block.line,
                    endLine: line,
                    depth: block.depth,
                    title: block.title!,
                    kind: OutlineKind.section,
                  ),
                );
              }
            case ',':
              leaf();
          }
        }
    }
  }
  return _ordered(nodes);
}

String _unquote(String text) {
  var name = text.trim();
  if (name.length >= 2 && name.startsWith('"') && name.endsWith('"')) {
    name = name.substring(1, name.length - 1);
  }
  return _short(name);
}

/// The files of a diff, and the hunks inside them.
List<OutlineNode> diffOutline(String source) {
  final lines = splitLines(source);
  final found = <(int, int, String, OutlineKind)>[];
  var named = false;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (found.length >= kOutlineMostNodes) break;
    if (line.startsWith('diff --git ')) {
      found.add((
        i,
        0,
        _pathOf(line.substring('diff --git '.length)),
        OutlineKind.file,
      ));
      named = true;
      continue;
    }
    if (line.startsWith('+++ ')) {
      // The pair after `diff --git` says the same thing twice; only a bare
      // diff — what `diff -u` prints — needs this to name the file.
      if (named) {
        named = false;
        continue;
      }
      found.add((i, 0, _pathOf(line.substring(4)), OutlineKind.file));
      continue;
    }
    if (partOf(line) == DiffPart.hunk) {
      found.add((i, found.isEmpty ? 0 : 1, _short(line), OutlineKind.hunk));
    }
  }

  // What a node covers runs to the line before the next one at its own level
  // or above it — a hunk ends where the next hunk begins, a file where the
  // next file does.
  return [
    for (var i = 0; i < found.length; i++)
      () {
        var end = lines.length - 1;
        for (var j = i + 1; j < found.length; j++) {
          if (found[j].$2 <= found[i].$2) {
            end = found[j].$1 - 1;
            break;
          }
        }
        return OutlineNode(
          line: found[i].$1,
          endLine: end < found[i].$1 ? found[i].$1 : end,
          depth: found[i].$2,
          title: found[i].$3,
          kind: found[i].$4,
        );
      }(),
  ];
}

/// The path out of a diff's own header, without the `a/` and `b/` it wears.
String _pathOf(String text) {
  var path = text.trim();
  final tab = path.indexOf('\t');
  if (tab > 0) path = path.substring(0, tab);
  final space = path.indexOf(' ');
  if (space > 0) path = path.substring(space + 1);
  if (path.startsWith('a/') || path.startsWith('b/')) {
    path = path.substring(2);
  }
  return _short(path);
}

/// The headings of a markdown document.
///
/// Fenced code is skipped, because a `#` inside a fence is a comment in
/// somebody's shell script and not a heading — which is the one thing a
/// line-at-a-time reading of markdown gets wrong.
List<OutlineNode> markdownOutline(String source) {
  final lines = splitLines(source);
  final nodes = <OutlineNode>[];
  final open = <_Open>[];
  final levels = <int>[];
  String? fence;

  void closeTo(int level, int endLine) {
    while (levels.isNotEmpty && levels.last >= level) {
      levels.removeLast();
      _emitHeading(nodes, open.removeLast(), endLine);
    }
  }

  for (var i = 0; i < lines.length; i++) {
    final text = lines[i];
    final trimmed = text.trimLeft();
    if (fence != null) {
      if (trimmed.startsWith(fence)) fence = null;
      continue;
    }
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      fence = trimmed.substring(0, 3);
      continue;
    }
    final match = _heading.firstMatch(trimmed);
    if (match == null) continue;

    final level = match.group(1)!.length;
    final title = _short(match.group(2)!);
    if (title.isEmpty) continue;
    closeTo(level, i - 1);
    levels.add(level);
    open.add(
      _Open(
        line: i,
        depth: levels.length - 1,
        indent: 0,
        title: title,
        kind: OutlineKind.heading,
      ),
    );
  }
  closeTo(0, lines.length - 1);
  return _ordered(nodes);
}

/// A heading node keeps whatever it heads, however short — a section with one
/// line under it is still a place in the document, which is not true of a
/// two-line block of code.
void _emitHeading(List<OutlineNode> nodes, _Open block, int endLine) {
  if (block.depth >= kOutlineDeepest) return;
  if (nodes.length >= kOutlineMostNodes) return;
  nodes.add(
    OutlineNode(
      line: block.line,
      endLine: endLine < block.line ? block.line : endLine,
      depth: block.depth,
      title: block.title!,
      kind: OutlineKind.heading,
    ),
  );
}

final RegExp _heading = RegExp(r'^(#{1,6})\s+(.*)$');
