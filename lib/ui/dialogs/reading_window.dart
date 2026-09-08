import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../state/panel_controller.dart';
import '../../state/window_stack.dart';
import '../windows/window_dialogs.dart';

/// How long a panel may be reading before it says so out loud.
///
/// **A pause and not an animation**, so it lives here rather than in
/// `motion.dart` and does not answer to the speed setting — the same argument
/// the floating remark's own life is written down under. What it buys is that
/// the folders read in a moment, which is nearly all of them, never put a
/// window on screen at all: long enough to cover a local directory, short
/// enough that an archive says what it is doing before the eye has time to
/// call the wait a fault.
const Duration kReadingWait = Duration(milliseconds: 350);

/// Says which panel is reading what, once the reading has taken long enough to
/// be worth a word.
///
/// **Because a panel that has been asked to open something is not there yet.**
/// `PanelController.navigateTo` says where it is going before it reads
/// anything, and the reading is not always quick: an archive is unpacked far
/// enough to list it by a plugin in another process, and a folder the system
/// guards is not read until the user has answered a question about it. Until
/// then the panel is standing where it always was, and with nothing on screen
/// to say so the wait reads as the application having gone wrong.
///
/// One watch over both panels rather than a call at each place that navigates:
/// a panel is sent somewhere by Enter, by the location bar, by a plugin's view,
/// by the drive menu, by a command typed into the console. All of them go
/// through the same field, and this listens to that.
class ReadingWatch {
  ReadingWatch({required this.windows, required this.panels});

  final WindowStack windows;

  /// Both of them, in the order their windows are told apart by.
  final List<PanelController> panels;

  final Map<PanelController, VoidCallback> _listeners = {};
  final Map<PanelController, Timer> _waits = {};
  final Map<PanelController, DeskWindow> _shown = {};

  void start() {
    for (final panel in panels) {
      void listener() => _look(panel);
      _listeners[panel] = listener;
      panel.addListener(listener);
    }
  }

  void stop() {
    for (final entry in _listeners.entries) {
      entry.key.removeListener(entry.value);
    }
    _listeners.clear();
    for (final wait in _waits.values) {
      wait.cancel();
    }
    _waits.clear();
    for (final window in _shown.values) {
      windows.close(window);
    }
    _shown.clear();
  }

  /// One panel has said something about itself. The only question here is
  /// whether it is still reading.
  void _look(PanelController panel) {
    if (panel.isLoading) {
      // Already counting, or already saying so. A panel notifies about a dozen
      // things while it works, and none of them restarts the pause.
      if (_waits.containsKey(panel) || _shown.containsKey(panel)) return;
      _waits[panel] = Timer(kReadingWait, () {
        _waits.remove(panel);
        if (panel.isLoading) _show(panel);
      });
      return;
    }

    _waits.remove(panel)?.cancel();
    final window = _shown.remove(panel);
    // The listing is in. Whether it came or failed, the panel has something to
    // say for itself now and this has nothing left to add.
    if (window != null) windows.close(window);
  }

  void _show(PanelController panel) {
    final at = panel.location;
    final archive = at?.archiveHost;
    final window = DeskWindow(
      // One per panel, so both sides can be reading at once and neither takes
      // the other's window away.
      id: 'reading-${panels.indexOf(panel)}',
      title: archive != null ? tr('Reading archive') : tr('Reading folder'),
      icon: archive != null ? Icons.folder_zip_outlined : Icons.folder_open,
      modal: true,
      resizable: false,
      preferredSize: const Size(460, 190),
      minSize: const Size(320, 170),
      builder: (_) => WindowForm(
        child: _ReadingBody(what: archive?.name ?? at?.name ?? ''),
      ),
    );
    _shown[panel] = window;
    // Escape and the close button put the window away, which is all they can
    // honestly do: reading a folder is one question to a file system and there
    // is no half of it to stop. The panel goes on waiting, and arrives when
    // the answer does.
    unawaited(windows.open(window));
  }
}

class _ReadingBody extends StatelessWidget {
  const _ReadingBody({required this.what});

  /// The archive's own name, or the folder's — what is being read, rather than
  /// the path it will be listed under.
  final String what;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          what,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 16),
        const LinearProgressIndicator(),
        const SizedBox(height: 14),
        // Which is the whole point of the window: the panel has not moved, and
        // that it has not moved is not a fault.
        Text(
          tr('The panel goes there when this has been read.'),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
