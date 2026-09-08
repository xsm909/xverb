import 'dart:collection';
import 'dart:convert';

import '../vfs/file_entry.dart';
import '../vfs/fs_provider.dart';
import '../vfs/fs_registry.dart';
import '../vfs/vfs_path.dart';
import 'file_mask.dart';

/// What to look for, and where.
class SearchQuery {
  const SearchQuery({
    required this.location,
    this.namePattern = '',
    this.containingText = '',
    this.caseSensitive = false,
    this.wholeWords = false,
    this.searchSubdirectories = true,
    this.includeDirectories = true,
    this.maxResults = 20000,
  });

  /// Where the walk starts.
  final VfsPath location;

  /// File mask, in [FileMask] syntax. Empty means every name.
  final String namePattern;

  /// Text the file must contain. Empty skips reading files altogether, which
  /// is the difference between a search that takes a second and one that takes
  /// a minute.
  final String containingText;

  final bool caseSensitive;
  final bool wholeWords;
  final bool searchSubdirectories;

  /// Whether directories can be results in their own right.
  final bool includeDirectories;

  /// Stops the walk once this many results are in, so a search of C:\ cannot
  /// grow until it takes the app down with it.
  final int maxResults;

  bool get searchesContent => containingText.isNotEmpty;

  /// One line describing the search, used as the window and panel title.
  String get summary {
    final what = namePattern.trim().isEmpty ? '*' : namePattern.trim();
    return searchesContent
        ? '$what containing "$containingText"'
        : what;
  }
}

/// Everything the engine reports while it runs.
sealed class SearchEvent {
  const SearchEvent();
}

/// A file or directory that matched.
class SearchHit extends SearchEvent {
  const SearchHit(this.entry);

  final FileEntry entry;
}

/// Where the walk currently is. Emitted once per directory, which is often
/// enough to look alive and rare enough not to drown the UI in rebuilds.
class SearchProgress extends SearchEvent {
  const SearchProgress({
    required this.directory,
    required this.scanned,
    required this.found,
  });

  final VfsPath directory;
  final int scanned;
  final int found;
}

/// A directory that could not be read. Reported rather than thrown: half of
/// `C:\` is unreadable, and that must not end the search.
class SearchFailure extends SearchEvent {
  const SearchFailure(this.path, this.message);

  final VfsPath path;
  final String message;
}

/// How much of one file is read before giving up on finding the text in it.
const int kMaxTextScanBytes = 64 * 1024 * 1024;

/// Walks [query] and reports what it finds.
///
/// Breadth-first, so shallow results — the ones the user most often wants —
/// arrive first. Cancelling the subscription stops the walk at the next
/// result; a directory listing or file read already in flight is allowed to
/// finish rather than being torn out from under the provider.
Stream<SearchEvent> searchFiles(
  SearchQuery query,
  FileSystemRegistry registry,
) async* {
  final mask = FileMask.parse(
    query.namePattern,
    caseSensitive: query.caseSensitive,
  );
  final needle = _Needle.of(query);
  final provider = registry.resolve(query.location);

  final queue = Queue<VfsPath>()..add(query.location);
  var scanned = 0;
  var found = 0;

  while (queue.isNotEmpty) {
    final directory = queue.removeFirst();

    List<FileEntry> listing;
    try {
      listing = await provider.list(directory);
    } on VfsException catch (e) {
      yield SearchFailure(directory, e.message);
      continue;
    } on Object catch (e) {
      yield SearchFailure(directory, e.toString());
      continue;
    }

    yield SearchProgress(
      directory: directory,
      scanned: scanned,
      found: found,
    );

    for (final entry in listing) {
      scanned++;

      if (entry.isDirectory && query.searchSubdirectories) {
        queue.add(entry.path);
      }
      if (entry.isDirectory && (!query.includeDirectories || needle != null)) {
        continue;
      }
      if (!mask.matches(entry.name)) continue;

      if (needle != null && !await _contains(provider, entry, needle)) {
        continue;
      }

      found++;
      yield SearchHit(entry);
      if (found >= query.maxResults) return;
    }
  }

  yield SearchProgress(
    directory: query.location,
    scanned: scanned,
    found: found,
  );
}

/// The text being looked for, encoded once.
class _Needle {
  _Needle(this.bytes, this.wholeWords, this.caseSensitive);

  final List<int> bytes;
  final bool wholeWords;
  final bool caseSensitive;

  static _Needle? of(SearchQuery query) {
    if (!query.searchesContent) return null;
    final text = query.caseSensitive
        ? query.containingText
        : query.containingText.toLowerCase();
    return _Needle(utf8.encode(text), query.wholeWords, query.caseSensitive);
  }

  /// ASCII case folding. Text files that need more than this to match — Greek,
  /// Cyrillic, anything outside ASCII — still match exactly, just not
  /// case-insensitively.
  int _fold(int byte) {
    if (caseSensitive) return byte;
    if (byte >= 0x41 && byte <= 0x5A) return byte + 0x20;
    return byte;
  }

  bool _isWordByte(int byte) =>
      (byte >= 0x30 && byte <= 0x39) ||
      (byte >= 0x41 && byte <= 0x5A) ||
      (byte >= 0x61 && byte <= 0x7A) ||
      byte == 0x5F ||
      byte >= 0x80;

  /// Plain scan. Files are read in chunks and the tail of each is carried over,
  /// so a match straddling a chunk boundary is not missed.
  bool matchesIn(List<int> buffer) {
    final length = bytes.length;
    if (length == 0 || buffer.length < length) return false;

    for (var start = 0; start <= buffer.length - length; start++) {
      var matched = true;
      for (var i = 0; i < length; i++) {
        if (_fold(buffer[start + i]) != bytes[i]) {
          matched = false;
          break;
        }
      }
      if (!matched) continue;

      if (wholeWords) {
        final before = start == 0 ? null : buffer[start - 1];
        final afterIndex = start + length;
        final after = afterIndex >= buffer.length ? null : buffer[afterIndex];
        if (before != null && _isWordByte(before)) continue;
        if (after != null && _isWordByte(after)) continue;
      }
      return true;
    }
    return false;
  }
}

Future<bool> _contains(
  FileSystemProvider provider,
  FileEntry entry,
  _Needle needle,
) async {
  // One byte of overlap more than the needle, so a whole-word match sitting
  // exactly on a chunk boundary still sees its neighbours.
  final overlap = needle.bytes.length;
  var carried = const <int>[];
  var read = 0;

  try {
    await for (final chunk in provider.openRead(entry.path)) {
      final buffer = carried.isEmpty ? chunk : [...carried, ...chunk];
      if (needle.matchesIn(buffer)) return true;

      carried = buffer.length <= overlap
          ? buffer
          : buffer.sublist(buffer.length - overlap);

      read += chunk.length;
      if (read >= kMaxTextScanBytes) break;
    }
  } on Object {
    // An unreadable file is simply not a match.
    return false;
  }
  return false;
}
