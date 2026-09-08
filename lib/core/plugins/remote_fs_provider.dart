import 'dart:async';
import 'dart:convert';

import '../vfs/file_entry.dart';
import '../vfs/fs_provider.dart';
import '../vfs/vfs_path.dart';
import 'rpc/json_rpc.dart';
import 'rpc/python_plugin_host.dart';

/// A [FileSystemProvider] whose work is done by a plugin over RPC.
///
/// Everything the panels do with a local disk they can do with this, which is
/// what lets FTP and SMB live outside the core.
class RemoteFileSystemProvider extends FileSystemProvider {
  RemoteFileSystemProvider({
    required this.scheme,
    required this.displayName,
    required this.host,
    this.isWritable = true,
    this.badge,
  });

  @override
  final String scheme;

  @override
  final String displayName;

  @override
  final bool isWritable;

  @override
  final String? badge;

  /// The plugin process that answers this provider's calls.
  final PythonPluginHost host;

  /// Bytes requested per `fs.read` round trip. Large enough that the RPC
  /// overhead stays negligible, small enough to keep progress smooth.
  static const int chunkSize = 256 * 1024;

  @override
  Future<List<VfsRoot>> roots() async {
    final result = await _call('fs.roots', {'scheme': scheme});
    final list = result is List ? result : const [];
    return [
      for (final item in list.cast<Map>())
        VfsRoot(
          path: VfsPath.parse(item['url'] as String),
          label: item['label'] as String? ?? scheme,
          subtitle: item['subtitle'] as String?,
          iconName: item['icon'] as String? ?? 'server',
        ),
    ];
  }

  @override
  Future<VfsPath> defaultLocation() async {
    final result = await _call('fs.defaultLocation', {'scheme': scheme});
    if (result is Map && result['url'] is String) {
      return VfsPath.parse(result['url'] as String);
    }
    return VfsPath.parse('$scheme:///');
  }

  @override
  Future<List<FileEntry>> list(VfsPath directory) async {
    final result = await _call('fs.list', {'url': directory.toString()});
    final entries = result is Map ? result['entries'] : result;
    if (entries is! List) return const [];
    return [
      for (final item in entries.cast<Map>())
        FileEntry.fromJson(Map<String, dynamic>.from(item), directory),
    ];
  }

  @override
  Future<FileEntry?> stat(VfsPath path) async {
    final result = await _call('fs.stat', {'url': path.toString()});
    if (result is! Map) return null;
    final parent = path.parent;
    return FileEntry.fromJson(
      Map<String, dynamic>.from(result),
      parent ?? path,
    );
  }

  @override
  Stream<List<int>> openRead(VfsPath file, {int? start, int? end}) async* {
    var offset = start ?? 0;
    while (true) {
      var want = chunkSize;
      if (end != null) {
        final remaining = end - offset;
        if (remaining <= 0) break;
        if (remaining < want) want = remaining;
      }

      final result = await _call('fs.read', {
        'url': file.toString(),
        'offset': offset,
        'length': want,
      });
      if (result is! Map) break;

      final encoded = result['data'] as String? ?? '';
      if (encoded.isNotEmpty) {
        final bytes = base64Decode(encoded);
        offset += bytes.length;
        yield bytes;
      }
      if (result['eof'] as bool? ?? encoded.isEmpty) break;
    }
  }

  @override
  Future<void> write(
    VfsPath file,
    Stream<List<int>> data, {
    int? length,
    DateTime? modified,
  }) async {
    var first = true;
    // Chunks arriving from the source are re-packed so a slow trickle of tiny
    // reads does not turn into one RPC round trip per read.
    final buffer = <int>[];

    Future<void> flush({required bool force}) async {
      while (buffer.length >= chunkSize || (force && buffer.isNotEmpty)) {
        final take = buffer.length < chunkSize ? buffer.length : chunkSize;
        final slice = buffer.sublist(0, take);
        buffer.removeRange(0, take);
        await _call('fs.write', {
          'url': file.toString(),
          'data': base64Encode(slice),
          'mode': first ? 'create' : 'append',
          // Only on the first chunk: what the plugin needs before it starts,
          // and what it cannot find out for itself. A file's size is worth
          // knowing up front, and its date cannot be recovered afterwards at
          // all — a member goes into an archive with the date it is given.
          if (first && length != null) 'length': length,
          if (first && modified != null)
            'modified': modified.millisecondsSinceEpoch,
        });
        first = false;
      }
    }

    try {
      await for (final chunk in data) {
        buffer.addAll(chunk);
        await flush(force: false);
      }
      await flush(force: true);

      // An empty source file still has to create the target.
      if (first) {
        await _call('fs.write', {
          'url': file.toString(),
          'data': '',
          'mode': 'create',
          'length': ?length,
          if (modified != null) 'modified': modified.millisecondsSinceEpoch,
        });
      }
    } on Object {
      // Say that it ended badly before letting the failure out. A backend that
      // has to assemble something — an archive holding a member half written —
      // otherwise waits for bytes that are never coming.
      await _closeWrite(file, complete: false);
      rethrow;
    }

    await _closeWrite(file, complete: true);
  }

  /// Tells the plugin the file is finished.
  ///
  /// Nothing else in the protocol says so: a write arrives as a `create`
  /// followed by any number of `append`s, and where those stop is the one thing
  /// the plugin could not see. A transport writing straight through does not
  /// care — the file was on the server after the last chunk. A backend that has
  /// to *close* something does: a member being deflated into an archive is not
  /// in the archive until its sizes and its central directory entry are
  /// written, and until this existed the last file of a copy stayed unfinished.
  ///
  /// Failures here are swallowed on purpose when the write already failed —
  /// the error that matters is the one that got us here.
  Future<void> _closeWrite(VfsPath file, {required bool complete}) async {
    try {
      await _call('fs.write', {
        'url': file.toString(),
        'data': '',
        'mode': complete ? 'close' : 'abort',
      });
    } on Object {
      if (complete) rethrow;
    }
  }

  @override
  Future<void> finishWrites(VfsPath where) async {
    try {
      await _call('fs.finish', {'url': where.toString()});
    } on RpcException catch (e) {
      // A plugin running against an SDK from before this existed simply has
      // nothing to finish. Timing hints are allowed to go unheard.
      if (e.code != -32601) rethrow;
    }
  }

  @override
  Future<void> createDirectory(VfsPath directory) =>
      _call('fs.mkdir', {'url': directory.toString()});

  @override
  Future<void> delete(VfsPath path) =>
      _call('fs.delete', {'url': path.toString()});

  @override
  Future<void> rename(VfsPath from, VfsPath to) => _call('fs.rename', {
        'from': from.toString(),
        'to': to.toString(),
      });

  @override
  Future<bool> copyWithin(VfsPath from, VfsPath to) async {
    try {
      final result = await _call('fs.copyWithin', {
        'from': from.toString(),
        'to': to.toString(),
      });
      return result == true;
    } on RpcException catch (e) {
      // -32601 means the plugin simply did not implement the fast path.
      if (e.code == -32601) return false;
      rethrow;
    }
  }

  @override
  Future<void> dispose() => host.stop();

  Future<dynamic> _call(String method, Map<String, dynamic> params) async {
    try {
      return await host.channel
          .call(method, params: params, timeout: PythonPluginHost.callTimeout);
    } on RpcException catch (e) {
      throw VfsException('$displayName: ${e.message}', cause: e);
    } on StateError catch (e) {
      throw VfsException('$displayName is not running', cause: e);
    }
  }
}
