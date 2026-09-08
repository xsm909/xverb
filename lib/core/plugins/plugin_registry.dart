import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../i18n/i18n.dart';
import '../i18n/plugin_strings.dart';
import '../vfs/file_entry.dart';
import '../vfs/fs_registry.dart';
import '../vfs/vfs_path.dart';
import 'declarative/declarative_renderer.dart';
import 'declarative/render_spec.dart';
import 'grammar.dart';
import 'grammar_folder.dart';
import 'facts.dart';
import 'plugin_manifest.dart';
import 'plugin_source.dart';
import 'remote_fs_provider.dart';
import 'rpc/json_rpc.dart';
import 'rpc/python_plugin_host.dart';
import 'rpc/python_runtime.dart';
import 'view.dart';
import 'viewer.dart';

/// An archive type something switched on can *create*.
///
/// A manifest's container declaration plus the fact that its scheme is running
/// and will take a write. Neither half is enough on its own, which is why this
/// is assembled at the moment it is asked for rather than kept in a table.
@immutable
class PackFormat {
  const PackFormat({
    required this.scheme,
    required this.extension,
    required this.title,
  });

  /// The scheme the archive is written through, e.g. `zip`.
  final String scheme;

  /// The extension a new archive of this type is given, without the dot.
  final String extension;

  /// What to call it where a person reads it — the container's own title.
  final String title;
}

/// Lifecycle state of a discovered plugin.
enum PluginState {
  /// Found on disk, not started.
  discovered,

  starting,

  /// Running, with its schemes and commands registered.
  active,

  /// Turned off by the user; it will not start on launch.
  disabled,

  /// Built against a different API version.
  incompatible,

  /// Declares platforms that do not include this one, needs a runtime that is
  /// unavailable here, or names a runtime this build does not know.
  unsupported,

  /// Crashed or refused to start; [PluginEntry.error] says why.
  failed,
}

/// A plugin as the plugin manager sees it.
class PluginEntry {
  PluginEntry({required this.manifest, required this.state, this.error});

  final PluginManifest manifest;
  PluginState state;
  String? error;
  PythonPluginHost? host;

  /// Schemes actually registered while running, which may be fewer than the
  /// manifest declares if another plugin already claimed one.
  List<String> activeSchemes = const [];

  /// Viewer ids this plugin currently provides.
  List<String> activeViewers = const [];

  /// View ids this plugin currently provides.
  List<String> activeViews = const [];

  /// Describer ids this plugin currently provides.
  List<String> activeDescribers = const [];

  bool get isActive => state == PluginState.active;
}

/// Where a plugin's command is offered.
///
/// The plugin's manifest states what it would like; this is what the user
/// decided, and the user wins. A command is in the Tools menu unless it was
/// taken out, because a command reachable from nowhere may as well not be
/// registered — the title bar is the surface that has to be asked for.
enum CommandSurface {
  /// In the Tools menu only. The default for most commands.
  menu,

  /// An icon in the application's title bar, and nothing in the menu.
  titleBar,

  /// Both.
  both,

  /// Neither: installed and enabled, but not offered anywhere.
  hidden;

  bool get inMenu => this == menu || this == both;

  bool get inTitleBar => this == titleBar || this == both;

  String get label => switch (this) {
        CommandSurface.menu => tr('Tools menu'),
        CommandSurface.titleBar => tr('Title bar'),
        CommandSurface.both => tr('Tools menu and title bar'),
        CommandSurface.hidden => tr('Nowhere'),
      };

  /// What a stored value means, falling back to what the manifest asked for.
  static CommandSurface parse(Object? stored, {required bool wantsTitleBar}) {
    for (final surface in CommandSurface.values) {
      if (surface.name == stored) return surface;
    }
    return wantsTitleBar ? CommandSurface.both : CommandSurface.menu;
  }
}

/// Orders things the user arranged: what the arrangement names first, in the
/// order it names them, then everything else by title.
///
/// Never load order, which is what the file system happens to return, so the
/// row would rearrange itself between launches. Something the order says
/// nothing about goes to the end rather than into the middle of an
/// arrangement someone made.
List<T> sortByArrangement<T>(
  Iterable<T> items,
  List<String> order, {
  required String Function(T item) idOf,
  required String Function(T item) titleOf,
}) {
  final sorted = items.toList()
    ..sort((a, b) {
      final left = order.indexOf(idOf(a));
      final right = order.indexOf(idOf(b));
      if (left != right) {
        if (left < 0) return 1;
        if (right < 0) return -1;
        return left.compareTo(right);
      }
      return titleOf(a).toLowerCase().compareTo(titleOf(b).toLowerCase());
    });
  return List.unmodifiable(sorted);
}

/// Orders the icons in the title bar.
List<PluginCommand> sortForTitleBar(
  Iterable<PluginCommand> commands,
  List<String> order,
) =>
    sortByArrangement(
      commands,
      order,
      idOf: (command) => command.spec.id,
      titleOf: (command) => command.spec.title,
    );

/// [current] with [commandId] moved [by] places, or null when nothing moves.
///
/// The result is written out in full from what is actually on the bar, so ids
/// left behind by a removed plugin do not accumulate in the settings.
List<String>? reorderTitleBar(List<String> current, String commandId, int by) {
  final from = current.indexOf(commandId);
  if (from < 0 || current.length < 2) return null;

  final to = (from + by).clamp(0, current.length - 1);
  if (to == from) return null;

  return [...current]
    ..removeAt(from)
    ..insert(to, commandId);
}

/// Files things under the category of the plugin that gave each one, with the
/// categories and their contents in alphabetical order.
///
/// A function of its inputs, so the ordering can be checked without starting
/// a plugin — which needs a Python process, and none of this is about that.
Map<String, List<T>> groupByCategory<T>(
  Iterable<T> items,
  String Function(String pluginId) categoryOf, {
  required String Function(T item) pluginIdOf,
  required String Function(T item) titleOf,
}) {
  final grouped = <String, List<T>>{};
  for (final item in items) {
    grouped.putIfAbsent(categoryOf(pluginIdOf(item)), () => []).add(item);
  }

  final shelves = grouped.keys.toList()..sort();
  return {
    for (final shelf in shelves)
      shelf: grouped[shelf]!
        ..sort((a, b) =>
            titleOf(a).toLowerCase().compareTo(titleOf(b).toLowerCase())),
  };
}

/// Files commands under the category of the plugin that gave each one.
Map<String, List<PluginCommand>> groupCommandsByCategory(
  Iterable<PluginCommand> commands,
  String Function(String pluginId) categoryOf,
) =>
    groupByCategory(
      commands,
      categoryOf,
      pluginIdOf: (command) => command.pluginId,
      titleOf: (command) => command.spec.title,
    );

/// A command or a view, as the menus and the title bar see it.
///
/// The two are different things — a command does something and is over, a view
/// is something you look at and come back to — but every surface that lists
/// them by name treats them alike, and the alternative was writing the ordering
/// and the grouping twice.
class PluginOffer {
  const PluginOffer.command(PluginCommand this.command) : view = null;

  const PluginOffer.view(RegisteredView this.view) : command = null;

  final PluginCommand? command;
  final RegisteredView? view;

  bool get isView => view != null;

  // Every one of these asks which of the two this is, rather than reaching for
  // the first non-null answer. `command?.spec.icon ?? view!.spec.icon` reads
  // the same and is not: a command without an icon is null there, so it fell
  // through to a view that does not exist. The Tools menu threw on the first
  // command that had not asked for an icon — which is most of them — and drew
  // its shelves with nothing under them.
  String get id => isView ? view!.spec.id : command!.spec.id;
  String get title => isView ? view!.spec.title : command!.spec.title;
  String? get icon => isView ? view!.spec.icon : command!.spec.icon;
  String? get description =>
      isView ? view!.spec.description : command!.spec.description;
  String get pluginId => isView ? view!.pluginId : command!.pluginId;
}

/// A command contributed by a plugin, invocable from the UI.
class PluginCommand {
  const PluginCommand({
    required this.spec,
    required this.pluginId,
    required this.invoke,
  });

  final PluginCommandSpec spec;
  final String pluginId;
  final Future<Object?> Function(Map<String, dynamic> args) invoke;

  /// What to call this command in a menu, in the language now in force.
  String get title => saidBy(pluginId, spec.title);

  String? get description => saidByOrNull(pluginId, spec.description);
}

/// Discovers plugins on disk, starts them, and wires what they provide into
/// the rest of the app.
///
/// This is the extension point the whole project is built around: the core only
/// ships a local file system, and everything else — FTP, SMB, archive support,
/// custom commands — arrives here.
class PluginRegistry extends ChangeNotifier {
  PluginRegistry({required this.fileSystems}) {
    // The renderer asks *this* which language a file is in, rather than
    // holding grammars of its own: they belong to whichever plugin brought
    // them, and a plugin can be switched off while a file is open.
    _declarative = DeclarativeRenderer(
      fileSystems,
      languageOf: (extension, name) =>
          grammarForExtension(extension, name: name)?.id ?? '',
    );
  }

  final FileSystemRegistry fileSystems;
  late final DeclarativeRenderer _declarative;

  /// Index of the extensions shipped inside the app, relative to the asset
  /// root. Bundled extensions are ordinary plugins that happen to travel with
  /// the binary, the way Blender ships add-ons alongside user scripts.
  static const String bundledIndexAsset = 'assets/plugins/index.json';

  final Map<String, PluginEntry> _entries = {};

  /// Bundled manifests that an installed copy is standing in front of, by id.
  /// Rebuilt by [discover]; see [shippedBehind] for what it is for.
  final Map<String, PluginManifest> _shipped = {};

  /// The languages read out of each plugin's `grammars/` folder, by plugin id.
  ///
  /// Kept here rather than on the manifest because a manifest is what
  /// `plugin.json` said and does not change, while these are files that can be
  /// replaced under a running application — see [reloadGrammars].
  final Map<String, List<SyntaxGrammar>> _grammarFiles = {};
  final Map<String, PluginCommand> _commands = {};
  final Map<String, RegisteredView> _views = {};
  final Map<String, RegisteredViewer> _viewers = {};
  final Map<String, RegisteredDescriber> _describers = {};
  final List<PluginLogRecord> _log = [];

  /// Redraws pushed by views that did not wait to be asked. One stream for
  /// every plugin: whoever is holding a session listens for its own, and an
  /// update nobody is holding falls on the floor, which is exactly right for a
  /// scan still running after its view was closed.
  final StreamController<ViewUpdate> _viewUpdates =
      StreamController<ViewUpdate>.broadcast();

  PythonRuntime? _runtime;
  Directory? _pluginsDirectory;

  /// Most recent messages from plugins, newest last. Bounded so a chatty
  /// plugin cannot grow the heap without limit.
  static const int maxLogRecords = 500;

  List<PluginEntry> get entries => _entries.values.toList(growable: false);

  List<PluginCommand> get commands => _commands.values.toList(growable: false);

  List<RegisteredView> get views => _views.values.toList(growable: false);

  /// The view with this id, or null when nothing running provides it.
  RegisteredView? view(String id) => _views[id];

  /// Commands the user has in the application's title bar, in the order they
  /// arranged — and by title for any the order says nothing about.
  ///
  /// Never by load order: which plugin starts first depends on the file
  /// system, so the row would rearrange itself between launches.
  List<PluginCommand> get titleBarCommands => sortForTitleBar(
        _commands.values.where((c) => surfaceFor(c).inTitleBar),
        titleBarOrder,
      );

  /// Everything on the title bar — commands and views together, arranged in
  /// one row because that is what the user sees. One order list covers both:
  /// the icons sit side by side, so ordering them separately would let the two
  /// halves shuffle past each other.
  List<PluginOffer> get titleBarOffers => sortByArrangement(
        [
          for (final command in _commands.values)
            if (surfaceFor(command).inTitleBar) PluginOffer.command(command),
          for (final view in _views.values)
            if (surfacesForView(view).contains(PluginSurface.titleBar))
              PluginOffer.view(view),
        ],
        titleBarOrder,
        idOf: (offer) => offer.id,
        titleOf: (offer) => offer.title,
      );

  /// Command ids in the order their icons sit in the title bar. Persisted by
  /// the settings store; commands not named here follow, in title order.
  List<String> titleBarOrder = const [];

  Future<void> Function(List<String> order)? onTitleBarOrderChanged;

  /// Moves one icon along the row by [by] places.
  Future<void> moveTitleBarCommand(String commandId, int by) async {
    final order = reorderTitleBar(
      titleBarOffers.map((offer) => offer.id).toList(),
      commandId,
      by,
    );
    if (order == null) return;

    titleBarOrder = order;
    await onTitleBarOrderChanged?.call(order);
    notifyListeners();
  }

  /// Keys the host keeps in a plugin's settings for its own purposes, such as
  /// where each command appears. Reserved: a plugin must not declare one, and
  /// they are stripped from what the plugin is told.
  static const String hostKeyPrefix = 'host.';

  static const String surfaceKeyPrefix = '${hostKeyPrefix}surface.';

  /// Where [command] is offered — the user's choice, or the manifest's wish.
  CommandSurface surfaceFor(PluginCommand command) => CommandSurface.parse(
        storedSettings(command.pluginId)['$surfaceKeyPrefix${command.spec.id}'],
        wantsTitleBar: command.spec.inTitleBar,
      );

  /// The same for a command that has been declared but is not running, which
  /// is what the settings form is editing.
  CommandSurface declaredSurfaceFor(String pluginId, PluginCommandSpec spec) =>
      CommandSurface.parse(
        storedSettings(pluginId)['$surfaceKeyPrefix${spec.id}'],
        wantsTitleBar: spec.inTitleBar,
      );

  /// Where a view's surfaces are kept. A separate prefix from a command's
  /// because the two answer different questions — a command is in one place, a
  /// view can be in several — and because nothing stops a plugin from giving a
  /// command and a view the same id.
  static const String viewSurfaceKeyPrefix = '${hostKeyPrefix}views.';

  /// Where a view appears: what the user chose, narrowed to what the view says
  /// it can do.
  ///
  /// The narrowing is the rule, not a precaution. Surfaces are stored by name,
  /// so a view that drops one in a later version would otherwise go on being
  /// offered somewhere it can no longer be drawn.
  List<PluginSurface> surfacesForView(RegisteredView view) =>
      declaredSurfacesForView(view.pluginId, view.spec);

  /// The same for a view read off a manifest, which is what the settings form
  /// edits — it has to work for a plugin that is not running.
  List<PluginSurface> declaredSurfacesForView(String pluginId, ViewSpec spec) {
    final stored = storedSettings(pluginId)['$viewSurfaceKeyPrefix${spec.id}'];

    // Nothing stored means the plugin's own declaration stands. Every surface
    // a view names is one it asked for, so there is nothing to hold back.
    if (stored is! String) return spec.surfaces;

    final chosen = stored.split(',').map((name) => name.trim()).toSet();
    return [
      for (final surface in spec.surfaces)
        if (chosen.contains(surface.name)) surface,
    ];
  }

  /// The stored form of a choice: surface names, comma separated. An empty
  /// string is a real answer — "nowhere" — and is why this is not simply the
  /// absence of a value.
  static String formatViewSurfaces(Iterable<PluginSurface> surfaces) =>
      surfaces.map((surface) => surface.name).join(',');

  /// Views the user can reach through [surface], by title.
  List<RegisteredView> viewsIn(PluginSurface surface) => sortByArrangement(
        _views.values.where((view) => surfacesForView(view).contains(surface)),
        surface == PluginSurface.titleBar ? titleBarOrder : const [],
        idOf: (view) => view.spec.id,
        titleOf: (view) => view.spec.title,
      );

  /// Every command, filed under the category of the plugin that gave it, with
  /// the categories and the commands inside each in alphabetical order.
  ///
  /// This is what the Tools menu is built from. Grouping by the plugin's own
  /// category rather than by plugin means two small plugins doing the same
  /// kind of thing land together instead of each getting a submenu of one.
  Map<String, List<PluginCommand>> get commandsByCategory =>
      groupCommandsByCategory(
        _commands.values.where((c) => surfaceFor(c).inMenu),
        (pluginId) => _entries[pluginId]?.manifest.category ?? 'Tools',
      );

  /// The Tools menu: commands and views on the same shelves.
  ///
  /// A view sits beside a command because from the menu they read the same —
  /// a name you pick. What happens next differs, and that is the menu's caller's
  /// problem, not the user's.
  Map<String, List<PluginOffer>> get menuOffersByCategory => groupByCategory(
        [
          for (final command in _commands.values)
            if (surfaceFor(command).inMenu) PluginOffer.command(command),
          for (final view in _views.values)
            if (surfacesForView(view).contains(PluginSurface.menu))
              PluginOffer.view(view),
        ],
        (pluginId) => _entries[pluginId]?.manifest.category ?? 'Tools',
        pluginIdOf: (offer) => offer.pluginId,
        titleOf: (offer) => offer.title,
      );

  List<RegisteredViewer> get viewers => _viewers.values.toList(growable: false);

  /// Connection kinds every discovered plugin declares.
  ///
  /// Read from manifests rather than from running plugins on purpose: a
  /// transport that cannot start — no interpreter installed, say — should
  /// still let its connections be set up, and fail with something honest at
  /// connect time rather than hiding the dialog.
  List<ConnectionSpec> get connectionSpecs => [
        for (final entry in _entries.values)
          if (entry.state != PluginState.disabled &&
              entry.manifest.supportsCurrentPlatform())
            ...entry.manifest.connections,
      ];

  /// The scheme a file of this type is browsed under, or null when nothing
  /// claims it as a folder.
  ///
  /// Only counts if the plugin is actually serving that scheme: a declaration
  /// from a transport that failed to start must not turn Enter on an archive
  /// into a dead end. That check is the registry's caller's — see
  /// [FileSystemRegistry.supports].
  String? containerSchemeFor(String extension) {
    if (extension.isEmpty) return null;
    for (final entry in _entries.values) {
      if (entry.state == PluginState.disabled) continue;
      if (!entry.manifest.supportsCurrentPlatform()) continue;
      for (final container in entry.manifest.containers) {
        if (container.handles(extension)) return container.scheme;
      }
    }
    return null;
  }

  /// Container types a *new* archive can be made in, best first.
  ///
  /// Three conditions, and all three have to hold at the moment the menu is
  /// drawn: a switched-on plugin declares the type **in `packs`**, its scheme is
  /// actually being served, and that scheme is writable. The last one is what
  /// will keep RAR out of this list without anybody writing RAR's name here —
  /// nothing free can create one, so the plugin that reads them will say it is
  /// read-only and it will simply not be offered.
  ///
  /// The first condition is `packs` and nothing else. It used to fall back to
  /// the first extension a container claimed, and that offered *Playlist ·
  /// .m3u* as a kind of archive: the playlist plugin opens an `.m3u` as a
  /// folder and cannot write one, so packing into it failed on the first file
  /// and on all fifty-seven after it.
  ///
  /// ZIP first where a plugin offers it. Not a favour to ZIP: it is the archive
  /// every desktop this application runs on can open without installing
  /// anything, so it is the safe thing to hand somebody who has not said what
  /// they want.
  List<PackFormat> get packFormats {
    final formats = <PackFormat>[];
    for (final entry in _entries.values) {
      if (entry.state == PluginState.disabled) continue;
      if (!entry.manifest.supportsCurrentPlatform()) continue;
      for (final container in entry.manifest.containers) {
        final provider = fileSystems.lookup(container.scheme);
        if (provider == null || !provider.isWritable) continue;
        for (final option in container.packs) {
          if (option.extension.isEmpty) continue;
          formats.add(PackFormat(
            scheme: container.scheme,
            extension: option.extension,
            title: option.title,
          ));
        }
      }
    }

    // ZIP first, and **otherwise the order the plugin wrote them in**: the four
    // ways to make a tarball are a sentence about compression, and alphabetical
    // order would shuffle the sentence. A stable sort keeps what the manifest
    // said.
    final zipFirst = [
      ...formats.where((f) => f.extension == 'zip'),
      ...formats.where((f) => f.extension != 'zip'),
    ];
    return zipFirst;
  }

  /// The scheme a new archive called [name] would be written under, or null
  /// when nothing switched on can write one.
  ///
  /// The typed name decides the format, exactly as the name on disk decides
  /// that Enter opens it as a folder — one rule, asked twice.
  String? packSchemeFor(String name) {
    final extension = FileEntry.extensionOf(name);
    if (extension.isEmpty) return null;
    for (final format in packFormats) {
      if (format.scheme == containerSchemeFor(extension)) return format.scheme;
    }
    return null;
  }

  /// The grammar for a language, or null when nothing has declared one.
  ///
  /// Asked of the manifests each time rather than kept in a table of its own:
  /// a grammar is data on a plugin that can be switched off while the viewer
  /// is open, and a table would go on colouring by a language nobody offers
  /// any more. There are a handful of plugins and it is a walk over a list.
  SyntaxGrammar? grammarFor(String language) {
    if (language.isEmpty) return null;
    final asked = language.toLowerCase();
    for (final grammar in _grammars) {
      if (grammar.id == asked) return grammar;
    }
    return null;
  }

  /// The grammar a file is written in, for a viewer that says "colour it by
  /// its name" rather than naming a language itself.
  ///
  /// By whole name as well as by extension, because some files are known by
  /// their name and have none — `LICENSE`, `Makefile`, `Dockerfile`.
  SyntaxGrammar? grammarForExtension(String extension, {String name = ''}) {
    if (extension.isEmpty && name.isEmpty) return null;
    for (final grammar in _grammars) {
      if (grammar.handles(extension, name: name)) return grammar;
    }
    return null;
  }

  /// Every language on offer, from every plugin that is switched on.
  Iterable<SyntaxGrammar> get _grammars sync* {
    for (final entry in _entries.values) {
      if (entry.state == PluginState.disabled) continue;
      if (!entry.manifest.supportsCurrentPlatform()) continue;
      yield* grammarsOf(entry.manifest.id);
    }
  }

  /// The languages one plugin brought — its folder first, then anything its
  /// manifest still declares inline.
  List<SyntaxGrammar> grammarsOf(String pluginId) => mergeGrammars(
        _grammarFiles[pluginId] ?? const [],
        _entries[pluginId]?.manifest.grammars ?? const [],
      );

  /// Re-reads every plugin's grammar folder, leaving everything else alone.
  ///
  /// **This is the whole point of a grammar being a file of its own.** A
  /// language is data: correcting one, or adding one nobody had written, must
  /// not cost a restart, and it has nothing to do with a plugin's process — a
  /// Python plugin keeps running across this, and a viewer keeps whatever it
  /// was showing. What changes is only what the next file is coloured by.
  Future<void> reloadGrammars() async {
    for (final entry in _entries.values.toList()) {
      await _readGrammarsOf(entry.manifest);
    }
    notifyListeners();
  }

  /// Fills in [_grammarFiles] for one plugin, from wherever it lives.
  Future<void> _readGrammarsOf(PluginManifest manifest) async {
    void problem(String file, Object error) => _appendLog(PluginLogRecord(
          manifest.id,
          'error',
          'Grammar $file: $error',
        ));

    final grammars = manifest.isBundled
        ? await readBundledGrammarFolder(manifest.directory, onProblem: problem)
        : await readGrammarFolder(manifest.directory, onProblem: problem);
    if (grammars.isEmpty) {
      _grammarFiles.remove(manifest.id);
    } else {
      _grammarFiles[manifest.id] = grammars;
    }
  }

  /// What the plugin manager lists under a plugin: the languages it brought.
  List<SyntaxGrammar> get grammars => _grammars.toList();

  /// Viewers that claim [extension], best match first.
  ///
  /// **Whoever names this type comes first**, whatever their priority, so an
  /// image plugin wins over anything that merely takes what is left. Among
  /// those that name it, and again among those that do not, the higher
  /// priority wins.
  ///
  /// The test is "does it name *this* extension", not "is it a fallback
  /// viewer": one viewer may do both — the text viewer names what it is really
  /// for and still takes a file nobody knows, which is what keeps an unknown
  /// file out of the hex dump.
  List<RegisteredViewer> viewersFor(String extension, {String name = ''}) {
    final matches = _viewers.values
        .where((viewer) => viewer.spec.handles(extension, name: name))
        .toList();
    matches.sort((a, b) {
      final named = a.spec.claims(extension, name: name);
      if (named != b.spec.claims(extension, name: name)) return named ? -1 : 1;
      return b.spec.priority.compareTo(a.spec.priority);
    });
    return matches;
  }

  /// Puts a viewer in by hand. **For tests only** — in the application these
  /// arrive from what a plugin declared, and there is no other way in.
  @visibleForTesting
  void addViewerForTest(RegisteredViewer viewer) => _viewers[viewer.id] = viewer;

  /// Who can say what [entry] says about itself, or null where nobody can.
  ///
  /// **One answer, not a list.** A file has one set of facts, so this is not a
  /// race between plugins the way opening one is: the first describer that
  /// claims the name answers, and two plugins claiming the same format is a
  /// collision in the collection rather than an order to settle at run time.
  RegisteredDescriber? describerFor(FileEntry entry) {
    for (final describer in _describers.values) {
      if (describer.spec.claims(entry.name)) return describer;
    }
    return null;
  }

  /// Puts a describer in by hand. **For tests only.**
  @visibleForTesting
  void addDescriberForTest(RegisteredDescriber describer) =>
      _describers[describer.id] = describer;

  /// How much of a file a probing viewer is shown.
  ///
  /// Enough for any of these formats to recognise itself — a workflow says what
  /// it is in its first keys — and small enough that asking costs nothing worth
  /// measuring. A reader that cannot tell from this much is a reader that would
  /// be guessing from the whole file too.
  static const int probeBytes = 64 * 1024;

  /// How long a viewer has to answer. **A key press must not wait for a
  /// plugin**: whoever is late is simply not asked about this file, and the
  /// order falls back to the extensions, which is what it was before.
  static const Duration probeTimeout = Duration(milliseconds: 900);

  /// How long a plugin has to make one small picture.
  ///
  /// Longer than a probe, because this is real work — a Photoshop file is
  /// composited before it can be shrunk — and shorter than a viewer, because
  /// a strip that stalls is worse than a strip with a name in one cell.
  static const Duration thumbnailTimeout = Duration(seconds: 8);

  /// The viewers for [entry], best match first, **after asking the ones that
  /// wanted to see the file**.
  ///
  /// The order from [viewersFor] with one change: a viewer that declared a
  /// probe and answered "mine" moves ahead of everything that claimed by
  /// extension alone. That is the whole of segment 7 — a node graph is a
  /// `.json`, `.json` is the text viewer's by right, and only the reader can
  /// say that *this* `.json` is a workflow.
  ///
  /// Nothing is asked when no candidate declared a probe, which is every file
  /// in the application but a handful.
  Future<List<RegisteredViewer>> viewersForFile(FileEntry entry) async {
    final ordered = viewersFor(entry.typeName, name: entry.name);
    final asking = [
      for (final viewer in ordered)
        if (viewer.probe != null) viewer,
    ];
    if (asking.isEmpty) return ordered;

    final head = await _firstBytesOf(entry.path, probeBytes);
    if (head == null || head.isEmpty) return ordered;

    final claimed = <String>{};
    await Future.wait([
      for (final viewer in asking)
        viewer
            .probe!(entry.path, head)
            .then((yes) {
              if (yes) claimed.add(viewer.id);
            })
            // A reader that throws has not claimed anything. It is a question,
            // not an operation: the only wrong answer is a stuck one.
            .catchError((Object _) {}),
    ]).timeout(probeTimeout, onTimeout: () => const []);

    if (claimed.isEmpty) return ordered;
    return [
      for (final viewer in ordered)
        if (claimed.contains(viewer.id)) viewer,
      for (final viewer in ordered)
        if (!claimed.contains(viewer.id)) viewer,
    ];
  }

  /// The first [bytes] of a file, or null when it cannot be read.
  ///
  /// Through the provider that owns the path, so a file inside an archive or a
  /// commit is probed the same way one on a disk is.
  Future<List<int>?> _firstBytesOf(VfsPath path, int bytes) async {
    try {
      final provider = fileSystems.resolve(path);
      final head = <int>[];
      await for (final chunk in provider.openRead(path, start: 0, end: bytes)) {
        head.addAll(chunk);
        if (head.length >= bytes) break;
      }
      return head;
    } on Object {
      return null;
    }
  }

  List<PluginLogRecord> get log => List.unmodifiable(_log);

  PythonRuntime? get runtime => _runtime;

  /// Null when Python was found; otherwise why *Python* plugins cannot run.
  /// Declarative extensions are unaffected.
  String? get runtimeProblem => _runtime == null ? PythonRuntime.lastError : null;

  /// Where users drop plugin folders. Null before [initialize] completes.
  String? get pluginsPath => _pluginsDirectory?.path;

  /// Plugin ids the user switched off. Persisted by the settings store.
  Set<String> disabled = <String>{};

  /// Called whenever [disabled] changes so it can be written to settings.
  Future<void> Function(Set<String> disabled)? onDisabledChanged;

  /// Which shipped plugins have already been handed over, and where to write
  /// that down. Without them nothing is seeded, which is what the tests want.
  Set<String> Function()? loadSeeded;
  Future<void> Function(Set<String> seeded)? onSeededChanged;

  /// Reads back what the user last saved for a plugin's own settings. Without
  /// one every plugin simply runs on its declared defaults, which is what the
  /// tests and the first launch after an install both want.
  Map<String, Object?> Function(String pluginId)? loadSettings;

  /// Called with the changed values so they can be written to settings.
  Future<void> Function(String pluginId, Map<String, Object?> values)?
      onSettingsChanged;

  /// Read-through cache over [loadSettings], so a running plugin's settings do
  /// not go back to disk on every rebuild of the manager.
  final Map<String, Map<String, Object?>> _settings = {};

  /// What the user changed, without the plugin's defaults underneath. This is
  /// what the settings form edits and what gets stored.
  Map<String, Object?> storedSettings(String pluginId) =>
      Map.of(_settings[pluginId] ??= Map.of(loadSettings?.call(pluginId) ?? {}));

  /// What the plugin actually runs on: its declared defaults, with the user's
  /// changes on top.
  ///
  /// The host's own keys are not among them. Where a command appears is the
  /// app's business, kept in the same place only because that is where a
  /// plugin's choices are already stored.
  /// A plugin's own picture, if it ships one: the file its manifest's `icon`
  /// names, beside its `plugin.json`.
  ///
  /// **A name or a file, and which is decided by what it looks like.** The set
  /// of icon names the host draws is small on purpose — it keeps a menu of
  /// plugins looking like one menu — but a tool with a mark of its own is
  /// recognised before it is read, and a git tool that draws a generic glyph
  /// is a git tool nobody spots. Anything with a dot in it is a file; anything
  /// else is one of the host's shapes.
  String? iconFileFor(String pluginId, String? icon) {
    if (icon == null || !icon.contains('.')) return null;
    // Only beside the manifest: an icon path is not a way to read the disk.
    if (icon.contains('/') || icon.contains(r'\')) return null;
    final directory = _entries[pluginId]?.manifest.directory;
    if (directory == null) return null;
    return '$directory${Platform.pathSeparator}$icon';
  }

  Map<String, Object?> settingsFor(String pluginId) {
    final manifest = _entries[pluginId]?.manifest;
    final values = <String, Object?>{
      ...?manifest?.settingDefaults,
      ...storedSettings(pluginId),
    };
    values.removeWhere((key, _) => key.startsWith(hostKeyPrefix));
    return values;
  }

  /// Saves a plugin's settings and tells it, if it is running.
  ///
  /// A stopped plugin needs no telling: it reads the values in its handshake
  /// the next time it starts.
  Future<void> setSettings(
    String pluginId,
    Map<String, Object?> values,
  ) async {
    _settings[pluginId] = Map.of(values);
    await onSettingsChanged?.call(pluginId, values);

    final host = _entries[pluginId]?.host;
    if (host != null && host.isRunning) {
      host.channel.notify(
        'settings.changed',
        params: {'settings': settingsFor(pluginId)},
      );
    }
    notifyListeners();
  }

  /// Loads bundled extensions, finds the user plugins directory, detects
  /// Python, then starts everything that is enabled.
  ///
  /// Safe to call when Python is missing or impossible: declarative extensions
  /// still load, so even iOS gets working viewers.
  Future<void> initialize({Set<String> disabledIds = const {}}) async {
    disabled = Set.of(disabledIds);
    _pluginsDirectory = await _resolvePluginsDirectory();
    _runtime = await PythonRuntime.detect();
    await _seedShipped();
    await rescan();
  }

  /// Where the plugins folder is, for a test that must not write into the
  /// one belonging to the machine it runs on.
  @visibleForTesting
  set pluginsDirectoryForTest(Directory directory) =>
      _pluginsDirectory = directory;

  /// Where to look for installed plugins, for a test that must not see
  /// whatever the developer happens to have installed.
  @visibleForTesting
  List<Directory>? searchPathsForTest;

  /// [_seedShipped], for a test.
  @visibleForTesting
  Future<void> seedForTest() => _seedShipped();

  /// Puts a view in the register without a plugin behind it.
  ///
  /// For tests that are about what the *host* does with a view — opening one
  /// again after it handed its panel over, say — rather than about running a
  /// plugin. Registering is what makes a view findable by id, which is how
  /// anything reopens it.
  @visibleForTesting
  void registerViewForTest(RegisteredView view) => _views[view.id] = view;

  /// Lays the shipped copies down in the plugins folder, once each.
  ///
  /// **The store owns them from then on.** The application still carries a
  /// first copy, because
  /// the core cannot view a file on its own and a fresh install with no viewer
  /// at all is an application that opens nothing — but once the copy is on
  /// disk it is an ordinary installed plugin, and the newer one from the store
  /// replaces it like any other.
  ///
  /// Once each, and remembered: a plugin the user deleted is a plugin they
  /// deleted, not one to put back on the next launch.
  Future<void> _seedShipped() async {
    final directory = _pluginsDirectory;
    if (directory == null) return;

    final already = Set.of(loadSeeded?.call() ?? const <String>{});
    final laid = <String>{};

    for (final folder in await _shippedFolders()) {
      if (already.contains(folder)) continue;
      final target = Directory(p.join(directory.path, folder));
      // Somebody has one already — from the store, or from a build before this
      // one. Nothing to hand over.
      if (await target.exists()) {
        laid.add(folder);
        continue;
      }
      try {
        await _copyShipped(folder, target);
        laid.add(folder);
        _appendLog(PluginLogRecord(folder, 'info', 'Installed the copy that '
            'ships with the application; the store updates it from here.'));
      } on Object catch (e) {
        _appendLog(PluginLogRecord(folder, 'error', 'Could not install the '
            'copy that ships with the application: $e'));
      }
    }

    if (laid.isNotEmpty) {
      await onSeededChanged?.call(already..addAll(laid));
    }
  }

  Future<List<String>> _shippedFolders() async {
    try {
      final index = jsonDecode(await rootBundle.loadString(bundledIndexAsset));
      return (index as List).cast<String>();
    } on Object {
      // No shipped extensions in this build; not an error.
      return const [];
    }
  }

  /// Writes every file of one shipped plugin into [target].
  ///
  /// Asked of the asset manifest rather than assuming a `plugin.json` and
  /// nothing else: a plugin may carry an icon, and one that lost it on the way
  /// out of the bundle would be a plugin the manager draws blank.
  Future<void> _copyShipped(String folder, Directory target) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final prefix = 'assets/plugins/$folder/';
    final files = manifest.listAssets().where((a) => a.startsWith(prefix));

    await target.create(recursive: true);
    for (final asset in files) {
      final data = await rootBundle.load(asset);
      final out = File(p.join(target.path, asset.substring(prefix.length)));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      ));
    }
  }

  /// Rescans both sources and starts whatever turned up.
  ///
  /// What "refresh" means to someone who just dropped a folder into the
  /// plugins directory: they expect the plugin, not a row saying it was found.
  /// [discover] on its own leaves it sitting at [PluginState.discovered], which
  /// registers no schemes and no commands — the plugin exists in the list and
  /// does nothing until the app is restarted.
  Future<void> rescan() async {
    await discover();
    await startEnabled();
  }

  /// Rescans both sources without restarting anything already running.
  Future<void> discover() async {
    // **Installed first.** What the store put on the disk is the newer copy of
    // the same plugin — the one the application ships is only ever the first
    // one — so it wins, and the shipped copy fills in for anything that is not
    // there at all.
    _shipped.clear();
    await _discoverInstalled();
    await _discoverBundled();
    await refreshStrings();
    notifyListeners();
  }

  /// Reads every plugin's own catalogue for the language now in force.
  ///
  /// Called after discovery and again whenever the language changes — see
  /// `plugin_strings.dart`. A plugin with no catalogue for this language is
  /// the ordinary case and costs one failed open.
  Future<void> refreshStrings() async {
    clearPluginStrings();
    for (final entry in _entries.values) {
      final manifest = entry.manifest;
      setPluginStrings(
        manifest.id,
        await readPluginStrings(
          directory: manifest.directory,
          isBundled: manifest.isBundled,
          code: activeLocalisation.code,
        ),
      );
    }
    notifyListeners();
  }

  /// Reads the extensions that ship inside the app bundle. These are always
  /// declarative, so there is nothing to unpack and nothing to execute.
  Future<void> _discoverBundled() async {
    List<String> directories;
    try {
      final index = jsonDecode(await rootBundle.loadString(bundledIndexAsset));
      directories = (index as List).cast<String>();
    } on Object {
      // No bundled extensions in this build; not an error.
      return;
    }

    for (final directory in directories) {
      final asset = 'assets/plugins/$directory/plugin.json';
      try {
        final json = jsonDecode(await rootBundle.loadString(asset))
            as Map<String, dynamic>;
        final manifest = PluginManifest.fromJson(
          json,
          'assets/plugins/$directory',
          isBundled: true,
        );
        // Already there from the plugins folder, which is where it belongs —
        // but **remember that this copy exists**, because that changes what
        // removing the installed one means.
        //
        // Both extensions that ship in the bundle are also published in the
        // plugins repository under the same id, so anyone who has ever pressed
        // Install has a folder shadowing one of these. Removing that folder is
        // not "the plugin is gone": `discover` runs afterwards and this copy
        // takes its place, which is what pressing Remove and seeing the plugin
        // still listed looks like.
        final standing = _entries[manifest.id];
        if (standing != null) {
          // Only when what is standing there is an *installed* copy. Discovery
          // runs more than once — start-up, then again after every install —
          // and on the second pass this entry is the one the first pass put
          // here, so a bare `containsKey` records the bundled copy as standing
          // behind itself. Caught by its own test rather than in the app, where
          // it would have shown up as a Remove button offering to go back to
          // the version already running.
          if (!standing.manifest.isBundled) _shipped[manifest.id] = manifest;
          continue;
        }
        _entries[manifest.id] = PluginEntry(
          manifest: manifest,
          state: _initialStateFor(manifest),
        );
        await _readGrammarsOf(manifest);
      } on Object catch (e) {
        _appendLog(PluginLogRecord(directory, 'error', 'Bundled: $e'));
      }
    }
  }

  /// Every place an installed plugin may live, nearest first.
  ///
  /// The support directory is where plugins are installed to. A `plugins`
  /// folder beside the executable is also scanned, so a portable copy of the
  /// app — and a freshly built one, with the examples next to it — works
  /// without anyone having to know where the support directory is.
  ///
  /// In a debug build the working directory is scanned too. `flutter run` sets
  /// it to the project root, so a `plugins/` folder dropped in a checkout is
  /// picked up with no setup at all — which is how a plugin is worked on
  /// without installing it after every edit. Debug only on purpose: a released
  /// app must not load code out of whatever directory it happened to be
  /// started from.
  List<Directory> get pluginSearchPaths {
    final only = searchPathsForTest;
    if (only != null) return only;

    final paths = <Directory>[?_pluginsDirectory];

    final beside = Directory(
      p.join(p.dirname(Platform.resolvedExecutable), 'plugins'),
    );
    if (beside.existsSync()) paths.add(beside);

    if (kDebugMode) {
      final checkout = Directory(p.join(Directory.current.path, 'plugins'));
      if (checkout.existsSync() &&
          !paths.any((d) => p.equals(d.path, checkout.path))) {
        paths.add(checkout);
      }
    }
    return paths;
  }

  Future<void> _discoverInstalled() async {
    for (final directory in pluginSearchPaths) {
      await _discoverIn(directory);
    }
  }

  Future<void> _discoverIn(Directory directory) async {
    if (!await directory.exists()) return;

    await for (final child in directory.list(followLinks: false)) {
      if (child is! Directory) continue;
      if (p.basename(child.path).startsWith('_')) continue;
      if (!await File(p.join(child.path, 'plugin.json')).exists()) continue;

      try {
        final manifest = await PluginManifest.load(child);
        final existing = _entries[manifest.id];
        if (existing != null && existing.isActive) continue;

        // Search paths are ordered, so a copy found later loses. Without this
        // the same plugin shipped beside the executable would silently replace
        // the one the user installed.
        if (existing != null &&
            !existing.manifest.isBundled &&
            existing.manifest.directory != child.path) {
          continue;
        }

        _entries[manifest.id] = PluginEntry(
          manifest: manifest,
          state: _initialStateFor(manifest),
        );
        await _readGrammarsOf(manifest);
      } on Object catch (e) {
        _appendLog(PluginLogRecord(
          p.basename(child.path),
          'error',
          'Invalid plugin.json: $e',
        ));
      }
    }
  }

  /// Starts every discovered plugin that is enabled and supported.
  Future<void> startEnabled() async {
    for (final entry in entries) {
      if (entry.state != PluginState.discovered) continue;
      await start(entry.manifest.id);
    }
  }

  Future<void> start(String pluginId) async {
    final entry = _entries[pluginId];
    if (entry == null || entry.isActive) return;

    if (!entry.manifest.isCompatible) {
      entry
        ..state = PluginState.incompatible
        ..error = 'Plugin targets API ${entry.manifest.apiVersion}, '
            'this build speaks API $kPluginApiVersion.';
      notifyListeners();
      return;
    }

    switch (entry.manifest.runtime) {
      case PluginRuntime.declarative:
        _startDeclarative(entry);
      case PluginRuntime.python:
        await _startPython(entry);
      case PluginRuntime.unknown:
        entry
          ..state = PluginState.unsupported
          ..error = 'Unknown runtime; this build understands '
              'python and declarative.';
        notifyListeners();
    }
  }

  /// Declarative extensions need no process: their viewers are closures over
  /// the built-in render primitives, so starting one is just registration.
  void _startDeclarative(PluginEntry entry) {
    final registered = <String>[];

    for (final spec in entry.manifest.viewers) {
      final render = spec.render;
      if (render == null) {
        _appendLog(PluginLogRecord(
          entry.manifest.id,
          'warning',
          'Viewer "${spec.id}" has no render block; skipped.',
        ));
        continue;
      }

      final parsed = RenderSpec.fromJson(render);
      if (!parsed.isSupported) {
        _appendLog(PluginLogRecord(
          entry.manifest.id,
          'warning',
          'Viewer "${spec.id}" wants render kind "${parsed.kind}", '
              'which this build does not provide; skipped.',
        ));
        continue;
      }

      _viewers[spec.id] = RegisteredViewer(
        spec: spec,
        pluginId: entry.manifest.id,
        pluginName: entry.manifest.name,
        open: (path) => _declarative.render(path, parsed),
      );
      registered.add(spec.id);
    }

    entry
      ..activeViewers = registered
      ..activeSchemes = const []
      ..state = PluginState.active
      ..error = registered.isEmpty ? 'Contributed nothing usable.' : null;
    notifyListeners();
  }

  Future<void> _startPython(PluginEntry entry) async {
    final runtime = _runtime;
    if (runtime == null) {
      entry
        ..state = PluginState.unsupported
        ..error = PythonRuntime.lastError;
      notifyListeners();
      return;
    }

    // Refuse here rather than let the process start and die on syntax the
    // interpreter cannot parse — the traceback for that names a line number,
    // not the reason.
    if (!entry.manifest.acceptsPython(runtime.version)) {
      entry
        ..state = PluginState.unsupported
        ..error = 'Needs Python ${entry.manifest.pythonMin} or newer; '
            'the interpreter in use is ${runtime.version}.';
      notifyListeners();
      return;
    }

    entry
      ..state = PluginState.starting
      ..error = null;
    notifyListeners();

    final pluginId = entry.manifest.id;
    final host = PythonPluginHost(
      manifest: entry.manifest,
      runtime: runtime,
      onLog: _appendLog,
      onRead: _readForPlugin,
      onList: _listForPlugin,
      onStat: _statForPlugin,
      onViewUpdate: _pushViewUpdate,
    );

    try {
      final handshake = await host.start(settings: settingsFor(pluginId));
      entry.host = host;
      _registerContributions(entry, handshake);
      entry.state = PluginState.active;
      _appendLog(PluginLogRecord(pluginId, 'info', 'Started'));
    } on Object catch (e) {
      await host.stop();
      entry
        ..host = null
        ..state = PluginState.failed
        ..error = e is RpcException ? e.message : e.toString();
      _appendLog(PluginLogRecord(pluginId, 'error', 'Failed to start: $e'));
    }
    notifyListeners();
  }

  Future<void> stop(String pluginId) async {
    final entry = _entries[pluginId];
    if (entry == null) return;

    for (final scheme in entry.activeSchemes) {
      await fileSystems.unregister(scheme);
    }
    _commands.removeWhere((_, command) => command.pluginId == pluginId);
    _views.removeWhere((_, view) => view.pluginId == pluginId);
    _viewers.removeWhere((_, viewer) => viewer.pluginId == pluginId);
    _describers.removeWhere((_, describer) => describer.pluginId == pluginId);

    await entry.host?.stop();
    entry
      ..host = null
      ..activeSchemes = const []
      ..activeViewers = const []
      ..activeViews = const []
      ..activeDescribers = const []
      ..state = disabled.contains(pluginId)
          ? PluginState.disabled
          : PluginState.discovered;
    notifyListeners();
  }

  /// Puts [entry] on disk and starts it, replacing any copy already there.
  ///
  /// Installing is a lifecycle change rather than a file copy, which is why it
  /// lives here and not in the settings page: a plugin serves its schemes and
  /// offers its commands only once [start] has run. A caller that copies and
  /// discovers leaves a transport looking installed while its scheme is served
  /// by nobody — which is exactly what happened, and only a relaunch fixed it.
  ///
  /// Replacing a running copy stops it first: the folder being overwritten is
  /// the one the process was loaded from, and on Windows a file in use cannot
  /// be replaced at all. Stopping something that was never running costs
  /// nothing, so there is no flag saying which case this is.
  Future<void> install(CatalogueEntry entry) async {
    final directory = _pluginsDirectory;
    if (directory == null) {
      throw StateError('The plugins directory is not ready yet.');
    }

    final id = entry.manifest.id;
    await stop(id);
    await PluginSource.install(entry, directory,
        runtimeVersion: _runtime?.version);
    await discover();
    // One the user switched off stays off through an update.
    if (!disabled.contains(id)) await start(id);
  }

  /// Stops a plugin and deletes it from disk.
  ///
  /// Bundled extensions are refused rather than half-removed: they live inside
  /// the app bundle, so deleting the folder would either fail or come back on
  /// the next launch. Switching them off is what "remove" means for those.
  /// The version that ships in the bundle for [pluginId], when an installed
  /// copy is standing in front of it.
  ///
  /// What "remove" means for such a plugin: not gone, but back to this one.
  PluginManifest? shippedBehind(String pluginId) => _shipped[pluginId];

  Future<void> uninstall(String pluginId) async {
    final entry = _entries[pluginId];
    if (entry == null) return;
    if (entry.manifest.isBundled) {
      throw StateError(
        'Bundled extensions ship with the app. Switch it off instead.',
      );
    }

    await stop(pluginId);
    final directory = Directory(entry.manifest.directory);
    if (await directory.exists()) await directory.delete(recursive: true);

    _entries.remove(pluginId);
    _grammarFiles.remove(pluginId);
    _appendLog(PluginLogRecord(pluginId, 'info', 'Removed.'));
    await discover();
  }

  Future<void> restart(String pluginId) async {
    await stop(pluginId);
    await start(pluginId);
  }

  /// Looks for an interpreter again and starts whatever can now run.
  ///
  /// Called after installing Python or pointing the app at one, so plugins
  /// come to life without a restart.
  Future<void> refreshRuntime() async {
    PythonRuntime.reset();
    _runtime = await PythonRuntime.detect();

    for (final entry in entries) {
      if (entry.isActive) continue;
      if (entry.state == PluginState.disabled) continue;
      // Anything parked for want of an interpreter gets another go.
      if (entry.state == PluginState.unsupported ||
          entry.state == PluginState.failed) {
        entry
          ..state = _initialStateFor(entry.manifest)
          ..error = null;
      }
    }
    notifyListeners();

    await startEnabled();
  }

  Future<void> setEnabled(String pluginId, bool enabled) async {
    if (enabled) {
      disabled.remove(pluginId);
    } else {
      disabled.add(pluginId);
    }
    await onDisabledChanged?.call(disabled);

    if (enabled) {
      final entry = _entries[pluginId];
      if (entry != null && entry.state == PluginState.disabled) {
        entry.state = PluginState.discovered;
      }
      await start(pluginId);
    } else {
      await stop(pluginId);
    }
  }

  /// Runs a plugin command by id. Returns null when no plugin provides it.
  Future<Object?> invokeCommand(String id, [Map<String, dynamic>? args]) async {
    final command = _commands[id];
    if (command == null) return null;
    return command.invoke(args ?? const {});
  }

  /// Stops every running plugin.
  ///
  /// **All at once, not one after another.** Ten plugins stopped in turn are
  /// ten waits laid end to end, and the wait is what somebody closing the
  /// window sees. They do not depend on each other and nothing here reads what
  /// they return, so they go together and the whole thing costs one [patience]
  /// rather than ten.
  Future<void> shutdown({
    Duration patience = const Duration(seconds: 3),
  }) async {
    await Future.wait([
      for (final entry in entries.toList())
        if (entry.host != null) entry.host!.stop(patience: patience),
    ]);
    _entries.clear();
    _commands.clear();
    _views.clear();
    _viewers.clear();
  }

  @override
  void dispose() {
    unawaited(_viewUpdates.close());
    super.dispose();
  }

  /// Serves `host.read`: a byte range from whichever provider owns the URL.
  Future<Map<String, Object?>> _readForPlugin(
    String url,
    int offset,
    int length,
  ) async {
    final path = VfsPath.parse(url);
    final provider = fileSystems.resolve(path);

    final bytes = <int>[];
    await for (final chunk
        in provider.openRead(path, start: offset, end: offset + length)) {
      bytes.addAll(chunk);
      if (bytes.length >= length) break;
    }

    final slice = bytes.length > length ? bytes.sublist(0, length) : bytes;
    return {
      'data': base64Encode(slice),
      'eof': slice.length < length,
    };
  }

  /// Serves `host.list`: a directory from whichever provider owns the URL.
  ///
  /// The `..` row never crosses: it is a thing the panel draws, not a thing on
  /// the disk, and a plugin walking a tree that followed it would walk for
  /// ever.
  Future<Map<String, Object?>> _listForPlugin(String url) async {
    final path = VfsPath.parse(url);
    final entries = await fileSystems.resolve(path).list(path);
    return {
      'entries': [
        for (final entry in entries)
          if (!entry.isParentLink) _entryToJson(entry),
      ],
    };
  }

  /// Serves `host.stat`.
  Future<Map<String, Object?>?> _statForPlugin(String url) async {
    final path = VfsPath.parse(url);
    final entry = await fileSystems.resolve(path).stat(path);
    return entry == null ? null : _entryToJson(entry);
  }

  /// The same shape a plugin's own file system returns, so a plugin that walks
  /// a tree reads one kind of entry however the directory was obtained.
  Map<String, Object?> _entryToJson(FileEntry entry) => {
        'name': entry.name,
        'url': entry.path.toString(),
        'kind': switch (entry.kind) {
          FileKind.directory => 'dir',
          FileKind.link => 'link',
          _ => 'file',
        },
        'size': entry.size,
        if (entry.modified != null)
          'modified': entry.modified!.millisecondsSinceEpoch,
        'hidden': entry.isHidden,
        if (entry.linkTarget != null) 'target': entry.linkTarget,
      };

  /// Serves `host.viewUpdate`, the one call that flows the other way for its
  /// own reasons rather than as a reply.
  void _pushViewUpdate(String viewId, String session, Map<String, dynamic> body) {
    if (viewId.isEmpty || _viewUpdates.isClosed) return;
    _viewUpdates.add(ViewUpdate(
      viewId: viewId,
      session: session,
      response: ViewResponse.fromJson(body),
    ));
  }

  PluginState _initialStateFor(PluginManifest manifest) {
    if (disabled.contains(manifest.id)) return PluginState.disabled;
    if (!manifest.supportsCurrentPlatform()) return PluginState.unsupported;
    if (!manifest.isCompatible) return PluginState.incompatible;
    if (manifest.runtime == PluginRuntime.unknown) {
      return PluginState.unsupported;
    }
    // Only Python plugins care whether an interpreter exists; declarative ones
    // run everywhere, which is the whole reason that runtime exists.
    if (manifest.needsPythonRuntime && !PythonRuntime.isSupported) {
      return PluginState.unsupported;
    }
    return PluginState.discovered;
  }

  /// Registers the schemes and commands a started plugin reported.
  void _registerContributions(PluginEntry entry, PluginHandshake handshake) {
    final host = entry.host!;
    final schemes = handshake.schemes.isNotEmpty
        ? handshake.schemes
        : entry.manifest.schemes;

    final registered = <String>[];
    for (final spec in schemes) {
      if (fileSystems.supports(spec.scheme)) {
        _appendLog(PluginLogRecord(
          entry.manifest.id,
          'warning',
          'Scheme "${spec.scheme}:" is already served by another provider; '
              'skipped.',
        ));
        continue;
      }
      fileSystems.register(RemoteFileSystemProvider(
        scheme: spec.scheme,
        displayName: entry.manifest.name,
        host: host,
        // What the panel is allowed to offer while it stands in this scheme.
        // Told rather than discovered: see SchemeSpec.
        isWritable: spec.isWritable,
        badge: spec.icon,
      ));
      registered.add(spec.scheme);
    }
    entry.activeSchemes = registered;

    // What registers is what the plugin reported, but how it is *presented*
    // comes from the manifest: the SDK's `@plugin.command` only carries an id
    // and a title, so an icon or a claim on the title bar would be lost if the
    // handshake simply replaced the declaration.
    final declared = {for (final c in entry.manifest.commands) c.id: c};
    final specs = handshake.commands.isNotEmpty
        ? [
            for (final reported in handshake.commands)
              switch (declared[reported.id]) {
                final PluginCommandSpec manifest => PluginCommandSpec(
                    id: reported.id,
                    title: reported.title,
                    description: reported.description ?? manifest.description,
                    icon: manifest.icon,
                    inTitleBar: manifest.inTitleBar,
                  ),
                _ => reported,
              },
          ]
        : entry.manifest.commands;
    for (final spec in specs) {
      _commands[spec.id] = PluginCommand(
        spec: spec,
        pluginId: entry.manifest.id,
        invoke: (args) => host.channel.call(
          'command.invoke',
          params: {'id': spec.id, 'args': args},
          timeout: PythonPluginHost.callTimeout,
        ),
      );
    }

    // A view's surfaces come from the manifest and nowhere else. The SDK's
    // decorator carries an id and a title, so a plugin reporting its views
    // would otherwise lose the very thing that decides where they go — and a
    // view whose surfaces silently became "full screen only" is a plugin that
    // looks installed and appears nowhere the user was told to look.
    final declaredViews = {for (final v in entry.manifest.views) v.id: v};
    final viewSpecs = handshake.views.isNotEmpty
        ? [
            for (final reported in handshake.views)
              declaredViews[reported.id] ?? reported,
          ]
        : entry.manifest.views;

    final registeredViews = <String>[];
    for (final spec in viewSpecs) {
      _views[spec.id] = RegisteredView(
        spec: spec,
        pluginId: entry.manifest.id,
        pluginName: entry.manifest.name,
        open: (context) => _callView(host, 'view.open', spec.id, {
          'context': context.toJson(),
        }),
        handle: (context, event) => _callView(host, 'view.event', spec.id, {
          'context': context.toJson(),
          'event': event.toJson(),
        }),
        close: (session) async {
          if (!host.isRunning) return;
          host.channel.notify(
            'view.close',
            params: {'viewId': spec.id, 'session': session},
          );
        },
        updates: _viewUpdates.stream.where((u) => u.viewId == spec.id),
      );
      registeredViews.add(spec.id);
    }
    entry.activeViews = registeredViews;

    final viewerSpecs = handshake.viewers.isNotEmpty
        ? handshake.viewers
        : entry.manifest.viewers;
    final registeredViewers = <String>[];
    for (final spec in viewerSpecs) {
      _viewers[spec.id] = RegisteredViewer(
        spec: spec,
        pluginId: entry.manifest.id,
        pluginName: entry.manifest.name,
        open: (path) async {
          final result = await host.channel.call(
            'viewer.open',
            params: {'viewerId': spec.id, 'url': path.toString()},
            timeout: PythonPluginHost.callTimeout,
          );
          if (result is! Map) {
            return ViewerContent.error('Viewer returned no content');
          }
          return ViewerContent.fromJson(Map<String, dynamic>.from(result));
        },
        thumbnail: !spec.thumbnails
            ? null
            : (path, pixels) async {
                try {
                  final result = await host.channel.call(
                    'viewer.thumbnail',
                    params: {
                      'viewerId': spec.id,
                      'url': path.toString(),
                      'pixels': pixels,
                    },
                    timeout: thumbnailTimeout,
                  );
                  if (result is! Map) return null;
                  final data = result['data'];
                  if (data is! String || data.isEmpty) return null;
                  return base64Decode(data);
                } on Object {
                  // A thumbnail is a convenience. A plugin that cannot make
                  // one leaves the cell showing the file's name, which is
                  // what it showed before anybody could be asked.
                  return null;
                }
              },
        // Only where the viewer asked to be asked. The head travels as base64
        // because the pipe carries JSON, and a file's first pages are not
        // text — a workflow inside a PNG will be along one day.
        probe: !spec.probe
            ? null
            : (path, head) async {
                final result = await host.channel.call(
                  'viewer.probe',
                  params: {
                    'viewerId': spec.id,
                    'url': path.toString(),
                    'head': base64Encode(head),
                    'bytes': head.length,
                  },
                  timeout: probeTimeout,
                );
                if (result is bool) return result;
                if (result is Map) return result['claims'] == true;
                return false;
              },
      );
      registeredViewers.add(spec.id);
    }
    entry.activeViewers = registeredViewers;

    final describerSpecs = handshake.describers.isNotEmpty
        ? handshake.describers
        : entry.manifest.describers;
    final registeredDescribers = <String>[];
    for (final spec in describerSpecs) {
      _describers[spec.id] = RegisteredDescriber(
        spec: spec,
        pluginId: entry.manifest.id,
        pluginName: entry.manifest.name,
        describe: (path) async {
          try {
            final result = await host.channel.call(
              'describe.open',
              params: {'describerId': spec.id, 'url': path.toString()},
              timeout: PythonPluginHost.callTimeout,
            );
            if (result is! Map) {
              return const FileFacts.failed('The plugin said nothing.');
            }
            return FileFacts.fromJson(Map<String, dynamic>.from(result));
          } on RpcException catch (e) {
            return FileFacts.failed(e.message);
          } on Object catch (failure) {
            return FileFacts.failed('$failure');
          }
        },
      );
      registeredDescribers.add(spec.id);
    }
    entry.activeDescribers = registeredDescribers;
  }

  /// One call into a view, with a failure turned into something the user can
  /// read rather than an exception thrown at whatever is drawing.
  ///
  /// A view is on screen while this runs — often in a panel — so a plugin that
  /// throws must leave a message in the panel, not take the panel down.
  Future<ViewResponse> _callView(
    PythonPluginHost host,
    String method,
    String viewId,
    Map<String, dynamic> params,
  ) async {
    try {
      final result = await host.channel.call(
        method,
        params: {'viewId': viewId, ...params},
        timeout: PythonPluginHost.callTimeout,
      );
      if (result is! Map) return const ViewResponse();
      return ViewResponse.fromJson(Map<String, dynamic>.from(result));
    } on RpcException catch (e) {
      return ViewResponse.error(e.message);
    } on Object catch (e) {
      return ViewResponse.error('$e');
    }
  }

  /// Plugins live in the user's support directory so they survive app updates
  /// and need no elevated permissions to install.
  Future<Directory> _resolvePluginsDirectory() async {
    final override = Platform.environment['XVERB_PLUGINS'];
    final directory = override != null && override.isNotEmpty
        ? Directory(override)
        : Directory(p.join(
            (await getApplicationSupportDirectory()).path,
            'plugins',
          ));
    await directory.create(recursive: true);
    return directory;
  }

  void _appendLog(PluginLogRecord record) {
    _log.add(record);
    if (_log.length > maxLogRecords) {
      _log.removeRange(0, _log.length - maxLogRecords);
    }
    notifyListeners();
  }
}
