import 'package:flutter/foundation.dart';

import '../i18n/i18n.dart';
import 'built_in_source.dart';
import 'plugin_registry.dart';
import 'plugin_source.dart';
import 'rpc/python_installer.dart';

/// The first run's offer, made on the About card: Python, and the everyday
/// plugins with it (backlog 149).
///
/// **Offered while there is no Python**, and never where there is one — a
/// machine that already runs plugins has nothing to be told. *Not now* puts it
/// away until the next start. Asked for on 2026-09-13, with the card itself
/// left as it was: the offer is one strip on it, not a second window.
///
/// **One object for the whole run, not the card's state.** The card goes the
/// moment anything else is pressed, and a download of Python is not something
/// a stray press should cancel; the work carries on, and the strip shows where
/// it has got to whenever the card is up.
class FirstRunSetup extends ChangeNotifier {
  FirstRunSetup._();

  static final FirstRunSetup instance = FirstRunSetup._();

  /// The everyday set: files as text, images, sound, archives,
  /// PDF, pictures, vector graphics and the disk map. The first three ship in
  /// the bundle and need neither Python nor a download, so these are the five
  /// the offer installs.
  static const List<String> everydayPlugins = [
    'org.xverb.archives',
    'org.xverb.pdf',
    'org.xverb.pictures',
    'org.xverb.vector',
    'org.xverb.diskmap',
  ];

  bool _dismissed = false;
  InstallProgress? _progress;
  String? _failure;
  int? _installed;

  /// What is being done, while something is.
  InstallProgress? get progress => _progress;

  /// Why it stopped, where it did.
  String? get failure => _failure;

  /// How many plugins went in, once it has finished.
  int? get installed => _installed;

  bool get busy => _progress != null;

  /// Stands in for "is there Python" in a test, which cannot arrange for a
  /// machine to have none.
  @visibleForTesting
  static bool? offerForTest;

  /// Whether the card has anything to say about it: the offer, the work under
  /// way, or how the work ended.
  bool shownWith(PluginRegistry plugins) {
    if (_dismissed) return false;
    if (busy || _failure != null || _installed != null) return true;
    return offerForTest ??
        (plugins.runtimeChecked &&
            plugins.runtime == null &&
            PythonInstaller.plannedUrl != null);
  }

  /// *Not now*: away until the application is started again.
  void notNow() {
    _dismissed = true;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _dismissed = false;
    _progress = null;
    _failure = null;
    _installed = null;
  }

  /// Installs Python if there is none, then whichever of [everydayPlugins]
  /// are not in yet, from the collection the application knows without being
  /// told.
  Future<void> install(PluginRegistry plugins) async {
    if (busy) return;
    _failure = null;
    _installed = null;
    _report(InstallProgress(tr('Starting…')));
    Catalogue? catalogue;
    try {
      if (plugins.runtime == null) {
        await PythonInstaller.install(onProgress: _report);
        // So the plugins about to go in start, rather than waiting for a
        // restart to find the interpreter they need.
        await plugins.refreshRuntime();
      }
      _report(InstallProgress(tr('Reading the plugin catalogue…')));
      catalogue = await PluginSource.fetch(
        kBuiltInPluginSource,
        onProgress: _report,
      );
      final there = {for (final entry in plugins.entries) entry.manifest.id};
      var count = 0;
      for (final id in everydayPlugins) {
        if (there.contains(id)) continue;
        final entry =
            catalogue.entries.where((e) => e.manifest.id == id).firstOrNull;
        if (entry == null) continue;
        _report(InstallProgress(
          tr('Installing {name}…', {'name': entry.manifest.name}),
        ));
        await plugins.install(entry);
        count++;
      }
      _installed = count;
    } on Object catch (error) {
      _failure = '$error';
    } finally {
      _progress = null;
      notifyListeners();
      await catalogue?.dispose();
    }
  }

  void _report(InstallProgress progress) {
    _progress = progress;
    notifyListeners();
  }
}
