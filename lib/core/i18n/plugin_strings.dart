/// The words a *plugin* supplies, in the user's language.
///
/// Everything a plugin contributes used to be shown exactly as it was written:
/// its name in the manager, a command's label in a menu, a setting's note, the
/// title of a viewer in "open with". Which made those the one place the
/// application went on speaking English while it was set to Russian.
///
/// **The catalogue is the plugin's, and it is keyed the same way the
/// application's is** — on the English text itself, in `i18n/<code>.json`
/// beside `plugin.json`. So a plugin author writes their strings once, in
/// English, and translating is adding a file; nothing has to be renamed and
/// nothing needs an identifier.
///
/// **The host does the looking up, and that is the decision this settles.** It
/// already draws all of this, it knows which language is on, and — the part
/// that makes it the only workable answer — a *declarative* plugin has no code
/// to run at all, so if the lookup lived in the plugin, half of them could
/// never speak anything. What a Python plugin builds at run time it translates
/// itself, through the same file, with the language it is handed at
/// `initialize`: the host cannot translate a sentence it has never seen.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// Every plugin's catalogue, by plugin id.
///
/// A library-level value for the same reason [tr]'s is: a plugin's name is
/// drawn in places that have no `BuildContext` and no registry to hand, and
/// threading either into all of them to reach something that changes once a
/// year is paying every day for almost nobody.
Map<String, Map<String, String>> _catalogues = {};

/// What [pluginId] calls [source] in the language now in force.
///
/// Falls back to [source], which is the English the plugin was written in —
/// so an untranslated plugin reads exactly as it always did, and a plugin that
/// has translated half its strings shows the other half in English rather than
/// showing a key.
String saidBy(String pluginId, String source) =>
    _catalogues[pluginId]?[source] ?? source;

/// The same, for text that may not be there at all — a description, an author.
String? saidByOrNull(String pluginId, String? source) =>
    source == null ? null : saidBy(pluginId, source);

/// Puts a catalogue in. For the registry, and for tests.
void setPluginStrings(String pluginId, Map<String, String> entries) {
  if (entries.isEmpty) {
    _catalogues.remove(pluginId);
    return;
  }
  _catalogues[pluginId] = entries;
}

/// Forgets everything, which is what a change of language means.
void clearPluginStrings() => _catalogues = {};

/// Whether [pluginId] has anything to say in this language. For a test, and
/// for the manager, which says so.
bool hasPluginStrings(String pluginId) => _catalogues.containsKey(pluginId);

/// Reads `i18n/<code>.json` for one plugin.
///
/// [directory] is the plugin's folder, or its asset path for a bundled one —
/// exactly what `PluginManifest.directory` holds, which is why the caller does
/// not have to know which kind it has.
Future<Map<String, String>> readPluginStrings({
  required String directory,
  required bool isBundled,
  required String code,
}) async {
  // English is the source, so there is nothing to read: the strings in the
  // manifest already are the catalogue.
  if (code == 'en' || code.isEmpty) return const {};
  try {
    final raw = isBundled
        ? utf8.decode(
            (await rootBundle.load('$directory/i18n/$code.json'))
                .buffer
                .asUint8List(),
          )
        : await File('$directory/i18n/$code.json').readAsString();
    final json = jsonDecode(raw);
    if (json is! Map) return const {};
    return {
      for (final entry in json.entries)
        if (entry.key is String &&
            entry.value is String &&
            (entry.value as String).isNotEmpty)
          entry.key as String: entry.value as String,
    };
  } on Object {
    // A plugin with no catalogue for this language is the ordinary case, not a
    // failure: it speaks English, which is what it was written in.
    return const {};
  }
}
