import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../../core/platform/key_letters.dart';
import '../../core/settings/appearance_settings.dart';
import '../motion.dart';
import 'blurred_backdrop.dart';
import 'hint.dart';
import '../picture_filter.dart';

/// How round a menu's corners are — and, since a title on the strip and the
/// menu it opens are one element, how round that title is too.
const double kMenuCornerRadius = 8;

/// One row in a context menu.
sealed class MenuNode {
  const MenuNode();
}

/// A command the user can pick.
class MenuItem extends MenuNode {
  const MenuItem(
    this.label, {
    this.icon,
    this.image,
    this.leading,
    this.leadingWidth = 22,
    this.shortcut,
    this.accelerator,
    this.enabled = true,
    this.checked,
    this.keywords = const [],
    this.children = const [],
    this.submenuTitle,
    this.onRemove,
    this.onPin,
    this.isPinned,
    this.onDragged,
    this.hint,
    required this.onSelected,
  });

  final String label;
  final IconData? icon;

  /// A picture file to draw instead of [icon] — a plugin's own mark.
  ///
  /// **Whatever put the row there is what the row shows.** A tool that ships a
  /// face has one so it can be recognised, and a row offering that tool with
  /// the generic extension shape instead is a row that makes the reader work
  /// out which of their tools it is. Drawn unrecoloured, for the reason the
  /// title bar's are: a mark that follows the palette is not a mark.
  final String? image;

  /// Drawn in the leading slot instead of an icon or a picture.
  ///
  /// **For a row whose mark is not a symbol.** The palette list draws three
  /// colours there — the whole point of choosing a palette by seeing what it is
  /// made of rather than by reading its name — and no icon can say that. It
  /// takes [leadingWidth], because three swatches do not fit in the 22 points
  /// an icon lives in.
  final Widget? leading;

  /// How wide the leading slot is for this row. The default is what an icon
  /// has always had.
  final double leadingWidth;

  /// Shown right-aligned, e.g. `F5`. Purely informational.
  final String? shortcut;

  /// A single character that picks this row outright while the menu is open —
  /// `c` for the C: drive. Typing anything that is *not* an accelerator still
  /// starts a search, so this only claims the few letters a menu has actually
  /// spoken for.
  final String? accelerator;

  /// What the row shows on its right: the shortcut, or the accelerator when
  /// there is no shortcut to show instead.
  String? get trailingLabel => shortcut ?? accelerator?.toUpperCase();

  final bool enabled;

  /// Takes this row out of the list it is in, where the list is one somebody
  /// can edit.
  ///
  /// **A cross on the row rather than a menu inside a menu.** The folder
  /// history is the one: a list built out of what somebody did will sooner or
  /// later hold something they would rather it did not, and the answer is one
  /// press on the row itself. Drawn only while the row is under the pointer or
  /// under the keyboard, because a row of crosses is a list that looks like a
  /// form.
  ///
  /// The row goes at once and the menu stays open — taking three folders out is
  /// three presses, not three journeys back to the same submenu.
  final VoidCallback? onRemove;

  /// Holds this row where it is, or lets it go again.
  ///
  /// **A list built out of what somebody did needs a way to say what they
  /// meant.** The folder history ranks by time, which is a good guess and is
  /// only a guess; a pin is somebody saying outright. Null where the row cannot
  /// be pinned — including where the list is already full of pins.
  final VoidCallback? onPin;

  /// Whether it is pinned **right now**.
  ///
  /// A question rather than a value, because the answer changes while the menu
  /// is open: pressing the pin has to draw the pin, and a boolean captured when
  /// the row was built would go on saying what was true before the press.
  final bool Function()? isPinned;

  /// What the pin looks like at this moment.
  bool get pinned => isPinned?.call() ?? false;

  /// What to say when the pointer rests on this row.
  ///
  /// **Because a name is not an answer.** Two folders called `src` are two
  /// different places, and a menu of names alone asks somebody to guess which
  /// one they are about to open. Null on the rows that are commands, where the
  /// label already
  /// says the whole of it.
  final String? hint;

  /// This row has been dragged [rows] places up (negative) or down.
  ///
  /// **Only rows that have an order worth changing offer it.** In the folder
  /// history that is the pinned ones: the rest are ranked by time, and a
  /// hand-placed row among them would jump the next time somebody worked
  /// somewhere. Null everywhere else, and the row is then not draggable at all
  /// — a drag that does nothing is worse than no drag.
  final void Function(int rows)? onDragged;

  /// Non-null renders a checkbox; used for toggles such as "show hidden".
  final bool? checked;

  /// Extra terms the search should match, for commands whose label does not
  /// contain the word a user would reach for.
  final List<String> keywords;

  /// Rows that belong under this one, shown as a submenu — and this row is
  /// **still a row**: it activates.
  ///
  /// **That is the whole difference from [MenuGroup].** A group can only be
  /// opened, which is right for a shelf that is not itself a destination. Home
  /// is a destination that has folders under it, and made a group it stopped
  /// being somewhere you could go: the row has to keep its letter and its
  /// journey, and unfold under the pointer or the cursor as well.
  ///
  /// So: the pointer resting on it, or the keyboard cursor landing on it,
  /// unfolds the submenu; Enter and a click still choose the row itself; Right
  /// steps into the submenu and Left comes back.
  final List<MenuNode> children;

  /// What the column of [children] is captioned, when the row's own label would
  /// say too much. Home's row carries its name and its path — useful on the
  /// row, and a caption repeating the path over its own submenu is noise.
  final String? submenuTitle;

  final VoidCallback onSelected;
}

/// A nested menu. Opens as another column of the same panel.
class MenuGroup extends MenuNode {
  const MenuGroup(this.label, this.children, {this.icon, this.enabled = true});

  final String label;
  final IconData? icon;
  final bool enabled;
  final List<MenuNode> children;
}

/// A divider, optionally captioned as a section heading.
class MenuSeparator extends MenuNode {
  const MenuSeparator([this.label]);

  final String? label;
}

/// How a menu is painted.
///
/// Passed in rather than read from settings, so the widget stays usable
/// without the app's providers around it — and so the menus follow the panel
/// palette instead of the Material scheme, which is generated from the accent
/// and would drift every time the accent changed.
class MenuAppearance {
  const MenuAppearance({
    required this.accent,
    required this.background,
    required this.foreground,
    this.border,
    this.borderWidth = 1,
    this.monolith = true,
    this.opacity = 0.6,
    this.blur = 30,
    this.blurPasses = 1,
    this.fontScale = 1,
  });

  /// Built from the ambient theme, for callers that have no palette to hand.
  factory MenuAppearance.of(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAppearance(
      accent: scheme.primary,
      background: scheme.surfaceContainerHigh,
      foreground: scheme.onSurface,
      opacity: 0.82,
      blur: 24,
    );
  }

  final Color accent;
  final Color background;
  final Color foreground;

  /// The line round the panel. Null falls back to the accent, which is what a
  /// menu raised without a palette to hand gets.
  final Color? border;

  /// How thick that line is — one, two or three.
  final int borderWidth;

  /// Whether a menu and the title it was opened from are one shape — see
  /// [AppearanceSettings.menuMonolith]. Off, they are two panels again.
  final bool monolith;

  Color get outline => border ?? accent.withValues(alpha: 0.65);

  /// How solid the surface is. The blur behind a menu is only visible through
  /// whatever this leaves see-through: at 1.0 there is no point blurring.
  final double opacity;

  final double blur;

  /// How many times the blur is applied.
  ///
  /// `BackdropFilter` paints the blurred snapshot *over* what is already
  /// there, so when the window itself is translucent the snapshot is
  /// translucent too and the sharp original keeps showing through — the blur
  /// then looks as if it never ran. Repeating the pass builds the coverage
  /// back up. See [menuAppearanceFrom], which decides how many are needed.
  final int blurPasses;

  /// The application's text size as a multiplier, so a menu is written at the
  /// size everything else is.
  ///
  /// A menu opened from a 20pt listing used to arrive at 13, because the sizes
  /// in here were written as the numbers they came out to at the default. They
  /// still are — [scaled] keeps what each of them said about the others, a
  /// shortcut hint two and a half points under a row, and lets the whole set
  /// follow the setting.
  ///
  /// A factor rather than a size, so this carries no knowledge of what the
  /// default is: it arrives already divided out.
  final double fontScale;

  double scaled(double base) => base * fontScale;

  Color get surface => background.withValues(alpha: opacity.clamp(0.0, 1.0));

  Color get muted => foreground.withValues(alpha: 0.62);
}

/// Opens a menu at [globalPosition], or below [anchorRect] when one is given.
///
/// Nesting grows the panel sideways instead of stacking floating cards on top
/// of it: every open level is a column of one surface, all the same height,
/// inside one border. The whole thing is measured before it is placed, so it
/// flips rather than spilling off screen.
///
/// Typing switches the menu into search mode.
///
/// This must never be handed data it had to wait for: build the nodes from
/// what is already known, or the menu appears to be broken rather than slow.
Future<void> showAppContextMenu({
  required BuildContext context,
  required List<MenuNode> nodes,
  Offset? globalPosition,
  Rect? anchorRect,
  String searchHint = 'Search commands',
  MenuAppearance? style,
  ValueChanged<Offset>? onPointerHover,
  ValueChanged<Offset>? onPointerDown,
  ValueChanged<bool>? onHighlighted,
  ValueChanged<MenuItem?>? onRowHighlighted,
  ValueListenable<List<MenuNode>>? live,
  bool Function(String letter)? onAccelerator,
  bool joined = false,
  double gap = 0,
}) {
  assert(globalPosition != null || anchorRect != null,
      'a menu needs somewhere to open');

  final navigator = Navigator.of(context);

  // Only ever one menu. A right-click while a menu is up does not always reach
  // the barrier — a secondary press can go straight past it to the panel —
  // and the second menu then opened on top of the first, which is what two
  // stacked menus were.
  final previous = _openMenu;
  if (previous != null && previous.isActive) {
    navigator.removeRoute(previous);
  }

  final route = _ContextMenuRoute(
    // A pointer is just a rect with no size, so both cases share one path.
    anchor: anchorRect ?? (globalPosition! & Size.zero),
    nodes: nodes,
    searchHint: searchHint,
    style: style ?? MenuAppearance.of(context),
    onPointerHover: onPointerHover,
    onPointerDown: onPointerDown,
    onHighlighted: onHighlighted,
    onRowHighlighted: onRowHighlighted,
    live: live,
    onAccelerator: onAccelerator,
    joined: joined,
    gap: gap,
    // Read where the menu is raised from, because a route has no settings of
    // its own and its length has to be fixed before it is pushed.
    duration: motionOf(context, kContextMenuAnimationDuration),
  );
  _openMenu = route;
  contextMenuIsOpen.value = true;

  return navigator.push(route).whenComplete(() {
    if (identical(_openMenu, route)) {
      _openMenu = null;
      contextMenuIsOpen.value = false;
    }
  });
}

/// The menu currently up, if any. There is at most one for the whole app, so
/// this is deliberately a single slot rather than per-widget state.
_ContextMenuRoute? _openMenu;

/// Whether a menu is on screen right now.
///
/// A menu is a route, and a route makes the page underneath stop being the
/// current one — which is how [WindowLayer] decides whether to draw the
/// internal windows. Without this, opening a menu from inside a window tore
/// the window down, taking the state that was waiting for the answer with it.
/// A menu covers nothing, so the layer watches this and carries on drawing.
final ValueNotifier<bool> contextMenuIsOpen = ValueNotifier<bool>(false);

class _ContextMenuRoute extends PopupRoute<void> {
  _ContextMenuRoute({
    required this.anchor,
    required this.nodes,
    required this.searchHint,
    required this.style,
    required this.duration,
    this.onPointerHover,
    this.onPointerDown,
    this.onHighlighted,
    this.onRowHighlighted,
    this.live,
    this.onAccelerator,
    this.joined = false,
    this.gap = 0,
  });

  final Rect anchor;
  final List<MenuNode> nodes;
  final String searchHint;
  final MenuAppearance style;

  /// Already scaled to the speed in force — see [Motion]. A route has no
  /// settings of its own, so this is handed in when it is built.
  final Duration duration;

  /// Every hover position while the menu is up, including over the barrier.
  /// A menu bar needs this to switch between its titles on hover, because the
  /// modal barrier otherwise swallows the pointer.
  final ValueChanged<Offset>? onPointerHover;

  /// Presses anywhere while the menu is up. Lets the title bar start a window
  /// drag on the same press that dismisses the menu, instead of eating it.
  final ValueChanged<Offset>? onPointerDown;

  /// Whether anything inside is picked out — the title above gives up its own
  /// fill while something in here has one.
  final ValueChanged<bool>? onHighlighted;

  /// **Which row is picked out**, every time it changes — by the keyboard, the
  /// pointer or the search alike.
  ///
  /// For a menu whose rows are worth seeing before they are chosen. The palette
  /// list applies the palette under the highlight as it is walked, so choosing
  /// one is looking at it rather than reading its name and finding out
  /// afterwards; closing without choosing puts back what was there.
  ///
  /// Separate from [onHighlighted], which answers a different question — is
  /// *anything* picked out — for the menu bar's titles.
  final ValueChanged<MenuItem?>? onRowHighlighted;

  /// A menu whose rows can change while it is open.
  ///
  /// **For a list that is about the world rather than about the application.**
  /// The drive menu is the one: a stick put in while the menu is up is a stick
  /// that should appear in it, and a menu that can only be right at the moment
  /// it opened is a menu somebody has to close and open again to trust.
  ///
  /// Only the outermost column is replaced, and only while it is the one being
  /// read — a list that rearranged itself under an open submenu would take away
  /// the row the submenu came from. A change that arrives while somebody is one
  /// level in waits until they come back out.
  final ValueListenable<List<MenuNode>>? live;

  /// Where an `Alt+<letter>` pressed while this menu is open is sent. Answering
  /// true means the letter was taken; the menu then leaves the press alone.
  final bool Function(String letter)? onAccelerator;

  /// Whether the anchor is a title on the strip, to be taken into the same
  /// outline as the panel.
  final bool joined;

  /// How far below the anchor the panel stands.
  ///
  /// Zero where the two are one shape — a gap in a shape is two shapes. With
  /// the monolith switched off it is five pixels, because two separate panels
  /// touching along an edge read as one that failed to join.
  final double gap;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => tr('Dismiss menu');

  @override
  Duration get transitionDuration => duration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _ContextMenuOverlay(
      anchor: anchor,
      nodes: nodes,
      searchHint: searchHint,
      style: style,
      onPointerHover: onPointerHover,
      onPointerDown: onPointerDown,
      onHighlighted: onHighlighted,
      onRowHighlighted: onRowHighlighted,
      live: live,
      onAccelerator: onAccelerator,
      joined: joined,
      gap: gap,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      // The unrolling itself is inside the overlay, which is the only thing
      // that knows whether the panel drops down or flips up; a fade over the
      // top of it keeps the first frame from being a hard edge.
      FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: kArrivingCurve),
        child: child,
      );
}

/// One column of the panel.
class _Level {
  _Level({required this.nodes, this.title});

  final List<MenuNode> nodes;

  /// The group this column came from; captioned at its head.
  final String? title;

  /// Row the keyboard is on.
  int highlighted = -1;

  /// Row whose column is open to the right, drawn filled so the trail through
  /// a deep menu stays visible.
  int openChild = -1;
}

class _ContextMenuOverlay extends StatefulWidget {
  const _ContextMenuOverlay({
    required this.anchor,
    required this.nodes,
    required this.searchHint,
    required this.style,
    this.joined = false,
    this.gap = 0,
    this.onPointerHover,
    this.onPointerDown,
    this.onHighlighted,
    this.onRowHighlighted,
    this.live,
    this.onAccelerator,
  });

  final Rect anchor;
  final List<MenuNode> nodes;
  final String searchHint;
  final MenuAppearance style;

  /// Whether the anchor is a title on the menu strip, to be taken into the
  /// same outline. See [_MenuOutline].
  final bool joined;

  /// How far below its anchor the panel stands. See [_ContextMenuRoute.gap].
  final double gap;

  final ValueChanged<Offset>? onPointerHover;
  final ValueChanged<Offset>? onPointerDown;

  /// See [_ContextMenuRoute.onRowHighlighted].
  final ValueChanged<MenuItem?>? onRowHighlighted;

  /// See [_ContextMenuRoute.live].
  final ValueListenable<List<MenuNode>>? live;

  /// Told whenever a row inside the menu becomes, or stops being, the one the
  /// pointer or the keyboard is on: while something in here is picked out, the
  /// title above it gives its own fill up and keeps only the frame.
  final ValueChanged<bool>? onHighlighted;

  /// Where an `Alt+<letter>` pressed while this menu is open is sent. Answering
  /// true means the letter was taken; the menu then leaves the press alone.
  final bool Function(String letter)? onAccelerator;

  @override
  State<_ContextMenuOverlay> createState() => _ContextMenuOverlayState();
}

class _ContextMenuOverlayState extends State<_ContextMenuOverlay> {
  late final List<_Level> _levels = [_Level(nodes: widget.nodes)];

  @override
  void initState() {
    super.initState();
    widget.live?.addListener(_liveNodes);
  }

  /// Rows that arrived while a submenu was open, waiting for it to close.
  List<MenuNode>? _waiting;

  /// The outermost column has been given a new list of rows.
  ///
  /// **Only while it is the column being read.** Replacing it under an open
  /// submenu would take away the row that submenu came from, and the reader is
  /// looking at the submenu rather than at the list that changed — so the new
  /// rows wait, and are taken the moment the submenu closes.
  ///
  /// The highlight is kept **by what it was on** rather than by its index: a
  /// disk appearing above the row somebody is standing on must not move them
  /// down a row, which is what keeping the number would do.
  void _liveNodes() {
    final rows = widget.live?.value;
    if (rows == null) return;
    if (_levels.length > 1 || _searching) {
      _waiting = rows;
      return;
    }
    _waiting = null;

    final level = _levels.first;
    final was = level.highlighted >= 0 && level.highlighted < level.nodes.length
        ? _labelOf(level.nodes[level.highlighted])
        : null;

    final fresh = _Level(nodes: rows, title: level.title);
    if (was != null) {
      for (var i = 0; i < rows.length; i++) {
        if (_labelOf(rows[i]) == was) {
          fresh.highlighted = i;
          break;
        }
      }
    }
    setState(() => _levels[0] = fresh);
  }

  /// The panel itself, so the outline can be drawn round where it actually
  /// ended up — it is placed by a delegate and it grows as it unrolls.
  final GlobalKey _panel = GlobalKey();

  /// Where the panel is on screen this frame, or null before it has been laid
  /// out. Read at paint time, which is after layout, so it is never stale.
  Rect? _panelRect() {
    final box = _panel.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Whether anything in the menu is picked out at the moment.
  bool get _anyHighlighted =>
      _searching ? _matches.isNotEmpty : _levels.any((l) => l.highlighted >= 0);

  bool _said = false;

  /// Says it once per change, and never during a build.
  void _tellHighlight() {
    final now = _anyHighlighted;
    if (now == _said) return;
    _said = now;
    widget.onHighlighted?.call(now);
  }

  MenuItem? _saidRow;

  /// The row picked out at the moment, whatever picked it.
  MenuItem? get _highlightedRow {
    if (_searching) {
      return _matchIndex >= 0 && _matchIndex < _matches.length
          ? _matches[_matchIndex].item
          : null;
    }
    for (final level in _levels.reversed) {
      if (level.highlighted < 0 || level.highlighted >= level.nodes.length) {
        continue;
      }
      final node = level.nodes[level.highlighted];
      return node is MenuItem ? node : null;
    }
    return null;
  }

  /// **Reported from the frame rather than from the events that cause it.**
  /// The highlight moves for three different reasons — an arrow key, the
  /// pointer, a search narrowing to one row — and hooking each of them is three
  /// places to forget. What the frame shows is one place, and it is the truth.
  void _tellRowHighlight() {
    if (widget.onRowHighlighted == null) return;
    final now = _highlightedRow;
    if (identical(now, _saidRow)) return;
    _saidRow = now;
    widget.onRowHighlighted!.call(now);
  }

  final TextEditingController _query = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'menu-search');

  /// Search has no visible field until the user types, so the menu opens as a
  /// plain cascade and becomes a palette on demand.
  bool _searching = false;

  List<_Match> _matches = const [];
  int _matchIndex = 0;

  Timer? _closeTimer;

  /// Fixed on the first build: the direction must not change as the panel
  /// grows, or opening a column makes the whole menu jump.
  _Placement? _placement;

  _Placement _placementFor(BuildContext context) => _placement ??=
      _MenuLayoutDelegate.decide(
        MediaQuery.sizeOf(context),
        widget.anchor,
        MediaQuery.paddingOf(context),
      );

  @override
  void dispose() {
    _closeTimer?.cancel();
    widget.live?.removeListener(_liveNodes);
    _query.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // --- Search -------------------------------------------------------------

  void _beginSearch(String seed) {
    setState(() {
      _searching = true;
      _query.text = seed;
      _query.selection = TextSelection.collapsed(offset: seed.length);
      _matches = _searchNodes(widget.nodes, seed);
      _matchIndex = 0;
      // Searching collapses the columns back to one flat list.
      if (_levels.length > 1) _levels.removeRange(1, _levels.length);
      _levels.first.openChild = -1;
    });
  }

  void _endSearch() {
    setState(() {
      _searching = false;
      _query.clear();
      _matches = const [];
      _matchIndex = 0;
    });
  }

  void _onQueryChanged(String value) {
    if (value.isEmpty) {
      _endSearch();
      return;
    }
    setState(() {
      _matches = _searchNodes(widget.nodes, value.trim());
      _matchIndex = 0;
    });
  }

  // --- Columns ------------------------------------------------------------

  /// Unfolds the rows under one row, whichever kind of row it is: a shelf that
  /// exists only to be opened, or an item that is a destination *and* has
  /// places under it. See [MenuItem.children].
  void _openChildren(
    String title,
    List<MenuNode> children,
    int levelIndex,
    int nodeIndex,
  ) {
    _cancelScheduledClose();
    // Re-entering the row that is already open must not rebuild the cascade.
    if (_levels[levelIndex].openChild == nodeIndex &&
        _levels.length > levelIndex + 1) {
      return;
    }
    setState(() {
      if (_levels.length > levelIndex + 1) {
        _levels.removeRange(levelIndex + 1, _levels.length);
      }
      _levels[levelIndex].openChild = nodeIndex;
      _levels.add(_Level(nodes: children, title: title));
    });
  }

  /// The rows under [node], or empty when it has none.
  static List<MenuNode> _childrenOf(MenuNode node) => switch (node) {
    MenuGroup(:final children) => children,
    MenuItem(:final children) => children,
    _ => const [],
  };

  /// What a column of children is captioned with.
  static String _labelOf(MenuNode node) => switch (node) {
    MenuGroup(:final label) => label,
    MenuItem(:final submenuTitle, :final label) => submenuTitle ?? label,
    _ => '',
  };

  /// Moving onto a plain row should eventually close whatever a sibling had
  /// opened — but not at once, and not quickly.
  ///
  /// The path from a group row to its column almost always crosses a sibling,
  /// so closing on the first hover made nested menus impossible to reach. The
  /// delay is cancelled the moment the pointer lands anywhere in the panel.
  ///
  /// It has to be generous. A quarter of a second is less time than it takes
  /// to look at the column, decide, and move to it — the column vanished
  /// mid-journey, and the only way that leaves is to click the group, which is
  /// not how a menu is used. Long enough to walk there beats tidy.
  static const Duration closeGrace = Duration(milliseconds: 900);

  void _scheduleCloseBelow(int levelIndex) {
    if (_levels.length <= levelIndex + 1) return;
    _closeTimer?.cancel();
    _closeTimer = Timer(closeGrace, () {
      if (!mounted || _levels.length <= levelIndex + 1) return;
      setState(() {
        _levels.removeRange(levelIndex + 1, _levels.length);
        _levels[levelIndex].openChild = -1;
      });
    });
  }

  void _cancelScheduledClose() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  void _closeDeepest() {
    if (_searching) {
      _endSearch();
      return;
    }
    if (_levels.length <= 1) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _levels.removeLast();
      _levels.last.openChild = -1;
    });
  }

  void _activate(MenuItem item) {
    if (!item.enabled) return;
    Navigator.of(context).pop();
    item.onSelected();
  }

  // --- Keyboard -----------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        _closeDeepest();
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowDown:
        _moveHighlight(1);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.arrowUp:
        _moveHighlight(-1);
        return KeyEventResult.handled;

      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _activateHighlighted();
        return KeyEventResult.handled;

      // **Delete takes the highlighted row out of its list**, where the list
      // is one that can be edited. Rule number one: a control the keyboard
      // cannot reach does not exist, and the cross beside the row is a control.
      //
      // Only claimed when the row under the keyboard actually offers it, so
      // Delete goes on meaning nothing in every other menu, and goes on
      // reaching the search box while one is being typed in.
      case LogicalKeyboardKey.delete:
        if (_searching) return KeyEventResult.ignored;
        return _removeHighlighted()
            ? KeyEventResult.handled
            : KeyEventResult.ignored;

      // **Insert pins the highlighted row**, where the row offers it. Insert is
      // already the application's "mark this one" key in the panels, and
      // pinning is marking — so it is the same word rather than a new one.
      // Claimed only where the row can be pinned, so it goes on meaning nothing
      // everywhere else.
      case LogicalKeyboardKey.insert:
        if (_searching) return KeyEventResult.ignored;
        return _pinHighlighted()
            ? KeyEventResult.handled
            : KeyEventResult.ignored;

      case LogicalKeyboardKey.arrowLeft:
        // Only steal Left when it cannot mean "move the caret".
        if (!_searching && _levels.length > 1) {
          _closeDeepest();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;

      case LogicalKeyboardKey.arrowRight:
        if (!_searching) {
          _openHighlightedGroup();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
    }

    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    // **Alt+F then Alt+C reaches Commands.** A menu is a route and sits above
    // the screen's own key handler, so while one is open the accelerator has
    // nobody to reach — which is why a started sequence could not be changed
    // its mind about, only escaped from. The route hands the letter back to
    // whoever raised it, and the strip decides what to do with it.
    //
    // The *physical* key, not the character: with a non-Latin layout in force
    // the key marked F composes a letter of that alphabet, and a menu bar that
    // stopped working when the layout was switched would be worse than one
    // that never answered Alt at all.
    if (keys.isAltPressed) {
      final letter = bindingLetter(event);
      final ask = widget.onAccelerator;
      if (letter != null && ask != null && ask(letter)) {
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Once a search is on, the query is edited from here unless the field itself
    // has the keyboard.
    //
    // It never used to. The field is created with `autofocus`, and nothing in the
    // chain hands it the focus — measured: after the first letter the primary
    // focus was still null. And because this branch only ran while *not*
    // searching, every letter after the first was dropped and Escape was the only
    // key that did anything. One letter in, no way out.
    if (_searching && !_searchFocus.hasFocus) {
      if (event.logicalKey == LogicalKeyboardKey.backspace) {
        final query = _query.text;
        _setQuery(query.isEmpty ? '' : query.substring(0, query.length - 1));
        return KeyEventResult.handled;
      }
      final typed = _printable(event);
      if (typed != null) {
        _setQuery(_query.text + typed);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (!_searching) {
      final typed = _printable(event);
      if (typed != null) {
        // A row that claimed this letter wins it — the *first* keypress is an
        // accelerator before it is a search. Everything else turns the cascade
        // into a search.
        //
        // The key's own position is asked after the character it composed, so
        // `C` picks the C: drive whatever language the keyboard is in — an
        // accelerator is about the key under the finger, not about the letter
        // the layout made of it. The layout still goes first, so a board that
        // really does put the letter elsewhere keeps it.
        final claimed =
            _acceleratorFor(typed) ?? _acceleratorForKey(event.physicalKey);
        if (claimed != null) {
          _activate(claimed);
        } else {
          _beginSearch(typed);
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// The character this key would type, or null if it types nothing.
  ///
  /// A space counts: names have spaces in them, and a search that cannot take one
  /// stops at the first word.
  String? _printable(KeyEvent event) {
    final character = event.character;
    if (character == null || character.length != 1) return null;
    if (character == '\n' || character == '\r' || character == '\t') return null;
    return character;
  }

  /// Puts [value] in the field and re-runs the search, as typing into it would.
  void _setQuery(String value) {
    if (value.isEmpty) {
      _endSearch();
      return;
    }
    _query
      ..text = value
      ..selection = TextSelection.collapsed(offset: value.length);
    _onQueryChanged(value);
  }

  /// The item in the open column that answers to the *key* [key], read without
  /// the keyboard layout. See [layoutIndependentLetter].
  MenuItem? _acceleratorForKey(PhysicalKeyboardKey key) {
    final letter = layoutIndependentLetter(key);
    return letter == null ? null : _acceleratorFor(letter);
  }

  /// The item in the open column that answers to [character], if any.
  MenuItem? _acceleratorFor(String character) {
    final wanted = character.toLowerCase();
    for (final node in _levels.last.nodes) {
      if (node is MenuItem &&
          node.enabled &&
          node.accelerator?.toLowerCase() == wanted) {
        return node;
      }
    }
    return null;
  }

  void _moveHighlight(int delta) {
    setState(() {
      if (_searching) {
        if (_matches.isEmpty) return;
        _matchIndex = (_matchIndex + delta) % _matches.length;
        if (_matchIndex < 0) _matchIndex += _matches.length;
        return;
      }

      final level = _levels.last;
      final selectable = <int>[
        for (var i = 0; i < level.nodes.length; i++)
          if (level.nodes[i] is! MenuSeparator) i,
      ];
      if (selectable.isEmpty) return;

      final current = selectable.indexOf(level.highlighted);
      var next = current < 0
          ? (delta > 0 ? 0 : selectable.length - 1)
          : (current + delta) % selectable.length;
      if (next < 0) next += selectable.length;
      level.highlighted = selectable[next];
    });
    _unfoldHighlighted();
  }

  /// **The cursor landing on a row shows what is under it**, the way resting
  /// the pointer there does. A row with nothing
  /// under it closes whatever the last one had opened, or the column would
  /// stand there describing a row the cursor has left.
  void _unfoldHighlighted() {
    if (_searching) return;
    final levelIndex = _levels.length - 1;
    final level = _levels[levelIndex];
    if (level.highlighted < 0 || level.highlighted >= level.nodes.length) return;

    final node = level.nodes[level.highlighted];
    final children = _childrenOf(node);
    if (children.isEmpty) {
      _closeBelow(levelIndex);
      return;
    }
    _openChildren(_labelOf(node), children, levelIndex, level.highlighted);
  }

  /// Shuts the columns under [levelIndex] at once.
  ///
  /// The pointer's own version of this waits — see [closeGrace], because the
  /// way to a submenu crosses its siblings. The keyboard has no such journey:
  /// it is either on the row or it is not.
  void _closeBelow(int levelIndex) {
    _cancelScheduledClose();
    if (_levels.length <= levelIndex + 1) return;
    setState(() {
      _levels.removeRange(levelIndex + 1, _levels.length);
      _levels[levelIndex].openChild = -1;
    });
  }

  /// Takes the row under the keyboard out of its column, if it offers that.
  ///
  /// Answers whether it did, so the key is only claimed where it means
  /// something.
  bool _removeHighlighted() {
    if (_levels.isEmpty) return false;
    final level = _levels.last;
    if (level.highlighted < 0 || level.highlighted >= level.nodes.length) {
      return false;
    }
    final node = level.nodes[level.highlighted];
    if (node is! MenuItem || node.onRemove == null) return false;

    _removeRow(_levels.length - 1, level.highlighted);
    node.onRemove!();
    return true;
  }

  /// Pins the row under the keyboard, or lets it go. Answers whether it could.
  ///
  /// **The row is left where it is.** Pinning moves it in the list it came
  /// from, and the list is rebuilt the next time the menu opens; moving it
  /// under the hand while somebody is looking at it would take away the row
  /// they were about to press. Only the pin changes, and the order settles on
  /// the way back in.
  bool _pinHighlighted() {
    if (_levels.isEmpty) return false;
    final level = _levels.last;
    if (level.highlighted < 0 || level.highlighted >= level.nodes.length) {
      return false;
    }
    final node = level.nodes[level.highlighted];
    if (node is! MenuItem || node.onPin == null) return false;

    node.onPin!();
    // The row draws its own pin from [MenuItem.isPinned], so this only has to
    // ask for a frame.
    setState(() {});
    return true;
  }

  /// Puts a row somewhere else in its own column.
  ///
  /// **The column is rearranged rather than rebuilt**, for the reason the
  /// removal is: the list these rows came from is only read when the menu
  /// opens, and rebuilding it under the hand would close the column somebody is
  /// standing in. The highlight travels with the row, because the row is what
  /// they were holding.
  void _moveRow(int levelIndex, int from, int to) {
    setState(() {
      final level = _levels[levelIndex];
      final rows = [...level.nodes];
      final node = rows.removeAt(from);
      rows.insert(to, node);

      final fresh = _Level(nodes: rows, title: level.title)..highlighted = to;
      _levels[levelIndex] = fresh;
      if (_levels.length > levelIndex + 1) {
        _levels.removeRange(levelIndex + 1, _levels.length);
      }
    });
  }

  /// Takes one row out of one column, and keeps the menu usable afterwards.
  ///
  /// **The row goes at once**, rather than the whole menu being rebuilt from
  /// wherever the rows came from. Taking three folders out of a list is three
  /// presses, and a rebuild between each of them would close the column they
  /// are in and send the reader back down through the cascade twice.
  ///
  /// The highlight stays where it is, which now means the row *below* the one
  /// that went — the same thing every list does when a row is deleted, and the
  /// only choice that lets three in a row be taken out without moving the hand.
  void _removeRow(int levelIndex, int index) {
    setState(() {
      final level = _levels[levelIndex];
      final rows = [...level.nodes]..removeAt(index);

      // Nothing left to look at. The column closes and, if it was the last one,
      // so does the menu — a column with nothing in it is a column that says
      // the list is empty by being empty, which nobody can read.
      if (rows.isEmpty) {
        if (levelIndex == 0) {
          Navigator.of(context).maybePop();
          return;
        }
        _levels.removeRange(levelIndex, _levels.length);
        _levels[levelIndex - 1].openChild = -1;
        return;
      }

      final fresh = _Level(nodes: rows, title: level.title)
        ..highlighted = index >= rows.length ? rows.length - 1 : index;
      _levels[levelIndex] = fresh;
      // Anything that was open below this row is about a row that has gone.
      if (_levels.length > levelIndex + 1) {
        _levels.removeRange(levelIndex + 1, _levels.length);
      }
    });
  }

  void _activateHighlighted() {
    if (_searching) {
      if (_matches.isEmpty) return;
      _activate(_matches[_matchIndex].item);
      return;
    }

    final level = _levels.last;
    if (level.highlighted < 0 || level.highlighted >= level.nodes.length) return;
    final node = level.nodes[level.highlighted];
    // **An item is chosen even when it has rows under it.** Enter on Home goes
    // home; the folders under it are reached with Right, or with the pointer.
    // A group has nowhere of its own to go, so Enter opens it.
    if (node is MenuItem) _activate(node);
    if (node is MenuGroup) _openHighlightedGroup();
  }

  /// Right, and Enter on a shelf: step into whatever is under this row.
  void _openHighlightedGroup() {
    final levelIndex = _levels.length - 1;
    final level = _levels[levelIndex];
    if (level.highlighted < 0) return;
    final node = level.nodes[level.highlighted];
    final children = _childrenOf(node);
    if (children.isEmpty) return;
    _openChildren(_labelOf(node), children, levelIndex, level.highlighted);
    // Right *enters* the column: without this the cursor stayed on the row it
    // came from and Down walked the wrong level.
    setState(() => _levels.last.highlighted = _firstSelectable(_levels.last));
  }

  static int _firstSelectable(_Level level) {
    for (var i = 0; i < level.nodes.length; i++) {
      if (level.nodes[i] is! MenuSeparator) return i;
    }
    return -1;
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // After the frame, never during it: a listener that repaints the whole
    // application is not something to run inside a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _tellRowHighlight();
      // Rows that arrived while a submenu was open, taken now that it is not.
      // Read off the frame rather than hooked into each of the four places a
      // column closes — the same reason the highlight is reported this way.
      if (_waiting != null && _levels.length == 1 && !_searching) _liveNodes();
    });

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          // Reports pointer activity across the whole screen, including over
          // the modal barrier, which otherwise hides it completely. Translucent
          // so it observes without consuming anything.
          if (widget.onPointerHover != null || widget.onPointerDown != null)
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerHover: (event) =>
                    widget.onPointerHover?.call(event.position),
                onPointerDown: (event) =>
                    widget.onPointerDown?.call(event.position),
              ),
            ),
          CustomSingleChildLayout(
            delegate: _MenuLayoutDelegate(
              anchor: widget.anchor,
              padding: MediaQuery.paddingOf(context),
              placement: _placementFor(context),
              gap: widget.gap,
            ),
            child: MouseRegion(
              onEnter: (_) => _cancelScheduledClose(),
              // Unrolled from whichever edge is against the anchor, so the
              // panel grows away from what was clicked rather than towards
              // it, and clipped so it never paints the rows it has not made
              // room for yet.
              //
              // An Align with both factors, not a SizeTransition: that one
              // leaves the width to the constraints, and the panel here is
              // laid out by its own delegate from the size it reports — a
              // full-width report moved the whole menu sideways.
              child: AnimatedBuilder(
                animation: _unroll(context),
                builder: (context, child) => ClipRect(
                  key: const ValueKey('menu-unroll'),
                  child: Align(
                    alignment: _placementFor(context).down
                        ? Alignment.topCenter
                        : Alignment.bottomCenter,
                    heightFactor: _unroll(context).value.clamp(0.05, 1.0),
                    widthFactor: 1,
                    child: child,
                  ),
                ),
                child: _MenuSurface(
                  key: _panel,
                  clipper: widget.joined
                      ? _MenuClip(
                          panel: _panelRect,
                          anchor: widget.anchor,
                          joined: true,
                        )
                      : null,
                  levels: _levels,
                  style: widget.style,
                  searching: _searching,
                  matches: _matches,
                  matchIndex: _matchIndex,
                  searchHint: widget.searchHint,
                  queryController: _query,
                  searchFocus: _searchFocus,
                  onQueryChanged: _onQueryChanged,
                  onActivate: _activate,
                  onOpenGroup: _openChildren,
                  onCloseBelow: _scheduleCloseBelow,
                  onRemoveRow: _removeRow,
                  onMoveRow: _moveRow,
                  onHighlight: (levelIndex, index) {
                    setState(() {
                      if (_searching) {
                        _matchIndex = index;
                      } else {
                        _levels[levelIndex].highlighted = index;
                      }
                    });
                    _tellHighlight();
                  },
                ),
              ),
            ),
          ),
          // The line round the lot, painted last so nothing draws over it and
          // nothing clips it. It takes no pointer: it is a line.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _MenuOutline(
                  panel: _panelRect,
                  anchor: widget.anchor,
                  joined: widget.joined,
                  colour: widget.style.outline,
                  width: widget.style.borderWidth.toDouble(),
                  radius: _MenuSurface.radius,
                  // The panel grows as it unrolls, so the line has to be
                  // redrawn with it rather than once at the end.
                  repaint: _unroll(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// How far the panel has unrolled, as an animation the transition can drive.
  ///
  /// Taken from the route rather than from a controller of our own: the menu
  /// is a route, so it already has an animation, and two of them would drift.
  Animation<double> _unroll(BuildContext context) {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null) return const AlwaysStoppedAnimation<double>(1);
    return CurvedAnimation(parent: animation, curve: kArrivingCurve);
  }
}

/// The outline of a menu — and of the title it belongs to, when it has one,
/// because then they are **one element**.
///
/// An item of the main menu and the context menu under it are one element to
/// look at, so there is one path: up the shared left edge without a corner,
/// round the
/// title, and back down into the panel through a rounded junction on each side
/// the title does not sit flush against.
///
/// Built in global coordinates and used twice — stroked over everything as the
/// line, and handed to the panel as its clip so its fill stops exactly where
/// the line does. A fill that squares off inside a curved outline is two
/// shapes again.
Path menuJoinPath({
  required Rect panel,
  required Rect anchor,
  required bool joined,
  required double radius,
  double inset = 0,
}) {
  final p = panel.deflate(inset);
  final r = Radius.circular(radius);

  // Joined only where the two really meet: a panel that had to slide, or one
  // that opened above or beside its title, is a panel on its own.
  final meets =
      joined &&
      (panel.top - anchor.bottom).abs() <= 2 &&
      anchor.right > panel.left &&
      anchor.left < panel.right;

  if (!meets) {
    return Path()..addRRect(RRect.fromRectAndRadius(p, r));
  }

  final a = Rect.fromLTRB(
    anchor.left + inset,
    anchor.top + inset,
    anchor.right - inset,
    p.top,
  );

  // Flush on a side means the two left (or right) edges are one line, and a
  // corner there would be a corner in the middle of a straight edge.
  final leftFlush = (a.left - p.left).abs() < 1;
  final rightFlush = (a.right - p.right).abs() < 1;

  // How round the junction is. The same number as every other corner here, so
  // the shape reads as one thing drawn with one pen.
  final f = radius;

  final path = Path()..moveTo(p.left, p.bottom - radius);
  path
    ..arcToPoint(
      Offset(p.left + radius, p.bottom),
      radius: r,
      clockwise: false,
    )
    ..lineTo(p.right - radius, p.bottom)
    ..arcToPoint(Offset(p.right, p.bottom - radius), radius: r, clockwise: false)
    ..lineTo(p.right, p.top + (rightFlush ? 0 : radius));

  if (rightFlush) {
    // The title reaches the panel's right edge: the two right edges are one
    // line, so there is no corner and no junction on this side.
    path.lineTo(a.right, a.top + radius);
  } else {
    path
      ..arcToPoint(Offset(p.right - radius, p.top), radius: r, clockwise: false)
      // The junction: the panel's top edge curves up into the title's side.
      // Concave, so it is drawn the other way round from every corner above.
      ..lineTo(a.right + f, p.top)
      ..arcToPoint(
        Offset(a.right, p.top - f),
        radius: Radius.circular(f),
        clockwise: true,
      )
      ..lineTo(a.right, a.top + radius);
  }

  // The title itself.
  path
    ..arcToPoint(Offset(a.right - radius, a.top), radius: r, clockwise: false)
    ..lineTo(a.left + radius, a.top)
    ..arcToPoint(Offset(a.left, a.top + radius), radius: r, clockwise: false);

  if (leftFlush) {
    // Straight down the shared edge, all the way.
    path.lineTo(p.left, p.bottom - radius);
  } else {
    path
      ..lineTo(a.left, p.top - f)
      ..arcToPoint(
        Offset(a.left - f, p.top),
        radius: Radius.circular(f),
        clockwise: true,
      )
      ..lineTo(p.left + radius, p.top)
      ..arcToPoint(Offset(p.left, p.top + radius), radius: r, clockwise: false)
      ..lineTo(p.left, p.bottom - radius);
  }

  return path..close();
}

/// Draws [menuJoinPath] over the menu and its title.
///
/// Painted in the route's own layer rather than as a border on the panel,
/// because the panel is clipped to its own shape — a stroke on it is half cut
/// away — and because half of this line is somewhere the panel is not.
class _MenuOutline extends CustomPainter {
  _MenuOutline({
    required this.panel,
    required this.anchor,
    required this.joined,
    required this.colour,
    required this.width,
    required this.radius,
    super.repaint,
  });

  /// Where the panel is, in the coordinates this paints in. Null while the
  /// first frame is still being laid out.
  final ValueGetter<Rect?> panel;

  /// The title the menu hangs off, if it hangs off one.
  final Rect anchor;

  final bool joined;
  final Color colour;
  final double width;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = panel();
    if (rect == null || rect.isEmpty) return;

    canvas.drawPath(
      menuJoinPath(
        panel: rect,
        anchor: anchor,
        joined: joined,
        radius: radius,
        // Half a stroke in, so the line lands *on* the shape rather than
        // straddling it: a centred stroke puts half of itself outside, which is
        // a one-pixel line drawn as two half-lit rows.
        inset: width / 2,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = colour,
    );
  }

  @override
  bool shouldRepaint(_MenuOutline old) =>
      old.anchor != anchor ||
      old.joined != joined ||
      old.colour != colour ||
      old.width != width;
}

/// Clips the panel to the shape the outline draws, so its fill ends where the
/// line does — including inside the junction curves.
class _MenuClip extends CustomClipper<Path> {
  _MenuClip({required this.panel, required this.anchor, required this.joined});

  final ValueGetter<Rect?> panel;
  final Rect anchor;
  final bool joined;

  @override
  Path getClip(Size size) {
    final rect = panel();
    // Before the first layout there is nothing to place the join against, and
    // a plain rounded rectangle is what a menu is anyway.
    if (rect == null || rect.isEmpty) {
      return Path()
        ..addRRect(
          RRect.fromRectAndRadius(
            Offset.zero & size,
            const Radius.circular(_MenuSurface.radius),
          ),
        );
    }
    return menuJoinPath(
      panel: rect,
      anchor: anchor,
      joined: joined,
      radius: _MenuSurface.radius,
    ).shift(-rect.topLeft);
  }

  @override
  bool shouldReclip(_MenuClip old) =>
      old.anchor != anchor || old.joined != joined;
}

/// Which way the panel opens. Decided once, when the menu appears.
class _Placement {
  const _Placement({required this.down, required this.right});

  final bool down;
  final bool right;
}

/// Places the panel next to its anchor.
///
/// The **direction** is fixed for the life of the menu: recomputing it as
/// columns opened made the whole panel jump around the moment a submenu made
/// it too tall to fit. The *position* is not fixed. The panel grows from the
/// anchored edge and, when it outgrows the room on that side, slides back by
/// exactly the overflow — never further, and never the other way. That is a
/// continuous movement of at most the amount that would otherwise have hung
/// off the screen, where a flip was a jump of the panel's whole width.
///
/// Only a panel too big for the screen itself is capped, and then its columns
/// scroll. Before, everything that did not fit *beside the anchor* scrolled,
/// so a cascade opened near the bottom of the screen was stuck in a couple of
/// hundred pixels with most of the desk empty above it.
class _MenuLayoutDelegate extends SingleChildLayoutDelegate {
  _MenuLayoutDelegate({
    required this.anchor,
    required this.padding,
    required this.placement,
    this.gap = 0,
  });

  final Rect anchor;
  final EdgeInsets padding;
  final _Placement placement;

  /// Room left between the anchor and the panel. See [_ContextMenuRoute.gap].
  final double gap;

  static const double margin = 8;

  /// Below this a menu is too cramped to be worth opening downwards.
  static const double minimumHeight = 140;

  /// Picks the side with more room, preferring down and right.
  static _Placement decide(Size screen, Rect anchor, EdgeInsets padding) {
    final below = screen.height - padding.bottom - margin - anchor.bottom;
    final above = anchor.top - padding.top - margin;
    return _Placement(
      down: below >= minimumHeight || below >= above,
      right: true,
    );
  }

  /// The room the whole screen has, which is what bounds the panel now — not
  /// the room on the anchored side, which is what it may slide out of.
  double _usableHeight(Size screen) =>
      screen.height - padding.top - padding.bottom - margin * 2;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(Size(
      constraints.maxWidth - margin * 2,
      _usableHeight(constraints.biggest).clamp(80.0, constraints.maxHeight),
    ));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = margin;
    final right = size.width - childSize.width - margin;
    final top = padding.top + margin;
    final bottom = size.height - padding.bottom - margin - childSize.height;

    // Where the panel would sit if the screen were endless: against the edge
    // it was told to grow from. Everything below is the slide back onto the
    // screen, and a clamp moves it by exactly the overflow and no more.
    final x = placement.right ? anchor.left : anchor.left - childSize.width;
    final y = placement.down
        ? anchor.bottom + gap
        : anchor.top - childSize.height - gap;

    // A panel wider or taller than the screen has no position that fits, so it
    // goes to the top left corner and scrolls from there.
    return Offset(
      right < left ? left : x.clamp(left, right),
      bottom < top ? top : y.clamp(top, bottom),
    );
  }

  @override
  bool shouldRelayout(_MenuLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      placement.down != oldDelegate.placement.down ||
      placement.right != oldDelegate.placement.right;
}

/// The panel: one border, one blur, one row of equal-height columns.
class _MenuSurface extends StatelessWidget {
  const _MenuSurface({
    super.key,
    this.clipper,
    required this.levels,
    required this.style,
    required this.searching,
    required this.matches,
    required this.matchIndex,
    required this.searchHint,
    required this.queryController,
    required this.searchFocus,
    required this.onQueryChanged,
    required this.onActivate,
    required this.onOpenGroup,
    required this.onCloseBelow,
    required this.onHighlight,
    required this.onRemoveRow,
    required this.onMoveRow,
  });

  /// The shape to cut the panel to. Null is the ordinary rounded rectangle;
  /// a menu joined to its title is cut to the shape they make together.
  final CustomClipper<Path>? clipper;

  final List<_Level> levels;
  final MenuAppearance style;
  final bool searching;
  final List<_Match> matches;
  final int matchIndex;
  final String searchHint;
  final TextEditingController queryController;
  final FocusNode searchFocus;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<MenuItem> onActivate;
  final void Function(
    String title,
    List<MenuNode> children,
    int levelIndex,
    int nodeIndex,
  ) onOpenGroup;
  final ValueChanged<int> onCloseBelow;
  final void Function(int levelIndex, int index) onHighlight;

  /// Takes one row out of one column. See [_ContextMenuOverlayState._removeRow].
  final void Function(int levelIndex, int index) onRemoveRow;

  /// Moves one row within one column. See [_ContextMenuOverlayState._moveRow].
  final void Function(int levelIndex, int from, int to) onMoveRow;


  static const double radius = kMenuCornerRadius;
  static const double columnWidth = 232;
  static const double rowHeight = 28;

  /// Rows are inset so their highlight reads as a pill inside the column
  /// rather than a band across it.
  static const EdgeInsets rowMargin =
      EdgeInsets.symmetric(horizontal: 5, vertical: 1);

  /// From the top of one row to the top of the next — the height and the gap
  /// between. What a row being carried is measured in.
  static double get rowPitch => rowHeight + rowMargin.vertical;

  static final BorderRadius pill = BorderRadius.circular(rowHeight / 2);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = BorderRadius.circular(radius);

    final clip = clipper;
    if (clip != null) {
      return ClipPath(
        clipper: clip,
        child: blurredBackdrop(
          sigma: style.blur,
          passes: style.blurPasses,
          child: ColoredBox(
            color: style.surface,
            child: Material(
              type: MaterialType.transparency,
              child: searching
                  ? SizedBox(
                      width: columnWidth + 60,
                      child: _buildSearch(context),
                    )
                  : _buildColumns(context, scheme),
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: shape,
      child: blurredBackdrop(
        sigma: style.blur,
        passes: style.blurPasses,
        child: DecoratedBox(
          decoration: BoxDecoration(color: style.surface, borderRadius: shape),
          // Transparent Material: the panel paints its own surface, but the
          // text field and ink effects inside still need a Material ancestor.
          child: Material(
            type: MaterialType.transparency,
            child: searching
                ? SizedBox(
                    width: columnWidth + 60,
                    child: _buildSearch(context),
                  )
                : _buildColumns(context, scheme),
          ),
        ),
      ),
    );
  }

  Widget _buildSearch(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SearchField(
          style: style,
          controller: queryController,
          focusNode: searchFocus,
          hint: tr(searchHint),
          onChanged: onQueryChanged,
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: matches.isEmpty
                  ? [
                      Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        child: Text(tr('No matching command'),
                            style: TextStyle(fontSize: 13)),
                      ),
                    ]
                  : [
                      for (var i = 0; i < matches.length; i++)
                        _ItemRow(
                          item: matches[i].item,
                          style: style,
                          // Where it lives, muted and right-aligned. While
                          // searching that matters more than the shortcut.
                          trailing: matches[i].path,
                          highlighted: i == matchIndex,
                          onHover: () => onHighlight(0, i),
                          onTap: () => onActivate(matches[i].item),
                        ),
                    ],
            ),
          ),
        ),
      ],
    );
  }

  /// All columns are laid out as one row and stretched to a common height, so
  /// the panel is a single rectangle however deep the nesting goes.
  Widget _buildColumns(BuildContext context, ColorScheme scheme) {
    return IntrinsicHeight(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < levels.length; i++)
            DecoratedBox(
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(
                        left: BorderSide(
                          color: style.foreground.withValues(alpha: 0.18),
                        ),
                      ),
              ),
              child: SizedBox(
                width: columnWidth,
                child: _MenuColumn(
                  level: levels[i],
                  levelIndex: i,
                  style: style,
                  showTitle: i > 0,
                  onActivate: onActivate,
                  onOpenGroup: onOpenGroup,
                  onCloseBelow: onCloseBelow,
                  onHighlight: (index) => onHighlight(i, index),
                  onRemoveRow: onRemoveRow,
                  onMoveRow: onMoveRow,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MenuColumn extends StatelessWidget {
  const _MenuColumn({
    required this.level,
    required this.levelIndex,
    required this.style,
    required this.showTitle,
    required this.onActivate,
    required this.onOpenGroup,
    required this.onCloseBelow,
    required this.onHighlight,
    required this.onRemoveRow,
    required this.onMoveRow,
  });

  final _Level level;
  final int levelIndex;
  final MenuAppearance style;
  final bool showTitle;
  final ValueChanged<MenuItem> onActivate;
  final void Function(
    String title,
    List<MenuNode> children,
    int levelIndex,
    int nodeIndex,
  ) onOpenGroup;
  final ValueChanged<int> onCloseBelow;
  final ValueChanged<int> onHighlight;

  /// Takes one row out of one column. See [_ContextMenuOverlayState._removeRow].
  final void Function(int levelIndex, int index) onRemoveRow;

  /// Moves one row within one column. See [_ContextMenuOverlayState._moveRow].
  final void Function(int levelIndex, int from, int to) onMoveRow;

  /// Where a row carried [rows] places from [from] can actually land.
  ///
  /// **It stops at the first row that cannot be dragged**, which is what keeps
  /// a pinned folder among the pinned ones without this code knowing what a pin
  /// is. Dragging past the end lands at the end, because that is what dragging
  /// past the end means everywhere else.
  static int _draggableIndex(List<MenuNode> nodes, int from, int rows) {
    final step = rows.isNegative ? -1 : 1;
    var at = from;
    for (var moved = 0; moved != rows; moved += step) {
      final next = at + step;
      if (next < 0 || next >= nodes.length) break;
      final node = nodes[next];
      if (node is! MenuItem || node.onDragged == null) break;
      at = next;
    }
    return at;
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < level.nodes.length; i++) {
      final node = level.nodes[i];
      final highlighted = i == level.highlighted;

      switch (node) {
        case MenuSeparator(:final label):
          rows.add(_SeparatorRow(label: label, style: style));
        case MenuItem():
          // A row with places under it unfolds them where the pointer rests,
          // and still goes where it says when it is pressed.
          final unfolds = node.children.isNotEmpty;
          rows.add(_ItemRow(
            item: node,
            style: style,
            trailing: node.trailingLabel,
            highlighted: highlighted,
            open: unfolds && level.openChild == i,
            onHover: () {
              onHighlight(i);
              if (unfolds) {
                onOpenGroup(
                  node.submenuTitle ?? node.label,
                  node.children,
                  levelIndex,
                  i,
                );
              } else {
                onCloseBelow(levelIndex);
              }
            },
            onTap: () => onActivate(node),
            // The column takes the row out and the item is told afterwards, so
            // one press does both and neither can happen without the other.
            onRemove: node.onRemove == null
                ? null
                : () {
                    onRemoveRow(levelIndex, i);
                    node.onRemove!();
                  },
            // The column moves the row and the item is told how far it
            // actually went — clamped to the run of rows that can be dragged,
            // so a row cannot be carried out of the group it belongs to.
            onDragged: node.onDragged == null
                ? null
                : (rows) {
                    final to = _draggableIndex(level.nodes, i, rows);
                    if (to == i) return;
                    onMoveRow(levelIndex, i, to);
                    node.onDragged!(to - i);
                  },
          ));
        case MenuGroup():
          rows.add(_GroupRow(
            group: node,
            style: style,
            highlighted: highlighted,
            open: level.openChild == i,
            onHover: () => onHighlight(i),
            onOpen: () => onOpenGroup(node.label, node.children, levelIndex, i),
          ));
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showTitle && level.title != null)
            _SeparatorRow(label: level.title, style: style),
          ...rows,
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.style,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onChanged,
  });

  final MenuAppearance style;
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
      child: Container(
        decoration: BoxDecoration(
          color: style.foreground.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: style.accent.withValues(alpha: 0.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          autofocus: true,
          onChanged: onChanged,
          // Written in the menu's ink for the same reason the rows are: what
          // is typed here stands on the menu's own surface.
          style: TextStyle(
            fontSize: style.scaled(13),
            color: style.foreground,
          ),
          cursorColor: style.accent,
          cursorHeight: 14,
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: style.scaled(13),
              color: style.muted,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 9),
          ),
        ),
      ),
    );
  }
}

class _SeparatorRow extends StatelessWidget {
  const _SeparatorRow({required this.style, this.label});

  final MenuAppearance style;
  final String? label;

  @override
  Widget build(BuildContext context) {
    // **The menu's own ink, not Material's.** Both of these were taking their
    // colour from the `ColorScheme`, which is seeded from the accent and has
    // nothing to do with what the menu is painted in — so on a light palette
    // the caption over a submenu came out near-black on a dark blue menu and
    // could not be read at all. Reported 2026-08-15: in the context menu the
    // caption of a submenu does not match.
    if (label == null) {
      return Divider(
        height: 9,
        thickness: 0.6,
        color: style.foreground.withValues(alpha: 0.18),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 4),
      child: Text(
        label!.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          letterSpacing: 1.1,
          fontSize: style.scaled(10),
          fontWeight: FontWeight.w600,
          color: style.muted,
        ),
      ),
    );
  }
}

/// A small control at the end of a row: the pin, or the cross.
///
/// A hit target of its own, so pressing it is not pressing the row — going to a
/// folder, holding it, and forgetting it are three different things and they
/// are a few points apart. It lights on hover, which is the only way to tell a
/// control from a decoration before pressing it.
class _RowAction extends StatefulWidget {
  const _RowAction({
    required this.icon,
    required this.ink,
    required this.accent,
    required this.size,
    required this.onPressed,
  });

  final IconData icon;
  final Color ink;
  final Color accent;
  final double size;
  final VoidCallback onPressed;

  @override
  State<_RowAction> createState() => _RowActionState();
}

class _RowActionState extends State<_RowAction> {
  bool _over = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: GestureDetector(
          // Opaque, or the press would fall through to the row underneath and
          // the folder would be opened rather than forgotten.
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
            child: Icon(
              widget.icon,
              size: widget.size,
              color: _over
                  ? widget.accent
                  : widget.ink.withValues(alpha: 0.55),
            ),
          ),
        ),
      );
}

class _ItemRow extends StatefulWidget {
  const _ItemRow({
    required this.item,
    required this.style,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
    this.open = false,
    this.trailing,
    this.onRemove,
    this.onDragged,
  });

  final MenuItem item;
  final MenuAppearance style;
  final bool highlighted;

  /// Takes this row out of the column it is in *and* tells the item. Null where
  /// the item does not offer it.
  final VoidCallback? onRemove;

  /// Moves this row within its column *and* tells the item. Null where the row
  /// has no order worth changing — see [MenuItem.onDragged].
  final void Function(int rows)? onDragged;

  /// True while this row's own column is showing. Filled solid like a group's,
  /// so the trail through the cascade reads the same whichever kind of row it
  /// passed through.
  final bool open;

  final VoidCallback onHover;
  final VoidCallback onTap;

  /// Shortcut while browsing, group path while searching.
  final String? trailing;

  @override
  State<_ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<_ItemRow> {
  /// Whether the pointer is on this row. The cross is drawn under the pointer
  /// or under the keyboard and nowhere else: a row of crosses is a list that
  /// looks like a form to fill in.
  bool _over = false;

  /// How far the row has been carried, while it is being carried.
  ///
  /// **Null when nothing is being dragged**, which is also what says the row is
  /// standing still: a drag that has begun but not moved is still a drag, and
  /// the row has to look lifted from the first pixel or the gesture reads as a
  /// press that went wrong.
  double? _carried;

  /// Whether this row can be picked up at all — see [MenuItem.onDragged].
  bool get _draggable => widget.onDragged != null;

  MenuItem get item => widget.item;
  MenuAppearance get style => widget.style;
  bool get highlighted => widget.highlighted;
  bool get open => widget.open;
  String? get trailing => widget.trailing;
  VoidCallback? get onRemove => widget.onRemove;
  VoidCallback get onHover => widget.onHover;
  VoidCallback get onTap => widget.onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = item.enabled;
    final pinned = item.pinned;
    final foreground = !enabled
        ? style.foreground.withValues(alpha: 0.38)
        : open
            ? _readableOn(style.accent)
            : style.foreground;

    final row = Hint(
      message: item.hint ?? '',
      child: MouseRegion(
      onEnter: (_) {
        // A row being carried is not a row being pointed at: the highlight
        // must not run ahead of the hand, and a submenu must not unroll under
        // a row on its way past.
        if (_carried != null) return;
        onHover();
        if (onRemove != null) setState(() => _over = true);
      },
      onExit: (_) {
        if (onRemove != null && mounted) setState(() => _over = false);
      },
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        // **Measured from where the pointer went down**, not from where the
        // drag was recognised. The default throws away the slop the gesture
        // spent proving itself — about eighteen points — and a row carried two
        // places arrived reporting one.
        dragStartBehavior: DragStartBehavior.down,
        // **A tap and a drag on the same row, told apart by the arena.**
        // Nothing moves until the pointer has travelled the slop, so a press
        // that goes where it says still goes where it says — and a press that
        // travels is a row being carried instead.
        onVerticalDragStart:
            _draggable ? (_) => setState(() => _carried = 0) : null,
        onVerticalDragUpdate: _draggable
            ? (details) =>
                setState(() => _carried = (_carried ?? 0) + details.delta.dy)
            : null,
        onVerticalDragEnd: _draggable
            ? (_) {
                final carried = _carried ?? 0;
                setState(() => _carried = null);
                // The pitch from one row to the next is the unit, because the
                // rows are all one height — so where it was dropped *is* how
                // many places it moved, with no hit-testing to do.
                final rows = (carried / _MenuSurface.rowPitch).round();
                if (rows != 0) widget.onDragged!(rows);
              }
            : null,
        onVerticalDragCancel:
            _draggable ? () => setState(() => _carried = null) : null,
        child: Container(
          height: _MenuSurface.rowHeight,
          margin: _MenuSurface.rowMargin,
          decoration: (open || highlighted) && enabled
              ? BoxDecoration(
                  color: style.accent.withValues(alpha: open ? 1 : 0.22),
                  borderRadius: _MenuSurface.pill,
                )
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              SizedBox(
                width: item.leadingWidth,
                child: item.leading ??
                    (item.checked != null
                    ? Icon(
                        item.checked!
                            ? Icons.check_box_outlined
                            : Icons.check_box_outline_blank,
                        size: 15,
                        color: foreground,
                      )
                    : item.image != null
                        ? Image.file(
                            File(item.image!),
                            width: 16,
                            height: 16,
                            filterQuality: pictureSmoothing,
                            // A file that has gone — a plugin uninstalled
                            // while its menu was open — falls back to the
                            // shape rather than to a broken picture.
                            errorBuilder: (context, _, _) => Icon(
                              item.icon ?? Icons.extension_outlined,
                              size: 16,
                              color: foreground,
                            ),
                          )
                        : item.icon == null
                            ? null
                            : Icon(item.icon, size: 16, color: foreground)),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: style.scaled(13),
                    color: foreground,
                  ),
                ),
              ),
              if (trailing != null && trailing!.isNotEmpty) ...[
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 82),
                  child: Text(
                    trailing!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: style.scaled(10.5),
                      color: open ? foreground : style.muted,
                    ),
                  ),
                ),
              ],
              // **The cross that takes the row out of the list.**
              //
              // Where the shortcut would be, because a row has one or the
              // other: a list somebody can edit is not a list of commands with
              // keys on them. Drawn only while the row is pointed at or
              // selected, so the column is a list of folders until it needs to
              // be a list of folders you can throw away.
              // **The pin is drawn whenever it is set**, and only under the
              // pointer or the keyboard when it is not. A pinned row has to say
              // so while nobody is touching it — that is the whole of what a
              // pin is for — and an empty pin on every row would be the column
              // of crosses again.
              if (item.onPin != null && (pinned || _over || highlighted)) ...[
                const SizedBox(width: 8),
                _RowAction(
                  icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  ink: pinned ? style.accent : foreground,
                  accent: style.accent,
                  size: style.scaled(13),
                  // Redrawn here as well as done: the pin is the only sign that
                  // the press landed, and the list it reorders is not rebuilt
                  // until the menu is opened again.
                  onPressed: () {
                    item.onPin!();
                    if (mounted) setState(() {});
                  },
                ),
              ],
              if (onRemove != null && (_over || highlighted)) ...[
                const SizedBox(width: 8),
                _RowAction(
                  icon: Icons.close,
                  ink: foreground,
                  accent: style.accent,
                  size: style.scaled(13),
                  onPressed: onRemove!,
                ),
              ],
              // The same arrow a shelf carries: whatever the row does when it
              // is pressed, this is what says there is more to the right.
              if (item.children.isNotEmpty)
                Icon(Icons.chevron_right, size: 16, color: foreground),
            ],
          ),
        ),
      ),
      ),
    );

    // **The wrapper is always here**, and only its numbers change.
    //
    // It was built only while a row was being carried, and that was a bug with
    // a very quiet symptom: adding widgets above the gesture detector changes
    // the shape of the tree, so Flutter threw the element away and made a new
    // one — taking the recogniser holding the drag with it. The drag began and
    // then simply stopped, mid-gesture, every time.
    final carried = _carried ?? 0;
    return Transform.translate(
      offset: Offset(0, carried),
      child: DecoratedBox(
        // Carried above its neighbours, so the row the hand is holding reads as
        // the one on top of the pile rather than one sliding behind the others.
        decoration: BoxDecoration(
          borderRadius: _MenuSurface.pill,
          boxShadow: _carried == null
              ? const []
              : const [BoxShadow(color: Color(0x40000000), blurRadius: 8)],
        ),
        child: row,
      ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.style,
    required this.highlighted,
    required this.open,
    required this.onHover,
    required this.onOpen,
  });

  final MenuGroup group;
  final MenuAppearance style;
  final bool highlighted;

  /// True while this row's column is showing; it stays filled so the path
  /// through a deep menu is visible at a glance.
  final bool open;

  final VoidCallback onHover;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final enabled = group.enabled && group.children.isNotEmpty;

    // An open group is filled solid, so the trail through a deep menu reads at
    // a glance; merely hovering gets the same pill at low opacity.
    final foreground = !enabled
        ? style.foreground.withValues(alpha: 0.38)
        : open
            ? _readableOn(style.accent)
            : style.foreground;

    return MouseRegion(
      onEnter: (_) {
        onHover();
        if (enabled) onOpen();
      },
      child: GestureDetector(
        onTap: enabled ? onOpen : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: _MenuSurface.rowHeight,
          margin: _MenuSurface.rowMargin,
          decoration: open || (highlighted && enabled)
              ? BoxDecoration(
                  color: style.accent.withValues(alpha: open ? 1 : 0.22),
                  borderRadius: _MenuSurface.pill,
                )
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: Icon(
                  group.icon ?? Icons.folder_outlined,
                  size: 16,
                  color: foreground,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  group.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: style.scaled(13),
                    color: foreground,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: foreground),
            ],
          ),
        ),
      ),
    );
  }
}

/// Builds the menu palette from the app's appearance settings.
///
/// Lives here rather than on [AppearanceSettings] so the settings model stays
/// free of widget-layer types.
MenuAppearance menuAppearanceFrom(AppearanceSettings appearance) =>
    MenuAppearance(
      accent: appearance.accentColor,
      background: appearance.effectiveMenuBackground,
      foreground: appearance.effectiveMenuForeground,
      border: appearance.menuBorderColor,
      borderWidth: appearance.menuBorderWidth,
      monolith: appearance.menuMonolith,
      opacity: appearance.menuOpacity,
      blur: appearance.menuBlur,
      blurPasses: blurPassesFor(appearance, sigma: appearance.menuBlur),
      fontScale: appearance.fontScale,
    );

/// Black or white, whichever stays legible on [background].
///
/// The accent is user-chosen, so a fixed foreground would eventually land on
/// an unreadable pairing.
Color _readableOn(Color background) =>
    background.computeLuminance() > 0.5 ? Colors.black : Colors.white;

/// A leaf command found by search, with the group path it lives under.
class _Match {
  const _Match(this.item, this.path, this.score);

  final MenuItem item;
  final String path;
  final int score;
}

/// Walks every group and returns the leaves that match, best first.
List<_Match> _searchNodes(List<MenuNode> nodes, String query, [String path = '']) {
  final results = <_Match>[];

  for (final node in nodes) {
    switch (node) {
      case MenuSeparator():
        continue;
      case MenuGroup(:final label, :final children):
        results.addAll(
          _searchNodes(children, query, path.isEmpty ? label : '$path › $label'),
        );
      case MenuItem():
        int? best;
        for (final haystack in [node.label, ...node.keywords]) {
          final score = _score(haystack, query);
          if (score != null && (best == null || score > best)) best = score;
        }

        // The group name matches too, so typing "sort" surfaces everything
        // under Sort by. It is heavily penalised: a command whose own name
        // matches must always outrank one that only shares a parent.
        if (path.isNotEmpty) {
          final viaPath = _score(path, query);
          if (viaPath != null) {
            final discounted = viaPath - 900;
            if (best == null || discounted > best) best = discounted;
          }
        }

        if (best != null) results.add(_Match(node, path, best));

        // **A row that is a destination may still have rows under it**, and
        // those are leaves like any other — the folders under home are found
        // by searching for them, not only by unfolding.
        if (node.children.isNotEmpty) {
          results.addAll(
            _searchNodes(
              node.children,
              query,
              path.isEmpty ? node.label : '$path › ${node.label}',
            ),
          );
        }
    }
  }

  results.sort((a, b) => b.score.compareTo(a.score));
  return results;
}

/// Scores [text] against [query]: exact prefix beats word start beats plain
/// substring beats a scattered subsequence. Null means no match at all.
int? _score(String text, String query) {
  final haystack = text.toLowerCase();
  final needle = query.toLowerCase();
  if (needle.isEmpty) return 0;

  if (haystack.startsWith(needle)) return 1000 - haystack.length;

  final index = haystack.indexOf(needle);
  if (index > 0) {
    final atWordStart = haystack[index - 1] == ' ' || haystack[index - 1] == '›';
    return (atWordStart ? 700 : 400) - index;
  }

  // Subsequence: every query character appears in order, so "nfd" finds
  // "New folder".
  var cursor = 0;
  var gaps = 0;
  for (final char in needle.split('')) {
    final found = haystack.indexOf(char, cursor);
    if (found < 0) return null;
    gaps += found - cursor;
    cursor = found + 1;
  }
  return 200 - gaps;
}
