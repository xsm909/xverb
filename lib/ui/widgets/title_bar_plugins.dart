import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_registry.dart';
import '../../state/app_state.dart';
import '../plugins/plugin_command_page.dart';
import '../plugins/plugin_icons.dart';
import '../plugins/view_launcher.dart';
import 'context_menu.dart';
import 'title_bar.dart';
import 'x_button.dart';

/// Buttons plugins put in the application's title bar.
///
/// A plugin has to ask for this — `inTitleBar` on a command, or `titleBar`
/// among a view's surfaces. The title bar is small and shared, and a row that
/// filled itself with everything any plugin happened to contribute would be
/// worse than useless.
///
/// Past [maxVisible] the rest move behind a `…` button rather than squeezing:
/// icons that shrink to fit stop being recognisable, which is the only thing an
/// icon is for.
class TitleBarPluginItems extends StatefulWidget {
  const TitleBarPluginItems({
    super.key,
    required this.foreground,
    this.menuKeys,
  });

  final Color foreground;

  /// The F10 selector, whose ring runs from the menu titles along to these.
  /// Null where the bar is drawn without one — a dialog's own chrome.
  final TitleBarMenus? menuKeys;

  /// How many buttons the bar will show before folding the rest away.
  static const int maxVisible = 3;

  @override
  State<TitleBarPluginItems> createState() => _TitleBarPluginItemsState();
}

class _TitleBarPluginItemsState extends State<TitleBarPluginItems> {
  /// The `…` button, so the keyboard can drop its menu under it the way a click
  /// does.
  final GlobalKey _foldedKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    // Nullable on purpose. The title bar is drawn in places that have no
    // plugin registry above them — a dialog pumped on its own in a test, and
    // anything that reuses the bar for its own chrome. Demanding a provider
    // here would make the bar refuse to build rather than simply have nothing
    // to add.
    final plugins = context.watch<PluginRegistry?>();
    final offers = plugins?.titleBarOffers ?? const [];
    final keys = widget.menuKeys;
    if (offers.isEmpty) {
      // Said out loud, or the selector's ring would keep the length it had
      // when a plugin was last loaded.
      keys?.registerTools(0, (_) {});
      return const SizedBox.shrink();
    }

    final visible = offers.take(TitleBarPluginItems.maxVisible).toList();
    final folded = offers.skip(TitleBarPluginItems.maxVisible).toList();

    keys?.registerTools(visible.length + (folded.isEmpty ? 0 : 1), (index) {
      if (index < visible.length) {
        unawaited(_run(context, visible[index]));
      } else {
        unawaited(_showFolded(_foldedKey.currentContext ?? context, folded));
      }
    });

    Widget row(BuildContext context) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < visible.length; i++)
          XButton(
            icon: pluginIcon(visible[i].icon),
            image: plugins?.iconFileFor(visible[i].pluginId, visible[i].icon),
            tooltip: visible[i].title,
            shape: XButtonShape.bare,
            height: 22,
            // The bar's ink, which is what everything else on the bar is
            // written in. It was handed to this widget from the start and
            // never passed on, so a plugin's icon was drawn in the *panel's*
            // ink: on a light palette that is a near-black glyph on a slate
            // bar, and the only tool anybody could pick out was the one
            // shipping a picture of its own.
            ink: widget.foreground,
            selected: keys?.isToolSelected(i) ?? false,
            onPressed: () => _run(context, visible[i]),
          ),
        if (folded.isNotEmpty)
          XButton(
            key: _foldedKey,
            icon: Icons.more_horiz,
            tooltip: tr('More plugin actions'),
            shape: XButtonShape.bare,
            height: 22,
            ink: widget.foreground,
            selected: keys?.isToolSelected(visible.length) ?? false,
            onPressed: () =>
                _showFolded(_foldedKey.currentContext ?? context, folded),
          ),
      ],
    );

    // The selector is somebody else's state; the icons redraw when it moves.
    if (keys == null) return row(context);
    return ListenableBuilder(
      listenable: keys,
      builder: (context, _) => row(context),
    );
  }

  Future<void> _showFolded(
    BuildContext context,
    List<PluginOffer> folded,
  ) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final origin = box.localToGlobal(Offset(0, box.size.height));

    await showAppContextMenu(
      context: context,
      globalPosition: origin,
      nodes: [
        for (final offer in folded)
          MenuItem(
            offer.title,
            icon: pluginIcon(offer.icon),
            onSelected: () => _run(context, offer),
          ),
      ],
    );
  }

  Future<void> _run(BuildContext context, PluginOffer offer) async {
    final command = offer.command;
    if (command != null) return runPluginCommand(context, command);

    // Views need the panels, and the title bar is drawn on pages that have no
    // application state above them. Nothing happens there rather than
    // something wrong: the same view is in the Tools menu of the main window.
    final app = context.read<AppState?>();
    final view = offer.view;
    if (app == null || view == null) return;

    await ViewLauncher(app).open(context, view);
  }
}
