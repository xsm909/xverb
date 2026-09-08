import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_store.dart';
import '../../state/panel_attachment.dart';
import '../widgets/context_menu.dart'
    show menuAppearanceFrom, showAppContextMenu;
import 'view_pill.dart' show viewMenuNodes;

/// The secondary press on a row of a view, and whatever the view says about it.
///
/// **A gesture that does something in private is a gesture nobody can use.**
/// The press has always reached the plugin; what came back was an action, so
/// right-clicking a commit sent the other panel somewhere with no word about
/// it, and the identical press two rows lower — in the working tree — staged a
/// file instead. Same button, same table, two meanings, neither written down.
///
/// A view may now answer the press with a list of items, which are drawn where
/// the press landed and read like every other menu in the application; picking
/// one raises the ordinary `button` event. A view that answers with none is
/// unchanged, which is what keeps the disk map's "mark this for deletion"
/// working.
Future<void> showViewRowMenu({
  required BuildContext context,
  required PanelAttachment attachment,
  required int row,
  required String part,
  required Offset? at,
}) async {
  final style = menuAppearanceFrom(context.read<SettingsStore>().appearance);

  // The round trip happens either way: the press is the view's to interpret,
  // and a view that acts on it rather than answering with a menu still has to
  // hear about it.
  final items = await attachment.mark(row, part: part);
  if (items.isEmpty || at == null || !context.mounted) return;

  await showAppContextMenu(
    context: context,
    globalPosition: at,
    style: style,
    // Choosing a row acts on what was picked out, so it uses it up — the same
    // rule pressing Enter follows. Leaving the marks behind would leave them
    // on rows that are no longer the same files: the list has just changed
    // *because* of them.
    nodes: viewMenuNodes(items, (id) {
      unawaited(attachment.press(id));
      attachment.cursorFor(part).clearMarks();
    }),
  );
}
