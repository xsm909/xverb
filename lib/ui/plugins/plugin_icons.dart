import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/plugins/plugin_manifest.dart';
import '../viewer/diff_syntax.dart';
import '../picture_filter.dart';

/// The small set of icons a plugin may name, and the shelves they sit on.
///
/// One table for the whole app: the plugin manager, the title bar and the
/// Tools menu all draw the same plugin, and three tables meant the same
/// extension could be three different pictures depending on where it was
/// being looked at.

/// Names a plugin may use, mapped to what this build can draw.
///
/// Anything unknown falls back to a neutral mark rather than to nothing, so a
/// newer plugin still gets an icon on an older app.
IconData pluginIcon(String? name) => switch (name) {
      'memory' => Icons.memory,
      'cloud' => Icons.cloud_outlined,
      'archive' => Icons.inventory_2_outlined,
      'view' => Icons.visibility_outlined,
      'image' => Icons.image_outlined,
      'table' => Icons.table_chart_outlined,
      'text' => Icons.notes_outlined,
      'code' => Icons.code,
      'terminal' => Icons.terminal,
      'folder' => Icons.folder_outlined,
      'info' => Icons.info_outline,
      'chart' => Icons.insights_outlined,
      'compare' => Icons.compare_arrows,
      'history' => Icons.history,
      // The sand runs, and what it runs to is a moment that has been: the
      // button that walks a panel into a commit.
      'hourglass' => Icons.hourglass_bottom,
      'lock' => Icons.lock_outline,
      'copy' => Icons.copy,
      'refresh' => Icons.refresh,
      'search' => Icons.search,
      // Between here and somewhere else. Down is what arrives, up is what
      // leaves, and the pair of them is a repository being caught up with.
      'download' => Icons.arrow_downward,
      'upload' => Icons.arrow_upward,
      'sync' => Icons.sync,
      // Put aside, and written down. A pocket and a pencil, which is what a
      // stash and a commit are.
      'aside' => Icons.inventory_outlined,
      'write' => Icons.edit_note,
      // What happened to a file. Named rather than drawn as words, because a
      // column of "changed / changed / added" is a column of reading where a
      // column of marks is a column of glancing.
      'added' => Icons.add,
      'changed' => Icons.edit_outlined,
      'deleted' => Icons.remove,
      'renamed' => Icons.subdirectory_arrow_right,
      'copied' => Icons.copy_all_outlined,
      'untracked' => Icons.help_outline,
      'staged' => Icons.check,
      'conflict' => Icons.warning_amber_outlined,
      _ => Icons.extension_outlined,
    };

/// The colour an icon carries by what it *means*, or null to take the row's.
///
/// The plugin names the thing and the host decides what it looks like, here as
/// everywhere — and green and red are the one exception the palette allows,
/// for the same reason the diff has them: **the two colours are the meaning**.
/// They come from the same place the diff's do, so a file marked added and its
/// added lines are the same green.
Color? pluginIconColour(String? name, DiffColours diff, Color plain) =>
    switch (name) {
      'added' || 'untracked' => diff.added,
      'deleted' => diff.removed,
      'conflict' => diff.removed,
      'staged' => diff.added,
      _ => null,
    };

/// A shelf's own mark, so a list of categories is not five identical rows.
IconData pluginCategoryIcon(String category) => switch (category.toLowerCase()) {
      'tools' => Icons.build_outlined,
      'viewers' => Icons.visibility_outlined,
      'transports' => Icons.cloud_outlined,
      'archives' => Icons.inventory_2_outlined,
      'appearance' => Icons.palette_outlined,
      'development' => Icons.code,
      _ => Icons.category_outlined,
    };

/// What a plugin looks like when it named no icon of its own.
///
/// Inferred from what it contributes, most specific first. Containers before
/// schemes — an archive plugin serves a scheme too, and "opens archives" is
/// the more useful thing to say about it than "talks to something over a
/// network", which is what a cloud reads as.
IconData pluginManifestIcon(PluginManifest manifest) {
  // A manifest that names a *file* is answered by drawing the file, and the
  // fallback here has to skip it rather than look `icon.png` up in the table of
  // names and hand back whatever that misses to. See [PluginManifest.iconFile].
  final named = manifest.iconFile == null ? manifest.icon : null;
  if (named != null && named.isNotEmpty) return pluginIcon(named);

  if (manifest.containers.isNotEmpty) return Icons.inventory_2_outlined;
  if (manifest.schemes.isNotEmpty) return Icons.cloud_outlined;
  if (manifest.viewers.isNotEmpty) return Icons.visibility_outlined;
  if (manifest.commands.isNotEmpty) return Icons.bolt_outlined;
  return Icons.extension_outlined;
}

/// The plugin's own picture where it ships one, and the host's shape where it
/// does not.
///
/// **The picture is never fetched.** It sits beside the manifest wherever the
/// manifest came from — an installed folder, the app bundle, the repository
/// just downloaded, or the catalogue cache — so the one case that would need
/// the network is the one case that has already been through it.
///
/// A picture that will not load falls back to the shape rather than to a broken
/// image: a plugin is described by what it does, and the drawing is a nicety.
Widget pluginArtwork(PluginManifest manifest, {required double size}) {
  final file = manifest.iconFile;
  final fallback = Icon(pluginManifestIcon(manifest), size: size * 0.56);
  if (file == null) return fallback;

  final where = '${manifest.directory}/$file';

  // A bundled extension's "directory" is an asset path, not a place on the
  // disk. Told apart by the manifest, which knows which it is.
  if (manifest.isBundled) {
    return Image.asset(
      where,
      width: size,
      height: size,
      fit: BoxFit.cover,
      filterQuality: pictureSmoothing,
      errorBuilder: (_, _, _) => fallback,
    );
  }
  return Image.file(
    File(where),
    width: size,
    height: size,
    fit: BoxFit.cover,
    filterQuality: pictureSmoothing,
    // Cheaper than it looks: the same file is asked for once per row and the
    // image cache answers the rest.
    errorBuilder: (_, _, _) => fallback,
  );
}
