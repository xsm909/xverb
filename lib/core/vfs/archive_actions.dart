import 'file_entry.dart';
import 'vfs_path.dart';

/// The names a pack and an unpack land on.
///
/// Two decisions, both small, both easy to get subtly wrong, and neither one
/// needing a widget or a plugin to make: what to call a new archive, and what
/// to call the folder an archive is unpacked into. They live here so the
/// context menu can ask them and a test can check them.

/// What to suggest calling a new archive of [targets], made in [directory].
///
/// One thing packed keeps its own name — `photos/` becomes `photos.zip`, and
/// `notes.txt` becomes `notes.zip` rather than `notes.txt.zip`, because the
/// extension of what went in says nothing about the box it went into. Several
/// things have no name of their own, so they take the folder's: packing the
/// whole of `2026-08/` gives `2026-08.zip`, which is what the folder was
/// called and what it will be recognised by.
String suggestedArchiveName(
  List<FileEntry> targets, {
  required VfsPath directory,
  required String extension,
}) {
  final stem = targets.length == 1
      ? (targets.single.isDirectory ? targets.single.name : targets.single.baseName)
      : directory.name;
  final safe = stem.trim().isEmpty ? 'archive' : stem.trim();
  return extension.isEmpty ? safe : '$safe.$extension';
}

/// What to call the folder [archive] is unpacked into.
///
/// The archive's name without its extension — and without a second one where
/// the second is part of the same archive: `logs.tar.gz` unpacks into `logs`,
/// not into `logs.tar`, because there is no `logs.tar` at the end of it. Only
/// `.tar` is treated that way, because it is the only extension that is
/// routinely wrapped in another.
String unpackFolderName(FileEntry archive) {
  var stem = archive.baseName;
  if (stem.toLowerCase().endsWith('.tar') && stem.length > 4) {
    stem = stem.substring(0, stem.length - 4);
  }
  return stem.trim().isEmpty ? archive.name : stem;
}

/// The extension a name ends in, for deciding which archive it is.
///
/// [FileEntry.extensionOf] with one thing added: a `.tar` in front of the
/// compression is part of the same extension, so `logs.tar.gz` answers `gz` and
/// not something that would send it to the wrong plugin. It answers the same
/// question the panel answers about a file on disk, on a name being typed.
String archiveExtensionOf(String name) => FileEntry.extensionOf(name);

/// [name] with its archive extension replaced by [extension].
///
/// What picking a kind in the pack dialog does. The folder and the stem are
/// kept, and **a `.tar` before the compression goes with it**: choosing xz for
/// `logs.tar.gz` gives `logs.txz`, where replacing only the last extension
/// would have given `logs.tar.txz` — a name saying the file is a tar inside an
/// xz inside a tar.
String withArchiveExtension(String name, String extension) {
  var stem = name;
  final dot = stem.lastIndexOf('.');
  final slash = stem.lastIndexOf(RegExp(r'[\\/]'));
  if (dot > slash + 1) stem = stem.substring(0, dot);
  if (stem.toLowerCase().endsWith('.tar') && stem.length > 4) {
    stem = stem.substring(0, stem.length - 4);
  }
  return extension.isEmpty ? stem : '$stem.$extension';
}

/// Where files go when they are packed into [archive], served under [scheme].
///
/// The archive as a folder — the same location Enter on it would reach — so a
/// pack is the ordinary copy the application already performs, with the
/// progress, the collisions and the cancellation that come with it.
VfsPath packTarget(VfsPath archive, String scheme) =>
    VfsPath.insideArchive(archive, scheme);
