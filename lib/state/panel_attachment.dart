import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/plugins/plugin_manifest.dart';
import '../core/plugins/plugin_registry.dart';
import '../core/plugins/view.dart';
import '../core/plugins/viewer.dart';
import '../ui/viewer/structure_panel.dart' show StructureHandle;
import '../core/vfs/file_entry.dart';
import '../core/vfs/vfs_path.dart';
import 'listing_cursor.dart';

/// Something occupying a panel in place of its file listing.
///
/// The panel keeps everything else — its frame, its place in the layout, which
/// panel is active — and swaps only what fills it. That is what makes a
/// viewport out of one side while the other goes on being a file panel, and it
/// is the same trick the search results already play: the panel is a frame with
/// something in it, not a listing with chrome around it.
abstract class PanelAttachment extends ChangeNotifier {
  /// The reach into the structure panel of whatever reading is attached here.
  ///
  /// Held by the attachment rather than by the widget for the reason every
  /// cursor here is: the content is replaced wholesale whenever the plugin
  /// answers, and the chrome around it — the strip with the cross in it — has
  /// to be able to reach the panel without going through the drawing.
  final StructureHandle structure = StructureHandle();

  /// One cursor per part, because a split has a listing in each of them and
  /// they do not share a keyboard.
  ///
  /// Held here rather than in the widget for two reasons, and both are about
  /// something outside the widget knowing. The content is replaced wholesale
  /// every time the plugin answers, so a cursor that lived in the drawing
  /// would go back to the top on every keystroke; and the keys themselves
  /// arrive at the commander screen or at the full-screen page, neither of
  /// which can reach inside a widget to move anything.
  final Map<String, ListingCursor> _cursors = {};

  /// Which part the keyboard is in. Empty is the whole content, which is what
  /// anything that is not a split has.
  String _focused = '';

  String get focusedPart => _focused;

  /// Puts the keyboard in a part. Called when one is clicked, and when the
  /// keys are walked from one part to the next.
  ///
  /// A part that only holds other parts is refused: there is nothing in it to
  /// put a cursor on, and the keyboard resting there is the keyboard being
  /// nowhere. Belt as well as braces — the part that holds others no longer
  /// asks — because a keyboard that can be put nowhere is the one failure this
  /// application does not get to have.
  void focusPart(String part) {
    if (_focused == part) return;
    if (part.isNotEmpty && !partNames.contains(part)) return;
    _focused = part;
    notifyListeners();
  }

  ListingCursor cursorFor(String part) => _cursors.putIfAbsent(part, () {
        final cursor = ListingCursor();
        cursor.addListener(() => onCursorSettling(part, cursor.index));
        return cursor;
      });

  /// The cursor moved in [part]. Only [PluginViewAttachment] has anywhere to
  /// send that, and only when the view asked to be told.
  void onCursorSettling(String part, int row) {}

  /// Puts each part's cursor where the content asked for it, if it asked.
  ///
  /// See [ViewerContent.cursor]: a request that arrives before the rows do is
  /// held by the cursor and spent when they arrive, so this can run the moment
  /// content lands rather than waiting for a frame.
  void _placeCursors(ViewerContent? content) {
    void walk(ViewerContent? at, String part) {
      if (at == null) return;
      if (at.kind == ViewerContentKind.split) {
        for (final piece in at.parts) {
          walk(piece.content, piece.id);
        }
        return;
      }
      if (at.cursor >= 0) cursorFor(part).wantRow(at.cursor);
    }

    walk(content, '');
  }

  /// Where the keyboard is now — the cursor of the part holding it.
  ListingCursor get listingCursor => cursorFor(_focused);

  /// Every part that holds something of its own, in reading order — or one
  /// empty name for content that is not a split at all.
  ///
  /// **The leaves, not the branches.** A split may hold a split: the git tool
  /// is a log above, and beneath it the files on one side and the difference
  /// on the other. Listing only the outermost two named a part that draws
  /// nothing itself and never named the two that do, so the keyboard could not
  /// be walked to the list of files — and clicking it did not help either,
  /// because nothing could find it to ask whether it was a listing.
  List<String> get partNames {
    final found = <String>[];
    void walk(ViewerContent? at) {
      if (at == null) return;
      if (at.kind != ViewerContentKind.split) return;
      for (final part in at.parts) {
        if (part.content?.kind == ViewerContentKind.split) {
          walk(part.content);
        } else {
          found.add(part.id);
        }
      }
    }

    walk(content);
    return found.isEmpty ? const [''] : found;
  }

  /// What one part holds, wherever it is in the tree.
  ViewerContent? contentOfPart(String id) {
    if (content?.kind != ViewerContentKind.split) {
      return id.isEmpty ? content : null;
    }

    ViewerContent? search(ViewerContent at) {
      for (final part in at.parts) {
        if (part.id == id) return part.content;
        final inner = part.content;
        if (inner != null && inner.kind == ViewerContentKind.split) {
          final found = search(inner);
          if (found != null) return found;
        }
      }
      return null;
    }

    return search(content!);
  }

  /// Puts the keyboard somewhere it can be used, when it is nowhere.
  ///
  /// Called whenever new content arrives. A page that opens with the keyboard
  /// in none of its parts is a page the arrow keys do nothing in until
  /// something is clicked — and this application is worked from the keyboard
  /// first, so that is not a state it may be in.
  void _focusSomethingUsable() {
    final parts = partNames;
    if (parts.contains(_focused)) return;
    for (final part in parts) {
      if (contentOfPart(part)?.kind == ViewerContentKind.table) {
        _focused = part;
        return;
      }
    }
    _focused = parts.first;
  }

  /// Moves the keyboard to the next part along, and says whether it could.
  ///
  /// It wraps, because three parts and a key that stops at the last one means
  /// reaching for the mouse to get back to the first.
  bool focusNextPart({bool backwards = false}) {
    final parts = partNames;
    if (parts.length < 2) return false;
    final at = parts.indexOf(_focused);
    final next = (at < 0 ? 0 : at + (backwards ? -1 : 1)) % parts.length;
    focusPart(parts[next < 0 ? parts.length - 1 : next]);
    return true;
  }

  @override
  void dispose() {
    for (final cursor in _cursors.values) {
      cursor.dispose();
    }
    super.dispose();
  }

  /// Shown in the panel's path bar in place of the location.
  String get title;

  /// One line along the bottom, where the file totals normally are.
  String? get status;

  /// Where the attachment has walked to, outermost first, for the place a
  /// panel keeps its path. Empty means it has nowhere to walk and [title]
  /// stands in.
  List<String> get trail => const [];

  /// One level of that trail was pressed.
  Future<void> step(int index) async {}

  /// An icon for the path bar, named from the set the host knows.
  String? get icon => null;

  /// Whose content this is, for the settings that are about how it is drawn
  /// rather than about what is in it. Null for anything the host holds itself.
  String? get pluginId => null;

  /// Buttons the attachment offers. The pills among them are drawn where a
  /// panel keeps its path, which is the one place a panel has for them — see
  /// `ViewChrome`.
  List<ViewCommand> get commands => const [];

  bool get isLoading;

  /// What to draw. Null while nothing has arrived yet.
  ViewerContent? get content;

  /// Whether the rows of a table are worth clicking. False for an attachment
  /// that shows a file rather than a list of them.
  bool get isInteractive => false;

  /// The other panel moved. Only attachments that asked to follow one do
  /// anything with this.
  void follow({VfsPath? location, FileEntry? cursor}) {}

  /// A row was opened.
  Future<void> activate(int row, {String part = ''}) async {}

  /// What is picked out in [part], by row. Every event carries it, so a view
  /// that acts on several rows at once needs no separate question.
  List<int> markedIn(String part) => cursorFor(part).marked;

  /// Rows were carried out of one part and let go over another.
  Future<void> dropRows(String from, String to, List<int> rows) async {}

  /// The menus whatever is attached brings with it, or none. Asked of every
  /// attachment because both surfaces draw them now — see [ViewResponse.menus].
  List<ViewMenu> get menus => const [];

  /// A row was picked out rather than opened — the secondary press.
  ///
  /// What comes back is what the view wants drawn under the pointer, empty
  /// when it wants nothing: see [ViewResponse.contextMenu].
  Future<List<ViewMenuItem>> mark(int row, {String part = ''}) async => const [];

  /// One of the buttons the content declared was pressed. [values] is what a
  /// form's fields held, and is empty from every other kind of content.
  Future<void> press(String buttonId, {Map<String, Object?> values = const {}}) async {}

  /// Whether the view has a page open over its own first one — see
  /// [HostActionKind.page]. Back and Escape mean *that* while it is true.
  bool get canGoBack => false;

  /// Draws the page underneath again, and tells the view it happened.
  Future<void> goBack() async {}

  /// A key press the attachment asked for. Returns true when it used it, so
  /// the panel's own bindings still work for everything it did not.
  Future<bool> handleKey(String key) async => false;

  /// The attachment is going away. Anything holding a plugin session releases
  /// it here.
  Future<void> release() async {}
}

/// The panel as a viewport onto whatever the other panel's cursor is on.
///
/// No plugin knows this is happening: it resolves an ordinary viewer, the same
/// one F3 would open, and asks it for the file under the cursor. Every viewer
/// ever written therefore works in a panel on the day this ships, which is the
/// whole reason it is built out of the viewer contribution rather than a new
/// one.
class QuickViewAttachment extends PanelAttachment {
  QuickViewAttachment({required this.plugins});

  final PluginRegistry plugins;

  /// How long the cursor has to settle before the file is read.
  ///
  /// Holding an arrow key walks a directory a row at a time; without this,
  /// every row on the way is opened, decoded and thrown away. The delay is
  /// short enough to feel immediate when the cursor stops.
  static const Duration settle = Duration(milliseconds: 120);

  Timer? _pending;
  VfsPath? _showing;
  FileEntry? _target;
  ViewerContent? _content;
  bool _loading = false;
  String? _viewerName;

  /// Counts the reads, so a slow one landing after a newer one is discarded
  /// rather than painted over the file the cursor is actually on.
  int _generation = 0;

  @override
  String get title => _target?.name ?? 'Quick view';

  @override
  String? get status => switch (_target) {
        null => 'Nothing under the cursor',
        final entry when entry.isDirectory => 'Folder',
        _ => _viewerName,
      };

  @override
  String? get icon => 'view';

  /// Whichever viewer answered for the file under the cursor — a quick view is
  /// the same reading the full page would give, so it is drawn the same way.
  @override
  String? get pluginId => _pluginId;
  String? _pluginId;

  @override
  bool get isLoading => _loading;

  @override
  ViewerContent? get content => _content;

  @override
  void follow({VfsPath? location, FileEntry? cursor}) {
    // The `..` row is a way back up, not a file. Showing the parent folder's
    // name with nothing under it reads as an error where nothing is wrong.
    final entry = cursor != null && !cursor.isParentLink ? cursor : null;
    if (entry?.path == _target?.path) return;

    _target = entry;
    _pending?.cancel();
    _pending = Timer(settle, _load);
    notifyListeners();
  }

  Future<void> _load() async {
    final entry = _target;
    final generation = ++_generation;

    if (entry == null || entry.isDirectory) {
      _showing = null;
      _content = null;
      _viewerName = null;
      _pluginId = null;
      _loading = false;
      notifyListeners();
      return;
    }
    if (entry.path == _showing) return;

    // Asking the viewers about the file is a round trip, so the cursor may
    // have moved on while it was in flight — the same guard the open below
    // already keeps.
    final candidates = await plugins.viewersForFile(entry);
    if (generation != _generation) return;
    if (candidates.isEmpty) {
      _showing = entry.path;
      _viewerName = null;
      _content = ViewerContent.error(
        'No viewer claims .${entry.extension}. '
        'Install one from Settings → Plugins.',
      );
      _loading = false;
      notifyListeners();
      return;
    }

    _loading = true;
    notifyListeners();

    final viewer = candidates.first;
    ViewerContent result;
    try {
      result = await viewer.open(entry.path);
    } on Object catch (e) {
      result = ViewerContent.error('${viewer.title} failed: $e');
    }

    // A newer cursor position won while this was in flight.
    if (generation != _generation) return;

    _showing = entry.path;
    _viewerName = '${viewer.title} · ${viewer.pluginName}';
    _pluginId = viewer.pluginId;
    _content = result;
    _loading = false;
    notifyListeners();
  }

  @override
  Future<void> release() async {
    _pending?.cancel();
    _pending = null;
  }

  @override
  void dispose() {
    _pending?.cancel();
    super.dispose();
  }
}

/// What came of a view's actions: what actually went, and what the user said.
///
/// One object rather than two return values, because both are answers to
/// questions the view asked and both come back the same way — as an event, so
/// the view learns the fact instead of assuming it.
class ViewOutcome {
  const ViewOutcome({this.deleted = const [], this.answers = const {}});

  /// Only the paths that really went. A cancelled confirmation leaves this
  /// empty, which is how a view is stopped from drawing a folder as gone.
  final List<VfsPath> deleted;

  /// What was said to each question, by the id the view gave it.
  final Map<String, bool> answers;

  bool get isEmpty => deleted.isEmpty && answers.isEmpty;
}

/// Carries out a view's actions and reports back what came of them.
typedef ViewActionSink = Future<ViewOutcome> Function(List<HostAction> actions);

/// A plugin's own view, filling a panel.
///
/// The session lives as long as the panel holds it, so a view that built
/// something expensive — a walk of a whole disk — keeps it across events
/// instead of rebuilding on every click.
class PluginViewAttachment extends PanelAttachment {
  PluginViewAttachment({
    required this.view,
    required this.session,
    required VfsPath? location,
    required this.onActions,
    PluginSurface surface = PluginSurface.panel,
    VfsPath? otherLocation,
  }) : _context = ViewContext(
          session: session,
          surface: surface,
          path: location,
          otherPath: otherLocation,
          isDirectory: location != null,
        ) {
    // A view that pushes redraws — a scan filling in as it goes — is answered
    // here rather than in every screen that can hold one.
    _updates = view.updates
        .where((update) => update.session == session)
        .listen(_apply);
  }

  final RegisteredView view;

  @override
  String? get pluginId => view.pluginId;

  /// Identifies this open copy to the plugin — `left`, `right`, or the page.
  final String session;

  /// Carries out whatever the view asked the host to do, and answers with
  /// whatever was deleted along the way. Supplied by the screen, because
  /// navigating a panel is not something state can do to itself: which panel
  /// "the other one" is depends on where the view sits.
  ///
  /// The answer matters for exactly one case: a view that asked for a delete
  /// has to learn what actually went, because the user may have said no.
  final ViewActionSink onActions;

  static const Duration settle = Duration(milliseconds: 120);

  ViewContext _context;
  Timer? _pending;
  StreamSubscription<ViewUpdate>? _updates;
  ViewerContent? _content;
  String? _title;
  String? _status;
  List<String> _trail = const [];
  List<ViewMenu> _menus = const [];
  List<ViewCommand> _commands = const [];
  bool _loading = false;
  int _generation = 0;

  /// What the view offers the bar. Kept between answers, like the title and
  /// the trail — see [ViewResponse.menus].
  @override
  List<ViewMenu> get menus => _menus;
  @override
  List<ViewCommand> get commands => _commands;

  @override
  String get title => _title ?? view.spec.title;

  @override
  String? get status => _status;

  @override
  List<String> get trail => _trail;

  @override
  String? get icon => view.spec.icon;

  @override
  bool get isLoading => _loading;

  @override
  ViewerContent? get content => _content;

  @override
  bool get isInteractive => true;

  bool get wantsKeys => view.spec.wantsKeys;

  /// How long the cursor has to stand still before the view is told.
  ///
  /// The same 120 ms the panel viewport waits, and for the same reason: an
  /// arrow key held down walks a listing faster than any round trip, and a
  /// view asked about every row on the way would answer with pages nobody saw.
  static const Duration cursorSettle = Duration(milliseconds: 120);

  Timer? _settling;

  /// The pages this view has put on top of its own, oldest first.
  ///
  /// Held here rather than in whatever is drawing it, because both surfaces a
  /// view can be on would otherwise need their own copy of it — and because
  /// going back has to be *drawing*, not another round trip: a page that has
  /// to be asked for again is a page that flickers on the way back.
  final List<_ViewPage> _stack = [];

  @override
  bool get canGoBack => _stack.isNotEmpty;

  /// The last row each part was told about, so an answer that redraws a
  /// listing without moving its cursor does not ask the same question again.
  /// Two parts pointing at each other that way is a loop, not a view.
  final Map<String, int> _told = {};

  @override
  void onCursorSettling(String part, int row) {
    if (!view.spec.wantsCursor) return;
    if (_told[part] == row) return;
    _settling?.cancel();
    _settling = Timer(cursorSettle, () {
      _told[part] = row;
      unawaited(
        _run(() => view.handle(_context, ViewEvent.cursor(row, part: part))),
      );
    });
  }

  /// Opens the view for the first time, pointed at [location] and [cursor] if
  /// it follows either.
  ///
  /// Pointing before opening rather than after is what keeps the first draw
  /// from being thrown away: a view that follows a cursor would otherwise open
  /// on the panel it is in, then immediately be re-opened somewhere else.
  Future<void> start({VfsPath? location, FileEntry? cursor}) {
    _retarget(location: location, cursor: cursor);
    return _run(() => view.open(_context));
  }

  @override
  void follow({VfsPath? location, FileEntry? cursor}) {
    // The other side, kept current whatever the view follows. A view that
    // follows nothing still has a panel beside it, and a tool about both sides
    // must not be told where the other one was ten folders ago. It is not on
    // its own a reason to ask the view again — that is what `follows` decides.
    if (location != null && location != _context.otherPath) {
      _context = _context.withOtherPath(location);
    }

    if (!_retarget(location: location, cursor: cursor)) return;

    _pending?.cancel();
    _pending = Timer(settle, () => unawaited(_run(() => view.open(_context))));
  }

  /// Moves the context to what the view follows. True when it moved.
  bool _retarget({VfsPath? location, FileEntry? cursor}) {
    final next = switch (view.spec.follows) {
      ViewFollows.none => null,
      ViewFollows.location => location,
      ViewFollows.cursor =>
        cursor != null && !cursor.isParentLink ? cursor.path : location,
    };
    if (next == null || next == _context.path) return false;

    final isDirectory = switch (view.spec.follows) {
      ViewFollows.cursor => cursor?.isDirectory ?? true,
      _ => true,
    };
    _context = _context.withPath(next, isDirectory: isDirectory);
    return true;
  }

  @override
  Future<void> activate(int row, {String part = ''}) async {
    final picked = markedIn(part);
    await _activate(row, part, picked);
    // Acting on what was picked out uses it up, the way it does in a panel
    // after a copy or a delete. Leaving the marks would leave them on rows
    // that are no longer the same files: the list has just changed *because*
    // of them.
    if (picked.isNotEmpty) cursorFor(part).clearMarks();
  }

  Future<void> _activate(int row, String part, List<int> marked) => _run(
        () => view.handle(
          _context,
          // What is picked out travels with the press. A view that can act on
          // several rows never has to ask which ones, and one that cannot is
          // free to ignore the list — the row it happened on is still there.
          ViewEvent.activate(row, part: part, marked: marked),
        ),
        // A split does not walk anywhere: opening a row in the log fills in
        // the part underneath, and the log is still the log. Rewinding every
        // cursor there would throw away the place the reader is holding in the
        // very list they just pressed.
        rewind: content?.kind != ViewerContentKind.split,
      );

  @override
  Future<List<ViewMenuItem>> mark(int row, {String part = ''}) async {
    final response = await _run(
      () => view.handle(
        _context,
        ViewEvent.mark(row, part: part, marked: markedIn(part)),
      ),
    );
    return response?.contextMenu ?? const [];
  }

  @override
  Future<void> press(String buttonId, {Map<String, Object?> values = const {}}) =>
      _run(() => view.handle(_context, ViewEvent.button(buttonId, values: values)));

  @override
  @override
  Future<void> dropRows(String from, String to, List<int> rows) async {
    await _run(() => view.handle(_context, ViewEvent.drop(from, to, rows)));
    // Carried and let go is acting on them, so they are used up like anything
    // else done to what was picked out.
    cursorFor(from).clearMarks();
  }

  @override
  Future<void> step(int index) =>
      _run(() => view.handle(_context, ViewEvent.step(index)), rewind: true);

  @override
  Future<bool> handleKey(String key) async {
    if (!wantsKeys) return false;
    await _run(() => view.handle(_context, ViewEvent.key(key)));
    return true;
  }

  /// Runs one round trip to the plugin and draws whatever came back.
  ///
  /// [rewind] is what tells a walk apart from a redraw. Opening a row and
  /// pressing a level of the trail both mean "go into this", and the cursor
  /// starts at the top of what you went into; a refresh, a button and a push
  /// from the plugin are the *same* page arriving again, and moving the cursor
  /// there would lose the reader's place for no reason.
  Future<ViewResponse?> _run(
    Future<ViewResponse> Function() call, {
    bool rewind = false,
  }) async {
    final generation = ++_generation;
    _loading = true;
    notifyListeners();

    final response = await call();
    // Null rather than an answer: this round trip has been overtaken by a
    // later one, and whoever is waiting on it — a menu about to be drawn under
    // the pointer — must not act on what it said.
    if (generation != _generation) return null;

    if (rewind && response.content != null) {
      for (final cursor in _cursors.values) {
        cursor.rewind();
      }
    }
    _loading = false;
    _apply(ViewUpdate(
      viewId: view.id,
      session: session,
      response: response,
    ));
    return response;
  }

  /// Draws an answer, whether it was asked for or pushed, and carries out
  /// whatever it wanted of the host.
  void _apply(ViewUpdate update) {
    final response = update.response;

    // Before anything is drawn over: a page that asked to be pushed is asking
    // for *what is here now* to be kept, and it comes in the same answer as
    // what replaces it.
    final pushing = [
      for (final action in response.actions)
        if (action.kind == HostActionKind.page) action,
    ];
    if (pushing.isNotEmpty) {
      _stack.add(_ViewPage(
        content: _content,
        title: _title,
        status: _status,
        trail: _trail,
        menus: _menus,
        commands: _commands,
        focused: _focused,
        cursors: {
          for (final part in _cursors.keys) part: _cursors[part]!.index,
        },
      ));
    }

    // Content is left alone when the view returned none: an answer that only
    // moves the other panel should not blank what the user is looking at.
    if (response.content != null) {
      _content = response.content;
      _placeCursors(response.content);
    }
    if (response.title != null) _title = response.title;
    // A page that does not rename the bar looks like the one it covered, so
    // the action carries a title of its own for the common case.
    if (response.title == null && pushing.isNotEmpty) {
      final named = pushing.last.title;
      if (named != null && named.isNotEmpty) _title = named;
    }
    if (response.status != null) _status = response.status;
    _focusSomethingUsable();

    // Said, rather than sent. Everything here is kept until replaced, and an
    // empty list is a replacement like any other: it is how a view puts its
    // own chrome away when it stops being about what the chrome said.
    if (response.saidTrail || response.trail.isNotEmpty) {
      _trail = response.trail;
    }
    if (response.saidMenus || response.menus.isNotEmpty) {
      _menus = response.menus;
    }
    if (response.saidCommands || response.commands.isNotEmpty) {
      _commands = response.commands;
    }
    notifyListeners();

    if (response.actions.isEmpty) return;
    if (response.actions.any((action) => action.kind == HostActionKind.back)) {
      unawaited(goBack());
    }
    unawaited(_carryOut(response.actions));
  }

  /// Draws the page underneath again.
  ///
  /// Nothing is asked for: everything the page had is here, down to where each
  /// cursor was standing, so what comes back is the page that was left rather
  /// than a fresh one that looks like it. The view is *told*, after the fact,
  /// so a plugin keeping its own idea of where it is can put it straight — and
  /// a plugin that does not care needs no code at all.
  @override
  Future<void> goBack() async {
    if (_stack.isEmpty) return;
    final page = _stack.removeLast();
    // A page pushed before anything was drawn — a view opened straight onto
    // it — has nothing underneath to put back. What is on screen stays there
    // until the view answers the event below, rather than blanking on the way
    // to being told what to draw.
    if (page.content != null) _content = page.content;
    _title = page.title;
    _status = page.status;
    _trail = page.trail;
    _menus = page.menus;
    _commands = page.commands;
    for (final part in page.cursors.keys) {
      cursorFor(part).moveTo(page.cursors[part]!);
    }
    _focused = page.focused;
    _focusSomethingUsable();
    notifyListeners();

    await _run(() => view.handle(_context, ViewEvent.back(_stack.length)));
  }

  /// A view that asked for a delete is told what actually went, because the
  /// user was asked in between and may well have said no. Without the round
  /// trip the map would show a folder as gone when it is still there.
  Future<void> _carryOut(List<HostAction> actions) async {
    final outcome = await onActions(actions);
    if (outcome.isEmpty) return;

    // One event each, and the answers first: a view that asked before doing
    // something wants the answer before it is told what was done.
    for (final answer in outcome.answers.entries) {
      await _run(
        () => view.handle(
          _context,
          ViewEvent.answered(answer.key, answer.value),
        ),
      );
    }
    if (outcome.deleted.isEmpty) return;
    await _run(() => view.handle(_context, ViewEvent.deleted(outcome.deleted)));
  }

  @override
  Future<void> release() async {
    _pending?.cancel();
    _pending = null;
    _settling?.cancel();
    _settling = null;
    // Not awaited: cancelling stops the events at once, and whoever is closing
    // the panel is waiting on this to put the listing back.
    unawaited(_updates?.cancel());
    _updates = null;
    await view.close(session);
  }

  @override
  void dispose() {
    _pending?.cancel();
    _settling?.cancel();
    unawaited(_updates?.cancel());
    super.dispose();
  }
}

/// A page a view put on screen before pushing another over it.
///
/// Everything the chrome was saying as well as the content, because a title
/// bar that came back saying what the *inner* page was called would be a page
/// that half went back.
class _ViewPage {
  const _ViewPage({
    required this.content,
    required this.title,
    required this.status,
    required this.trail,
    required this.menus,
    required this.commands,
    required this.focused,
    required this.cursors,
  });

  final ViewerContent? content;
  final String? title;
  final String? status;
  final List<String> trail;
  final List<ViewMenu> menus;
  final List<ViewCommand> commands;

  /// Which part had the keyboard, and where every cursor was standing. This is
  /// what makes going back feel like going back rather than opening it again.
  final String focused;
  final Map<String, int> cursors;
}
