import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../../core/plugins/view.dart';
import '../../core/settings/settings_store.dart';
import '../../core/vfs/vfs_path.dart';
import '../../state/app_state.dart';
import '../../state/panel_attachment.dart';
import '../keyboard_focus.dart';
import '../page_transition.dart';
import '../viewer/plugin_viewer_page.dart' show PluginContentView;
import '../widgets/context_menu.dart' show MenuNode;
import '../widgets/escape_to_pop.dart';
import '../widgets/title_bar.dart';
import 'plugin_icons.dart';
import 'plugin_table.dart' show driveTable;
import 'row_menu.dart';
import 'view_pill.dart';
import '../windows/window_layer.dart';

/// A plugin's view, filling the window.
///
/// The same session machinery as a panel uses — a view cannot tell the two
/// apart except by the surface named in its context, and that is deliberate:
/// what a view draws should not have to change because of where it was opened.
class PluginViewPage extends StatefulWidget {
  const PluginViewPage({
    super.key,
    required this.view,
    required this.location,
    required this.onActions,
    this.otherLocation,
    this.canToPanel = false,
  });

  final RegisteredView view;

  /// Where the panel it was opened from was pointing.
  final VfsPath? location;

  /// Where the other panel was — the one that was not being worked in. A tool
  /// about both sides of the application needs both.
  final VfsPath? otherLocation;

  /// Carries out what the view asks for. A full-screen view has no panel of
  /// its own, so "the other panel" means the inactive one, exactly as it does
  /// everywhere else — the screen decides that, not this page.
  final ViewActionSink onActions;

  /// Whether this view can be shown in a panel at all. Only then is there
  /// anywhere to send it, and only then is the button worth drawing.
  final bool canToPanel;

  /// Opens the page, and answers **true** when it was left by asking for the
  /// panel rather than by going back.
  ///
  /// A result rather than a callback: the page has to be gone before the view
  /// is opened again somewhere else — the same view twice on screen is the one
  /// thing the page claim exists to stop — and popping with an answer is how
  /// the two are put in that order without either knowing about the other.
  static Future<bool> open(
    BuildContext context, {
    required RegisteredView view,
    required VfsPath? location,
    required ViewActionSink onActions,
    VfsPath? otherLocation,
    bool canToPanel = false,
  }) async {
    final result = await Navigator.of(context).push<bool>(
      MotionPageRoute<bool>.of(
        context,
        // Named, so a page buried under another tool's can be found and
        // brought back rather than being refused — see [AppState.pageRouteName].
        settings: RouteSettings(name: AppState.pageRouteName(view.id)),
        builder: (_) => PluginViewPage(
          view: view,
          location: location,
          otherLocation: otherLocation,
          onActions: onActions,
          canToPanel: canToPanel,
        ),
      ),
    );
    return result ?? false;
  }

  /// Full screen to a panel and back. Ctrl and Shift so it cannot be reached
  /// by accident from a view that takes plain Enter for its own.
  static const SingleActivator toPanelKey = SingleActivator(
    LogicalKeyboardKey.enter,
    control: true,
    shift: true,
  );

  @override
  State<PluginViewPage> createState() => _PluginViewPageState();
}

class _PluginViewPageState extends State<PluginViewPage> {
  late final PluginViewAttachment _attachment = PluginViewAttachment(
    view: widget.view,
    session: 'page',
    surface: PluginSurface.fullscreen,
    location: widget.location,
    otherLocation: widget.otherLocation,
    onActions: widget.onActions,
  );

  @override
  void initState() {
    super.initState();
    _attachment.start(location: widget.location);
  }

  @override
  void dispose() {
    // The plugin is told the session is over, but nothing here can wait for
    // it: the page is going away this frame.
    unawaited(_attachment.release());
    _attachment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;

    return Focus(
      // Outside `EscapeToPop`, so its own autofocused node sees the key first
      // and this one only gets what it did not want.
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (widget.canToPanel &&
            PluginViewPage.toPanelKey.accepts(event, HardwareKeyboard.instance)) {
          _toPanel();
          return KeyEventResult.handled;
        }
        return _onKey(event);
      },
      child: EscapeToPop(
      // A page the view put over its own goes back first. Only when there is
      // none left does Escape mean the whole tool.
      onEscape: _goBack,
      child: ColoredBox(
        // The panel's own fill, backdrop and all: a page fills the window, and
        // a window that is translucent everywhere except on its pages is a
        // window whose translucency the user cannot see.
        color: theme.effectivePanelBackground,
        child: ListenableBuilder(
          listenable: _attachment,
          builder: (context, _) => Column(
            children: [
              // The view's chrome *is* the title bar now. Back, the way into a
              // panel, whatever menu the view declares and its own title all
              // stand in the application's bar rather than in a second one
              // underneath it — two bars for one window was the thing to lose.
              TitleBar(
                leading: [
                  TitleBarButton(
                    icon: Icons.arrow_back,
                    tooltip: tr('Back'),
                    // The same one key: back a page while the view has one,
                    // and out of the tool when it has not.
                    onPressed: () {
                      if (!_goBack()) Navigator.of(context).pop();
                    },
                  ),
                  if (widget.canToPanel)
                    TitleBarButton(
                      icon: Icons.flip_to_back,
                      tooltip: tr('Show in the panel'),
                      onPressed: _toPanel,
                    ),
                ],
                menus: [
                  for (final menu in _attachment.menus)
                    TitleBarMenu(
                      menu.label,
                      accelerator: menu.accelerator,
                      () => _menuNodes(menu.items),
                    ),
                ],
                // **A pill stands where the path stands.** It is the same
                // sentence — which repository, which branch — and two of them
                // in one bar is one of them being ignored. See `ViewChrome`.
                title: ViewChrome(
                  attachment: _attachment,
                  theme: theme,
                  titleStyle: TitleBar.titleStyle(theme),
                ),
                actions: [
                  for (final command in _attachment.commands)
                    if (!command.isPill)
                      TitleBarButton(
                        icon: pluginIcon(command.icon),
                        tooltip: command.tooltip ?? command.label,
                        onPressed: () => unawaited(
                          _attachment.press(command.id),
                        ),
                      ),
                ],
              ),
              Expanded(
                child: WindowLayer(
                  stack: context.read<AppState>().windows,
                  child: Scaffold(
                    backgroundColor: Colors.transparent,
                    body: switch (_attachment.content) {
                      null => const Center(child: CircularProgressIndicator()),
                      final content => PluginContentView(
                          content: content,
                          pluginId: _attachment.pluginId,
                          cursor: _attachment.cursorFor,
                          focusedPart: _attachment.focusedPart,
                          onFocusPart: _attachment.focusPart,
                          onActivateRow: (row, part) =>
                              _attachment.activate(row, part: part),
                          onMarkRow: (row, part, at) => unawaited(
                            showViewRowMenu(
                              context: context,
                              attachment: _attachment,
                              row: row,
                              part: part,
                              at: at,
                            ),
                          ),
                          onButton: (id, values) =>
                              _attachment.press(id, values: values),
                          onDropRows: (from, to, rows) =>
                              _attachment.dropRows(from, to, rows),
                        ),
                    },
                  ),
                ),
              ),
              // Where a panel keeps its own: along the bottom. It used to hang
              // under the title as a second line, which is a place the panels
              // never put a total and the eye never looks for one.
              if (_attachment.status != null)
                // Its own Material, and not decoration. Text with no Material
                // above it is drawn in the framework's error style, and a
                // style that sets a colour and a size but no decoration
                // inherits the rest of it — which is where the yellow double
                // underline under the status line came from. The title bar
                // carries the same note for the same reason; this strip sits
                // outside it, under the Scaffold rather than inside one.
                Material(
                  type: MaterialType.transparency,
                  child: Container(
                    height: theme.chromeRowHeight,
                    width: double.infinity,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    color: theme.effectiveHeaderBackground,
                    child: Text(
                      _attachment.status!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // The header's own ink, not the page's — see the same
                        // correction in the viewer's status line.
                        color: theme.headerForeground,
                        fontSize: theme.fontSize - 1,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// Leaves the page with an answer the launcher acts on.
  void _toPanel() => Navigator.of(context).pop(true);

  /// True when there was a page to go back to, and it is now on screen.
  bool _goBack() {
    if (!_attachment.canGoBack) return false;
    unawaited(_attachment.goBack());
    return true;
  }

  /// The keyboard, which used to stop at the edge of this page.
  ///
  /// A view in a panel has always had one: the commander screen hands it every
  /// key the panel does not claim. Full screen there was no panel to do that,
  /// so a tool that filled the window could only be worked with a mouse —
  /// which is the rule this application is built on, broken in the one place
  /// the tool is largest.
  ///
  /// Same order as the panel's, and that order is the contract: a view that
  /// asked for `keys` gets first refusal, and the table's own cursor takes
  /// what is left.
  KeyEventResult _onKey(KeyDownEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) return KeyEventResult.ignored;

    // A field on this page has the keyboard, so what is typed is its business
    // and nothing else's. A field lets the key events go up unclaimed while it
    // takes the characters themselves through the platform — so without this,
    // the space in a commit message also marked a row in the list above it.
    // The form answers Escape itself; see [PluginForm].
    if (keyboardIsInAField()) return KeyEventResult.ignored;

    // The same binding a panel has, so one key walks the parts wherever the
    // tool is. Plain Tab does it here too — full screen there is no second
    // panel for it to switch to.
    final keys = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.tab &&
        (keys.isControlPressed || keys.isAltPressed)) {
      return _attachment.focusNextPart(backwards: keys.isShiftPressed)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (_attachment.wantsKeys) {
      final named = _viewKeyName(key, event);
      if (named != null) {
        unawaited(_attachment.handleKey(named));
        return KeyEventResult.handled;
      }
    }
    // Full screen there is no second panel for Tab to switch to, so it is
    // free to do what it does in every other tool with more than one list in
    // it: walk to the next one.
    return driveTable(
      _attachment,
      key,
      shift: HardwareKeyboard.instance.isShiftPressed,
      acrossParts: true,
    )
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  /// The name a view is told a key by. The function row and Tab are not on the
  /// list, exactly as they are not on the panel's — see `CommanderScreen`.
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
        _ => event.character != null && event.character!.trim().isNotEmpty
            ? event.character
            : null,
      };

  /// A view's menu rows, as the ones the application's own menus are made of.
  ///
  /// Built on every open, so a checkbox shows what the view last said. A row
  /// with neither an id nor children is a separator — see [ViewMenuItem].
  List<MenuNode> _menuNodes(List<ViewMenuItem> items) =>
      viewMenuNodes(items, (id) => unawaited(_attachment.press(id)));
}

