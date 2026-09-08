import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/vfs/archive_actions.dart';
import '../../core/vfs/file_entry.dart';
import '../../state/app_state.dart';
import '../widgets/context_menu.dart';

/// The menu about a file, and about the folder that file is in.
///
/// **One definition, two surfaces.** The right button opens it over a row, and
/// the File drop-down on the title bar opens the same commands over whatever
/// the cursor is standing on. Written twice they would drift: a command added
/// to one, a shortcut renamed in the other, and the same menu would answer two
/// different ways depending on how it was asked for.
///
/// It lives here rather than in the commander screen because that file is the
/// window — the keys, the panels, the console, the drag session — and a menu is
/// a list of things that can be done to a file, which needs none of that. What
/// it does need is a way to *run* them, and that arrives as [FileMenuActions]:
/// the screen owns the dialogs, the progress and the notices, so the menu names
/// a command and the screen performs it.

/// What the rows can ask for. Every one of them is the screen's own method,
/// handed over rather than reached for.
///
/// Deliberately a bag of callbacks and not a reference to the screen's state:
/// a menu that could see the screen would grow to use it, and the next command
/// would arrive as a field on the widget rather than as a line here.
@immutable
class FileMenuActions {
  const FileMenuActions({
    required this.openWithShell,
    required this.view,
    required this.edit,
    required this.rename,
    required this.copyPath,
    required this.copyToClipboard,
    required this.pasteHere,
    required this.transfer,
    required this.pack,
    required this.extract,
    required this.delete,
    required this.createDirectory,
    required this.refresh,
  });

  /// Hands the file to the desktop, the way Enter does.
  final void Function(FileEntry entry) openWithShell;

  /// F3: whichever viewer claims the file.
  ///
  /// **Not which one.** Choosing among them was a group in this menu and is
  /// gone from it: it is Shift+F3, where a second key on the same finger is
  /// the natural place for "the same thing, but let me pick". A menu row per
  /// installed viewer is a list about the plugins rather than about the file
  /// that was clicked.
  final void Function(FileEntry entry) view;

  /// F4.
  final void Function(FileEntry entry) edit;

  /// F2.
  final VoidCallback rename;

  /// The path as the path bar writes it, to the desktop's clipboard.
  final void Function(FileEntry entry) copyPath;

  /// Ctrl+C and Ctrl+X: the desktop's clipboard, not the other panel.
  final void Function({required bool cut}) copyToClipboard;

  /// Ctrl+V, into the folder on screen.
  final VoidCallback pasteHere;

  /// F5 and F6.
  final void Function({required bool move}) transfer;

  /// "Pack into archive…": what is marked, or the row under the cursor, into a
  /// new archive **in this folder**. Alt+F5 is the same command aimed at the
  /// other panel, and the screen owns which is which.
  final VoidCallback pack;

  /// Alt+F9: an archive's contents out of it. [intoFolder] puts them in a new
  /// folder named after the archive instead of loose in the one on screen.
  final void Function(FileEntry entry, {required bool intoFolder}) extract;

  /// Del and Shift+Del.
  final void Function({required bool toTrash}) delete;

  /// F7.
  final VoidCallback createDirectory;

  /// Ctrl+R.
  final VoidCallback refresh;
}

/// The right-click menu: the row under the pointer, and the folder it is in.
///
/// **Nothing else, and that is the whole of the design.** It used to be the
/// Commands and View menus poured in after the entry's own commands, so a
/// right-click on a file offered sorting, row density, the window backdrop,
/// hidden files, the panel swap and a submenu of every drive and saved
/// connection — thirty-odd rows, most of them about the application rather than
/// about the file that was clicked. A menu that has to be read to be used is a
/// menu nobody reads.
///
/// None of those was lost with them: each lives on the title bar, in
/// Appearance, or on a key, and the drives are what the location pill drops —
/// which is where a drive is chosen from.
///
/// Everything shown comes from state already in hand. Opening a menu must never
/// wait on a provider.
Future<void> showFileContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required MenuAppearance style,
  required AppState app,
  required FileEntry? entry,
  required FileMenuActions actions,
}) => showAppContextMenu(
  context: context,
  globalPosition: globalPosition,
  style: style,
  nodes: [
    ...entryMenuNodes(app: app, entry: entry, actions: actions),
    ...folderMenuNodes(app: app, hasEntry: entry != null, actions: actions),
  ],
);

/// Commands that act on the entry under the pointer. Empty over blank space.
List<MenuNode> entryMenuNodes({
  required AppState app,
  required FileEntry? entry,
  required FileMenuActions actions,
}) {
  if (entry == null) return const [];

  // What the two sides allow, asked once. A commit, an archive, a server
  // mounted read-only: the row is still there to be read and copied out of, and
  // everything that would write to it is offered dead rather than offered and
  // then refused.
  final here = !app.active.isReadOnly;
  final there = !app.inactive.isReadOnly;
  final canTrash = here && app.operations.canTrash(app.active.actionTargets);

  // Whether this row is an archive, and whether a new one can be made at all.
  // Both are read off state already in hand — a manifest and the table of
  // running schemes — because a menu must never wait on a provider to know
  // what to show.
  final container = entry.isDirectory
      ? null
      : app.plugins.containerSchemeFor(entry.typeName);
  final unpackable =
      container != null && app.fileSystems.supports(container) && here;
  final packable = here && app.plugins.packFormats.isNotEmpty;

  return [
    MenuItem(
      entry.isDirectory ? tr('Open') : tr('Open with the default app'),
      icon: entry.isDirectory ? Icons.folder_open : Icons.open_in_new,
      shortcut: 'Enter',
      keywords: const ['launch', 'associate', 'default'],
      onSelected: () => entry.isDirectory
          ? unawaited(app.active.navigateTo(entry.path))
          : actions.openWithShell(entry),
    ),
    if (!entry.isDirectory)
      MenuItem(
        tr('View'),
        icon: Icons.visibility_outlined,
        shortcut: 'F3',
        keywords: const ['preview', 'plugin'],
        onSelected: () => actions.view(entry),
      ),
    if (!entry.isDirectory)
      MenuItem(
        tr('Edit'),
        icon: Icons.edit_outlined,
        shortcut: 'F4',
        keywords: const ['change', 'editor', 'text'],
        onSelected: () => actions.edit(entry),
      ),
    MenuItem(
      tr('Rename'),
      icon: Icons.drive_file_rename_outline,
      shortcut: 'F2',
      enabled: here,
      onSelected: actions.rename,
    ),
    // The path as the path bar writes it: a native `C:\…` for local files, and
    // for anything else the address it is actually browsed by, which is the
    // form that can be pasted back into the application.
    MenuItem(
      tr('Copy path'),
      icon: Icons.content_copy_outlined,
      shortcut: 'Ctrl+Shift+C',
      keywords: const ['clipboard', 'location', 'full'],
      onSelected: () => actions.copyPath(entry),
    ),
    const MenuSeparator(),
    // The desktop's clipboard, not the other panel's. These three are the way
    // files travel between this application and Explorer or Finder, and they
    // are named the way that desktop names them.
    MenuItem(
      tr('Copy'),
      icon: Icons.copy_outlined,
      shortcut: 'Ctrl+C',
      keywords: const ['clipboard'],
      onSelected: () => actions.copyToClipboard(cut: false),
    ),
    MenuItem(
      tr('Cut'),
      icon: Icons.content_cut,
      shortcut: 'Ctrl+X',
      keywords: const ['clipboard', 'move'],
      enabled: here,
      onSelected: () => actions.copyToClipboard(cut: true),
    ),
    MenuItem(
      tr('Paste'),
      icon: Icons.content_paste_outlined,
      shortcut: 'Ctrl+V',
      keywords: const ['clipboard', 'insert'],
      enabled: here,
      onSelected: actions.pasteHere,
    ),
    const MenuSeparator(),
    MenuItem(
      tr('Copy to other panel'),
      icon: Icons.copy_all_outlined,
      shortcut: 'F5',
      keywords: const ['duplicate'],
      enabled: there,
      onSelected: () => actions.transfer(move: false),
    ),
    MenuItem(
      tr('Move to other panel'),
      icon: Icons.drive_file_move_outline,
      shortcut: 'F6',
      // A move is a copy and then a delete, so it wants both sides: out of
      // history there is no moving, only bringing a copy forward.
      enabled: here && there,
      onSelected: () => actions.transfer(move: true),
    ),
    // Archives. Unpacking is offered only on a row something claims as one and
    // whose plugin is actually running: the alternative is a menu that says
    // "Extract here" over a `.7z` nobody can open, which is a promise the
    // application cannot keep. Packing is offered wherever anything at all can
    // write an archive, because what it is packed *into* is chosen by name in
    // the dialog rather than by what was clicked.
    if (unpackable || packable) const MenuSeparator(),
    if (unpackable)
      MenuItem(
        tr('Extract here'),
        icon: Icons.unarchive_outlined,
        shortcut: 'Alt+F9',
        keywords: const ['unpack', 'archive', 'zip', 'decompress'],
        onSelected: () => actions.extract(entry, intoFolder: false),
      ),
    if (unpackable)
      MenuItem(
        tr('Extract to {folder}', {'folder': unpackFolderName(entry)}),
        icon: Icons.drive_folder_upload_outlined,
        keywords: const ['unpack', 'archive', 'subfolder'],
        onSelected: () => actions.extract(entry, intoFolder: true),
      ),
    if (packable)
      // No shortcut on this row, and that is not an omission. Alt+F5 packs into
      // the *other* panel, the way every F-key in this application acts across;
      // this row is about the folder that was clicked, so it packs where the
      // files already are. A row advertising a key that lands somewhere else is
      // worse than a row with no key on it — Alt+F5 is in the keyboard list
      // under Help instead.
      MenuItem(
        tr('Pack into archive…'),
        icon: Icons.archive_outlined,
        keywords: const ['compress', 'zip', 'tar', 'archive', 'pack'],
        onSelected: actions.pack,
      ),
    if (unpackable || packable) const MenuSeparator(),
    MenuItem(
      canTrash ? tr('Delete to recycle bin') : tr('Delete'),
      icon: Icons.delete_outline,
      shortcut: 'Del',
      enabled: canTrash,
      keywords: const ['remove', 'trash', 'bin'],
      onSelected: () => actions.delete(toTrash: true),
    ),
    MenuItem(
      tr('Delete permanently'),
      icon: Icons.delete_forever_outlined,
      shortcut: 'Shift+Del',
      keywords: const ['remove', 'erase', 'destroy'],
      enabled: here,
      onSelected: () => actions.delete(toTrash: false),
    ),
    const MenuSeparator(),
  ];
}

/// What a right-click offers about the folder on screen rather than about a row
/// in it.
///
/// Paste is here only when there is no row under the pointer: the entry menu
/// carries its own beside Copy and Cut, and one menu with two Pastes in it is a
/// menu that has to be read twice.
List<MenuNode> folderMenuNodes({
  required AppState app,
  required bool hasEntry,
  required FileMenuActions actions,
}) {
  // Somewhere that cannot be written to — a commit, an archive, a server
  // mounted read-only — takes neither a new folder nor a paste.
  final here = !app.active.isReadOnly;
  return [
    MenuItem(
      tr('New folder'),
      icon: Icons.create_new_folder_outlined,
      shortcut: 'F7',
      keywords: const ['create', 'directory', 'mkdir'],
      enabled: here,
      onSelected: actions.createDirectory,
    ),
    if (!hasEntry)
      MenuItem(
        tr('Paste'),
        icon: Icons.content_paste_outlined,
        shortcut: 'Ctrl+V',
        keywords: const ['clipboard', 'insert'],
        enabled: here,
        onSelected: actions.pasteHere,
      ),
    MenuItem(
      tr('Refresh'),
      icon: Icons.refresh,
      shortcut: 'Ctrl+R',
      keywords: const ['reload', 'listing'],
      onSelected: actions.refresh,
    ),
  ];
}
