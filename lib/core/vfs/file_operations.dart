import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../i18n/i18n.dart';
import 'file_entry.dart';
import 'fs_provider.dart';
import 'fs_registry.dart';
import 'vfs_path.dart';

/// What to do when a target file already exists.
enum ConflictAction { overwrite, skip, autoRename, abort }

/// Asked once per collision. Returning null aborts the whole operation.
typedef ConflictResolver = Future<ConflictAction> Function(
  FileEntry source,
  FileEntry existing,
);

/// Live state of a running copy/move/delete, suitable for a progress dialog.
class OperationProgress {
  const OperationProgress({
    required this.currentPath,
    required this.filesDone,
    required this.filesTotal,
    required this.bytesDone,
    required this.bytesTotal,
  });

  final String currentPath;
  final int filesDone;
  final int filesTotal;
  final int bytesDone;
  final int bytesTotal;

  /// Overall completion in 0..1, or null when the total is not yet known.
  double? get fraction {
    if (bytesTotal > 0) return (bytesDone / bytesTotal).clamp(0.0, 1.0);
    if (filesTotal > 0) return (filesDone / filesTotal).clamp(0.0, 1.0);
    return null;
  }
}

typedef ProgressCallback = void Function(OperationProgress progress);

/// Cooperative cancellation shared between the UI and a running operation.
class CancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const OperationCancelled();
  }
}

class OperationCancelled implements Exception {
  const OperationCancelled();

  @override
  String toString() => tr('Operation cancelled');
}

/// One item that did not make it, and why.
///
/// Kept as two fields rather than one sentence because the two are wanted
/// separately: the window shows them joined, and [OperationResult.asJson] hands
/// them over as data — a list of failures worth reading somewhere else is a list
/// worth having the paths out of.
@immutable
class OperationFailure {
  const OperationFailure(this.path, this.reason);

  /// Where it happened, as the path bar would write it. Empty when the failure
  /// is about the operation rather than about one entry.
  final String path;

  /// What went wrong, in the words whatever failed used.
  final String reason;

  /// The one-line form the error window shows.
  String get text => path.isEmpty ? reason : '$path: $reason';

  @override
  String toString() => text;
}

/// Outcome of a finished operation, including per-item failures. Nothing is
/// thrown for individual failures — a batch copy should survive one bad file.
class OperationResult {
  OperationResult({this.operation = 'operation'});

  /// What was being done — `copy`, `move`, `delete`, `trash`. Carried so a
  /// report of what failed says what it was that failed.
  final String operation;

  int succeeded = 0;
  int skipped = 0;
  bool cancelled = false;
  final List<OperationFailure> errors = [];

  bool get hasErrors => errors.isNotEmpty;

  /// Records a failure. [where] may be empty for a failure about the whole
  /// operation rather than about one entry.
  void fail(String where, Object reason) =>
      errors.add(OperationFailure(where, '$reason'));

  /// The whole outcome as JSON, for pasting somewhere it can be read.
  ///
  /// **A list of failures is no use inside a window.** Twenty paths that could
  /// not be copied are the input to whatever is done next — a script, a bug
  /// report, a question to somebody — and reading them off the screen by hand
  /// is how a list of twenty becomes a list of nineteen. Indented, because it
  /// is going to be read by a person as often as by a program.
  ///
  /// [when] is passed in rather than read from the clock, so that what this
  /// returns depends only on what it is given.
  String asJson({DateTime? when}) => const JsonEncoder.withIndent('  ').convert({
        'operation': operation,
        if (when != null) 'when': when.toIso8601String(),
        'succeeded': succeeded,
        'skipped': skipped,
        'failed': errors.length,
        'cancelled': cancelled,
        'errors': [
          for (final failure in errors)
            {
              if (failure.path.isNotEmpty) 'path': failure.path,
              'reason': failure.reason,
            },
        ],
      });
}

/// One planned unit of work: a single file or a single directory to create.
class _WorkItem {
  _WorkItem(
    this.source,
    this.target,
    this.isDirectory,
    this.size, {
    this.modified,
    this.linkTarget,
  });

  final VfsPath source;
  final VfsPath target;
  final bool isDirectory;
  final int size;

  /// What the source said its date was, read while planning the walk and handed
  /// to the write. A backend that records the date rather than keeping it — an
  /// archive — has no other way to know it.
  final DateTime? modified;

  /// Where a link points, when this item *is* a link to be recreated rather
  /// than a file to be read.
  final String? linkTarget;
}

/// Copy, move and delete across any combination of providers.
///
/// Transfers always go through the provider interface, so copying from a local
/// disk to a plugin-supplied FTP location is the same code path as a local
/// copy — only the fast paths differ.
class FileOperations {
  FileOperations(this.registry);

  final FileSystemRegistry registry;

  /// Copies [sources] into [targetDirectory].
  ///
  /// [as] names what the user asked for, for the report at the end. Packing an
  /// archive and unpacking one are both this method underneath — that is the
  /// whole design — but *"copy: 58 failed"* about a compression somebody asked
  /// for is a report describing the machinery instead of the request.
  Future<OperationResult> copy(
    List<VfsPath> sources,
    VfsPath targetDirectory, {
    ConflictResolver? onConflict,
    ProgressCallback? onProgress,
    CancellationToken? token,
    String? as,
  }) =>
      _transfer(
        sources,
        targetDirectory,
        deleteSourceAfter: false,
        onConflict: onConflict,
        onProgress: onProgress,
        token: token,
        as: as,
      );

  /// Copies one entry to an exact path — Shift+F5, "copy under another name".
  ///
  /// The destination is given whole rather than assembled from the source's own
  /// name, because the name is the user's choice: that is the entire point of
  /// the command. Everything else — the conflict question, the progress, the
  /// cancellation — is the ordinary copy.
  Future<OperationResult> copyAs(
    VfsPath source,
    VfsPath target, {
    ConflictResolver? onConflict,
    ProgressCallback? onProgress,
    CancellationToken? token,
    String? as,
  }) {
    final directory = target.parent;
    if (directory == null) {
      final result = OperationResult(operation: as ?? 'copy');
      result.fail(target.display, tr('A root cannot be a destination'));
      return Future.value(result);
    }

    return _transfer(
      [source],
      directory,
      deleteSourceAfter: false,
      underName: target.name,
      onConflict: onConflict,
      onProgress: onProgress,
      token: token,
      as: as,
    );
  }

  Future<OperationResult> move(
    List<VfsPath> sources,
    VfsPath targetDirectory, {
    ConflictResolver? onConflict,
    ProgressCallback? onProgress,
    CancellationToken? token,
  }) =>
      _transfer(
        sources,
        targetDirectory,
        deleteSourceAfter: true,
        onConflict: onConflict,
        onProgress: onProgress,
        token: token,
      );

  /// Deletes [paths]. With [toTrash] the entries go to the platform recycle
  /// bin; a backend without one reports an error rather than quietly deleting
  /// outright, because the difference matters too much to guess at.
  Future<OperationResult> delete(
    List<VfsPath> paths, {
    bool toTrash = false,
    ProgressCallback? onProgress,
    CancellationToken? token,
  }) async {
    if (toTrash) {
      return _trash(paths, onProgress: onProgress, token: token);
    }

    final result = OperationResult(operation: 'delete');
    for (var i = 0; i < paths.length; i++) {
      if (token?.isCancelled ?? false) {
        result.cancelled = true;
        break;
      }
      final path = paths[i];
      onProgress?.call(OperationProgress(
        currentPath: path.display,
        filesDone: i,
        filesTotal: paths.length,
        bytesDone: 0,
        bytesTotal: 0,
      ));
      try {
        await registry.resolve(path).delete(path);
        result.succeeded++;
      } on Object catch (e) {
        result.fail(path.display, e);
      }
    }
    for (final scheme in {for (final path in paths) path.scheme}) {
      final path = paths.firstWhere((p) => p.scheme == scheme);
      await _settle(registry.resolve(path), path, result);
    }
    return result;
  }

  /// Sends everything to the recycle bin, one call per backend rather than one
  /// per file.
  ///
  /// A file at a time is a *process* at a time: the recycle bin is reached
  /// through the platform shell, so a hundred files meant a hundred shell
  /// start-ups — and on macOS a hundred Finder delete events, which the
  /// desktop announces by playing the trash sound a hundred times for one
  /// keypress.
  ///
  /// What that costs is the reporting: progress cannot count files off while a
  /// batch is in flight, and cancelling only takes effect between backends. It
  /// is a fair trade, because the work being watched is now one call instead of
  /// a hundred and is over before there is anything to watch.
  Future<OperationResult> _trash(
    List<VfsPath> paths, {
    ProgressCallback? onProgress,
    CancellationToken? token,
  }) async {
    final result = OperationResult(operation: 'trash');

    // Grouped by scheme in arrival order, so a selection spanning two backends
    // still takes as few calls as there are backends.
    final groups = <String, List<VfsPath>>{};
    for (final path in paths) {
      groups.putIfAbsent(path.scheme, () => []).add(path);
    }

    void refuse(Iterable<VfsPath> paths, String because) {
      for (final path in paths) {
        result.fail(path.display, because);
      }
    }

    var done = 0;
    for (final group in groups.values) {
      if (token?.isCancelled ?? false) {
        result.cancelled = true;
        break;
      }
      onProgress?.call(OperationProgress(
        currentPath: group.first.display,
        filesDone: done,
        filesTotal: paths.length,
        bytesDone: 0,
        bytesTotal: 0,
      ));

      try {
        final provider = registry.resolve(group.first);
        if (!provider.supportsTrash) {
          refuse(group, 'could not be moved to the recycle bin');
        } else {
          // What comes back is what could not be moved, so the rest succeeded
          // — the batch says which files failed, not merely that one did.
          // Counted from the group rather than from the answer's length, so a
          // provider naming something that was never asked for cannot make the
          // tally disagree with the errors listed.
          final failed = (await provider.trashAll(group)).toSet();
          final refused = group.where(failed.contains).toList();
          refuse(refused, 'could not be moved to the recycle bin');
          result.succeeded += group.length - refused.length;
        }
      } on Object catch (e) {
        refuse(group, '$e');
      }
      done += group.length;
    }

    onProgress?.call(OperationProgress(
      currentPath: '',
      filesDone: done,
      filesTotal: paths.length,
      bytesDone: 0,
      bytesTotal: 0,
    ));

    for (final group in groups.values) {
      await _settle(registry.resolve(group.first), group.first, result);
    }
    return result;
  }

  /// Whether every one of [paths] can go to a recycle bin.
  ///
  /// Every one, not any: a mixed set has to be described to the user as the
  /// most destructive thing that is about to happen to it.
  bool canTrash(List<VfsPath> paths) => paths.isNotEmpty &&
      paths.every(
        (path) => registry.lookup(path.scheme)?.canTrash(path) ?? false,
      );

  Future<void> createDirectory(VfsPath parent, String name) async {
    final target = parent.child(name);
    await registry.resolve(target).createDirectory(target);
  }

  Future<void> rename(VfsPath path, String newName) async {
    final parent = path.parent;
    if (parent == null) {
      throw VfsException(tr('Cannot rename a root'), path: path);
    }
    await registry.resolve(path).rename(path, parent.child(newName));
  }

  Future<OperationResult> _transfer(
    List<VfsPath> sources,
    VfsPath targetDirectory, {
    required bool deleteSourceAfter,
    ConflictResolver? onConflict,
    ProgressCallback? onProgress,
    CancellationToken? token,

    /// The name to land under, for a copy of one entry that is being given a
    /// new one. Null means every entry keeps its own, which is what a copy of
    /// several things can possibly mean.
    String? underName,

    /// What the user called this, for the report. Null means it was a copy or a
    /// move and can say so for itself.
    String? as,
  }) async {
    assert(
      underName == null || sources.length == 1,
      'one new name cannot serve several sources',
    );
    final result = OperationResult(
      operation: as ?? (deleteSourceAfter ? 'move' : 'copy'),
    );
    final targetProvider = registry.resolve(targetDirectory);

    if (!targetProvider.isWritable) {
      result.fail('', tr('{where} is read-only',
          {'where': targetProvider.displayName}));
      return result;
    }

    // A whole-directory move inside one provider is a rename; skip the walk.
    //
    // **But only onto a free name.** A rename replaces whatever is already
    // there without a word — that is what the system call does — so a move onto
    // an occupied name went through silently while the same collision on a
    // *copy* raised the dialog. Two roads for one question, and the quiet one
    // was the one that destroyed a file: cut and paste asked nothing at all.
    if (deleteSourceAfter) {
      final remaining = <VfsPath>[];
      for (final source in sources) {
        if (source.scheme != targetDirectory.scheme ||
            source.uri.authority != targetDirectory.uri.authority) {
          remaining.add(source);
          continue;
        }

        final provider = registry.resolve(source);
        var target = targetDirectory.child(underName ?? source.name);
        final existing = await targetProvider.stat(target);

        if (existing != null) {
          final action = await onConflict?.call(
                await provider.stat(source) ??
                    FileEntry(
                      path: source,
                      name: source.name,
                      kind: FileKind.file,
                    ),
                existing,
              ) ??
              ConflictAction.skip;

          switch (action) {
            case ConflictAction.skip:
              result.skipped++;
              continue;
            case ConflictAction.abort:
              result.cancelled = true;
              return result;
            case ConflictAction.autoRename:
              target = await _uniqueName(targetProvider, target);
            case ConflictAction.overwrite:
              // A folder onto a folder is a merge, not a replacement, and a
              // rename cannot merge: it would take the whole of the old folder
              // away along with everything in it that the new one does not
              // have. That one goes the long way round, where the collision is
              // answered file by file.
              if (existing.isDirectory) {
                remaining.add(source);
                continue;
              }
          }
        }

        try {
          await provider.rename(source, target);
          result.succeeded++;
          continue;
        } on Object {
          // Renames fail across volumes; fall back to copy + delete.
        }
        remaining.add(source);
      }
      if (remaining.isEmpty) return result;
      sources = remaining;
    }

    final work = <_WorkItem>[];
    for (final source in sources) {
      if (source.contains(targetDirectory)) {
        result.fail(
            source.display, tr('Cannot copy a directory into itself'));
        continue;
      }
      try {
        await _plan(
          source,
          targetDirectory.child(underName ?? source.name),
          work,
          refuse: (where, reason) => result.fail(where.display, reason),
        );
      } on Object catch (e) {
        result.fail(source.display, e);
      }
    }

    final bytesTotal = work
        .where((item) => !item.isDirectory)
        .fold<int>(0, (sum, item) => sum + item.size);
    final filesTotal = work.where((item) => !item.isDirectory).length;
    var bytesDone = 0;
    var filesDone = 0;

    for (final item in work) {
      if (token?.isCancelled ?? false) {
        result.cancelled = true;
        break;
      }

      onProgress?.call(OperationProgress(
        currentPath: item.source.display,
        filesDone: filesDone,
        filesTotal: filesTotal,
        bytesDone: bytesDone,
        bytesTotal: bytesTotal,
      ));

      try {
        if (item.isDirectory) {
          await _ensureDirectory(item.target);
          continue;
        }

        final target = await _resolveConflict(item, onConflict, result);
        if (target == null) {
          if (result.cancelled) break;
          continue;
        }

        if (item.linkTarget != null) {
          await _copyLink(item, target);
          filesDone++;
          result.succeeded++;
          continue;
        }

        final startBytes = bytesDone;
        await _copyFile(
          item.source,
          target,
          length: item.size,
          modified: item.modified,
          token: token,
          onBytes: (transferred) {
            bytesDone = startBytes + transferred;
            onProgress?.call(OperationProgress(
              currentPath: item.source.display,
              filesDone: filesDone,
              filesTotal: filesTotal,
              bytesDone: bytesDone,
              bytesTotal: bytesTotal,
            ));
          },
        );
        bytesDone = startBytes + item.size;
        filesDone++;
        result.succeeded++;
      } on OperationCancelled {
        result.cancelled = true;
        break;
      } on Object catch (e) {
        result.fail(item.source.display, e);
      }
    }

    // Everything that was going to be written has been. A backend that stages
    // what it is given — a compressed tarball, which cannot be appended to —
    // writes itself out here rather than after every single file.
    await _settle(targetProvider, targetDirectory, result);

    // Sources are removed only once every file landed, so a cancelled or
    // partially failed move never destroys data that was not copied.
    if (deleteSourceAfter && !result.cancelled && !result.hasErrors) {
      for (final source in sources) {
        try {
          await registry.resolve(source).delete(source);
        } on Object catch (e) {
          result.fail(source.display, e);
        }
      }
    }

    return result;
  }

  /// How deep a walk may go before it is called a loop.
  ///
  /// A symlinked folder is walked as the folder it points at, which is what
  /// makes a copy of a Flutter project work — but a link that points at one of
  /// its own ancestors then has no end, and `/Volumes/Macintosh HD -> /` is on
  /// every Mac. Nothing here can tell a loop from a deep tree without resolving
  /// every path, which not every backend can do, so the walk is bounded instead
  /// and says where it stopped. Windows cannot hold a path this deep at all, and
  /// no real tree on any platform comes close.
  static const int maxDepth = 64;

  /// Tells a backend the writing is over, and never lets that be the failure.
  ///
  /// Anything staged has to survive not being told — this is about *when* a
  /// backend assembles itself, not whether it may — so a refusal here is
  /// recorded beside the real work and does not become the outcome of it.
  Future<void> _settle(
    FileSystemProvider provider,
    VfsPath where,
    OperationResult result,
  ) async {
    try {
      await provider.finishWrites(where);
    } on Object catch (e) {
      result.fail(where.display, e);
    }
  }

  /// Walks [source] and appends the files and directories that make it up.
  Future<void> _plan(
    VfsPath source,
    VfsPath target,
    List<_WorkItem> work, {
    int depth = 0,

    /// Where a branch that cannot be walked is reported. The branch is dropped
    /// and the rest of the tree still copies: one strange link in a project
    /// folder must not cost the whole copy.
    void Function(VfsPath where, Object reason)? refuse,
  }) async {
    final provider = registry.resolve(source);
    final entry = await provider.stat(source);
    if (entry == null) {
      throw VfsException(tr('Does not exist'), path: source);
    }

    // **A link is copied as a link**, where the destination can hold one. Not a
    // nicety: following it means a link pointing back at its own folder is
    // walked until something breaks, and every Mac has `/Volumes/Macintosh HD`
    // pointing at `/`. Where the destination cannot hold one — Windows without
    // Developer Mode, a transport, an archive — what it points at is copied
    // instead, and [maxDepth] is what stops that going round.
    final linkTarget = entry.linkTarget;
    if (linkTarget != null && registry.resolve(target).supportsLinks) {
      work.add(_WorkItem(source, target, false, 0, linkTarget: linkTarget));
      return;
    }

    if (!entry.isDirectory) {
      work.add(
        _WorkItem(source, target, false, entry.size, modified: entry.modified),
      );
      return;
    }

    if (depth >= maxDepth) {
      refuse?.call(
        source,
        tr('More than {depth} folders deep — a link pointing back at itself?',
            {'depth': '$maxDepth'}),
      );
      return;
    }

    work.add(_WorkItem(source, target, true, 0));
    for (final child in await provider.list(source)) {
      await _plan(
        child.path,
        target.child(child.name),
        work,
        depth: depth + 1,
        refuse: refuse,
      );
    }
  }

  Future<void> _ensureDirectory(VfsPath directory) async {
    final provider = registry.resolve(directory);
    if (await provider.stat(directory) != null) return;
    await provider.createDirectory(directory);
  }

  /// Returns the path to write to, or null when the file should be skipped.
  /// Sets `result.cancelled` when the user aborts the batch.
  Future<VfsPath?> _resolveConflict(
    _WorkItem item,
    ConflictResolver? onConflict,
    OperationResult result,
  ) async {
    final targetProvider = registry.resolve(item.target);
    final existing = await targetProvider.stat(item.target);
    if (existing == null) return item.target;

    final action = await onConflict?.call(
          FileEntry(
            path: item.source,
            name: item.source.name,
            kind: FileKind.file,
            size: item.size,
          ),
          existing,
        ) ??
        ConflictAction.skip;

    switch (action) {
      case ConflictAction.overwrite:
        return item.target;
      case ConflictAction.skip:
        result.skipped++;
        return null;
      case ConflictAction.abort:
        result.cancelled = true;
        return null;
      case ConflictAction.autoRename:
        return _uniqueName(targetProvider, item.target);
    }
  }

  /// Appends ` (2)`, ` (3)`… until the name is free.
  Future<VfsPath> _uniqueName(FileSystemProvider provider, VfsPath target) async {
    final parent = target.parent;
    if (parent == null) return target;

    final name = target.name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final suffix = dot > 0 ? name.substring(dot) : '';

    for (var index = 2; index < 1000; index++) {
      final candidate = parent.child('$stem ($index)$suffix');
      if (await provider.stat(candidate) == null) return candidate;
    }
    throw VfsException(tr('Could not find a free name'), path: target);
  }

  /// Puts the link itself at the destination, pointing where it pointed.
  ///
  /// Anything already there is removed first: making a link is not an overwrite
  /// on any platform, so the conflict the user already answered has to be
  /// carried out here rather than by the call.
  Future<void> _copyLink(_WorkItem item, VfsPath target) async {
    final provider = registry.resolve(target);
    if (await provider.stat(target) != null) {
      await provider.delete(target);
    }
    await provider.createLink(target, item.linkTarget!);
  }

  Future<void> _copyFile(
    VfsPath source,
    VfsPath target, {
    int? length,
    DateTime? modified,
    CancellationToken? token,
    void Function(int transferred)? onBytes,
  }) async {
    final sourceProvider = registry.resolve(source);
    final targetProvider = registry.resolve(target);

    if (identical(sourceProvider, targetProvider) &&
        await sourceProvider.copyWithin(source, target)) {
      return;
    }

    var transferred = 0;
    final counted = sourceProvider.openRead(source).map((chunk) {
      token?.throwIfCancelled();
      transferred += chunk.length;
      onBytes?.call(transferred);
      return chunk;
    });

    await targetProvider.write(
      target,
      counted,
      length: length,
      modified: modified,
    );
  }
}
