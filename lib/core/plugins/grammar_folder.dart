import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path/path.dart' as p;

import 'grammar.dart';

/// Where a plugin keeps the languages it knows: one file per language, in a
/// folder beside its `plugin.json`.
///
/// **A grammar is a thing in its own right, not a paragraph of a manifest.**
/// Fourteen of them inside one `plugin.json` made the file twenty-five
/// kilobytes of data nobody could read, put every language on the same version
/// number, and meant that adding one was editing the plugin rather than adding
/// a file. One file per language undoes all three: `cpp.json` is C++, it can be
/// replaced on its own, and a language nobody wrote yet is a file that is not
/// there yet.
///
/// **The folder is read, not listed.** Nothing in the manifest names these
/// files, so dropping one in is enough — which is what makes topping the
/// collection up at run time possible at all. A manifest that had to list them
/// would make every new language two edits, and the second one would be the
/// one people forget.
const String kGrammarFolder = 'grammars';

/// What to do with a grammar file that will not parse. The folder is read
/// whenever plugins are discovered, so one bad file must cost its own language
/// and nothing else.
typedef GrammarProblem = void Function(String file, Object error);

/// Reads every grammar in the folder of an installed plugin.
///
/// Missing folder is not a problem: most plugins declare no language at all.
Future<List<SyntaxGrammar>> readGrammarFolder(
  String directory, {
  GrammarProblem? onProblem,
}) async {
  final folder = Directory(p.join(directory, kGrammarFolder));
  if (!await folder.exists()) return const [];

  final files = <File>[
    await for (final child in folder.list(followLinks: false))
      if (child is File && p.extension(child.path).toLowerCase() == '.json')
        child,
  ];
  // By name, so the order does not depend on how the file system feels about
  // it: two machines listing the same folder differently would resolve a
  // clash between two languages differently, which is the kind of difference
  // nobody thinks to look for.
  files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

  final grammars = <SyntaxGrammar>[];
  for (final file in files) {
    try {
      grammars.add(_parse(await file.readAsString(), p.basename(file.path)));
    } on Object catch (e) {
      onProblem?.call(p.basename(file.path), e);
    }
  }
  return grammars;
}

/// The same folder, for an extension that ships inside the application.
///
/// Asked of the asset manifest because a bundle has no directories to list.
Future<List<SyntaxGrammar>> readBundledGrammarFolder(
  String assetDirectory, {
  GrammarProblem? onProblem,
}) async {
  final prefix = '$assetDirectory/$kGrammarFolder/';
  final List<String> assets;
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    assets = manifest
        .listAssets()
        .where((a) => a.startsWith(prefix) && a.toLowerCase().endsWith('.json'))
        .toList()
      ..sort();
  } on Object {
    // No asset manifest in this build; the same as having no grammars.
    return const [];
  }

  final grammars = <SyntaxGrammar>[];
  for (final asset in assets) {
    try {
      grammars.add(_parse(
        await rootBundle.loadString(asset),
        asset.substring(prefix.length),
      ));
    } on Object catch (e) {
      onProblem?.call(asset.substring(prefix.length), e);
    }
  }
  return grammars;
}

/// The languages of one plugin: what is in its folder, and then whatever its
/// manifest still declares inline.
///
/// **The folder wins.** An inline grammar is the older way of saying it and,
/// more to the point, the folder is the half that can be replaced while the
/// application is running — so a file dropped in to fix a language has to beat
/// the copy baked into the manifest, or fixing it would mean editing two
/// places and hoping.
List<SyntaxGrammar> mergeGrammars(
  List<SyntaxGrammar> fromFolder,
  List<SyntaxGrammar> inline,
) {
  final claimed = {for (final grammar in fromFolder) grammar.id};
  return [
    ...fromFolder,
    for (final grammar in inline)
      if (!claimed.contains(grammar.id)) grammar,
  ];
}

/// One file, one language. The id may be left out and taken from the file
/// name, which is what makes `cpp.json` a complete answer on its own.
SyntaxGrammar _parse(String source, String fileName) {
  final json = Map<String, dynamic>.from(jsonDecode(source) as Map);
  if ((json['id'] as String? ?? '').isEmpty) {
    json['id'] = p.basenameWithoutExtension(fileName);
  }
  final grammar = SyntaxGrammar.fromJson(json);
  if (grammar.id.isEmpty) {
    throw FormatException('a grammar with no id', fileName);
  }
  return grammar;
}
