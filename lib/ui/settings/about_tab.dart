import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../core/version.dart';
import '../text_scale.dart';
import 'update_check_row.dart';

/// Key bindings and project information.
class AboutTab extends StatelessWidget {
  const AboutTab({super.key});

  /// The two rows that depend on which key opens quick search — see
  /// [QuickSearchOpener]. They are worth building rather than writing down
  /// because with **Typing** chosen the other row changes too: a letter is no
  /// longer the command line's, and a table that says it is would send whoever
  /// read it to a key that does something else.
  static List<(String, String)> _searchBindings(QuickSearchOpener opener) =>
      switch (opener) {
        QuickSearchOpener.altS => const [
          ('Type anything', 'Goes to the command line'),
          ('Alt+S', 'Quick search; ↑↓ steps through matches'),
        ],
        QuickSearchOpener.ctrlAltLetter => const [
          ('Type anything', 'Goes to the command line'),
          ('Ctrl+Alt+letter', 'Quick search; ↑↓ steps through matches'),
        ],
        QuickSearchOpener.typing => const [
          ('Type anything', 'Quick search; ↑↓ steps through matches'),
          ('Ctrl+↓', 'Into the command line, where typing is typing again'),
        ],
      };

  static List<(String, String)> _bindings(QuickSearchOpener opener) => [
    ('Tab', 'Switch panel'),
    ('Enter', 'Enter a directory, or open a file with its default app'),
    ('Backspace', 'Delete the last character typed'),
    ('Double click', 'The same as Enter on that row; one click only moves to it'),
    ('Ctrl+↑', 'Go to parent directory'),
    ('Ctrl+↓', 'Enter the folder under the cursor'),
    ('Ctrl+← / Ctrl+→', 'Show that folder in the left / right panel'),
    ('Insert', 'Mark entry and step down'),
    ('Space', 'Mark, and measure the folder under the cursor'),
    ('Alt+Shift+Enter', 'Measure every folder'),
    ('Numpad *', 'Invert marks'),
    ('Ctrl+A', 'Mark everything'),
    // Esc unwinds one thing at a time, so it is listed as the chain it is —
    // it is the way back out of anything, and that is worth knowing in full.
    (
      'Esc',
      'Back out of one thing: quick search, the command line, a running '
          'command, the console, a view, a panel that cannot list, then marks',
    ),
    ('Left / Right', 'Jump to the first or last entry'),
    ('F2', 'Rename'),
    ('F3', 'View with the best matching plugin'),
    ('Shift+F3', 'View with a chosen plugin'),
    ('F4', 'Edit in the machine\'s own text editor'),
    ('F5', 'Copy to the other panel'),
    ('Shift+F5', 'Copy under another name, here by default'),
    ('F6', 'Move to the other panel'),
    ('Shift+F6', 'Rename one, move several'),
    ('F7', 'Create folder'),
    ('F8 / Delete', 'Delete to the recycle bin'),
    ('Shift+Delete', 'Delete permanently'),
    ('F9', 'Settings'),
    ('Ctrl+F3', 'Sort by name (again to reverse)'),
    ('Ctrl+F4', 'Sort by extension'),
    ('Ctrl+F5', 'Sort by date'),
    ('Ctrl+F6', 'Sort by size'),
    ('Alt+F1 / Alt+F2', 'Drives and connections for the left / right panel'),
    ('Alt+F5', 'Pack into a new archive in the other panel'),
    ('Alt+F9', 'Unpack the archive under the cursor, into this folder'),
    (
      'Alt+F M C O V T W H',
      'Open a menu: File, Mark, Commands, Console, View, Tools, Window, Help',
    ),
    ('F10', 'Into the menu bar; ←→ walks it, ↓ opens, Esc leaves'),
    ('Ctrl+H', 'Toggle hidden files'),
    ('Ctrl+R', 'Refresh'),
    ('Ctrl+U', 'Swap panels'),
    ..._searchBindings(opener),
    ('Ctrl+O', 'Show or hide the console output'),
    ('Ctrl+Shift+O', "Open the machine's own terminal in this folder"),
    ('Ctrl+E / Ctrl+Shift+E', 'Previous / next command from history'),
    ('Ctrl+V / Shift+Insert', 'Paste into the command line'),
    ('Ctrl+Backspace', 'Delete a word from the command line'),
    ('Right-click', 'Context menu, with search over every command'),
    (
      'Menu / Shift+F10',
      "The desktop's own menu for the row under the cursor",
    ),
    ('Hold right-click', "The same, from the pointer"),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(kAppTitle, style: Theme.of(context).textTheme.headlineSmall),
        Text(
          tr('Version {version}', {'version': kAppVersion}),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const UpdateCheckRow(),
        const SizedBox(height: 8),
        Text(
          tr('A dual-pane file manager built on Flutter. The core does file management and nothing else — transports, viewers and every other feature arrive as Python plugins.'),
        ),
        const SizedBox(height: 8),
        Text(
          tr('Plugin API version {version}', {'version': kPluginApiVersion}),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        SelectableText(tr('https://github.com/xsm909/xverb')),
        const SizedBox(height: 12),
        // The GPL asks an interactive program to say this itself, and it is the
        // right place for it anyway: whoever wants to know what they may do with
        // a copy looks in About, not in the repository.
        Text(
          'Copyright (C) 2026 xsm909',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          tr('Free software under the GNU General Public License, version 3 or later. It comes with absolutely no warranty. The full licence is in the LICENSE file beside the program.'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        SelectableText(
          'https://www.gnu.org/licenses/gpl-3.0.html',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 32),
        Text(
          tr('KEY BINDINGS'),
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(
                letterSpacing: 1.1,
                fontWeight: context.uiWeight(FontWeight.w700),
              ),
        ),
        const SizedBox(height: 8),
        for (final (keys, description) in _bindings(
          context.watch<SettingsStore>().appearance.quickSearchOpener,
        ))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 150,
                  child: Text(
                    tr(keys),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: context.uiWeight(FontWeight.w600),
                    ),
                  ),
                ),
                Expanded(child: Text(tr(description))),
              ],
            ),
          ),
      ],
    );
  }
}
