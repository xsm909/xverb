/// Total Commander style file masks.
///
/// `*` and `?` behave as everywhere else. Several masks are separated by
/// spaces, semicolons or commas, and a `|` starts the list of masks to
/// *exclude*: `*.dart *.yaml | *.g.dart`.
///
/// A token with no wildcard in it is matched as a substring rather than as a
/// whole name — typing `readme` into a search field means "anything called
/// readme-something", which is what Total Commander does too.
class FileMask {
  const FileMask._(this._include, this._exclude, this.source);

  /// Matches everything. What an empty search field means.
  static const FileMask any = FileMask._([], [], '');

  final List<_Token> _include;
  final List<_Token> _exclude;

  /// The text this mask was parsed from, kept for titles and error messages.
  final String source;

  bool get isEmpty => _include.isEmpty && _exclude.isEmpty;

  factory FileMask.parse(String text, {bool caseSensitive = false}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return any;

    final bar = trimmed.indexOf('|');
    final includeText = bar < 0 ? trimmed : trimmed.substring(0, bar);
    final excludeText = bar < 0 ? '' : trimmed.substring(bar + 1);

    return FileMask._(
      _tokenize(includeText, caseSensitive),
      _tokenize(excludeText, caseSensitive),
      trimmed,
    );
  }

  bool matches(String name) {
    if (_exclude.any((token) => token.matches(name))) return false;
    if (_include.isEmpty) return true;
    return _include.any((token) => token.matches(name));
  }

  static List<_Token> _tokenize(String text, bool caseSensitive) => [
        for (final part in text.split(RegExp(r'[\s;,]+')))
          if (part.isNotEmpty) _Token(part, caseSensitive),
      ];
}

/// One mask: either a glob or a plain substring.
class _Token {
  _Token(String pattern, this.caseSensitive)
      : _glob = pattern.contains('*') || pattern.contains('?')
            ? _compile(pattern, caseSensitive)
            : null,
        _literal = caseSensitive ? pattern : pattern.toLowerCase();

  final bool caseSensitive;
  final RegExp? _glob;
  final String _literal;

  bool matches(String name) {
    final glob = _glob;
    if (glob != null) return glob.hasMatch(name);
    return caseSensitive
        ? name.contains(_literal)
        : name.toLowerCase().contains(_literal);
  }

  static RegExp _compile(String pattern, bool caseSensitive) {
    // `*.*` reads as "every file" everywhere it is offered, even though taken
    // literally it would demand a dot.
    if (pattern == '*.*' || pattern == '*') {
      return RegExp(r'^.*$');
    }

    final buffer = StringBuffer('^');
    for (final rune in pattern.runes) {
      final char = String.fromCharCode(rune);
      switch (char) {
        case '*':
          buffer.write('.*');
        case '?':
          buffer.write('.');
        default:
          buffer.write(RegExp.escape(char));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString(), caseSensitive: caseSensitive);
  }
}
