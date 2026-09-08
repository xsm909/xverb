import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../i18n/i18n.dart';
import 'file_entry.dart';
import 'fs_provider.dart';
import 'trash.dart';
import 'user_folders.dart';
import 'vfs_path.dart';
import 'windows_attributes.dart';
import 'windows_drives.dart';

/// The built-in `file:` provider, backed by `dart:io`.
///
/// This is the only storage backend that ships in the core. Everything else is
/// expected to arrive as a plugin.
class LocalFileSystemProvider extends FileSystemProvider {
  @override
  String get scheme => VfsPath.localScheme;

  @override
  String get displayName => tr('Local disk');

  @override
  Future<List<VfsRoot>> roots() async {
    final roots = <VfsRoot>[];

    if (Platform.isWindows) {
      roots.addAll(await _windowsDrives());
    } else {
      roots.add(VfsRoot(
        path: VfsPath.local('/'),
        label: '/',
        subtitle: tr('Root'),
        iconName: 'drive',
      ));
      // **And everything else that is mounted.**
      //
      // An external disk or a stick plugged in was not in the list, and
      // re-reading the roots was only half of that and the smaller half —
      // nothing on this side
      // of Windows ever looked at the mounted volumes at all, so an external
      // disk was not in the list however often it was asked for. Windows has
      // had its drives since the beginning because a drive letter is
      // unmissable; a mount point had to be gone and looked for.
      roots.addAll(_mountedVolumes());
    }

    final home = _homeDirectory();
    if (home != null) {
      roots.add(VfsRoot(
        path: VfsPath.local(home),
        label: tr('Home'),
        subtitle: home,
        iconName: 'home',
        // H whatever the interface is written in — see [VfsRoot.accelerator].
        accelerator: 'h',
        // Home is a folder, not a volume: it goes home, not to wherever this
        // disk was left.
        isVolume: false,
        // The folders every desktop gives a person, asked of the machine rather
        // than composed out of `$HOME` — see [UserFolders]. No subtitle:
        // these are named by the folder itself, and the path beside it would
        // say the same thing twice.
        children: [
          for (final folder in UserFolders.known())
            VfsRoot(
              path: VfsPath.local(folder.path),
              label: folder.label,
              iconName: 'folder',
              isVolume: false,
            ),
        ],
      ));
    }

    // On mobile the app is sandboxed, so the useful roots are the directories
    // the platform hands us rather than anything resembling a disk.
    if (Platform.isAndroid || Platform.isIOS) {
      final documents = await getApplicationDocumentsDirectory();
      roots.add(VfsRoot(
        path: VfsPath.local(documents.path),
        label: tr('Documents'),
        subtitle: documents.path,
        iconName: 'folder',
        isVolume: false,
      ));
      final temp = await getTemporaryDirectory();
      roots.add(VfsRoot(
        path: VfsPath.local(temp.path),
        label: tr('Temporary'),
        subtitle: temp.path,
        iconName: 'folder',
        isVolume: false,
      ));
      if (Platform.isAndroid) {
        final external = await getExternalStorageDirectory();
        if (external != null) {
          roots.add(VfsRoot(
            path: VfsPath.local(external.path),
            label: tr('External storage'),
            subtitle: external.path,
            iconName: 'drive',
          ));
        }
      }
    }

    return roots;
  }

  @override
  Future<VfsPath> defaultLocation() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final documents = await getApplicationDocumentsDirectory();
      return VfsPath.local(documents.path);
    }
    final home = _homeDirectory();
    if (home != null && Directory(home).existsSync()) {
      return VfsPath.local(home);
    }
    return VfsPath.local(Directory.current.path);
  }

  @override
  Future<List<FileEntry>> list(VfsPath directory) async {
    final dir = Directory(directory.toNativePath());
    if (!await dir.exists()) {
      throw VfsException(tr('Directory does not exist'), path: directory);
    }

    final entries = <FileEntry>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final entry = await _toEntry(entity, directory);
        if (entry != null) entries.add(entry);
      }
    } on FileSystemException catch (e) {
      throw VfsException(e.message, path: directory, cause: e);
    }
    return entries;
  }

  @override
  Future<FileEntry?> stat(VfsPath path) async {
    final native = path.toNativePath();
    final type = await FileSystemEntity.type(native, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;

    // **What it resolves to, not what it is** — the same rule [_toEntry] uses
    // for a listing, and it has to be the same rule. `FileStat.stat` follows
    // the link, so this describes the target. It used to describe the link
    // itself, so a listing showed a symlinked folder as a folder while a copy
    // asked about the same entry and was told "link", planned it as a file, and
    // tried to read a directory:
    //
    //     .plugin_symlinks/window_manager: Cannot open file
    //     (OS Error: Is a directory, errno = 21)
    //
    // Every Flutter project on this machine has a folder of those in it.
    final stat = await FileStat.stat(native);
    var kind = _kindFromType(stat.type);

    String? linkTarget;
    if (type == FileSystemEntityType.link) {
      try {
        linkTarget = await Link(native).target();
      } on FileSystemException {
        linkTarget = null;
      }
      // A link whose target is gone has nothing to describe, so it stays one.
      if (kind == FileKind.unknown) kind = FileKind.link;
    }

    return FileEntry(
      path: path,
      name: p.basename(native),
      kind: kind,
      size: kind == FileKind.file ? stat.size : 0,
      modified: stat.modified,
      isHidden: _isHidden(native),
      linkTarget: linkTarget,
    );
  }

  @override
  Stream<List<int>> openRead(VfsPath file, {int? start, int? end}) =>
      File(file.toNativePath()).openRead(start, end);

  @override
  Future<void> write(
    VfsPath file,
    Stream<List<int>> data, {
    int? length,
    DateTime? modified,
  }) async {
    // [modified] is deliberately not applied: a copy on the local disk has
    // always taken today's date here, and whether it should keep the source's
    // is a question about every copy in the application rather than about this
    // parameter. An archive is the case that cannot shrug — the date is written
    // into the member and nothing else holds it.
    final sink = File(file.toNativePath()).openWrite();
    try {
      await sink.addStream(data);
    } finally {
      await sink.close();
    }
  }

  /// **Everywhere but Windows.** On Unix a link is an ordinary thing to make and
  /// every tool that copies keeps it, so a copied tree stays the tree it was —
  /// and, more to the point, a link pointing back at its own folder is copied
  /// rather than walked forever.
  ///
  /// On Windows making one needs Developer Mode or an administrator, so a copy
  /// of a folder holding a few would report a failure for each of them on most
  /// machines. There the contents are copied instead, which is what Explorer
  /// does with a junction and what anybody copying a folder there expects.
  @override
  bool get supportsLinks => !Platform.isWindows;

  @override
  Future<void> createLink(VfsPath link, String target) async {
    await Link(link.toNativePath()).create(target);
  }

  @override
  Future<void> createDirectory(VfsPath directory) async {
    final dir = Directory(directory.toNativePath());
    if (await dir.exists()) {
      throw VfsException(tr('Already exists'), path: directory);
    }
    await dir.create(recursive: true);
  }

  @override
  Future<void> delete(VfsPath path) async {
    final native = path.toNativePath();
    final type = await FileSystemEntity.type(native, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(native).delete(recursive: true);
      case FileSystemEntityType.link:
        await Link(native).delete();
      case FileSystemEntityType.notFound:
        throw VfsException(tr('Does not exist'), path: path);
      default:
        await File(native).delete();
    }
  }

  @override
  bool get supportsTrash => Trash.isSupported;

  @override
  bool canTrash(VfsPath path) {
    if (!Trash.isSupported) return false;
    // Already in the bin: there is nowhere left to move it to, and emptying
    // the bin from the panel is an ordinary thing to want to do.
    try {
      return !Trash.isInside(path.toNativePath());
    } on Object {
      return true;
    }
  }

  @override
  Future<bool> trash(VfsPath path) async {
    if (!Trash.isSupported) return false;
    final failed = await Trash.send([path.toNativePath()]);
    return failed.isEmpty;
  }

  @override
  Future<List<VfsPath>> trashAll(List<VfsPath> paths) async {
    if (paths.isEmpty) return const [];
    if (!Trash.isSupported) return List.of(paths);

    // One shell call for the lot. [Trash.send] answers with the native paths it
    // could not move, which are matched back to what was asked for rather than
    // re-parsed — the shell may hand back a path spelled differently from the
    // one it was given.
    final byNative = {for (final path in paths) path.toNativePath(): path};
    final failed = await Trash.send(byNative.keys.toList());
    return [for (final native in failed) ?byNative[native]];
  }

  @override
  Future<void> rename(VfsPath from, VfsPath to) async {
    final source = from.toNativePath();
    final target = to.toNativePath();
    final type = await FileSystemEntity.type(source, followLinks: false);
    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(source).rename(target);
      } else {
        await File(source).rename(target);
      }
    } on FileSystemException catch (e) {
      throw VfsException(e.message, path: from, cause: e);
    }
  }

  @override
  Future<bool> copyWithin(VfsPath from, VfsPath to) async {
    // Only files take the fast path; directories are walked by FileOperations
    // so that progress stays per-file.
    final type = await FileSystemEntity.type(from.toNativePath(),
        followLinks: false);
    if (type != FileSystemEntityType.file) return false;
    await File(from.toNativePath()).copy(to.toNativePath());
    return true;
  }

  /// Reads the drive table instead of probing it. Probing with `existsSync`
  /// blocks on disconnected network and empty optical drives, which is enough
  /// to freeze whatever is waiting for the list.
  /// The disks mounted on this machine, on the systems that mount them into
  /// the one tree.
  ///
  /// **macOS puts them in `/Volumes`**, and one of them is the boot disk under
  /// its own name — a symlink to `/`, which is already offered above as *Root*.
  /// Offering it twice would be offering the same disk under two names, so the
  /// one that resolves to the root is left out.
  ///
  /// **Linux has no single answer**, so this looks in the three places the
  /// desktops actually use: `/media/<user>` and `/run/media/<user>`, which only
  /// exist while something is mounted, and `/mnt`, which is where people mount
  /// things by hand. A folder somebody made under `/mnt` and never mounted
  /// anything on is offered too; it is a folder that opens, and telling it from
  /// a mount point means comparing device numbers Dart does not expose.
  ///
  /// Read fresh on every call, which is what makes the refresh in the drive
  /// menu worth anything.
  List<VfsRoot> _mountedVolumes() {
    final places = mountPlaces ??
        <String>[
          if (Platform.isMacOS) '/Volumes',
          if (Platform.isLinux) ...[
            '/media/${_userName()}',
            '/run/media/${_userName()}',
            '/media',
            '/mnt',
          ],
        ];

    final roots = <VfsRoot>[];
    final seen = <String>{};
    for (final place in places) {
      final directory = Directory(place);
      if (!directory.existsSync()) continue;
      final List<FileSystemEntity> entries;
      try {
        entries = directory.listSync(followLinks: false);
      } on Object {
        // A place we are not allowed to read is a place with nothing in it as
        // far as the drive list is concerned.
        continue;
      }
      entries.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(
            p.basename(b.path).toLowerCase(),
          ));

      for (final entry in entries) {
        final name = p.basename(entry.path);
        // `.DS_Store`, `.Trashes`, and whatever else the system leaves lying
        // about in a mount directory.
        if (name.startsWith('.')) continue;
        if (!seen.add(name)) continue;

        // The boot disk under its own name. It is already up there as `/`.
        String resolved;
        try {
          resolved = entry.resolveSymbolicLinksSync();
        } on Object {
          // A mount that has gone away between the listing and now, or one this
          // user cannot follow. Neither is a disk to offer.
          continue;
        }
        if (resolved == '/') continue;

        roots.add(VfsRoot(
          path: VfsPath.local(entry.path),
          label: name,
          subtitle: entry.path,
          iconName: 'drive',
        ));
      }
    }
    return roots;
  }

  /// Where to look for mounted disks, when a test wants to say.
  ///
  /// Null means the real places for this machine. A test cannot use those: it
  /// would be asserting about whatever the person running it happens to have
  /// plugged in.
  @visibleForTesting
  List<String>? mountPlaces;

  /// Who is logged in, for the two Linux paths that are named after them.
  String _userName() =>
      Platform.environment['USER'] ??
      Platform.environment['LOGNAME'] ??
      p.basename(_homeDirectory() ?? '');

  Future<List<VfsRoot>> _windowsDrives() async {
    return [
      for (final drive in WindowsDrives.list())
        VfsRoot(
          path: VfsPath.local(drive.root),
          label: '${drive.letter}:',
          subtitle: drive.description,
          iconName: switch (drive.kind) {
            WindowsDriveKind.network => 'network',
            WindowsDriveKind.optical => 'optical',
            WindowsDriveKind.removable => 'removable',
            _ => 'drive',
          },
        ),
    ];
  }

  String? _homeDirectory() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final profile = env['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) return profile;
      final drive = env['HOMEDRIVE'];
      final path = env['HOMEPATH'];
      if (drive != null && path != null) return '$drive$path';
      return null;
    }
    return env['HOME'];
  }

  Future<FileEntry?> _toEntry(FileSystemEntity entity, VfsPath directory) async {
    final name = p.basename(entity.path);
    FileStat stat;
    try {
      stat = await entity.stat();
    } on FileSystemException {
      // Entries can vanish between the listing and the stat, and some are
      // unreadable. Showing one with unknown metadata beats dropping it
      // silently.
      //
      // The attribute is still worth asking for — hidden is a thing this can
      // know even when nothing else about the entry could be read.
      return FileEntry(
        path: directory.child(name),
        name: name,
        kind: FileKind.unknown,
        isHidden: _isHidden(entity.path),
      );
    }

    String? linkTarget;
    var kind = _kindFromType(stat.type);
    if (entity is Link) {
      try {
        linkTarget = await entity.target();
      } on FileSystemException {
        linkTarget = null;
      }
      // `stat` follows the link, so `kind` already describes what it points at
      // — and that is what Enter should act on. A symlinked directory has to
      // be a directory here, or the panel hands it to the desktop shell and a
      // native window opens instead of the folder being browsed. macOS relies
      // on this for `/Volumes` and for `/etc`, `/tmp` and `/var` at the root.
      //
      // A link whose target is gone has nothing to describe, so it stays one.
      if (kind == FileKind.unknown) kind = FileKind.link;

      // A folder-shaped door that cannot be opened is not shown at all — not
      // even with hidden files switched on. `C:\Documents and Settings` is the
      // one this came from: a junction to `C:\Users` that denies everyone the
      // right to list it *or* to read where it points, so it cannot be entered,
      // measured, copied, or asked about. There is nothing to be done with the
      // row, and behind it is a folder the user already has. Windows keeps a set
      // of these for software written before Vista, one lot at the root of the
      // drive and one in every profile.
      //
      // Both conditions, and neither alone: the attributes have to call it a
      // directory link, and reading it has to have actually failed. A junction
      // of one's own making answers, and stays. An ordinary folder that only
      // refuses to be *listed* stays too — that one is worth seeing, and says
      // so when it is opened.
      if (linkTarget == null && WindowsAttributes.isDirectoryLink(entity.path)) {
        return null;
      }
    }

    return FileEntry(
      path: directory.child(name),
      name: name,
      kind: kind,
      size: kind == FileKind.file ? stat.size : 0,
      modified: stat.modified,
      isHidden: _isHidden(entity.path),
      linkTarget: linkTarget,
    );
  }

  static FileKind _kindFromType(FileSystemEntityType type) => switch (type) {
        FileSystemEntityType.directory => FileKind.directory,
        FileSystemEntityType.file => FileKind.file,
        FileSystemEntityType.link => FileKind.link,
        _ => FileKind.unknown,
      };

  /// Hidden means two different things on the two kinds of platform, and this
  /// takes both: the attribute bit on Windows, and a leading dot everywhere
  /// else. Both, on Windows — a `.env` copied over from a Unix machine carries
  /// no attribute, and still reads as a file meant to be out of the way.
  static bool _isHidden(String nativePath) =>
      WindowsAttributes.isHidden(nativePath) ||
      _isHiddenName(p.basename(nativePath));

  static bool _isHiddenName(String name) => name.startsWith('.');
}
