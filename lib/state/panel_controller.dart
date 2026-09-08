import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/settings/settings_store.dart';
import '../core/vfs/file_entry.dart';
import '../core/vfs/fs_provider.dart';
import '../core/vfs/fs_registry.dart';
import '../core/vfs/vfs_path.dart';
import 'panel_attachment.dart';

/// The way out of somewhere a tool sent a panel, and what to put back.
///
/// **A view that hands its panel over has gone.** A panel cannot be in a folder
/// and hold a tool at the same time, so the git tool sending its panel into a
/// commit closes the log — and until this there was nothing left on screen that
/// knew a log had ever been there. The only way out was to remember the path
/// and type it.
///
/// **Both panels, not one**, and that is the part that is easy to miss: while
/// reading history in one panel the other one gets moved — to compare a file
/// with how it is now, usually. Coming back has to put *that* panel back too,
/// or the tool opens beside a folder that is a different repository, or none at
/// all, and what comes back is not what you left.
class WayBack {
  const WayBack({
    required this.label,
    required this.viewId,
    required this.to,
    required this.into,
    this.beside,
  });

  /// What the way back is called — the view's own words. "Back to commits",
  /// because "Back" alone leaves the reader to remember what they were doing.
  final String label;

  /// The view to open again once the panels are back where they were.
  final String viewId;

  /// Where this panel stood when the view handed it over.
  final VfsPath to;

  /// Where it was sent. The way back lives as long as the panel is still in
  /// there: walk out of the excursion by any other road and there is nothing
  /// left to come back from.
  final VfsPath into;

  /// Where the panel *beside* it stood. Null when nothing was worth putting
  /// back — a panel with no location yet.
  final VfsPath? beside;
}

/// State of one file panel: where it is, what it shows, and what is marked.
class PanelController extends ChangeNotifier {
  PanelController({
    required this.registry,
    required this.settings,
    required this.isLeft,
  }) {
    settings.addListener(_onSettingsChanged);
  }

  final FileSystemRegistry registry;
  final SettingsStore settings;

  /// Which side of the window this panel is on, which is what says where it is
  /// saved and read back from.
  ///
  /// Not final, because Ctrl+U moves a panel to the other side rather than
  /// moving its path across — see [AppState.swapSides].
  bool isLeft;

  VfsPath? _location;
  List<FileEntry> _all = const [];
  List<FileEntry> _visible = const [];
  final Set<VfsPath> _marked = <VfsPath>{};
  int _cursor = 0;
  bool _loading = false;
  String? _error;
  String? _failure;

  /// Recursive sizes of directories the user asked about with Space, keyed by
  /// path. Cleared on navigation because the numbers go stale.
  final Map<VfsPath, int> _directorySizes = {};

  /// Directories currently being walked, so the row can say so.
  final Set<VfsPath> _sizing = <VfsPath>{};

  /// Set while something other than a listing fills the panel.
  PanelAttachment? _attachment;

  /// What is filling the panel instead of its listing, or null for a listing.
  PanelAttachment? get attachment => _attachment;

  bool get isAttached => _attachment != null;

  /// Set while the panel shows a result set instead of a directory listing.
  String? _virtualLabel;

  /// Where `..` goes back to when leaving a result set.
  VfsPath? _virtualOrigin;

  /// The way out of an excursion a view sent this panel on, or null.
  WayBack? _wayBack;

  /// See [WayBack]. Null unless a tool handed this panel over to a place and
  /// named the road back.
  WayBack? get wayBack => _wayBack;

  VfsPath? get location => _location;

  /// The provider serving where the panel stands, or null when nothing does —
  /// a panel with no location yet, or one whose plugin has been unloaded from
  /// under it.
  FileSystemProvider? get provider {
    final at = _location;
    if (at == null) return null;
    try {
      return registry.resolve(at);
    } on Object {
      return null;
    }
  }

  /// Whether this is somewhere that cannot be written to — a commit, an
  /// archive, a server mounted read-only.
  ///
  /// **The question is asked before the key is offered, not after it is
  /// pressed.** A panel standing in history that shows a live Delete is a
  /// panel lying about where it is; see [FileSystemProvider.isWritable].
  bool get isReadOnly => !(provider?.isWritable ?? true);

  /// What to draw beside the path to say what kind of place this is, named
  /// from the plugin icon table. Null for an ordinary disk.
  String? get badge => provider?.badge;

  /// Non-null while the panel is showing search results rather than a
  /// directory. The entries then come from all over the tree, so each row
  /// carries its own full path.
  String? get virtualLabel => _virtualLabel;

  bool get isVirtual => _virtualLabel != null;

  List<FileEntry> get entries => _visible;
  bool get isLoading => _loading;

  /// Set only while the panel has nothing to show at all, and the message has
  /// to be drawn where the listing would be.
  String? get error => _error;

  /// Why the last move did not happen, waiting to be said out loud once.
  ///
  /// Read it with [takeFailure]: the panel stayed where it was, so this is news
  /// about a keystroke rather than a state to be drawn, and reporting it twice
  /// for one keypress is worse than not at all.
  String? get failure => _failure;

  /// Returns the pending failure and forgets it.
  String? takeFailure() {
    final failure = _failure;
    _failure = null;
    return failure;
  }

  int get cursorIndex => _cursor;
  Set<VfsPath> get marked => _marked;

  FileEntry? get cursorEntry =>
      _cursor >= 0 && _cursor < _visible.length ? _visible[_cursor] : null;

  /// Number of real entries, excluding the `..` row.
  int get itemCount => _visible.where((e) => !e.isParentLink).length;

  int get markedCount => _marked.length;

  /// Known size of an entry: the file size, or the computed total for a
  /// directory the user has measured. Null when a directory is unmeasured.
  int? sizeOf(FileEntry entry) {
    if (entry.isParentLink) return null;
    if (!entry.isDirectory) return entry.size;
    return _directorySizes[entry.path];
  }

  bool isSizing(FileEntry entry) => _sizing.contains(entry.path);

  /// The directory totals measured in the folder being shown, copied out.
  ///
  /// For whoever has to go on drawing this listing after the panel has left it:
  /// walking somewhere else clears the measurements, and a folder fading out
  /// with its totals already gone would be the listing changing while it
  /// leaves. See the frozen listing in `file_panel.dart`.
  Map<VfsPath, int> get measuredSizes => Map.of(_directorySizes);

  int get markedBytes => _visible
      .where((e) => _marked.contains(e.path))
      .fold(0, (sum, e) => sum + (sizeOf(e) ?? 0));

  /// Total of everything listed, counting measured directories.
  int get totalBytes =>
      _visible.fold(0, (sum, e) => sum + (sizeOf(e) ?? 0));

  /// Walks a directory and records its total size, the way Space does in
  /// Total Commander. Runs in the background; the row updates when it lands.
  Future<void> computeDirectorySize(FileEntry entry) async {
    if (!entry.isDirectory || entry.isParentLink) return;
    if (_sizing.contains(entry.path)) return;

    _sizing.add(entry.path);
    notifyListeners();

    var total = 0;
    try {
      final provider = registry.resolve(entry.path);
      final pending = <VfsPath>[entry.path];
      while (pending.isNotEmpty) {
        final directory = pending.removeLast();
        for (final child in await provider.list(directory)) {
          if (child.isDirectory) {
            pending.add(child.path);
          } else {
            total += child.size;
          }
        }
      }
      _directorySizes[entry.path] = total;
    } on Object {
      // An unreadable subtree leaves the directory unmeasured rather than
      // reporting a number that is quietly wrong.
    } finally {
      _sizing.remove(entry.path);
      notifyListeners();
    }
  }

  /// Measures every marked directory at once — Total Commander's Alt+Shift+Enter.
  Future<void> computeMarkedSizes() async {
    final targets = _visible
        .where((e) => e.isDirectory && !e.isParentLink && _marked.contains(e.path))
        .toList();
    final all = targets.isEmpty
        ? _visible.where((e) => e.isDirectory && !e.isParentLink).toList()
        : targets;
    await Future.wait(all.map(computeDirectorySize));
  }

  /// What a command should act on: the marked entries, or the cursor row when
  /// nothing is marked. This is the orthodox-commander convention.
  List<VfsPath> get actionTargets {
    if (_marked.isNotEmpty) {
      return _visible
          .where((e) => _marked.contains(e.path))
          .map((e) => e.path)
          .toList();
    }
    final entry = cursorEntry;
    if (entry == null || entry.isParentLink) return const [];
    return [entry.path];
  }

  /// Writes down where this panel is standing, under the side it is on now.
  ///
  /// Ordinarily [navigateTo] does this as it moves. A panel that has changed
  /// sides without moving has nothing to save on its own, and would come back
  /// after a restart on the side it was on before Ctrl+U.
  Future<void> rememberWhereItIs() async {
    final at = _location;
    if (at == null) return;
    await settings.setPanelPath(isLeft, at.toString());
    // Under the side it is on *now*, the same as the location: a panel that
    // changed sides and kept the old side's row would come back standing on
    // whatever the other panel was looking at.
    rememberCursorNow();
  }

  Future<void> openInitialLocation() async {
    final saved = settings.panelPath(isLeft);
    if (saved != null) {
      final path = VfsPath.parse(saved);
      if (registry.supports(path.scheme)) {
        // And on the row it was left on. A name that is not there any more
        // finds nothing and the panel opens at the top, which is what it did
        // before this was remembered at all.
        await navigateTo(
          path,
          remember: false,
          cursorOn: settings.panelCursor(isLeft),
        );
        if (_error == null) return;
      }
    }
    final provider = registry.lookup(VfsPath.localScheme);
    if (provider == null) return;
    await navigateTo(await provider.defaultLocation());
  }

  /// Fills the panel with an arbitrary set of entries — Total Commander's
  /// "feed the search results to the listbox".
  ///
  /// The rows keep their own paths, so copying, viewing and deleting work on
  /// them exactly as they do in a normal listing. `..` leaves the result set
  /// and goes back to [origin].
  void showResults(
    List<FileEntry> entries, {
    required String label,
    VfsPath? origin,
  }) {
    _virtualLabel = label;
    _virtualOrigin = origin ?? _location;
    _all = List<FileEntry>.unmodifiable(entries);
    _marked.clear();
    _directorySizes.clear();
    _sizing.clear();
    _error = null;
    _loading = false;
    _rebuildVisible();
    _cursor = _visible.isEmpty ? 0 : (_visible.first.isParentLink ? 1 : 0);
    if (_cursor >= _visible.length) _cursor = _visible.length - 1;
    notifyListeners();
  }

  /// Hands the panel over to something that is not a listing — a quick view of
  /// the other panel's cursor, or a plugin's own view.
  ///
  /// The location is kept untouched underneath. Detaching puts the panel back
  /// exactly where it was, which is what makes this safe to do on a keystroke:
  /// nothing was navigated away from, so nothing has to be found again.
  Future<void> attach(PanelAttachment attachment) async {
    if (identical(attachment, _attachment)) return;
    await detach();

    _attachment = attachment..addListener(_onAttachmentChanged);
    notifyListeners();
  }

  /// Puts the listing back.
  Future<void> detach() async {
    final attachment = _attachment;
    if (attachment == null) return;

    _attachment = null;
    attachment.removeListener(_onAttachmentChanged);
    await attachment.release();
    attachment.dispose();
    notifyListeners();
  }

  void _onAttachmentChanged() => notifyListeners();

  /// Tells whatever is attached that the other panel moved.
  void followedPanelChanged({VfsPath? location, FileEntry? cursor}) =>
      _attachment?.follow(location: location, cursor: cursor);

  /// Writes down the way back out of where a view has just sent this panel.
  ///
  /// Set *after* the move, because moving is what clears it: the navigation
  /// that starts an excursion must not throw away the note about it.
  void rememberWayBack(WayBack back) {
    _wayBack = back;
    notifyListeners();
  }

  void forgetWayBack() {
    if (_wayBack == null) return;
    _wayBack = null;
    notifyListeners();
  }

  /// Leaves a result set, returning to the directory it was started from.
  Future<void> closeResults() async {
    if (!isVirtual) return;
    final origin = _virtualOrigin ?? _location;
    _virtualLabel = null;
    _virtualOrigin = null;
    if (origin != null) {
      await navigateTo(origin);
    } else {
      _all = const [];
      _rebuildVisible();
      notifyListeners();
    }
  }

  /// Moves the panel, and says whether it went.
  ///
  /// **The answer is a return value and not a field to read back afterwards.**
  /// [failure] is *consumed* by whoever says it out loud — the panel does that
  /// from a listener, so the `notifyListeners` in the `finally` below clears it
  /// synchronously, before this method has finished. Anything asking "did that
  /// work?" by looking at [failure] a line later is told yes. That is not a
  /// hypothetical: it is how a folder that could not be opened came to be
  /// written down as where its drive had been left, and how the drive then
  /// failed the same way every time it was chosen afterwards.
  Future<bool> navigateTo(
    VfsPath path, {
    bool remember = true,
    String? cursorOn,
  }) async {
    // Going somewhere puts the listing back. A panel cannot be in a folder and
    // handed over to something else at the same time, so a view that sends its
    // own panel to a location is asking to be replaced by what is there.
    if (_attachment != null) await detach();

    // Everything needed to put the panel back exactly as it is, should the move
    // not happen. `previous` is only the folder walked out of — a result set is
    // not one, so the cursor rule sees nothing to come back from.
    final priorLocation = _location;
    final priorLabel = _virtualLabel;
    final priorOrigin = _virtualOrigin;
    final previous = isVirtual ? null : priorLocation;

    _virtualLabel = null;
    _virtualOrigin = null;
    _location = path;
    _loading = true;
    _error = null;
    _failure = null;
    notifyListeners();

    var moved = true;
    try {
      final provider = registry.resolve(path);
      final listing = await provider.list(path);
      _all = listing;
      // What was marked, and what was measured, belonged to the folder being
      // left. Cleared here rather than before the listing, so a move that does
      // not happen does not cost the user their selection.
      _marked.clear();
      _directorySizes.clear();
      _sizing.clear();
      _rebuildVisible();

      // Where to leave the cursor: on the row asked for, or on the folder
      // walked out of, or at the top. Asking for one is how "show me *that*
      // file" is answered — the panel goes to where it lives and stands on it,
      // which is what anybody means by pointing at a file.
      final target = cursorOn ?? _rowComingBackFrom(path, previous);
      _cursor = target == null ? 0 : _indexOfName(target);
      _error = null;
    } on VfsException catch (e) {
      moved = false;
      _stayPut(e.message, path, priorLocation, priorLabel, priorOrigin);
    } on Object catch (e) {
      moved = false;
      _stayPut(e.toString(), path, priorLocation, priorLabel, priorOrigin);
    } finally {
      _loading = false;
      notifyListeners();
    }

    // Still inside the excursion — deeper into the commit's tree, say — and the
    // way back is still the way back. Anywhere else and it is stale: this panel
    // has left by another road, and a control offering to undo a journey it is
    // no longer on would put the user somewhere they never were.
    final back = _wayBack;
    if (back != null && moved && !back.into.contains(path)) {
      _wayBack = null;
    }

    if (remember && moved) {
      await settings.setPanelPath(isLeft, path.toString());

      // Where this volume was left, for the next change of drive. Only
      // locations of the volume's own kind: inside an archive the walk up leads
      // out to the drive holding it, and "go to C:" opening a zip file is not
      // what anybody meant by remembering.
      if (path.scheme == path.root.scheme) {
        await settings.setVolumePath(path.root.toString(), path.toString());
      }
    }
    return moved;
  }

  /// A move that did not happen changes nothing.
  ///
  /// The panel keeps the folder it was in, its listing, its cursor and its
  /// marks, and the reason goes to [failure] for the UI to say out loud. What it
  /// must not do is replace the listing with a screen carrying the message,
  /// because that screen is a dead end: its button cannot be reached from the
  /// keyboard, and there is nothing behind it to go back to. Pressing Enter on
  /// `C:\Documents and Settings` is how that was found.
  ///
  /// The one time the message has nowhere else to go is a panel that never had
  /// a listing — a saved location that has since gone, on the way up. Then the
  /// panel does have to carry it, and Ctrl+R retries.
  void _stayPut(
    String message,
    VfsPath attempted,
    VfsPath? priorLocation,
    String? priorLabel,
    VfsPath? priorOrigin,
  ) {
    _failure = message;

    if (priorLocation == null && priorLabel == null) {
      _all = const [];
      _visible = const [];
      _cursor = 0;
      _error = message;
      _location = attempted;
      return;
    }

    _error = null;
    _location = priorLocation;
    _virtualLabel = priorLabel;
    _virtualOrigin = priorOrigin;
    // The listing itself was never touched; this puts the `..` row back on the
    // folder we are still in.
    _rebuildVisible();
  }

  /// Which row the cursor takes after moving to [path] from [previous], or
  /// null to start at the top — on `..`, the way out.
  ///
  /// Entering a folder always starts there: the first row is the way back, so
  /// Enter walks down and Enter again walks straight out, and the cursor is
  /// somewhere the user can predict. Only walking *up* restores a position, and
  /// then the row is the folder just left — the child of [path] on the way down
  /// to [previous], which is still the right one when several levels were
  /// skipped at once from the path bar.
  ///
  /// Where the cursor sat on an *earlier* visit is deliberately not remembered.
  /// Doing so made entering a folder land on a row with nothing to do with the
  /// way in.
  String? _rowComingBackFrom(VfsPath path, VfsPath? previous) {
    if (previous == null || previous == path) return null;
    // Stepping out of an archive lands in the folder holding it, and the
    // archive file is the row that was left.
    final deeper = path.contains(previous) ? previous : previous.archiveHost;
    if (deeper == null || !path.contains(deeper)) return null;
    final segments = deeper.segments;
    if (segments.length <= path.segments.length) return null;
    return segments[path.segments.length];
  }

  Future<void> refresh() async {
    // A result set has no directory to re-read; refreshing one would silently
    // throw the results away.
    if (isVirtual) return;

    final path = _location;
    if (path == null) return;

    final cursorName = cursorEntry?.name;
    final cursorWas = _cursor;
    final markedNames = _visible
        .where((e) => _marked.contains(e.path))
        .map((e) => e.name)
        .toSet();

    _loading = true;
    notifyListeners();

    try {
      _all = await registry.resolve(path).list(path);
      _error = null;
    } on Object catch (e) {
      // The folder may simply not be there any more — moved, renamed or
      // deleted, by this application or by whoever else is on the machine. A
      // panel standing in it has nowhere to be, and a message with a Retry
      // button is an answer to a question nobody can answer: the folder is not
      // coming back. So it climbs instead.
      if (await _climbOutOfNowhere(path)) return;
      _all = const [];
      _error = e is VfsException ? e.message : e.toString();
    }

    _rebuildVisible();
    _marked
      ..clear()
      ..addAll(_visible
          .where((e) => !e.isParentLink && markedNames.contains(e.name))
          .map((e) => e.path));
    // The row it was on, wherever that row has got to. When it has gone
    // altogether — deleted, moved away, renamed — the cursor stays at the same
    // *place* in the listing instead of jumping to the top, and steps back to
    // the last row when the listing is now shorter than that. Deleting the
    // fourth of five files leaves the cursor on what is now the fourth; deleting
    // the last leaves it on the new last.
    final found = cursorName == null ? -1 : _visible.indexWhere((e) => e.name == cursorName);
    _cursor = found >= 0
        ? found
        : (_visible.isEmpty ? 0 : cursorWas.clamp(0, _visible.length - 1));

    _loading = false;
    notifyListeners();
  }

  /// Walks up to the nearest folder above [gone] that still exists, and lands
  /// there with the cursor where the missing one used to be.
  ///
  /// **Only when it is really gone.** A folder that refused to be read for any
  /// other reason — a permission, a server that dropped the connection — is
  /// still where it was, and walking out of it would cost the user their place
  /// over a hiccup. The question asked is therefore not "did the listing fail"
  /// but "is it still there", and it is asked of the provider.
  ///
  /// Returns false when the panel should stay and show the error instead.
  Future<bool> _climbOutOfNowhere(VfsPath gone) async {
    final FileSystemProvider provider;
    try {
      provider = registry.resolve(gone);
      if (await provider.stat(gone) != null) return false;
    } on Object {
      return false;
    }

    var missing = gone.name;
    var above = gone.parent;
    while (above != null) {
      try {
        if (await provider.stat(above) != null) {
          await navigateTo(above, cursorOn: missing);
          return true;
        }
      } on Object {
        break;
      }
      missing = above.name;
      above = above.parent;
    }

    // Not even the root is there — a volume that has been unmounted, an archive
    // that has been deleted with the panel inside it. Wherever this provider
    // starts is the last place left to be.
    try {
      await navigateTo(await provider.defaultLocation());
      return true;
    } on Object {
      return false;
    }
  }

  /// Changes to a volume, landing in the folder it was last left in.
  ///
  /// What every orthodox commander does, and what Windows itself does with a
  /// current directory per drive: pressing `D:` goes back to the folder being
  /// worked in on D:, not to its root. The memory is shared between the panels
  /// on purpose — the question is "where was I on this drive", and it has one
  /// answer whichever half of the window asks it.
  ///
  /// The root itself is always the fallback: a remembered folder that has since
  /// been deleted, or lives on a stick that came back with a different tree,
  /// must not leave the panel unable to reach the drive at all. Going to a root
  /// through the path bar is [navigateTo] and is left alone — a trail button
  /// says which place is wanted, and it is not a remembered one.
  Future<void> openVolume(VfsPath volume) async {
    final remembered = settings.volumePath(volume.root.toString());

    if (remembered != null) {
      final path = VfsPath.parse(remembered);
      if (path != volume &&
          volume.contains(path) &&
          registry.supports(path.scheme)) {
        if (await navigateTo(path)) return;
        // The remembered folder has gone, or was never one. Not news, and not
        // the user's mistake — they named a drive, and the drive is where they
        // are about to arrive; a remark here complains about our own memory
        // and names a folder nobody asked for. The root below is remembered in
        // its place, so one bad memory cannot poison a volume for good.
        takeFailure();
      }
    }
    await navigateTo(volume);
  }

  /// Escape, from a panel that has nothing in it but a message.
  ///
  /// The level above, or where the panel would have opened if there is no level
  /// above — a drive that has gone has no parent to walk to, and Escape still
  /// has to lead somewhere.
  Future<void> leaveError() async {
    if (_error == null) return;

    final parent = _location?.parent;
    if (parent != null) {
      await navigateTo(parent);
      return;
    }

    final provider = registry.lookup(VfsPath.localScheme);
    if (provider != null) await navigateTo(await provider.defaultLocation());
  }

  Future<void> goUp() async {
    if (isVirtual) return closeResults();

    final path = _location;
    final parent = path?.parent;
    if (path == null || parent == null) return;
    await navigateTo(parent);
  }

  /// Enters the cursor row if it is a directory. Returns the file to open when
  /// it is not, leaving the decision to the caller.
  Future<FileEntry?> activateCursor() async {
    final entry = cursorEntry;
    if (entry == null) return null;
    return activateEntry(entry);
  }

  /// The same, on a row named outright rather than found through the cursor.
  ///
  /// This is what a double click goes through: the click knows which row it
  /// landed on, and nothing about the cursor should be able to change what it
  /// opens between the press and the work.
  Future<FileEntry?> activateEntry(FileEntry entry) async {
    if (entry.isParentLink) {
      await goUp();
      return null;
    }
    if (entry.isDirectory) {
      await navigateTo(entry.path);
      return null;
    }
    return entry;
  }

  void moveCursor(int delta) {
    if (_visible.isEmpty) return;
    setCursor(_cursor + delta);
  }

  void setCursor(int index) {
    _endSelectionRun();
    if (_visible.isEmpty) return;
    final clamped = index.clamp(0, _visible.length - 1);
    if (clamped == _cursor) return;
    _cursor = clamped;
    _rememberCursorSoon();
    notifyListeners();
  }

  /// Puts the cursor on [entry] if it is in the listing, and says whether it
  /// was.
  ///
  /// **What a viewer walking the folder calls.** Somebody who opens the first
  /// of a thousand photographs and steps to the four hundredth has moved
  /// through the folder, and coming back to the panel to find the cursor still
  /// on the first is the panel disagreeing with what they just did — which is
  /// exactly what made remembering the row worth having.
  bool putCursorOn(FileEntry entry) {
    final index = _visible.indexWhere((e) => e.path == entry.path);
    if (index < 0) return false;
    setCursor(index);
    return true;
  }

  /// Writes down which row the panel is standing on, at most once in
  /// [_cursorSettles].
  ///
  /// **Throttled, and with no timer anywhere.** Holding an arrow down through
  /// a folder of a thousand files is a thousand cursor moves, and a preference
  /// written on each one is a thousand trips across the platform channel — on
  /// Windows, a thousand rewrites of the whole settings file — for nine
  /// hundred and ninety-nine answers nobody will ever read. A timer would have
  /// been the obvious way to collapse them and is the wrong one: a pending
  /// timer under a widget test's fake clock fails the test, and fifty-nine of
  /// them failed at once when this was written that way. So the throttle is
  /// arithmetic on a clock rather than anything scheduled.
  ///
  /// What the throttle leaves behind — the last row of a burst, still unwritten
  /// — is caught by [rememberCursorNow] on the way out.
  void _rememberCursorSoon() {
    final now = DateTime.now();
    final last = _cursorWritten;
    if (last != null && now.difference(last) < _cursorSettles) return;
    rememberCursorNow();
  }

  /// Writes it down this instant, wherever waiting is not safe — the window
  /// going away being the case that matters.
  void rememberCursorNow() {
    _cursorWritten = DateTime.now();
    final entry = cursorEntry;
    // `..` is not a row anybody was looking at, and a panel restored onto it
    // would be a panel that forgot.
    if (entry == null || entry.isParentLink) return;
    unawaited(settings.setPanelCursor(isLeft, entry.name));
  }

  DateTime? _cursorWritten;

  /// How often the row is written down while it is moving. Long enough that a
  /// walk through a folder is a handful of writes rather than a thousand.
  static const Duration _cursorSettles = Duration(milliseconds: 400);

  /// How many rows fit on screen at once.
  ///
  /// Set by the panel widget as it lays itself out, because Page Up and Page
  /// Down mean a page of the listing *as it is on screen* and only the widget
  /// knows how tall that is. It used to be a hard 20 here, which on a tall
  /// window skipped half of what was showing and on a short one ran past the
  /// end of it.
  ///
  /// Assigned rather than announced: it is discovered during a build, and a
  /// notifier that told the tree about it then would be asking for a rebuild
  /// from inside one. Nothing is drawn from it — it is only ever read back when
  /// a key is pressed.
  int visibleRows = 20;

  /// The row a run of Shift-moves set off from, and the rows that run has
  /// marked. -1 when no run is going.
  int _selectAnchor = -1;
  final Set<int> _runMarked = {};

  void _endSelectionRun() {
    _selectAnchor = -1;
    _runMarked.clear();
  }

  /// Moves the cursor to [index] and marks everything between there and where
  /// the run began — Shift with an arrow, a page key or Home and End, as
  /// Total Commander does it.
  ///
  /// Anchored rather than "mark the row and step on", so that walking back over
  /// what was just marked unmarks it again. And only what *this* run marked is
  /// ever given back: a selection made before Shift was pressed survives a
  /// shift-move across it, because taking it away is not something the user
  /// asked for by holding a modifier.
  void selectTo(int index) {
    if (_visible.isEmpty) return;
    final target = index.clamp(0, _visible.length - 1);
    if (_selectAnchor < 0) _selectAnchor = _cursor;

    final from = _selectAnchor < target ? _selectAnchor : target;
    final to = _selectAnchor < target ? target : _selectAnchor;

    for (final row in _runMarked.toList()) {
      if (row < from || row > to) {
        if (row < _visible.length) _marked.remove(_visible[row].path);
        _runMarked.remove(row);
      }
    }
    for (var row = from; row <= to; row++) {
      final entry = _visible[row];
      // `..` is not an entry and is not markable, here as everywhere else.
      if (entry.isParentLink) continue;
      if (_marked.add(entry.path)) _runMarked.add(row);
    }

    _cursor = target;
    _rememberCursorSoon();
    notifyListeners();
  }

  /// Marks or unmarks the cursor row and steps down, like Insert does in
  /// Total Commander.
  ///
  /// [measureDirectory] reproduces what Space does there: marking a folder also
  /// starts counting what is inside it.
  void toggleMarkAtCursor({bool advance = true, bool measureDirectory = false}) {
    final entry = cursorEntry;
    if (entry == null || entry.isParentLink) return;

    final wasMarked = _marked.remove(entry.path);
    if (!wasMarked) _marked.add(entry.path);

    if (measureDirectory && entry.isDirectory) {
      // Fire and forget: the row fills in when the walk finishes.
      unawaited(computeDirectorySize(entry));
    }

    if (advance && _cursor < _visible.length - 1) _cursor++;
    notifyListeners();
  }

  /// What quick search is looking for, while it is looking.
  ///
  /// The panel keeps it so that the rows can be drawn accordingly: the ones that
  /// do not match are ghosted rather than merely skipped over, which turns "the
  /// cursor jumped somewhere" into "these are the ones, and here is the first".
  /// The matching rule stays in one place — [matchesSearch] and [findMatches] are
  /// the same test.
  String? get searchQuery => _searchQuery;
  String? _searchQuery;

  void setSearchQuery(String? query) {
    final next = (query == null || query.isEmpty) ? null : query;
    if (next == _searchQuery) return;
    _searchQuery = next;
    notifyListeners();
  }

  /// Whether [entry] answers the current query. True for everything when nothing
  /// is being searched for, and always true for `..` — the way out of a folder is
  /// not something to hide while looking for something in it.
  bool matchesSearch(FileEntry entry) {
    final query = _searchQuery;
    if (query == null || entry.isParentLink) return true;
    return _matches(entry, query.toLowerCase());
  }

  static bool _matches(FileEntry entry, String lowerQuery) {
    if (entry.isParentLink) return false;
    final name = entry.name.toLowerCase();
    return name.startsWith(lowerQuery) || name.contains(lowerQuery);
  }

  /// Moves the cursor to the next entry matching [query], wrapping around.
  /// [direction] of -1 searches backwards. Returns the number of matches.
  int findMatches(String query, {int direction = 0}) {
    if (query.isEmpty) return 0;
    final lower = query.toLowerCase();

    bool matches(FileEntry entry) => _matches(entry, lower);

    final hits = <int>[
      for (var i = 0; i < _visible.length; i++)
        if (matches(_visible[i])) i,
    ];
    if (hits.isEmpty) return 0;

    if (direction == 0) {
      // A fresh query prefers a prefix hit, then falls back to any substring.
      final prefix = hits.firstWhere(
        (i) => _visible[i].name.toLowerCase().startsWith(lower),
        orElse: () => hits.first,
      );
      setCursor(prefix);
      return hits.length;
    }

    final position = hits.indexOf(_cursor);
    final next = position < 0
        ? (direction > 0
            ? hits.firstWhere((i) => i > _cursor, orElse: () => hits.first)
            : hits.lastWhere((i) => i < _cursor, orElse: () => hits.last))
        : hits[(position + direction + hits.length) % hits.length];
    setCursor(next);
    return hits.length;
  }

  void toggleMark(FileEntry entry) {
    if (entry.isParentLink) return;
    if (!_marked.remove(entry.path)) _marked.add(entry.path);
    notifyListeners();
  }

  void markAll() {
    _marked
      ..clear()
      ..addAll(_visible.where((e) => !e.isParentLink).map((e) => e.path));
    notifyListeners();
  }

  void clearMarks() {
    if (_marked.isEmpty) return;
    _marked.clear();
    notifyListeners();
  }

  void invertMarks() {
    final inverted = _visible
        .where((e) => !e.isParentLink && !_marked.contains(e.path))
        .map((e) => e.path)
        .toSet();
    _marked
      ..clear()
      ..addAll(inverted);
    notifyListeners();
  }

  /// Moves the cursor to the first entry whose name starts with [prefix].
  /// Used by type-ahead search.
  bool jumpToPrefix(String prefix) {
    final lower = prefix.toLowerCase();
    for (var i = 0; i < _visible.length; i++) {
      if (_visible[i].isParentLink) continue;
      if (_visible[i].name.toLowerCase().startsWith(lower)) {
        setCursor(i);
        return true;
      }
    }
    return false;
  }

  void _onSettingsChanged() {
    _rebuildVisible();
    notifyListeners();
  }

  /// Applies the hidden-file filter and the sort order, then puts `..` on top.
  void _rebuildVisible() {
    final filtered = settings.appearance.showHidden
        ? List<FileEntry>.from(_all)
        : _all.where((e) => !e.isHidden).toList();

    final column = settings.sortColumn;
    final ascending = settings.sortAscending;
    final directoriesFirst = settings.directoriesFirst;

    filtered.sort((a, b) {
      if (directoriesFirst && a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      final result = switch (column) {
        SortColumn.name =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        SortColumn.extension => a.extension.compareTo(b.extension) != 0
            ? a.extension.compareTo(b.extension)
            : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        SortColumn.size => a.size.compareTo(b.size),
        SortColumn.modified => (a.modified ?? DateTime(0))
            .compareTo(b.modified ?? DateTime(0)),
      };
      return ascending ? result : -result;
    });

    // In a result set the `..` row is the way out of it, not the way up the
    // tree — the rows below it come from all over the disk.
    final parent = isVirtual ? _virtualOrigin : _location?.parent;
    _visible = [
      if (parent != null) FileEntry.parentLink(parent),
      ...filtered,
    ];
    if (_cursor >= _visible.length) {
      _cursor = _visible.isEmpty ? 0 : _visible.length - 1;
    }
  }

  int _indexOfName(String name) {
    final index = _visible.indexWhere((e) => e.name == name);
    return index < 0 ? 0 : index;
  }

  @override
  void dispose() {
    settings.removeListener(_onSettingsChanged);
    // Not through detach(): that notifies listeners, and this object is on its
    // way out. The plugin still has to be told, so the session is released
    // without waiting for it — nothing is left to await it here.
    final attachment = _attachment;
    if (attachment != null) {
      _attachment = null;
      attachment.removeListener(_onAttachmentChanged);
      unawaited(attachment.release());
      attachment.dispose();
    }
    super.dispose();
  }
}
