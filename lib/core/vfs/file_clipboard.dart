import 'package:flutter/foundation.dart';

import '../platform/file_transfer_channel.dart';
import 'vfs_path.dart';

/// What came off the clipboard when it was asked for files.
class FileClipboardContents {
  const FileClipboardContents({
    required this.paths,
    required this.intent,
    required this.fromHere,
  });

  final List<VfsPath> paths;
  final TransferIntent intent;

  /// Whether this is our own copy or cut coming back, rather than something
  /// Explorer or Finder put there. It decides two things: that a cut is a cut
  /// at all on macOS, where the pasteboard cannot carry one, and that the
  /// locations may be virtual — a file on a server has no path on this disk,
  /// and only the application that put it there knows what it was.
  final bool fromHere;
}

/// The file clipboard: Ctrl+C, Ctrl+X and the half of Ctrl+V that is about
/// files rather than text.
///
/// **Two clipboards kept in step, and the desktop's is the one that wins.**
/// What is remembered here is the selection as the panels know it — locations
/// in the virtual file system, which may be on a server or inside an archive.
/// What goes to the desktop is the part of that which exists as files on the
/// disk. When both have something to say, the desktop is asked first: if its
/// serial still matches the one we were given when we wrote, the clipboard is
/// still ours and the richer record stands. If it has moved on, somebody else
/// has copied something since, and theirs is what a paste must mean.
///
/// A cut marks nothing and deletes nothing. The originals go only when the
/// paste that consumes them has arrived, which is why [consumed] exists and why
/// nothing here ever deletes a file itself.
class FileClipboard extends ChangeNotifier {
  FileClipboard({FileTransferChannel? channel})
    : _channel = channel ?? FileTransferChannel.instance;

  final FileTransferChannel _channel;

  /// Turns locations no desktop can name into files on the local disk, for the
  /// moment they have to leave the application. Set by the UI, because doing it
  /// means showing progress and being cancellable. Null before it is set, and
  /// on a build with no native half, where nothing ever leaves.
  Future<List<String>?> Function(List<VfsPath> paths)? materialiser;

  List<VfsPath> _paths = const [];
  TransferIntent _intent = TransferIntent.copy;

  /// The desktop clipboard's serial at the moment we last wrote to it, or 0
  /// when what we hold never went out there at all.
  int _serial = 0;

  /// What this application last copied or cut, whether or not the desktop was
  /// told about it. Empty is empty.
  List<VfsPath> get paths => _paths;

  TransferIntent get intent => _intent;

  /// Enough to draw a menu with: it says something *was* copied here, not that
  /// the desktop clipboard still holds it. Reading that costs a platform call,
  /// and a menu that has to wait for one reads as a menu that is broken.
  bool get hasOwnFiles => _paths.isNotEmpty;

  Future<void> copy(List<VfsPath> paths) => _put(paths, TransferIntent.copy);

  Future<void> cut(List<VfsPath> paths) => _put(paths, TransferIntent.move);

  Future<void> _put(List<VfsPath> paths, TransferIntent intent) async {
    if (paths.isEmpty) return;
    _paths = List.unmodifiable(paths);
    _intent = intent;
    notifyListeners();

    // Only what the desktop can actually open goes to the desktop. A selection
    // that is partly local and partly not would arrive over there as a quiet
    // half of itself, so it is all or nothing — the rest is materialised on
    // the way out, when there is something to show progress in.
    final native = _localPathsOf(paths);
    _serial = native == null
        ? 0
        : await _channel.writeClipboard(native, intent: intent);
  }

  /// What a paste should act on, or null when there is nothing to paste.
  Future<FileClipboardContents?> read() async {
    final desktop = await _channel.readClipboard();

    if (desktop != null) {
      if (_isOurs(desktop) && _paths.isNotEmpty) {
        return FileClipboardContents(
          paths: _paths,
          intent: _intent,
          fromHere: true,
        );
      }
      return FileClipboardContents(
        paths: desktop.paths.map(VfsPath.local).toList(growable: false),
        intent: desktop.intent,
        fromHere: false,
      );
    }

    if (_paths.isEmpty) return null;

    // The desktop holds no files. If ours went out there and the serial has
    // moved on, somebody has copied something else since — a line of text, an
    // image — and our record is a stale answer to a question the user asked of
    // the clipboard, not of us.
    if (_serial != 0 && await _channel.clipboardSerial() != _serial) {
      _paths = const [];
      notifyListeners();
      return null;
    }

    return FileClipboardContents(
      paths: _paths,
      intent: _intent,
      fromHere: true,
    );
  }

  /// Called by the paste that finished a cut. The originals have gone, so what
  /// is held now points at nothing — and a second Ctrl+V would be a move of
  /// files that are no longer there.
  void consumed() {
    if (_paths.isEmpty) return;
    _paths = const [];
    _serial = 0;
    notifyListeners();
  }

  /// Whether what is on the desktop's clipboard is what this application put
  /// there.
  ///
  /// **Two answers, and the slower one is the one that can be trusted.** The
  /// serial is the fast path: if it still matches the number handed back when
  /// we wrote, nothing has been on the clipboard since. But the serial can move
  /// under a clipboard nobody meant to change — a pasteboard that is being
  /// synced to another device is re-declared by the daemon doing the syncing,
  /// and the number moves without the content moving. That was a cut arriving
  /// as a copy: the files were still ours, and the intention was thrown away
  /// with them.
  ///
  /// So when the serial disagrees, the paths are compared. Same files, in the
  /// same order, means it is still what we wrote, whoever else has touched the
  /// clipboard since.
  bool _isOurs(ClipboardFiles desktop) {
    if (_serial != 0 && desktop.changeCount == _serial) return true;
    final ours = _localPathsOf(_paths);
    if (ours == null || ours.length != desktop.paths.length) return false;
    for (var i = 0; i < ours.length; i++) {
      if (ours[i] != desktop.paths[i]) return false;
    }
    return true;
  }

  /// The files these locations are on the disk, or null when one of them is
  /// not a file on this disk at all.
  static List<String>? _localPathsOf(List<VfsPath> paths) {
    final native = <String>[];
    for (final path in paths) {
      if (path.scheme != VfsPath.localScheme) return null;
      native.add(path.toNativePath());
    }
    return native;
  }

  /// The same list as the desktop would need to see it: local paths as they
  /// are, everything else fetched to a temporary folder first. Null when that
  /// could not be done — no materialiser, or the user cancelled it.
  Future<List<String>?> nativePathsFor(List<VfsPath> paths) async {
    final direct = _localPathsOf(paths);
    if (direct != null) return direct;
    final fetch = materialiser;
    if (fetch == null) return null;
    return fetch(paths);
  }
}
