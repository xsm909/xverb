import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/plugins/view.dart';
import '../../core/settings/appearance_settings.dart';
import '../../state/panel_attachment.dart';
import '../widgets/trail_bar.dart';
import 'plugin_icons.dart';
import '../widgets/context_menu.dart'
    show MenuGroup, MenuItem, MenuNode, MenuSeparator, showAppContextMenu;
import '../widgets/hint.dart';

/// A command drawn as words rather than as a glyph, with whatever it offers
/// dropping out underneath it.
///
/// The panel's own drive button in the tool's bar: **it says where you are and
/// opens the way to somewhere else.** A list down the side of the window says
/// the same thing and spends a fifth of the window saying it, which is a poor
/// trade in a tool whose whole point is the log.
class ViewPill extends StatefulWidget {
  const ViewPill({
    super.key,
    required this.command,
    required this.theme,
    required this.onPressed,
  });

  final ViewCommand command;
  final AppearanceSettings theme;
  final ValueChanged<String> onPressed;

  @override
  State<ViewPill> createState() => _ViewPillState();
}

class _ViewPillState extends State<ViewPill> {
  bool _hovered = false;
  bool _open = false;

  Future<void> _press() async {
    final command = widget.command;
    if (command.items.isEmpty) {
      widget.onPressed(command.id);
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    setState(() => _open = true);
    await showAppContextMenu(
      context: context,
      // Anchored to the pill rather than to the pointer, exactly as the path
      // bar's is: the same menu appears in the same place however it was asked
      // for.
      anchorRect: box.localToGlobal(Offset.zero) & box.size,
      searchHint: command.tooltip ?? command.label,
      nodes: viewMenuNodes(command.items, widget.onPressed),
    );
    if (mounted) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;

    final Color background;
    final Color foreground;
    if (_open) {
      background = theme.accentColor.withValues(alpha: 0.85);
      foreground = theme.accentColor.computeLuminance() > 0.5
          ? Colors.black
          : Colors.white;
    } else if (_hovered) {
      background = theme.accentColor.withValues(alpha: 0.28);
      foreground = theme.headerForeground;
    } else {
      background = theme.panelForeground.withValues(alpha: 0.07);
      foreground = theme.headerForeground;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_press()),
        child: Hint(
          message: widget.command.tooltip ?? '',
          wait: const Duration(milliseconds: 700),
          child: Container(
            height: theme.chromeRowHeight,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: EdgeInsets.only(
              left: 9,
              right: widget.command.items.isEmpty ? 9 : 2,
            ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: _open || _hovered
                    ? theme.accentColor
                    : theme.headerForeground.withValues(alpha: 0.12),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.command.label,
                  style: TextStyle(
                    color: foreground,
                    fontSize: theme.fontSize - 1,
                    fontWeight: theme.uiWeightFor(FontWeight.w500),
                    decoration: TextDecoration.none,
                  ),
                ),
                if (widget.command.items.isNotEmpty)
                  Icon(Icons.arrow_drop_down, size: 16, color: foreground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A view's menu rows as the application's own, wherever they are shown.
List<MenuNode> viewMenuNodes(
  List<ViewMenuItem> items,
  ValueChanged<String> onPressed,
) =>
    [
      for (final item in items)
        if (item.isSeparator)
          MenuSeparator(item.label.isEmpty ? null : item.label)
        else if (item.items.isNotEmpty)
          MenuGroup(item.label, viewMenuNodes(item.items, onPressed),
              enabled: item.enabled)
        else
          MenuItem(
            item.label,
            shortcut: item.shortcut,
            enabled: item.enabled,
            checked: item.checked,
            onSelected: () => onPressed(item.id ?? ''),
          ),
    ];


/// What a view puts where a panel keeps its path: its pills, and then its own
/// name or the levels it has walked into.
///
/// **The pill goes first and the path gives way to it.** A tool standing in a
/// repository was saying the same thing twice — a trail reading `repo / main`
/// beside a pill reading `main` — and two things saying it means one of them
/// is not being read. A view with no pills is exactly what it was before.
///
/// One widget for both surfaces on purpose. A panel and a full-screen page
/// disagreeing about where a tool says where it is would be two tools.
/// Everything a view puts in a panel's chrome row stands on the **header's**
/// fill — the pills, the trail, the title, the view's own icons — so it is
/// written in the header's ink. It used to take the *panel's*, which on a light
/// palette is a near-black glyph on a slate strip — first seen on the git
/// tool's icons and its branch pill, and it is the same mistake the title
/// bar's tools icons had.
class ViewChrome extends StatelessWidget {
  const ViewChrome({
    super.key,
    required this.attachment,
    required this.theme,
    this.titleStyle,
    this.withCommands = false,
  });

  final PanelAttachment attachment;
  final AppearanceSettings theme;

  /// How the view's own name is drawn where there is no trail. The two
  /// surfaces have always drawn it differently — the bar's type is a size
  /// smaller than the panel's — and that difference is theirs to keep.
  final TextStyle? titleStyle;

  /// Whether the view's commands with an icon are drawn here too.
  ///
  /// **True in a panel, false full screen**, and the difference is where else
  /// they could go: full screen they stand in the title bar, beside the tools,
  /// and drawing them twice would be drawing them twice. A panel has no such
  /// bar, so before this they were simply not drawn at all — a tool in a panel
  /// could offer nothing but its pills, which is how a fetch button nobody
  /// could find came to be shipped.
  final bool withCommands;

  @override
  Widget build(BuildContext context) {
    final pills = [
      for (final command in attachment.commands)
        if (command.isPill)
          ViewPill(
            command: command,
            theme: theme,
            onPressed: (id) => unawaited(attachment.press(id)),
          ),
    ];

    final rest = attachment.trail.isEmpty
        ? Text(
            attachment.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle ??
                TextStyle(
                  color: theme.headerForeground,
                  fontSize: theme.fontSize,
                ),
          )
        : TrailBar(
            steps: attachment.trail,
            onGo: (index) => unawaited(attachment.step(index)),
          );

    final buttons = [
      if (withCommands)
        for (final command in attachment.commands)
          if (!command.isPill)
            Hint(
              message: command.tooltip ?? command.label,
              child: IconButton(
                icon: Icon(pluginIcon(command.icon), size: 15),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 24, height: 22),
                color: theme.headerForeground.withValues(alpha: 0.75),
                onPressed: () => unawaited(attachment.press(command.id)),
              ),
            ),
    ];

    if (pills.isEmpty && buttons.isEmpty) return rest;
    return Row(
      children: [
        ...pills,
        if (pills.isNotEmpty) const SizedBox(width: 4),
        Expanded(child: rest),
        ...buttons,
      ],
    );
  }
}
