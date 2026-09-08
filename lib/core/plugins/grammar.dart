/// What one language looks like, as data a plugin ships.
///
/// **The dictionary belongs to a plugin; the reading of it belongs here**, so
/// that a new language costs a block of data rather than a build. A grammar
/// names its comments, its quotes, its words and its numbers; [splitCode] walks
/// a file with it once, and the viewer turns what comes back into the palette's
/// colours.
///
/// It is deliberately not a parser and cannot become one. There are no rules
/// about nesting, no state beyond "inside a comment, a string, or neither", and
/// nothing a language can say about what its words *mean*. That is enough to
/// read a file and not nearly enough to compile one, which is the trade: a
/// dozen languages at a dozen lines each.
library;

/// What a run of characters is — the vocabulary a grammar may use, and the only
/// thing the drawing side knows about.
///
/// **A role, never a colour.** A grammar that named colours would be a grammar
/// that fights the palette, and in this application a colour is something the
/// user presses in the appearance preview.
enum CodeRole {
  keyword,
  type,
  constant,
  number,
  string,
  comment,

  /// A line that is about the file rather than in it: `#include`, `@override`,
  /// `[Section]` at the head of an INI block.
  meta,

  punctuation,
  plain,
}

CodeRole _roleOf(String? name) => switch (name) {
  'keyword' => CodeRole.keyword,
  'type' => CodeRole.type,
  'constant' => CodeRole.constant,
  'number' => CodeRole.number,
  'string' => CodeRole.string,
  'comment' => CodeRole.comment,
  'meta' => CodeRole.meta,
  'punctuation' => CodeRole.punctuation,
  _ => CodeRole.plain,
};

/// One way a language writes a string.
///
/// A language usually has three or four: `"…"`, `'…'`, `"""…"""`, and the raw
/// forms that turn the escape off. They are tried longest [open] first, so
/// `"""` wins over `"` without the grammar having to say so.
class StringRule {
  const StringRule({
    required this.open,
    required this.close,
    this.escape = '\\',
    this.multiline = false,
  });

  factory StringRule.fromJson(Map<String, dynamic> json) {
    final open = json['open'] as String? ?? '"';
    return StringRule(
      open: open,
      close: json['close'] as String? ?? open,
      // An empty escape is how a raw string says it has none — `r'\n'` in Dart
      // ends where the quote is, backslash or no backslash.
      escape: json['escape'] as String? ?? '\\',
      multiline: json['multiline'] as bool? ?? false,
    );
  }

  final String open;
  final String close;
  final String escape;

  /// Whether a newline is inside it or ends it. **The one thing that cannot be
  /// decided a line at a time**, and the reason the scanner reads a whole file
  /// rather than colouring the rows on screen.
  final bool multiline;
}

/// How a file of this language says one thing is inside another.
///
/// **The grammar declares it; nothing is guessed.** Which of the three a file
/// answers to decides how its outline is built — see `outline.dart`.
enum BlockNesting {
  /// `{` and `}`, counted in the colouring's own pass. C++, Dart, JS, C#.
  braces,

  /// Indentation. Python, YAML.
  indent,

  /// Neither: the file is flat, and what structure it has is the roles its
  /// lines already carry — `[Section]` in an INI file.
  none,
}

BlockNesting _nestingOf(String? name) => switch (name) {
  'braces' => BlockNesting.braces,
  'indent' => BlockNesting.indent,
  _ => BlockNesting.none,
};

/// A line that is a place to go to, named by a pattern.
///
/// **The door the structure specification left open, opened.** It said the
/// three mechanisms — braces, indentation, line roles — come first and that
/// regular expressions stay a door for later, to be pushed only when a real
/// language needs them. SQL is that language: `CREATE TABLE orders (` is
/// a heading in every editor and none of the three can see it, because SQL has
/// no braces, no indentation that means anything, and no line role worth
/// colouring.
///
/// Data in a plugin, as everything about a language is. The kind is a *role* —
/// the host picks the mark and the colour, exactly as it does for the
/// highlighting.
class OutlineRule {
  const OutlineRule({required this.match, this.kind = 'section', this.name = 1});

  factory OutlineRule.fromJson(Map<String, dynamic> json) => OutlineRule(
        match: RegExp(json['match'] as String? ?? r'$^', caseSensitive: false),
        kind: json['kind'] as String? ?? 'section',
        name: (json['name'] as num?)?.toInt() ?? 1,
      );

  /// Matched against the line, after its leading spaces.
  final RegExp match;

  /// What the host should call this — `section`, `type`, `function`. Named
  /// rather than drawn: see `OutlineKind`.
  final String kind;

  /// Which capture group holds the name. Zero means the whole match, which is
  /// what a heading that *is* its own name wants.
  final int name;
}

/// A pattern anchored at the start of a line, and what it makes that line.
class LineRule {
  const LineRule({required this.match, required this.role});

  factory LineRule.fromJson(Map<String, dynamic> json) => LineRule(
    match: RegExp(json['match'] as String? ?? r'$^'),
    role: _roleOf(json['role'] as String?),
  );

  /// Matched against what is left of the line, after its leading spaces.
  final RegExp match;
  final CodeRole role;
}

/// One language, as a plugin declares it.
class SyntaxGrammar {
  const SyntaxGrammar({
    required this.id,
    this.name = '',
    this.extensions = const [],
    this.names = const [],
    this.lineComments = const [],
    this.blockComments = const [],
    this.strings = const [],
    this.keywords = const {},
    this.types = const {},
    this.constants = const {},
    this.linePatterns = const [],
    this.sticky = const {},
    this.blocks = BlockNesting.none,
    this.declares = const {},
    this.outlineRoles = const {},
    this.outlinePatterns = const [],
    this.statementsEndAtLine = false,
    this.numbers = true,
    this.caseSensitive = true,
  });

  factory SyntaxGrammar.fromJson(Map<String, dynamic> json) {
    List<String> words(String key) =>
        ((json[key] as List?) ?? const []).map((e) => e.toString()).toList();

    final sensitive = json['caseSensitive'] as bool? ?? true;
    Set<String> set(String key) => {
      for (final word in words(key)) sensitive ? word : word.toLowerCase(),
    };

    return SyntaxGrammar(
      id: (json['id'] as String? ?? '').toLowerCase(),
      name: json['name'] as String? ?? '',
      extensions: words(
        'extensions',
      ).map((e) => e.toLowerCase().replaceFirst('.', '')).toList(),
      names: words('names').map((e) => e.toLowerCase()).toList(),
      lineComments: words('lineComment'),
      blockComments: [
        for (final pair in (json['blockComment'] as List?) ?? const [])
          if (pair is List && pair.length >= 2)
            (pair[0].toString(), pair[1].toString()),
      ],
      strings: [
        for (final rule in (json['strings'] as List?) ?? const [])
          if (rule is Map) StringRule.fromJson(Map<String, dynamic>.from(rule)),
      ],
      keywords: set('keywords'),
      types: set('types'),
      constants: set('constants'),
      linePatterns: [
        for (final rule in (json['linePatterns'] as List?) ?? const [])
          if (rule is Map) LineRule.fromJson(Map<String, dynamic>.from(rule)),
      ],
      sticky: {for (final name in words('sticky')) _roleOf(name)},
      blocks: _nestingOf(json['blocks'] as String?),
      declares: set('declares'),
      outlineRoles: {for (final name in words('outlineRoles')) _roleOf(name)},
      outlinePatterns: [
        for (final rule in (json['outline'] as List?) ?? const [])
          if (rule is Map) OutlineRule.fromJson(Map<String, dynamic>.from(rule)),
      ],
      statementsEndAtLine: json['statementsEndAtLine'] as bool? ?? false,
      numbers: json['numbers'] as bool? ?? true,
      caseSensitive: sensitive,
    );
  }

  /// What a file says it is written in — `dart`, `cpp`, `ini`.
  final String id;

  /// What to call it where a person reads it.
  final String name;

  /// What it is usually kept in, so a viewer can say "colour this one by its
  /// name" and get the right answer without being told twice.
  final List<String> extensions;

  /// Whole file names written in this language and carrying no extension —
  /// `Makefile`, `Dockerfile`, `LICENSE`. Matched exactly, case ignored.
  final List<String> names;

  final List<String> lineComments;
  final List<(String, String)> blockComments;
  final List<StringRule> strings;
  final Set<String> keywords;
  final Set<String> types;
  final Set<String> constants;
  final List<LineRule> linePatterns;

  /// Which roles make a line stand over the ones below it — `"sticky":
  /// ["meta"]`, so an INI file keeps `[Section]` at the top while its keys go
  /// past.
  ///
  /// Item 70b, and it is one of the two mechanisms rather than the only one:
  /// this is for the flat formats, where a heading is a *kind of line* the
  /// grammar already marks. Code is held up by its indentation instead, which
  /// needs nothing declared. Empty is the ordinary answer — most languages have
  /// no such line.
  final Set<CodeRole> sticky;

  /// How this language nests, for the outline the structure panel shows.
  ///
  /// [BlockNesting.none] is the answer for a language that has not said, and it
  /// means the file gets no tree out of its shape — only whatever
  /// [outlineRoles] names. Nothing is inferred from the other fields: a
  /// grammar that never mentions braces is not thereby a brace language.
  final BlockNesting blocks;

  /// The words that declare something with a name after them — `class`,
  /// `struct`, `namespace`, `def`.
  ///
  /// They are already in [keywords]; this says which of them a reader would
  /// look for in a table of contents. **The word decides the kind of node**,
  /// and the host decides that mapping: the grammar names words, never icons
  /// and never colours, exactly as it names roles rather than colours for the
  /// highlighting.
  ///
  /// Deliberately not the words that open a block — `if`, `for`, `while`. A
  /// block with no declaring word is transparent: it is not shown, and what is
  /// inside it rises to its parent. That one rule is what keeps forty `if`
  /// nodes out of the panel without a single regular expression.
  final Set<String> declares;

  /// Which line roles are structure in their own right — `"outlineRoles":
  /// ["meta"]`, so an INI file's `[Section]` heads the tree and a YAML file's
  /// keys are its branches.
  ///
  /// The counterpart of [sticky], and separate from it on purpose: an INI file
  /// wants its section to stand over the reading *and* to be in the outline,
  /// while a YAML file wants its keys in the outline and would be held up by
  /// its own indentation.
  final Set<CodeRole> outlineRoles;

  /// Lines that are places to go to, named by pattern — `"outline": [...]`.
  /// See [OutlineRule] for why this exists and why it came last.
  final List<OutlineRule> outlinePatterns;

  /// Whether a line of this language is a sentence — true for the shells,
  /// false for everything descended from C.
  ///
  /// It decides where a block's header starts: back to the previous `;` in a C
  /// language, and back to the start of the line in PowerShell, which has no
  /// `;` to go back to. Without it a `[CmdletBinding()]` four lines above a
  /// `function` ends up naming it, and that is the expensive kind of mistake —
  /// the same wrong name over and over.
  ///
  /// A header still runs on while a bracket is open, so a `param(` spread over
  /// six lines is one header either way.
  final bool statementsEndAtLine;

  /// Whether a run of digits is a *thing* in this language.
  ///
  /// True everywhere a program is written, and false for prose: a year in a
  /// paragraph of Markdown is not a literal, and colouring it as one turns a
  /// page of writing into a page with pale specks through it.
  final bool numbers;

  /// SQL and INI do not care about case; C does. Word lists are folded once,
  /// when the grammar is read, rather than at every word of every file.
  final bool caseSensitive;

  bool handles(String extension, {String name = ''}) =>
      (extension.isNotEmpty && extensions.contains(extension.toLowerCase())) ||
      (name.isNotEmpty && names.contains(name.toLowerCase()));

  /// Which of the three word lists this one is in, or [CodeRole.plain].
  CodeRole roleOfWord(String word) {
    final asked = caseSensitive ? word : word.toLowerCase();
    if (keywords.contains(asked)) return CodeRole.keyword;
    if (types.contains(asked)) return CodeRole.type;
    if (constants.contains(asked)) return CodeRole.constant;
    return CodeRole.plain;
  }

  /// True when there is nothing here to colour by — an empty grammar draws a
  /// file exactly as no grammar at all would, and saying so is cheaper than
  /// finding out one run at a time.
  bool get isEmpty =>
      lineComments.isEmpty &&
      blockComments.isEmpty &&
      strings.isEmpty &&
      keywords.isEmpty &&
      types.isEmpty &&
      constants.isEmpty &&
      linePatterns.isEmpty;
}
