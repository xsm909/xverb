import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'plugin_manifest.dart';
import 'plugin_source.dart';

/// What a plugin source offered, remembered between openings of the manager.
///
/// **The plugin manager used to go to the network every time it was opened**,
/// and it downloaded a whole repository tarball per source to do it — so the
/// list arrived late, an update was news only after a wait, and opening the tab
/// on a train showed nothing at all. What it offers has to be cached.
///
/// **The cache is a shallow copy of the repository**: the `plugin.json` of each
/// plugin and its icon file, and nothing else. That shape was chosen over a
/// file of serialised fields for three reasons, and the first is the one that
/// matters:
///
/// - **Reading it is the same code that reads a real one.**
///   `PluginManifest.load` on a folder, exactly as the tarball walk does, so a
///   field added to a manifest tomorrow is in the cache without a line written
///   here. A hand-written serialiser is the thing that goes stale, and it goes
///   stale silently.
/// - The icons come for free, and an icon is the one part of a plugin's
///   description that cannot be reconstructed from text.
/// - It is small. Fifteen manifests and one icon is a few tens of kilobytes
///   against the several megabytes of the tarballs they were read from.
///
/// **What it deliberately does not hold is the code.** An entry read back from
/// here can be listed, searched and compared for a newer version, and it cannot
/// be installed — [CatalogueEntry.metadataOnly] says so, and the manager
/// fetches for real when somebody presses Install. Copying a cached entry into
/// the plugins folder would install a manifest with no plugin under it, which
/// is a worse failure than a wait.
class CatalogueCache {
  const CatalogueCache._();

  /// How long what a source said stays worth showing without asking again.
  ///
  /// Long enough that opening the manager twice in an afternoon costs one
  /// fetch, short enough that "there is an update" is news rather than
  /// history. It is not a promise: the refresh button ignores it, and so does
  /// pressing Install, which fetches whatever the source has right now.
  static const Duration life = Duration(hours: 6);

  /// The folder for [address]. Named by a digest rather than by the address
  /// itself, which may hold slashes, colons and anything else a person pasted.
  static Future<Directory> folderFor(String address) async {
    final support = await getApplicationSupportDirectory();
    final digest = sha1.convert(utf8.encode(address)).toString().substring(0, 16);
    return Directory(p.join(support.path, 'catalogue', digest));
  }

  /// Writes what [catalogue] holds, replacing whatever was there for [address].
  ///
  /// Written whole and then swapped in, so a run that dies halfway through
  /// leaves the previous answer rather than half of this one.
  static Future<void> write(String address, Catalogue catalogue) async {
    final folder = await folderFor(address);
    final building = Directory('${folder.path}.writing');
    if (await building.exists()) await building.delete(recursive: true);
    await building.create(recursive: true);

    final index = <Map<String, dynamic>>[];
    for (final entry in catalogue.entries) {
      final name = p.basename(entry.sourceDirectory);
      final target = Directory(p.join(building.path, name));
      await target.create(recursive: true);

      final manifest = File(p.join(entry.sourceDirectory, 'plugin.json'));
      if (!await manifest.exists()) continue;
      await manifest.copy(p.join(target.path, 'plugin.json'));

      // The icon, when the manifest names a file rather than one of the names
      // the host draws itself. This is the only other thing worth keeping.
      final icon = entry.manifest.iconFile;
      if (icon != null) {
        final from = File(p.join(entry.sourceDirectory, icon));
        if (await from.exists()) await from.copy(p.join(target.path, icon));
      }

      index.add({
        'folder': name,
        'id': entry.manifest.id,
        if (entry.updated != null)
          'updated': entry.updated!.toIso8601String(),
      });
    }

    await File(p.join(building.path, 'cache.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'address': address,
        'source': catalogue.source.toString(),
        'fetchedAt': DateTime.now().toIso8601String(),
        'entries': index,
      }),
    );

    if (await folder.exists()) await folder.delete(recursive: true);
    await building.rename(folder.path);
  }

  /// What was remembered for [address], or null when nothing was.
  ///
  /// Whether a plugin can run here is not part of what is remembered: it is a
  /// fact about *this machine now*, and it is asked at the moment the row is
  /// drawn — see [CatalogueEntry.blockedBecause].
  static Future<CachedCatalogue?> read(String address) async {
    final folder = await folderFor(address);
    final file = File(p.join(folder.path, 'cache.json'));
    if (!await file.exists()) return null;

    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final fetched = DateTime.tryParse(json['fetchedAt'] as String? ?? '');
      if (fetched == null) return null;

      final updates = <String, DateTime>{};
      for (final row in (json['entries'] as List? ?? const [])) {
        final map = row as Map<String, dynamic>;
        final when = DateTime.tryParse(map['updated'] as String? ?? '');
        if (when != null) updates[map['id'] as String? ?? ''] = when;
      }

      final entries = <CatalogueEntry>[];
      await for (final child in folder.list(followLinks: false)) {
        if (child is! Directory) continue;
        try {
          final manifest = await PluginManifest.load(child);
          entries.add(CatalogueEntry(
            manifest: manifest,
            sourceDirectory: child.path,
            updated: updates[manifest.id],
            metadataOnly: true,
          ));
        } on Object {
          // A folder we cannot read is one plugin missing from the list, not a
          // reason to throw the rest of the answer away.
        }
      }
      entries.sort((a, b) =>
          a.manifest.name.toLowerCase().compareTo(b.manifest.name.toLowerCase()));

      return CachedCatalogue(
        address: address,
        fetchedAt: fetched,
        entries: entries,
      );
    } on Object {
      return null;
    }
  }

  /// Forgets [address] — for a source somebody has removed.
  static Future<void> forget(String address) async {
    final folder = await folderFor(address);
    if (await folder.exists()) await folder.delete(recursive: true);
  }
}

/// A catalogue read back from the cache, with when it was true.
class CachedCatalogue {
  const CachedCatalogue({
    required this.address,
    required this.fetchedAt,
    required this.entries,
  });

  final String address;
  final DateTime fetchedAt;
  final List<CatalogueEntry> entries;

  /// Whether it is old enough to be worth asking again. Said as a question
  /// about age rather than a flag, because the answer changes while the tab is
  /// open and nothing should have to be told.
  bool get isStale => DateTime.now().difference(fetchedAt) > CatalogueCache.life;
}
