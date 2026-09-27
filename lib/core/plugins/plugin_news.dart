import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'catalogue_cache.dart';
import 'plugin_manifest.dart';

/// One plugin as a repository's `index.json` lists it: enough to say that it
/// is there and whether this application could run it, and no more.
class IndexedPlugin {
  const IndexedPlugin({
    required this.id,
    required this.name,
    this.apiVersion = 1,
    this.platforms = const [],
  });

  final String id;
  final String name;
  final int apiVersion;
  final List<String> platforms;

  /// Whether this build could install it: the plugin API level it needs, and
  /// the machines it says it runs on. Offering the news of a plugin that
  /// would then be greyed in the list is offering nothing.
  bool get runsHere =>
      apiVersion >= kPluginApiOldest &&
      apiVersion <= kPluginApiVersion &&
      (platforms.isEmpty ||
          platforms.contains(PluginManifest.currentPlatformName()));

  static List<IndexedPlugin> listIn(Object? decoded) {
    final rows = decoded is Map ? decoded['plugins'] : decoded;
    if (rows is! List) return const [];
    return [
      for (final row in rows)
        if (row is Map && row['id'] is String && (row['id'] as String).isNotEmpty)
          IndexedPlugin(
            id: row['id'] as String,
            name: (row['name'] as String?)?.trim().isNotEmpty == true
                ? row['name'] as String
                : row['id'] as String,
            apiVersion: (row['apiVersion'] as num?)?.toInt() ?? 1,
            platforms: [
              for (final platform in (row['platforms'] as List?) ?? const [])
                if (platform is String) platform,
            ],
          ),
    ];
  }
}

/// What the plugin collection has that it did not have the last time anybody
/// looked — for the remark at start-up that says so.
///
/// **Asked of the repository's `index.json`, one small file**, not of the
/// catalogue the plugin manager builds: that one is a whole repository tarball
/// per source, several megabytes, which is the price of opening the manager and
/// not a price to charge every start of the application. A source that
/// publishes no index — a repository somebody added by hand — is answered from
/// what the manager last saw of it, and not asked at all.
class PluginNews {
  const PluginNews._();

  static const Duration timeout = Duration(seconds: 10);

  /// Where [address]'s `index.json` would be, most likely first. Only GitHub
  /// is known: `owner/repo`, or a github.com address with or without a branch.
  static List<Uri> indexUrls(String address) {
    final trimmed = address.trim().replaceAll(RegExp(r'\.git$'), '');
    String? owner, repo, branch;
    final shorthand = RegExp(r'^([\w.-]+)/([\w.-]+)$').firstMatch(trimmed);
    if (shorthand != null) {
      owner = shorthand.group(1);
      repo = shorthand.group(2);
    } else {
      final uri = Uri.tryParse(trimmed);
      if (uri == null || !uri.host.endsWith('github.com')) return const [];
      final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (parts.length < 2) return const [];
      owner = parts[0];
      repo = parts[1];
      if (parts.length >= 4 && parts[2] == 'tree') branch = parts[3];
    }
    return [
      for (final ref in branch != null ? [branch] : const ['main', 'master'])
        Uri.https('raw.githubusercontent.com', '/$owner/$repo/$ref/index.json'),
    ];
  }

  /// The plugins [address] lists, or null when it could not be asked.
  static Future<List<IndexedPlugin>?> fetchIndex(String address) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      for (final url in indexUrls(address)) {
        try {
          final request = await client.getUrl(url).timeout(timeout);
          request.headers.set(HttpHeaders.userAgentHeader, 'xverb');
          final response = await request.close().timeout(timeout);
          if (response.statusCode != 200) {
            await response.drain<void>();
            continue;
          }
          final body = await response.transform(utf8.decoder).join().timeout(timeout);
          return IndexedPlugin.listIn(jsonDecode(body));
        } on Object {
          continue;
        }
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// What the plugin manager last saw of [address], or null if it never
  /// looked.
  static Future<List<IndexedPlugin>?> remembered(String address) async {
    final CachedCatalogue? cached;
    try {
      cached = await CatalogueCache.read(address);
    } on Object {
      // No support folder, a cache half written: nothing remembered.
      return null;
    }
    if (cached == null) return null;
    return [
      for (final entry in cached.entries)
        IndexedPlugin(
          id: entry.manifest.id,
          name: entry.manifest.name,
          apiVersion: entry.manifest.apiVersion,
          platforms: entry.manifest.platforms,
        ),
    ];
  }

  /// The plugins in [offered] worth telling somebody about: not installed,
  /// not seen before, and able to run here. In the order the source lists
  /// them, each once.
  static List<IndexedPlugin> fresh({
    required Iterable<IndexedPlugin> offered,
    required Set<String> installed,
    required Set<String> known,
  }) {
    final seen = <String>{};
    return [
      for (final plugin in offered)
        if (!installed.contains(plugin.id) &&
            !known.contains(plugin.id) &&
            plugin.runsHere &&
            seen.add(plugin.id))
          plugin,
    ];
  }
}
