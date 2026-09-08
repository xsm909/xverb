import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/plugins/plugin_registry.dart';
import '../core/settings/folder_history.dart';
import '../core/settings/settings_store.dart';
import '../core/settings/connection_store.dart';
import '../core/shell/command_line.dart';
import '../core/shell/shell_kind.dart';
import '../core/vfs/file_clipboard.dart';
import '../core/vfs/file_operations.dart';
import '../core/vfs/fs_registry.dart';
import '../core/vfs/local_provider.dart';
import 'drag_session.dart';
import 'panel_controller.dart';
import 'window_stack.dart';

/// Root of the application's runtime state.
///
/// Owns the two panels plus the three registries they depend on, and decides
/// which panel has focus.
class AppState extends ChangeNotifier {
  AppState._({
    required this.settings,
    required this.fileSystems,
    required this.plugins,
  }) : operations = FileOperations(fileSystems) {
    left = PanelController(
      registry: fileSystems,
      settings: settings,
      isLeft: true,
    );
    right = PanelController(
      registry: fileSystems,
      settings: settings,
      isLeft: false,
    );

    // Each panel watches the other, so anything attached to one that asked to
    // follow a cursor gets told when that cursor moves. Nothing happens unless
    // something is attached, and an attachment ignores a move that leaves it
    // pointed where it already was, so this cannot echo between the two.
    left.addListener(_leftMoved);
    right.addListener(_rightMoved);
  }

  void _leftMoved() {
    _record();
    right.followedPanelChanged(
      location: left.location,
      cursor: left.cursorEntry,
    );
  }

  void _rightMoved() {
    _record();
    left.followedPanelChanged(
      location: right.location,
      cursor: right.cursorEntry,
    );
  }

  /// Tells the history which folders are open.
  ///
  /// **Both panels, not only the active one.** A folder held open on one
  /// side while the work darts in and out of the other is a folder being used,
  /// and counting only the active one took its clock away at every crossing —
  /// which is most of what working with two panels *is*.
  ///
  /// A folder open in both is counted once. The same minute cannot be spent
  /// twice, and [FolderHistory.showing] keys its clocks by folder rather than
  /// by panel so that it cannot be.
  ///
  /// A **virtual** listing counts as nowhere: search results are a question
  /// somebody asked rather than a place to go back to, and a row that cannot be
  /// opened is a row that lies.
  ///
  /// Called on every change either panel has, which is far more often than
  /// anything happens: the folders already being counted keep their clocks
  /// untouched, and [FolderHistory.showing] says so itself.
  void _record() {
    history.showing([
      left.isVirtual ? null : left.location,
      right.isVirtual ? null : right.location,
    ]);
  }

  final SettingsStore settings;
  final FileSystemRegistry fileSystems;
  final PluginRegistry plugins;
  final FileOperations operations;

  /// Where the panels have been, and how often — what Alt+F1 and Alt+F2 offer
  /// under History. Kept in memory and written on the way out; see
  /// [FolderHistory].
  FolderHistory history = FolderHistory.inMemory();

  /// What a plugin currently has filling the window as a page — views by view
  /// id, commands by command id.
  ///
  /// One page each, never a stack of them. Pressing the same title-bar icon
  /// twice is the ordinary way to end up with two, and two is wrong for both
  /// kinds: every full-screen copy of a view is the same `page` session to the
  /// plugin, so the second would share the first one's state, and a command
  /// stacked on itself is the same report read twice with the older one
  /// waiting underneath.
  final Set<String> _openPages = {};

  bool isPageOpen(String id) => _openPages.contains(id);

  /// What the route holding one of these pages is called.
  ///
  /// A name rather than a handle, because what has to be done with it is done
  /// through the navigator: a page buried under another tool's page is brought
  /// back by popping to it, and popping to something needs a way to recognise
  /// it. See [ViewLauncher.open].
  static String pageRouteName(String id) => 'plugin-page:$id';

  /// True when this call is the one that opened it.
  bool claimPage(String id) => _openPages.add(id);

  void releasePage(String id) => _openPages.remove(id);

  /// The command line shared by both panels; it always runs in whichever one
  /// is active, the way Total Commander's does.
  final CommandLine commandLine = CommandLine();

  /// Saved connections for every transport plugin.
  final ConnectionStore connections = ConnectionStore();

  /// Internal windows — settings, viewers — floating over the panels.
  final WindowStack windows = WindowStack();

  /// Ctrl+C, Ctrl+X and the file half of Ctrl+V, shared by both panels and
  /// kept in step with the desktop's own clipboard.
  final FileClipboard clipboard = FileClipboard();

  /// Everything dragged over the window, whether it came from Explorer, from
  /// Finder or from the panel on the other side.
  final DragSession drags = DragSession();

  /// The two panels, by the side of the window they are on — which is a thing
  /// that changes: see [swapSides].
  late PanelController left;
  late PanelController right;

  /// Ctrl+U — the two panels change places.
  ///
  /// **The panels, not their paths.** This used to read both locations and
  /// navigate each panel to the other's, which is a different act wearing the
  /// same name: everything about a panel except where it points stayed on its
  /// own side — the cursor, what was marked, the history — and a panel holding
  /// a tool was *given up* altogether, because a panel cannot be in a folder
  /// and handed over to a view at the same time. Open the git tool on the left,
  /// press Ctrl+U, and the tool closed and a folder was listed in its place.
  ///
  /// Swapping the two objects moves each panel whole, with whatever it is
  /// holding, and re-reads nothing at all.
  ///
  /// Two things settled while building it:
  ///
  /// - **The same side stays active**, not the same panel. Ctrl+U is about the
  ///   window, and the hand is where it was; Total Commander's does the same.
  /// - **A view's `other_url` needs no telling.** The panel beside it is still
  ///   the panel beside it — both moved at once — so nothing a tool was told
  ///   about the other side has stopped being true.
  void swapSides() {
    // The listeners are the pairing, not the panel: `_leftMoved` says "tell
    // the right one where the left one is". Left attached to the panel that
    // has just become the right one, it would tell a panel about itself.
    left.removeListener(_leftMoved);
    right.removeListener(_rightMoved);

    final wasLeft = left;
    left = right;
    right = wasLeft;
    left.isLeft = true;
    right.isLeft = false;

    left.addListener(_leftMoved);
    right.addListener(_rightMoved);

    // Where each side was left, so the arrangement survives a restart — the
    // panels themselves have not moved anywhere and will not save it
    // otherwise.
    unawaited(left.rememberWhereItIs());
    unawaited(right.rememberWhereItIs());
    notifyListeners();
  }

  bool _leftIsActive = true;

  /// The panel keyboard commands apply to.
  PanelController get active => _leftIsActive ? left : right;

  /// The other panel — the default target of copy and move.
  PanelController get inactive => _leftIsActive ? right : left;

  bool get leftIsActive => _leftIsActive;

  /// Whether the command line holds the keyboard rather than a panel.
  ///
  /// There are two places to be and the difference has to be visible, or the
  /// same keystroke does two things and neither of them is the one expected.
  /// While this is true no panel counts as active: the cursor and the frame
  /// are drawn the way an inactive panel's are, and the only thing on the
  /// screen with the keyboard's attention is the line.
  ///
  /// State rather than a widget's private flag, because "where the keyboard
  /// is" is not something one widget can answer for the two that must both
  /// show it.
  bool get keyboardInCommandLine => _keyboardInCommandLine;
  bool _keyboardInCommandLine = false;

  set keyboardInCommandLine(bool value) {
    if (_keyboardInCommandLine == value) return;
    _keyboardInCommandLine = value;
    notifyListeners();
  }

  /// Whether [panel] is the one the keyboard is working in — which nothing is
  /// while the command line has it.
  bool isActive(PanelController panel) =>
      identical(panel, active) && !_keyboardInCommandLine;

  /// The panel that *would* have the keyboard. What copy and move act on, and
  /// which half of the window the selection frame sits over: going into the
  /// command line does not change which panel you came from.
  bool isCurrent(PanelController panel) => identical(panel, active);

  void activate(PanelController panel) {
    final shouldBeLeft = identical(panel, left);
    if (_leftIsActive == shouldBeLeft) return;
    _leftIsActive = shouldBeLeft;
    notifyListeners();
  }

  void toggleActivePanel() {
    _leftIsActive = !_leftIsActive;
    notifyListeners();
  }

  /// Builds the whole runtime: the local provider, the plugin system, then both
  /// panels. Plugins load in the background so a slow or broken plugin never
  /// delays the first frame.
  ///
  /// [settings] is passed in because the window needs them before this runs.
  static Future<AppState> create({SettingsStore? settings}) async {
    final store = settings ?? await SettingsStore.load();
    final fileSystems = FileSystemRegistry()..register(LocalFileSystemProvider());
    final plugins = PluginRegistry(fileSystems: fileSystems)
      ..onDisabledChanged = store.setDisabledPlugins
      // What has already been handed over from the copies that travel with the
      // application — see `PluginRegistry._seedShipped`.
      // Parenthesised, because an arrow body swallows the cascade that
      // follows it: `() => store.seededPlugins..onSeededChanged = ...` reads
      // as one expression and every setter after it lands on a `Set`.
      ..loadSeeded = (() => store.seededPlugins)
      ..onSeededChanged = store.setSeededPlugins
      ..loadSettings = store.pluginSettings
      ..onSettingsChanged = store.setPluginSettings
      ..titleBarOrder = store.titleBarOrder
      ..onTitleBarOrderChanged = store.setTitleBarOrder;
    // A plugin speaks its own language out of its own catalogue, so a change
    // of language has to reach the plugins as well as the application.
    store.onLanguageChanged = plugins.refreshStrings;

    final state = AppState._(
      settings: store,
      fileSystems: fileSystems,
      plugins: plugins,
    );

    state.commandLine
      ..shell = ShellKind.values.firstWhere(
        (kind) => kind.name == store.shellKind,
        orElse: () => ShellKind.system,
      )
      ..consoleHeight = store.consoleHeight ?? state.commandLine.consoleHeight
      ..saveHistory = store.setCommandHistory
      ..loadHistory(store.commandHistory);

    // Connections come from a small INI; loading them is cheap and the drive
    // list needs them on the first open.
    await state.connections.initialize().catchError(
          (Object error) => debugPrint('Connections unavailable: $error'),
        );

    // Before the panels open anywhere, so the folder they start in is counted
    // like any other — it is the one somebody comes back to most.
    state.history = await FolderHistory.load();

    await state.left.openInitialLocation();
    await state.right.openInitialLocation();
    // The folder the application opens in is where the clock starts. Without
    // this it would not start until the first time
    // somebody went somewhere — and since a folder needs a minute in it to be
    // in the history at all, the folder they opened *into* and worked in all
    // morning would never get there.
    state._record();

    unawaitedInitialize(plugins, store);
    return state;
  }

  /// Starts plugin discovery without blocking startup.
  static void unawaitedInitialize(
    PluginRegistry plugins,
    SettingsStore settings,
  ) {
    plugins.initialize(disabledIds: settings.disabledPlugins).catchError(
          (Object error) => debugPrint('Plugin initialisation failed: $error'),
        );
  }

  /// Stops the plugin processes and the connections they hold.
  ///
  /// **This is the way out for everything that is not this process.** A plugin
  /// runs in a Python interpreter of its own, and while the application is up
  /// there are as many of those as there are plugins. Left alone they go when
  /// their end of the pipe closes — which happens somewhere inside the engine
  /// shutting down, and until it does, the shutdown is waiting for them.
  /// Asking them to go first is what makes closing the window quick.
  ///
  /// [patience] is per plugin and they are stopped together, so it is also
  /// roughly what the whole call costs. On the way out it should be short: a
  /// plugin has nothing of the user's to lose — everything a person typed is
  /// written by [saveOnExit] before this is called — and the alternative to
  /// killing it is somebody watching a window that will not go.
  Future<void> shutdown({
    Duration patience = const Duration(seconds: 3),
  }) async {
    await plugins.shutdown(patience: patience);
    await fileSystems.disposeProviders();
  }

  /// Everything that is kept in memory and written on the way out.
  ///
  /// One call rather than a list at the call site, so the next thing that works
  /// this way is added here and not forgotten in `app.dart`.
  Future<void> saveOnExit() => history.save();

  @override
  void dispose() {
    left.removeListener(_leftMoved);
    right.removeListener(_rightMoved);
    left.dispose();
    right.dispose();
    commandLine.dispose();
    super.dispose();
  }
}
