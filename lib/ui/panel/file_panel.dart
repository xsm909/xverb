import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/platform/file_transfer_channel.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../core/colour_contrast.dart';
import '../../core/vfs/file_entry.dart';
import '../../core/vfs/native_icons.dart';
import '../../core/vfs/system_menu.dart';
import '../../core/vfs/vfs_path.dart';
import '../../state/app_state.dart';
import '../../state/drag_session.dart';
import '../../state/panel_attachment.dart';
import '../../state/panel_controller.dart';
import '../format.dart';
import '../motion.dart';
import '../notice.dart';
import 'icon_tint.dart';
import '../plugins/plugin_icons.dart' show pluginIcon;
import '../plugins/row_menu.dart' show showViewRowMenu;
import '../plugins/view_launcher.dart' show ViewLauncher;
import '../plugins/view_pill.dart' show ViewChrome;
import '../viewer/plugin_viewer_page.dart' show PluginContentView;
import '../widgets/listing_motion.dart';
import '../widgets/press_and_hold.dart';
import '../widgets/trail_bar.dart';
import '../widgets/hint.dart';
import '../picture_filter.dart';

/// The three column widths, worked out from the settings and the font.
///
/// **The settings are in characters and the columns are in pixels, and this is
/// the only place that knows both.** A column set to 52 pixels holds six
/// letters at 13pt and three at 22pt, and the person who set it was thinking
/// about characters both times.
///
/// Two units, because there are two kinds of column here. An extension is
/// letters, measured as an *average* one — the alphabet divided by
/// twenty-six — because `mmmm` is not what extensions look like and sizing for
/// it would waste a third of the column on every row. A size and a date are
/// figures, and a figure is wider than an average letter in every font with
/// tabular numbers; counted in letters those two would come out a character
/// short, which is the kind of almost-right that reads as a fault in the
/// drawing.
class ColumnWidths {
  const ColumnWidths({
    required this.extension,
    required this.size,
    required this.modified,
  });

  final double extension;
  final double size;
  final double modified;

  factory ColumnWidths.of(AppearanceSettings theme) => ColumnWidths(
    extension: _width(theme, theme.extensionLetters, digits: false),
    size: _width(theme, theme.sizeDigits, digits: true),
    modified: _width(theme, theme.modifiedDigits, digits: true),
  );

  /// These widths, shrunk to what a panel [available] wide can actually hold.
  ///
  /// **A set width is a wish, not a promise.** The name column takes what is
  /// left over, so three columns set generously on a wide window would, on a
  /// narrow one, leave it nothing and then go on past the edge — which is a
  /// row that overflows and a listing with a striped bar across it. What the
  /// setting really means is "this much, when there is this much to give".
  ///
  /// Everything gives way together, in proportion, so the columns keep their
  /// relative sizes as the window closes on them instead of one of them
  /// collapsing while the others stand.
  ColumnWidths within(double available, {required bool wide}) {
    final gaps = _ColumnGrip.reach * (wide ? 3 : 1);
    final shown = wide ? extension + size + modified : size;
    // What the name column keeps whatever else happens: enough for a name to
    // be a name rather than an ellipsis.
    final reserved = math.max(90.0, available * 0.25);
    final room = available - gaps - reserved;
    if (room <= 0 || shown <= room) return this;

    final scale = room / shown;
    return ColumnWidths(
      extension: math.max(18, extension * scale),
      size: math.max(30, size * scale),
      modified: math.max(30, modified * scale),
    );
  }

  static ColumnWidths lerp(ColumnWidths a, ColumnWidths b, double t) =>
      ColumnWidths(
        extension: a.extension + (b.extension - a.extension) * t,
        size: a.size + (b.size - a.size) * t,
        modified: a.modified + (b.modified - a.modified) * t,
      );

  @override
  bool operator ==(Object other) =>
      other is ColumnWidths &&
      other.extension == extension &&
      other.size == size &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(extension, size, modified);
}

/// Interpolates between two sets of widths, so all three columns travel on one
/// animation instead of three that can drift apart.
class ColumnWidthsTween extends Tween<ColumnWidths> {
  ColumnWidthsTween({super.begin, super.end});

  @override
  ColumnWidths lerp(double t) => ColumnWidths.lerp(begin!, end!, t);
}

/// The gap that keeps the last character of a column off the next one.
const double _columnPadding = 6;

double _width(AppearanceSettings theme, int characters, {required bool digits}) =>
    _unit(theme, digits: digits) * characters + _columnPadding;

/// What a column of [width] pixels comes to in characters, which is what a
/// drag on its edge is saying. Left unclamped: each edge knows its own ends.
int columnCharactersFor(
  AppearanceSettings theme,
  double width, {
  required bool digits,
}) => ((width - _columnPadding) / _unit(theme, digits: digits)).round();

/// Measured once per font rather than once per row: a `TextPainter` costs about
/// what laying out the row itself costs, and there are forty of those on
/// screen.
final Map<String, double> _units = {};

double _unit(AppearanceSettings theme, {required bool digits}) {
  final key = '${theme.fileFamily}/${theme.fontSize}/$digits';
  return _units[key] ??= _measure(theme, digits: digits);
}

double _measure(AppearanceSettings theme, {required bool digits}) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz';
  const figures = '0123456789';
  final sample = digits ? figures : alphabet;
  final painter = TextPainter(
    text: TextSpan(
      text: sample,
      style: TextStyle(fontSize: theme.fontSize, fontFamily: theme.fileFamily),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width / sample.length;
  painter.dispose();
  return width;
}

/// One half of the commander: path bar, column headers, listing, status line.
class FilePanel extends StatefulWidget {
  const FilePanel({
    super.key,
    required this.controller,
    required this.onActivateRow,
    required this.onContextMenu,
    required this.onSystemMenu,
    required this.onOpenLocations,
    required this.onDragOut,
    required this.onDropFiles,
    required this.locationKey,
    required this.cursorKey,
    this.locationMenuOpen = false,
  });

  final PanelController controller;

  /// A row was opened, by a double click. Deliberately the *same* callback
  /// Enter goes through rather than one of its own: a double click on a script
  /// should run it, as Enter does, and not open it in a viewer.
  ///
  /// The row comes with it. A double click says which entry it landed on and
  /// owes nothing to where the cursor is or which panel was active a moment
  /// ago — that is the whole of what makes it one gesture rather than two.
  final ValueChanged<FileEntry> onActivateRow;

  /// Right-click or long-press. The entry is null over empty space.
  final void Function(Offset globalPosition, FileEntry? entry) onContextMenu;

  /// The right button held down over a row: the desktop's own menu for it.
  final void Function(Offset globalPosition, FileEntry entry) onSystemMenu;

  /// Opens the drives-and-connections menu under the location pill. The rect
  /// is the pill's, so the menu hangs off it like a combo box.
  final ValueChanged<Rect> onOpenLocations;

  /// A selection has been picked up with the mouse and is leaving the panel.
  ///
  /// What happens after that is not the panel's business: the files may have to
  /// be fetched off a server before any desktop can be shown them, and that
  /// means progress and a way out of it. The screen owns both.
  final void Function(PanelController from, List<VfsPath> sources) onDragOut;

  /// Files were let go over this panel. The target is a folder in it — the one
  /// under the pointer, or the one the panel is showing.
  final Future<void> Function(
    List<VfsPath> sources,
    VfsPath target,
    TransferIntent intent,
  ) onDropFiles;

  /// Identifies the pill, so a key binding can anchor the same menu to it
  /// without going through the pointer.
  final GlobalKey locationKey;

  /// Rides on the cursor row, so the menu key can open a menu against the row
  /// it is about. Null while the cursor is scrolled out of the viewport, which
  /// is the caller's cue to fall back to the panel itself.
  final GlobalKey cursorKey;

  /// Whether this panel's location menu is currently showing.
  final bool locationMenuOpen;

  @override
  State<FilePanel> createState() => _FilePanelState();
}

/// Which way the panel went, which is what the exchange has to draw.
///
/// [across] is a move that is neither: a drive, a path typed into the bar, a
/// result set. It is not deeper than where you were and it is not shallower, so
/// it is drawn without any depth at all — see [kListingSwapZoom].
enum _SwapWay { into, outOf, across }

class _FilePanelState extends State<FilePanel>
    with SingleTickerProviderStateMixin
    implements DropZone {
  final ScrollController _scroll = ScrollController();
  int _lastCursor = -1;

  /// The folder being left fading out, and the folder arrived in fading in,
  /// on one timeline. 0 to 0.5 is the fade out, 0.5 to 1 the fade in, and the
  /// rows are exchanged at the midpoint where there is nothing to see it.
  /// Rests at 1, which is "this is the folder".
  late final AnimationController _swap = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: kListingSwapDuration),
    value: 1,
  );

  /// What the panel was showing when it set off somewhere else, drawn for the
  /// fade-out half. Null the rest of the time, which is nearly all of it.
  _FrozenListing? _frozen;

  /// The copy is up and the timeline has not started: the panel has said where
  /// it is going and the folder there has not been read yet.
  ///
  /// **This is what keeps the exchange from being a lie.** A local folder is
  /// read between two frames and the wait is nothing; an archive is opened by
  /// a plugin that has to unpack its table, and a folder the system guards
  /// waits on a question put to the user. Playing the exchange at the moment
  /// the panel *asks* would show the folder being left going away and the rows
  /// of that same folder coming back — the panel appearing to open a folder
  /// and land in the one it started in, which reads as a fault. So the copy
  /// stands, untouched and at full strength, and the exchange plays when the
  /// listing is really there.
  bool _waiting = false;

  /// Which listing is on screen — the folder, or the label of a result set,
  /// and null while a view has the panel instead. What a change of it means is
  /// that the panel has gone somewhere.
  Object? _showing;

  /// Which way the exchange now running is going. Outlives [_frozen]: the
  /// second half is the arrival, and an arrival still has a direction.
  _SwapWay _way = _SwapWay.across;

  /// The whole panel, which is what a drag is aimed at, and the listing inside
  /// it, which is what rows are counted in.
  final GlobalKey _panelKey = GlobalKey();
  final GlobalKey _viewportKey = GlobalKey();

  /// Written every build, read while a drag is over the panel — a drop lands
  /// on a row, and a row is a number of pixels that only the build knows.
  double _rowHeight = 0;

  DragSession? _drags;

  /// What is being drawn for a drag hanging over this panel: whether it is this
  /// panel's drop at all, and which row it would land in.
  bool _dropHere = false;
  int? _dropRow;

  /// The listing walking itself while a drag rests near its top or bottom edge.
  Timer? _edgeScroll;
  double _edgeDirection = 0;

  @override
  void initState() {
    super.initState();
    _showing = _listingKey(widget.controller);
    widget.controller.addListener(_reportFailure);
    widget.controller.addListener(_watchListing);
    _swap.addListener(_releaseFrozen);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final drags = context.read<AppState>().drags;
    if (identical(drags, _drags)) return;
    _leaveSession();
    _drags = drags
      ..register(this)
      ..addListener(_dragChanged);
  }

  @override
  void didUpdateWidget(FilePanel old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_reportFailure);
      old.controller.removeListener(_watchListing);
      widget.controller.addListener(_reportFailure);
      widget.controller.addListener(_watchListing);
      // A different panel altogether: whatever was fading out belonged to the
      // old one, and finishing its fade here would be this panel claiming a
      // move it never made.
      _frozen = null;
      _waiting = false;
      _showing = _listingKey(widget.controller);
      _swap.value = 1;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_reportFailure);
    widget.controller.removeListener(_watchListing);
    _swap.dispose();
    _leaveSession();
    _stopEdgeScroll();
    _scroll.dispose();
    super.dispose();
  }

  void _leaveSession() {
    _drags
      ?..unregister(this)
      ..removeListener(_dragChanged);
    _drags = null;
  }

  // --- Taking a drop ------------------------------------------------------

  /// Only what this panel draws differently is rebuilt on, and a drag crossing
  /// the *other* panel changes nothing here. Every pointer movement during a
  /// drag comes through this.
  void _dragChanged() {
    final drags = _drags;
    if (drags == null) return;
    final here = drags.isHovered(this) && drags.proposal != null;
    final row = here ? drags.proposal?.row : null;
    // The chip follows the pointer, so while this panel is the one being
    // pointed at every movement is worth a frame.
    if (here == _dropHere && row == _dropRow && !here) return;
    if (!mounted) return;
    setState(() {
      _dropHere = here;
      _dropRow = row;
    });
  }

  @override
  Rect? get dropBounds {
    final box = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  DropProposal? proposeDrop(
    Offset globalPosition,
    DragPayload payload,
    DragKeys keys,
  ) {
    final panel = widget.controller;
    final location = panel.location;
    // A panel holding a tool is not a folder, whatever is behind the tool.
    if (location == null || panel.isAttached) return null;

    _followEdge(globalPosition);

    // The row under the pointer decides where it lands: a folder takes the
    // drop into itself, everything else lands in the folder being shown. `..`
    // is a folder for this purpose — it is the way out, and dragging a file
    // onto it means putting the file where that leads.
    VfsPath target = location;
    int? row;
    final index = _rowAt(globalPosition);
    if (index != null) {
      final entry = panel.entries[index];
      if (entry.isParentLink) {
        final up = location.parent;
        if (up != null) {
          target = up;
          row = index;
        }
      } else if (entry.isDirectory) {
        target = entry.path;
        row = index;
      }
    }

    final intent = dropIntentFor(
      sources: payload.sources,
      target: target,
      keys: keys,
      allowsMove: payload.allowsMove,
      targetWritable: !panel.isReadOnly,
    );
    if (intent == null) return null;
    return DropProposal(target: target, intent: intent, row: row);
  }

  @override
  Future<void> performDrop(DropProposal proposal, DragPayload payload) async {
    _stopEdgeScroll();
    if (!mounted) return;
    // The panel that took the files is the panel being worked in.
    context.read<AppState>().activate(widget.controller);
    await widget.onDropFiles(payload.sources, proposal.target, proposal.intent);
  }

  @override
  void dropHoverEnded() => _stopEdgeScroll();

  /// The row at a point on the screen, or null when the point is not over one.
  int? _rowAt(Offset globalPosition) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || _rowHeight <= 0) return null;
    final local = box.globalToLocal(globalPosition);
    if (local.dy < 0 || local.dy > box.size.height) return null;
    if (local.dx < 0 || local.dx > box.size.width) return null;
    final offset = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final index = ((local.dy + offset) / _rowHeight).floor();
    final entries = widget.controller.entries;
    return index >= 0 && index < entries.length ? index : null;
  }

  /// Walks the listing while the drag rests near an edge of it.
  ///
  /// Without this a folder further down the list than the window is tall
  /// cannot be dropped into at all: the drag holds the pointer, so the wheel
  /// and the keyboard are both out of reach, and the only way down is to let go
  /// somewhere else first.
  void _followEdge(Offset globalPosition) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !_scroll.hasClients) {
      return _stopEdgeScroll();
    }
    final local = box.globalToLocal(globalPosition);
    final band = _rowHeight * 1.5;
    final inside = local.dx >= 0 && local.dx <= box.size.width;
    _edgeDirection = !inside
        ? 0
        : local.dy >= 0 && local.dy < band
        ? -1
        : local.dy > box.size.height - band && local.dy <= box.size.height
        ? 1
        : 0;
    if (_edgeDirection == 0) return _stopEdgeScroll();
    _edgeScroll ??= Timer.periodic(
      const Duration(milliseconds: 40),
      (_) => _scrollByEdge(),
    );
  }

  void _scrollByEdge() {
    if (!_scroll.hasClients || _edgeDirection == 0) return _stopEdgeScroll();
    final was = _scroll.position.pixels;
    final now = (was + _edgeDirection * _rowHeight * 0.5).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    if (now == was) return;
    _scroll.jumpTo(now);
    // The rows moved under a pointer that did not: what is being pointed at is
    // a different row now, and only the session can ask again.
    _drags?.refreshHover();
  }

  void _stopEdgeScroll() {
    _edgeScroll?.cancel();
    _edgeScroll = null;
    _edgeDirection = 0;
  }

  // --- Starting one -------------------------------------------------------

  /// A row was picked up with the mouse.
  ///
  /// What travels is the selection when the row is part of it, and the row
  /// alone when it is not — which is what every file manager does, and the
  /// difference between dragging four marked files and dragging the one the
  /// hand happened to land on.
  void _dragOut(int index, FileEntry entry) {
    final panel = widget.controller;
    if (entry.isParentLink) return;
    context.read<AppState>().activate(panel);
    final marked = panel.marked.contains(entry.path);
    if (!marked) panel.setCursor(index);
    final sources = marked ? panel.actionTargets : [entry.path];
    if (sources.isEmpty) return;
    widget.onDragOut(panel, sources);
  }

  /// A move that did not happen says why along the bottom of the window, and
  /// the panel stays where it was. There is nothing to dismiss and nothing to
  /// escape from — pressing Enter on a folder Windows will not open used to
  /// replace the listing with a message whose only button was out of the
  /// keyboard's reach.
  void _reportFailure() {
    final failure = widget.controller.takeFailure();
    if (failure == null) return;
    // Off the notifier's own callback: a notice goes into the overlay, and that
    // is a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showNotice(context, failure, long: true);
    });
  }

  // --- Changing folders ---------------------------------------------------

  /// Which listing the panel is showing, as one value to compare against the
  /// last one: the folder and the label of a result set, and null while a view
  /// has the panel and there is no listing at all.
  Object? _listingKey(PanelController panel) =>
      panel.isAttached ? null : (panel.location, panel.virtualLabel);

  /// The panel has gone somewhere else: keep the rows that are on screen, fade
  /// them out, and let the rows of the new folder fade in behind them.
  ///
  /// **On the notification and not in a build, and that is the whole trick.**
  /// Reading a directory off a local disk can finish before the frame that
  /// asked for it is ever drawn, and then the only frame this widget sees is
  /// one with the new rows already in it — nothing left to fade out, and what
  /// the eye would get is the folder it has just opened blinking at it.
  /// `PanelController.navigateTo` says where it is going *before* it reads
  /// anything, so this runs while everything on screen is still the folder
  /// being left, and takes its copy from there.
  void _watchListing() {
    final panel = widget.controller;
    final key = _listingKey(panel);
    if (key == _showing) {
      // Same listing as last time — and if it is the one this panel has been
      // holding an exchange for, it has just arrived and the exchange can play.
      _playWhenRead();
      return;
    }
    final was = _showing;
    _showing = key;

    final frozen = _frozen;
    if (frozen != null) {
      // A move that did not happen puts the panel back where it was — and the
      // rows fading out are the rows that are still there. Nothing changed, so
      // nothing is shown changing: the listing comes straight back.
      if (key == frozen.key) {
        _swap.value = 1;
        _waiting = false;
        setState(() => _frozen = null);
      }
      // Somewhere else again, mid-fade. The rows on screen are still the ones
      // being left, whichever folder has since been asked for, so the copy
      // stands and the timeline is not restarted. One move, one fade.
      return;
    }

    // Nothing to fade from — the panel is arriving at its first folder — or
    // nothing to fade into, because a view has taken the panel and a page
    // transition is already saying so.
    if (was == null || key == null) return;

    final theme = panel.settings.appearance;
    // None is a cut: the folder is simply open, the way it was before any of
    // this existed. No copy is taken and no timeline runs — see
    // [FolderSwapMotion.none].
    if (!theme.animates || !theme.animateFolderChange) return;

    // `was` is where it is coming from, and the panel has already been told
    // where it is going: both ends of the move are known before a frame of it
    // is drawn.
    _way = _wayFrom(_locationOf(was), panel.location);
    setState(() => _frozen = _FrozenListing.of(panel, key: was));
    _swap
      ..duration = theme.animated(kListingSwapDuration)
      ..value = 0;
    _waiting = true;
    // Nearly always the same turn of the loop: a folder off a local disk is
    // read before the frame that asked for it, and then the wait is nothing
    // and the exchange runs exactly as it did before any of this.
    _playWhenRead();
  }

  /// Starts the exchange the panel has been holding, once there is something
  /// on the other side of it to arrive at.
  void _playWhenRead() {
    if (!_waiting || widget.controller.isLoading) return;
    _waiting = false;
    _swap
      ..duration = widget.controller.settings.appearance.animated(
        kListingSwapDuration,
      )
      ..forward(from: 0);
  }

  /// The folder half of a listing key — see [_listingKey], which pairs it with
  /// the label of a result set.
  VfsPath? _locationOf(Object? key) =>
      key is (VfsPath?, String?) ? key.$1 : null;

  /// In, out, or neither.
  ///
  /// **An archive is entered from the folder holding it** and left back into
  /// that folder, so the archive *file* stands in for the location on the
  /// outside — the same substitution `PanelController._rowComingBackFrom`
  /// makes when it decides which row to land on.
  _SwapWay _wayFrom(VfsPath? from, VfsPath? to) {
    if (from == null || to == null || from == to) return _SwapWay.across;
    if (from.contains(to.archiveHost ?? to)) return _SwapWay.into;
    if (to.contains(from.archiveHost ?? from)) return _SwapWay.outOf;
    return _SwapWay.across;
  }

  /// How far through its own half the exchange is: 0 to 1 across the going,
  /// and 0 to 1 again across the arriving.
  ///
  /// **The same easing as the fade, on the same two halves.** Whatever else
  /// moves and the strength it is drawn with are one movement described twice,
  /// and two curves would show them coming apart at the midpoint — the rule the
  /// cursor mark is written under. One function for both shapes of the
  /// exchange, so the depth and the slide cannot drift apart either.
  double _swapHalf(double t) =>
      kBothCurve.transform(t < 0.5 ? t * 2 : t * 2 - 1);

  /// How big the listing is drawn at [t], on its way in or out.
  double _swapScale(double t, double zoom) {
    if (zoom == 0) return 1;
    final progress = _swapHalf(t);
    // Leaving: away from its own size. Arriving: back to it, from the far side.
    return t < 0.5 ? 1 + zoom * progress : 1 - zoom * (1 - progress);
  }

  /// How far aside the listing is drawn at [t], as a fraction of its own width.
  ///
  /// [travel] is where the movement is *going*, signed in screen order: the
  /// listing being left goes off that way and the one arriving comes in from
  /// behind it, which is one continuous movement rather than two listings each
  /// choosing a side. Which way that is belongs to the panel and not to this —
  /// see [_swapTravel].
  double _swapSlide(double t, double travel) {
    if (travel == 0) return 0;
    final progress = _swapHalf(t);
    return t < 0.5 ? travel * progress : -travel * (1 - progress);
  }

  /// Which way the slide goes, and how far, for the panel this is.
  ///
  /// **The window is what gives it its direction.** Going deeper the listing
  /// travels towards the middle of the window, and coming back out it travels
  /// towards the edge its own panel sits on — so the left panel goes right on
  /// the way in and left on the way out, and the right panel is the mirror
  /// image of that. Two panels sliding the same way would be a window with a
  /// bias in it; sliding towards each other, they read as a pair of doors.
  ///
  /// [reach] is the direction of the move itself, positive for going in, and
  /// carries the Mac's multiplier with it.
  double _swapTravel(double reach, {required bool isLeft}) =>
      reach * (isLeft ? 1 : -1) * kListingSwapSlide;

  /// The listing drawn over or under its own size, which is depth.
  ///
  /// From the middle. What it says is that the eye moved into the folder or
  /// back out of it, and an eye moves into the middle of what it is looking at.
  ///
  /// Nothing at all at zero, rather than a scale of 1: the exchange that is not
  /// asked for should leave no mark in the tree, not an identity one.
  Widget _deepened(double t, double zoom, Widget child) => zoom == 0
      ? child
      : Transform.scale(scale: _swapScale(t, zoom), child: child);

  /// The listing drawn aside, which is distance.
  ///
  /// A fraction of the listing's own width rather than a number of pixels: a
  /// panel is half a window on one machine and a quarter of one on another, and
  /// the movement has to read the same on both.
  /// Nothing at all at zero, for the reason [_deepened] is.
  Widget _asided(double t, double travel, Widget child) => travel == 0
      ? child
      : FractionalTranslation(
          translation: Offset(_swapSlide(t, travel), 0),
          child: child,
        );

  /// Lets the copy go at the midpoint, which is where the exchange happens:
  /// from here on the panel draws what it actually holds, fading in.
  void _releaseFrozen() {
    if (_frozen == null || _swap.value < 0.5) return;
    setState(() => _frozen = null);
  }

  /// Keeps the keyboard cursor inside the viewport as it moves.
  void _revealCursor(double rowHeight) {
    if (!_scroll.hasClients) return;
    final index = widget.controller.cursorIndex;
    final top = index * rowHeight;
    final bottom = top + rowHeight;
    final viewTop = _scroll.offset;
    final viewBottom = viewTop + _scroll.position.viewportDimension;

    if (top < viewTop) {
      _scroll.jumpTo(top);
    } else if (bottom > viewBottom) {
      _scroll.jumpTo(
        (bottom - _scroll.position.viewportDimension).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    // One measurement for the header and every row of the panel, and one
    // animation carrying all of them: the column steps from letter to letter,
    // and a step that is cut rather than travelled reads as the listing
    // flinching. Both panels draw off the one setting, so both move together.
    return TweenAnimationBuilder<ColumnWidths>(
      tween: ColumnWidthsTween(end: ColumnWidths.of(theme)),
      duration: theme.animated(kColumnWidthDuration),
      curve: kBothCurve,
      builder: (context, widths, _) => _panel(context, widths),
    );
  }

  Widget _panel(BuildContext context, ColumnWidths widths) {
    final appState = context.watch<AppState>();
    final settings = context.watch<SettingsStore>();
    final panel = context.watch<PanelController>();
    final theme = settings.appearance;

    final isActive = appState.isActive(widget.controller);
    // Which way the exchange leans, and how far — signed by the direction the
    // panel went: into a folder the listing being left grows or goes aside,
    // out of one it does the opposite, and a move that is neither leans not at
    // all and only fades. Whether it is said with size or with distance is the
    // setting; the Mac takes the same multiplier a live row does — see
    // [kLiveRowReachOnMac].
    final swapping = theme.folderChangeMotion;
    final reach =
        switch (_way) {
          _SwapWay.into => 1.0,
          _SwapWay.outOf => -1.0,
          _SwapWay.across => 0.0,
        } *
        liveRowReach(Theme.of(context).platform);
    final zoom = reach * kListingSwapZoom;
    final travel = _swapTravel(reach, isLeft: panel.isLeft);
    final rowHeight = theme.fontSize * 1.45 + theme.density.verticalPadding * 2;
    _rowHeight = rowHeight;

    // Not while the folder being left is on screen: the copy is drawn through
    // this panel's one scroll position, so scrolling to a row of the folder
    // being *arrived* in would drag the rows that are fading out along with
    // it. `_lastCursor` is left stale on purpose, so the move is noticed again
    // on the build that lets the copy go.
    if (panel.cursorIndex != _lastCursor && _frozen == null) {
      _lastCursor = panel.cursorIndex;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _revealCursor(rowHeight),
      );
    }

    final body = GestureDetector(
      key: _panelKey,
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => appState.activate(widget.controller),
      // On *up*, not on down. `onSecondaryTapDown` fires for every tap
      // recogniser tracking the pointer once its deadline passes, winner or
      // not, so as a down handler this opened the empty-space menu on top of
      // whatever the row under the pointer was doing. Waiting for the up means
      // waiting for the arena, which the row wins when there is one.
      onSecondaryTapUp: (details) {
        appState.activate(widget.controller);
        widget.onContextMenu(details.globalPosition, null);
      },
      // A panel is a square slab and nothing else. It has no frame of its own:
      // the ring that marks the active one is a single widget living over both
      // of them, and it slides — see PanelSelection.
      //
      // Square because two panels sit edge to edge, and a rounded panel has to
      // negotiate with the one beside it. Both rounded, the two curves turn
      // away from each other and leave a notch at the join: first with the
      // window's backdrop showing through it, and once that was closed, with
      // the fill. A square slab has no join to negotiate, and the selection —
      // which is never beside anything, because there is one of it — can be as
      // round as it likes.
      child: Container(
        color: theme.effectivePanelBackground,
        // **No padding.** It used to keep the room the frame once reserved, so
        // the selection would not be drawn over the listing's first column of
        // pixels — and what it actually did was leave a two-pixel band of
        // panel fill above the path bar and below the count at the bottom. The
        // strips run the width of the panel now, and what divides the chrome is
        // a hairline instead — [AppearanceSettings.chromeRule].
        child: Column(
          children: [
            // Nothing in the chrome may take keyboard focus: the commander's
            // key handling lives on one focus node, and a stray button stealing
            // focus silently kills every shortcut.
            ExcludeFocus(
              child: Column(
                children: [
                  _PathBar(
                    panel: panel,
                    isActive: isActive,
                    locationKey: widget.locationKey,
                    onOpenLocations: widget.onOpenLocations,
                    menuOpen: widget.locationMenuOpen,
                  ),
                  if (!panel.isAttached)
                    _ColumnHeader(settings: settings, widths: widths),
                ],
              ),
            ),
            Expanded(
              child: panel.isAttached
                  ? _Attached(
                      attachment: panel.attachment!,
                      isActive: isActive,
                      onClose: () => unawaited(widget.controller.detach()),
                    )
                  : AnimatedBuilder(
                      animation: _swap,
                      // The listing is the builder's `child`, so it is built
                      // when the rows change and not once a frame: what the
                      // fade animates is how strongly it is drawn, and the
                      // rows themselves have nothing to do during it.
                      child: _Listing(
                        panel: panel,
                        frozen: _frozen,
                        scroll: _scroll,
                        rowHeight: rowHeight,
                        isActive: isActive,
                        cursorKey: widget.cursorKey,
                        viewportKey: _viewportKey,
                        dropRow: _dropHere ? _dropRow : null,
                        widths: widths,
                        onActivate: () => appState.activate(widget.controller),
                        onActivateRow: widget.onActivateRow,
                        onContextMenu: widget.onContextMenu,
                        onSystemMenu: widget.onSystemMenu,
                        onDragOut: _dragOut,
                      ),
                      builder: (context, child) {
                        final t = _swap.value;
                        if (t == 1) return child!;
                        return ClipRect(
                          // Outermost, and it has to be: the listing being
                          // left is drawn over its own size or beside itself,
                          // and the panel has a header above it and a count
                          // below it that it may not spill into.
                          child: Opacity(
                            opacity: fadeThrough(t),
                            // Both wrap the same child in the same order
                            // whichever of them is asked for, so Both is the
                            // two of them and not a third movement.
                            child: _asided(
                              t,
                              swapping.hasSlide ? travel : 0,
                              _deepened(
                                t,
                                swapping.hasDepth ? zoom : 0,
                                child!,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            _StatusLine(panel: panel),
          ],
        ),
      ),
    );

    // Everything a drag draws is drawn *over* the panel and touches nothing
    // underneath it: no padding moves, no row is rebuilt to hold a border, and
    // with no drag in the window the whole of it is one invisible box.
    return Stack(
      children: [
        body,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: theme.animated(kDropPanelDuration),
              curve: kBothCurve,
              opacity: _dropHere ? 1 : 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: theme.accentColor, width: 2),
                ),
              ),
            ),
          ),
        ),
        if (_dropHere) _dropChip(theme),
      ],
    );
  }

  /// The little label that follows the pointer while a drag is over the panel.
  ///
  /// It says the two things a hand in the middle of a drag actually wants to
  /// know: **what** will happen, and **where** it will land. Copy or move is
  /// otherwise readable only from the cursor the desktop draws, which is a
  /// plus sign the size of a full stop, and the folder is otherwise readable
  /// only from which row is lit — which is no help at all when the drop lands
  /// in the folder the panel is already showing.
  Widget _dropChip(AppearanceSettings theme) {
    final drags = _drags;
    final proposal = drags?.proposal;
    final at = drags?.pointer;
    final box = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (proposal == null || at == null || box == null || !box.hasSize) {
      return const SizedBox.shrink();
    }
    final local = box.globalToLocal(at);
    final moving = proposal.intent == TransferIntent.move;
    final where = proposal.target.name;
    final label = moving
        ? tr('Move to {where}', {'where': where})
        : tr('Copy to {where}', {'where': where});

    return Positioned(
      // Below and to the right of the pointer, where the desktop's own drag
      // badge sits, and clamped so it cannot be pushed off the panel by a drop
      // aimed at the very edge of it.
      left: (local.dx + 18).clamp(0.0, math.max(0.0, box.size.width - 260)),
      top: (local.dy + 20).clamp(0.0, math.max(0.0, box.size.height - 36)),
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: theme.accentColor,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                moving ? Icons.drive_file_move_outline : Icons.copy_outlined,
                size: theme.fontSize,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: theme.fontSize * 0.92,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The ring that says which panel has the keyboard, and the only one of it.
///
/// Drawn over both panels rather than by each of them, because it is one thing
/// that changes place rather than two that take turns being visible. The panels
/// underneath do not change at all.
///
/// That is also what lets it be round. A frame drawn *by* a panel is stuck
/// beside the other panel's frame and the two of them leave a notch where they
/// meet; a frame drawn *over* the panels is beside nothing.
///
/// Pressing Tab fades it out, moves it while it cannot be seen, and fades it
/// back in. It used to travel — and travelling states the wrong thing. The
/// selection is not an object crossing the window; it is which panel has the
/// keyboard, and that changes at once. A fade says *this one, now that one*
/// without drawing a journey between them that nothing actually made.
class PanelSelection extends StatefulWidget {
  const PanelSelection({
    super.key,
    required this.leftActive,
    required this.split,
    this.dim = false,
  });

  /// Which half to sit on.
  final bool leftActive;

  /// How much of the width the left panel takes. 1 when there is only one
  /// panel, and then the ring covers the lot.
  final double split;

  /// Drawn faintly, because the keyboard is in the command line and not in the
  /// panel this is around. The frame does not move — that panel is still the
  /// one you came from and the one that will have the keyboard back — it only
  /// stops claiming to be where the typing goes.
  final bool dim;

  /// How faint that is. The same third the inactive panel's cursor is drawn
  /// at, so "not where the keyboard is" looks like one thing across the window
  /// rather than two.
  static const double dimmed = 0.35;

  @override
  State<PanelSelection> createState() => _PanelSelectionState();
}

class _PanelSelectionState extends State<PanelSelection>
    with SingleTickerProviderStateMixin {
  /// One timeline for both halves. 0 to 0.5 is the fade out, 0.5 to 1 the fade
  /// in, and the move happens at the midpoint where there is nothing on screen
  /// to move. Rests at 1, which is "arrived".
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: kPanelAnimationDuration),
    value: 1,
  );

  /// The side the ring is drawn on until the midpoint. Kept because the widget
  /// says where the keyboard is now, and for half of the animation the ring is
  /// still where the keyboard was.
  late bool _from = widget.leftActive;

  @override
  void didUpdateWidget(PanelSelection old) {
    super.didUpdateWidget(old);
    if (old.leftActive == widget.leftActive) return;

    final t = _fade.value;
    // Where the ring is actually drawn at this instant — which is not
    // `old.leftActive` if a previous crossing is still in its fade-out half,
    // because that half has not moved it yet.
    _from = t < 0.5 ? _from : old.leftActive;
    // Tab pressed again mid-crossing restarts at the point of the timeline
    // holding the opacity it already has, rather than at 0. The two halves are
    // mirror images, so the fade-in point t has a fade-out twin at 1 - t: the
    // ring keeps dimming from where it got to instead of flashing back to full
    // strength and starting over.
    _fade.forward(from: t < 0.5 ? t : 1 - t);
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    // Set here rather than at construction, so that changing the speed in
    // settings reaches a ring that is already on screen. `didUpdateWidget` runs
    // before `build` on the frame a panel changes, and so reads the length the
    // previous build left — which is the current one, unless the speed and the
    // active panel changed on the very same frame.
    _fade.duration = theme.animated(kPanelAnimationDuration);

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth * widget.split;
          final away = constraints.maxWidth - width;
          final from = _from ? 0.0 : away;
          final to = widget.leftActive ? 0.0 : away;

          return AnimatedBuilder(
            animation: _fade,
            // Built once and carried through: the ring itself never changes,
            // only where it is and how strongly it is drawn.
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: theme.accentColor,
                  // Always a whole number of pixels — see
                  // `AppearanceSettings.panelBorderWidth` for the two holes
                  // that came out of the 1.5 this used to be.
                  width: theme.panelBorderWidth.toDouble(),
                ),
                borderRadius: BorderRadius.circular(
                  AppearanceSettings.panelCornerRadius,
                ),
              ),
            ),
            builder: (context, child) {
              final t = _fade.value;
              return Stack(
                children: [
                  Positioned(
                    // No interpolation: it is on one side or the other, and it
                    // changes sides at the midpoint, where it is invisible.
                    left: t < 0.5 ? from : to,
                    width: width,
                    top: 0,
                    bottom: 0,
                    child: Opacity(
                      opacity:
                          fadeThrough(t) *
                          (widget.dim ? PanelSelection.dimmed : 1),
                      child: child,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({
    required this.panel,
    required this.isActive,
    required this.locationKey,
    required this.onOpenLocations,
    required this.menuOpen,
  });

  final PanelController panel;
  final bool isActive;
  final GlobalKey locationKey;
  final ValueChanged<Rect> onOpenLocations;

  /// True while this panel's location menu is showing, so the pill stays lit
  /// under it — whether the menu was opened by the pointer or by Alt+F1.
  final bool menuOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;

    // A result set has no trail to walk: its rows come from all over the tree.
    final trail = panel.isVirtual
        ? const <VfsPath>[]
        : panel.location?.trail ?? const <VfsPath>[];

    return Container(
      height: theme.pathBarHeight,
      color: theme.effectiveHeaderBackground,
      padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
      child: Row(
        children: [
          // **Before the path**, and ahead of the drive as well, because it is
          // not about where this panel is — it is the way out of being here at
          // all.
          if (panel.wayBack != null) ...[
            _WayBackButton(panel: panel, isActive: isActive),
            const SizedBox(width: 4),
          ],
          // The drive stays put whatever the path does: it is the way to the
          // other drives, and Alt+F1 hangs its menu off it.
          _LocationPill(
            key: locationKey,
            panel: panel,
            isActive: isActive,
            open: menuOpen,
            onOpen: onOpenLocations,
          ),
          Expanded(
            child: panel.isAttached
                // Something else has the panel. Its own title stands in for the
                // trail, which would otherwise go on offering to navigate a
                // listing nobody can see.
                ? _AttachedTitle(
                    attachment: panel.attachment!,
                    onClose: () => unawaited(panel.detach()),
                  )
                : _Trail(
                    // The whole trail, root first: the pill opens the drive
                    // *menu*, so the root needs a button of its own to be
                    // reachable at all.
                    steps: trail,
                    current: panel.location,
                    isActive: isActive,
                    onGo: (step) => unawaited(panel.navigateTo(step)),
                  ),
          ),
          if (panel.isLoading || (panel.attachment?.isLoading ?? false)) ...[
            const SizedBox(width: 6),
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: theme.accentColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The levels below the drive, drawn as buttons.
///
/// A short path sits against the drive on the left; a long one scrolls, and is
/// parked at its end so the folder you are actually in is the one you can see.
/// What the path bar says while something else has the panel: the title of
/// whatever is attached, and the way out.
class _AttachedTitle extends StatelessWidget {
  const _AttachedTitle({required this.attachment, required this.onClose});

  final PanelAttachment attachment;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;

    return ListenableBuilder(
      listenable: attachment,
      builder: (context, _) => Row(
        children: [
          // A page the view put over its own, and the way off it. Escape does
          // the same, but a panel is worked with a mouse too, and a page whose
          // only way back is a key is a page that looks stuck. It is here and
          // not always, because a view on its first page has nowhere to go
          // back *to* — that is what the cross beside it is for.
          if (attachment.canGoBack)
            Hint(
              message: tr('Back'),
              child: IconButton(
                icon: const Icon(Icons.arrow_back, size: 14),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 22, height: 22),
                color: theme.headerForeground.withValues(alpha: 0.75),
                onPressed: () => unawaited(attachment.goBack()),
              ),
            ),
          Expanded(
            // A view that has walked into something gets the panel's own path
            // bar rather than a flat line of text: it is the same problem, in
            // the same place, and it should be the same thing. And whatever
            // the view says *instead of* a path — a branch, in a pill — stands
            // here too, which is the one place it can stand in a panel.
            child: ViewChrome(
              attachment: attachment,
              theme: theme,
              // A panel has no title bar to put them in, and until now that
              // meant a tool in a panel could offer nothing it drew with an
              // icon at all.
              withCommands: true,
            ),
          ),
          // The structure of what is being read, beside the way out — next to
          // the close cross. Offered only where there is something to read a
          // structure out of, which the reading itself says: a table or a
          // picture never grows one.
          ListenableBuilder(
            listenable: attachment.structure,
            builder: (context, _) => !attachment.structure.offered
                ? const SizedBox.shrink()
                : Hint(
                    // In a panel it stays a chord: a bare letter here is
                    // the panel's own quick search. Full screen it is `O`.
                    message: '${tr('Structure')}  Ctrl+Shift+O',
                    child: IconButton(
                      icon: const Icon(Icons.toc, size: 14),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 22,
                        height: 22,
                      ),
                      color: theme.headerForeground.withValues(
                        alpha: attachment.structure.open ? 1 : 0.75,
                      ),
                      onPressed: attachment.structure.toggle,
                    ),
                  ),
          ),
          // Escape closes it too, but the panel is also worked with a mouse,
          // and a view with no visible way out is a panel that looks stuck.
          Hint(
            message: tr('Back to the listing'),
            child: IconButton(
              icon: const Icon(Icons.close, size: 14),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 22, height: 22),
              color: theme.headerForeground.withValues(alpha: 0.75),
              onPressed: onClose,
            ),
          ),
        ],
      ),
    );
  }
}

/// The body of a panel that has been handed over to a viewport or a view.
class _Attached extends StatelessWidget {
  const _Attached({
    required this.attachment,
    required this.isActive,
    required this.onClose,
  });

  final PanelAttachment attachment;

  /// Whether this is the panel with the keyboard. A table's cursor dims when
  /// it is not, exactly as a listing's does — there is one keyboard and two
  /// panels, and only one of them can have it.
  final bool isActive;

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: attachment,
      builder: (context, _) {
        final content = attachment.content;
        if (content == null) {
          return _PanelMessage(
            icon: attachment.isLoading
                ? Icons.hourglass_empty
                : Icons.visibility_outlined,
            message: attachment.isLoading
                ? tr('Loading…')
                : tr('Nothing to show yet.'),
          );
        }

        return PluginContentView(
          content: content,
          // A panel, not a page: content that would put a panel of its own
          // over itself has nowhere to put one here.
          fullScreen: false,
          structure: attachment.structure,
          pluginId: attachment.pluginId,
          cursor: attachment.cursorFor,
          focusedPart: attachment.focusedPart,
          onFocusPart: attachment.focusPart,
          isActive: isActive,
          onActivateRow: attachment.isInteractive
              ? (row, part) => unawaited(attachment.activate(row, part: part))
              : null,
          onMarkRow: attachment.isInteractive
              ? (row, part, at) => unawaited(showViewRowMenu(
                  context: context,
                  attachment: attachment,
                  row: row,
                  part: part,
                  at: at,
                ))
              : null,
          onButton: attachment.isInteractive
              ? (id, values) => unawaited(attachment.press(id, values: values))
              : null,
          onDropRows: attachment.isInteractive
              ? (from, to, rows) =>
                  unawaited(attachment.dropRows(from, to, rows))
              : null,
        );
      },
    );
  }
}

/// The panel's location, as a row of buttons.
///
/// A thin wrapper over the shared [TrailBar]: all this adds is what a path's
/// levels are called, which is the only part a plugin view's trail does
/// differently.
class _Trail extends StatelessWidget {
  const _Trail({
    required this.steps,
    required this.current,
    required this.isActive,
    required this.onGo,
  });

  final List<VfsPath> steps;
  final VfsPath? current;
  final bool isActive;
  final ValueChanged<VfsPath> onGo;

  @override
  Widget build(BuildContext context) => TrailBar(
        steps: [
          for (var i = 0; i < steps.length; i++)
            // The root is drawn as the separator that names it — `C:` is
            // already on the pill, and `C:\` is the folder itself.
            i == 0 ? _rootLabel(steps[i]) : steps[i].label,
        ],
        current: steps.indexOf(current ?? steps.last),
        isActive: isActive,
        onGo: (index) => onGo(steps[index]),
      );
}

/// The way out of an excursion a tool sent this panel on.
///
/// **It says where it is going, not that it is going.** A button marked "Back"
/// leaves the reader to remember what they were doing three folders ago; the
/// tool named this — "Back to commits" — because the tool is the only one that
/// knows. See [WayBack].
///
/// Drawn only while there is a journey to undo, so it is not a control that
/// sits there greyed out most of the time.
class _WayBackButton extends StatefulWidget {
  const _WayBackButton({required this.panel, required this.isActive});

  final PanelController panel;
  final bool isActive;

  @override
  State<_WayBackButton> createState() => _WayBackButtonState();
}

class _WayBackButtonState extends State<_WayBackButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final back = widget.panel.wayBack;
    if (back == null) return const SizedBox.shrink();

    final ink = widget.isActive
        ? theme.headerForeground
        : theme.headerForeground.withValues(alpha: 0.6);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(
          ViewLauncher(context.read<AppState>())
              .takeTheWayBack(context, widget.panel),
        ),
        child: Hint(
          // Escape is the keyboard's answer, and a control that only says so
          // where the mouse is resting is a control the keyboard user never
          // learns about — but it is the only place there is room to say it.
          message: tr('Escape'),
          wait: const Duration(milliseconds: 700),
          child: Container(
            height: theme.chromeRowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _hovered
                  ? theme.accentColor.withValues(alpha: 0.28)
                  : theme.headerForeground.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: _hovered
                    ? theme.accentColor
                    : theme.headerForeground.withValues(alpha: 0.12),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back, size: theme.fontSize + 2, color: ink),
                const SizedBox(width: 4),
                Text(
                  back.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ink,
                    fontSize: theme.fontSize,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What the button for a root says: the separator that platform writes paths
/// with, so `C:` on the pill plus this reads as `C:\`.
String _rootLabel(VfsPath root) =>
    root.scheme == VfsPath.localScheme && Platform.isWindows ? r'\' : '/';

/// The drive and path, as one button.
///
/// It reads as a combo box because that is what it is: pressing it drops the
/// drives, the saved connections and the way to type a path underneath it —
/// anchored to the pill rather than to the pointer, so the same menu appears
/// in the same place whether it was opened by a click or by Alt+F1.
class _LocationPill extends StatefulWidget {
  const _LocationPill({
    super.key,
    required this.panel,
    required this.isActive,
    required this.open,
    required this.onOpen,
  });

  final PanelController panel;
  final bool isActive;
  final bool open;
  final ValueChanged<Rect> onOpen;

  @override
  State<_LocationPill> createState() => _LocationPillState();
}

class _LocationPillState extends State<_LocationPill> {
  bool _hovered = false;

  void _open() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    widget.onOpen(box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final panel = widget.panel;

    // The pill is the volume, not the path: the levels under it are drawn as
    // their own buttons beside it. A result set has no volume to name, so it
    // says what it is instead — its rows come from all over the tree.
    final label =
        panel.virtualLabel ?? panel.location?.volumeLabel ?? tr('No location');

    // What kind of place this is, when it is not simply a disk: a commit shows
    // the clock, an archive its box. **The panel has to say where it stands
    // before the user acts as though it were somewhere else** — half the F-keys
    // are dark in here, and a dark key with no reason given reads as a broken
    // application rather than as history.
    final badge = panel.badge;

    final Color background;
    final Color foreground;
    if (widget.open) {
      background = theme.accentColor.withValues(alpha: 0.85);
      foreground = theme.accentColor.computeLuminance() > 0.5
          ? Colors.black
          : Colors.white;
    } else if (_hovered) {
      background = theme.accentColor.withValues(alpha: 0.28);
      foreground = theme.headerForeground;
    } else {
      background = theme.headerForeground.withValues(alpha: 0.07);
      foreground = widget.isActive
          ? theme.headerForeground
          : theme.headerForeground.withValues(alpha: 0.6);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _open,
        child: Hint(
          message: [
            panel.virtualLabel ?? panel.location?.display ?? '',
            if (panel.isReadOnly) tr('Read-only'),
          ].join(' · '),
          wait: const Duration(milliseconds: 700),
          child: Container(
            height: theme.chromeRowHeight,
            padding: const EdgeInsets.only(left: 8, right: 2),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: widget.open || _hovered
                    ? theme.accentColor
                    : theme.headerForeground.withValues(alpha: 0.12),
              ),
            ),
            // Only as wide as what it says: the path continues beside it, and
            // a combo box stretched across the panel would be all box.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  panel.isVirtual
                      ? Icons.travel_explore
                      : badge != null
                      ? pluginIcon(badge)
                      : Icons.storage_outlined,
                  size: 14,
                  // Accent, like the one a result set wears, and for the same
                  // reason: the ordinary case is a disk and wants no colour,
                  // and these two are the cases where the panel is not what it
                  // usually is.
                  color: (panel.isVirtual || badge != null) && !widget.open
                      ? theme.accentColor
                      : foreground,
                ),
                // Nothing to say on POSIX, where the volume has no name of
                // its own: the icon is the whole pill and the trail keeps the
                // `/`. See VfsPath.volumeLabel.
                if (label.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    // A search label can be long; a drive letter never is.
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // Constant weight: re-measuring the label in a bolder
                      // face when the panel gains focus made it twitch
                      // sideways.
                      style: TextStyle(
                        color: foreground,
                        fontSize: theme.fontSize,
                        // The location is a directory like any other, and it
                        // is drawn in the listing's family for the same reason.
                        fontFamily: theme.fileFamily,
                        fontWeight: theme.directoryFontWeight.weight,
                      ),
                    ),
                  ),
                ],
                Icon(Icons.expand_more, size: 15, color: foreground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({required this.settings, required this.widths});

  final SettingsStore settings;

  /// The columns as they are drawn at this instant — which during the
  /// animation after a change is not yet the width the settings ask for.
  final ColumnWidths widths;

  @override
  Widget build(BuildContext context) {
    final theme = settings.appearance;
    final strong = theme.strongFontWeight;
    final style = TextStyle(
      color: theme.headerForeground.withValues(alpha: 0.7),
      fontSize: theme.fontSize - 1,
      fontWeight: strong.weight,
    );

    Widget cell(String label, SortColumn column, {TextAlign? align}) {
      final isSorted = settings.sortColumn == column;
      return InkWell(
        onTap: () => settings.applySort(column),
        child: Row(
          mainAxisAlignment: align == TextAlign.right
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            // **The heading gives way, the column does not.** Its width is a
            // number of characters the user set for the *values* underneath —
            // digits, for size and date — and a translated heading is under no
            // obligation to fit in them: the Russian for "Size" is half again
            // as wide as the English. Ellipsis rather than an overflow stripe,
            // which is what
            // this drew until 1.0.0.317.
            Flexible(
              child: Text(
                label,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
            if (isSorted)
              Icon(
                settings.sortAscending
                    ? Icons.arrow_drop_up
                    : Icons.arrow_drop_down,
                size: 14,
                color: theme.accentColor,
              ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 380;
        // The same clamp the rows apply, off the same width, so a heading and
        // the column under it cannot disagree.
        final widths = this.widths.within(constraints.maxWidth, wide: wide);
        return Container(
          height: theme.chromeRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: theme.effectiveHeaderBackground,
            border: Border(
              bottom: BorderSide(
                color: theme.headerForeground.withValues(alpha: 0.15),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(child: cell(tr('Name'), SortColumn.name)),
              if (wide) ...[
                _ColumnGrip(
                  key: columnGripKey('extension'),
                  settings: settings,
                  width: widths.extension,
                  height: theme.chromeRowHeight,
                  digits: false,
                  min: AppearanceSettings.minExtensionLetters,
                  max: AppearanceSettings.maxExtensionLetters,
                  apply: (a, n) => a.copyWith(extensionLetters: n),
                ),
                SizedBox(
                  width: widths.extension,
                  child: cell(tr('Ext'), SortColumn.extension),
                ),
              ],
              _ColumnGrip(
                key: columnGripKey('size'),
                settings: settings,
                width: widths.size,
                height: theme.chromeRowHeight,
                digits: true,
                min: AppearanceSettings.minSizeDigits,
                max: AppearanceSettings.maxSizeDigits,
                apply: (a, n) => a.copyWith(sizeDigits: n),
              ),
              SizedBox(
                width: widths.size,
                child: cell(tr('Size'), SortColumn.size,
                    align: TextAlign.right),
              ),
              if (wide) ...[
                _ColumnGrip(
                  key: columnGripKey('modified'),
                  settings: settings,
                  width: widths.modified,
                  height: theme.chromeRowHeight,
                  digits: true,
                  min: AppearanceSettings.minModifiedDigits,
                  max: AppearanceSettings.maxModifiedDigits,
                  apply: (a, n) => a.copyWith(modifiedDigits: n),
                ),
                SizedBox(
                  width: widths.modified,
                  child: cell(
                    tr('Modified'),
                    SortColumn.modified,
                    align: TextAlign.right,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// The listing as it stood the moment the panel set off somewhere else.
///
/// **Everything the rows are drawn from, and nothing live.** The panel has
/// already gone: its entries are being replaced, its marks and its measured
/// folder sizes are cleared on the way, and reading any of them while the old
/// rows fade out would show the folder being left losing its marks — which is
/// not what happened. What happened is that it was left.
///
/// Cheap to make and short-lived: it is one list reference, the cursor, and
/// two small copies, held for one fade.
class _FrozenListing {
  const _FrozenListing({
    required this.key,
    required this.entries,
    required this.cursor,
    required this.marked,
    required this.sizes,
    required this.ghosted,
  });

  /// Takes the copy from [panel] as it is at this instant — which is while it
  /// is still the folder named by [key].
  factory _FrozenListing.of(PanelController panel, {required Object key}) {
    return _FrozenListing(
      key: key,
      entries: panel.entries,
      cursor: panel.cursorIndex,
      marked: {...panel.marked},
      sizes: panel.measuredSizes,
      // Only when there is a quick search on, because this is the one line
      // here that costs a pass over the listing — and a listing being searched
      // is one the typing already walks on every keystroke.
      ghosted: panel.searchQuery == null
          ? const {}
          : {
              for (final entry in panel.entries)
                if (!panel.matchesSearch(entry)) entry.path,
            },
    );
  }

  /// What [_FilePanelState._listingKey] said of the folder this came from, so
  /// a panel that comes straight back to it can tell that it did.
  final Object key;

  final List<FileEntry> entries;
  final int cursor;
  final Set<VfsPath> marked;

  /// The directory totals that had been measured, by path.
  final Map<VfsPath, int> sizes;

  /// The rows a quick search was leaving out, by path.
  final Set<VfsPath> ghosted;

  /// [PanelController.sizeOf]'s rule, over what was measured then rather than
  /// over what is measured now. A file carries its own size; only a folder's
  /// total was ever held by the panel.
  int? sizeOf(FileEntry entry) {
    if (entry.isParentLink) return null;
    if (!entry.isDirectory) return entry.size;
    return sizes[entry.path];
  }
}

class _Listing extends StatefulWidget {
  const _Listing({
    required this.panel,
    required this.frozen,
    required this.scroll,
    required this.rowHeight,
    required this.isActive,
    required this.cursorKey,
    required this.viewportKey,
    required this.dropRow,
    required this.widths,
    required this.onActivate,
    required this.onActivateRow,
    required this.onContextMenu,
    required this.onSystemMenu,
    required this.onDragOut,
  });

  final PanelController panel;

  /// The listing the panel *was* showing, while it fades out, or null — which
  /// is every other frame. With one of these the rows come from the copy and
  /// nothing is read from [panel]: it is somewhere else already.
  final _FrozenListing? frozen;

  final ScrollController scroll;
  final double rowHeight;
  final bool isActive;

  /// Goes on the cursor row, wherever that is, so the menu key can find it.
  final GlobalKey cursorKey;

  /// Goes on the box the rows are drawn in, so the panel can turn a point on
  /// the screen into a row without asking the list for anything.
  final GlobalKey viewportKey;

  /// The row a drag hanging over this panel would land in, or null when it
  /// would land in the folder itself — or when there is no drag.
  final int? dropRow;

  /// The three set columns in pixels, worked out once for the whole panel —
  /// see [ColumnWidths].
  final ColumnWidths widths;

  /// A row is being carried off with the mouse.
  final void Function(int index, FileEntry entry) onDragOut;
  final VoidCallback onActivate;

  /// The row was opened — by a double click, and by nothing else. Whatever
  /// Enter does with the cursor row, this does to the row named here.
  final ValueChanged<FileEntry> onActivateRow;
  final void Function(Offset globalPosition, FileEntry? entry) onContextMenu;
  final void Function(Offset globalPosition, FileEntry entry) onSystemMenu;

  @override
  State<_Listing> createState() => _ListingState();
}

class _ListingState extends State<_Listing>
    with SingleTickerProviderStateMixin {
  /// The row a click landed on, for as long as a second click on it would still
  /// be the other half of a double one. -1 while nothing is armed.
  int _armedRow = -1;
  Timer? _disarm;

  /// The cursor mark's slide from one row to the next, shared with every other
  /// listing in the application — see [CursorSlide]. Built whether or not the
  /// setting is on, because a controller that is never started costs nothing.
  late final CursorSlide _slide = CursorSlide(this);

  @override
  void dispose() {
    _disarm?.cancel();
    _slide.dispose();
    super.dispose();
  }

  double _offset() =>
      widget.scroll.hasClients ? widget.scroll.position.pixels : 0;

  /// Whether this click completes a double click on the same row.
  ///
  /// Counted here rather than with `onDoubleTap`, because a detector carrying
  /// both makes every *single* tap wait out the double-tap window before it does
  /// anything — which is most of what made a touch screen feel as though it was
  /// ignoring the first press or two. Moving the cursor has to be instant.
  ///
  /// A timer, not two timestamps. This used to subtract frame timestamps, and a
  /// frame timestamp is not a clock: it only moves when something repaints, and
  /// a panel nobody has touched does not repaint. So the first click of a pair
  /// recorded the time of whatever frame happened to be the last one — often
  /// seconds old, from the mouse arriving over the panel — while the second
  /// click read the frame that the *first* click had just caused. The gap
  /// measured was idle time, not the gap between the two clicks, and a perfectly
  /// good double click on an untouched panel was thrown away as two slow ones.
  /// Tests never saw it, because pumping keeps the frame clock marching in step
  /// with the taps. A `Timer` runs off the real clock in the app and off the
  /// test's own fake one under `pump`, so both get the truth.
  bool _completesDoubleClick(int index) {
    if (index == _armedRow) {
      // A third click starts over rather than counting as another double.
      _disarmNow();
      return true;
    }

    _disarm?.cancel();
    _armedRow = index;
    _disarm = Timer(kDoubleTapTimeout, _disarmNow);
    return false;
  }

  void _disarmNow() {
    _disarm?.cancel();
    _disarm = null;
    _armedRow = -1;
  }

  /// Where the button went down, and on which row, for as long as the gesture
  /// could still turn into a drag. Null between drags.
  Offset? _pressedAt;
  int _pressedRow = -1;

  /// How far the pointer travels before a press becomes a drag rather than a
  /// click. Windows asks the system for this and gets four pixels; six is the
  /// same gesture with room for a hand that shakes slightly on a double click.
  static const double _dragThreshold = 6;

  void _pointerDown(PointerDownEvent event) {
    _pressedAt = null;
    _pressedRow = -1;
    if (event.buttons != kPrimaryButton) return;
    final index = _rowAt(event.position);
    if (index == null) return;
    _pressedAt = event.position;
    _pressedRow = index;
  }

  void _pointerMove(PointerMoveEvent event) {
    final from = _pressedAt;
    if (from == null) return;
    if ((event.position - from).distance < _dragThreshold) return;
    final index = _pressedRow;
    _pressedAt = null;
    _pressedRow = -1;
    // The click this press would have been never happens: the desktop is about
    // to take the pointer, and the up event that would disarm it never arrives.
    _disarmNow();
    final entries = widget.panel.entries;
    if (index < 0 || index >= entries.length) return;
    widget.onDragOut(index, entries[index]);
  }

  void _pointerDone(PointerEvent event) {
    _pressedAt = null;
    _pressedRow = -1;
  }

  /// The row at a point on the screen, counted rather than hit-tested: the rows
  /// are all one height and the list is one column, so arithmetic knows this
  /// as well as the render tree does and needs nothing from it.
  int? _rowAt(Offset globalPosition) {
    final box =
        widget.viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || widget.rowHeight <= 0) return null;
    final local = box.globalToLocal(globalPosition);
    if (local.dy < 0 || local.dy > box.size.height) return null;
    final offset = widget.scroll.hasClients
        ? widget.scroll.position.pixels
        : 0.0;
    final index = ((local.dy + offset) / widget.rowHeight).floor();
    return index >= 0 && index < widget.panel.entries.length ? index : null;
  }

  @override
  Widget build(BuildContext context) {
    final panel = widget.panel;
    // The folder being left, for as long as it is fading out. Everything a row
    // is drawn from is taken from here while it is set, and nothing at all is
    // read off the panel, which has gone somewhere else — see [_FrozenListing].
    final frozen = widget.frozen;
    final entries = frozen?.entries ?? panel.entries;
    final cursorIndex = frozen?.cursor ?? panel.cursorIndex;
    final scroll = widget.scroll;
    final isActive = widget.isActive;
    final cursorKey = widget.cursorKey;
    final onActivate = widget.onActivate;
    final onContextMenu = widget.onContextMenu;
    final onSystemMenu = widget.onSystemMenu;
    final theme = context.watch<SettingsStore>().appearance;

    if (frozen == null && panel.error != null) {
      // Both keys are named on screen. This is a panel with no rows in it, so
      // there is nothing for the cursor to be on and no way to reach a button
      // by moving it — and a button nothing but the mouse can press is, in a
      // file manager driven from the keyboard, no button at all.
      return _PanelMessage(
        icon: Icons.error_outline,
        message: panel.error!,
        hint: tr('Ctrl+R to try again, Esc to go back'),
        action: TextButton(
          onPressed: panel.refresh,
          child: Text(tr('Retry')),
        ),
      );
    }
    if (entries.isEmpty) {
      // A folder being left was not loading anything; it was standing there
      // empty, and that is what fades out.
      final loading = frozen == null && panel.isLoading;
      return _PanelMessage(
        icon: loading ? Icons.hourglass_empty : Icons.folder_open,
        message: loading ? tr('Loading…') : tr('Empty'),
      );
    }

    // The whole of the sliding cursor hangs off this. With it false nothing
    // below is built, nothing listens to the scroll position, and a row is the
    // row it was before any of this existed.
    // Never over the copy: the mark moved when the cursor did, and the cursor
    // is in the folder that is arriving, not in the one on its way out.
    final sliding =
        frozen == null && theme.animates && theme.animateFileListCursor;
    // The other listing setting, and a different question: whether the rows
    // answer the pointer. With it false no row builds a MouseRegion, no row
    // holds a ticker, and a row is the row it was before any of this existed.
    // Nothing here is about scrolling or about rows arriving.
    // Nor is the copy live. Rows that are leaving do not answer a pointer,
    // and a ticker on each of them for one fade is a ticker for nothing.
    final lively =
        frozen == null && theme.animates && theme.animateLiveFileList;
    // The length is handed over on every move, not set at construction: a
    // controller built once keeps the length it was born with, and this one is
    // born before the settings are read.
    // Not told about the copy at all: what the mark follows is where the
    // keyboard is, and the keyboard is in the new folder from the moment the
    // key was answered. It picks the move up on the build that lets the copy
    // go, which is the first frame anybody can see the new rows on.
    if (frozen == null) {
      _slide.follow(
        panel.cursorIndex,
        panel.location,
        widget.rowHeight,
        _offset(),
        sliding: sliding,
        length: theme.animated(kCursorAnimationDuration),
      );
    }

    // Only worth interpolating when there is something to interpolate between:
    // with the text not inverted, the mark is the only thing that moves.
    final inverting = sliding && theme.invertCursorText && isActive;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 380;
        final widths = widget.widths.within(constraints.maxWidth, wide: wide);
        // What Page Up and Page Down move by. Told to the panel rather than
        // guessed at by the key handler, which has no idea how tall the window
        // is — see `PanelController.visibleRows`.
        panel.visibleRows = (constraints.maxHeight / widget.rowHeight)
            .floor()
            .clamp(1, 1 << 20);
        final list = Scrollbar(
          controller: scroll,
          child: ListView.builder(
            controller: scroll,
            itemExtent: widget.rowHeight,
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final isCursor = index == cursorIndex;
              final cursorMoving = _slide.progressFor(
                index,
                isCursor: isCursor,
                sliding: sliding,
              );
              return _FileRow(
                widths: widths,
                // Inside the row rather than on it, and not by taste. A
                // GlobalKey that moves from one row to the next takes the
                // element it sits on with it, and a row that hands its element
                // away cannot remember that it is the one the cursor has just
                // left — the lean it should be giving back would be given to a
                // fresh state that never had it. The box the key finds is the
                // same box either way: the content fills the row.
                cursorKey: isCursor ? cursorKey : null,
                entry: entry,
                theme: theme,
                wide: wide,
                isCursor: isCursor,
                lively: lively,
                // With the mark sliding underneath, a row painting its own
                // would be a second cursor, sitting still.
                paintCursorFill: !sliding,
                // Both of these are the same animation, and that is the point.
                // Handed only to the two rows they concern, so a slide rebuilds
                // two rows and not the listing.
                cursorMoving: cursorMoving,
                inversion: inverting ? cursorMoving : null,
                isPanelActive: isActive,
                isMarked: (frozen?.marked ?? panel.marked).contains(entry.path),
                size: frozen == null
                    ? panel.sizeOf(entry)
                    : frozen.sizeOf(entry),
                isSizing: frozen == null && panel.isSizing(entry),
                striped: theme.alternateRowShading && index.isOdd,
                // Faded while a quick search is on and this row is not one of
                // the answers.
                ghost: frozen == null
                    ? !panel.matchesSearch(entry)
                    : frozen.ghosted.contains(entry.path),
                // One click moves the cursor here and stops. Opening takes a
                // second click, close enough behind the first to be one gesture.
                //
                // A single click used to open the row the cursor was already on,
                // which meant clicking a row twice — for no reason, or to be
                // sure of it — entered folders and opened files nobody had asked
                // to open.
                //
                // The open is handed `entry`, not left to read the cursor back
                // out of the panel. Whether this panel was the active one, and
                // where its cursor had been sitting, are no part of what a
                // double click means.
                onTap: () {
                  onActivate();
                  panel.setCursor(index);
                  if (_completesDoubleClick(index)) widget.onActivateRow(entry);
                },
                onToggleMark: () {
                  onActivate();
                  panel.setCursor(index);
                  panel.toggleMark(entry);
                },
                onContextMenu: (position) {
                  onActivate();
                  panel.setCursor(index);
                  onContextMenu(position, entry.isParentLink ? null : entry);
                },
                // Only a real file on disk has a shell menu. A parent link is
                // not an entry, and a row served by a plugin has no path the
                // desktop knows about.
                onSystemMenu:
                    SystemMenu.isSupported &&
                        !entry.isParentLink &&
                        entry.path.scheme == VfsPath.localScheme
                    ? (position) {
                        onActivate();
                        panel.setCursor(index);
                        onSystemMenu(position, entry);
                      }
                    : null,
              );
            },
          ),
        );

        // A Listener around the rows rather than a recogniser inside them:
        // this has to see the pointer without competing for it, or a press
        // that turns out to be a click would have to be won back from the
        // arena and the rows would lose their taps to it.
        final touchable = Listener(
          key: widget.viewportKey,
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerDone,
          onPointerCancel: _pointerDone,
          child: list,
        );

        final dropMark = widget.dropRow == null
            ? null
            : _DropMark(
                row: widget.dropRow!,
                rowHeight: widget.rowHeight,
                scroll: scroll,
                colour: theme.accentColor,
                length: theme.animated(kDropMarkDuration),
              );

        // The copy is a picture of a folder that has been walked out of.
        // Nothing on it can be clicked, dragged or dropped into: the rows it
        // shows are not where the panel is any more, and the one thing worse
        // than a listing that flinches is one that answers for the wrong
        // folder while it fades.
        if (frozen != null) return IgnorePointer(child: touchable);

        if (!sliding) {
          return dropMark == null
              ? touchable
              : ClipRect(child: Stack(children: [touchable, dropMark]));
        }

        final cursor = cursorIndex;
        final entry = cursor >= 0 && cursor < entries.length
            ? entries[cursor]
            : null;
        if (entry == null) return list;

        return ClipRect(
          child: Stack(
            children: [
              // Under the rows, not over them. The rows are transparent where
              // they are not striped, so the mark shows through the one it is
              // on, and nothing has to be drawn on top of a name to put a
              // background behind it.
              CursorMark(
                slide: _slide,
                index: cursor,
                rowHeight: widget.rowHeight,
                scroll: scroll,
                colour: theme.cursorColor.withValues(
                  alpha:
                      (isActive ? 1.0 : 0.35) *
                      (panel.matchesSearch(entry) ? 1 : _FileRow._ghostAlpha),
                ),
              ),
              touchable,
              // Over the rows, unlike the cursor's mark: this one is an
              // outline around the folder about to be written into, and an
              // outline under the names it surrounds is not an outline.
              ?dropMark,
            ],
          ),
        );
      },
    );
  }
}


/// The edge of a column, and the hand on it.
///
/// **Nothing at all, until the pointer is over it.** A column edge is not
/// furniture — it is a place a hand can take hold of — so it draws a bar only
/// while it is being pointed at or pulled, and the cursor over it says what it
/// does better than any permanent line would.
///
/// The bar is three pixels and the reach is ten, which is not fussiness: at one
/// pixel the whole of it hid *behind the resize cursor*, so the answer to "am I
/// on it" was drawn where the pointer already was.
///
/// What is dragged is **characters**, not pixels: the width lands on whole ones
/// and stays between this column's own two ends, so a pull past either goes
/// nowhere rather than being remembered as a number the column cannot draw. The
/// keyboard reaches the same settings in Appearance — a control the keyboard
/// cannot reach does not exist.
/// Names a column's edge, so a test can take hold of the same three pixels a
/// hand does. The right-aligned columns put their heading at the *far* side of
/// the column, so finding the edge by the word beside it finds the wrong place.
Key columnGripKey(String column) => ValueKey('column-grip:$column');

class _ColumnGrip extends StatefulWidget {
  const _ColumnGrip({
    super.key,
    required this.settings,
    required this.width,
    required this.height,
    required this.digits,
    required this.min,
    required this.max,
    required this.apply,
  });

  final SettingsStore settings;

  /// The column's width now, which is what the drag starts from.
  final double width;
  final double height;

  /// Whether this column is counted in figures rather than in letters.
  final bool digits;

  final int min;
  final int max;

  /// Writes the new count into the settings. The column it belongs to is the
  /// caller's business; this only knows how to count.
  final AppearanceSettings Function(AppearanceSettings settings, int count)
  apply;

  /// How wide the grip itself is, reserved in the rows as well as the header.
  static const double reach = 10;

  @override
  State<_ColumnGrip> createState() => _ColumnGripState();
}

class _ColumnGripState extends State<_ColumnGrip> {
  bool _pointing = false;
  bool _pulling = false;

  /// Where the column was when this drag began. Kept because the setting moves
  /// in whole characters: reading the *drawn* width back on every update would
  /// quantise the same pull twice and make the column crawl behind the hand.
  double _from = 0;

  void _pull(double dx) {
    final theme = widget.settings.appearance;
    // Left widens: the column is to the right of this edge, and the name
    // column beside it gives up what this one takes.
    final count = columnCharactersFor(
      theme,
      _from - dx,
      digits: widget.digits,
    ).clamp(widget.min, widget.max);
    final now = widget.apply(theme, count);
    if (now == theme) return;
    widget.settings.updateAppearance((a) => widget.apply(a, count));
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.settings.appearance;
    final lit = _pointing || _pulling;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _pointing = true),
      onExit: (_) => setState(() => _pointing = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() {
          _pulling = true;
          _from = widget.width;
        }),
        onHorizontalDragUpdate: (details) =>
            _pull(details.localPosition.dx - _ColumnGrip.reach / 2),
        onHorizontalDragEnd: (_) => setState(() => _pulling = false),
        onHorizontalDragCancel: () => setState(() => _pulling = false),
        child: SizedBox(
          width: _ColumnGrip.reach,
          height: widget.height,
          child: Center(
            child: AnimatedContainer(
              duration: theme.animated(kColumnWidthDuration),
              curve: kBothCurve,
              width: lit ? 3 : 1,
              height: widget.height * (lit ? 0.8 : 0.5),
              decoration: BoxDecoration(
                color: theme.accentColor.withValues(alpha: lit ? 1 : 0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where a dragged selection would land, drawn around the row it would land in.
///
/// One of it, moved between rows, for the same reason the cursor is one mark
/// that slides: a highlight that is switched off on one row and on at the next
/// says two separate things a hundred milliseconds apart, where a mark that
/// travels says one thing about where the drop is going. Dragging down a
/// listing of folders is exactly when that matters — the eye is following its
/// own hand, and the outline is what it is following.
class _DropMark extends StatelessWidget {
  const _DropMark({
    required this.row,
    required this.rowHeight,
    required this.scroll,
    required this.colour,
    required this.length,
  });

  final int row;
  final double rowHeight;
  final ScrollController scroll;
  final Color colour;
  final Duration length;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // The scroll as well: the listing walks itself while a drag rests near
      // its edge, and the mark is placed in viewport pixels.
      animation: scroll,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.18),
            border: Border.all(color: colour, width: 1.5),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
      builder: (context, child) => AnimatedPositioned(
        duration: length,
        curve: kBothCurve,
        left: 0,
        right: 0,
        top: row * rowHeight - (scroll.hasClients ? scroll.position.pixels : 0),
        height: rowHeight,
        child: child!,
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.cursorKey,
    required this.widths,
    required this.entry,
    required this.theme,
    required this.wide,
    required this.isCursor,
    required this.lively,
    required this.cursorMoving,
    required this.paintCursorFill,
    required this.inversion,
    required this.isPanelActive,
    required this.isMarked,
    required this.size,
    required this.isSizing,
    required this.striped,
    required this.ghost,
    required this.onTap,
    required this.onToggleMark,
    required this.onContextMenu,
    required this.onSystemMenu,
  });

  /// Marks the row the keyboard is on for whoever needs to find it on screen —
  /// the menus, which hang off it. Null on every other row.
  ///
  /// Carried down and put on the content rather than left on the row itself:
  /// see where it is handed over.
  final GlobalKey? cursorKey;

  /// How wide the set columns are drawn, handed down rather than worked out
  /// here: measuring a font costs about what laying out the row costs, and
  /// there are forty rows on screen.
  final ColumnWidths widths;

  final FileEntry entry;
  final AppearanceSettings theme;
  final bool wide;
  final bool isCursor;

  /// Whether the row answers the pointer at all: [_Lively] is only built with
  /// this true, and with it false the row has no MouseRegion and no ticker.
  final bool lively;

  /// How far this row is into being the cursor, or null when the cursor is not
  /// moving — for this row, or at all. The mark's own animation: whatever a row
  /// does about the cursor, it does at the rate the cursor is arriving.
  final Animation<double>? cursorMoving;

  /// False when the mark is a separate thing sliding under the listing. A row
  /// painting its own fill then would be a second cursor, sitting still.
  final bool paintCursorFill;

  /// How far this row's text is towards its inverted colour, or null — which is
  /// every row on every ordinary frame, and every row at all when the text is
  /// not inverted under the cursor.
  ///
  /// The mark sliding while the text flipped at one end or the other would be
  /// two events where there was one. Only the row being left and the row being
  /// arrived at are ever handed one of these, so a slide rebuilds two rows.
  final Animation<double>? inversion;

  final bool isPanelActive;
  final bool isMarked;

  /// Known size: the file size, or a measured directory total.
  final int? size;
  final bool isSizing;
  final bool striped;

  /// Not one of the rows quick search is pointing at. Still there, still
  /// clickable, still countable — just faded, so the answers stand out without
  /// the listing rearranging itself under the user's eyes.
  final bool ghost;

  /// Faint enough to fall back, dark enough to still be read: the point is to
  /// pick the answers out of the folder, not to pretend the rest went away.
  static const double _ghostAlpha = 0.32;
  final VoidCallback onTap;
  final VoidCallback onToggleMark;
  final ValueChanged<Offset> onContextMenu;

  /// The right button held down. Null where the desktop has no menu to offer.
  final ValueChanged<Offset>? onSystemMenu;

  /// What the row's text says about itself with no cursor involved: marked,
  /// a folder, or a plain file.
  Color get _plain => isMarked
      ? theme.markedColor
      : entry.isDirectory
      ? theme.directoryColor
      : theme.panelForeground;

  @override
  Widget build(BuildContext context) {
    final inversion = this.inversion;
    if (inversion == null) {
      // Only on the active panel: the inactive cursor is painted at a third of
      // its opacity, so what the row sits on is mostly the panel and inverting
      // against the cursor colour would be inverting against the wrong thing.
      final onCursor = isCursor && isPanelActive;
      return _body(onCursor && theme.invertCursorText
          ? theme.cursorForeground
          : _plain);
    }

    // The mark is on its way onto this row or off it, so the text is on its way
    // too — at the same rate, off the same curve. Rebuilds this row and no
    // other.
    return AnimatedBuilder(
      animation: inversion,
      builder: (context, _) => _body(
        Color.lerp(_plain, theme.cursorForeground, inversion.value)!,
      ),
    );
  }

  Widget _body(Color base) {
    // Faded, not hidden and not recoloured: whatever the row already said about
    // itself — folder, marked, on the cursor — it goes on saying, more quietly.
    // A search that removed rows would move every other row under the pointer,
    // and one that recoloured them would lose what the colours already mean.
    final color = ghost ? base.withValues(alpha: base.a * _ghostAlpha) : base;

    final background = isCursor && paintCursorFill
        ? theme.cursorColor.withValues(
            alpha: (isPanelActive ? 1.0 : 0.35) * (ghost ? _ghostAlpha : 1),
          )
        : striped
        ? theme.alternateRowColor
        : Colors.transparent;

    // Directories and files carry their own weight the way they carry their own
    // colour, and a `..` row is a directory in this as in everything else.
    final rowWeight = entry.isDirectory
        ? theme.directoryFontWeight
        : theme.fileFontWeight;

    final style = TextStyle(
      color: color,
      fontSize: theme.fontSize,
      fontFamily: theme.fileFamily,
      fontWeight: rowWeight.weight,
    );

    // No double tap. With one on the same detector every single tap has to
    // wait out the double-tap window first, which is most of what made a
    // touch screen feel like it was ignoring the first press or two.
    //
    // Built through a function of the two numbers a live row can be at, so that
    // the resting row and the answering row are the same row, differing by
    // them. At rest they are 0 and 1, which is what a listing with the setting
    // off is handed and what it has always drawn.
    Widget content(double lean, double scale) => GestureDetector(
      key: cursorKey,
      onTap: onTap,
      child: PressAndHold(
        onMenu: onContextMenu,
        onHold: onSystemMenu,
        child: Container(
          color: background,
          padding: EdgeInsets.symmetric(
            horizontal: 6,
            vertical: theme.density.verticalPadding,
          ),
          child: Row(
            children: [
              // The lean, taken out of the name's width. First in the row, so
              // the icon and the name move together and the columns to the
              // right stay where they are — a name that took the size and the
              // date with it would stop the columns being columns.
              SizedBox(width: lean),
              GestureDetector(
                // Clicking the icon marks, which is the mouse equivalent of Insert.
                onTap: entry.isParentLink ? null : onToggleMark,
                // Drawn larger, not laid out larger: a transform paints and
                // costs the layout nothing, so an icon growing cannot push the
                // name along or change how much of it fits. Both this and the
                // name grow from their left edge, so the row swells rightwards
                // from one place instead of from two.
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.centerLeft,
                  child: _RowIcon(
                    entry: entry,
                    theme: theme,
                    isMarked: isMarked,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    wide && !entry.isDirectory && entry.extension.isNotEmpty
                        ? entry.baseName
                        : entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ),
              // The gaps the header's grips stand over. Reserved here as well,
              // so an edge is taken hold of over a real space between two
              // columns rather than over the last letter of a name.
              if (wide) ...[
                const SizedBox(width: _ColumnGrip.reach),
                SizedBox(
                  width: widths.extension,
                  child: Text(
                    entry.isDirectory ? '' : entry.extension,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ],
              const SizedBox(width: _ColumnGrip.reach),
              SizedBox(
                width: widths.size,
                child: Text(
                  _sizeLabel(),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
              if (wide) ...[
                const SizedBox(width: _ColumnGrip.reach),
                SizedBox(
                  width: widths.modified,
                  child: Text(
                    formatDate(entry.modified),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (!lively) return content(0, 1);
    return LivelyRow(
      theme: theme,
      isCursor: isCursor,
      cursorMoving: cursorMoving,
      builder: content,
    );
  }

  /// Directories show `<DIR>` until Space measures them, then the real total.
  String _sizeLabel() {
    if (entry.isParentLink) return '[..]';
    if (!entry.isDirectory) return formatSize(entry.size);
    if (isSizing) return '…';
    return size == null ? '<DIR>' : formatSize(size!);
  }

  static IconData iconFor(FileEntry entry) => _iconFor(entry);

  static IconData _iconFor(FileEntry entry) {
    if (entry.isParentLink) return Icons.subdirectory_arrow_left;
    if (entry.isLink) return Icons.link;
    if (entry.isDirectory) return Icons.folder;
    return switch (entry.extension) {
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'webp' ||
      'bmp' ||
      'svg' => Icons.image_outlined,
      'mp4' || 'mkv' || 'mov' || 'avi' || 'webm' => Icons.movie_outlined,
      'mp3' || 'flac' || 'wav' || 'ogg' || 'm4a' => Icons.music_note_outlined,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' || 'xz' => Icons.archive_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'md' || 'markdown' => Icons.article_outlined,
      'py' ||
      'dart' ||
      'js' ||
      'ts' ||
      'c' ||
      'cpp' ||
      'h' ||
      'rs' ||
      'go' => Icons.code,
      'txt' ||
      'json' ||
      'yaml' ||
      'yml' ||
      'xml' ||
      'ini' ||
      'log' => Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

/// The picture at the head of a row: the built-in shape, or the desktop's own.
///
/// Which one is a setting, and both are worth having. The built-in set is one
/// shape per kind of thing and looks the same on every machine; the desktop's own
/// is what the rest of the machine shows for that file, which is what makes a
/// `.psd` or a `.blend` recognisable at a glance.
///
/// The native icon is asked for once per *kind* and remembered, so scrolling a
/// large folder costs nothing. Until it arrives — and if the shell has none — the
/// built-in shape stands in, so a row is never blank and never jumps about.
class _RowIcon extends StatefulWidget {
  const _RowIcon({
    required this.entry,
    required this.theme,
    required this.isMarked,
    required this.color,
  });

  final FileEntry entry;
  final AppearanceSettings theme;
  final bool isMarked;
  final Color color;

  @override
  State<_RowIcon> createState() => _RowIconState();
}

class _RowIconState extends State<_RowIcon> {
  ui.Image? _native;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(_RowIcon old) {
    super.didUpdateWidget(old);
    // Rows are recycled as the list scrolls, so the same widget shows a different
    // entry — and the icon has to follow it.
    if (old.entry.path != widget.entry.path ||
        old.theme.nativeIcons != widget.theme.nativeIcons) {
      _native = null;
      _ask();
    }
  }

  void _ask() {
    if (!widget.theme.nativeIcons || !NativeIcons.isSupported) return;
    if (widget.entry.isParentLink) return;
    if (widget.entry.path.scheme != VfsPath.localScheme) return;

    final native = widget.entry.path.toNativePath();
    final key = NativeIcons.cacheKeyFor(
      native,
      isDirectory: widget.entry.isDirectory,
    );

    // Already here: taken without a frame in between, so a listing that has been
    // scrolled once does not flicker when it is scrolled back.
    final ready = NativeIcons.ready[key];
    if (ready != null) {
      _native = ready;
      return;
    }

    unawaited(
      NativeIcons.of(native, isDirectory: widget.entry.isDirectory).then((image) {
        if (!mounted || image == null) return;
        // The row may have been recycled onto another entry while this was in
        // flight; only draw it if it is still the right one.
        final still = NativeIcons.cacheKeyFor(
          widget.entry.path.toNativePath(),
          isDirectory: widget.entry.isDirectory,
        );
        if (still != key) return;
        setState(() => _native = image);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.theme.fontSize + 2;

    // Marked wins over everything: what is about to be copied or deleted matters
    // more than what kind of file it is.
    if (widget.isMarked) {
      return Icon(Icons.check_box_outlined, size: size, color: widget.color);
    }

    final image = _native;
    if (image == null || !widget.theme.nativeIcons) {
      return Icon(
        _FileRow.iconFor(widget.entry),
        size: size,
        color: widget.color,
      );
    }

    final drawn = RawImage(
      image: image,
      width: size,
      height: size,
      // The icon is 16 or 32 pixels square and the row asks for whatever the font
      // size gives; smoothing keeps it from going crunchy either way.
      filterQuality: pictureSmoothing,
    );

    if (!widget.theme.monochromeIcons) return drawn;

    // Shape *and shading* from the desktop, colour from the palette. See
    // [IconTint]: the icon is desaturated and multiplied by the row's colour, the
    // way a tint is done in a shader. `srcIn` was tried first and was wrong — it
    // replaces every pixel with one flat colour, which is a paint fill and throws
    // away the detail that makes an icon recognisable.
    return ColorFiltered(
      colorFilter: IconTint.of(widget.color),
      child: drawn,
    );
  }
}

/// The marked colour, taken far enough to be read on the panel's status strip.
///
/// The summary line is drawn on the header's fill, which is not what the marked
/// colour was chosen against — in the shipped palette the two sit at 2.5:1,
/// which is not readable at all. [legibleInk] keeps the hue,
/// which is what says something is marked, and moves the lightness to whichever
/// end the strip leaves free.
///
/// Public so a test can ask it directly: what has to hold is a ratio, and a
/// ratio read off a rendered pixel is a ratio read twice.
Color markedTextOnStrip(AppearanceSettings theme) => legibleInk(
  theme.markedColor,
  on: theme.effectiveHeaderBackground,
  fallback: theme.headerForeground,
);

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.panel});

  final PanelController panel;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final marked = panel.markedCount;

    // Whatever has the panel says what goes here: the counts below are about a
    // listing that is not on screen.
    final attachment = panel.attachment;
    if (attachment != null) {
      return ListenableBuilder(
        listenable: attachment,
        builder: (context, _) => _StatusText(
          text: attachment.status ?? attachment.title,
          color: theme.headerForeground.withValues(alpha: 0.75),
        ),
      );
    }

    // Total Commander's wording: what is selected against what is there.
    var text = marked > 0
        ? tr('{markedSize} / {totalSize} in {marked} / {count} selected', {
            'markedSize': formatSize(panel.markedBytes),
            'totalSize': formatSize(panel.totalBytes),
            'marked': marked,
            'count': panel.itemCount,
          })
        : tr('{count} item(s)', {'count': panel.itemCount});

    // In a result set the rows come from all over the tree, so the one thing
    // the listing cannot tell you is where the file under the cursor lives.
    final folder = panel.isVirtual ? panel.cursorEntry?.path.parent : null;
    if (folder != null) text = '$text  ·  ${folder.display}';

    return _StatusText(
      text: text,
      color: marked > 0
          ? markedTextOnStrip(theme)
          : theme.headerForeground.withValues(alpha: 0.75),
    );
  }

}

/// The status strip itself, without any opinion about what it says.
class _StatusText extends StatelessWidget {
  const _StatusText({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;

    return Container(
      height: theme.chromeRowHeight,
      width: double.infinity,
      color: theme.effectiveHeaderBackground,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: theme.fontSize - 1),
      ),
    );
  }
}

class _PanelMessage extends StatelessWidget {
  const _PanelMessage({
    required this.icon,
    required this.message,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String message;

  /// The keys that get out of here, for a state that has no rows to move
  /// through.
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final color = theme.panelForeground.withValues(alpha: 0.6);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: color, fontSize: theme.fontSize),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: color.withValues(alpha: 0.75),
                  fontSize: theme.fontSize * 0.9,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}
