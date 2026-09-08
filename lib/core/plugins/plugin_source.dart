import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../i18n/i18n.dart';
import 'plugin_manifest.dart';
import 'rpc/python_installer.dart' show InstallProgress;

/// One plugin found inside a downloaded repository.
class CatalogueEntry {
  CatalogueEntry({
    required this.manifest,
    required this.sourceDirectory,
    this.updated,
    this.metadataOnly = false,
  });

  final PluginManifest manifest;

  /// When this plugin last changed, from the repository's `index.json`.
  ///
  /// It cannot be worked out here: a branch tarball carries no history, and
  /// every file in one is stamped with the same date. Null when the repository
  /// publishes no index, in which case freshness is simply unknown rather than
  /// guessed at.
  final DateTime? updated;

  /// Where it sits inside the extracted copy, until it is installed.
  final String sourceDirectory;

  /// True for an entry read back from [CatalogueCache], where [sourceDirectory]
  /// holds the manifest and the icon and **not the plugin**.
  ///
  /// It can be listed, searched and compared for a newer version; installing it
  /// means fetching the source for real first. Copying one of these into the
  /// plugins folder would install a description with nothing under it, which is
  /// a worse failure than a wait.
  final bool metadataOnly;

  /// Why this cannot be installed here **now**, or null when it can. Kept as
  /// a sentence so the list can say what is wrong instead of only greying a
  /// row.
  ///
  /// **Asked, never remembered.** Two of the three answers are settled when
  /// the entry is built — the plugin API and the platform list — but the third
  /// is whether there is a Python to run it on, and that changes inside a
  /// session the moment somebody presses Install Python. Held as a field it
  /// went stale: the interpreter arrived, the plugins it unblocked stayed grey,
  /// and the only way to see them was to close the settings and open them
  /// again. A question that has a different answer at two moments has to be a
  /// question and not a value.
  String? blockedBecause(String? runtimeVersion) =>
      PluginSource.blockReason(manifest, runtimeVersion);

  bool isInstallable(String? runtimeVersion) =>
      blockedBecause(runtimeVersion) == null;
}

/// Everything a repository offered, with the address it came from.
class Catalogue {
  Catalogue({
    required this.source,
    required this.entries,
    required this.workingCopy,
  });

  final Uri source;
  final List<CatalogueEntry> entries;

  /// The extracted tree. The caller owns it and must [dispose] when done.
  final Directory workingCopy;

  Future<void> dispose() async {
    if (await workingCopy.exists()) {
      await workingCopy.delete(recursive: true);
    }
  }
}

/// Installs plugins straight out of a git repository.
///
/// It downloads the branch tarball rather than running `git`, because git is
/// not something a file manager may assume is installed — on Windows it
/// usually is not, and on macOS it drags in the Xcode command line tools. One
/// request brings back both the list and the contents, so there is no separate
/// index to keep in step and nothing to prepare on the repository side.
class PluginSource {
  const PluginSource._();

  /// How deep to look for `plugin.json`. Enough for `plugins/<name>/` and for
  /// a repository that is itself one plugin; not so deep that a large tree
  /// turns the search into a walk of everything.
  static const int maxDepth = 3;

  /// Branches tried in order when the address names no particular one.
  static const List<String> defaultBranches = ['main', 'master'];

  /// Turns what a person is likely to paste into a tarball URL.
  ///
  /// Accepts `owner/repo`, a browser URL with or without `.git`, a URL with a
  /// branch in it, and a tarball URL already — which is what makes this work
  /// with hosts we have never heard of.
  static List<Uri> tarballCandidates(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return const [];

    if (trimmed.endsWith('.tar.gz') || trimmed.endsWith('.tgz')) {
      return [Uri.parse(trimmed)];
    }

    // `owner/repo`, the shorthand everyone types.
    final shorthand = RegExp(r'^([\w.-]+)/([\w.-]+)$').firstMatch(trimmed);
    if (shorthand != null) {
      return _githubCandidates(shorthand.group(1)!, shorthand.group(2)!, null);
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return const [];

    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return const [];
    final owner = segments[0];
    final repo = segments[1].replaceAll(RegExp(r'\.git$'), '');

    // `.../tree/<branch>` is what the browser address bar holds when someone
    // is looking at a branch, so honour it rather than guessing.
    String? branch;
    if (segments.length >= 4 && segments[2] == 'tree') {
      branch = segments.sublist(3).join('/');
    }

    if (uri.host.contains('github')) {
      return _githubCandidates(owner, repo, branch);
    }
    if (uri.host.contains('gitlab')) {
      final refs = branch == null ? defaultBranches : [branch];
      return [
        for (final ref in refs)
          Uri.parse('https://${uri.host}/$owner/$repo/-/archive/$ref/'
              '$repo-$ref.tar.gz'),
      ];
    }
    return const [];
  }

  static List<Uri> _githubCandidates(String owner, String repo, String? branch) {
    final refs = branch == null ? defaultBranches : [branch];
    return [
      for (final ref in refs)
        Uri.parse(
          'https://codeload.github.com/$owner/$repo/tar.gz/refs/heads/$ref',
        ),
    ];
  }

  /// Downloads a repository and reports every plugin in it.
  ///
  /// Whether the host can run any of them is not decided here — see
  /// [CatalogueEntry.blockedBecause] for why that is asked at the moment it is
  /// shown rather than fixed at the moment of the fetch.
  static Future<Catalogue> fetch(
    String address, {
    void Function(InstallProgress progress)? onProgress,
  }) async {
    final candidates = tarballCandidates(address);
    if (candidates.isEmpty) {
      throw StateError(
        tr(
          'That does not look like a repository. Use owner/name, the address '
          'from the browser, or a link to a .tar.gz.',
        ),
      );
    }

    final workingCopy =
        await Directory.systemTemp.createTemp('xverb_catalogue');
    try {
      final archive = File(p.join(workingCopy.path, 'repo.tar.gz'));
      final source = await _downloadFirstThatExists(
        candidates,
        archive,
        onProgress,
      );

      onProgress?.call(InstallProgress(tr('Reading the repository…')));
      final tree = Directory(p.join(workingCopy.path, 'tree'));
      await tree.create();
      await _unpack(archive, tree);
      await archive.delete();

      final entries = await _findPlugins(tree, _readIndex(tree));
      entries.sort((a, b) => a.manifest.name.toLowerCase().compareTo(
            b.manifest.name.toLowerCase(),
          ));
      return Catalogue(
        source: source,
        entries: entries,
        workingCopy: workingCopy,
      );
    } on Object {
      if (await workingCopy.exists()) {
        await workingCopy.delete(recursive: true);
      }
      rethrow;
    }
  }

  /// Copies one plugin into [pluginsDirectory], replacing an older copy of the
  /// same plugin. Returns where it landed.
  static Future<String> install(
    CatalogueEntry entry,
    Directory pluginsDirectory, {
    String? runtimeVersion,
  }) async {
    final blocked = entry.blockedBecause(runtimeVersion);
    if (blocked != null) {
      throw StateError(blocked);
    }
    if (entry.metadataOnly) {
      // The caller is meant to fetch the source and install *that* entry. This
      // is here so the mistake is a refusal rather than a folder holding a
      // manifest and nothing else — which would look installed and do nothing.
      throw StateError(
        tr(
          'This is a remembered description, not the plugin. Fetch the source '
          'again before installing it.',
        ),
      );
    }
    await pluginsDirectory.create(recursive: true);

    // Named after the folder it came from, not after the id: the id may hold
    // dots and characters a file system would rather not see.
    final name = p.basename(entry.sourceDirectory);
    final target = Directory(p.join(pluginsDirectory.path, name));
    if (await target.exists()) await target.delete(recursive: true);
    await _copyTree(Directory(entry.sourceDirectory), target);
    return target.path;
  }

  static Future<Uri> _downloadFirstThatExists(
    List<Uri> candidates,
    File destination,
    void Function(InstallProgress)? onProgress,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      Object? lastProblem;
      for (final url in candidates) {
        onProgress?.call(
            InstallProgress(tr('Fetching {host}…', {'host': url.host})));
        try {
          final request = await client.getUrl(url);
          final response = await request.close();
          if (response.statusCode != 200) {
            // A missing branch is a 404, which is why several are tried; only
            // the last failure is worth reporting.
            lastProblem = 'HTTP ${response.statusCode}';
            await response.drain<void>();
            continue;
          }

          final total = response.contentLength;
          var received = 0;
          final sink = destination.openWrite();
          try {
            await for (final chunk in response) {
              received += chunk.length;
              sink.add(chunk);
              onProgress?.call(InstallProgress(
                tr('Downloading…'),
                fraction: total > 0 ? received / total : null,
              ));
            }
          } finally {
            await sink.close();
          }
          return url;
        } on Object catch (e) {
          lastProblem = e;
        }
      }
      throw StateError(tr('Could not download the repository. '
          'Last problem: {error}', {'error': lastProblem}));
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _unpack(File archive, Directory target) async {
    // `--strip-components 1` drops the `<repo>-<ref>/` wrapper every host puts
    // around a tarball, so paths below are the repository's own.
    final result = await Process.run('tar', [
      '-xzf',
      archive.path,
      '-C',
      target.path,
      '--strip-components',
      '1',
    ]);
    if (result.exitCode != 0) {
      throw StateError(tr('The download is not a readable archive: {error}',
          {'error': result.stderr}));
    }
  }

  /// Last-changed dates by plugin id, from `index.json` at the repository
  /// root. A missing or unreadable index is normal — the folders are the
  /// source of truth and the index only adds what they cannot carry.
  static Map<String, DateTime> _readIndex(Directory root) {
    final file = File(p.join(root.path, 'index.json'));
    if (!file.existsSync()) return const {};
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return const {};
      return {
        for (final row in decoded)
          if (row is Map &&
              row['id'] is String &&
              DateTime.tryParse('${row['updated']}') != null)
            row['id'] as String: DateTime.parse('${row['updated']}'),
      };
    } on Object {
      return const {};
    }
  }

  static Future<List<CatalogueEntry>> _findPlugins(
    Directory root,
    Map<String, DateTime> updatedById,
  ) async {
    final found = <CatalogueEntry>[];

    Future<void> walk(Directory directory, int depth) async {
      if (depth > maxDepth) return;

      if (await File(p.join(directory.path, 'plugin.json')).exists()) {
        try {
          final manifest = await PluginManifest.load(directory);
          found.add(CatalogueEntry(
            manifest: manifest,
            sourceDirectory: directory.path,
            updated: updatedById[manifest.id],
          ));
        } on Object {
          // A folder with an unreadable manifest is not a plugin we can offer.
          // Staying quiet beats a list full of things nobody can install.
        }
        // A plugin holds no plugins, so stop rather than descend into it.
        return;
      }

      await for (final child in directory.list(followLinks: false)) {
        if (child is! Directory) continue;
        final name = p.basename(child.path);
        if (name.startsWith('.') || name.startsWith('_')) continue;
        await walk(child, depth + 1);
      }
    }

    await walk(root, 0);
    return found;
  }

  /// Why the host would refuse this plugin, in a sentence, or null.
  ///
  /// Public because the answer is about *this machine now* and has to be asked
  /// again every time it is shown — the machine may have grown an interpreter
  /// since the fetch, or since the last frame, and a plugin remembered as
  /// unrunnable would stay unrunnable on a list that is simply out of date.
  static String? blockReason(PluginManifest manifest, String? runtimeVersion) {
    if (!manifest.isCompatible) {
      return tr('Built for plugin API {theirs}; this app speaks {ours}.',
          {'theirs': manifest.apiVersion, 'ours': kPluginApiVersion});
    }
    if (!manifest.supportsCurrentPlatform()) {
      return tr('Does not list {platform} among the platforms it supports.',
          {'platform': PluginManifest.currentPlatformName()});
    }
    if (manifest.needsPythonRuntime && runtimeVersion == null) {
      return tr('Needs a Python interpreter, and none is set up yet.');
    }
    if (runtimeVersion != null && !manifest.acceptsPython(runtimeVersion)) {
      return tr(
          'Needs Python {needed} or newer; the interpreter in use is {actual}.',
          {'needed': manifest.pythonMin, 'actual': runtimeVersion});
    }
    return null;
  }

  static Future<void> _copyTree(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        await _copyTree(entity, Directory(p.join(to.path, name)));
      } else if (entity is File) {
        await entity.copy(p.join(to.path, name));
      }
    }
  }
}
