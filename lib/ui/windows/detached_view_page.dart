import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../../core/settings/settings_store.dart';
import '../../state/app_state.dart';
import '../../state/panel_attachment.dart';
import '../../state/window_stack.dart';
import '../plugins/plugin_about.dart';
import '../plugins/plugin_icons.dart';
import '../plugins/row_menu.dart';
import '../plugins/view_pill.dart' show ViewChrome, viewMenuNodes;
import '../viewer/plugin_viewer_page.dart' show PluginContentView;
import '../widgets/title_bar.dart';
import 'detached_window.dart';
import 'window_layer.dart';

/// **What a detached view is drawn by**: the thing that was in a panel, now
/// filling a window of its own.
///
/// It is the same [PanelAttachment] object the panel was showing — a quick
/// view of a file, or a plugin's view — handed over rather than started
/// again. Nothing is reloaded and nothing is re-measured; what was on the
/// screen is on the screen, in a window that now owns it.
///
/// **And it stays on it.** A quick view in a panel follows the other panel's
/// cursor because the panel tells it to; nothing tells it anything here, so
/// the file it was on is the file it keeps, whatever happens next in the
/// commander. That is the whole point of detaching one.
class DetachedViewPage extends StatefulWidget {
  const DetachedViewPage({super.key, required this.attachment});

  final PanelAttachment attachment;

  @override
  State<DetachedViewPage> createState() => _DetachedViewPageState();
}

class _DetachedViewPageState extends State<DetachedViewPage> {
  /// **This window's own desk.** A form a view opens belongs over the window
  /// it was opened in, and the application's own stack is the first window's.
  final WindowStack _desk = WindowStack();

  PanelAttachment get _attachment => widget.attachment;

  @override
  void dispose() {
    _desk.dispose();
    super.dispose();
  }

  PluginManifest? get _manifest {
    final id = _attachment.pluginId;
    if (id == null) return null;
    final registry = context.read<AppState?>()?.plugins;
    return registry?.manifestOf(id);
  }

  Future<void> _showAbout() async {
    final manifest = _manifest;
    if (manifest == null) return;
    await showPluginAbout(context, manifest: manifest);
  }

  /// Escape, and the arrow in the bar: a page the view put over its own goes
  /// back first, and when there is none left the window closes.
  void _leave() {
    if (_attachment.canGoBack) {
      unawaited(_attachment.goBack());
      return;
    }
    DetachedWindowScope.closeOf(context)?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          _leave();
          return KeyEventResult.handled;
        }
        // F1 and ? reach a plugin's card from every page it draws.
        if (isPluginAboutKey(event)) {
          unawaited(_showAbout());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: WindowStackScope(
        stack: _desk,
        child: ColoredBox(
          color: theme.effectivePanelBackground,
          child: ListenableBuilder(
            listenable: _attachment,
            builder: (context, _) => Column(
              children: [
                // The same bar a view fills the first window with: back, the
                // view's own menus, its title as a pill, its commands and its
                // plugin's card — in the application's bar, because a window
                // with two bars is one of them being ignored.
                TitleBar(
                  leading: [
                    TitleBarButton(
                      icon: Icons.arrow_back,
                      tooltip: _attachment.canGoBack
                          ? tr('Back')
                          : tr('Close the window'),
                      onPressed: _leave,
                    ),
                  ],
                  menus: [
                    for (final menu in _attachment.menus)
                      TitleBarMenu(
                        menu.label,
                        accelerator: menu.accelerator,
                        () => viewMenuNodes(
                          menu.items,
                          (id) => unawaited(_attachment.press(id)),
                        ),
                      ),
                  ],
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
                          onPressed: () =>
                              unawaited(_attachment.press(command.id)),
                        ),
                    if (_manifest != null)
                      TitleBarButton(
                        icon: Icons.help_outline,
                        tooltip: '${tr('About {name}', {
                              'name': _manifest!.displayName,
                            })}  F1',
                        onPressed: () => unawaited(_showAbout()),
                      ),
                  ],
                ),
                Expanded(
                  child: WindowLayer(
                    stack: _desk,
                    child: Scaffold(
                      backgroundColor: Colors.transparent,
                      body: switch (_attachment.content) {
                        null => Center(
                            child: Text(
                              _attachment.isLoading
                                  ? tr('Loading…')
                                  : tr('Nothing to show yet.'),
                              style: TextStyle(
                                color: theme.panelForeground
                                    .withValues(alpha: 0.6),
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        final content => PluginContentView(
                            content: content,
                            fullScreen: true,
                            structure: _attachment.structure,
                            pluginId: _attachment.pluginId,
                            cursor: _attachment.cursorFor,
                            focusedPart: _attachment.focusedPart,
                            onFocusPart: _attachment.focusPart,
                            onActivateRow: _attachment.isInteractive
                                ? (row, part) => unawaited(
                                    _attachment.activate(row, part: part))
                                : null,
                            onMarkRow: _attachment.isInteractive
                                ? (row, part, at) => unawaited(showViewRowMenu(
                                      context: context,
                                      attachment: _attachment,
                                      row: row,
                                      part: part,
                                      at: at,
                                    ))
                                : null,
                            onButton: _attachment.isInteractive
                                ? (id, values) => unawaited(
                                    _attachment.press(id, values: values))
                                : null,
                            onDropRows: _attachment.isInteractive
                                ? (from, to, rows) => unawaited(
                                    _attachment.dropRows(from, to, rows))
                                : null,
                          ),
                      },
                    ),
                  ),
                ),
                if (_attachment.status != null)
                  Material(
                    type: MaterialType.transparency,
                    child: Container(
                      height: theme.chromeRowHeight,
                      width: double.infinity,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        border:
                            Border(top: BorderSide(color: theme.chromeRule)),
                      ),
                      child: Text(
                        _attachment.status!,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
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
}
