import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/search/file_search.dart';
import '../core/vfs/file_entry.dart';
import '../core/vfs/fs_registry.dart';
import '../core/vfs/vfs_path.dart';

/// Drives one search and holds its results.
///
/// The engine is a stream; this is what a window can listen to. Results are
/// kept after the walk finishes so they can be handed to a panel — which is
/// the whole point of searching in a file manager.
class FileSearchController extends ChangeNotifier {
  FileSearchController(this.registry);

  final FileSystemRegistry registry;

  final List<FileEntry> results = [];

  StreamSubscription<SearchEvent>? _subscription;
  DateTime _lastNotified = DateTime.fromMillisecondsSinceEpoch(0);

  SearchQuery? _query;
  VfsPath? _currentDirectory;
  int _scanned = 0;
  int _failures = 0;
  bool _finished = false;

  /// The search that produced [results], or is producing them.
  SearchQuery? get query => _query;

  bool get isRunning => _subscription != null;

  /// True once a search has run to the end, so "no results" can be told apart
  /// from "nothing searched yet".
  bool get isFinished => _finished;

  VfsPath? get currentDirectory => _currentDirectory;

  int get scanned => _scanned;

  /// Directories that could not be read. Common, and worth saying out loud.
  int get failures => _failures;

  int get resultCount => results.length;

  bool get hitLimit =>
      _query != null && results.length >= _query!.maxResults;

  void start(SearchQuery query) {
    stop();

    _query = query;
    results.clear();
    _currentDirectory = query.location;
    _scanned = 0;
    _failures = 0;
    _finished = false;
    notifyListeners();

    _subscription = searchFiles(query, registry).listen(
      _onEvent,
      onDone: _onDone,
      onError: (Object error) {
        _failures++;
        _onDone();
      },
      cancelOnError: false,
    );
  }

  /// Stops the walk. Results found so far are kept — a search you cut short
  /// because you already spotted the file is still a useful result set.
  void stop() {
    final subscription = _subscription;
    if (subscription == null) return;
    _subscription = null;
    unawaited(subscription.cancel());
    _finished = true;
    notifyListeners();
  }

  void clear() {
    stop();
    results.clear();
    _query = null;
    _scanned = 0;
    _failures = 0;
    _finished = false;
    notifyListeners();
  }

  void _onEvent(SearchEvent event) {
    switch (event) {
      case SearchHit(:final entry):
        results.add(entry);
      case SearchProgress(:final directory, :final scanned):
        _currentDirectory = directory;
        _scanned = scanned;
      case SearchFailure():
        _failures++;
    }
    _notifyThrottled();
  }

  void _onDone() {
    _subscription = null;
    _finished = true;
    notifyListeners();
  }

  /// A deep search fires thousands of events a second; repainting on each one
  /// costs more than the search does.
  void _notifyThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastNotified) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastNotified = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}
