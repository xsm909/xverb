/// What a plugin says has changed in it, version by version.
///
/// **A file beside the manifest, not a field in it.** `CHANGES.md` is read by
/// people as often as by the host — on GitHub, in the folder, in a pull
/// request — and a list of sentences inside JSON is a list nobody keeps. The
/// catalogue cache copies only `plugin.json` and the icon, so a plugin that is
/// not installed has no changes to show, which is right: what it *is* comes
/// from the catalogue, and what changed in it is a question about the copy on
/// this machine.
///
/// The shape is the one a person would write anyway:
///
///     ## 0.4.1 — 2026-09-19
///
///     - Speaks the application's eleven languages.
///
/// A second-level heading opens a version: its first word is the version, and
/// whatever follows a dash is the date. Every bullet under it is one change; a
/// line that is not a bullet carries on the one above it. Anything before the
/// first heading — a title, a sentence about the file — is not a change and is
/// not shown.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'plugin_manifest.dart';

/// One version's worth of changes, newest first in any list of them.
class PluginChange {
  const PluginChange({required this.version, this.date, this.notes = const []});

  final String version;

  /// As the file wrote it. Not parsed: nothing here sorts or compares by it,
  /// and a date re-printed by the host would be a date in a different format
  /// from the one beside it on GitHub.
  final String? date;

  final List<String> notes;
}

/// The file's name, beside `plugin.json`.
const kPluginChangesFile = 'CHANGES.md';

/// Reads [text] as a list of versions, in the order the file gives them.
///
/// The order is the file's: newest first is the convention, and a file that
/// breaks it is shown as written rather than reordered by a guess at what its
/// version numbers mean.
List<PluginChange> parsePluginChanges(String text) {
  final changes = <PluginChange>[];
  String? version;
  String? date;
  var notes = <String>[];

  void close() {
    final open = version;
    if (open != null) {
      changes.add(PluginChange(version: open, date: date, notes: notes));
    }
    version = null;
    date = null;
    notes = <String>[];
  }

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('## ')) {
      close();
      final heading = line.substring(3).trim();
      // "0.4.1 — 2026-09-19", "0.4.1 - 2026-09-19", "0.4.1 (2026-09-19)", or
      // the version alone.
      final match = RegExp(
        r'^v?(\S+)\s*(?:[—–-]\s*|\()?([^)]*)\)?$',
      ).firstMatch(heading);
      version = match?.group(1) ?? heading;
      final rest = match?.group(2)?.trim() ?? '';
      date = rest.isEmpty ? null : rest;
      continue;
    }
    if (version == null || line.isEmpty) continue;
    final bullet = RegExp(r'^[-*+]\s+').firstMatch(line);
    if (bullet != null) {
      notes.add(line.substring(bullet.end));
    } else if (notes.isEmpty) {
      notes.add(line);
    } else {
      notes[notes.length - 1] = '${notes.last} $line';
    }
  }
  close();
  return changes;
}

/// The changes [manifest]'s plugin ships, in the language [code] where it has
/// written them in that language, and in English otherwise.
///
/// A translation lives where the plugin's other words do, in `i18n/`, as
/// `CHANGES.<code>.md`. None is the ordinary case, and so is no file at all:
/// both come back as an empty list rather than a failure, because a plugin that
/// never wrote its history down is not broken.
Future<List<PluginChange>> readPluginChanges(
  PluginManifest manifest, {
  String code = 'en',
}) async {
  final candidates = [
    if (code.isNotEmpty && code != 'en') 'i18n/CHANGES.$code.md',
    kPluginChangesFile,
  ];
  for (final name in candidates) {
    final text = await _read(manifest, name);
    if (text != null) return parsePluginChanges(text);
  }
  return const [];
}

Future<String?> _read(PluginManifest manifest, String name) async {
  try {
    if (manifest.isBundled) {
      final data = await rootBundle.load('${manifest.directory}/$name');
      return utf8.decode(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    final file = File('${manifest.directory}${Platform.pathSeparator}$name');
    if (!await file.exists()) return null;
    return await file.readAsString();
  } on Object {
    return null;
  }
}
