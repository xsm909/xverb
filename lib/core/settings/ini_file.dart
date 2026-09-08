/// A small INI reader and writer.
///
/// Connection files are meant to be opened and edited by hand, which is why
/// they are INI rather than JSON — and why writing preserves nothing clever:
/// what comes out is plain, ordered and diffable.
class IniFile {
  IniFile([Map<String, Map<String, String>>? sections])
      : sections = sections ?? <String, Map<String, String>>{};

  /// Section name to its keys, both in the order they were read or added.
  final Map<String, Map<String, String>> sections;

  static final RegExp _sectionPattern = RegExp(r'^\s*\[(.+)\]\s*$');

  /// Parses [text]. Anything unrecognisable is skipped rather than throwing:
  /// a hand-edited file with one bad line should still load.
  factory IniFile.parse(String text) {
    final file = IniFile();
    var current = <String, String>{};

    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) {
        continue;
      }

      final section = _sectionPattern.firstMatch(line);
      if (section != null) {
        current = <String, String>{};
        file.sections[section.group(1)!.trim()] = current;
        continue;
      }

      // Split on the first separator only: values may contain '=' freely,
      // which URLs and base64 both do.
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      current[line.substring(0, separator).trim()] =
          line.substring(separator + 1).trim();
    }
    return file;
  }

  String encode() {
    final buffer = StringBuffer();
    for (final entry in sections.entries) {
      buffer.writeln('[${entry.key}]');
      for (final pair in entry.value.entries) {
        buffer.writeln('${pair.key}=${pair.value}');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// A section name cannot contain the brackets that delimit it, and leading
  /// or trailing space would be lost on the next read.
  static String sanitiseSectionName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\[\]\r\n]'), '').trim();
    return cleaned.isEmpty ? 'Connection' : cleaned;
  }

  /// A value must survive a round trip, so newlines are not allowed in one.
  static String sanitiseValue(String value) =>
      value.replaceAll(RegExp(r'[\r\n]'), ' ');
}
