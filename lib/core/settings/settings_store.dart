import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n/i18n.dart';
import '../i18n/plugin_strings.dart';
import '../update/update_offer.dart';
import 'appearance_settings.dart';

/// Which column the panels sort by.
enum SortColumn { name, extension, size, modified }

/// Persisted user settings: appearance, sorting, and per-panel last location.
///
/// Backed by `shared_preferences`, which resolves to the right place on every
/// platform, so there is no config file to manage.
class SettingsStore extends ChangeNotifier {
  SettingsStore._(this._prefs, this._appearance);

  static const _kAppearance = 'appearance';
  static const _kLeftPath = 'panel.left.path';
  static const _kRightPath = 'panel.right.path';
  static const _kLeftCursor = 'panel.left.cursor';
  static const _kRightCursor = 'panel.right.cursor';
  static const _kSortColumn = 'panel.sort.column';
  static const _kSortAscending = 'panel.sort.ascending';
  static const _kDirectoriesFirst = 'panel.sort.directoriesFirst';
  static const _kAdvancedAppearance = 'appearance.advanced';
  static const _kDisabledPlugins = 'plugins.disabled';
  static const _kSeededPlugins = 'plugins.seeded';
  static const _kShellKind = 'shell.kind';
  static const _kPluginSources = 'plugins.sources';
  static const _kConsoleHeight = 'shell.consoleHeight';
  static const _kCommandHistory = 'shell.history';
  static const _kTitleBarOrder = 'plugins.titleBarOrder';
  static const _kLanguage = 'language';
  static const _kVolumePaths = 'panel.volumePaths';
  static const _kSlidePanelShare = 'viewer.slidePanel.share';
  static const _kSlidePanelOpen = 'viewer.slidePanel.open';
  static const _kSlidePanelPinned = 'viewer.slidePanel.pinned';
  static const _kOutlineShare = 'viewer.outline.share';
  static const _kOutlineOpen = 'viewer.outline.open';
  static const _kOutlinePinned = 'viewer.outline.pinned';
  static const _kNodeMinimap = 'viewer.nodes.minimap';
  static const _kFilmStrip = 'viewer.filmStrip.open';
  static const _kFilmStripRows = 'viewer.filmStrip.rows';
  static const _kFilmStripFold = 'viewer.filmStrip.fold';
  static const _kZoomMode = 'viewer.zoom.mode';
  static const _kSoundVolume = 'viewer.sound.volume';
  static const _kSoundSpectrum = 'viewer.sound.spectrum';
  static const _kUpdateStaying = 'update.staying';
  static const _kUpdatePostponed = 'update.postponed';
  static const _kUpdateRemindAfter = 'update.remindAfter';
  static const _kUpdateLastChecked = 'update.lastChecked';

  final SharedPreferences _prefs;
  AppearanceSettings _appearance;

  static Future<SettingsStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kAppearance);

    var appearance = const AppearanceSettings();
    if (raw != null) {
      try {
        appearance = AppearanceSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } on Object {
        // Corrupt or older-format settings fall back to defaults rather than
        // blocking startup.
      }
    }

    final store = SettingsStore._(prefs, appearance);
    // Before the first frame: a language applied afterwards would show the
    // application in English and then swap it, which reads as a bug even when
    // it lasts a single frame.
    await store._applyLanguage();
    return store;
  }

  /// What the user picked, which may be [LanguageOption.system].
  LanguageOption get language =>
      LanguageOption.byCode(_prefs.getString(_kLanguage));

  /// The language actually in use, with "System" resolved to a real one.
  LanguageOption get resolvedLanguage =>
      LanguageOption.resolve(_prefs.getString(_kLanguage));

  Future<void> setLanguage(LanguageOption value) async {
    await _prefs.setString(_kLanguage, value.code);
    await _applyLanguage();
    notifyListeners();
  }

  /// Loads the catalogue for the chosen language and makes it the active one.
  ///
  /// A language that will not load leaves the application in English rather
  /// than half-translated: a missing or broken catalogue is a packaging
  /// mistake, and English is always readable.
  Future<void> _applyLanguage() async {
    final option = resolvedLanguage;
    try {
      activeLocalisation = await Localisation.fromAsset(option);
    } on Object {
      activeLocalisation = Localisation.sourceLanguage(
        LanguageOption.shipped.first,
      );
    }
    // A plugin's own words come out of its own catalogue, which is now the
    // wrong one. Forgotten here rather than left standing: a name in the last
    // language is worse than a name in English, because it looks deliberate.
    clearPluginStrings();
    await onLanguageChanged?.call();
  }

  /// Told after the catalogue has changed, so whoever holds the plugins can
  /// read theirs again. Wired in `AppState.create`, the way every other hook
  /// between the store and the registry is.
  Future<void> Function()? onLanguageChanged;

  AppearanceSettings get appearance => _appearance;

  set appearance(AppearanceSettings value) {
    _appearance = value;
    _prefs.setString(_kAppearance, jsonEncode(value.toJson()));
    notifyListeners();
  }

  /// Applies a single change without rebuilding the whole object at call sites.
  void updateAppearance(
    AppearanceSettings Function(AppearanceSettings current) change,
  ) => appearance = change(_appearance);

  void resetAppearance() => appearance = const AppearanceSettings();

  SortColumn get sortColumn => SortColumn.values.firstWhere(
    (c) => c.name == _prefs.getString(_kSortColumn),
    orElse: () => SortColumn.name,
  );

  set sortColumn(SortColumn value) {
    _prefs.setString(_kSortColumn, value.name);
    notifyListeners();
  }

  bool get sortAscending => _prefs.getBool(_kSortAscending) ?? true;

  set sortAscending(bool value) {
    _prefs.setBool(_kSortAscending, value);
    notifyListeners();
  }

  /// Sorts by [column], flipping the direction when it is already the one in
  /// use. This is what both the column headers and Ctrl+F3..F6 call.
  void applySort(SortColumn column) {
    if (sortColumn == column) {
      sortAscending = !sortAscending;
    } else {
      _prefs.setString(_kSortColumn, column.name);
      sortAscending = true;
    }
  }

  bool get directoriesFirst => _prefs.getBool(_kDirectoriesFirst) ?? true;

  set directoriesFirst(bool value) {
    _prefs.setBool(_kDirectoriesFirst, value);
    notifyListeners();
  }

  /// Whether the appearance settings show everything or only the few things
  /// most people change. Remembered, because someone who wants every dial is
  /// not going to want to ask for them again next time.
  bool get advancedAppearance => _prefs.getBool(_kAdvancedAppearance) ?? false;

  set advancedAppearance(bool value) {
    _prefs.setBool(_kAdvancedAppearance, value);
    notifyListeners();
  }

  /// Repositories the plugin manager offers extensions from, newest first.
  ///
  /// Only the ones the user added: the collection the app ships with is a
  /// constant, so it cannot be lost and does not have to be migrated into
  /// anyone's settings.
  List<String> get pluginSources =>
      _prefs.getStringList(_kPluginSources) ?? const [];

  Future<void> addPluginSource(String source) async {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return;
    final sources = [...pluginSources]
      ..removeWhere((s) => s.toLowerCase() == trimmed.toLowerCase())
      ..insert(0, trimmed);
    await _prefs.setStringList(_kPluginSources, sources);
    notifyListeners();
  }

  Future<void> removePluginSource(String source) async {
    final sources = [...pluginSources]..remove(source);
    await _prefs.setStringList(_kPluginSources, sources);
    notifyListeners();
  }

  String? panelPath(bool isLeft) =>
      _prefs.getString(isLeft ? _kLeftPath : _kRightPath);

  Future<void> setPanelPath(bool isLeft, String uri) =>
      _prefs.setString(isLeft ? _kLeftPath : _kRightPath, uri);

  /// The row the panel was standing on when the application was last closed.
  ///
  /// **A name, not an index.** A folder is not the same list next time — a file
  /// arrives, another is deleted, the sort is changed — and an index would put
  /// the cursor on whatever has since taken that place, which is worse than
  /// putting it at the top. A name that is no longer there simply finds
  /// nothing, and the panel opens at the top as it always did.
  ///
  /// One per side rather than one per folder. Remembering the row for *every*
  /// folder ever visited is a different feature with a store of its own to
  /// keep; this is the one thing that was actually missing — coming back to
  /// where you were.
  String? panelCursor(bool isLeft) =>
      _prefs.getString(isLeft ? _kLeftCursor : _kRightCursor);

  Future<void> setPanelCursor(bool isLeft, String name) =>
      _prefs.setString(isLeft ? _kLeftCursor : _kRightCursor, name);

  /// Where the user last was on each volume, keyed by the volume's own root.
  ///
  /// Changing drive then goes back to the folder that drive was left in, which
  /// is what every orthodox commander does and what Windows itself does with a
  /// current directory per drive. Not per panel: whichever panel changes to a
  /// volume wants the folder that was being worked in there, and a memory that
  /// depended on which half of the window asked would answer differently for
  /// the same question.
  ///
  /// One preference holding a map rather than a key per volume, so a drive that
  /// is never seen again leaves one entry to clean up rather than one key.
  Map<String, String> get volumePaths {
    final raw = _prefs.getString(_kVolumePaths);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final entry in decoded.entries) entry.key: entry.value.toString(),
      };
    } on Object {
      // Written by an older version, or damaged. Forgetting where the user was
      // is not worth failing to start over.
      return const {};
    }
  }

  /// The folder [volume] was last left in, or null if it has not been visited.
  String? volumePath(String volume) => volumePaths[volume];

  Future<void> setVolumePath(String volume, String uri) async {
    final paths = {...volumePaths, volume: uri};
    await _prefs.setString(_kVolumePaths, jsonEncode(paths));
  }

  /// Which shell the command line runs commands in.
  String? get shellKind => _prefs.getString(_kShellKind);

  Future<void> setShellKind(String name) => _prefs.setString(_kShellKind, name);

  double? get consoleHeight => _prefs.getDouble(_kConsoleHeight);

  Future<void> setConsoleHeight(double value) =>
      _prefs.setDouble(_kConsoleHeight, value);

  /// What the panel that slides over a reading was left at.
  ///
  /// **One set for the viewer, not one per file and not one per file type.**
  /// Somebody who reads with the panel out reads *everything* with it out; the
  /// alternative is a panel whose state depends on which file you opened,
  /// which nobody can predict and therefore nobody can rely on.
  ///
  /// Null share means it has never been dragged, and the panel takes its own
  /// default — the width lives with the widget, not in here.
  double? get slidePanelShare => _prefs.getDouble(_kSlidePanelShare);

  Future<void> setSlidePanelShare(double value) =>
      _prefs.setDouble(_kSlidePanelShare, value);

  /// Whether it was left out. This is the *only* way a panel opens without a
  /// key being pressed — it never decides for itself that a file wants one.
  bool get slidePanelOpen => _prefs.getBool(_kSlidePanelOpen) ?? false;

  Future<void> setSlidePanelOpen(bool value) =>
      _prefs.setBool(_kSlidePanelOpen, value);

  /// Whether it was pinned — which is what decides if a press in the content
  /// puts it away again.
  bool get slidePanelPinned => _prefs.getBool(_kSlidePanelPinned) ?? false;

  Future<void> setSlidePanelPinned(bool value) =>
      _prefs.setBool(_kSlidePanelPinned, value);

  /// The same three, for the structure of a document.
  ///
  /// **A second set rather than the node canvas's**, though the panel is the
  /// same widget: the two show different things, and somebody who keeps a
  /// node's properties out has not thereby asked for a table of contents over
  /// every file of text they open afterwards.
  double? get outlinePanelShare => _prefs.getDouble(_kOutlineShare);

  Future<void> setOutlinePanelShare(double value) =>
      _prefs.setDouble(_kOutlineShare, value);

  bool get outlinePanelOpen => _prefs.getBool(_kOutlineOpen) ?? false;

  Future<void> setOutlinePanelOpen(bool value) =>
      _prefs.setBool(_kOutlineOpen, value);

  bool get outlinePanelPinned => _prefs.getBool(_kOutlinePinned) ?? false;

  Future<void> setOutlinePanelPinned(bool value) =>
      _prefs.setBool(_kOutlinePinned, value);

  /// Whether the node canvas draws the whole graph small in a corner.
  ///
  /// Null means nobody has said either way, and the canvas decides by where it
  /// is: out on a page, away in a panel, where a minimap in a quarter of the
  /// window costs more than it returns.
  bool? get nodeMinimap => _prefs.getBool(_kNodeMinimap);

  Future<void> setNodeMinimap(bool value) =>
      _prefs.setBool(_kNodeMinimap, value);

  /// Whether a full-screen viewer shows the row of neighbouring files along
  /// its bottom edge.
  ///
  /// **One setting for every viewer, and on by default.** It is the same
  /// argument the slide panel's is written down under: somebody who walks a
  /// folder with the strip up walks *every* folder with it up, and a strip
  /// whose presence depended on which file you opened is one nobody can rely
  /// on. It is also what makes Left and Right honest — with the strip away
  /// they go back to moving the picture, and that state is on the screen
  /// rather than in anybody's memory.
  bool get filmStripOpen => _prefs.getBool(_kFilmStrip) ?? true;

  Future<void> setFilmStripOpen(bool value) async {
    await _prefs.setBool(_kFilmStrip, value);
    notifyListeners();
  }

  /// How many rows the strip folds into when the pointer is on it.
  ///
  /// **A number rather than a switch**, because the answer depends on the
  /// window and on the folder: three rows of a wide window is most of a
  /// hundred photographs at once, and on a small screen it is the picture
  /// itself that has gone. Clamped on the way out as well as on the way in, so
  /// a value written by hand into the preferences cannot leave the strip
  /// taller than the window it stands in.
  /// **One at the least and five at the most.** One row is not a grid — it is
  /// what the strip already is — so setting it there is how the folding is
  /// turned off altogether. Beyond five the thing being looked at
  /// is behind the thing that is meant to help you look at it.
  static const int fewestStripRows = 1;
  static const int mostStripRows = 5;
  static const int defaultStripRows = 3;

  int get filmStripRows => (_prefs.getInt(_kFilmStripRows) ?? defaultStripRows)
      .clamp(fewestStripRows, mostStripRows);

  /// How the strip lays itself out once it is folded — the name of one of the
  /// strip's own arrangements, read back by the strip.
  ///
  /// **A name, not the enum**, for the reason the zoom mode's is one: the
  /// arrangements belong to the strip and the settings have no business
  /// importing the interface. Anything unknown — a value written by a build
  /// that offered a third — falls back to the default where it is read.
  String? get filmStripFold => _prefs.getString(_kFilmStripFold);

  Future<void> setFilmStripFold(String name) async {
    await _prefs.setString(_kFilmStripFold, name);
    notifyListeners();
  }

  Future<void> setFilmStripRows(int value) async {
    await _prefs.setInt(
      _kFilmStripRows,
      value.clamp(fewestStripRows, mostStripRows),
    );
    notifyListeners();
  }

  /// How a picture or a drawing arrives in a full-screen viewer: fitted,
  /// filling the window, or one pixel to one pixel.
  ///
  /// **A name, not the enum**, because the enum belongs to the canvas and the
  /// settings have no business importing the interface. Read back through
  /// `ZoomMode.byName`, which answers with the default for anything it does
  /// not know — so a value written by a build that offered a fourth mode does
  /// not leave the viewer opening in nothing.
  ///
  /// One for every viewer, remembered, and for the reason the strip's is:
  /// somebody who looks at photographs filling the window looks at *every*
  /// photograph that way, and a mode that depended on which file you opened is
  /// one nobody can rely on.
  String? get viewerZoomMode => _prefs.getString(_kZoomMode);

  Future<void> setViewerZoomMode(String name) async {
    await _prefs.setString(_kZoomMode, name);
    notifyListeners();
  }

  /// Commands already entered, oldest first. Kept between runs, because the
  /// command worth repeating is often the one from yesterday.
  List<String> get commandHistory =>
      _prefs.getStringList(_kCommandHistory) ?? const [];

  Future<void> setCommandHistory(List<String> entries) =>
      _prefs.setStringList(_kCommandHistory, entries);

  Set<String> get disabledPlugins =>
      (_prefs.getStringList(_kDisabledPlugins) ?? const []).toSet();

  Future<void> setDisabledPlugins(Set<String> ids) =>
      _prefs.setStringList(_kDisabledPlugins, ids.toList());

  /// Plugins the application has already handed over a first copy of.
  ///
  /// The viewers travel inside the app so a fresh install can open a file at
  /// all, and are then ordinary installed plugins that the store updates. Once
  /// one has been laid down it is never laid down again — a plugin the user
  /// deleted is a plugin they deleted, not one to be put back on next launch.
  Set<String> get seededPlugins =>
      (_prefs.getStringList(_kSeededPlugins) ?? const []).toSet();

  Future<void> setSeededPlugins(Set<String> ids) =>
      _prefs.setStringList(_kSeededPlugins, ids.toList());

  /// What the user changed in one plugin's own settings.
  ///
  /// Only the changes: a plugin's declared defaults are not copied in here, so
  /// a plugin that revises a default gets the new one for everybody who never
  /// touched it. One entry per plugin, so removing a plugin leaves nothing to
  /// tidy up elsewhere.
  Map<String, Object?> pluginSettings(String pluginId) {
    final raw = _prefs.getString(_pluginSettingsKey(pluginId));
    if (raw == null) return const {};
    try {
      return Map<String, Object?>.from(jsonDecode(raw) as Map);
    } on Object {
      return const {};
    }
  }

  Future<void> setPluginSettings(
    String pluginId,
    Map<String, Object?> values,
  ) async {
    final key = _pluginSettingsKey(pluginId);
    if (values.isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, jsonEncode(values));
    }
    notifyListeners();
  }

  static String _pluginSettingsKey(String pluginId) =>
      'plugins.settings.$pluginId';

  /// How loud a sound is played, 0..1 — the application's own volume and
  /// nothing to do with the system's mixer.
  ///
  /// Remembered because it is a property of the person, not of the file: turning
  /// it down for one track and finding the next one at full scale is the one
  /// behaviour a player must not have. Seven tenths by default, which leaves
  /// somewhere to go up as well as down.
  double get soundVolume => _prefs.getDouble(_kSoundVolume) ?? 0.7;

  Future<void> setSoundVolume(double value) async {
    await _prefs.setDouble(_kSoundVolume, value.clamp(0.0, 1.0));
    notifyListeners();
  }

  /// What was last said about updating, and when the release folder was last
  /// read.
  ///
  /// A key per fact rather than one blob: each is written on its own occasion,
  /// and a blob makes the answers overwrite each other. Times are ISO-8601
  /// strings, as everywhere else that remembers a moment here.
  ///
  /// No [notifyListeners]: nothing on screen is drawn from this. It is read at
  /// a start and written when somebody answers a window.
  UpdatePrompt get updatePrompt => UpdatePrompt(
        staying: _prefs.getString(_kUpdateStaying),
        postponed: _prefs.getString(_kUpdatePostponed),
        remindAfter:
            DateTime.tryParse(_prefs.getString(_kUpdateRemindAfter) ?? ''),
        lastChecked:
            DateTime.tryParse(_prefs.getString(_kUpdateLastChecked) ?? ''),
      );

  Future<void> setUpdatePrompt(UpdatePrompt prompt) async {
    await _remember(_kUpdateStaying, prompt.staying);
    await _remember(_kUpdatePostponed, prompt.postponed);
    await _remember(_kUpdateRemindAfter, prompt.remindAfter?.toIso8601String());
    await _remember(_kUpdateLastChecked, prompt.lastChecked?.toIso8601String());
  }

  /// Writes a value, or forgets the key when there is none. A cleared answer
  /// has to leave nothing behind, or it comes back at the next start.
  Future<void> _remember(String key, String? value) =>
      value == null ? _prefs.remove(key) : _prefs.setString(key, value);

  /// Whether a sound is looked at as frequencies rather than as loudness.
  ///
  /// One setting for the viewer rather than one per file, and for the reason
  /// the slide panel's is: somebody who reads spectra reads them, and a way of
  /// looking that depends on which file you opened is one nobody can rely on.
  bool get soundSpectrum => _prefs.getBool(_kSoundSpectrum) ?? false;

  Future<void> setSoundSpectrum(bool value) async {
    await _prefs.setBool(_kSoundSpectrum, value);
    notifyListeners();
  }

  /// Command ids in the order their icons sit in the title bar.
  ///
  /// Only the ones the user has moved. A command that is not named here goes
  /// after those that are, by title, so installing a plugin does not disturb
  /// an order someone arranged.
  List<String> get titleBarOrder =>
      _prefs.getStringList(_kTitleBarOrder) ?? const [];

  Future<void> setTitleBarOrder(List<String> commandIds) async {
    await _prefs.setStringList(_kTitleBarOrder, commandIds);
    notifyListeners();
  }
}
