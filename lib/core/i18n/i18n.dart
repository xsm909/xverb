import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// One language the application can be shown in.
///
/// The **key of every entry is the English text itself**. That is the whole
/// design: English needs no catalogue, because the source already is one; a
/// string nobody has translated yet falls back to English by construction
/// rather than by a rule someone has to remember; and a translator is handed
/// sentences rather than identifiers like `menu.file.delete.confirm`, which
/// say nothing about how the sentence ends up reading.
///
/// The cost is real and worth stating: changing an English string orphans its
/// translations. That is the same bargain gettext and Qt's `tr()` make, and it
/// is the right one here — the alternative is a second name for every sentence
/// in the application, kept in step by hand.
class Localisation {
  const Localisation({
    required this.code,
    required this.name,
    required this.entries,
  });

  /// Reads a catalogue from the JSON shipped in the bundle.
  ///
  /// **Decoded here rather than by `rootBundle.loadString`**, which hands
  /// anything over 50 KB to an isolate — and an isolate never finishes inside a
  /// widget test, whose clock is fake. The Russian catalogue crossed that line
  /// on 1.0.0.317 and hung `language_change_test`; Japanese, still under it,
  /// went on passing, which is what made it look like a Russian bug. Decoding
  /// fifty kilobytes takes well under a millisecond and happens once per change
  /// of language, so the isolate was never buying anything here.
  static Future<Localisation> fromAsset(LanguageOption language) async {
    if (language.isSource) return sourceLanguage(language);

    final bytes = await rootBundle.load('assets/i18n/${language.code}.json');
    final raw = utf8.decode(bytes.buffer.asUint8List());
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return Localisation(
      code: language.code,
      name: language.name,
      entries: {
        for (final entry in json.entries)
          if (entry.value is String && (entry.value as String).isNotEmpty)
            entry.key: entry.value as String,
      },
    );
  }

  /// A catalogue with nothing in it, which is exactly what English is.
  static Localisation sourceLanguage(LanguageOption language) =>
      Localisation(code: language.code, name: language.name, entries: const {});

  final String code;
  final String name;
  final Map<String, String> entries;

  /// The translation of [source], or [source] itself.
  String lookup(String source) => entries[source] ?? source;
}

/// A language the user can pick, and how it is written.
class LanguageOption {
  const LanguageOption({
    required this.code,
    required this.name,
    required this.endonym,
    this.needsWideCoverage = false,
  });

  /// The code stored in settings and used to find the catalogue. `system` is
  /// not a language: it means "whatever the machine is set to".
  final String code;

  /// The language named in English, for anyone reading the setting in English.
  final String name;

  /// The language named in itself, which is what someone looking for their own
  /// language actually scans the list for.
  final String endonym;

  /// True for a language the ordinary interface font cannot draw — Japanese
  /// above all. The theme adds a fallback stack for these, or every string
  /// comes out as boxes.
  final bool needsWideCoverage;

  /// English is the source, so it has no catalogue to load.
  bool get isSource => code == 'en';

  static const LanguageOption system = LanguageOption(
    code: 'system',
    name: 'System',
    endonym: 'System',
  );

  /// Every language that ships with the app.
  ///
  /// A language is **not** a plugin. It travels in the bundle, so the
  /// application can be read on a machine that has installed nothing — which
  /// includes the first launch, and the platforms where plugins cannot run at
  /// all.
  static const List<LanguageOption> shipped = [
    LanguageOption(code: 'en', name: 'English', endonym: 'English'),
    LanguageOption(code: 'ru', name: 'Russian', endonym: 'Русский'),
    LanguageOption(code: 'es', name: 'Spanish', endonym: 'Español'),
    LanguageOption(code: 'de', name: 'German', endonym: 'Deutsch'),
    LanguageOption(code: 'fr', name: 'French', endonym: 'Français'),
    // Hangul is no more drawable by the ordinary interface face than kana is,
    // so this one asks for the wide stack alongside Japanese.
    LanguageOption(
      code: 'ko',
      name: 'Korean',
      endonym: '한국어',
      needsWideCoverage: true,
    ),
    LanguageOption(
      code: 'ja',
      name: 'Japanese',
      endonym: '日本語',
      needsWideCoverage: true,
    ),
  ];

  /// What the language setting offers: the languages, with "System" first.
  static const List<LanguageOption> choices = [system, ...shipped];

  static LanguageOption byCode(String? code) {
    for (final option in choices) {
      if (option.code == code) return option;
    }
    return system;
  }

  /// What "System" resolves to: the machine's language if one of ours matches
  /// it, and English otherwise.
  static LanguageOption ofPlatform() {
    // The tag looks like `ru_RU.UTF-8` or `ja_JP`; only the language matters.
    final locale = Platform.localeName.split(RegExp('[_.-]')).first;
    for (final option in shipped) {
      if (option.code == locale) return option;
    }
    return shipped.first;
  }

  /// The language a stored setting actually means.
  static LanguageOption resolve(String? code) {
    final chosen = byCode(code);
    return chosen.code == system.code ? ofPlatform() : chosen;
  }
}

/// The catalogue every [tr] call reads.
///
/// A library-level value rather than something carried through the widget
/// tree. Strings are wanted in places that have no `BuildContext` — a menu
/// assembled in a helper, an error raised in `core/` — and threading a context
/// into all of them to reach a value that changes about once a year would be
/// paying every day for something almost nobody does. It is set in one place,
/// by the settings store, and read everywhere.
Localisation _active = const Localisation(
  code: 'en',
  name: 'English',
  entries: {},
);

Localisation get activeLocalisation => _active;

/// Swaps the catalogue.
///
/// Set it through `SettingsStore.setLanguage` in the application: whoever
/// changes the language also has to rebuild the interface, and the store is
/// what everything already listens to. Assigning here directly is for tests.
set activeLocalisation(Localisation value) => _active = value;

/// The user's text for [source].
///
/// [source] is the English sentence, written out in full at the point it is
/// used, so the code reads as what the user sees. Placeholders are named and
/// written `{like_this}`, because a translated sentence puts them in a
/// different order and a positional `%s` cannot survive that.
///
/// ```dart
/// tr('Delete {count} items?', {'count': '12'})
/// ```
String tr(String source, [Map<String, Object?> values = const {}]) {
  var text = _active.lookup(source);
  if (values.isEmpty) return text;

  for (final entry in values.entries) {
    text = text.replaceAll('{${entry.key}}', '${entry.value}');
  }
  return text;
}
