import 'dart:async';

import 'package:flutter/foundation.dart';

import '../i18n/i18n.dart';
import 'fs_provider.dart';
import 'vfs_path.dart';

/// Maps URI schemes to the providers that serve them.
///
/// The core registers `file:` at startup; plugins add their own schemes as they
/// load. Panels resolve every location through here and never hold a direct
/// reference to a provider, so a plugin can be unloaded without stranding them.
class FileSystemRegistry extends ChangeNotifier {
  final Map<String, FileSystemProvider> _providers = {};

  List<VfsRoot> _knownRoots = const [];

  /// Roots from the last refresh, available immediately.
  ///
  /// Anything drawn in response to a click — a context menu above all — must
  /// read this rather than call [allRoots], because a plugin's provider can
  /// take seconds to answer and a menu that waits on I/O reads as broken.
  List<VfsRoot> get knownRoots => _knownRoots;

  /// Schemes currently served, in registration order.
  List<String> get schemes => _providers.keys.toList(growable: false);

  Iterable<FileSystemProvider> get providers => _providers.values;

  bool supports(String scheme) => _providers.containsKey(scheme);

  void register(FileSystemProvider provider) {
    _providers[provider.scheme] = provider;
    notifyListeners();
    unawaited(refreshRoots());
  }

  /// Removes a scheme and disposes its provider. Panels sitting on that scheme
  /// are expected to fall back to their default location.
  Future<void> unregister(String scheme) async {
    final provider = _providers.remove(scheme);
    if (provider == null) return;
    await provider.dispose();
    notifyListeners();
    await refreshRoots();
  }

  FileSystemProvider? lookup(String scheme) => _providers[scheme];

  /// Provider for [path], or throws when no plugin serves its scheme.
  FileSystemProvider resolve(VfsPath path) {
    final provider = _providers[path.scheme];
    if (provider == null) {
      throw VfsException(
        tr(
          'No provider is registered for "{scheme}:". '
          'A plugin may be missing or failed to load.',
          {'scheme': path.scheme},
        ),
        path: path,
      );
    }
    return provider;
  }

  /// Every root offered by every provider, for the drive/connection bar.
  ///
  /// May be slow: a network provider has to go and look. Prefer [knownRoots]
  /// on any path that has to render immediately.
  Future<List<VfsRoot>> allRoots() async {
    final roots = <VfsRoot>[];
    // A snapshot, because this awaits inside the loop and plugins register
    // their schemes as they finish starting — the map changes under the
    // iterator, and what that costs is the whole drive bar, thrown away by an
    // exception nobody catches.
    for (final provider in _providers.values.toList()) {
      try {
        roots.addAll(await provider.roots());
      } on Object {
        // A misbehaving plugin must not empty the whole drive bar.
        continue;
      }
    }
    return roots;
  }

  /// The refresh in flight, and whether another was asked for while it ran.
  ///
  /// **There is only ever one.** A provider can register from inside its own
  /// `roots()` — a plugin finishing its start-up while the drive list is being
  /// read — and each registration asks for a refresh, so several used to run
  /// over one another and the last to *finish* decided what the list said. One
  /// loop that goes round again instead: whoever asks while it is running joins
  /// the one that is there, and `await refreshRoots()` means everything has
  /// settled rather than everything this particular call started.
  Future<void>? _refresh;
  bool _again = false;

  /// Re-reads every provider's roots into [knownRoots] and notifies listeners.
  ///
  /// **Provider by provider, publishing as each answers.** It used to gather
  /// them all and publish once, which meant one network share taking five
  /// seconds held up the local drives that had answered in one millisecond —
  /// and a stick plugged in a moment ago was not in the list until the share
  /// replied.
  ///
  /// [within] is how long the caller is prepared to wait. It does **not** cut
  /// the refresh short — the rest lands when it lands and [knownRoots] takes
  /// it — it only says when to stop waiting. A menu opening passes a few tens
  /// of milliseconds: long enough for the local disks, far too short to be felt.
  Future<void> refreshRoots({Duration? within}) {
    if (_refresh != null) {
      _again = true;
    } else {
      _refresh = _loop().whenComplete(() => _refresh = null);
    }
    final work = _refresh!;
    if (within == null) return work;
    // Swallowed, because a slow provider is not an error and the caller has
    // what it came for either way.
    return work.timeout(within, onTimeout: () {}).catchError((Object _) {});
  }

  /// How many times round the loop will go before giving up on settling.
  ///
  /// **A bound, because "go round again" can be asked for forever.** A provider
  /// that registers something every time it is asked for its roots — which is
  /// what the race test does, deliberately — would otherwise keep this running
  /// for the life of the process. In real use one pass is the answer and two is
  /// a plugin that finished starting halfway through; anything after that is
  /// picked up by the next refresh, and there is always a next one.
  static const int _settlingPasses = 3;

  Future<void> _loop() async {
    for (var pass = 0; pass < _settlingPasses; pass++) {
      _again = false;
      await _onePass();
      if (!_again) return;
    }
  }

  Future<void> _onePass() async {
    final gathered = <VfsRoot>[];
    // A snapshot, because this awaits inside the loop and plugins register
    // their schemes as they finish starting. Anything that arrives meanwhile
    // sets [_again] and is read on the next time round.
    for (final provider in _providers.values.toList()) {
      try {
        gathered.addAll(await provider.roots());
      } on Object {
        // A misbehaving plugin must not empty the whole drive bar.
        continue;
      }
      _publish(gathered);
    }
    _publish(gathered);
  }

  void _publish(List<VfsRoot> roots) {
    _knownRoots = List.unmodifiable(roots);
    notifyListeners();
  }

  /// Disposes every provider. Kept separate from [dispose] because shutting
  /// down connections is asynchronous and `ChangeNotifier.dispose` is not.
  Future<void> disposeProviders() async {
    // Snapshot for the same reason [allRoots] takes one: this awaits, and a
    // plugin that is still stopping may unregister while it does.
    for (final provider in _providers.values.toList()) {
      await provider.dispose();
    }
    _providers.clear();
  }
}
