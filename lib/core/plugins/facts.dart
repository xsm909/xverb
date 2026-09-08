/// What a file says about itself.
///
/// **A separate contribution from the viewer, and deliberately so.** Who draws
/// a photograph and who can read what is written inside it are not the same
/// question: on both machines the picture is decoded by the *system's* engine
/// through a declarative plugin that runs no code of ours at all, so a JPEG's
/// EXIF has nobody to come from if facts are something a viewer returns. A
/// describer is asked separately, by extension, and answers for a file whoever
/// happens to be drawing it.
///
/// It is also the shape the sound viewer wants — tags, and what is in the file
/// — so the two were designed together rather than one after the other.
///
/// **Groups rather than a flat list**, because two hundred EXIF tags in one
/// column is a hex dump with names on it. The plugin decides what belongs
/// together and in what order; the host draws the groups it is given, in the
/// order it is given them, and knows nothing about cameras.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One thing a file says: a label and what it says for it.
class Fact {
  const Fact({required this.label, required this.value, this.wide = false});

  factory Fact.fromJson(Map<String, dynamic> json) => Fact(
    label: json['label']?.toString() ?? '',
    value: json['value']?.toString() ?? '',
    wide: json['wide'] == true,
  );

  final String label;
  final String value;

  /// Whether this wants the whole width — a description, a comment, a list of
  /// keywords. Drawn under its label rather than beside it.
  final bool wide;
}

/// Facts that belong together, under a heading.
class FactGroup {
  const FactGroup({required this.title, required this.facts});

  factory FactGroup.fromJson(Map<String, dynamic> json) => FactGroup(
    title: json['title']?.toString() ?? '',
    facts: [
      for (final fact in (json['facts'] as List?) ?? const [])
        if (fact is Map) Fact.fromJson(Map<String, dynamic>.from(fact)),
    ],
  );

  final String title;
  final List<Fact> facts;
}

/// Everything one file says about itself, as one describer read it.
class FileFacts {
  const FileFacts({
    this.groups = const [],
    this.note,
    this.error,
    this.picture,
    this.pictureType = 'image/jpeg',
  });

  factory FileFacts.fromJson(Map<String, dynamic> json) => FileFacts(
    groups: [
      for (final group in (json['groups'] as List?) ?? const [])
        if (group is Map) FactGroup.fromJson(Map<String, dynamic>.from(group)),
    ],
    note: json['note']?.toString(),
    error: json['error']?.toString(),
    picture: _bytes(json['picture']),
    pictureType: json['pictureType']?.toString() ?? 'image/jpeg',
  );

  const FileFacts.failed(String message)
    : groups = const [],
      note = null,
      error = message,
      picture = null,
      pictureType = 'image/jpeg';

  static Uint8List? _bytes(Object? value) {
    if (value is! String || value.isEmpty) return null;
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }

  final List<FactGroup> groups;

  /// A sentence under the groups — what could not be read, or that the file
  /// carries nothing beyond its own size. Never a substitute for the groups:
  /// a file with nothing to say still says how big it is.
  final String? note;

  /// Set when the describer could not be asked at all. Told apart from [note]
  /// because one is the file's answer and the other is the absence of one.
  final String? error;

  /// A picture that *is* one of the facts — the cover art inside a recording,
  /// which is a thing the file says about itself as much as the album name is.
  ///
  /// Bytes rather than a path, because it is inside the file and there is no
  /// path to it, and drawn by the engine like any other picture. Null wherever
  /// the file carries none.
  final Uint8List? picture;

  /// What kind of picture [picture] is, so the engine is not asked to guess.
  final String pictureType;

  bool get isEmpty =>
      picture == null && groups.every((group) => group.facts.isEmpty);
}
