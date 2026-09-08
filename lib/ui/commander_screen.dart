import 'dart:async';
import 'dart:io' show Directory, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/i18n/i18n.dart';
import '../core/platform/key_letters.dart';
import '../core/plugins/plugin_manifest.dart';
import '../core/plugins/plugin_registry.dart';
import '../core/plugins/view.dart';
import '../core/plugins/viewer.dart';
import '../core/settings/connection_store.dart';
import '../core/settings/appearance_settings.dart';
import '../core/settings/settings_store.dart';
import '../core/settings/window_service.dart';
import '../core/update/release_check.dart';
import '../core/update/update_installer.dart' show StageStep;
import '../core/update/update_log.dart';
import '../core/update/update_offer.dart';
import '../core/update/update_start.dart';
import '../core/shell/name_completion.dart';
import '../core/shell/script_launch.dart';
import '../core/shell/shell_kind.dart';
import '../core/version.dart';
import '../core/platform/file_transfer_channel.dart';
import '../core/vfs/archive_actions.dart';
import '../core/vfs/failure_text.dart';
import '../core/vfs/file_entry.dart';
import '../core/vfs/fs_provider.dart' show VfsRoot;
import '../core/vfs/fs_registry.dart';
import '../core/links.dart';
import '../core/vfs/shell_open.dart';
import '../core/vfs/system_menu.dart';
import '../core/vfs/vfs_path.dart';
import '../core/vfs/file_operations.dart' show ConflictAction;
import '../state/app_state.dart';
import '../state/panel_attachment.dart';
import '../state/panel_controller.dart';
import '../state/window_stack.dart';
import '../core/colour_contrast.dart';
import 'keyboard_focus.dart';
import 'page_transition.dart';
import 'dialogs/common_dialogs.dart';
import 'dialogs/connection_dialog.dart';
import 'dialogs/pack_dialog.dart';
import 'update/update_offer_window.dart';
import 'dialogs/connection_manager_dialog.dart';
import 'shell/command_line_bar.dart';
import 'dialogs/progress_dialog.dart';
import 'dialogs/reading_window.dart';
import 'dialogs/roots_dialog.dart';
import 'notice.dart';
import 'widgets/blurred_backdrop.dart';
import 'panel/file_panel.dart';
import 'plugins/plugin_command_page.dart';
import 'plugins/plugin_icons.dart';
import 'about/about_splash.dart';
import 'plugins/plugin_table.dart' show driveTable;
import 'plugins/view_launcher.dart';
import 'plugins/view_pill.dart' show viewMenuNodes;
import 'search/search_window.dart';
import 'settings/settings_page.dart';
import 'viewer/plugin_viewer_page.dart';
import 'panel/file_context_menu.dart';
import 'widgets/context_menu.dart';
import 'widgets/title_bar.dart';
import 'windows/window_dialogs.dart';
import 'windows/window_layer.dart';

/// The main window: title bar, two panels, quick search, and the key bindings.
class CommanderScreen extends StatefulWidget {
  const CommanderScreen({super.key});

  @override
  State<CommanderScreen> createState() => _CommanderScreenState();
}

class _CommanderScreenState extends State<CommanderScreen>
    with WidgetsBindingObserver {
  final FocusNode _keyboard = FocusNode(debugLabel: 'commander');

  /// The command line's real input, used only while it is being edited by
  /// pointer or touch. It lives here rather than in the bar because the
  /// console hands it the keyboard too, and the two are siblings.
  final FocusNode _commandInput = FocusNode(debugLabel: 'command line');
  final TextEditingController _commandText = TextEditingController();

  /// Whether that input is up.
  bool _editingCommand = false;

  /// Active quick-search text, or null when the search bar is closed.
  String? _search;
  int _searchMatches = 0;

  /// Where the next character lands.
  ///
  /// Only the Alt+S box shows it and only that style lets it move: under
  /// Ctrl+Alt+letter it sits at the end of the query and never leaves, because
  /// there Left and Right belong to the panels and always did.
  int _searchCaret = 0;

  /// Below this width only one panel fits, so the layout switches to tabs.
  static const double _twoPanelBreakpoint = 720;

  late final WindowStack _windows = context.read<AppState>().windows;

  /// The location pills, so Alt+F1 and Alt+F2 can drop the menu under the
  /// right one instead of at the pointer.
  final GlobalKey _leftLocationKey = GlobalKey(debugLabel: 'left location');
  final GlobalKey _rightLocationKey = GlobalKey(debugLabel: 'right location');

  /// How Alt+F and the rest reach the menu strip in the title bar.
  final TitleBarMenus _menuKeys = TitleBarMenus();

  /// Sits on whichever row the cursor is on, so a menu asked for from the
  /// keyboard opens against that row rather than in a corner.
  final GlobalKey _leftCursorKey = GlobalKey(debugLabel: 'left cursor row');
  final GlobalKey _rightCursorKey = GlobalKey(debugLabel: 'right cursor row');

  /// Whose location menu is open, so its pill stays lit.
  PanelController? _locationMenuPanel;

  /// Says so when a panel has been reading for longer than a moment — an
  /// archive being unpacked far enough to list, a folder the system asks about
  /// before it hands it over.
  late final ReadingWatch _reading = ReadingWatch(
    windows: _windows,
    panels: [_app.left, _app.right],
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _windows.addListener(_onWindowsChanged);
    // A window opened from here comes out of the row the cursor is on. This
    // screen is the only thing that knows where that row is — it holds the key
    // that travels with the cursor — so it is the one that answers.
    _windows.originOf = _cursorRect;
    _reading.start();
    // Done here rather than where these two objects are built, because both
    // ends of it need dialogs: a drag has to be able to show progress while it
    // fetches, and a drop has to be able to ask about a name collision.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _app.drags.start();
      _app.clipboard.materialiser = _materialise;
      // **The splash, if this is a start-up.** After the first frame, so it is
      // laid over a commander somebody can see rather than over nothing —
      // Blender's does the same, and a card floating on grey reads as a
      // program that has not finished loading.
      if (takeStartupSplash()) unawaited(showAboutSplash(context));
      unawaited(_offerUpdateWhenDue());
      // And again while it runs. A file manager is opened in the morning and
      // left open, so a start is not a schedule — see [_offerUpdateWhenDue].
      // The timer is short and the decision is not: it wakes often and asks
      // [UpdatePrompt.dueForCheck], which is what knows when the network is
      // touched. A timer set to the interval itself would drift past it every
      // time the machine slept.
      _updatePoll = Timer.periodic(
        const Duration(minutes: 15),
        (_) => unawaited(_offerUpdateWhenDue()),
      );
    });
  }

  /// The poll that keeps looking for a release while the application runs.
  Timer? _updatePoll;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updatePoll?.cancel();
    _stopWatchingRoots();
    _reading.stop();
    _windows.removeListener(_onWindowsChanged);
    // The keys go with this screen, so the answer has to go with it too.
    if (identical(_windows.originOf, _cursorRect)) _windows.originOf = null;
    _menuKeys.dispose();
    _keyboard.dispose();
    _commandInput.dispose();
    _commandText.dispose();
    super.dispose();
  }

  /// Coming back to the window re-reads what the panels are standing on.
  ///
  /// **Because while we were away, somebody else was working.** A file dragged
  /// out to Finder onto a name that is taken is not moved when the drag ends —
  /// it is moved when the question Finder asks has been answered, which is
  /// after we have already looked. The same is true of anything else done on
  /// the machine while this window was behind another one, and this
  /// application has no watch on the file system to hear about it.
  ///
  /// Only local folders. A panel standing on a server would go and ask it every
  /// time the window was clicked away from and back, which is a network round
  /// trip for a question nobody asked.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      // On the way out, and this is the only warning there is. Where the
      // cursor is standing is written a moment after it stops moving, so that
      // walking a folder does not write a preference per keystroke — and a
      // window closed inside that moment would take the answer with it.
      for (final panel in [_app.left, _app.right]) {
        panel.rememberCursorNow();
      }
      return;
    }
    _rereadLocalPanels();
  }

  void _rereadLocalPanels() {
    for (final panel in [_app.left, _app.right]) {
      if (panel.location?.scheme == VfsPath.localScheme && !panel.isAttached) {
        unawaited(panel.refresh());
      }
    }
  }

  /// The front window owns the keyboard while it is open, so the panels take it
  /// back the moment the last one closes.
  void _onWindowsChanged() {
    if (mounted && _windows.isEmpty) _keyboard.requestFocus();
  }

  AppState get _app => context.read<AppState>();

  ViewLauncher get _views => ViewLauncher(_app);

  SettingsStore get _settings => context.read<SettingsStore>();

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final theme = context.watch<SettingsStore>().appearance;

    return Focus(
      focusNode: _keyboard,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        backgroundColor: theme.backdrop == WindowBackdrop.opaque
            ? (theme.darkChrome ? const Color(0xFF10151C) : null)
            : Colors.transparent,
        body: Column(
          children: [
            // Listening to whatever the active panel is holding, because a
            // tool's menus arrive with its answers rather than when it opens:
            // the bar has to be rebuilt when the plugin says what it can do,
            // not only when the panel was handed over.
            ListenableBuilder(
              listenable: Listenable.merge([appState.active.attachment]),
              builder: (context, _) =>
                  TitleBar(menus: _titleMenus(), menuKeys: _menuKeys),
            ),
            Expanded(
              child: SafeArea(
                top: false,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final sideBySide =
                        constraints.maxWidth >= _twoPanelBreakpoint;
                    // Windows float over the panels, the console and the
                    // command bar — but not over the application's title bar,
                    // which has to stay reachable to drag the app window.
                    // F11: the console takes the window. The panels are left
                    // out of the tree rather than squeezed to nothing — a
                    // panel one pixel tall is still a panel being laid out,
                    // and a listing nobody can see is a listing nobody should
                    // be paying for.
                    return WindowLayer(
                      stack: appState.windows,
                      // Listened to here as well as further down: whether the
                      // console has the window decides what is *above* it, and
                      // the screen watches the application rather than the
                      // command line — so without this F11 changed the state
                      // and nothing above the strip was rebuilt.
                      child: ListenableBuilder(
                        listenable: appState.commandLine,
                        builder: (context, _) {
                          final consoleOwnsIt =
                              appState.commandLine.consoleVisible &&
                                  appState.commandLine.consoleFullScreen;
                          return Column(
                        children: [
                          if (!consoleOwnsIt)
                            Expanded(
                              child: sideBySide
                                  ? _twoPanels(appState)
                                  : _singlePanel(appState),
                            ),
                          // Everything below the panels, measured as one: a
                          // remark floats above this rather than over it. See
                          // `noticeBottomInset`.
                          // Full screen the strip is what takes the room the
                          // panels were taking; otherwise it is as tall as
                          // what is in it.
                          if (consoleOwnsIt)
                            Expanded(
                              child: NoticeBottomInset(
                                child: _bottomStrip(
                                  appState,
                                  constraints,
                                  sideBySide: sideBySide,
                                ),
                              ),
                            )
                          else
                            NoticeBottomInset(
                              child: _bottomStrip(
                                appState,
                                constraints,
                                sideBySide: sideBySide,
                              ),
                            ),
                        ],
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The console, the command line and the function keys — everything under
  /// the panels.
  ///
  /// One method rather than three children of the screen's own column, because
  /// it is also one *thing*: the strip a remark has to clear. Wrapped in
  /// [NoticeBottomInset], which measures it.
  Widget _bottomStrip(
    AppState appState,
    BoxConstraints constraints, {
    required bool sideBySide,
  }) {
    final full = appState.commandLine.consoleVisible &&
        appState.commandLine.consoleFullScreen;
    final theme = _settings.appearance;

    // **Two notifiers, because the strip draws from two.** The command line is
    // the obvious one; the prompt beside it is the *active panel's* folder, and
    // walking into a folder notifies the panel and nobody else. Listening to
    // the command line alone left the prompt naming the folder you had left
    // until something else happened to rebuild the strip — Tab, which notifies
    // `AppState`, or a click in the console, which notifies the line. Reported
    // 2026-09-06.
    //
    // `active` is a different object after Tab, so the merge is rebuilt with
    // it: `AppState` notifies when the active panel changes, and this method
    // runs under `context.watch<AppState>()`.
    final console = ListenableBuilder(
      listenable: Listenable.merge([appState.commandLine, appState.active]),
      builder: (context, _) => Column(
            mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
            children: [
              if (appState.commandLine.consoleVisible)
                () {
                  final pane = ConsolePane(
                    // What it fills when it has the window, and the height it
                    // was dragged to otherwise — which is kept either way, so
                    // coming back out puts it where it was.
                    fills: full,
                    commandLine: appState.commandLine,
                    onCollapse: appState.commandLine.toggleConsole,
                    onBeginEditing: _beginCommandEditing,
                    // Leave room for the panels: the console can grow, but not
                    // eat the listing.
                    onResize: (delta) => appState.commandLine.resizeConsole(
                      delta,
                      available: constraints.maxHeight - 160,
                    ),
                    onResizeEnd: _saveConsoleHeight,
                  );
                  return full ? Expanded(child: pane) : pane;
                }(),
              CommandLineBar(
                commandLine: appState.commandLine,
                location: appState.active.location,
                focused: !appState.commandLine.isEmpty,
                onPickShell: _pickShell,
                onToggleConsole: appState.commandLine.toggleConsole,
                editing: _editingCommand,
                input: _commandInput,
                inputText: _commandText,
                onBeginEditing: _beginCommandEditing,
                onSubmit: () => unawaited(_runCommand()),
                onDismiss: _endCommandEditing,
              ),
            ],
          ),
    );

    return Column(
      // Full screen the strip *is* the window, so it takes what there is
      // rather than the height it was dragged to. Expanded around the console
      // itself, because a column hands its children unbounded height and a
      // flex child inside an unbounded column is an error rather than a
      // stretch.
      mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
      children: [
        // What divides this from the panels: one hairline, the same one that
        // runs under the menu and under the tabs. Here rather than on
        // the console pane, because the strip starts with the command line
        // when the console is closed.
        Container(height: 1, color: theme.chromeRule),
        if (full) Expanded(child: console) else console,
        ExcludeFocus(
          // Rebuilt when either panel moves, not when the application does.
          // The keys say what can be done *where the panels are standing*, and
          // walking into a commit is a change in the panel alone — without
          // this the bar went on offering Delete until something else happened
          // to redraw the screen.
          child: ListenableBuilder(
            listenable: Listenable.merge([appState.left, appState.right]),
            builder: (context, _) =>
                _CommandBar(compact: !sideBySide, actions: _actions()),
          ),
        ),
      ],
    );
  }

  /// The panels sit flush against each other. A spacer between them showed the
  /// desktop through as a bright slot once the window became translucent.
  /// Two square slabs with one ring over them. The ring slides on Tab; see
  /// [PanelSelection].
  Widget _twoPanels(AppState appState) => Stack(
    children: [
      Row(
        children: [
          Expanded(child: _panel(appState.left)),
          Expanded(child: _panel(appState.right)),
        ],
      ),
      Positioned.fill(
        child: PanelSelection(
          leftActive: appState.leftIsActive,
          split: 0.5,
          // The frame stays over the panel you came from — going into the line
          // does not change which panel that is — but it goes pale, because
          // the keyboard is not in it.
          dim: appState.keyboardInCommandLine,
        ),
      ),
    ],
  );

  Widget _singlePanel(AppState appState) => Column(
    children: [
      ExcludeFocus(
        child: _PanelSwitcher(
          leftActive: appState.leftIsActive,
          onSelect: (left) =>
              appState.activate(left ? appState.left : appState.right),
        ),
      ),
      Expanded(child: _panel(appState.active)),
    ],
  );

  Widget _panel(PanelController controller) {
    final isLeft = identical(controller, _app.left);

    // The box belongs to the panel being searched. It is that listing's
    // question, and in the other panel's corner it would be asking about a
    // listing nobody is looking through.
    final searching = _search != null && identical(controller, _app.active);

    return ChangeNotifierProvider.value(
      value: controller,
      child: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              // Like a context menu: a click in a listing puts the search
              // away. Only listened for, never swallowed, so the click still
              // does whatever it was going to do — moving the cursor, opening
              // a folder — and the search does not survive it.
              onPointerDown: _search == null ? null : (_) => _closeSearch(),
              child: _filePanel(controller, isLeft),
            ),
          ),
          if (searching)
            // **Bottom right, over the size and date.** It used to stand in the
            // bottom left corner, on top of the names — and the cursor walks to
            // whatever matched, so a match near the end of the listing was
            // hidden by the very box that found it. Chosen over a box that
            // dodges the cursor: the size and the date are not what a search
            // is reading, and the name column stays clear.
            Positioned(
              right: 0,
              bottom: 0,
              child: _QuickSearchBox(
                query: _search!,
                caret: _searchCaret,
                matches: _searchMatches,
                onClose: _closeSearch,
              ),
            ),
        ],
      ),
    );
  }

  Widget _filePanel(PanelController controller, bool isLeft) => FilePanel(
    controller: controller,
    // Exactly what Enter does, including running a script in a terminal and
    // stepping into an archive. A double click used to reach the viewer
    // instead, so `.ps1` was shown rather than run.
    //
    // The panel becomes the active one because you are now working in it, not
    // because the opening needs it to be: the row was named by the click.
    onActivateRow: (entry) {
      _app.activate(controller);
      unawaited(_activateEntry(controller, entry));
    },
    onContextMenu: (position, entry) => _showMenu(position, entry),
    onSystemMenu: (position, entry) =>
        unawaited(_showSystemMenu(position, entry)),
    locationKey: isLeft ? _leftLocationKey : _rightLocationKey,
    cursorKey: isLeft ? _leftCursorKey : _rightCursorKey,
    locationMenuOpen: identical(_locationMenuPanel, controller),
    onOpenLocations: (anchor) =>
        unawaited(_showLocationMenu(controller, anchor)),
    onDragOut: (from, sources) => unawaited(_dragOut(from, sources)),
    onDropFiles: _dropFiles,
  );

  // --- Dragging -----------------------------------------------------------

  /// A selection has been picked up in [from] and is on its way to whoever
  /// wants it — the other panel, Explorer, Finder, a text editor's window.
  ///
  /// The desktop is handed real files and nothing else. Anything the panel is
  /// showing that is not a file on this disk — a file on a server, an entry
  /// inside an archive — is fetched first, because "drag it out" and "download
  /// it" are the same act from the far side of the window.
  Future<void> _dragOut(PanelController from, List<VfsPath> sources) async {
    final native = await _app.clipboard.nativePathsFor(sources);
    if (native == null || native.isEmpty || !mounted) return;

    final did = await _app.drags.dragOut(
      sources: sources,
      nativePaths: native,
      allowMove: !from.isReadOnly,
    );
    if (!mounted || did != TransferIntent.move) return;

    // Twice, and neither is one too many. The folder is re-read now, for the
    // ordinary case where the files have already gone; and once more a moment
    // later, because the application that took them is doing the moving on its
    // own clock and may not have finished while this line ran.
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _rereadLocalPanels();
      }),
    );

    // **Nothing is deleted here, and that is the whole of the rule.**
    //
    // A move out of the window is performed by whoever took the files — Finder
    // does it, Explorer does it — and the only thing left to do is show the
    // folder as it now is. Deleting what is still on disk looks like finishing
    // the job and is exactly backwards: if the file is still there, it is
    // because the other side did *not* take it. Finder asks "replace?" after
    // it has already reported the drag as a move, so a cancelled replace and a
    // completed move look identical from here — and one of the two answers
    // destroys the file. This is the mirror of the rule for drags coming *in*,
    // where the move is ours to perform and never theirs.
    await _refreshWhereChanged([from.location, ..._parentsOf(sources)]);
    from.clearMarks();
  }

  /// Files were let go over a panel. Everything about how that is carried out —
  /// the progress, the collisions, the refresh — is the same machinery F5 goes
  /// through, and deliberately so.
  Future<void> _dropFiles(
    List<VfsPath> sources,
    VfsPath target,
    TransferIntent intent,
  ) async {
    await _runTransfer(
      sources: sources,
      target: target,
      move: intent == TransferIntent.move,
      ask: false,
    );
  }

  /// Fetches locations that are not files on this disk into a folder that is,
  /// so they can be handed to a desktop that only knows about files.
  ///
  /// Returns null when the user stopped it or nothing could be fetched. The
  /// folder is the system's temporary one and is left to the system to clear:
  /// what has been dragged out of a server and into a text editor must go on
  /// existing for as long as that editor holds it open, and we are not the ones
  /// who can know when that is.
  Future<List<String>?> _materialise(List<VfsPath> sources) async {
    if (sources.isEmpty) return null;
    final temporary = await Directory.systemTemp.createTemp('xverb-drag-');
    if (!mounted) return null;

    final target = VfsPath.local(temporary.path);
    final result = await runWithProgress(
      context,
      title: tr('Fetching…'),
      task: (onProgress, token) => _app.operations.copy(
        sources,
        target,
        onConflict: (source, existing) async => ConflictAction.autoRename,
        onProgress: onProgress,
        token: token,
      ),
    );
    if (result.cancelled || result.hasErrors) {
      if (mounted && result.hasErrors) showOperationResult(context, result);
      return null;
    }
    return sources
        .map((path) => '${temporary.path}${Platform.pathSeparator}${path.name}')
        .toList(growable: false);
  }

  // --- Key handling -------------------------------------------------------

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // Before the up events are dropped, because letting Shift go is exactly
    // what the F-key row has to hear: F6 says which of its two things it would
    // do while Shift is down, and a row still saying it after the key came up
    // is a row that lies.
    _syncShiftHeld();

    if (event is KeyUpEvent) return KeyEventResult.ignored;

    // An open window has the keyboard. Whatever it did not use bubbles up to
    // here, and must not reach the panels behind it.
    if (_windows.isNotEmpty) return KeyEventResult.ignored;

    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed || keys.isMetaPressed;
    final shift = keys.isShiftPressed;
    final alt = keys.isAltPressed;
    final key = event.logicalKey;

    // F10 leaves a selector on the menu bar, and while it is there the bar has
    // the keyboard: the arrows walk the titles instead of the listing. Checked
    // before everything else for exactly that reason.
    if (_menuKeys.selecting) {
      final handled = _onMenuBarKey(key);
      if (handled != null) return handled;
    }

    // While the command line is being edited it has the keyboard, and what it
    // does not use arrives here — Escape among it, because a text field has no
    // use for one. Caught before anything else, or the panel's Escape would
    // clear the line and leave the input still sitting there.
    if (_editingCommand) {
      if (key == LogicalKeyboardKey.escape) {
        _escapeInConsole();
        return KeyEventResult.handled;
      }
      // Ctrl+Up is the way out, facing the Ctrl+Down that came in. Checked
      // before the bare arrows below, which belong to the history.
      if (ctrl && key == LogicalKeyboardKey.arrowUp) {
        _endCommandEditing();
        return KeyEventResult.handled;
      }
      // The console is not a place where the main menu stops existing. Alt
      // belongs to the menu strip wherever the keyboard happens to be, and a
      // field has no use for it.
      if (alt && !ctrl) return _onAltKey(key, event);
      // Shift+Insert, which the field itself does not answer to — Ctrl+V it
      // already knows. Claimed here, before the field, for the same reason Tab
      // is: a binding the console has to have cannot depend on what Flutter
      // happens to bind on this platform.
      if (shift && key == LogicalKeyboardKey.insert) {
        unawaited(_pasteIntoCommandLine());
        return KeyEventResult.handled;
      }
      // The one Control binding that is about the console itself.
      if (ctrl && key == LogicalKeyboardKey.keyO) {
        _app.commandLine.toggleConsole();
        return KeyEventResult.handled;
      }
      // Tab completes the name being typed. Claimed here and never passed on:
      // left alone it reaches the framework's focus traversal and moves the
      // keyboard to whatever widget happens to be next, which is why pressing
      // it in the console did something different depending on whether the
      // console was open. Switching panels with it is a panel binding and has
      // no business in a command line.
      if (key == LogicalKeyboardKey.tab) {
        _completeName(backwards: shift);
        return KeyEventResult.handled;
      }
      // A single-line field has no use for Up and Down, so they arrive here
      // unclaimed — which is what the command history wants them for. Nothing
      // else on the desk puts its history anywhere else.
      if (key == LogicalKeyboardKey.arrowUp) {
        _recallCommand(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _recallCommand(-1);
        return KeyEventResult.handled;
      }

      // Everything else belongs to the field, and a cursor that walks the
      // listing while a command is being typed is the panels answering keys
      // the user is aiming somewhere else.
      return KeyEventResult.ignored;
    }

    // A field somewhere on the screen has the keyboard — a plugin's form, the
    // message a commit is being written in. **Its characters arrive here as
    // well**, because a text field takes what is typed through the platform's
    // input connection and lets the key events go on up unclaimed; claiming
    // them here typed the commit message into the command line at the same
    // time, and gave the panel's own keys — space, Insert, the function row —
    // a second job while somebody was writing a sentence.
    //
    // Alt is the exception, and only Alt: the menu strip exists wherever the
    // keyboard is, and a field has no use for it. Escape is deliberately not
    // one — the form answers that itself, taking the keyboard out of the field
    // and leaving the next press to mean "out of this page".
    if (keyboardIsInAField()) {
      if (alt && !ctrl) return _onAltKey(key, event);
      return KeyEventResult.ignored;
    }

    // Quick search owns the keyboard while it is open.
    if (_search != null) {
      final handled = _onSearchKey(event, key, ctrl, alt);
      if (handled != null) return handled;
    }

    // Modifier combinations are checked before the plain keys, otherwise
    // Alt+F2 would be swallowed by the F2 rename binding.
    //
    // Ctrl+Alt first, and it falls through when it does not want the key, so
    // Ctrl+Alt+R still refreshes.
    if (ctrl && alt) {
      final handled = _onCtrlAltKey(key, event);
      if (handled != null) return handled;
    }
    if (alt && !ctrl) return _onAltKey(key, event);
    if (ctrl) return _onCtrlKey(key, shift);

    return _onPlainKey(key, shift, event);
  }

  /// Whether Shift is down, as far as the F-key row is concerned.
  bool _shiftHeld = false;

  void _syncShiftHeld() {
    final held = HardwareKeyboard.instance.isShiftPressed;
    if (held == _shiftHeld || !mounted) return;
    setState(() => _shiftHeld = held);
  }

  /// The keys that belong to the menu bar while F10 has put the selector on it.
  ///
  /// Dictated 2026-08-12: F10 enters the menu **without opening it**, the
  /// selector goes round the titles and the tools icons in a circle, and Down is
  /// what unrolls one. Escape puts the keyboard back where it was, which is rule
  /// number one.
  ///
  /// Returns null for anything else, so a key the bar has no use for still
  /// reaches the panels rather than being swallowed by a state the user may have
  /// forgotten they are in.
  KeyEventResult? _onMenuBarKey(LogicalKeyboardKey key) {
    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
        _menuKeys.step(-1);
      case LogicalKeyboardKey.arrowRight:
        _menuKeys.step(1);
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _menuKeys.activateSelected();
      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.f10:
        _menuKeys.leave();
      default:
        return null;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _onAltKey(LogicalKeyboardKey key, KeyEvent event) {
    // Alt+Tab walks the parts too, where the desktop lets it through. **On
    // Windows it never will** — Alt+Tab is the window switcher there and the
    // application is not asked — so Ctrl+Tab is the binding that is promised
    // and this one is the convenience.
    if (key == LogicalKeyboardKey.tab) {
      final attachment = _app.active.attachment;
      if (attachment != null &&
          attachment.focusNextPart(
            backwards: HardwareKeyboard.instance.isShiftPressed,
          )) {
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.f1) {
      unawaited(_openLocationMenu(_app.left));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2) {
      unawaited(_openLocationMenu(_app.right));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f7) {
      unawaited(showSearchWindow(context));
      return KeyEventResult.handled;
    }
    // Total Commander's two archive keys, and they are here rather than only in
    // the menu because a command the keyboard cannot reach is not a command.
    if (key == LogicalKeyboardKey.f5) {
      unawaited(_pack(toOtherPanel: true));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f9) {
      final entry = _entryUnderCursor;
      if (entry != null) unawaited(_extract(entry, intoFolder: false));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter &&
        HardwareKeyboard.instance.isShiftPressed) {
      unawaited(_app.active.computeMarkedSizes());
      return KeyEventResult.handled;
    }

    // Quick search, when that is the key chosen for it. Nothing on the menu
    // strip answers to S, so this takes no letter away from it — but it is
    // checked before the strip is asked, because the search is what S is for
    // here.
    final binding = bindingLetter(event);
    if (binding == 's' && _searchOpener == QuickSearchOpener.altS) {
      _startSearch('');
      return KeyEventResult.handled;
    }

    // Alt+F opens File, and so on down the strip — where every other
    // application on the desk puts its menus. Quick search moved to Ctrl+Alt to
    // make room for this.
    if (binding != null && _menuKeys.open(binding)) {
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// Ctrl+Alt+letter starts quick search.
  ///
  /// Alt+letter used to, and Alt on its own is wanted for the menus, where every
  /// other application on the desk already puts it — Alt+F for File. The
  /// character is usually null while these modifiers are held, so the key's own
  /// label stands in for it.
  ///
  /// The **right** Alt is deliberately left out. On a great many layouts it is
  /// AltGr, which the platform reports as Control and Alt together, and claiming
  /// that would take the characters it composes away from the command line.
  ///
  /// Returns null for anything it does not want, so the plain Control bindings
  /// still see the key.
  KeyEventResult? _onCtrlAltKey(LogicalKeyboardKey key, KeyEvent event) {
    // One opener is live at a time, so with Alt+S chosen this binding is not
    // merely unused: it must not fire, or Ctrl+Alt+R would start a search
    // instead of refreshing.
    if (_searchOpener != QuickSearchOpener.ctrlAltLetter) return null;

    if (!HardwareKeyboard.instance.logicalKeysPressed
        .contains(LogicalKeyboardKey.altLeft)) {
      return null;
    }

    final typed = _printableOf(event, key);
    if (typed == null) return null;

    _startSearch(typed);
    return KeyEventResult.handled;
  }

  KeyEventResult _onCtrlKey(LogicalKeyboardKey key, bool shift) {
    // **Ctrl+Tab walks the parts of whatever is in the panel**, and it is the
    // one binding that means that wherever the tool happens to be. Tab itself
    // cannot: in a panel it is the panel switch and always has been, so a tool
    // in a panel had a list it could reach with the mouse and with nothing
    // else. Full screen Tab does it as well, because there the application has
    // one to spare — but a key that works on one surface and not on the other
    // is a key nobody trusts, and this one is both.
    if (key == LogicalKeyboardKey.tab) {
      final attachment = _app.active.attachment;
      if (attachment != null && attachment.focusNextPart(backwards: shift)) {
        return KeyEventResult.handled;
      }
    }

    switch (key) {
      // Total Commander's sort bindings. Repeating one flips the direction.
      case LogicalKeyboardKey.f3:
        _settings.applySort(SortColumn.name);
      case LogicalKeyboardKey.f4:
        _settings.applySort(SortColumn.extension);
      case LogicalKeyboardKey.f5:
        _settings.applySort(SortColumn.modified);
      case LogicalKeyboardKey.f6:
        _settings.applySort(SortColumn.size);

      // Out of the folder and into the one under the cursor — the pair Total
      // Commander puts on the page keys, and the only pair that goes anywhere.
      case LogicalKeyboardKey.pageUp:
        unawaited(_app.active.goUp());
      case LogicalKeyboardKey.pageDown:
        unawaited(_enterDirectory());

      // The ends of the listing. Ctrl+Up used to walk out of the folder, which
      // it does in no file manager: there it makes a tab, and there are no tabs
      // here. Sending it where Ctrl+Home goes at least makes it a movement key,
      // which is what its arrow says it is.
      case LogicalKeyboardKey.home:
      case LogicalKeyboardKey.arrowUp:
        _app.active.setCursor(0);
      case LogicalKeyboardKey.end:
        _app.active.setCursor(_app.active.entries.length - 1);

      // Total Commander drops the command line's history here. Ours has no
      // list to drop, so it does the half of that which is worth having: puts
      // the keyboard in the line, ready to type.
      case LogicalKeyboardKey.arrowDown:
        _beginCommandEditing();

      case LogicalKeyboardKey.arrowLeft:
        unawaited(_openInPanel(_app.left));
      case LogicalKeyboardKey.arrowRight:
        unawaited(_openInPanel(_app.right));

      case LogicalKeyboardKey.keyA:
        _app.active.markAll();
      case LogicalKeyboardKey.keyR:
        unawaited(_app.active.refresh());
      case LogicalKeyboardKey.keyH:
        _settings.updateAppearance(
          (a) => a.copyWith(showHidden: !a.showHidden),
        );
      case LogicalKeyboardKey.keyU:
        _swapPanels();
      case LogicalKeyboardKey.keyF:
        _startSearch('');
      case LogicalKeyboardKey.keyO:
        // Shift asks for a terminal of the machine's own instead of ours.
        if (shift) {
          unawaited(_openTerminalHere());
        } else {
          _app.commandLine.toggleConsole();
        }
      case LogicalKeyboardKey.keyE:
        // Total Commander recalls the previous command with Ctrl+E.
        _app.commandLine.recall(shift ? -1 : 1);
      case LogicalKeyboardKey.keyQ:
        unawaited(_views.toggleQuickView());
      // The three clipboard keys. Ctrl+V is the one with two meanings, and
      // what is on the clipboard decides which — see [_pasteHere].
      case LogicalKeyboardKey.keyC:
        // Shift asks for the path as text, which is what Ctrl+C used to be
        // reached for here before there were files on the clipboard at all.
        if (shift) {
          final entry = _entryUnderCursor;
          if (entry != null) unawaited(_copyPath(entry));
        } else {
          unawaited(_copyToClipboard(cut: false));
        }
      case LogicalKeyboardKey.keyX:
        unawaited(_copyToClipboard(cut: true));
      case LogicalKeyboardKey.insert:
        // Ctrl+Insert is the older copy, and the one a commander user's hand
        // goes to. Both, for the same reason Shift+Insert pastes.
        unawaited(_copyToClipboard(cut: false));
      case LogicalKeyboardKey.keyV:
        unawaited(_pasteHere());
      case LogicalKeyboardKey.backspace:
        _app.commandLine.deleteWord();

      // A tool in a panel, put on the whole window. The other half of it lives
      // on the page, which sends the view back here — the same key both ways,
      // because it is one movement and not two commands.
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (!shift) return KeyEventResult.ignored;
        unawaited(_views.toFullScreen(context, _app.active));

      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _pasteIntoCommandLine() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    // Newlines would silently submit several commands at once.
    final line = text.replaceAll(RegExp(r'[\r\n]+'), ' ');

    // With no field up there is no caret to land at: the line is a string the
    // panel is holding and the paste goes on the end of it.
    if (!_editingCommand) {
      _app.commandLine.insert(line);
      return;
    }

    // With the field up it lands at the caret and takes the selection with it,
    // which is what paste means everywhere else on the desk. An invalid
    // selection — a field that has never been put a caret in — is the end.
    final value = _commandText.value;
    final at = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final grown = value.text.replaceRange(at.start, at.end, line);

    _commandText.value = TextEditingValue(
      text: grown,
      selection: TextSelection.collapsed(offset: at.start + line.length),
    );
    // The controller is not the state — setting `value` does not run the
    // field's `onChanged`, the same trap `_applyCompletion` documents.
    _app.commandLine.setText(grown);
  }

  KeyEventResult _onPlainKey(
    LogicalKeyboardKey key,
    bool shift,
    KeyEvent event,
  ) {
    final panel = _app.active;

    // A view that asked for the keyboard gets first refusal on it, and only
    // while it is the one being worked in. Anything it does not take falls
    // through to the panel's own bindings, so Tab and the function row never
    // stop working.
    if (panel.isAttached && key != LogicalKeyboardKey.escape) {
      final named = _viewKeyName(key, event);
      if (named != null && _sendKeyToView(panel, named)) {
        return KeyEventResult.handled;
      }
      // Whatever the view did not want, the table underneath it might. Moving
      // a cursor along a listing is the host's job wherever the listing came
      // from — a plugin that had to answer four arrow keys to be usable would
      // be a plugin nobody writes.
      if (driveTable(panel.attachment, key)) return KeyEventResult.handled;
    }

    switch (key) {
      case LogicalKeyboardKey.tab:
        _app.toggleActivePanel();

      // Every movement key comes in two: on its own it moves the cursor, with
      // Shift it drags a selection along behind it, which is how a run of files
      // is marked in Total Commander. `selectTo` is anchored, so walking back
      // over what was just marked gives it up again.
      case LogicalKeyboardKey.arrowDown:
        _move(panel, panel.cursorIndex + 1, shift);
      case LogicalKeyboardKey.arrowUp:
        _move(panel, panel.cursorIndex - 1, shift);
      // A page of the listing as it stands on screen, not a fixed twenty rows
      // — see `PanelController.visibleRows`.
      case LogicalKeyboardKey.pageDown:
        _move(panel, panel.cursorIndex + panel.visibleRows, shift);
      case LogicalKeyboardKey.pageUp:
        _move(panel, panel.cursorIndex - panel.visibleRows, shift);
      case LogicalKeyboardKey.home:
        _move(panel, 0, shift);
      case LogicalKeyboardKey.end:
        _move(panel, panel.entries.length - 1, shift);

      // Ours, and deliberately not Total Commander's: a file panel here has one
      // column, so left and right have nothing to move along, and a hand
      // already on the arrows should not have to find Home. No Shift form —
      // these are jumps rather than steps, and dragging a selection the whole
      // length of a listing is what Shift+End is for.
      case LogicalKeyboardKey.arrowLeft:
        panel.setCursor(0);
      case LogicalKeyboardKey.arrowRight:
        panel.setCursor(panel.entries.length - 1);

      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        // A typed command takes precedence over the cursor row, as in
        // Total Commander.
        if (!_app.commandLine.isEmpty) {
          unawaited(_runCommand());
        } else {
          unawaited(_activate(panel));
        }
      case LogicalKeyboardKey.backspace:
        // Always the command line, never "up a level". One key meaning two
        // things depending on whether anything had been typed was a key nobody
        // could predict: it edited the line when there was a line and walked out
        // of the folder when there was not. Going up is Ctrl+PageUp.
        _app.commandLine.backspace();

      case LogicalKeyboardKey.insert:
        // Shift+Insert is the older of the two pastes and the one a commander
        // user reaches for. Both keys, not one instead of the other — and the
        // Shift is what keeps Insert's own meaning, which is marking a row.
        if (shift) {
          unawaited(_pasteHere());
        } else {
          panel.toggleMarkAtCursor();
        }
      case LogicalKeyboardKey.space:
        // Once a command is being typed, space belongs to it. With an empty
        // command line it marks and measures, the way Total Commander does.
        if (!_app.commandLine.isEmpty) {
          _app.commandLine.insert(' ');
        } else {
          panel.toggleMarkAtCursor(advance: false, measureDirectory: true);
        }
      case LogicalKeyboardKey.numpadMultiply:
        panel.invertMarks();

      case LogicalKeyboardKey.escape:
        _onEscape(panel);

      // The key next to the right Control, and Shift+F10, which is what the
      // desktop uses for the same thing on a keyboard that has not got one.
      case LogicalKeyboardKey.contextMenu:
        unawaited(_menuAtCursor(panel));
      // F10 on its own is the menu bar's, as it has been since Windows 3:
      // the selector lands on the first title and nothing is unrolled until
      // Down asks for it. See [_onMenuBarKey].
      case LogicalKeyboardKey.f10:
        if (shift) {
          unawaited(_menuAtCursor(panel));
        } else {
          _menuKeys.enter();
        }

      case LogicalKeyboardKey.f2:
        unawaited(_rename());
      case LogicalKeyboardKey.f3:
        unawaited(_viewCursor(choose: shift));
      case LogicalKeyboardKey.f4:
        unawaited(_editCursor());
      case LogicalKeyboardKey.f5:
        // Shift asks for a name to land under, the way Total Commander does.
        if (shift) {
          unawaited(_copyAs());
        } else {
          unawaited(_transfer(move: false));
        }
      case LogicalKeyboardKey.f6:
        // Shift+F6 is Total Commander's: one file and it renames the way F2
        // does, several and it moves the way F6 does. See [_renameOrMove].
        if (shift) {
          unawaited(_renameOrMove());
        } else {
          unawaited(_transfer(move: true));
        }
      case LogicalKeyboardKey.f7:
        unawaited(_createDirectory());
      case LogicalKeyboardKey.f8:
      case LogicalKeyboardKey.delete:
        // Shift means "skip the recycle bin", as everywhere else on the desktop.
        unawaited(_delete(toTrash: !shift));
      case LogicalKeyboardKey.f9:
        unawaited(_openSettings());
      // The console takes the window. It opens the console if it was not
      // showing, because a key that does nothing until
      // another one has been pressed is a key that looks broken.
      case LogicalKeyboardKey.f11:
        _app.commandLine.toggleConsoleFullScreen();

      default:
        final typed = _printableOf(event, key);
        if (typed == null) return KeyEventResult.ignored;
        // The third way into quick search, and the only one that is not a
        // chord: with **Typing** chosen a letter pressed in a panel opens the
        // box already holding it. The rule is about where the keyboard is
        // rather than about the keys — this branch is the panel's, and the
        // console's own letters were answered long before the key reached
        // here, so in there a letter is still a letter.
        //
        // Under the other two openers plain typing goes to the command line,
        // as it always has, and the search waits for its chord.
        if (_searchOpener == QuickSearchOpener.typing && _takesTypedText(typed)) {
          _startSearch(typed);
        } else {
          _app.commandLine.insert(typed);
        }
        return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  /// Characters that can never begin a quick search.
  ///
  /// **A search starts on a character a name could hold, and on nothing else.**
  /// There is nothing for such a character to match, so what it does instead is
  /// what it always did: it goes to the command line.
  ///
  /// The two separators are here on every system, backslash included — a POSIX
  /// name may legally hold one, and it is the key that takes the panel to the
  /// root. Windows forbids the rest.
  ///
  /// The dot is not in this set and is turned away for a different reason —
  /// see [_takesTypedText].
  static final _notInAName = RegExp(
    Platform.isWindows ? r'[\\/:*?"<>|]' : r'[\\/]',
  );

  /// Whether a character typed in a panel belongs to quick search rather than
  /// to the command line, with **Typing** chosen as the opener.
  ///
  /// **The dot is the reason this is a question at all.** A bare `.` typed into
  /// the line and entered opens this folder in the desktop's own file manager,
  /// `..` walks out of it, and a bare `/` goes to the root — see
  /// `CommandLine._runBuiltin`, which is built for exactly those. A search that
  /// swallowed the first dot would take them away, so until the search has
  /// started, a dot is the console's.
  ///
  /// What follows the dot is the console's too, or `.\name` would break in the
  /// middle of being typed: **once there is anything on the line, typing goes
  /// on into it**. The line is drawn along the bottom, so this is not a mode
  /// anybody is left guessing about, and Escape clears it.
  ///
  /// None of this applies once the box is up: what is typed then is being added
  /// to a query rather than starting one, and a name with an odd character in
  /// it is still a name to look for.
  bool _takesTypedText(String typed) {
    if (!_app.commandLine.isEmpty) return false;
    if (_notInAName.hasMatch(typed)) return false;
    // Nothing on the line yet, so the character decides — and the dot is the
    // one printable key that already means something here on its own.
    return typed != '.';
  }

  /// A movement key, with or without the Shift that turns it into a selection.
  void _move(PanelController panel, int to, bool shift) =>
      shift ? panel.selectTo(to) : panel.setCursor(to);

  static final _letterOrDigit = RegExp(r'[A-Za-z0-9]');

  /// The character a key would type, or null if it is not a printable key.
  ///
  /// With Alt held the key's own label is asked **first**. Windows suppresses
  /// the character while Alt is down, so there the label was only ever needed
  /// as a fallback; macOS instead *composes* — Option+A is a real `å`, Option+D
  /// a real `∂`, and Option+E is a dead key whose mark lands on the next press
  /// — so trusting the character first handed quick search and the menu strip
  /// whatever the compose table produced rather than the letter that was
  /// pressed.
  String? _printableOf(KeyEvent event, LogicalKeyboardKey key) {
    if (HardwareKeyboard.instance.isAltPressed) {
      final letter = _letterOf(key);
      if (letter != null) return letter;
    }
    final character = event.character;
    if (character != null &&
        character.length == 1 &&
        character.trim().isNotEmpty) {
      return character;
    }
    return _letterOf(key);
  }

  /// The plain letter or digit a key stands for, with no composition applied.
  String? _letterOf(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.length == 1 && _letterOrDigit.hasMatch(label)) {
      return label.toLowerCase();
    }
    return null;
  }


  // --- Quick search -------------------------------------------------------

  /// The one place the query is written down.
  ///
  /// The bar along the bottom draws it, and the panel needs it too — the rows
  /// that do not answer it are faded rather than merely skipped over. Only the
  /// panel being searched: the other one is not being asked a question, and
  /// leaving a query on it would fade a listing nobody is looking through.
  void _setSearch(String? query, {int? caret}) {
    _search = query;
    final length = query?.length ?? 0;
    _searchCaret = (caret ?? length).clamp(0, length);
    _app.active.setSearchQuery(query);
    _app.inactive.setSearchQuery(null);
  }

  /// Which key the settings say opens quick search. There is only one search;
  /// this is how it is reached.
  QuickSearchOpener get _searchOpener =>
      _settings.appearance.quickSearchOpener;

  void _startSearch(String initial) {
    setState(() {
      _setSearch(initial);
      _searchMatches = initial.isEmpty ? 0 : _app.active.findMatches(initial);
    });
  }

  void _closeSearch() {
    if (_search == null) return;
    setState(() {
      _setSearch(null);
      _searchMatches = 0;
    });
  }

  /// Returns null to let the key fall through to the normal bindings.
  KeyEventResult? _onSearchKey(
    KeyEvent event,
    LogicalKeyboardKey key,
    bool ctrl,
    bool alt,
  ) {
    final panel = _app.active;

    switch (key) {
      case LogicalKeyboardKey.escape:
        _closeSearch();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _closeSearch();
        return null; // Enter still opens whatever the cursor landed on.

      case LogicalKeyboardKey.backspace:
        setState(() {
          final query = _search!;
          if (query.isEmpty) {
            _setSearch(null);
            return;
          }
          // Nothing to the left of the caret to take away.
          final at = _searchCaret;
          if (at == 0) return;
          _setSearch(
            query.substring(0, at - 1) + query.substring(at),
            caret: at - 1,
          );
          _searchMatches = _search!.isEmpty ? 0 : panel.findMatches(_search!);
        });
        return KeyEventResult.handled;

      // The caret keys, which while the box is up move through the typed text
      // rather than through the listing — whichever key opened it.
      case LogicalKeyboardKey.arrowLeft:
        setState(
          () => _searchCaret = (_searchCaret - 1).clamp(0, _search!.length),
        );
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowRight:
        setState(
          () => _searchCaret = (_searchCaret + 1).clamp(0, _search!.length),
        );
        return KeyEventResult.handled;

      case LogicalKeyboardKey.home:
        setState(() => _searchCaret = 0);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.end:
        setState(() => _searchCaret = _search!.length);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowDown:
        setState(
          () => _searchMatches = panel.findMatches(_search!, direction: 1),
        );
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowUp:
        setState(
          () => _searchMatches = panel.findMatches(_search!, direction: -1),
        );
        return KeyEventResult.handled;
    }

    if (!ctrl && !alt) {
      final typed = _printableOf(event, key);
      if (typed != null) {
        setState(() {
          final query = _search!;
          final at = _searchCaret;
          _setSearch(
            query.substring(0, at) + typed + query.substring(at),
            caret: at + typed.length,
          );
          _searchMatches = panel.findMatches(_search!);
        });
        return KeyEventResult.handled;
      }
    }

    // Anything that is neither a caret key nor part of a name ends the search
    // and is then handled normally — the function row included, which is why
    // F5 still copies while a search is open.
    _closeSearch();
    return null;
  }

  /// Escape unwinds one thing at a time, most transient first.
  void _onEscape(PanelController panel) {
    if (_search != null) {
      _closeSearch();
      return;
    }
    if (!_app.commandLine.isEmpty) {
      _app.commandLine.clear();
      return;
    }
    if (_app.commandLine.isRunning) {
      _app.commandLine.cancel();
      return;
    }
    if (_app.commandLine.consoleVisible) {
      // Out of full screen first, then away altogether: Escape goes back one
      // state at a time, which is the rule the whole application follows.
      if (_app.commandLine.consoleFullScreen) {
        _app.commandLine.toggleConsoleFullScreen();
        return;
      }
      _app.commandLine.toggleConsole();
      return;
    }
    // Whatever has the panel goes before the marks do: a view filling the
    // panel is the most recent thing the user opened, so it is the thing
    // Escape is about — and a page the view put over its own is more recent
    // still, so that comes off first.
    if (panel.isAttached) {
      final attachment = panel.attachment;
      if (attachment != null && attachment.canGoBack) {
        unawaited(attachment.goBack());
        return;
      }
      unawaited(panel.detach());
      return;
    }
    if (_app.inactive.isAttached) {
      // Quick view lives in the *other* panel, and Escape in the one being
      // navigated is how it is put away — nobody moves the cursor over there
      // to close it.
      unawaited(_app.inactive.detach());
      return;
    }
    // A panel showing nothing but a message has no rows to move through, so
    // Escape is the only way out of it that does not need the mouse.
    if (panel.error != null) {
      unawaited(panel.leaveError());
      return;
    }
    // **Marks first, and the journey after.** One state at a time, and marks
    // are the more recent of the two: reading history and picking files out of
    // it to copy is exactly what somebody is doing in here, and Escape taking
    // them out of the commit instead of clearing the selection would be the
    // wrong half undone.
    if (panel.markedCount > 0) {
      panel.clearMarks();
      return;
    }
    // The way out of where a tool sent this panel — the same thing the control
    // at the head of the path bar does, because a control the keyboard cannot
    // reach does not exist.
    if (panel.wayBack != null) {
      unawaited(ViewLauncher(_app).takeTheWayBack(context, panel));
      return;
    }
    panel.clearMarks();
  }

  // --- Views ---------------------------------------------------------------

  /// Runs whichever kind of thing was picked from a menu or a title-bar icon.
  Future<void> _runOffer(PluginOffer offer) async {
    final view = offer.view;
    if (view != null) return _openView(view);

    final command = offer.command;
    if (command != null) return runPluginCommand(context, command);
  }

  /// The name a view is told a key by, or null for keys a view never sees.
  ///
  /// The function row and Tab are not on the list on purpose: they belong to
  /// the application whatever is in the panel, and a view that could swallow
  /// F5 would be a view that can break copying.
  String? _viewKeyName(LogicalKeyboardKey key, KeyEvent event) => switch (key) {
    LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => 'enter',
    LogicalKeyboardKey.backspace => 'backspace',
    LogicalKeyboardKey.arrowUp => 'up',
    LogicalKeyboardKey.arrowDown => 'down',
    LogicalKeyboardKey.arrowLeft => 'left',
    LogicalKeyboardKey.arrowRight => 'right',
    LogicalKeyboardKey.pageUp => 'pageup',
    LogicalKeyboardKey.pageDown => 'pagedown',
    LogicalKeyboardKey.home => 'home',
    LogicalKeyboardKey.end => 'end',
    _ => _printableOf(event, key),
  };

  /// True when the key went to a view. Only a view that declared `keys` gets
  /// one; everything else leaves the panel's own bindings alone.
  bool _sendKeyToView(PanelController panel, String key) {
    final attachment = panel.attachment;
    if (attachment is! PluginViewAttachment || !attachment.wantsKeys) {
      return false;
    }
    unawaited(attachment.handleKey(key));
    return true;
  }

  /// Opens a view, wherever it belongs. See [ViewLauncher].
  Future<void> _openView(RegisteredView view, {PanelController? panel}) =>
      _views.open(
        context,
        view,
        panel: panel,
        onReturn: () {
          if (mounted) _keyboard.requestFocus();
        },
      );

  // --- The command line ----------------------------------------------------

  /// The line was pressed. The input starts on what is already typed, with the
  /// caret after it — pressing a line to correct one word should not throw the
  /// rest of it away.
  void _beginCommandEditing() {
    final typed = _app.commandLine.text;
    _commandText.value = TextEditingValue(
      text: typed,
      selection: TextSelection.collapsed(offset: typed.length),
    );
    if (_editingCommand) return;
    setState(() => _editingCommand = true);
    // Said out loud, so the panels can go pale. Two places to be, and which one
    // you are in has to be visible without pressing a key to find out.
    _app.keyboardInCommandLine = true;

    // Asked for after the frame that builds the field, and asked for
    // explicitly. `autofocus` is not enough: it only takes effect when nothing
    // in the enclosing scope holds focus, and the commander's own node always
    // does — so the field came up with a blinking cursor while every keystroke
    // still went to the panels, which put the text in the drawn line the field
    // was covering.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingCommand) _commandInput.requestFocus();
    });
  }

  /// Gives the keyboard back to the panels.
  ///
  /// Explicitly, rather than by unfocusing: with nothing focused the
  /// commander's own handler stops being reached, and every key binding in the
  /// application would go quiet until something was clicked.
  void _endCommandEditing() {
    if (!_editingCommand) return;
    setState(() => _editingCommand = false);
    _app.keyboardInCommandLine = false;
    _commandInput.unfocus();
    _keyboard.requestFocus();
  }

  /// Walks the commands already entered. [delta] of 1 is the older one.
  ///
  /// The drawn line and the input are two views of the same text, so the one
  /// that is up has to be told: recalling into a field still showing the last
  /// thing typed would look like nothing happened.
  void _recallCommand(int delta) {
    final line = _app.commandLine;
    line.recall(delta);
    _commandText.value = TextEditingValue(
      text: line.text,
      selection: TextSelection.collapsed(offset: line.text.length),
    );
  }

  Future<void> _runCommand() async {
    final panel = _app.active;
    final destination = await _app.commandLine.submit(location: panel.location);
    // The line is cleared by submit; the input has to be told, or the command
    // just run is still sitting in it.
    _commandText.clear();
    if (destination != null) await panel.navigateTo(destination);
    // A command usually changed something on disk, and the other panel may be
    // looking at the same folder.
    await _refreshWhereChanged([panel.location]);
    if (mounted) _takeKeyboardBack();
  }

  /// Escape in the command line, one rung at a time.
  ///
  /// A half-typed command, an open console and being in the console at all are
  /// three things to be got out of, and one key gets out of them in the order
  /// they were got into — innermost first. Nothing is ever thrown away and left
  /// behind: the press that clears the line does only that, so the line can be
  /// cleared without also losing the console, and the press that leaves takes
  /// the console down with it because staying open behind a keyboard that is no
  /// longer in it is what made the whole thing ambiguous.
  ///
  ///  * text in the line — clear it
  ///  * console open  — close it and go back to the panel
  ///  * neither       — go back to the panel
  void _escapeInConsole() {
    final line = _app.commandLine;
    if (line.text.isNotEmpty) {
      line.clear();
      _commandText.clear();
      _completions = const [];
      return;
    }
    if (line.consoleVisible) line.toggleConsole();
    _endCommandEditing();
  }

  /// What Tab has grown the word into, and the other names it could grow into.
  ///
  /// Kept between presses so that Tab again offers the next one rather than
  /// starting over on a word it has just finished writing. The line as it was
  /// left is remembered too: anything typed since makes the run stale, and the
  /// next Tab looks at the word that is actually there now.
  List<String> _completions = const [];
  int _completionIndex = -1;
  int _completionStart = 0;
  String? _completedLine;

  /// Tab in the command line: the word under the caret becomes a name from the
  /// listing, and pressing again walks the others it could have been.
  ///
  /// A word with no separator in it is answered from the rows already on
  /// screen and is therefore instant. A word with one — `./te`, `/pro`,
  /// `sub/te` — is about some other folder, and that folder has to be read
  /// first, so those go the long way round.
  void _completeName({required bool backwards}) {
    final value = _commandText.value;
    final caret = value.selection.baseOffset < 0
        ? value.text.length
        : value.selection.baseOffset;

    if (_completedLine != value.text || _completions.isEmpty) {
      _completionStart = NameCompletion.wordStart(value.text, caret);
      _completionIndex = -1;
      final typed = NameCompletion.splitPath(
        NameCompletion.wordAt(value.text, caret),
      );
      if (typed.directory.isNotEmpty) {
        unawaited(_completeFromDisk(typed, caret, backwards: backwards));
        return;
      }
      _completions = NameCompletion.matching(typed.prefix, _namesInPanel());
    }
    _applyCompletion(value.text, caret, backwards: backwards);
  }

  /// How long Tab waits for a folder before giving up on it.
  ///
  /// The same reasoning as the viewer probe's, and nearly the same number: a
  /// key press must not wait for a plugin. Long enough for a local folder of
  /// thousands and for an archive already open; short enough that a server
  /// which is not answering costs one beat rather than a stuck line.
  static const Duration _completionPatience = Duration(milliseconds: 1200);

  /// The half of Tab that has to read a folder before it can answer.
  Future<void> _completeFromDisk(
    TypedPath typed,
    int caret, {
    required bool backwards,
  }) async {
    final panel = _app.active;
    final location = panel.location;
    if (location == null) return;
    final directory = NameCompletion.directoryOf(location, typed.directory);
    // Walked up past a root, or somewhere no provider claims. Nothing to say,
    // and saying nothing is the whole of the right answer.
    if (directory == null || !panel.registry.supports(directory.scheme)) return;

    final List<FileEntry> entries;
    try {
      entries = await panel.registry
          .resolve(directory)
          .list(directory)
          // **A key press must not wait for a server.** The folder may be on
          // FTP or inside an archive on FTP, where listing it is a round trip
          // and can be a slow one — and a completion that arrives after the
          // typing has moved on is worse than no completion, because it
          // rewrites a line somebody is in the middle of. The caret is checked
          // below for the same reason; this is the half of it that a caret
          // sitting still cannot catch.
          .timeout(_completionPatience);
    } on Object {
      // A folder that is not there, not readable, or too slow to be worth a
      // keystroke. Tab is not the place to report any of them: the user is
      // still typing the path.
      return;
    }
    if (!mounted) return;

    // The line as it is *now*: reading a folder takes time, and in that time
    // the keystroke may have been overtaken by typing.
    final value = _commandText.value;
    final at = value.selection.baseOffset < 0
        ? value.text.length
        : value.selection.baseOffset;
    if (at != caret) return;

    _completions = NameCompletion.matching(typed.prefix, _namesOf(entries))
        // Each candidate carries the path the user typed, because what is
        // replaced is the whole word — `./te` becomes `./temp\`, not `temp\`.
        .map((name) => '${typed.directory}$name')
        .toList();
    _applyCompletion(value.text, at, backwards: backwards);
  }

  void _applyCompletion(String text, int caret, {required bool backwards}) {
    if (_completions.isEmpty) return;

    _completionIndex =
        (_completionIndex + (backwards ? -1 : 1)) % _completions.length;
    final grown = NameCompletion.replace(
      text,
      _completionStart,
      caret,
      _completions[_completionIndex],
    );

    _completedLine = grown.text;
    _commandText.value = TextEditingValue(
      text: grown.text,
      selection: TextSelection.collapsed(offset: grown.caret),
    );
    // The controller is not the state. Setting `value` does not run the field's
    // `onChanged`, so the command line would still be holding what was typed
    // before the completion.
    _app.commandLine.setText(grown.text);
  }

  /// What there is to complete against: the folder the active panel is showing.
  Iterable<String> _namesInPanel() => _namesOf(_app.active.entries);

  /// A directory carries its separator, so `cd wo` becomes `cd work\` and the
  /// next name can be typed straight on.
  Iterable<String> _namesOf(List<FileEntry> entries) => entries
      .where((entry) => !entry.isParentLink)
      .map((entry) => entry.isDirectory
          ? '${entry.name}${Platform.pathSeparator}'
          : entry.name);

  /// Puts the keyboard back where the state machine says it is.
  ///
  /// **This is the bug that made the console unusable.** A single-line field
  /// gives up the focus when it submits, and nothing here took it back — so
  /// after Enter the keyboard belonged to nothing at all: not to the field, and
  /// not to the commander's own handler, which is a `Focus` node and is only
  /// reached while it has the focus. Escape, the arrows, the whole function
  /// row and even Alt+F went dead, and the only way out was the mouse. Pressing
  /// a panel and then Escape sometimes worked and sometimes had to be done
  /// twice, because `_editingCommand` was still true and the first Escape spent
  /// itself on turning that off.
  ///
  /// Running a command leaves you in the command line, as it does in a shell
  /// and in Total Commander. Leaving is Escape or Ctrl+Up, and both are
  /// deliberate.
  void _takeKeyboardBack() {
    if (_editingCommand) {
      // After the frame: the field is rebuilt around the cleared text, and a
      // focus asked for before that lands on a node about to be replaced.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _editingCommand) _commandInput.requestFocus();
      });
    } else {
      _keyboard.requestFocus();
    }
  }

  void _saveConsoleHeight() =>
      unawaited(_settings.setConsoleHeight(_app.commandLine.consoleHeight));

  Future<void> _pickShell() async {
    final chosen = await pickShell(context, _app.commandLine.shell);
    if (chosen == null || !mounted) return;
    _app.commandLine.setShell(chosen);
    await _settings.setShellKind(chosen.name);
    _keyboard.requestFocus();
  }

  // --- Context menu -------------------------------------------------------

  /// Right-click menu — see `panel/file_context_menu.dart`, which holds what
  /// it offers and why it offers nothing else.
  Future<void> _showMenu(Offset position, FileEntry? entry) async {
    await showFileContextMenu(
      context: context,
      globalPosition: position,
      style: menuAppearanceFrom(_settings.appearance),
      app: _app,
      entry: entry,
      actions: _menuActions,
    );
    if (mounted) _keyboard.requestFocus();
  }

  /// The screen's own methods, handed to the menu.
  ///
  /// The menu names a command; performing it is the window's business, because
  /// every one of these can raise a dialog, a progress window or a remark.
  FileMenuActions get _menuActions => FileMenuActions(
    openWithShell: (entry) => unawaited(_openWithShell(entry)),
    view: (entry) => unawaited(_viewFile(entry)),
    edit: (entry) => unawaited(_editFile(entry)),
    rename: () => unawaited(_rename()),
    copyPath: (entry) => unawaited(_copyPath(entry)),
    copyToClipboard: ({required cut}) => unawaited(_copyToClipboard(cut: cut)),
    pasteHere: () => unawaited(_pasteHere()),
    transfer: ({required move}) => unawaited(_transfer(move: move)),
    pack: () => unawaited(_pack(toOtherPanel: false)),
    extract: (entry, {required intoFolder}) =>
        unawaited(_extract(entry, intoFolder: intoFolder)),
    delete: ({required toTrash}) => unawaited(_delete(toTrash: toTrash)),
    createDirectory: () => unawaited(_createDirectory()),
    refresh: () => unawaited(_app.active.refresh()),
  );

  /// The entry the entry-menu acts on, or null when there is none to act on.
  FileEntry? get _entryUnderCursor {
    final entry = _app.active.cursorEntry;
    return entry == null || entry.isParentLink ? null : entry;
  }

  Future<void> _copyPath(FileEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.path.display));
    if (mounted) showNotice(context, tr('Copied to the clipboard.'));
  }

  /// The File menu, and the head of the right-click menu.
  ///
  /// `..` is not an entry for this purpose. It is the way out of a folder, not
  /// a file in it, and the right-click menu has always left it out — the File
  /// menu was offering Rename, Delete and now Copy path for it because it
  /// asked for the cursor entry without applying the same rule.
  List<MenuNode> _fileMenu() => [
    ...entryMenuNodes(
      app: _app,
      entry: _entryUnderCursor,
      actions: _menuActions,
    ),
    MenuItem(
      tr('New folder'),
      icon: Icons.create_new_folder_outlined,
      shortcut: 'F7',
      keywords: const ['create', 'directory', 'mkdir'],
      // Dead where nothing can be written, like everything else that writes.
      enabled: !_app.active.isReadOnly,
      onSelected: () => unawaited(_createDirectory()),
    ),
    const MenuSeparator(),
    MenuItem(
      tr('Settings'),
      icon: Icons.settings_outlined,
      shortcut: 'F9',
      keywords: const ['preferences', 'appearance', 'plugins', 'options'],
      onSelected: () => unawaited(_openSettings()),
    ),
    MenuItem(
      tr('Exit'),
      icon: Icons.logout,
      keywords: const ['quit', 'close'],
      onSelected: WindowService.close,
    ),
  ];

  /// Whether either panel is already holding this view.
  bool _isViewOpen(RegisteredView view) {
    for (final panel in [_app.left, _app.right]) {
      final held = panel.attachment;
      if (held is PluginViewAttachment && held.view.id == view.id) return true;
    }
    return false;
  }

  /// Drives and connections, built from the registry's cached roots so the
  /// menu never blocks on a provider that has to go and look.
  MenuGroup _drivesGroup() => MenuGroup(
    tr('Drives and connections'),
    _locationNodes(_app.active),
    icon: Icons.storage_outlined,
  );

  /// One row of the location menu, with a submenu where the root has places
  /// under it.
  ///
  /// **The row stays a row.** Home keeps its letter and still goes home; what
  /// is under it unfolds where the pointer rests or where the cursor lands, and
  /// Enter is unaffected. Made a shelf instead, it stopped being a destination
  /// at all: the row has to keep its letter and its journey. See
  /// [MenuItem.children].
  ///
  /// The accelerator letters inside a submenu are claimed from a set of their
  /// own: a letter only has to be unique among the rows shown beside it, and
  /// sharing the outer set would have cost `D` to whichever of Desktop,
  /// Documents and Downloads happened to come first in a menu it is not even
  /// on.
  MenuNode _rootNode(
    VfsRoot root,
    String? Function(String) claim,
    void Function(VfsRoot) goTo,
  ) {
    final inside = <String>{};
    String? claimInside(String label) {
      for (final rune in label.runes) {
        final char = String.fromCharCode(rune).toLowerCase();
        if (!RegExp(r'[a-z0-9]').hasMatch(char)) continue;
        return inside.add(char) ? char : null;
      }
      return null;
    }

    return MenuItem(
      root.subtitle == null ? root.label : '${root.label}  ${root.subtitle}',
      icon: _rootIcon(root.iconName),
      // The letter a root asks for, and only then the one its caption offers:
      // a translated caption may have no Latin letter in it at all.
      accelerator: claim(root.accelerator ?? root.label),
      keywords: [root.label, if (root.subtitle != null) root.subtitle!],
      onSelected: () => goTo(root),
      // The caption over the folders is the place's name alone: the row beside
      // them already carries the path, and saying it twice is what the Pack
      // window was corrected for.
      submenuTitle: root.label,
      children: [
        for (final child in root.children)
          MenuItem(
            child.label,
            icon: _rootIcon(child.iconName),
            accelerator: claimInside(child.label),
            keywords: [child.label, child.path.display],
            onSelected: () => goTo(child),
          ),
      ],
    );
  }

  /// Everywhere [target] can be sent: the drives first, then the saved
  /// connections, then the ways to make or type a new one.
  ///
  /// This is both the Commands submenu and what the location pill drops, so a
  /// drive is in the same place whichever way it is reached.
  List<MenuNode> _locationNodes(PanelController target) {
    final app = _app;
    final saved = app.connections.all;
    final specs = app.plugins.connectionSpecs;

    // Only views that can actually take a panel: this menu sends the panel
    // somewhere, and an entry that cannot be gone to is an entry that lies.
    //
    // And only ones that are not already up. **A view is one thing.** Offering
    // a second copy of a tool that follows the other panel offers the worst
    // state there is — two panels each following the other, so neither is
    // looking at a folder and both say there is nothing there. It is not a
    // greyed-out row either: a row that is only ever there to be refused is a
    // row that has to be read every time to learn nothing.
    final views = [
      for (final view in app.plugins.viewsIn(PluginSurface.locations))
        if (view.spec.isPanelCapable && !_isViewOpen(view)) view,
    ];

    // One letter per row, first come first served: `C` picks the C: drive the
    // moment the menu is open, which is the whole point of Alt+F1 then C.
    final claimed = <String>{};
    String? claim(String label) {
      for (final rune in label.runes) {
        final char = String.fromCharCode(rune).toLowerCase();
        if (!RegExp(r'[a-z0-9]').hasMatch(char)) continue;
        if (claimed.add(char)) return char;
        return null;
      }
      return null;
    }

    // Picking a drive is a change of volume, so it lands where that volume was
    // left rather than at its root. **A place is not a volume**: home goes
    // home — see [VfsRoot.isVolume].
    void goToRoot(VfsRoot root) {
      app.activate(target);
      unawaited(
        root.isVolume
            ? target.openVolume(root.path)
            : target.navigateTo(root.path),
      );
    }

    return [
      if (target.isVirtual) ...[
        MenuItem(
          tr('Leave the search results'),
          icon: Icons.travel_explore,
          keywords: const ['close', 'listing', 'back'],
          onSelected: () => unawaited(target.closeResults()),
        ),
        const MenuSeparator(),
      ],
      for (final root in app.fileSystems.knownRoots)
        _rootNode(root, claim, goToRoot),
      // Views that asked to be here. A place a panel can be sent is exactly
      // what this menu is, so a disk map or a folder comparison belongs among
      // the drives rather than in a menu of its own.
      if (views.isNotEmpty) ...[
        MenuSeparator(tr('Views')),
        for (final view in views)
          MenuItem(
            locationViewLabel(view.spec, targetIsLeft: target == app.left),
            // The tool's own mark, where it has one. Whatever put the row
            // there is what the row shows — the alternative is the same
            // generic shape on every tool, and then the reader works out
            // which is which from the words alone.
            icon: pluginIcon(view.spec.icon),
            image: app.plugins.iconFileFor(view.pluginId, view.spec.icon),
            keywords: [?view.spec.description, view.pluginName],
            onSelected: () => unawaited(_openView(view, panel: target)),
          ),
      ],
      // **Where this panel has been.** Alt+F1 and Alt+F2 already opened this
      // menu, so the history belongs in it rather than behind a key of its
      // own: it is a list of places to go, which is exactly what this menu is.
      ..._historyGroup(target),
      if (saved.isNotEmpty) MenuSeparator(tr('Connections')),
      for (final connection in saved)
        MenuItem(
          connection.name,
          icon: Icons.dns_outlined,
          keywords: [connection.summary, connection.scheme],
          onSelected: () {
            app.activate(target);
            unawaited(_openConnection(connection));
          },
        ),
      const MenuSeparator(),
      // Setting a connection up is housekeeping, and it was crowding out the
      // thing this menu is for: going somewhere. One row per transport plus a
      // manager is a list that grows with every transport installed, and none
      // of it is what the menu is opened for. The connections themselves stay
      // where they are — those *are* places to go.
      if (specs.isNotEmpty || saved.isNotEmpty)
        MenuGroup(tr('Set up connections'), [
          // The manager first: it is the one that does everything the rest of
          // this list does, and the one wanted most often.
          if (saved.isNotEmpty) ...[
            MenuItem(
              tr('Manage connections…'),
              icon: Icons.tune,
              keywords: const ['edit', 'delete', 'rename', 'ftp'],
              onSelected: () => unawaited(_manageConnections()),
            ),
            const MenuSeparator(),
          ],
          // The "+ftp" entry point: one per transport that declares a form.
          for (final spec in specs)
            MenuItem(
              tr('+ {name} connection…', {'name': spec.title}),
              icon: Icons.add_link,
              keywords: ['new', 'add', spec.scheme],
              onSelected: () {
                app.activate(target);
                unawaited(_newConnection(spec));
              },
            ),
        ], icon: Icons.settings_outlined),
      MenuItem(
        tr('Enter a path or URL…'),
        icon: Icons.edit_location_alt_outlined,
        keywords: const ['type', 'goto', 'address'],
        onSelected: () => unawaited(_chooseRoot(target)),
      ),
    ];
  }

  /// The History submenu: the folders visited most often, then the ones
  /// visited last.
  ///
  /// **One list, and it is where the time went.** It was two for a day, with a
  /// chronological *where was I just now* underneath, and that one is gone.
  /// Once the ranking is time rather than arrivals the top already holds
  /// everywhere worth going back to, and a second list of the same folders in
  /// another order is a second list to read.
  ///
  /// Nothing at all until there is something to show. A submenu offering an
  /// empty list is a row that has to be opened to learn there is nothing in it.
  List<MenuNode> _historyGroup(PanelController target) {
    final history = _app.history;
    final favourites = history.favourites;
    if (favourites.isEmpty) return const [];

    // **Nothing is written on a row but the name.** A count was drawn there for
    // one build and taken out again, and the same goes for a time. The menu is
    // opened to go somewhere, not to read a table.
    MenuItem row(VfsPath where) => MenuItem(
      where.label,
      icon: Icons.folder_outlined,
      // What it is, under what it is called — a name on its own is ambiguous
      // the moment two folders are called `src`. Searchable, and shown on a
      // hint when the pointer rests on the row.
      keywords: [where.display],
      hint: where.display,
      // **A cross on the row, under the pointer or under the keyboard.**
      // A list built
      // out of what somebody did will sooner or later hold something they would
      // rather it did not, and clearing the lot is too big an answer for one
      // folder. The menu takes the row out itself, so three of them is three
      // presses rather than three journeys back down to the same submenu.
      onRemove: () => unawaited(history.forget(where)),
      // **The pin, beside it.** Ranking by time is a good guess and is only a
      // guess; a pin is somebody saying outright, and a pinned folder leads the
      // list and stays there. Not offered at all once ten are pinned — the list
      // is ten, so ten pins is a list with nothing else in it, and that is the
      // point of pinning.
      isPinned: () => history.isPinned(where),
      // **Dragged into whatever order is wanted**, which only the pinned ones
      // have: the rest are ranked by time, and a hand-placed row among them
      // would jump the next time somebody worked somewhere.
      onDragged: history.isPinned(where)
          ? (rows) => unawaited(history.movePin(where, by: rows))
          : null,
      onPin: history.isPinned(where) || history.canPin
          ? () => unawaited(
              history.pin(where, pinned: !history.isPinned(where)),
            )
          : null,
      onSelected: () {
        _app.activate(target);
        unawaited(target.navigateTo(where));
      },
    );

    return [
      MenuGroup(tr('History'), [
        for (final where in favourites) row(where),
        const MenuSeparator(),
        MenuItem(
          tr('Clear the history'),
          icon: Icons.delete_sweep_outlined,
          keywords: const ['forget', 'empty', 'reset'],
          // The times as well as the list: a cleared history that still ranked
          // by where you used to work would not be cleared.
          onSelected: () => unawaited(history.clear()),
        ),
      ], icon: Icons.history),
      const MenuSeparator(),
    ];
  }

  /// Drops the location menu under [anchor] — the pill's own rectangle, so it
  /// hangs off the button the way a combo box does.
  Future<void> _showLocationMenu(PanelController panel, Rect anchor) async {
    _app.activate(panel);
    setState(() => _locationMenuPanel = panel);

    // **Ask the machine what is plugged in, before drawing the answer.**
    //
    // The roots were read once at start-up and on a provider registering, and
    // nothing after that — so a stick put in five minutes ago was not in the
    // list, and the one taken out was.
    //
    // **Bounded, because a menu that waits on I/O reads as broken.** The wait
    // is for the local disks, which answer in a millisecond or two; a network
    // share that takes five seconds is not waited for at all, and its roots
    // land in `knownRoots` for the next opening. The menu is built from
    // whatever is known when the wait is over.
    await _app.fileSystems.refreshRoots(
      within: const Duration(milliseconds: 120),
    );
    if (!mounted) return;

    // **And it goes on asking while it is open.**
    //
    // Re-reading once, on opening, answers "I plugged it in and then opened the
    // menu". It does not answer "I opened the menu and then plugged it in",
    // which is the same evening's other half — and a menu that can only be
    // right at the moment it opened is one somebody has to close and open again
    // to trust.
    //
    // A poll rather than a subscription, because a subscription means native
    // code on three platforms for a list somebody is looking at for a few
    // seconds. Every second and a half, and only while the menu is up: reading
    // the mounted volumes is a directory listing, and nothing here runs when
    // the menu is not.
    final live = ValueNotifier<List<MenuNode>>(_locationNodes(panel));
    var known = _app.fileSystems.knownRoots;
    void onRoots() {
      final now = _app.fileSystems.knownRoots;
      // Only when the drives have actually changed. The registry says so on
      // every provider that answers, and rebuilding the menu on each of those
      // would move the rows under the hand for no reason at all.
      if (_sameRoots(known, now)) return;
      known = now;
      live.value = _locationNodes(panel);
    }

    // **Held on the state, not only in the `finally`.** The window can be torn
    // down with the menu still up — a test does exactly that — and then the
    // `await` below never returns and the timer outlives everything.
    _rootsWatch = onRoots;
    _rootsWatched = _app.fileSystems..addListener(onRoots);
    _rootsPoll = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => unawaited(_app.fileSystems.refreshRoots()),
    );

    try {
      await showAppContextMenu(
        context: context,
        anchorRect: anchor,
        style: menuAppearanceFrom(_settings.appearance),
        nodes: live.value,
        live: live,
        searchHint: tr('Search drives and connections'),
      );
    } finally {
      _stopWatchingRoots();
      live.dispose();
    }

    if (!mounted) return;
    setState(() => _locationMenuPanel = null);
    _keyboard.requestFocus();
  }

  /// The poll that keeps the open drive menu current, the listener that
  /// redraws it, and the registry both belong to. Null whenever the menu is
  /// not up.
  ///
  /// **The registry is held rather than looked up again.** This is unwound from
  /// `dispose`, and a `Provider.of` there reaches for an ancestor of a widget
  /// that is already on its way out — which throws.
  Timer? _rootsPoll;
  VoidCallback? _rootsWatch;
  FileSystemRegistry? _rootsWatched;

  void _stopWatchingRoots() {
    _rootsPoll?.cancel();
    _rootsPoll = null;
    final watch = _rootsWatch;
    if (watch != null) _rootsWatched?.removeListener(watch);
    _rootsWatch = null;
    _rootsWatched = null;
  }

  /// Whether two readings of the drives say the same thing.
  ///
  /// By path and label, which is what the menu draws. A volume renamed while
  /// the menu is open is a different row and should be redrawn as one.
  static bool _sameRoots(List<VfsRoot> a, List<VfsRoot> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].path != b[i].path || a[i].label != b[i].label) return false;
    }
    return true;
  }

  /// Alt+F1 / Alt+F2. The menu belongs under that panel's pill, which on a
  /// one-panel layout only exists once the panel is the one on show.
  Future<void> _openLocationMenu(PanelController panel) async {
    _app.activate(panel);

    var box = _pillBoxOf(panel);
    if (box == null) {
      // The panel was hidden a moment ago; its pill exists after the frame
      // that activating it caused.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      box = _pillBoxOf(panel);
    }
    if (box == null) {
      // No pill to hang it off — ask for the path outright rather than
      // dropping a menu in a corner.
      await _chooseRoot(panel);
      return;
    }

    await _showLocationMenu(panel, box.localToGlobal(Offset.zero) & box.size);
  }

  /// The menu key, and Shift+F10: Windows' own menu for the cursor row, the
  /// same one the right button gives after being held.
  ///
  /// Anchored under the row it is about, the way the pointer would have left it.
  /// A row the shell knows nothing about — the `..` link, or anything served by
  /// a plugin rather than by the disk — gets the application's own menu instead,
  /// so the key always opens something.
  Future<void> _menuAtCursor(PanelController panel) async {
    final box = _cursorBoxOf(panel);
    // Scrolled out of sight, so there is no row on screen to hang it off. The
    // cursor is where the keyboard left it, and bringing it back into view is a
    // frame away; the panel itself is the honest anchor for one keypress.
    final anchor = box ?? _pillBoxOf(panel);
    if (anchor == null) return;

    final origin = anchor.localToGlobal(Offset(0, anchor.size.height));
    final entry = panel.cursorEntry;

    if (entry == null ||
        entry.isParentLink ||
        !SystemMenu.isSupported ||
        entry.path.scheme != VfsPath.localScheme) {
      _showMenu(origin, entry != null && !entry.isParentLink ? entry : null);
      return;
    }
    await _showSystemMenu(origin, entry);
  }

  /// The row the cursor is on, in global coordinates — where a window opened
  /// from here comes out of, and goes back to.
  ///
  /// The *active* panel's row, because that is the one the keyboard was in
  /// when the window was asked for. Null while a panel is showing something
  /// other than a listing, and then the window arrives about its own centre.
  Rect? _cursorRect() {
    final box = _cursorBoxOf(_app.active);
    if (box == null || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  RenderBox? _cursorBoxOf(PanelController panel) {
    final key = identical(panel, _app.left) ? _leftCursorKey : _rightCursorKey;
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    return box != null && box.hasSize ? box : null;
  }

  RenderBox? _pillBoxOf(PanelController panel) {
    final key = identical(panel, _app.left)
        ? _leftLocationKey
        : _rightLocationKey;
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    return box != null && box.hasSize ? box : null;
  }

  // --- Connections --------------------------------------------------------

  Future<void> _newConnection(ConnectionSpec spec) async {
    final result = await showConnectionDialog(context, spec: spec);
    if (result == null || !mounted) return;

    await _app.connections.save(
      spec,
      result.connection,
      password: result.password,
      storePassword: result.storePassword,
    );
    await _openConnection(result.connection, password: result.password);
  }

  Future<void> _editConnection(SavedConnection connection) async {
    final spec = _app.plugins.connectionSpecs
        .where((s) => s.id == connection.specId)
        .firstOrNull;
    if (spec == null) {
      _reportError(
        tr('The plugin that owns "{name}" is not installed.', {
          'name': connection.name,
        }),
      );
      return;
    }

    final result = await showConnectionDialog(
      context,
      spec: spec,
      existing: connection,
    );
    if (result == null || !mounted) return;

    // Renaming means the old section is left behind, so drop it first.
    if (result.connection.name != connection.name) {
      await _app.connections.delete(connection);
    }
    await _app.connections.save(
      spec,
      result.connection,
      password: result.password,
      storePassword: result.storePassword,
    );
  }

  /// Navigates the active panel to a saved connection, asking for the password
  /// when none was kept.
  Future<void> _openConnection(
    SavedConnection connection, {
    String? password,
  }) async {
    var secret = password ?? connection.revealPassword();

    final needsUser = (connection[ConnectionSpec.userKey] ?? '').isNotEmpty;
    if (needsUser && (secret == null || secret.isEmpty)) {
      secret = await promptForPassword(context, connection);
      if (secret == null || !mounted) return;
    }

    if (!_app.fileSystems.supports(connection.scheme)) {
      _reportError(
        tr(
          'Nothing serves {scheme}: right now. '
          'Check the plugin in Settings.',
          {'scheme': connection.scheme},
        ),
      );
      return;
    }

    await _app.active.navigateTo(connection.toPath(password: secret));
    if (mounted) _keyboard.requestFocus();
  }

  Future<void> _manageConnections() async {
    await showConnectionManager(
      context,
      store: _app.connections,
      onOpen: _openConnection,
      onEdit: _editConnection,
    );
  }

  List<MenuNode> _markMenu() {
    final app = _app;
    return [
      MenuItem(
        tr('Mark all'),
        icon: Icons.select_all,
        shortcut: 'Ctrl+A',
        onSelected: app.active.markAll,
      ),
      MenuItem(
        tr('Invert marks'),
        icon: Icons.flip,
        shortcut: 'Num *',
        onSelected: app.active.invertMarks,
      ),
      MenuItem(
        tr('Clear marks'),
        icon: Icons.deselect,
        shortcut: 'Esc',
        onSelected: app.active.clearMarks,
      ),
      const MenuSeparator(),
      MenuItem(
        tr('Calculate folder sizes'),
        icon: Icons.functions,
        shortcut: 'Alt+Shift+Enter',
        keywords: const ['size', 'measure', 'space'],
        onSelected: () => unawaited(app.active.computeMarkedSizes()),
      ),
    ];
  }

  List<MenuNode> _commandsMenu() {
    final app = _app;
    return [
      _drivesGroup(),
      MenuItem(
        tr('Find files…'),
        icon: Icons.search,
        shortcut: 'Alt+F7',
        keywords: const ['search', 'grep', 'contains', 'mask'],
        onSelected: () => unawaited(showSearchWindow(context)),
      ),
      if (app.active.isVirtual)
        MenuItem(
          tr('Leave the search results'),
          icon: Icons.travel_explore,
          keywords: const ['close', 'results', 'listing'],
          onSelected: () => unawaited(app.active.closeResults()),
        ),
      MenuGroup(tr('Selection'), _markMenu(), icon: Icons.checklist),
      MenuItem(
        tr('Up one level'),
        icon: Icons.drive_folder_upload_outlined,
        shortcut: 'Ctrl+PgUp',
        keywords: const ['parent', 'back', 'folder', 'up'],
        enabled: app.active.location?.parent != null,
        onSelected: () => unawaited(app.active.goUp()),
      ),
      MenuItem(
        tr('Swap panels'),
        icon: Icons.swap_horiz,
        shortcut: 'Ctrl+U',
        onSelected: _swapPanels,
      ),
      MenuItem(
        tr('Refresh'),
        icon: Icons.refresh,
        shortcut: 'Ctrl+R',
        onSelected: () => unawaited(app.active.refresh()),
      ),
    ];
  }

  List<MenuNode> _viewMenu() {
    final settings = _settings;
    return [
      MenuGroup(tr('Sort by'), [
        MenuItem(
          tr('Name'),
          shortcut: 'Ctrl+F3',
          checked: settings.sortColumn == SortColumn.name,
          onSelected: () => settings.applySort(SortColumn.name),
        ),
        MenuItem(
          tr('Extension'),
          shortcut: 'Ctrl+F4',
          checked: settings.sortColumn == SortColumn.extension,
          onSelected: () => settings.applySort(SortColumn.extension),
        ),
        MenuItem(
          tr('Date'),
          shortcut: 'Ctrl+F5',
          checked: settings.sortColumn == SortColumn.modified,
          onSelected: () => settings.applySort(SortColumn.modified),
        ),
        MenuItem(
          tr('Size'),
          shortcut: 'Ctrl+F6',
          checked: settings.sortColumn == SortColumn.size,
          onSelected: () => settings.applySort(SortColumn.size),
        ),
        const MenuSeparator(),
        MenuItem(
          tr('Directories first'),
          checked: settings.directoriesFirst,
          onSelected: () =>
              settings.directoriesFirst = !settings.directoriesFirst,
        ),
      ], icon: Icons.sort),
      MenuGroup(tr('Density'), [
        for (final density in PanelDensity.values)
          MenuItem(
            density.label,
            checked: settings.appearance.density == density,
            onSelected: () =>
                settings.updateAppearance((a) => a.copyWith(density: density)),
          ),
      ], icon: Icons.density_medium),
      if (WindowService.isSupported)
        MenuGroup(tr('Window backdrop'), [
          for (final backdrop in WindowBackdrop.values)
            MenuItem(
              backdrop.label,
              checked: settings.appearance.backdrop == backdrop,
              keywords: const ['acrylic', 'mica', 'blur', 'transparent'],
              onSelected: () => settings.updateAppearance(
                (a) => a.copyWith(backdrop: backdrop),
              ),
            ),
          const MenuSeparator(),
          // Windows drops the effect on things it never tells us about —
          // locking the session above all. The app puts it back on its own
          // when it next gets focus; this is the button for when that was
          // not enough.
          MenuItem(
            tr('Re-apply the backdrop'),
            icon: Icons.refresh,
            enabled: settings.appearance.backdrop != WindowBackdrop.opaque,
            keywords: const ['repair', 'fix', 'lost', 'acrylic', 'blur'],
            onSelected: () => unawaited(
              WindowService.reapplyBackdrop(
                settings.appearance,
                reason: 'menu',
              ),
            ),
          ),
        ], icon: Icons.blur_on),
      const MenuSeparator(),
      MenuItem(
        tr('Quick view in the other panel'),
        icon: Icons.preview_outlined,
        shortcut: 'Ctrl+Q',
        checked: _app.inactive.isAttached,
        keywords: const ['preview', 'viewport', 'panel', 'viewer'],
        onSelected: () => unawaited(_views.toggleQuickView()),
      ),
      MenuItem(
        tr('Show hidden files'),
        icon: Icons.visibility_off_outlined,
        shortcut: 'Ctrl+H',
        checked: settings.appearance.showHidden,
        keywords: const ['dotfiles'],
        onSelected: () => settings.updateAppearance(
          (a) => a.copyWith(showHidden: !a.showHidden),
        ),
      ),
    ];
  }

  List<MenuNode> _helpMenu() => [
    MenuItem(
      tr('Key bindings'),
      icon: Icons.keyboard_outlined,
      keywords: const ['shortcuts', 'hotkeys', 'about'],
      onSelected: () => unawaited(_openSettings()),
    ),
    MenuItem(
      tr('Plugins'),
      icon: Icons.extension_outlined,
      keywords: const ['extensions', 'python', 'declarative'],
      onSelected: () => unawaited(_openSettings()),
    ),
    const MenuSeparator(),
    MenuItem(
      tr("What's new"),
      icon: Icons.auto_awesome_outlined,
      keywords: const ['release', 'notes', 'changes', 'version'],
      onSelected: () => unawaited(ShellOpen.open(kReleasesUrl)),
    ),
    const MenuSeparator(),
    MenuItem(
      tr('About {app}', {'app': kAppTitle}),
      icon: Icons.info_outline,
      shortcut: kAppVersion,
      keywords: const ['version', 'licence', 'license', 'gpl', 'splash'],
      onSelected: () => unawaited(showAboutSplash(context)),
    ),
  ];

  /// Open internal windows. A window can end up completely behind another one,
  /// so this is the way back to it.
  List<MenuNode> _windowMenu() {
    final windows = _windows.windows;
    if (windows.isEmpty) {
      return [
        MenuItem(
          tr('No open windows'),
          icon: Icons.web_asset_outlined,
          enabled: false,
          onSelected: () {},
        ),
      ];
    }

    return [
      // Front window first: the reverse of the stack's bottom-to-top order.
      for (final window in windows.reversed)
        MenuItem(
          window.title,
          icon: window.icon ?? Icons.web_asset_outlined,
          checked: _windows.isTop(window),
          onSelected: () => _windows.focus(window),
        ),
      const MenuSeparator(),
      MenuItem(
        tr('Close the front window'),
        icon: Icons.close,
        shortcut: 'Esc',
        onSelected: _windows.closeTop,
      ),
      if (windows.length > 1)
        MenuItem(
          tr('Close all windows'),
          icon: Icons.clear_all,
          onSelected: _windows.closeAll,
        ),
    ];
  }

  /// Everything the installed plugins contribute, on shelves.
  ///
  /// Plugin commands used to be reachable from the title bar and nowhere else,
  /// so a command that did not ask for an icon there could not be run at all.
  /// The menu is the surface every command gets; the icon is the one it has to
  /// ask for. Grouped by the plugin's category, so the menu stays a list of a
  /// few things rather than one of everything.
  List<MenuNode> _toolsMenu() {
    final grouped = _app.plugins.menuOffersByCategory;
    if (grouped.isEmpty) {
      return [
        MenuItem(
          tr('No plugin commands yet'),
          icon: Icons.extension_outlined,
          enabled: false,
          onSelected: () {},
        ),
      ];
    }

    List<MenuNode> itemsIn(List<PluginOffer> offers) => [
      for (final offer in offers)
        MenuItem(
          offer.title,
          icon: pluginIcon(offer.icon),
          image: _app.plugins.iconFileFor(offer.pluginId, offer.icon),
          keywords: [?offer.description, offer.pluginId],
          onSelected: () => unawaited(_runOffer(offer)),
        ),
    ];

    // One shelf is not a shelf: with everything in a single category the
    // submenu would be a menu inside a menu of one entry.
    if (grouped.length == 1) return itemsIn(grouped.values.single);

    return [
      for (final entry in grouped.entries)
        MenuGroup(
          tr(entry.key),
          itemsIn(entry.value),
          icon: pluginCategoryIcon(entry.key),
        ),
    ];
  }

  /// The strip of drop-downs carried by the title bar.
  ///
  /// The letters are Alt accelerators, and they are spelled out rather than
  /// taken from the labels: Commands and Console both begin with C, so one of
  /// them has to be something else, and `o` is the letter the console already
  /// answers to on Ctrl+O.
  List<TitleBarMenu> _titleMenus() => [
    TitleBarMenu(tr('File'), _fileMenu, accelerator: 'f'),
    TitleBarMenu(tr('Mark'), _markMenu, accelerator: 'm'),
    TitleBarMenu(tr('Commands'), _commandsMenu, accelerator: 'c'),
    TitleBarMenu(tr('Console'), _shellMenu, accelerator: 'o'),
    TitleBarMenu(tr('View'), _viewMenu, accelerator: 'v'),
    TitleBarMenu(tr('Tools'), _toolsMenu, accelerator: 't'),
    TitleBarMenu(tr('Window'), _windowMenu, accelerator: 'w'),
    TitleBarMenu(tr('Help'), _helpMenu, accelerator: 'h'),
    // **What the panel is holding, if it is holding a tool.** Full screen a
    // view's menus replace the application's, because none of File, Mark or
    // Commands is about anything on screen. In a panel both are true at once:
    // there is still a listing beside it, and the tool still has things it can
    // do — so its menus stand after the application's own rather than instead
    // of them. The *active* panel's, because that is the one being worked in
    // and two tools' menus in one bar is a bar nobody can read.
    ..._attachedMenus(),
  ];

  /// The menus of whatever the active panel has been handed over to.
  List<TitleBarMenu> _attachedMenus() {
    final attachment = _app.active.attachment;
    if (attachment == null) return const [];
    return [
      for (final menu in attachment.menus)
        TitleBarMenu(
          menu.label,
          accelerator: menu.accelerator,
          () => viewMenuNodes(
            menu.items,
            (id) => unawaited(attachment.press(id)),
          ),
        ),
    ];
  }

  static IconData _rootIcon(String? name) => switch (name) {
    'drive' => Icons.storage,
    'home' => Icons.home_outlined,
    'folder' => Icons.folder_outlined,
    'server' => Icons.dns_outlined,
    'network' => Icons.lan_outlined,
    'optical' => Icons.album_outlined,
    'removable' => Icons.usb,
    _ => Icons.place_outlined,
  };

  // --- Commands -----------------------------------------------------------

  /// The F-keys, each knowing whether it can work where the panels are
  /// standing.
  ///
  /// **A key is dim rather than gone.** Inside a commit four of the eight
  /// cannot do anything, and a bar that dropped them would put Copy where
  /// Delete was — the one place in the application where the hand goes without
  /// the eye. They keep their places and stop answering.
  ///
  /// Which panel each one asks about is the whole of the rule: rename, a new
  /// folder and delete happen *here*; copy lands *there*; a move is a copy and
  /// then a delete, so it needs both.
  List<_CommandAction> _actions() {
    final here = !_app.active.isReadOnly;
    final there = !_app.inactive.isReadOnly;

    return [
      _CommandAction(
        'F2',
        tr('Rename'),
        Icons.drive_file_rename_outline,
        _rename,
        enabled: here,
      ),
      _CommandAction('F3', tr('View'), Icons.visibility_outlined, _viewCursor),
      _CommandAction('F4', tr('Edit'), Icons.edit_outlined, _editCursor),
      _CommandAction(
        'F5',
        tr('Copy'),
        Icons.copy_all_outlined,
        () => _transfer(move: false),
        enabled: there,
      ),
      // Two keys in one place while Shift is held. **The row has to say which**:
      // Shift+F6 is a rename or a move depending on what is marked, and a key
      // whose meaning the user has to work out from the listing is a key nobody
      // presses. The rest of the row keeps its own labels — Shift changes this
      // one into something else, not the whole bar into another bar.
      if (_shiftHeld && !_shiftF6Moves)
        _CommandAction(
          '⇧F6',
          tr('Rename'),
          Icons.drive_file_rename_outline,
          _renameOrMove,
          enabled: here,
        )
      else
        _CommandAction(
          _shiftHeld ? '⇧F6' : 'F6',
          tr('Move'),
          Icons.drive_file_move_outline,
          () => _transfer(move: true),
          enabled: here && there,
        ),
      _CommandAction(
        'F7',
        tr('Folder'),
        Icons.create_new_folder_outlined,
        _createDirectory,
        enabled: here,
      ),
      _CommandAction(
        'F8',
        tr('Delete'),
        Icons.delete_outline,
        () => _delete(toTrash: true),
        enabled: here,
      ),
      _CommandAction(
        'F9',
        tr('Settings'),
        Icons.settings_outlined,
        _openSettings,
      ),
    ];
  }

  List<MenuNode> _shellMenu() => [
    MenuItem(
      _app.commandLine.consoleVisible ? tr('Hide console') : tr('Show console'),
      icon: Icons.terminal,
      shortcut: 'Ctrl+O',
      keywords: const ['output', 'terminal', 'log'],
      onSelected: _app.commandLine.toggleConsole,
    ),
    MenuGroup(tr('Run commands in'), [
      for (final kind in ShellResolver.available())
        MenuItem(
          tr(kind.label),
          icon: Icons.terminal,
          checked: _app.commandLine.shell == kind,
          keywords: [ShellResolver.executableFor(kind) ?? ''],
          onSelected: () {
            _app.commandLine.setShell(kind);
            unawaited(_settings.setShellKind(kind.name));
          },
        ),
    ], icon: Icons.settings_ethernet),
    // The way round the guesswork. A command that needs its own terminal is
    // recognised by name, and a list of names is a guess however long it gets —
    // this asks for one outright, in the folder the panel is showing.
    MenuItem(
      tr('Open a terminal here'),
      icon: Icons.terminal_outlined,
      shortcut: 'Ctrl+Shift+O',
      keywords: const ['shell', 'cmd', 'prompt', 'window', 'bash'],
      onSelected: () => unawaited(_openTerminalHere()),
    ),
    MenuItem(
      tr('Clear console'),
      icon: Icons.delete_sweep_outlined,
      onSelected: _app.commandLine.clearConsole,
    ),
  ];

  /// A terminal of its own, in the folder the active panel is showing.
  Future<void> _openTerminalHere() async {
    final location = _app.active.location;
    if (location == null || location.scheme != VfsPath.localScheme) {
      _reportError(
        tr(
          'A terminal needs a local folder; this panel is somewhere a plugin '
          'serves.',
        ),
      );
      return;
    }

    final failure = await ScriptLaunch.runCommand(
      _app.commandLine.shell == ShellKind.system
          ? (Platform.isWindows ? 'cmd' : 'sh')
          : ShellResolver.executableFor(_app.commandLine.shell) ?? 'cmd',
      directory: location.toNativePath(),
    );
    if (failure != null) _reportError(failure);
  }

  /// Enter. Directories are entered; so are files a plugin says are really
  /// folders — an archive, above all. Everything else is handed to whatever
  /// the desktop associates with it. F3 is the one that stays inside the app.
  Future<void> _activate(PanelController panel) async {
    final entry = panel.cursorEntry;
    if (entry == null) return;
    await _activateEntry(panel, entry);
  }

  /// The same on a named row, which is what a double click has and Enter has to
  /// go and look up. Reading the cursor here would have made a double click
  /// depend on where the cursor had got to by the time the second click landed.
  Future<void> _activateEntry(PanelController panel, FileEntry entry) async {
    if (!entry.isDirectory && await _enterContainer(panel, entry)) return;

    final file = await panel.activateEntry(entry);
    if (file != null) await _openWithShell(file);
  }

  /// Steps into an archive, the way Total Commander does. Returns false when
  /// nothing claims this file type, or when the plugin that does is not
  /// serving its scheme.
  Future<bool> _enterContainer(PanelController panel, FileEntry entry) async {
    final scheme = _app.plugins.containerSchemeFor(entry.typeName);
    if (scheme == null) return false;

    if (!_app.fileSystems.supports(scheme)) {
      _reportError(
        tr(
          'Nothing serves {scheme}: right now, so "{name}" cannot be '
          'opened as a folder. Check the plugin in Settings.',
          {'scheme': scheme, 'name': entry.name},
        ),
      );
      return false;
    }

    await panel.navigateTo(VfsPath.insideArchive(entry.path, scheme));
    return true;
  }

  // --- Archives -----------------------------------------------------------

  /// What is marked, or the row under the cursor, into a new archive.
  ///
  /// **Where it lands depends on how it was asked for**, and the two readings
  /// are both right. Alt+F5 is an F-key, and every F-key in this application
  /// acts *across*: copy, move, and now pack all mean "into the other panel".
  /// The right-click menu is about the folder that was clicked, so it packs
  /// where the files already are. Neither is a default the other has to live
  /// with — the field holds the whole destination and can be edited.
  ///
  /// **The name chooses the format.** What is typed after the last dot decides
  /// which plugin writes it — the same rule that decides Enter on a file opens
  /// it as a folder, asked in the other direction. A dialog of radio buttons
  /// would be a second place where the application knows the list of archive
  /// formats, and it would be wrong the day a plugin added one.
  Future<void> _pack({required bool toOtherPanel}) async {
    final panel = _app.active;
    final source = panel.location;
    final targets = panel.actionTargets;
    if (source == null || targets.isEmpty) return;

    final into = toOtherPanel ? _app.inactive : panel;
    final directory = into.location;
    if (directory == null) return;
    if (!_canWriteTo(into)) return;

    final formats = _app.plugins.packFormats;
    if (formats.isEmpty) {
      showNotice(
        context,
        tr('Nothing installed can create an archive. Check the plugins in '
            'Settings.'),
        long: true,
      );
      return;
    }

    final entries = [
      for (final path in targets)
        panel.entries.firstWhere(
          (entry) => entry.path == path,
          orElse: () =>
              FileEntry(path: path, name: path.name, kind: FileKind.file),
        ),
    ];
    // Named after what is being packed, but *addressed* to where it is going —
    // and the folder is in the field rather than only in the title, because a
    // command that writes somewhere the user cannot see is a command they have
    // to guess at. The same shape Shift+F5 uses, for the same reason.
    final suggestion = suggestedArchiveName(
      entries,
      directory: source,
      extension: formats.first.extension,
    );
    final separator =
        directory.scheme == VfsPath.localScheme && Platform.isWindows ? r'\' : '/';
    final folder = directory.display.endsWith(separator)
        ? directory.display
        : '${directory.display}$separator';
    final initial = '$folder$suggestion';

    final typed = await askPackTarget(
      context,
      initialValue: initial,
      // The name is selected and neither the folder nor the extension is, so
      // typing replaces what it is called while leaving where it goes and the
      // part that chooses the format in place. A deliberate edit of either
      // still changes it.
      selectionStart: folder.length,
      selectionEnd: initial.length - formats.first.extension.length - 1,
      formats: formats,
      count: targets.length,
    );
    if (typed == null || typed.trim().isEmpty || !mounted) return;

    final archive = _resolveDestination(typed.trim(), directory);
    if (archive == null) return;
    final name = archive.name;

    final scheme = _app.plugins.packSchemeFor(name);
    if (scheme == null) {
      showNotice(
        context,
        tr('Nothing installed writes "{name}". Try one of: {formats}.', {
          'name': name,
          'formats': formats.map((f) => '.${f.extension}').join(', '),
        }),
        long: true,
      );
      return;
    }

    // An archive that is already there is added to rather than replaced — that
    // is what "add files to an archive" means — but it is said out loud first,
    // because the two readings of pressing Pack over an existing name are far
    // apart.
    if (await _app.fileSystems.resolve(archive).stat(archive) != null) {
      if (!mounted) return;
      final agreed = await confirm(
        context,
        title: tr('{name} already exists', {'name': name}),
        message: tr('Add these files to the archive that is there?'),
        confirmLabel: tr('Add'),
      );
      if (!agreed || !mounted) return;
    }

    await _runTransfer(
      sources: targets,
      target: packTarget(archive, scheme),
      move: false,
      ask: false,
      as: 'pack',
      busyTitle: tr('Packing…'),
    );
    panel.clearMarks();
    await _refreshWhereChanged([archive.parent]);
  }

  /// Alt+F9, and "Extract here": an archive's contents into the folder it is
  /// sitting in, or into a new folder of its own.
  ///
  /// It is the ordinary copy, out of the archive read as a directory. Nothing
  /// here knows how to unpack anything: the plugin serving the scheme does the
  /// reading, and the progress, the collisions and the cancel are the ones
  /// every other copy in the application uses.
  Future<void> _extract(FileEntry entry, {required bool intoFolder}) async {
    final panel = _app.active;
    final directory = panel.location;
    if (directory == null || entry.isDirectory) return;
    if (!_canWriteTo(panel)) return;

    final scheme = _app.plugins.containerSchemeFor(entry.typeName);
    if (scheme == null || !_app.fileSystems.supports(scheme)) {
      showNotice(
        context,
        tr('Nothing installed can open "{name}" as a folder, so there is '
            'nothing to extract it with.', {'name': entry.name}),
        long: true,
      );
      return;
    }

    final inside = VfsPath.insideArchive(entry.path, scheme);

    if (intoFolder) {
      // One source landing under a new name, which is what makes the folder:
      // the copy creates it and walks the whole archive into it.
      await _runTransfer(
        sources: [inside],
        target: directory,
        move: false,
        ask: false,
        underName: unpackFolderName(entry),
        as: 'extract',
        busyTitle: tr('Extracting…'),
      );
      await _refreshWhereChanged([directory]);
      return;
    }

    // Loose in the folder on screen: the archive's top level, entry by entry.
    // Reading it can take a moment on a large archive, so it happens here and
    // not while a menu is being drawn.
    final List<FileEntry> top;
    try {
      top = await _app.fileSystems.resolve(inside).list(inside);
    } on Object catch (failure) {
      if (mounted) _reportError('${entry.name}: $failure');
      return;
    }
    if (top.isEmpty) {
      if (mounted) {
        showNotice(context, tr('{name} is empty.', {'name': entry.name}));
      }
      return;
    }
    if (!mounted) return;

    await _runTransfer(
      sources: [for (final item in top) item.path],
      target: directory,
      move: false,
      ask: false,
      as: 'extract',
      busyTitle: tr('Extracting…'),
    );
    await _refreshWhereChanged([directory]);
  }

  Future<void> _openWithShell(FileEntry entry) async {
    if (entry.path.scheme != VfsPath.localScheme) {
      // Nothing on disk for the shell to open, so fall back to a viewer.
      await _viewFile(entry);
      return;
    }

    final native = entry.path.toNativePath();

    // A script is run, not opened, and it is run in a terminal of its own that
    // stays — in the folder it lives in, because that is where a script expects
    // to find the files it works on.
    if (ScriptLaunch.isScript(native)) {
      final refused = await ScriptLaunch.run(native);
      if (refused == null || !mounted) return;
      showNotice(
        context,
        refused,
        long: true,
        actionLabel: tr('Edit'),
        onAction: () => unawaited(_editFile(entry)),
      );
      return;
    }

    // Enter is the desktop's own action on the file, and when the desktop has no
    // answer it is the desktop's own question — Windows' "How do you want to open
    // this file?". It used to be our viewer instead, which is the application
    // deciding it knows better than the machine it is running on; F3 is there for
    // anyone who wants that.
    final failure = await ShellOpen.openAs(native);
    if (failure == null || !mounted) return;

    // Something else went wrong — the file has gone, or is not allowed to be
    // read. A viewer will not help with either, but it is the one thing left to
    // offer, so it is offered rather than assumed.
    showNotice(
      context,
      failure,
      long: true,
      actionLabel: tr('View'),
      onAction: () => unawaited(_viewFile(entry)),
    );
  }

  /// F4: open the file under the cursor in the machine's own text editor.
  ///
  /// Not Enter, which hands the file to whatever claims its extension — that
  /// may well be something that only displays it. The core ships no editor and
  /// is not going to: editing is not file management, and every machine
  /// already has one.
  Future<void> _editCursor() async {
    final entry = _app.active.cursorEntry;
    if (entry == null) return;
    await _editFile(entry);
  }

  Future<void> _editFile(FileEntry entry) async {
    if (entry.isDirectory || entry.isParentLink) return;

    if (entry.path.scheme != VfsPath.localScheme) {
      // An editor takes a path, and a file on a transport has none. Copy it
      // down first — F5 — and edit the copy.
      _reportError(
        tr(
          'Only files on this machine can be edited. Copy "{name}" '
          'here first.',
          {'name': entry.name},
        ),
      );
      return;
    }

    final failure = await ShellOpen.edit(entry.path.toNativePath());
    if (failure == null || !mounted) return;
    showNotice(
      context,
      failure,
      long: true,
      actionLabel: tr('View'),
      onAction: () => unawaited(_viewFile(entry)),
    );
  }

  /// Ctrl+Down: step into the folder under the cursor.
  Future<void> _enterDirectory() async {
    final panel = _app.active;
    final entry = panel.cursorEntry;
    if (entry == null) return;
    if (entry.isDirectory) await panel.activateCursor();
  }

  /// Ctrl+Left / Ctrl+Right: show the folder under the cursor in that panel.
  Future<void> _openInPanel(PanelController target) async {
    final source = _app.active;
    final entry = source.cursorEntry;
    final destination =
        entry != null && entry.isDirectory && !entry.isParentLink
        ? entry.path
        : source.location;
    if (destination == null) return;
    await target.navigateTo(destination);
  }

  Future<void> _viewCursor({bool choose = false}) async {
    final entry = _app.active.cursorEntry;
    if (entry == null || entry.isDirectory || entry.isParentLink) return;
    await _viewFile(entry, choose: choose);
  }

  /// F3. The core cannot display a file itself — it asks the plugin registry
  /// which viewers claim this extension and hands the file to one of them.
  Future<void> _viewFile(
    FileEntry entry, {
    bool choose = false,
    RegisteredViewer? viewer,
  }) async {
    // Held rather than asked for again when the page is built: the listing the
    // reader walks and the panel that follows them must be the same one, and
    // the active panel can change while a plugin is being asked.
    final panel = _app.active;
    // Asked *of the file*, not only of its name: a viewer that declared a
    // probe gets shown the first pages and can say "this one is mine" — which
    // is how a node graph, which is a `.json` like any other, opens on F3
    // rather than one Shift+F3 further on.
    final candidates = await _app.plugins.viewersForFile(entry);
    if (!mounted) return;

    if (candidates.isEmpty) {
      _showNoViewer(entry);
      return;
    }

    var index = viewer == null ? 0 : candidates.indexOf(viewer);
    if (index < 0) index = 0;

    if (viewer == null && choose && candidates.length > 1) {
      final picked = await _pickViewer(candidates);
      if (picked == null || !mounted) return;
      index = candidates.indexOf(picked);
    }

    if (!mounted) return;
    // A page, not a window: viewing is somewhere you go and come back from,
    // and it wants the whole panel area rather than a frame floating over it.
    await Navigator.of(context).push(
      MotionPageRoute<void>.of(
        context,
        builder: (_) => PluginViewerPage(
          entry: entry,
          viewers: candidates,
          initialIndex: index,
          // What the panel has on screen, in the order it has it — the sort,
          // the filter and the hidden files all already applied. The page
          // picks its neighbours out of this; walking them must agree with
          // walking the listing, or the same folder is two different orders
          // depending on which key you press.
          siblings: panel.entries,
          // The panel follows the reader through the folder. Somebody who
          // opens the first of a thousand photographs and steps to the four
          // hundredth has moved through the listing; coming back to find the
          // cursor still on the first is the panel disagreeing with what they
          // just did — and it is what the panel would then have remembered
          // for next time.
          onWalked: panel.putCursorOn,
        ),
      ),
    );
    if (mounted) _keyboard.requestFocus();
  }

  Future<RegisteredViewer?> _pickViewer(List<RegisteredViewer> candidates) =>
      showDeskWindow<RegisteredViewer>(
        context,
        id: 'viewer-picker',
        title: tr('Open with'),
        icon: Icons.visibility_outlined,
        preferredSize: const Size(460, 300),
        minSize: const Size(340, 220),
        builder: (window) => WindowForm(
          padding: const EdgeInsets.symmetric(vertical: 6),
          actions: [
            TextButton(onPressed: window.close, child: Text(tr('Cancel'))),
          ],
          child: ListView(
            children: [
              for (final viewer in candidates)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.extension_outlined),
                  title: Text(viewer.title),
                  subtitle: Text(viewer.pluginName),
                  onTap: () => window.close(viewer),
                ),
            ],
          ),
        ),
      );

  void _showNoViewer(FileEntry entry) {
    final extension = entry.extension.isEmpty
        ? tr('this file type')
        : '.${entry.extension}';
    showNotice(
      context,
      tr('No viewer plugin handles {what}.', {'what': extension}),
      long: true,
      actionLabel: tr('Plugins'),
      onAction: () => unawaited(_openSettings()),
    );
  }

  Future<void> _chooseRoot(PanelController panel) async {
    _app.activate(panel);
    final root = await showRootsDialog(context, _app.fileSystems);
    // Also a change of volume, whichever way the list of them was reached.
    if (root != null) await panel.openVolume(root);
    if (mounted) _keyboard.requestFocus();
  }

  /// Re-reads whichever panels were showing a folder the operation changed.
  ///
  /// One panel is not enough, and that was three separate bug reports. Copying
  /// with both panels on the same folder left the one copied *from* showing the
  /// listing it had before — the new file was on disk and in the other panel,
  /// which reads exactly like the copy having not happened. The same for
  /// renaming, and for a folder created beside an identical view.
  ///
  /// Only the folders that actually changed, so a panel sitting on an FTP server
  /// is not made to fetch a listing because something happened on a local disk.
  Future<void> _refreshWhereChanged(Iterable<VfsPath?> directories) async {
    final changed = directories.nonNulls.toSet();
    if (changed.isEmpty) return;

    for (final panel in [_app.left, _app.right]) {
      final location = panel.location;
      if (location == null) continue;
      // The folder itself, and any folder *inside* one of these — a panel
      // standing in a folder that has just been moved away or deleted is
      // standing nowhere, and only a re-read will tell it so. It then climbs
      // to the nearest folder above that still exists; see
      // `PanelController.refresh`.
      if (changed.contains(location) ||
          changed.any((path) => path.contains(location))) {
        await panel.refresh();
      }
    }
  }

  /// The folder each of these lives in — where something appearing or vanishing
  /// changes what a panel shows.
  Iterable<VfsPath?> _parentsOf(Iterable<VfsPath> paths) =>
      paths.map((path) => path.parent);

  /// True when [panel] can be written to, and says why not when it cannot.
  ///
  /// The F-key and the menu row are already dim where this is false; this is
  /// for the key pressed anyway — Del in a commit — and for the answer to be
  /// the same sentence wherever it is asked.
  bool _canWriteTo(PanelController panel) {
    if (!panel.isReadOnly) return true;
    showNotice(
      context,
      tr('{where} is read-only: nothing here can be changed.', {
        'where': panel.provider?.displayName ?? tr('This location'),
      }),
    );
    return false;
  }

  Future<void> _createDirectory() async {
    final panel = _app.active;
    final location = panel.location;
    if (location == null || !_canWriteTo(panel)) return;

    final name = await promptForText(
      context,
      title: tr('Create folder'),
      hint: tr('Folder name'),
      confirmLabel: tr('Create'),
    );
    if (name == null || name.trim().isEmpty) return;

    try {
      await _app.operations.createDirectory(location, name.trim());
      await _refreshWhereChanged([location]);
      panel.findMatches(name.trim());
    } on Object catch (e) {
      _reportError(e);
    }
    if (mounted) _keyboard.requestFocus();
  }

  /// Shift+F6: F2 for a single file, F6 for several.
  ///
  /// A third binding beside the two that exist, not a replacement for either.
  /// Which of the two it is depends on what is marked at the moment it is
  /// pressed, so the row along the bottom says which — see [_actions].
  Future<void> _renameOrMove() {
    if (_shiftF6Moves) return _transfer(move: true);
    // The marked file rather than whatever the cursor is standing on: with one
    // mark, that mark is the answer to "which file", and the cursor may be
    // three rows further down from having walked there.
    final marked = _app.active.marked;
    return _rename(only: marked.length == 1 ? marked.first : null);
  }

  /// Whether Shift+F6 would move rather than rename, right now.
  ///
  /// `actionTargets` is the orthodox rule — what is marked, or the cursor row
  /// when nothing is — so "several" means several *files*, not several marks
  /// left over in a listing that has since moved on.
  bool get _shiftF6Moves => _app.active.actionTargets.length > 1;

  Future<void> _rename({VfsPath? only}) async {
    final panel = _app.active;
    final entry = only == null
        ? panel.cursorEntry
        : panel.entries.where((e) => e.path == only).firstOrNull;
    if (entry == null || entry.isParentLink || !_canWriteTo(panel)) return;

    final name = await promptForText(
      context,
      title: tr('Rename'),
      initialValue: entry.name,
      confirmLabel: tr('Rename'),
      // Preselect the stem so typing replaces the name but keeps the suffix.
      selectionEnd: entry.extension.isEmpty
          ? entry.name.length
          : entry.name.length - entry.extension.length - 1,
    );
    if (name == null || name.trim().isEmpty || name == entry.name) return;

    try {
      await _app.operations.rename(entry.path, name.trim());
      await _refreshWhereChanged([entry.path.parent]);
      // The row now has a different name, so the cursor follows the new one.
      panel.findMatches(name.trim());
    } on Object catch (e) {
      _reportError(e);
    }
    if (mounted) _keyboard.requestFocus();
  }

  /// Shift+F5 — duplicate the cursor row under a name the user gives.
  ///
  /// **This** folder is the default, not the other panel's: the usual reason to
  /// reach for it is to keep a copy of something beside the original before
  /// changing it. F5 is the command for "put it over there".
  ///
  /// The whole destination is prefilled, folder and all, with only the name part
  /// selected: type and the name is replaced, or edit the folder and the copy
  /// lands somewhere else entirely.
  Future<void> _copyAs() async {
    final panel = _app.active;

    // One name cannot serve several files. With a set marked, the useful reading
    // of Shift+F5 is the ordinary copy, so that is what it does rather than
    // refusing or quietly acting on one row out of the set.
    if (panel.actionTargets.length > 1) return _transfer(move: false);

    final entry = panel.cursorEntry;
    final destination = panel.location;
    if (entry == null || entry.isParentLink || destination == null) return;

    final separator = destination.scheme == VfsPath.localScheme && Platform.isWindows
        ? r'\'
        : '/';
    final folder = destination.display.endsWith(separator)
        ? destination.display
        : '${destination.display}$separator';
    final initial = '$folder${entry.name}';
    final stemEnd = entry.extension.isEmpty
        ? initial.length
        : initial.length - entry.extension.length - 1;

    final typed = await promptForText(
      context,
      title: tr('Copy as'),
      initialValue: initial,
      confirmLabel: tr('Copy'),
      selectionStart: folder.length,
      selectionEnd: stemEnd,
    );
    if (typed == null || typed.trim().isEmpty || !mounted) return;

    final target = _resolveDestination(typed.trim(), destination);
    if (target == null) return;
    if (target == entry.path) {
      // Submitted unchanged. Copying a file onto itself is not a thing that can
      // be done, and saying nothing at all would read as the command failing.
      showNotice(
        context,
        tr('A copy beside the original needs a name of its own.'),
      );
      return;
    }

    // One name, but a folder under it can hold any number of collisions, so
    // this copy gets its own memory of what was answered just like a transfer.
    final conflicts = ConflictPolicy();
    final result = await runWithProgress(
      context,
      title: tr('Copying…'),
      task: (onProgress, token) => _app.operations.copyAs(
        entry.path,
        target,
        onConflict: (src, existing) => conflicts.resolve(context, src, existing),
        onProgress: onProgress,
        token: token,
      ),
    );

    await _refreshWhereChanged([target.parent]);
    if (mounted) {
      showOperationResult(context, result);
      _keyboard.requestFocus();
    }
  }

  /// What the user typed into "Copy as": a whole path, or a bare name meaning a
  /// file in [fallbackDirectory].
  VfsPath? _resolveDestination(String typed, VfsPath fallbackDirectory) {
    if (typed.contains('://')) return VfsPath.parse(typed);

    final looksLikeAPath = Platform.isWindows
        ? RegExp(r'^([A-Za-z]:[\\/]|\\\\)').hasMatch(typed)
        : typed.startsWith('/');
    if (looksLikeAPath) return VfsPath.local(typed);

    // A name, or a relative path below the folder shown.
    var result = fallbackDirectory;
    for (final segment in typed.split(RegExp(r'[\\/]'))) {
      if (segment.isEmpty || segment == '.') continue;
      result = segment == '..' ? (result.parent ?? result) : result.child(segment);
    }
    return result == fallbackDirectory ? null : result;
  }

  Future<void> _transfer({required bool move}) async {
    final source = _app.active;
    final target = _app.inactive;
    final targetLocation = target.location;
    final sources = source.actionTargets;
    if (targetLocation == null || sources.isEmpty) return;
    // Where it lands has to take it, and a move also empties where it came
    // from: out of a commit a copy can be brought forward, a move cannot.
    if (!_canWriteTo(target)) return;
    if (move && !_canWriteTo(source)) return;

    await _runTransfer(sources: sources, target: targetLocation, move: move);
    source.clearMarks();
  }

  /// Where every copy and every move in the application ends up: the F-keys,
  /// a paste, and a selection dropped on a panel.
  ///
  /// [ask] is the only thing that differs between them, and it differs for a
  /// reason. F5 names no target — it acts on the other panel, whichever that
  /// is, so it says out loud what it is about to do. A paste and a drop were
  /// both aimed by hand at a place the user was looking at; asking again is
  /// asking somebody to confirm the gesture they just made.
  Future<bool> _runTransfer({
    required List<VfsPath> sources,
    required VfsPath target,
    required bool move,
    bool ask = true,

    /// What the user called this, for the report at the end and the words on
    /// the progress window. Packing and unpacking are this same copy underneath
    /// — that is the design — but a report of a failed *compression* that calls
    /// itself a copy is describing the machinery instead of the request.
    String? as,
    String? busyTitle,

    /// The one name everything lands under, for a copy of a single thing that
    /// is being given a new one — extracting an archive into a folder called
    /// after it. Meaningless for several sources, and asserted against.
    String? underName,
  }) async {
    if (sources.isEmpty) return false;
    assert(
      underName == null || sources.length == 1,
      'one new name cannot serve several sources',
    );

    // A folder cannot be copied into itself. Copying a file into the folder it
    // is already in is a different matter and a real one — it is how a
    // duplicate is made, and the collision that follows is what offers the
    // name for it.
    final workable =
        sources.where((path) => !path.contains(target)).toList(growable: false);
    if (workable.isEmpty) return false;

    final verb = move ? tr('Move') : tr('Copy');
    if (ask) {
      final confirmed = await confirm(
        context,
        title: tr('{verb} {count} item(s)',
            {'verb': verb, 'count': workable.length}),
        message: tr('To {target}', {'target': target.display}),
        confirmLabel: verb,
      );
      if (!confirmed || !mounted) return false;
    }

    // One memory for the whole transfer — a copy, a move, a pack or an unpack
    // all end up here, so "Apply to all" reaches every one of them. It is made
    // per command and thrown away with it: the next transfer asks again.
    final conflicts = ConflictPolicy();
    final result = await runWithProgress(
      context,
      title: busyTitle ?? (move ? tr('Moving…') : tr('Copying…')),
      task: (onProgress, token) {
        if (underName != null) {
          return _app.operations.copyAs(
            workable.single,
            target.child(underName),
            onConflict: (src, existing) =>
                conflicts.resolve(context, src, existing),
            onProgress: onProgress,
            token: token,
            as: as,
          );
        }
        if (move) {
          return _app.operations.move(
            workable,
            target,
            onConflict: (src, existing) =>
                conflicts.resolve(context, src, existing),
            onProgress: onProgress,
            token: token,
          );
        }
        return _app.operations.copy(
          workable,
          target,
          onConflict: (src, existing) =>
              conflicts.resolve(context, src, existing),
          onProgress: onProgress,
          token: token,
          as: as,
        );
      },
    );

    // Where things arrived, and — for a move — where they left from. Either can
    // be what both panels are showing.
    await _refreshWhereChanged([
      target,
      // For a move, where they left from *and* what they were: a panel
      // standing inside one of these folders has just lost the ground under
      // it.
      if (move) ...workable,
      if (move) ..._parentsOf(workable),
    ]);

    if (mounted) {
      showOperationResult(context, result);
      _keyboard.requestFocus();
    }
    return true;
  }

  // --- The clipboard ------------------------------------------------------

  /// Ctrl+C and Ctrl+X. What is marked, or the row under the cursor.
  ///
  /// A cut takes nothing away yet and marks nothing as taken: the files go when
  /// the paste that consumes them has arrived. Everything else is a file
  /// manager that has hidden your files because you pressed a key and then
  /// changed your mind.
  Future<void> _copyToClipboard({required bool cut}) async {
    final panel = _app.active;
    final sources = panel.actionTargets;
    if (sources.isEmpty) return;
    if (cut && !_canWriteTo(panel)) return;

    if (cut) {
      await _app.clipboard.cut(sources);
    } else {
      await _app.clipboard.copy(sources);
    }
    if (!mounted) return;
    showNotice(
      context,
      cut
          ? tr('{count} item(s) cut.', {'count': '${sources.length}'})
          : tr('{count} item(s) copied.', {'count': '${sources.length}'}),
    );
  }

  /// Ctrl+V and Shift+Insert, wherever the keyboard happens to be.
  ///
  /// **What is on the clipboard decides what the key means.** Files on it and
  /// the panel takes them; anything else and the command line takes the text,
  /// which is what both of these keys have always done here. The one exception
  /// is a command line being typed in: a caret in a field is an aim, and text
  /// is what it is aimed at.
  Future<void> _pasteHere() async {
    if (_editingCommand) return _pasteIntoCommandLine();

    final held = await _app.clipboard.read();
    if (held == null || held.paths.isEmpty) return _pasteIntoCommandLine();
    if (!mounted) return;

    final panel = _app.active;
    final target = panel.location;
    if (target == null) return;
    if (!_canWriteTo(panel)) return;

    final move = held.intent == TransferIntent.move;
    final done = await _runTransfer(
      sources: held.paths,
      target: target,
      move: move,
      ask: false,
    );
    // A cut is spent by the paste that completed it. A copy is not: pasting
    // the same files into three folders in turn is the ordinary way to use one.
    if (done && move) _app.clipboard.consumed();
  }

  Future<void> _delete({required bool toTrash}) async {
    final panel = _app.active;
    final targets = panel.actionTargets;
    if (targets.isEmpty || !_canWriteTo(panel)) return;

    // Falling back silently from the recycle bin to a permanent delete would
    // be the worst possible surprise, so say which one is about to happen.
    final canTrash = toTrash && _app.operations.canTrash(targets);
    if (toTrash && !canTrash) {
      final proceed = await confirm(
        context,
        title: tr('No recycle bin here'),
        message: tr(
          'This location cannot move files to a recycle bin. '
          'Delete {count} item(s) permanently?',
          {'count': targets.length},
        ),
        confirmLabel: tr('Delete permanently'),
        destructive: true,
      );
      if (!proceed || !mounted) return;
    } else {
      final confirmed = await confirm(
        context,
        title: canTrash
            ? tr('Move {count} item(s) to the recycle bin', {
                'count': targets.length,
              })
            : tr('Permanently delete {count} item(s)', {
                'count': targets.length,
              }),
        message: targets.length == 1
            ? targets.first.display
            : canTrash
            ? tr('They can be restored from the recycle bin.')
            : tr('This cannot be undone.'),
        confirmLabel: canTrash ? tr('Move to bin') : tr('Delete'),
        destructive: !canTrash,
      );
      if (!confirmed || !mounted) return;
    }

    final result = await runWithProgress(
      context,
      title: canTrash ? tr('Moving to the recycle bin…') : tr('Deleting…'),
      task: (onProgress, token) => _app.operations.delete(
        targets,
        toTrash: canTrash,
        onProgress: onProgress,
        token: token,
      ),
    );

    // The folders they were in, and the folders they *were*: the other panel
    // may be standing inside one that has just gone to the bin.
    await _refreshWhereChanged([...targets, ..._parentsOf(targets)]);
    panel.clearMarks();
    if (mounted) {
      showOperationResult(context, result);
      _keyboard.requestFocus();
    }
  }

  /// Ctrl+U — the classic "swap panels" binding, and it swaps the panels.
  ///
  /// The whole of it is [AppState.swapSides]: what used to be here navigated
  /// each panel to the other's path, which left the cursor, the marks and any
  /// tool being held behind on the old side.
  void _swapPanels() => _app.swapSides();

  /// Looks for a release when one is due, at a start and then while it runs,
  /// and offers what it finds.
  ///
  /// **A start is no longer the only moment.** It was, and the reasoning was
  /// that a start is the one time the person is not already in the middle of
  /// something — true, and beside the point once every published build became
  /// one somebody put there by hand for a reason. This application is opened
  /// in the morning and left open; a build put out at noon reached nobody until
  /// they happened to restart, which on some machines is next week.
  ///
  /// Nothing is downloaded by the looking, and nothing is installed without an
  /// answer — the three answers and how long each of them lasts are
  /// [UpdatePrompt].
  Future<void> _offerUpdateWhenDue() async {
    if (Platform.isAndroid || Platform.isIOS) return;
    final settings = _settings;
    final now = DateTime.now();
    final asked = settings.updatePrompt;
    if (!asked.dueForCheck(now)) return;

    // **Never over a question already on screen.** A modal is something being
    // answered — a name being typed, a collision being decided — and a window
    // arriving on top of it takes the keyboard away mid-word. Asked twice: once
    // to save the request, and again after it, because the listing takes a
    // moment and a window can open inside that moment.
    if (_windows.hasModal) return;

    final source = defaultReleaseSource();
    final found = await checkForUpdate(
      source: source,
      running:
          ReleaseVersion.tryParse(kAppVersion) ?? const ReleaseVersion([0, 0, 0, 0]),
    );
    // **Nothing is recorded when it backs off here**, so the next tick looks
    // again in fifteen minutes rather than what was found being lost for four
    // hours. It costs one listing per tick, and only while a window is open.
    if (!mounted || _windows.hasModal) return;

    // Written whatever the answer was, a failure included: a machine that is
    // never on a network must not reach for one at every tick.
    final prompt = asked.copyWith(lastChecked: now);
    await settings.setUpdatePrompt(prompt);

    // Silent for all three of "nothing newer", "nothing published" and "could
    // not be read". Nobody asked, so nobody is told.
    if (found is! UpdateAvailable) return;
    if (!prompt.worthOffering(found.archive.version, now)) return;

    final notes = await ReleaseNotes.fetch(source, found.archive.version);
    if (!mounted) return;
    final answer = await showUpdateOffer(
      context,
      running: found.running,
      offered: found.archive.version,
      notes: notes,
    );

    switch (answer) {
      case UpdateAnswer.later:
        await settings.setUpdatePrompt(
            prompt.afterLater(DateTime.now(), found.archive.version));
      case UpdateAnswer.staying:
        await settings
            .setUpdatePrompt(prompt.afterStaying(found.archive.version));
      case UpdateAnswer.install:
        await settings.setUpdatePrompt(prompt.afterInstalling());
        await _takeUpdate(source, found.archive);
    }
  }

  /// Everything slow, with the window still up and saying what is happening.
  ///
  /// A notice rather than a modal window: none of this can be cancelled — the
  /// download and its checksum are one call — and a modal with no way out of
  /// it is worse than a line that says where it has got to.
  Future<void> _takeUpdate(ReleaseSource source, ReleaseArchive archive) async {
    StageStep? reached;
    try {
      await UpdateStart.run(
        source: source,
        archive: archive,
        onStep: (step) {
          reached = step;
          if (mounted) showNotice(context, _updateNote(step), long: true);
        },
      );
    } on Object catch (problem) {
      final logged = await UpdateLog.path();
      if (!mounted) return;
      hideNotice();
      // **A window, not a remark.** This used to be a notice along the bottom
      // and it took the reason away with it after three seconds — which is how
      // an update that failed on Windows came to be a thing nobody could say
      // anything about. A failure stays until it is read and goes to the
      // clipboard whole; see [showProblem].
      await showProblem(
        context,
        title: tr('The update did not happen'),
        message: '$problem',
        detail: [
          if (reached != null)
            tr('It got as far as: {step}', {'step': _updateNote(reached!)}),
          tr('Version {version}, from {source}', {
            'version': '${archive.version}',
            'source': source.describe,
          }),
          ?logged,
        ].join('\n'),
      );
    }
  }

  String _updateNote(StageStep step) => switch (step) {
        StageStep.downloading => tr('Downloading…'),
        StageStep.verifying => tr('Checking what was downloaded…'),
        StageStep.unpacking => tr('Unpacking…'),
        StageStep.copying => tr('Preparing to restart…'),
        StageStep.ready => tr('Restarting…'),
      };

  Future<void> _openSettings() async {
    // A page, not a window: settings are somewhere you go and come back from,
    // and they want the whole area rather than a frame floating over it. The
    // page draws the application's own title bar itself, so the window is
    // still draggable from inside — see SettingsPage.
    await SettingsPage.open(context);
    if (mounted) _keyboard.requestFocus();
  }

  /// Explorer's own menu for the row under the pointer, after the right button
  /// has been held.
  ///
  /// The position is in logical pixels; the shell wants physical ones on the
  /// screen. Only the first half of that conversion happens here — the runner
  /// knows where its own window is and turns client coordinates into screen
  /// ones itself, which is one fewer thing to get wrong from this side.
  Future<void> _showSystemMenu(Offset position, FileEntry entry) async {
    final ratio = View.of(context).devicePixelRatio;

    final failure = await SystemMenu.show(
      entry.path.toNativePath(),
      x: (position.dx * ratio).round(),
      y: (position.dy * ratio).round(),
    );

    if (failure != null && mounted) showNotice(context, failure);
    // Whatever the shell did with the file, the listing may no longer match it —
    // in either panel, if both are looking at that folder.
    if (mounted) {
      unawaited(_refreshWhereChanged([_app.active.location]));
    }
  }

  void _reportError(Object error) {
    if (!mounted) return;
    // The same voice the viewer's own failures speak in — see [saidPlainly].
    // A remark along the bottom saying `PathNotFoundException` is a remark
    // written for whoever wrote the code rather than for whoever pressed F8.
    showNotice(context, saidPlainly(error), long: true);
  }
}

class _CommandAction {
  const _CommandAction(
    this.key,
    this.label,
    this.icon,
    this.run, {
    this.enabled = true,
  });

  final String key;
  final String label;
  final IconData icon;
  final Future<void> Function() run;

  /// False where this cannot work — a write inside a commit, an archive, or
  /// anything else the provider says is read-only.
  final bool enabled;
}

/// Quick search: a small box hanging over the bottom right of the panel, shaped
/// like the one the context menu opens.
///
/// The one box, however it was opened. Alt+S brings it up empty; Ctrl+Alt+letter
/// and plain typing bring it up already holding that letter — three ways into
/// the same search, not three searches.
///
/// It draws its own caret. There is no [TextField] behind this on purpose — a
/// field would claim Enter, the arrow keys and every editing chord for itself,
/// and the rule here is the opposite one: only what can be part of a file name
/// stays in the box, and everything else ends the search and reaches the
/// application. Drawing the caret costs two [Text]s and a rule, and keeps every
/// key in one place.
/// The name the quick search box answers to.
///
/// **For the tests, and the tests needed it.** Asking the whole screen whether
/// the letter `x` is on it found the box *and* a step of the path bar, which on
/// this machine had shortened a long temporary folder to its first letter — so
/// the test failed on the Mac and passed on Windows for weeks, over nothing.
/// A widget a test has to point at is a widget with a name.
const Key quickSearchBoxKey = Key('quick-search-box');

class _QuickSearchBox extends StatelessWidget {
  const _QuickSearchBox({
    required this.query,
    required this.caret,
    required this.matches,
    required this.onClose,
  });

  final String query;
  final int caret;
  final int matches;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final found = matches > 0 || query.isEmpty;
    final at = caret.clamp(0, query.length);

    // **It is painted as the menu is painted**, which is what it has always
    // been described as: a small box that hangs over the listing the way the
    // context menu does. It took the *header's* fill and the *panel's* ink
    // instead — two colours from two different places — and on a dark palette
    // that came out near-black on slate, with none of the translucency the
    // menus have.
    final menu = menuAppearanceFrom(theme);
    final surface = menu.background.withValues(alpha: menu.opacity);
    // Contrast is asked of the *opaque* fill: what shows through a translucent
    // one is the blurred listing, which has no one colour to be measured
    // against, and the fill is what dominates it.
    final ground = menu.background;

    final typed = TextStyle(
      // The no-match colour is borrowed from the palette, so it goes through
      // the same rule everything borrowed does — see [legibleInk].
      color: found
          ? menu.foreground
          : legibleInk(
              theme.markedColor,
              on: ground,
              fallback: menu.foreground,
            ),
      fontSize: theme.fontSize,
      fontWeight: FontWeight.w600,
    );
    final muted = TextStyle(
      color: menu.foreground.withValues(alpha: 0.6),
      fontSize: theme.fontSize - 2,
    );

    return Listener(
      key: quickSearchBoxKey,
      // A hit target of its own, so the click that would put the search away
      // is not the click that lands on the box itself. Opaque behaviour rather
      // than a gesture, or the close button would have to win an arena to be
      // pressed.
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {},
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Material(
          type: MaterialType.transparency,
          // The shadow is on the outside of the clip, or it would be blurred
          // along with everything else and then cut off at the corners.
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF000000).withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: blurredBackdrop(
                sigma: menu.blur,
                passes: menu.blurPasses,
                child: Container(
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: theme.accentColor.withValues(alpha: 0.6),
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.search,
                        size: 14,
                        color: legibleInk(
                          theme.accentColor,
                          on: ground,
                          fallback: menu.foreground,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(query.substring(0, at), style: typed),
                      Container(
                        width: 1.5,
                        height: theme.fontSize + 3,
                        color: legibleInk(
                          theme.accentColor,
                          on: ground,
                          fallback: menu.foreground,
                        ),
                      ),
                      Text(query.substring(at), style: typed),
                      const SizedBox(width: 10),
                      Text(
                        query.isEmpty
                            ? tr('Type to search')
                            : found
                            ? tr('{count} match(es) · ↑↓ to step, Esc to close',
                                {'count': matches})
                            : tr('no match'),
                        style: muted,
                      ),
                      ExcludeFocus(
                        child: IconButton(
                          iconSize: 14,
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 22, minHeight: 22),
                          color: menu.foreground,
                          icon: const Icon(Icons.close),
                          onPressed: onClose,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The F-key bar at the bottom. On narrow screens the labels turn into icons.
class _CommandBar extends StatelessWidget {
  const _CommandBar({required this.actions, required this.compact});

  final List<_CommandAction> actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;

    return Container(
      // Grows with the text it holds. Left at 30 the bar kept its height while
      // the labels in it grew, so turning the size up squeezed the hints rather
      // than enlarging them — which reads as the F-keys being the one thing
      // that ignored the setting.
      height: theme.scaled(compact ? 52 : 30),
      color: theme.effectiveHeaderBackground,
      child: Row(
        children: [
          for (final action in actions)
            Expanded(
              // Half-lit, and it does not answer. The bar's own colours taken
              // down rather than a grey of their own: a disabled key on a dark
              // theme and on a light one is the same key, less of it.
              child: Opacity(
                opacity: action.enabled ? 1 : 0.35,
                child: InkWell(
                  onTap: action.enabled ? action.run : null,
                  child: compact
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              action.icon,
                              size: 18,
                              color: theme.headerForeground,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              action.label,
                              style: TextStyle(
                                color: theme.headerForeground,
                                fontSize: theme.scaled(10),
                              ),
                            ),
                          ],
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              action.key,
                              style: TextStyle(
                                color: theme.accentColor,
                                fontSize: theme.fontSize - 1,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 5),
                            // Flexible, because eight tiles share the width and
                            // the words in them are not the application's to
                            // choose: a longer language, a larger font or a key
                            // that grows a Shift into its name all end at the
                            // same striped overflow otherwise.
                            Flexible(
                              child: Text(
                                action.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: theme.headerForeground,
                                  fontSize: theme.fontSize - 1,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Left/right selector shown instead of the second panel on small screens.
class _PanelSwitcher extends StatelessWidget {
  const _PanelSwitcher({required this.leftActive, required this.onSelect});

  final bool leftActive;
  final ValueChanged<bool> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;

    Widget tab(String label, bool isLeft) => Expanded(
      child: InkWell(
        onTap: () => onSelect(isLeft),
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: leftActive == isLeft
                    ? theme.accentColor
                    : Colors.transparent,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: leftActive == isLeft
                  ? theme.headerForeground
                  : theme.headerForeground.withValues(alpha: 0.6),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: theme.effectiveHeaderBackground,
        // The same hairline that runs under the menu: in this layout the tabs
        // are what the panel hangs from, so this is where the line belongs.
        border: Border(bottom: BorderSide(color: theme.chromeRule)),
      ),
      child: Row(children: [tab(tr('Left'), true), tab(tr('Right'), false)]),
    );
  }
}
