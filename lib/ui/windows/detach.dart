import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/plugins/viewer.dart';
import '../../core/vfs/file_entry.dart';
import '../../state/panel_attachment.dart';
import '../../state/panel_controller.dart';
import '../../state/program_windows.dart';
import '../viewer/plugin_viewer_page.dart';
import 'detached_view_page.dart';

/// **Taking what is on the screen into a window of its own.**
///
/// Four things can be detached and they are all the same gesture: the view a
/// panel is showing, a quick view of a file, a plugin's view filling the
/// window, and a file being read. Afterwards the window is on its own — what
/// it holds is no longer followed by anything, no longer navigated by
/// anything, and nothing in the commander can take it back. **There is no
/// merging back**, by design, and there is deliberately no gesture that
/// pretends there is.
///
/// Whether any of it is possible is [ProgramWindows.canDetach] — a machine
/// whose runner cannot take the platform's bar off a new window would show a
/// button that lies.
const SingleActivator detachKey = SingleActivator(
  LogicalKeyboardKey.keyD,
  control: true,
  shift: true,
);

/// The same chord written for the Mac's own hand as well, where Control is
/// not the key a window command is reached by.
const SingleActivator detachKeyMeta = SingleActivator(
  LogicalKeyboardKey.keyD,
  meta: true,
  shift: true,
);

bool isDetachKey(KeyEvent event) =>
    detachKey.accepts(event, HardwareKeyboard.instance) ||
    detachKeyMeta.accepts(event, HardwareKeyboard.instance);

/// Whether anything can be detached on this machine at all.
bool get canDetach => ProgramWindows.canDetach;

/// **Takes what [panel] is showing into a window of its own**, and gives the
/// panel back its listing.
///
/// The attachment is handed over, not restarted: a quick view keeps the file
/// it had read and a plugin view keeps everything it had built. The panel is
/// where it always was underneath — detaching navigates nothing.
void detachFromPanel(BuildContext context, PanelController panel) {
  if (!canDetach) return;
  final windows = context.read<ProgramWindows>();
  final attachment = panel.attachment;
  if (attachment == null) return;

  // One view is one thing wherever it is. A plugin view already in a window
  // cannot be detached twice, because the second window would start a second
  // session the plugin would answer for both.
  final holding = _holdingName(attachment);
  if (holding != null && windows.holds(holding)) {
    windows.raiseIfHolding(holding);
    return;
  }

  final handed = panel.handOver();
  if (handed == null) return;
  _openWindowFor(context, windows, handed, holding: holding);
}

/// The same, for a view that is filling the first window: the page hands over
/// its attachment and is popped by the caller.
///
/// The page's own claim on being the only copy of that view is carried into
/// the window, which is why the launcher must not release it — see
/// `view_launcher.dart`.
void detachFromPage(
  BuildContext context,
  PanelAttachment attachment, {
  VoidCallback? alsoOnGone,
}) {
  if (!canDetach) return;
  final windows = context.read<ProgramWindows>();
  _openWindowFor(
    context,
    windows,
    attachment,
    holding: _holdingName(attachment),
    alsoOnGone: alsoOnGone,
  );
}

void _openWindowFor(
  BuildContext context,
  ProgramWindows windows,
  PanelAttachment attachment, {
  String? holding,
  VoidCallback? alsoOnGone,
}) {
  final made = windows.open(
    title: attachment.title,
    holding: holding,
    content: (context) => DetachedViewPage(attachment: attachment),
    // **The window owns it from here, release included.** Nothing is let go
    // of while the window may still be drawing it — [ProgramWindows.closed]
    // waits a turn for exactly that reason.
    onGone: () {
      unawaited(attachment.release());
      attachment.dispose();
      alsoOnGone?.call();
    },
  );
  if (made == null) {
    // The window could not be made, so nothing may be left holding an
    // attachment nobody draws.
    unawaited(attachment.release());
    attachment.dispose();
    alsoOnGone?.call();
  }
}

/// **Takes a file being read into a window of its own.**
///
/// A reading cannot be handed over the way an attachment can: its state —
/// where you are in the file, which viewer, the structure beside it — lives
/// in the page's own widget state, and widget state does not cross from one
/// view to another. So the reading is opened again in the new window, where
/// it comes up on the page it was left at: the reading remembers where you
/// stopped by itself (see `DocumentMemory`), and that memory is the
/// application's, not the window's.
void detachReading(
  BuildContext context, {
  required FileEntry entry,
  required List<RegisteredViewer> viewers,
  int initialIndex = 0,
  List<FileEntry> siblings = const [],
}) {
  if (!canDetach) return;
  final windows = context.read<ProgramWindows>();
  final holding = 'reading:${entry.path.uri}';
  if (windows.holds(holding)) {
    windows.raiseIfHolding(holding);
    return;
  }
  windows.open(
    title: entry.name,
    holding: holding,
    content: (context) => PluginViewerPage(
      entry: entry,
      viewers: viewers,
      initialIndex: initialIndex,
      siblings: siblings,
    ),
  );
}

/// What a detached thing is known by, so that a second copy of it is refused
/// and the window that has it is brought forward instead. A quick view is
/// nobody's session and needs no name: two readings of two files in two
/// windows is a reasonable thing to want.
String? _holdingName(PanelAttachment attachment) =>
    attachment is PluginViewAttachment ? 'view:${attachment.view.id}' : null;

/// The name the page claim uses for a view, so the two agree.
String viewHoldingName(String viewId) => 'view:$viewId';

/// Brings the window holding a view forward, and answers whether there was
/// one. Used where a second copy would otherwise be made.
bool raiseDetachedView(BuildContext context, String viewId) {
  final windows = context.read<ProgramWindows?>();
  if (windows == null) return false;
  return windows.raiseIfHolding(viewHoldingName(viewId));
}

/// Whether the application knows about a detached copy of this view.
bool hasDetachedView(BuildContext context, String viewId) =>
    context.read<ProgramWindows?>()?.holds(viewHoldingName(viewId)) ?? false;
