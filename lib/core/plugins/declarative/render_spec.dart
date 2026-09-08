/// How a declarative viewer turns bytes into content.
///
/// A declarative plugin contains no code — it names one of the host's built-in
/// primitives and configures it. This is the same idea as Blender's node groups
/// and theme extensions: real functionality composed from primitives the
/// application already ships, described purely as data.
///
/// The trade is explicit. Anything the primitives cannot express cannot be
/// written declaratively; that is what the Python runtime is for.
class RenderSpec {
  const RenderSpec({
    required this.kind,
    this.source = 'lines',
    this.transform = 'none',
    this.encoding = 'utf-8',
    this.syntax = '',
    this.delimiter = 'auto',
    this.hasHeader = true,
    this.maxBytes = 1 << 20,
    this.maxRows = 5000,
  });

  factory RenderSpec.fromJson(Map<String, dynamic> json) => RenderSpec(
        kind: json['kind'] as String? ?? 'text',
        source: json['source'] as String? ?? 'lines',
        transform: json['transform'] as String? ?? 'none',
        encoding: json['encoding'] as String? ?? 'utf-8',
        syntax: json['syntax'] as String? ?? '',
        delimiter: json['delimiter'] as String? ?? 'auto',
        hasHeader: json['hasHeader'] as bool? ?? true,
        maxBytes: (json['maxBytes'] as num?)?.toInt() ?? (1 << 20),
        maxRows: (json['maxRows'] as num?)?.toInt() ?? 5000,
      );

  /// One of `text`, `markdown`, `hex`, `image`, `table`, `audio`.
  final String kind;

  /// For `table`: `csv`, `tsv`, `json` or `lines`.
  final String source;

  /// For `text`: `none` or `json-pretty`.
  final String transform;

  /// `utf-8` or `latin1`. Malformed bytes are replaced, never fatal.
  final String encoding;

  /// For `text`: the language to colour it as, `auto` to take that from the
  /// file's own extension, or empty for no colouring at all.
  ///
  /// **Choosing, not computing.** The viewer says which language; a grammar
  /// somebody shipped as data says what that language looks like; the host
  /// reads the file once with it. Nothing here describes a language.
  final String syntax;

  /// For `table` with a `csv` source: a literal separator, or `auto` to sniff.
  final String delimiter;

  /// Whether the first row of a table names the columns.
  final bool hasHeader;

  /// Ceiling on how much of the file is pulled across.
  final int maxBytes;

  /// Ceiling on rows shown in a table.
  final int maxRows;

  /// True when the spec names a primitive the host actually implements.
  bool get isSupported =>
      const {'text', 'markdown', 'hex', 'image', 'table', 'audio'}
          .contains(kind);
}
