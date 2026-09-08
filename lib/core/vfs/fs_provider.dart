import '../i18n/i18n.dart';
import 'file_entry.dart';
import 'vfs_path.dart';

/// A named starting point offered by a provider — a disk, a bookmark, a server.
class VfsRoot {
  const VfsRoot({
    required this.path,
    required this.label,
    this.subtitle,
    this.iconName,
    this.children = const [],
    this.accelerator,
    this.isVolume = true,
  });

  final VfsPath path;
  final String label;
  final String? subtitle;

  /// Symbolic icon name resolved by the UI, e.g. `drive`, `home`, `server`.
  final String? iconName;

  /// Whether choosing this row means *that volume* or *that folder*.
  ///
  /// **A volume lands where it was last left**, which is what a drive is for:
  /// pressing D: takes you back to the folder you were working in on D:. A
  /// folder lands in the folder, and nowhere else.
  ///
  /// Everything here was a volume until Home stopped going home: on macOS
  /// every path shares the root `/`, so the panel dutifully restored the last
  /// folder it had been in. On Windows the same held for any place under
  /// `C:\`.
  final bool isVolume;

  /// The letter this place answers to while a menu of roots is open.
  ///
  /// **Given here because the caption is translated and the letter is not.**
  /// A menu claims a letter off the first character of the row, which works for
  /// `C:` in any language and fails for every word: a translated caption may
  /// hold no letter of the Latin alphabet at all, and then the row answered to
  /// nothing. Null
  /// leaves the menu to guess from the caption, which is right for a drive.
  final String? accelerator;

  /// Places that belong *under* this one, shown as a submenu wherever the roots
  /// are listed — the desktop, the documents and the downloads under home.
  ///
  /// A root with children is still a place: whatever draws these has to keep it
  /// reachable, because a folder that can only be opened by walking past it is
  /// a folder that has been taken away.
  final List<VfsRoot> children;
}

/// Raised by providers for anything the caller could reasonably show a user.
class VfsException implements Exception {
  VfsException(this.message, {this.path, this.cause});

  final String message;
  final VfsPath? path;
  final Object? cause;

  @override
  String toString() =>
      path == null ? message : '$message (${path!.display})';
}

/// The single abstraction every storage backend implements.
///
/// The local disk is one implementation; FTP, SMB, archives and anything else
/// arrive as plugins that are surfaced through the same interface, so the panels
/// never learn what they are actually talking to.
abstract class FileSystemProvider {
  /// URI scheme this provider is registered under, e.g. `file` or `ftp`.
  String get scheme;

  /// Shown in the connection list and in error messages.
  String get displayName;

  /// False for read-only backends. **Said in advance, not found out.** The
  /// panel dims the keys that cannot work here and the operations refuse
  /// before they start, rather than letting the user press F8 on a commit and
  /// read a refusal from three layers down.
  ///
  /// The plugin declares it per scheme — see `SchemeSpec`.
  bool get isWritable => true;

  /// What the panel draws beside the path while it stands here, named from the
  /// table in `pluginIcon`. Null for a provider that is simply a disk: the
  /// path already says where it is, and an icon on everything is an icon that
  /// says nothing.
  String? get badge => null;

  /// Locations the user can jump to directly. Called whenever the drive bar
  /// is opened, so it must be cheap.
  Future<List<VfsRoot>> roots();

  /// Where a fresh panel opens.
  Future<VfsPath> defaultLocation();

  /// Directory contents, excluding `.` and `..`. Hidden entries are always
  /// returned; filtering them out is the UI's decision.
  Future<List<FileEntry>> list(VfsPath directory);

  /// Metadata for a single entry, or null when it does not exist.
  Future<FileEntry?> stat(VfsPath path);

  /// Streams a file's bytes for reading. [start] and [end] request a byte
  /// range, which is what lets a viewer plugin page through a large file
  /// without pulling all of it across.
  Stream<List<int>> openRead(VfsPath file, {int? start, int? end});

  /// Writes [data] to [file], replacing anything already there.
  ///
  /// [length] is the expected total size when known, for progress reporting.
  /// [modified] is what the source said its date was, for a backend that has to
  /// *record* it rather than let the file system keep it: a member packed into
  /// an archive carries its own timestamp, and without this every file in a new
  /// archive was dated the moment it was packed. Backends where the date is the
  /// disk's business ignore it.
  Future<void> write(
    VfsPath file,
    Stream<List<int>> data, {
    int? length,
    DateTime? modified,
  });

  Future<void> createDirectory(VfsPath directory);

  /// The operation that was writing here has finished.
  ///
  /// Nothing else says so. A write is one file at a time, and a backend that
  /// can only assemble itself as a whole has no way to tell the last file of a
  /// copy from the middle of one — so it either does the whole assembly after
  /// every file, or it never knows when to do it at all.
  ///
  /// **A compressed tarball is the case this exists for.** There is no such
  /// thing as appending to one: adding a file means writing the archive again,
  /// so fifty files would mean fifty rewrites of a growing archive. With this,
  /// members are staged and the archive is written once. It is a *hint about
  /// timing*, never about correctness: anything staged has to survive not being
  /// told, and the panel showing something out of date is the worst it may cost.
  ///
  /// Called after a copy, a move and a delete, on the provider that was written
  /// to. Does nothing by default, which is right for every backend where a file
  /// is finished when its bytes have arrived.
  Future<void> finishWrites(VfsPath where) async {}

  /// Whether this backend can hold a symbolic link at all.
  ///
  /// What it decides is how a link is *copied*: where the answer is yes it is
  /// recreated pointing at the same place, and where it is no the thing it
  /// points at is copied instead. Both are right somewhere — Unix tools keep
  /// the link, Explorer copies the contents — and neither can be done on a
  /// backend that has no such idea, so the destination is asked.
  bool get supportsLinks => false;

  /// Creates a symbolic link at [link] pointing at [target], which is a path in
  /// this backend's own terms and may not exist.
  Future<void> createLink(VfsPath link, String target) async =>
      throw VfsException(tr('This location cannot hold a link'), path: link);

  /// Removes a file, or a directory and everything in it. Irreversible.
  Future<void> delete(VfsPath path);

  /// Whether this backend has a recycle bin at all. Network transports
  /// generally do not, and the UI says so before deleting.
  bool get supportsTrash => false;

  /// Whether *this* entry can go to the recycle bin rather than being
  /// destroyed. Defaults to whatever the backend supports; a backend where a
  /// particular path cannot be binned — one already in the bin, say —
  /// overrides this and says so, because the confirmation the user reads is
  /// built from the answer.
  bool canTrash(VfsPath path) => supportsTrash;

  /// Moves [path] to the platform recycle bin. Returns false when it could not
  /// be done, leaving the caller to decide whether to delete outright.
  Future<bool> trash(VfsPath path) async => false;

  /// Moves all of [paths] to the recycle bin at once, returning the ones that
  /// could not be moved.
  ///
  /// A whole selection is one operation, not a hundred: the platform's recycle
  /// bin is reached through the shell, and asking it once per file spawns a
  /// process per file and makes the desktop announce each one — on macOS that
  /// is a hundred Finder events and a hundred trash sounds for one keypress.
  ///
  /// The default walks [trash] for backends that have no batch of their own,
  /// so overriding it is worth it only where the platform offers one.
  Future<List<VfsPath>> trashAll(List<VfsPath> paths) async {
    final failed = <VfsPath>[];
    for (final path in paths) {
      if (!await trash(path)) failed.add(path);
    }
    return failed;
  }

  /// Renames or moves within this provider.
  Future<void> rename(VfsPath from, VfsPath to);

  /// Optional fast path for copying inside one provider — a server-side copy,
  /// or a native file copy locally. Return false to fall back to a
  /// read-then-write stream transfer.
  Future<bool> copyWithin(VfsPath from, VfsPath to) async => false;

  /// Releases connections. Called when a plugin unloads or the app exits.
  Future<void> dispose() async {}
}
