import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../core/plugins/graph.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../motion.dart';
import '../../core/i18n/i18n.dart';
import '../viewer/find_box.dart';
import '../widgets/context_menu.dart' show kMenuCornerRadius;
import '../widgets/fade_through.dart';
import '../widgets/keyboard_scrollable.dart';
import '../widgets/slide_panel.dart';
import 'commit_graph.dart' show GraphColours;
import 'node_layout.dart';
import 'plugin_table.dart' show appearanceOf, legibleOn;

/// How big a reroute is drawn — a dot, not a box.
const double kRerouteSize = 22;

/// Whether a node is a bend in a wire rather than a thing that does anything.
///
/// **Worked out rather than declared**, because no format says it in a way the
/// others share: LiteGraph and ComfyUI call the class `Reroute`, and the rest
/// of the shape is the giveaway anywhere else — nothing written on it, one
/// wire in, one wire out. Drawn as a box, a reroute is a box with nothing in
/// it, several times the size of the thing it actually is; drawn as a dot, the
/// wire simply bends where its author bent it.
bool isReroute(GraphNode node) {
  if (node.fields.isNotEmpty) return false;
  if (node.inputs.length > 1 || node.outputs.length > 1) return false;
  final name = node.title.toLowerCase();
  return name.isEmpty || name.contains('reroute');
}

/// The marks a reader may ask for on a node, and what each is drawn as.
///
/// **A reader names a badge; it never names a picture.** The same rule as the
/// roles and the colours — `muted` is a thing that is true of a node, and what
/// that looks like is the host's business. A name nobody here knows is drawn as
/// nothing, which is better than a box with a question mark in it.
const Map<String, IconData> kNodeBadges = {
  'muted': Icons.block,
  'bypassed': Icons.block,
  'disabled': Icons.block,
  'error': Icons.error_outline,
  'warning': Icons.warning_amber_rounded,
  'locked': Icons.lock_outline,
  'pinned': Icons.push_pin_outlined,
  'link': Icons.link,
  'starred': Icons.star_outline,
};

/// A graph of boxes and the wires between them, drawn from a [GraphDocument].
///
/// **The host owns this canvas and every colour on it.** A reader turns a
/// ComfyUI workflow or an n8n export into the document and hands it over; what
/// a node is *called* is the plugin's, what it *looks like* is not. The same
/// split as a grammar and the scanner, and for the same reason: a box is as wide
/// as its text in the font the user chose, which the plugin cannot know.
///
/// Segment 1 of the plan: boxes, pins, wires, groups, notes, pan, zoom and fit.
/// The keyboard is segment 2 and is deliberately not here yet — the mouse can
/// reach everything this draws, which is not the same as it being finished.
class NodeGraphView extends StatefulWidget {
  const NodeGraphView({
    super.key,
    required this.graph,
    this.hasKeyboard = true,
    this.fullScreen = true,
  });

  final GraphDocument graph;

  /// Whether this is the thing being worked in. A canvas in the panel beside
  /// the one being typed in answers no keys at all.
  final bool hasKeyboard;

  /// Whether there is a whole window to work in.
  ///
  /// **The properties panel is full-screen only.** In a quick view (Ctrl+Q) the
  /// canvas is a quarter of the window already; a panel over a quarter leaves
  /// neither the graph nor the properties readable, and one unreadable thing is
  /// better than two. The same line the structure panel is drawn at.
  final bool fullScreen;

  @override
  State<NodeGraphView> createState() => _NodeGraphViewState();
}

class _NodeGraphViewState extends State<NodeGraphView>
    with TickerProviderStateMixin {
  /// What the view is looking at: a scale and an offset, in document units.
  double _scale = 1;
  Offset _origin = Offset.zero;

  /// The node the keyboard is on, and the whole point of the canvas.
  ///
  /// **Rule number one.** Every node viewer anybody ships is mouse-first; this
  /// one has a focus from the moment it opens and the viewport follows it, so a
  /// workflow can be read without touching the pointer at all.
  int _focus = 0;

  /// Where the focus has been, for Backspace. A walk through a graph is a walk
  /// somebody wants to undo.
  final List<int> _history = [];

  /// How the focus arrived: the node it came from, and whether it walked
  /// forwards. That is what `↑` and `↓` need — the siblings are the *other*
  /// ends of the wire that was just followed, and nothing else knows it.
  int _cameFrom = -1;
  bool _cameForwards = true;

  /// The glide. The viewport moves to the focus rather than jumping, which is
  /// what shows the reader the wire they have just walked along — and it is off
  /// the application's own animation scale, like everything else that moves.
  late final AnimationController _glide = AnimationController(vsync: this);
  Offset _from = Offset.zero;
  Offset _to = Offset.zero;

  /// The glide carries the **scale** too, which is rule number two: a view that
  /// changes size between two frames is a blink, and the whole picture blinking
  /// is the loudest one there is.
  double _scaleFrom = 1;
  double _scaleTo = 1;

  /// The find box, which is the reading's own — see [FindBox].
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode(debugLabel: 'find in graph');
  final FocusNode _keys = FocusNode(debugLabel: 'node canvas');
  bool _finding = false;
  List<int> _matches = const [];
  int _match = 0;

  /// Whether the focused node's own page is out, and how wide it is.
  ///
  /// **Nothing is asked of the plugin to fill it.** Everything a properties
  /// pane can show — the fields, the pins, the id — is already in the document
  /// the reader sent, so this is the same picture read a second way rather than
  /// a round trip on every arrow press. It is why segment 4 turned out to be a
  /// panel over the canvas instead of the split the plan first reached for: a
  /// split would re-lay-out the graph, and losing your place is the one thing a
  /// reader must not do to you.
  bool _properties = false;
  double _propertiesShare = kSlidePanelFraction;
  final ScrollController _propertiesScroll = ScrollController();

  /// Whether the panel stays when the canvas is pressed. The slide opens on an
  /// event, a press in the content folds it away, and the pin says otherwise.
  bool _pinned = false;

  /// Whether the keyboard is in the panel rather than on the canvas. Enter
  /// hands it over, Escape hands it back — a panel you cannot get into, or
  /// cannot get out of, fails rule number one either way.
  bool _inPanel = false;

  /// Whether the remembered state has been read yet. Once, not on every
  /// dependency change: it is a starting point, not a leash.
  bool _restored = false;

  /// Whether the view has been placed over the graph yet. The first frame is
  /// the only one that knows how big the canvas is, so the fit waits for it.
  bool _placed = false;

  /// What the scale was when a pinch began, so the gesture's own factor applies
  /// to that rather than compounding frame by frame.
  double _pinch = 1;

  /// What the last keyboard step followed, in words — `KSampler.LATENT →
  /// VAEDecode.samples`. Null while nothing has been said lately.
  ///
  /// **Because this canvas is walked by keyboard.** An arrow moves the view to
  /// a node the reader has not seen yet; without the wire being named, the
  /// press is a guess that moved the picture. It is said where they are
  /// looking rather than in a status line at the edge, and it goes away by
  /// itself — a label that stayed would be read as part of the graph.
  String? _said;
  Timer? _saying;

  /// The box the mouse is over, or -1. Drawn a step brighter; it is also what
  /// says the canvas answers the pointer at all.
  int _hovered = -1;

  /// Where the second press landed. A double tap carries no position of its
  /// own, and "which node was that" is the whole question here.
  Offset _doubleAt = Offset.zero;

  /// Nodes whose folded state is the **opposite** of what the file said.
  ///
  /// Held as a difference rather than as the state itself, so a document that
  /// arrives with half its nodes collapsed keeps that and `C` still flips
  /// whichever one the keyboard is on. Reading is not editing: nothing here
  /// goes back to the file.
  final Set<String> _folded = {};

  /// The fold, in flight. **Rule number two**: a box that changes height
  /// between two frames is a blink, and a graph full of them is a graph that
  /// looks broken. One controller drives every node folding at once — which is
  /// what `Shift+C` does — and `_foldFrom` remembers what each of them looked
  /// like when the key was pressed.
  late final AnimationController _fold = AnimationController(vsync: this);
  Map<String, double> _foldFrom = const {};

  /// Whether the whole graph is drawn small in the corner.
  ///
  /// Out on a page and away in a panel, by default and for the reason the plan
  /// gives: a minimap in a quarter of the window costs more than it returns.
  late bool _minimap = widget.fullScreen;

  /// How far a scroll notch moves the zoom. Multiplicative, so a notch means
  /// the same thing at every scale.
  static const double _zoomStep = 1.12;
  static const double _minimumScale = 0.1;
  static const double _maximumScale = 4;

  /// What a node takes when the document did not say.
  static const double _defaultWidth = 180;

  /// How much room a framed node leaves round itself, as a multiple of its own
  /// size, and the most `F` will magnify anything. A box filling the window
  /// says nothing about what it is joined to.
  static const double _frameMargin = 2.2;
  static const double _frameMost = 2.0;

  /// Where each node sits and how big it is, in document units.
  ///
  /// Measured here rather than in the reader, because the height of a box is
  /// the height of the text in it and the text is drawn in the user's own font.
  Map<String, Rect> _boxes(AppearanceSettings theme) {
    final sizes = <String, Size>{};
    for (final node in widget.graph.nodes) {
      if (isReroute(node)) {
        // A reroute is a bend in a wire that somebody gave a node to. Drawn as
        // a box it is a box with nothing in it, three times the size of the
        // thing it actually is.
        sizes[node.id] = const Size(kRerouteSize, kRerouteSize);
        continue;
      }
      final width = node.width ?? _defaultWidth;
      final rows = math.max(
        node.inputs.length + node.outputs.length,
        node.fields.length,
      );
      // The fold is a factor rather than a switch, so the box closes over a
      // couple of hundred milliseconds and the wires follow it down.
      final open = 1 - _foldFactor(node);
      sizes[node.id] = Size(
        width,
        _titleHeight(theme) + rows * _rowHeight(theme) * open + _padding * 2,
      );
    }

    // **Where the file did not say.** The ComfyUI API export is a dictionary of
    // nodes and their inputs and carries no coordinates at all — so the host
    // works them out, which it can and the reader cannot: the spacing depends
    // on the sizes just measured above, in the font the user chose.
    final laid = widget.graph.layout == GraphLayout.layered
        ? const LayeredLayout().run(widget.graph, (node) {
            final size = sizes[node.id]!;
            return Size2(size.width, size.height);
          })
        : const LayeredPlacement({}, {});
    final placed = laid.places;
    _routes = laid.routes;

    final boxes = <String, Rect>{};
    for (final node in widget.graph.nodes) {
      final size = sizes[node.id]!;
      final at = placed[node.id];
      boxes[node.id] = Rect.fromLTWH(
        at?.x ?? node.x,
        at?.y ?? node.y,
        size.width,
        size.height,
      );
    }
    return boxes;
  }

  /// Whether this node is drawn folded: what the file said, flipped by
  /// whatever `C` has been pressed on since.
  bool _isCollapsed(GraphNode node) =>
      _folded.contains(node.id) ? !node.collapsed : node.collapsed;

  /// How folded a node is drawn *right now*: 1 folded, 0 open, and in between
  /// while the fold is running.
  double _foldFactor(GraphNode node) {
    final target = _isCollapsed(node) ? 1.0 : 0.0;
    final from = _foldFrom[node.id];
    if (from == null || !_fold.isAnimating) return target;
    return ui.lerpDouble(from, target, _fold.value)!;
  }

  /// Flips the fold on [ids] and animates every one of them together.
  void _foldThese(Iterable<String> ids) {
    final before = {
      for (final node in _nodes) node.id: _foldFactor(node),
    };
    setState(() {
      for (final id in ids) {
        if (!_folded.remove(id)) _folded.add(id);
      }
      _foldFrom = before;
    });
    _fold
      ..duration = motionOf(context, kNodeFoldDuration)
      ..forward(from: 0);
  }

  double _titleHeight(AppearanceSettings theme) => theme.fontSize + 12;
  double _rowHeight(AppearanceSettings theme) => theme.fontSize + 6;
  static const double _padding = 6;

  /// Everything the graph occupies, boxes and groups and notes together.
  Rect _bounds(Map<String, Rect> boxes) {
    var union = boxes.values.isEmpty ? Rect.zero : boxes.values.first;
    for (final box in boxes.values) {
      union = union.expandToInclude(box);
    }
    for (final group in widget.graph.groups) {
      union = union.expandToInclude(
        Rect.fromLTWH(group.x, group.y, group.width, group.height),
      );
    }
    for (final note in widget.graph.notes) {
      union = union.expandToInclude(
        Rect.fromLTWH(note.x, note.y, note.width, note.height),
      );
    }
    // The way round a wire takes counts as part of the picture: a loop that
    // runs under the graph and is cut off by "fit everything" is a wire that
    // goes nowhere as far as the reader can tell.
    for (final route in _routes.values) {
      for (final point in route) {
        union = union.expandToInclude(
          Rect.fromLTWH(point.x, point.y, 1, 1),
        );
      }
    }
    return union;
  }

  /// Puts the whole graph on screen, with a margin so nothing touches an edge.
  void _fit(Size size, Map<String, Rect> boxes) {
    if (boxes.isEmpty || size.isEmpty) return;
    final bounds = _bounds(boxes).inflate(24);
    if (bounds.width <= 0 || bounds.height <= 0) return;

    final scale = math
        .min(size.width / bounds.width, size.height / bounds.height)
        .clamp(_minimumScale, 1.0);
    final origin = Offset(
      bounds.left - (size.width / scale - bounds.width) / 2,
      bounds.top - (size.height / scale - bounds.height) / 2,
    );

    // The first fit is where the picture *starts*: there is nothing to move
    // from, so it is set rather than animated. Every fit after that is a
    // movement somebody asked for, and it is shown.
    if (!_placed) {
      setState(() {
        _scale = scale;
        _origin = origin;
        _placed = true;
      });
      return;
    }
    _glideTo(origin, scale: scale);
  }

  /// Zooms about a point on the canvas, so what is under the pointer stays
  /// under it — the only zoom that does not feel like the picture ran away.
  void _zoomAt(Offset local, double by) {
    final before = _origin + local / _scale;
    final scale = (_scale * by).clamp(_minimumScale, _maximumScale);
    setState(() {
      _scale = scale;
      _origin = _within(before - local / scale);
    });
  }

  @override
  void initState() {
    super.initState();
    _focus = _firstSource();
    _glide.addListener(() {
      setState(() {
        _origin = Offset.lerp(_from, _to, _glide.value)!;
        _scale = ui.lerpDouble(_scaleFrom, _scaleTo, _glide.value)!;
      });
    });
    _fold.addListener(() => setState(() {}));
    _takeKeyboard();
  }

  @override
  void didUpdateWidget(NodeGraphView old) {
    super.didUpdateWidget(old);
    // A different graph is a different picture: it gets its own fit rather than
    // whatever the last one was left at.
    if (!identical(old.graph, widget.graph)) _placed = false;
    // Not while the keyboard has been handed to the panel: a rebuild from
    // above would otherwise pull it back out from under the reader.
    if (widget.hasKeyboard && !_keys.hasFocus && !_inPanel) {
      _keys.requestFocus();
    }
  }

  /// What the panel was left at last time, read once.
  ///
  /// **This is the only way it opens without a key being pressed.** Nothing
  /// here looks at the file and decides it wants a panel.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    final store = _store();
    if (store == null) return;
    setState(() {
      _propertiesShare = store.slidePanelShare ?? kSlidePanelFraction;
      _pinned = store.slidePanelPinned;
      _properties = store.slidePanelOpen;
      _minimap = store.nodeMinimap ?? widget.fullScreen;
    });
  }

  /// The store, or null where there is none — a canvas is pumped on its own in
  /// tests, and a remembered width is not worth a crash on the way to drawing.
  SettingsStore? _store() {
    try {
      return context.read<SettingsStore>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// Folds every node, and opens them all again only once they are all folded.
  ///
  /// Not by majority: at two nodes with one of each, "most of them" is a coin
  /// toss and the key does the opposite of what the eye expects. One box still
  /// open means there is folding left to do.
  void _foldAll() {
    final folding = _nodes.any((node) => !_isCollapsed(node));
    _foldThese([
      for (final node in _nodes)
        if (_isCollapsed(node) != folding) node.id,
    ]);
  }

  void _showProperties(bool open) {
    setState(() {
      _properties = open;
      if (!open) _inPanel = false;
    });
    unawaited(_store()?.setSlidePanelOpen(open) ?? Future<void>.value());
  }

  /// **Taken, not asked for.** `autofocus` only lands where nothing else in the
  /// scope holds the keyboard, and something always does: a viewer is not a
  /// route, so it opens inside the scope the panel F3 was pressed in, and that
  /// panel keeps what it has. The canvas answered no keys at all until
  /// something was clicked — the very trap `KeyboardScrollable` documents, and
  /// walked straight into.
  void _takeKeyboard() {
    if (!widget.hasKeyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.hasKeyboard && !_keys.hasFocus) {
        _keys.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _saying?.cancel();
    _glide.dispose();
    _fold.dispose();
    _query.dispose();
    _queryFocus.dispose();
    _keys.dispose();
    _propertiesScroll.dispose();
    super.dispose();
  }

  List<GraphNode> get _nodes => widget.graph.nodes;

  /// Where the keyboard is, for a test to ask. There is nothing on screen that
  /// says "node index 2", and asserting about pixels would be asserting about
  /// the drawing rather than about the walk.
  @visibleForTesting
  int get debugFocus => _focus;

  /// What the viewport is at, for a test to ask. Pixels would answer the same
  /// question by measuring the drawing rather than the gesture.
  @visibleForTesting
  double get debugScale => _scale;

  @visibleForTesting
  Offset get debugOrigin => _origin;

  /// Where the boxes came out, for a test to ask whether a node folded or a
  /// reroute was drawn as a dot. Pixels would answer by measuring the drawing.
  @visibleForTesting
  Map<String, Rect> get debugBoxes => _lastBoxes;

  @visibleForTesting
  bool get debugMinimap => _minimap;

  /// A node nothing comes into — where a graph is read from. The first one in
  /// drawn order, or simply the first node when everything has a parent.
  int _firstSource() {
    final targets = {for (final link in widget.graph.links) link.to};
    for (var i = 0; i < _nodes.length; i++) {
      if (!targets.contains(_nodes[i].id)) return i;
    }
    return 0;
  }

  int _indexOf(String id) => _nodes.indexWhere((node) => node.id == id);

  /// The nodes a wire leads to from [from], in the order they are drawn.
  List<int> _next(int from, {required bool forwards}) {
    if (from < 0 || from >= _nodes.length) return const [];
    final id = _nodes[from].id;
    final found = <int>[];
    for (final link in widget.graph.links) {
      final other = forwards
          ? (link.from == id ? link.to : null)
          : (link.to == id ? link.from : null);
      if (other == null) continue;
      final at = _indexOf(other);
      if (at >= 0 && !found.contains(at)) found.add(at);
    }
    found.sort((a, b) => _drawnOrder(a).compareTo(_drawnOrder(b)));
    return found;
  }

  /// Top to bottom, then left to right — the order a reader's eye takes them
  /// in, which is what `↑` and `↓` have to agree with to mean anything.
  double _drawnOrder(int index) => _nodes[index].y * 10000 + _nodes[index].x;

  /// Every node in an order that respects the wires: a source before what it
  /// feeds. Cycles are not a crash — whatever is left over goes on the end in
  /// drawn order, because a graph that loops is still a graph to be read.
  late final List<int> _topological = _sorted();

  List<int> _sorted() {
    final incoming = <int, int>{};
    final out = <int, List<int>>{};
    for (var i = 0; i < _nodes.length; i++) {
      incoming[i] = 0;
      out[i] = [];
    }
    for (final link in widget.graph.links) {
      final from = _indexOf(link.from);
      final to = _indexOf(link.to);
      if (from < 0 || to < 0) continue;
      out[from]!.add(to);
      incoming[to] = incoming[to]! + 1;
    }

    final ready = [
      for (var i = 0; i < _nodes.length; i++)
        if (incoming[i] == 0) i,
    ]..sort((a, b) => _drawnOrder(a).compareTo(_drawnOrder(b)));
    final order = <int>[];
    while (ready.isNotEmpty) {
      final next = ready.removeAt(0);
      order.add(next);
      for (final child in out[next]!) {
        incoming[child] = incoming[child]! - 1;
        if (incoming[child] == 0) ready.add(child);
      }
      ready.sort((a, b) => _drawnOrder(a).compareTo(_drawnOrder(b)));
    }
    for (var i = 0; i < _nodes.length; i++) {
      if (!order.contains(i)) order.add(i);
    }
    return order;
  }

  /// Says what the last step followed, for as long as it is worth reading.
  void _say(String what) {
    _saying?.cancel();
    setState(() => _said = what);
    _saying = Timer(kNodeStepSaidLife, () {
      if (mounted) setState(() => _said = null);
    });
  }

  /// The wire between two nodes, in words, or just the name of where the step
  /// landed when no single wire joins them.
  String _wire(int from, int to, {required bool forwards}) {
    final source = forwards ? from : to;
    final sink = forwards ? to : from;
    if (source < 0 || sink < 0) return _nodes[to].title;

    final fromId = _nodes[source].id;
    final toId = _nodes[sink].id;
    for (final link in widget.graph.links) {
      if (link.from != fromId || link.to != toId) continue;
      final out = link.fromPin == null
          ? _nodes[source].title
          : '${_nodes[source].title}.${link.fromPin}';
      final into = link.toPin == null
          ? _nodes[sink].title
          : '${_nodes[sink].title}.${link.toPin}';
      return '$out → $into';
    }
    // Node-RED joins nodes rather than ports, and a step over the topological
    // order followed no wire at all.
    return '${_nodes[source].title} → ${_nodes[sink].title}';
  }

  /// Moves the focus, remembers where it came from, and glides after it.
  void _focusOn(
    int index, {
    int? from,
    bool forwards = true,
    bool keep = true,
  }) {
    if (index < 0 || index >= _nodes.length || index == _focus) return;
    setState(() {
      if (keep) _history.add(_focus);
      _cameFrom = from ?? -1;
      _cameForwards = forwards;
      _focus = index;
    });
    _glideToFocus();
  }

  /// Brings the focused node into view — but only when it is not already in it.
  /// A viewport that recentres on every press is a viewport nobody can keep
  /// their place in.
  void _glideToFocus() {
    final size = _size;
    final box = _lastBoxes[_nodes[_focus].id];
    if (size == null || box == null) return;

    final visible = Rect.fromLTWH(
      _origin.dx,
      _origin.dy,
      size.width / _scale,
      size.height / _scale,
    );
    if (visible.contains(box.topLeft) && visible.contains(box.bottomRight)) {
      return;
    }

    _glideTo(
      Offset(
        box.center.dx - size.width / _scale / 2,
        box.center.dy - size.height / _scale / 2,
      ),
    );
  }

  /// Moves the view there, over time, taking the scale with it.
  ///
  /// Everything that changes the view on purpose goes through this — the walk,
  /// the fit, the zoom keys, `F`. What does *not* is the wheel and the drag,
  /// which follow the pointer and must arrive with it.
  void _glideTo(Offset origin, {double? scale}) {
    _from = _origin;
    _to = _within(origin);
    _scaleFrom = _scale;
    _scaleTo = scale ?? _scale;
    _glide
      ..duration = motionOf(context, kNodeGlideDuration)
      ..forward(from: 0);
  }

  /// Frames the node the keyboard is on — **the pattern every 3D and node
  /// editor already uses**, spelled the way Blender and Unreal spell it.
  ///
  /// `F` frames what is selected, `A` frames everything: Blender, Unreal, Maya
  /// and Unity all agree on the first and differ only in how they spell the
  /// second, so this takes the one they share and gives the other two spellings
  /// (`A` and the `0` this canvas already had). Opening a graph puts the focus
  /// on the first source, so `F` on arrival is "back to the beginning".
  ///
  /// The node is drawn at a size it can be read at rather than filling the
  /// window: a box blown up to the whole page tells you nothing about what it
  /// is joined to.
  void _frameFocused() {
    final size = _size;
    if (_nodes.isEmpty || size == null) return;
    final box = _lastBoxes[_nodes[_focus].id];
    if (box == null || box.isEmpty) return;

    final scale = math
        .min(size.width / (box.width * _frameMargin),
            size.height / (box.height * _frameMargin))
        .clamp(_minimumScale, _frameMost);

    _glideTo(
      Offset(
        box.center.dx - size.width / scale / 2,
        box.center.dy - size.height / scale / 2,
      ),
      scale: scale,
    );
  }

  /// What the viewport can see, in document units — the rectangle the minimap
  /// draws round.
  Rect get _viewport {
    final size = _size;
    if (size == null) return Rect.zero;
    return Rect.fromLTWH(
      _origin.dx,
      _origin.dy,
      size.width / _scale,
      size.height / _scale,
    );
  }

  /// Centres the view on a point in the document. What the minimap does when
  /// it is pressed, and it moves at once rather than gliding: the press said
  /// where to go, so there is nothing to be shown on the way.
  void _lookAt(Offset at) {
    final size = _size;
    if (size == null) return;
    setState(() {
      _origin = _within(Offset(
        at.dx - size.width / _scale / 2,
        at.dy - size.height / _scale / 2,
      ));
    });
  }

  /// Keeps the view within reach of the graph.
  ///
  /// **A viewport a long way from every box is not a view of anything**, and it
  /// is worse than useless: nothing on screen says which way home is. It also
  /// used to be dangerous — see the paper's own grid, which cannot be drawn at
  /// coordinates in the billions.
  ///
  /// A tenth of the view has to stay over the graph. Anything less and panning
  /// feels caged; anything more and a node at the far corner cannot be brought
  /// to the middle of the window.
  Offset _within(Offset origin) {
    final size = _size;
    if (size == null || _lastBoxes.isEmpty) return origin;
    final bounds = _bounds(_lastBoxes);
    final width = size.width / _scale;
    final height = size.height / _scale;

    double hold(double value, double low, double high, double middle) =>
        low > high ? middle : value.clamp(low, high);

    return Offset(
      hold(
        origin.dx,
        bounds.left - width * 0.9,
        bounds.right - width * 0.1,
        bounds.center.dx - width / 2,
      ),
      hold(
        origin.dy,
        bounds.top - height * 0.9,
        bounds.bottom - height * 0.1,
        bounds.center.dy - height / 2,
      ),
    );
  }

  /// The way each long wire goes round, worked out by the layout — empty for a
  /// document that carried its own coordinates, where the wires go as the file
  /// drew them.
  Map<int, List<Offset2>> _routes = const {};

  /// What the last layout measured, so the keys can ask where a node is
  /// without laying the graph out again on every press.
  Map<String, Rect> _lastBoxes = const {};
  Size? _size;

  // --- The keyboard -------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_nodes.isEmpty) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final keys = HardwareKeyboard.instance;

    if (_finding) {
      // While the box is up it has the letters; these are the keys that are
      // still the canvas's.
      if (key == LogicalKeyboardKey.escape) {
        _closeFind();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.f3) {
        _stepMatch(keys.isShiftPressed ? -1 : 1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    switch (key) {
      // The focused node, read in full. A toggle rather than an opener: the key
      // that puts it up is the key that takes it away, which is one thing to
      // remember instead of two.
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        // Once to put it out, again to go and read it. Two presses, and the
        // second is how the keyboard gets into a panel that has no cursor of
        // its own to walk.
        if (!_properties) {
          _showProperties(true);
        } else if (!_inPanel) {
          setState(() => _inPanel = true);
        }

      // Escape closes the panel before it closes the viewer — the find box
      // first, then this, then the page. Unhandled it would take the whole
      // page away, which is not what somebody shutting a panel asked for.
      case LogicalKeyboardKey.escape:
        // Out of the panel first, then the panel, then the page. Each press
        // undoes exactly one thing, which is the only order anybody can guess.
        if (_inPanel) {
          setState(() => _inPanel = false);
          _keys.requestFocus();
        } else if (_properties) {
          _showProperties(false);
        } else {
          return KeyEventResult.ignored;
        }

      // The panel is read without the canvas giving up the keyboard: a long
      // prompt is scrolled from here, and the arrows still walk the graph.
      case LogicalKeyboardKey.pageDown:
      case LogicalKeyboardKey.pageUp:
        if (!_properties || !_propertiesScroll.hasClients) {
          return KeyEventResult.ignored;
        }
        _scrollProperties(key == LogicalKeyboardKey.pageDown ? 1 : -1);

      // Along a wire, forwards and back. The candidates are in drawn order, so
      // "the first one" means the top one, which is what the eye picked too.
      case LogicalKeyboardKey.arrowRight:
        final ahead = _next(_focus, forwards: true);
        if (ahead.isEmpty) return KeyEventResult.handled;
        _say(_wire(_focus, ahead.first, forwards: true));
        _focusOn(ahead.first, from: _focus, forwards: true);
      case LogicalKeyboardKey.arrowLeft:
        final behind = _next(_focus, forwards: false);
        if (behind.isEmpty) return KeyEventResult.handled;
        _say(_wire(_focus, behind.first, forwards: false));
        _focusOn(behind.first, from: _focus, forwards: false);

      // The other ends of the wire just followed — the siblings. Without this
      // a junction of five could only ever be entered by its first branch.
      case LogicalKeyboardKey.arrowDown:
        _stepSibling(1);
      case LogicalKeyboardKey.arrowUp:
        _stepSibling(-1);

      // Tab is not used, and `[` `]` say the same thing: the order the graph
      // runs in. Tab belongs to the panels and to the parts of a page, and a
      // viewer that took it would break something older than itself.
      case LogicalKeyboardKey.bracketRight:
        _stepOrder(1);
      case LogicalKeyboardKey.bracketLeft:
        _stepOrder(-1);

      case LogicalKeyboardKey.home:
        _focusOn(_topological.first);
      case LogicalKeyboardKey.end:
        _focusOn(_topological.last);

      case LogicalKeyboardKey.backspace:
        if (_history.isEmpty) return KeyEventResult.handled;
        final back = _history.removeLast();
        _focusOn(back, keep: false);

      // Fold the box the keyboard is on, or every box at once. A workflow
      // whose prompts are five lines each is a wall of text until this.
      case LogicalKeyboardKey.keyC:
        if (keys.isShiftPressed) {
          _foldAll();
        } else {
          _foldThese([_nodes[_focus].id]);
        }

      // The whole graph, small, in the corner.
      case LogicalKeyboardKey.keyM:
        setState(() => _minimap = !_minimap);
        unawaited(
          _store()?.setNodeMinimap(_minimap) ?? Future<void>.value(),
        );

      // Frame what is selected, and frame everything: `F` and `A` as every 3D
      // and node editor spells them.
      case LogicalKeyboardKey.keyF:
        _frameFocused();
      case LogicalKeyboardKey.keyA:
        final size = _size;
        if (size != null) _fit(size, _lastBoxes);

      case LogicalKeyboardKey.slash:
        _openFind();

      case LogicalKeyboardKey.equal:
      case LogicalKeyboardKey.add:
      case LogicalKeyboardKey.numpadAdd:
        _zoomOnFocus(1.2);
      case LogicalKeyboardKey.minus:
      case LogicalKeyboardKey.numpadSubtract:
        _zoomOnFocus(1 / 1.2);

      case LogicalKeyboardKey.digit0:
      case LogicalKeyboardKey.numpad0:
        final size = _size;
        if (size != null) _fit(size, _lastBoxes);
      case LogicalKeyboardKey.digit1:
      case LogicalKeyboardKey.numpad1:
        _zoomOnFocus(1 / _scale);

      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Between the nodes that share the current wire's other end.
  void _stepSibling(int by) {
    if (_cameFrom < 0) {
      // Nothing was walked along, so there are no siblings — step the drawn
      // order instead, which is what an arrow key means with no wire in hand.
      _stepOrder(by);
      return;
    }
    final siblings = _next(_cameFrom, forwards: _cameForwards);
    final at = siblings.indexOf(_focus);
    if (at < 0 || siblings.length < 2) return;
    final next = (at + by) % siblings.length;
    final landed = siblings[next < 0 ? next + siblings.length : next];
    // The same wire, its other end: what changed is which branch of the
    // junction the reader is standing on, and that is what is said.
    _say(_wire(_cameFrom, landed, forwards: _cameForwards));
    _focusOn(landed, from: _cameFrom, forwards: _cameForwards);
  }

  void _stepOrder(int by) {
    final at = _topological.indexOf(_focus);
    if (at < 0) return;
    final next = (at + by).clamp(0, _topological.length - 1);
    if (next == at) return;
    // No wire was followed here — this is the order the graph runs in — so
    // what is said is where it landed, which is the question the press asked.
    _say(_nodes[_topological[next]].title);
    _focusOn(_topological[next]);
  }

  /// A page of the properties, one screenful at a time.
  void _scrollProperties(int by) {
    final position = _propertiesScroll.position;
    final page = position.viewportDimension * 0.9;
    _propertiesScroll.animateTo(
      (position.pixels + page * by).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
      duration: motionOf(context, kNodeGlideDuration),
      curve: kBothCurve,
    );
  }

  void _zoomOnFocus(double by) {
    final size = _size;
    final box = _lastBoxes[_nodes[_focus].id];
    if (size == null || box == null) return;
    final scale = (_scale * by).clamp(_minimumScale, _maximumScale);
    _glideTo(
      Offset(
        box.center.dx - size.width / scale / 2,
        box.center.dy - size.height / scale / 2,
      ),
      scale: scale,
    );
  }

  // --- Finding ------------------------------------------------------------

  void _openFind() {
    setState(() {
      _finding = true;
      _query.clear();
      _matches = const [];
      _match = 0;
    });
  }

  void _closeFind() {
    setState(() => _finding = false);
    _keys.requestFocus();
  }

  /// **What is searched is the fields as well as the names.** Nobody looks for
  /// the node called `CLIPTextEncode`; they look for the words in the prompt.
  void _find(String query) {
    final needle = query.trim().toLowerCase();
    setState(() {
      _matches = needle.isEmpty
          ? const []
          : [
              for (var i = 0; i < _nodes.length; i++)
                if (_haystack(_nodes[i]).contains(needle)) i,
            ];
      _match = 0;
    });
    if (_matches.isNotEmpty) _focusOn(_matches.first, keep: false);
  }

  String _haystack(GraphNode node) => [
    node.caption,
    node.subtitle ?? '',
    for (final field in node.fields) '${field.label} ${field.value}',
  ].join(' ').toLowerCase();

  void _stepMatch(int by) {
    if (_matches.isEmpty) return;
    setState(() {
      _match = (_match + by) % _matches.length;
      if (_match < 0) _match += _matches.length;
    });
    _focusOn(_matches[_match], keep: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = appearanceOf(context);
    final boxes = _boxes(theme);
    _lastBoxes = boxes;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        _size = size;
        if (!_placed) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_placed) _fit(size, boxes);
          });
        }

        return _keyboard(
          theme,
          MouseRegion(
            onHover: (event) => _onHover(event.localPosition, boxes),
            onExit: (_) {
              if (_hovered != -1) setState(() => _hovered = -1);
            },
            child: Listener(
              // A wheel notch, and a trackpad. **Both, because a Mac has no
              // wheel**: two fingers on the pad arrive as a pan-zoom gesture
              // rather than as a scroll, and a canvas listening only for the
              // scroll cannot be zoomed on a Mac at all.
              onPointerSignal: (signal) {
                if (signal is! PointerScrollEvent) return;
                _zoomAt(
                  signal.localPosition,
                  signal.scrollDelta.dy < 0 ? _zoomStep : 1 / _zoomStep,
                );
              },
              onPointerPanZoomStart: (event) => _pinch = _scale,
              onPointerPanZoomUpdate: (event) {
                if ((event.scale - 1).abs() > 0.001) {
                  final want = (_pinch * event.scale).clamp(
                    _minimumScale,
                    _maximumScale,
                  );
                  _zoomAt(event.localPosition, want / _scale);
                } else {
                  setState(
                    () => _origin =
                        _within(_origin - event.localPanDelta / _scale),
                  );
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Scale rather than pan, because a scale gesture *is* a pan
                // while nothing is pinching: one handler for the mouse
                // dragging, a finger dragging, and two fingers spreading.
                onScaleStart: (details) => _pinch = _scale,
                onScaleUpdate: (details) {
                  if ((details.scale - 1).abs() > 0.001) {
                    final want = (_pinch * details.scale).clamp(
                      _minimumScale,
                      _maximumScale,
                    );
                    _zoomAt(details.localFocalPoint, want / _scale);
                  } else {
                    setState(
                      () => _origin =
                          _within(_origin - details.focalPointDelta / _scale),
                    );
                  }
                },
                // A press picks a node up; a press on nothing leaves the focus
                // where it is, because the canvas is walked by keyboard and
                // clicking past a box is a miss, not an instruction.
                onTapUp: (details) {
                  final at = _nodeAt(details.localPosition, boxes);
                  if (at >= 0) _focusOn(at);
                },
                onDoubleTapDown: (details) => _doubleAt = details.localPosition,
                // On a node: its own page. On the canvas: the whole graph,
                // which is what it has always meant.
                onDoubleTap: () {
                  final at = _nodeAt(_doubleAt, boxes);
                  if (at < 0) {
                    _fit(size, boxes);
                    return;
                  }
                  _focusOn(at);
                  setState(() => _properties = true);
                },
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _NodeGraphPainter(
                    graph: widget.graph,
                    boxes: boxes,
                    theme: theme,
                    colours: NodeColours.of(theme),
                    scale: _scale,
                    origin: _origin,
                    hovered: _hovered,
                    focused: widget.hasKeyboard ? _focus : -1,
                    foldOf: _foldFactor,
                    routes: _routes,
                    titleHeight: _titleHeight(theme),
                    rowHeight: _rowHeight(theme),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The canvas with its keys on it, the properties over one side of it, and
  /// the find box over the corner.
  ///
  /// Both float rather than pushing the graph about, which is the shape every
  /// search in this application has — see [FindBox] — and, for the properties,
  /// the whole reason they are a panel: the canvas keeps its place.
  ///
  /// The find box is drawn **above** the panel on purpose. They share the
  /// bottom-right corner, and the one being typed into is the one that has to
  /// be visible.
  Widget _keyboard(AppearanceSettings theme, Widget canvas) => Focus(
    focusNode: _keys,
    autofocus: widget.hasKeyboard,
    onKeyEvent: _onKey,
    child: Stack(
      children: [
        Positioned.fill(
          child: SlidePanel(
            open: _properties,
            fraction: _propertiesShare,
            pinned: _pinned,
            onPinnedChanged: (pinned) {
              setState(() => _pinned = pinned);
              unawaited(
                _store()?.setSlidePanelPinned(pinned) ?? Future<void>.value(),
              );
            },
            onClose: () => _showProperties(false),
            // A press on another node moves the panel to it; a press on the
            // canvas itself puts the panel away. Without this, opening the
            // node next door meant closing the panel and opening it again,
            // which reads as nonsense.
            onContentPressed: (at) {
              final node = _nodeAt(at, _lastBoxes);
              if (node < 0) return false;
              _focusOn(node);
              return true;
            },
            onFractionChanged: (share) {
              setState(() => _propertiesShare = share);
              unawaited(
                _store()?.setSlidePanelShare(share) ?? Future<void>.value(),
              );
            },
            panel: (context) => KeyboardScrollable(
              hasKeyboard: _inPanel,
              controller: _propertiesScroll,
              // **Rule number two.** Walking a wire used to swap the whole
              // panel between two frames, which reads as a fault rather than
              // as an arrival. It fades through instead, and comes back to the
              // top of the new node on the way.
              builder: (controller) => FadeThrough<String>(
                data: _nodes.isEmpty
                    ? ''
                    : _nodes[_focus.clamp(0, _nodes.length - 1)].id,
                onSwap: () {
                  if (_propertiesScroll.hasClients) {
                    _propertiesScroll.jumpTo(0);
                  }
                },
                builder: (context, id) => _NodeProperties(
                  node: _nodes.where((node) => node.id == id).firstOrNull,
                  theme: theme,
                  colours: NodeColours.of(theme),
                  controller: controller,
                ),
              ),
            ),
            child: canvas,
          ),
        ),
        // What the last step followed, said where the reader is looking. It
        // takes no presses and it goes away by itself: a label that stayed
        // would be read as part of the graph.
        Positioned(
          left: 0,
          right: 0,
          bottom: 12,
          child: IgnorePointer(
            child: Center(
              child: AnimatedSwitcher(
                duration: motionOf(context, kContentSwapDuration),
                switchInCurve: kArrivingCurve,
                switchOutCurve: kLeavingCurve,
                child: _said == null
                    ? const SizedBox.shrink()
                    : _Said(text: _said!, theme: theme),
              ),
            ),
          ),
        ),
        // The whole graph, small, out of the way of the panel on the right and
        // the find box in the corner. It is a map, so it is where a map goes:
        // in a corner, and it does not move.
        if (widget.fullScreen && _nodes.isNotEmpty)
          Positioned(
            left: 12,
            bottom: 12,
            // It arrives and leaves rather than appearing and vanishing — the
            // same rule, and the map is a big enough thing on screen that a
            // blink would be the loudest event in the window.
            child: AnimatedOpacity(
              opacity: _minimap ? 1 : 0,
              duration: motionOf(context, kContentSwapDuration),
              curve: _minimap ? kArrivingCurve : kLeavingCurve,
              child: IgnorePointer(
                ignoring: !_minimap,
                child: _Minimap(
                  graph: widget.graph,
                  boxes: _lastBoxes,
                  colours: NodeColours.of(theme),
                  theme: theme,
                  focused: _focus,
                  view: _viewport,
                  onGoTo: _lookAt,
                ),
              ),
            ),
          ),
        if (_finding)
          Positioned(
            right: 12,
            bottom: 12,
            child: FindBox(
              query: _query,
              node: _queryFocus,
              theme: theme,
              hint: tr('Find a node'),
              matches: _matches.length,
              current: _matches.isEmpty ? 0 : _match + 1,
              onChanged: _find,
              onStep: _stepMatch,
              onClose: _closeFind,
            ),
          ),
      ],
    ),
  );

  /// Which node is under a point on the canvas, or -1. Backwards, so the box
  /// drawn last — the one on top — is the one that answers.
  int _nodeAt(Offset local, Map<String, Rect> boxes) {
    final at = _origin + local / _scale;
    for (var i = widget.graph.nodes.length - 1; i >= 0; i--) {
      if (boxes[widget.graph.nodes[i].id]?.contains(at) ?? false) return i;
    }
    return -1;
  }

  void _onHover(Offset local, Map<String, Rect> boxes) {
    final found = _nodeAt(local, boxes);
    if (found != _hovered) setState(() => _hovered = found);
  }
}

/// The focused node, read in full, on the panel that slides over the canvas.
///
/// Everything here is already in the document — this is the same node the box
/// draws, read a second way rather than fetched a second time. The box caps a
/// field at a few lines because forty of them make a wall of text; this is
/// where the whole of a five-hundred-word prompt is read, and where it can be
/// selected and taken away.
class _NodeProperties extends StatelessWidget {
  const _NodeProperties({
    required this.node,
    required this.theme,
    required this.colours,
    required this.controller,
  });

  /// Null only where the graph has no nodes at all, which the canvas already
  /// says in its own words — so this says nothing more than that.
  final GraphNode? node;

  final AppearanceSettings theme;
  final NodeColours colours;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    // The panel stands on the canvas's own fill, not on a node's, so the ink
    // is the one worked out for the canvas. A fill and an ink go in together.
    final ink = colours.onCanvas;
    final muted = ink.withValues(alpha: 0.62);

    final node = this.node;
    if (node == null) {
      return Center(
        child: Text(tr('No node'), style: TextStyle(color: muted)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(node, ink, muted),
        Expanded(
          child: Scrollbar(
            controller: controller,
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              children: _sections(node, ink, muted),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(GraphNode node, Color ink, Color muted) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The role, said the same way the box says it: a mark in the colour
        // the palette gave that role, never a word for a colour.
        Container(
          width: 4,
          height: theme.fontSize + 10,
          margin: const EdgeInsets.only(top: 2, right: 8),
          decoration: BoxDecoration(
            color: colours.of(node.role),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                node.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ink,
                  fontSize: theme.fontSize + 1,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (node.subtitle != null && node.subtitle!.isNotEmpty)
                Text(
                  node.subtitle!,
                  style: TextStyle(color: muted, fontSize: theme.fontSize - 1),
                ),
              Text(
                '#${node.id} · ${node.role.name}',
                style: TextStyle(color: muted, fontSize: theme.fontSize - 2),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  List<Widget> _sections(GraphNode node, Color ink, Color muted) => [
    if (node.fields.isEmpty && node.inputs.isEmpty && node.outputs.isEmpty)
      Text(
        tr('This node carries nothing but its name.'),
        style: TextStyle(color: muted, fontSize: theme.fontSize - 1),
      ),
    if (node.fields.isNotEmpty) ...[
      _heading(tr('Fields'), muted),
      for (final field in node.fields) _field(field, ink, muted),
    ],
    if (node.inputs.isNotEmpty) ...[
      _heading(tr('Inputs'), muted),
      for (final pin in node.inputs) _pin(pin, ink, muted),
    ],
    if (node.outputs.isNotEmpty) ...[
      _heading(tr('Outputs'), muted),
      for (final pin in node.outputs) _pin(pin, ink, muted),
    ],
  ];

  Widget _heading(String text, Color muted) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: muted,
        fontSize: theme.fontSize - 3,
        letterSpacing: 0.8,
      ),
    ),
  );

  /// A value, whole and selectable. Selectable because the reason somebody
  /// opens a workflow is often to take the prompt out of it.
  Widget _field(GraphField field, Color ink, Color muted) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (field.label.isNotEmpty)
          Text(
            field.label,
            style: TextStyle(color: muted, fontSize: theme.fontSize - 2),
          ),
        SelectableText(
          field.value.isEmpty ? '—' : field.value,
          style: TextStyle(color: ink, fontSize: theme.fontSize),
        ),
      ],
    ),
  );

  /// A socket, marked in the colour its own wires are drawn in — so a pin and
  /// the wire leaving it agree, which is the only way to follow one by eye.
  Widget _pin(GraphPin pin, Color ink, Color muted) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: colours.wire(pin.type),
            shape: BoxShape.circle,
          ),
        ),
        Expanded(
          child: Text(
            pin.caption,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ink, fontSize: theme.fontSize - 1),
          ),
        ),
        if (pin.type != null && pin.type!.isNotEmpty)
          Text(
            pin.type!,
            style: TextStyle(color: muted, fontSize: theme.fontSize - 2),
          ),
      ],
    ),
  );
}


/// The whole graph, small, in a corner — and a way of getting about it.
///
/// It is a **map**, not a second canvas: it draws where things are and where
/// you are looking, and pressing it takes you there. Nothing is written on it,
/// because at this size nothing would be readable and a wall of grey smudges
/// would say less than the boxes' own colours do.
class _Minimap extends StatelessWidget {
  const _Minimap({
    required this.graph,
    required this.boxes,
    required this.colours,
    required this.theme,
    required this.focused,
    required this.view,
    required this.onGoTo,
  });

  final GraphDocument graph;
  final Map<String, Rect> boxes;
  final NodeColours colours;
  final AppearanceSettings theme;
  final int focused;

  /// What the canvas can see, in document units.
  final Rect view;

  /// Where to look, in document units.
  final ValueChanged<Offset> onGoTo;

  static const Size size = Size(180, 120);

  Rect get _bounds {
    if (boxes.isEmpty) return Rect.zero;
    var union = boxes.values.first;
    for (final box in boxes.values) {
      union = union.expandToInclude(box);
    }
    // **The viewport is deliberately not in this.** It was, and it made the
    // map a thing that moved as you used it: pressing it moved the view, which
    // grew the frame, which changed what the same point on the map meant — so
    // the second press landed somewhere else again and the view ran away
    // across the document. A map whose scale depends on where you are looking
    // is not a map. Where you are is *drawn* on it, and clipped by its own
    // edge when you are outside the graph.
    return union.inflate(40);
  }

  @override
  Widget build(BuildContext context) {
    final bounds = _bounds;
    if (bounds.isEmpty) return const SizedBox.shrink();

    final factor = math.min(
      size.width / bounds.width,
      size.height / bounds.height,
    );

    void goTo(Offset local) {
      onGoTo(Offset(
        bounds.left + local.dx / factor,
        bounds.top + local.dy / factor,
      ));
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) => goTo(details.localPosition),
      onPanUpdate: (details) => goTo(details.localPosition),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: DecoratedBox(
          // Its own hairline, for the same reason the slide panel has one: a
          // translucent thing over a translucent thing has no edge where what
          // is under it happens to be plain.
          decoration: BoxDecoration(
            color: theme.panelBackground.withValues(alpha: 0.72),
            border: Border.all(
              color: colours.onCanvas.withValues(alpha: 0.25),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: CustomPaint(
            size: size,
            painter: _MinimapPainter(
              graph: graph,
              boxes: boxes,
              colours: colours,
              focused: focused,
              view: view,
              bounds: bounds,
              factor: factor,
            ),
          ),
        ),
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  _MinimapPainter({
    required this.graph,
    required this.boxes,
    required this.colours,
    required this.focused,
    required this.view,
    required this.bounds,
    required this.factor,
  });

  final GraphDocument graph;
  final Map<String, Rect> boxes;
  final NodeColours colours;
  final int focused;
  final Rect view;
  final Rect bounds;
  final double factor;

  Rect _small(Rect box) => Rect.fromLTWH(
    (box.left - bounds.left) * factor,
    (box.top - bounds.top) * factor,
    math.max(2, box.width * factor),
    math.max(2, box.height * factor),
  );

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < graph.nodes.length; i++) {
      final node = graph.nodes[i];
      final box = boxes[node.id];
      if (box == null) continue;
      canvas.drawRect(
        _small(box),
        Paint()
          ..color = i == focused
              ? colours.accent
              : colours.of(node.role).withValues(alpha: 0.75),
      );
    }

    // Where you are looking. Drawn last and in the accent, because on a map of
    // two hundred boxes this is the only thing being looked for.
    if (!view.isEmpty) {
      canvas.drawRect(
        _small(view),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = colours.onCanvas.withValues(alpha: 0.85),
      );
    }
  }

  @override
  bool shouldRepaint(_MinimapPainter old) =>
      old.view != view ||
      old.focused != focused ||
      old.bounds != bounds ||
      !identical(old.boxes, boxes);
}

/// What the canvas draws things in.
///
/// Taken from the palette, never from the document: a reader names a role and
/// the theme answers for how that looks. The rule `CodeColours` follows for a
/// grammar and `GraphColours` for the commit braid.
class NodeColours {
  const NodeColours({
    required this.surface,
    required this.ink,
    required this.muted,
    required this.onCanvas,
    required this.roles,
    required this.wires,
    required this.accent,
  });

  factory NodeColours.of(AppearanceSettings theme) {
    // **A box is a step away from the canvas it stands on, in the canvas's own
    // family** — the panel's ink laid thinly over the panel's fill. On a dark
    // palette that lifts it, on a light one it drops it, and either way the two
    // are related rather than borrowed from somewhere else.
    //
    // The first cut took the *header's* fill for this and the *panel's* ink to
    // write on it, which on a light palette is a dark box with dark words on
    // it — measured at 1.4:1. A fill and an ink go in together or neither
    // does.
    final surface = Color.alphaBlend(
      theme.panelForeground.withValues(alpha: 0.09),
      theme.panelBackground,
    );

    return NodeColours(
      surface: surface,
      // Asked of the fill rather than declared, which is the same question the
      // chips in a listing ask and the same answer.
      ink: legibleOn(surface, theme),
      muted: legibleOn(surface, theme).withValues(alpha: 0.62),
      // What is written straight on the canvas rather than on a box: a group's
      // name, a note. A different fill, so a different question.
      onCanvas: legibleOn(theme.panelBackground, theme),
      accent: theme.accentColor,
      roles: {
        // A node's kind, off the shelves of the palette rather than a new set
        // of colours: what marks a directory marks the sources here.
        NodeRole.event: theme.markedColor,
        NodeRole.flow: theme.accentColor,
        NodeRole.pure: theme.directoryColor,
        NodeRole.input: theme.directoryColor,
        NodeRole.output: theme.markedColor,
        NodeRole.variable: theme.panelForeground,
        NodeRole.note: theme.panelForeground.withValues(alpha: 0.4),
        NodeRole.group: theme.panelForeground.withValues(alpha: 0.25),
        NodeRole.error: const Color(0xFFFF8A80),
        NodeRole.normal: theme.panelForeground.withValues(alpha: 0.75),
      },
      // The same nine hues the commit braid uses, so two pictures that colour
      // by name agree with each other.
      wires: GraphColours.of(theme).lanes,
    );
  }

  final Color surface;
  final Color ink;
  final Color muted;
  final Color onCanvas;
  final Color accent;
  final Map<NodeRole, Color> roles;
  final List<Color> wires;

  Color of(NodeRole role) => roles[role] ?? ink;

  /// The title strip of a node in [role], as a colour rather than a veil.
  ///
  /// **A hint of the role, not a banner.** Tinted harder than this it lands in
  /// the middle of the range on some palettes, where neither of the theme's two
  /// inks can be read on it — the amber a marked file is written in, over a
  /// dark box, came out at 4.34:1 and the name on it with it. Worked out here
  /// so the canvas and the test that measures the contrast are asking the same
  /// question of the same colour.
  Color strip(NodeRole role, {bool lit = false}) =>
      Color.alphaBlend(of(role).withValues(alpha: lit ? 0.38 : 0.22), surface);

  /// A wire's colour, by the name of what travels through it. Hashed into the
  /// wheel, so two `LATENT` wires match wherever they are and nothing is ever
  /// coloured from outside the theme.
  Color wire(String? type) {
    if (type == null || type.isEmpty) return muted;
    var hash = 0;
    for (final unit in type.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return wires[hash % wires.length];
  }
}

class _NodeGraphPainter extends CustomPainter {
  _NodeGraphPainter({
    required this.graph,
    required this.boxes,
    required this.theme,
    required this.colours,
    required this.scale,
    required this.origin,
    required this.hovered,
    required this.focused,
    required this.foldOf,
    required this.routes,
    required this.titleHeight,
    required this.rowHeight,
  });

  final GraphDocument graph;
  final Map<String, Rect> boxes;
  final AppearanceSettings theme;
  final NodeColours colours;
  final double scale;
  final Offset origin;
  final int hovered;

  /// The node the keyboard is on, or -1 where the canvas has no keyboard. Drawn
  /// ringed in the accent, and its wires brighter and over the rest: the eye
  /// has to find it after every press without being told where to look.
  final int focused;

  /// How folded each node is drawn, 0..1 — the canvas's own `_foldFactor`,
  /// which is a factor rather than a switch because a box that changes height
  /// between two frames is a blink.
  final double Function(GraphNode) foldOf;

  /// Waypoints for the wires that cross more than one layer — see
  /// [LayeredPlacement.routes]. A wire drawn straight through a layer it does
  /// not stop in goes *under* a box and comes out the other side, which reads
  /// as a wire arriving where no socket is.
  final Map<int, List<Offset2>> routes;

  bool _isCollapsed(GraphNode node) => foldOf(node) > 0.999;

  final double titleHeight;
  final double rowHeight;

  static const double _radius = 6;

  /// The most dots of paper drawn along one edge. A window is a hundred or so;
  /// anything past this is a view that has gone wrong, and a bare page says so
  /// better than a frozen one.
  static const int _dotsMost = 600;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..clipRect(Offset.zero & size)
      ..scale(scale)
      ..translate(-origin.dx, -origin.dy);

    _paintDots(canvas, size);
    _paintGroups(canvas);
    _paintNotes(canvas);
    // **Wires under boxes, always.** Paint order, not clipping — the standing
    // rule, and the reason a wire never crosses the name it belongs to.
    _paintWires(canvas, size);
    _paintNodes(canvas);

    canvas.restore();
  }

  /// The paper the graph is drawn on: dots at the corners of a grid.
  ///
  /// An empty field gives the eye nothing to judge a pan or a zoom against, so
  /// the canvas feels as though it is sliding rather than being moved.
  ///
  /// **Dots, not squared paper.** Lines make a second graph on top of the one
  /// being read; dots say where the grid is and then get out of the way.
  ///
  /// The spacing lives in the document, so the paper moves with the drawing —
  /// but it is doubled or halved until it lands between [_dotsNearest] and
  /// [_dotsFurthest] on *screen*, which is what stops a zoom turning it into
  /// either a wash or a bare page. A dot keeps its size on screen for the same
  /// reason a hairline does.
  void _paintDots(Canvas canvas, Size size) {
    var step = 24.0;
    for (var i = 0; i < 8 && step * scale < _dotsNearest; i++) {
      step *= 2;
    }
    for (var i = 0; i < 8 && step * scale > _dotsFurthest; i++) {
      step /= 2;
    }

    final view = _visible(size);
    if (!view.left.isFinite || !view.top.isFinite) return;

    // **Counted, not accumulated.** Adding `step` to a coordinate in the
    // billions leaves it unchanged — doubles run out of precision long before
    // they run out of range — and the loop never ends. That is what froze the
    // window on 2026-08-16 after the minimap sent the view somewhere absurd:
    // not a slow frame, an infinite one. The count is also capped, so a
    // viewport nobody expected costs a bare page rather than the application.
    final firstX = (view.left / step).floorToDouble() * step;
    final firstY = (view.top / step).floorToDouble() * step;
    final columns = ((view.right - firstX) / step).ceil() + 1;
    final rows = ((view.bottom - firstY) / step).ceil() + 1;
    if (columns <= 0 || rows <= 0) return;
    if (columns > _dotsMost || rows > _dotsMost) return;

    final points = <Offset>[];
    for (var i = 0; i < columns; i++) {
      for (var j = 0; j < rows; j++) {
        points.add(Offset(firstX + i * step, firstY + j * step));
      }
    }
    if (points.isEmpty) return;

    canvas.drawPoints(
      ui.PointMode.points,
      points,
      Paint()
        ..color = colours.onCanvas.withValues(alpha: 0.18)
        ..strokeCap = StrokeCap.round
        // One and a half pixels on screen, whatever the zoom is.
        ..strokeWidth = 1.5 / scale,
    );
  }

  /// How close together the dots are allowed to get on screen, and how far
  /// apart, before the spacing is stepped.
  static const double _dotsNearest = 14;
  static const double _dotsFurthest = 56;

  void _paintGroups(Canvas canvas) {
    for (final group in graph.groups) {
      final rect = Rect.fromLTWH(group.x, group.y, group.width, group.height);
      canvas
        ..drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(_radius)),
          Paint()..color = colours.of(NodeRole.group).withValues(alpha: 0.10),
        )
        ..drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(_radius)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = colours.of(NodeRole.group),
        );
      if (group.title.isNotEmpty) {
        _text(
          canvas,
          group.title,
          Offset(rect.left + 8, rect.top + 4),
          colours.onCanvas.withValues(alpha: 0.7),
          theme.fontSize,
        );
      }
    }
  }

  void _paintNotes(Canvas canvas) {
    for (final note in graph.notes) {
      final rect = Rect.fromLTWH(note.x, note.y, note.width, note.height);
      canvas
        ..drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(_radius)),
          Paint()..color = colours.of(NodeRole.note).withValues(alpha: 0.07),
        )
        ..drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(_radius)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = colours.onCanvas.withValues(alpha: 0.18),
        );

      // **A note is read, not glanced at.** In n8n a sticky note is where the
      // only documentation a workflow has ends up, so it is wrapped over as
      // many lines as it was given room for rather than cut at the first one.
      _text(
        canvas,
        note.text,
        Offset(rect.left + 8, rect.top + 6),
        colours.onCanvas.withValues(alpha: 0.75),
        theme.fontSize - 1,
        maxWidth: rect.width - 16,
        maxLines: math.max(1, (rect.height - 12) ~/ (theme.fontSize + 3)),
      );
    }
  }

  /// What the viewport can see, in document units. A wire whose far end is
  /// outside it is drawn as a stub with a name on it — see [_paintWires].
  Rect _visible(Size size) => Rect.fromLTWH(
    origin.dx,
    origin.dy,
    size.width / scale,
    size.height / scale,
  );

  void _paintWires(Canvas canvas, Size size) {
    final view = _visible(size);
    final focusedId = focused >= 0 && focused < graph.nodes.length
        ? graph.nodes[focused].id
        : null;

    for (var i = 0; i < graph.links.length; i++) {
      final link = graph.links[i];
      final from = boxes[link.from];
      final to = boxes[link.to];
      if (from == null || to == null) continue;

      // Where a wire meets a box that has no socket for it — Node-RED joins
      // nodes rather than ports, and a scene tree has no ports at all. **It
      // leaves by the side the graph reads towards**: the right edge where the
      // graph runs across the page, the bottom edge where it runs down it.
      // Taking the right edge in a downward graph sent every wire out past the
      // margin and back, which is what the picture showed the moment a Godot
      // scene was drawn.
      final downwards = graph.direction == GraphDirection.topToBottom;
      final start =
          _pinAt(link.from, link.fromPin, out: true) ??
          (downwards
              ? Offset(from.center.dx, from.bottom)
              : Offset(from.right, from.center.dy));
      final end =
          _pinAt(link.to, link.toPin, out: false) ??
          (downwards
              ? Offset(to.center.dx, to.top)
              : Offset(to.left, to.center.dy));

      // The lane the layout kept open for this wire, where it crosses layers
      // it does not stop in. Without it the wire goes under whatever stands in
      // the way and appears to arrive at a socket that is not there.
      final through = [
        start,
        for (final point in routes[i] ?? const <Offset2>[])
          Offset(point.x, point.y),
        end,
      ];

      final lr = graph.direction == GraphDirection.leftToRight;
      final path = Path()..moveTo(start.dx, start.dy);
      for (var leg = 0; leg + 1 < through.length; leg++) {
        final one = through[leg];
        final other = through[leg + 1];
        // Bezier, leaving horizontally where the graph reads left to right and
        // vertically where it reads down. The control distance grows with the
        // span, which is what stops short wires looking like knots.
        final span = (other - one).distance;
        final reach = math.max(24.0, math.min(160.0, span * 0.4));
        path.cubicTo(
          one.dx + (lr ? reach : 0),
          one.dy + (lr ? 0 : reach),
          other.dx - (lr ? reach : 0),
          other.dy - (lr ? 0 : reach),
          other.dx,
          other.dy,
        );
      }

      // The wires touching the focused node are brighter and drawn last, so
      // what the next press will follow is the thing the eye finds first.
      final touching =
          focusedId != null && (link.from == focusedId || link.to == focusedId);
      final colour = link.role == LinkRole.flow
          ? colours.accent
          : colours.wire(link.type);

      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = touching
              ? 2.4
              : (link.role == LinkRole.flow ? 2 : 1.4)
          ..color = touching ? colour : colour.withValues(alpha: 0.75),
      );

      // **A wire that says what it is, says it on itself.** A Godot signal is
      // the case: `body_entered → _on_hit` is the whole reason that wire
      // exists, and without it a reader is left asking what the line across
      // the picture means. Only wires whose reader gave them a label carry
      // one, so nothing else on the canvas gains a word.
      if (link.label.isNotEmpty) {
        // Near the end it leaves from, not at the middle of the path. A wire
        // that goes backwards is routed the long way round, and the middle of
        // *that* is out past the edge of the picture with nothing beside it —
        // which is where the first cut put the words, and it read as a caption
        // for nothing.
        final towards = through.length > 1 ? through[1] : end;
        final step = towards - start;
        final at = step.distance < 1
            ? start
            : start + step / step.distance * math.min(46, step.distance / 2);
        _labelOn(canvas, at, link.label, colour);
      }

      // **A wire that leaves the view carries the name of where it goes.** Not
      // decoration: with the keyboard walking the graph, a wire off the edge is
      // the only clue about where the next press lands.
      if (touching) {
        if (!view.contains(end)) {
          _stub(canvas, start, end, graph.nodes[_indexOf(link.to)], colour);
        }
        if (!view.contains(start)) {
          _stub(canvas, end, start, graph.nodes[_indexOf(link.from)], colour);
        }
      }
    }
  }

  int _indexOf(String id) => graph.nodes.indexWhere((node) => node.id == id);

  /// A name written where a wire leaves the view, at the point it crosses.
  void _stub(
    Canvas canvas,
    Offset from,
    Offset towards,
    GraphNode far,
    Color colour,
  ) {
    final direction = towards - from;
    if (direction.distance < 1) return;
    final at = from + direction / direction.distance * 60;

    canvas.drawCircle(at, 3, Paint()..color = colour);
    _text(
      canvas,
      far.caption,
      at + const Offset(6, -7),
      colour,
      theme.fontSize - 2,
      maxWidth: 140,
    );
  }

  /// What a wire is called, written on the wire itself.
  ///
  /// On a small plate of the canvas's own colour, because a word laid straight
  /// over a line is a word with a line through it.
  void _labelOn(Canvas canvas, Offset at, String text, Color colour) {
    final size = theme.fontSize - 2;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: colour, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 160);

    final plate = Rect.fromCenter(
      center: at,
      width: painter.width + 10,
      height: painter.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(plate, const Radius.circular(4)),
      // The canvas's own ground, so the words sit *on* the picture rather
      // than on a box that is not there.
      Paint()
        ..color = Color.alphaBlend(
          theme.panelBackground.withValues(alpha: 0.86),
          theme.panelBackground,
        ),
    );
    painter.paint(canvas, Offset(plate.left + 5, plate.top + 2));
  }

  /// Where a pin sits on its node, or null when the link named none.
  Offset? _pinAt(String node, String? pin, {required bool out}) {
    if (pin == null) return null;
    final box = boxes[node];
    final owner = graph.nodes.where((n) => n.id == node).firstOrNull;
    if (box == null || owner == null) return null;

    // A dot has no row to put a socket on, and neither has a folded box: both
    // meet their wires at the edge the wire comes from. Left to the row
    // arithmetic below, a folded node's sockets land outside its own box.
    if (isReroute(owner) || _isCollapsed(owner)) {
      return Offset(out ? box.right : box.left, box.center.dy);
    }

    final pins = out ? owner.outputs : owner.inputs;
    final index = pins.indexWhere((p) => p.id == pin);
    if (index < 0) return null;

    // Inputs run down the left, outputs down the right, both under the title.
    final offset = out ? owner.inputs.length + index : index;
    return Offset(
      out ? box.right : box.left,
      box.top + titleHeight + _padding + rowHeight * (offset + 0.5),
    );
  }

  static const double _padding = 6;

  void _paintNodes(Canvas canvas) {
    for (var i = 0; i < graph.nodes.length; i++) {
      final node = graph.nodes[i];
      final box = boxes[node.id];
      if (box == null) continue;

      final role = colours.of(node.role);
      final lit = i == hovered || i == focused;
      final here = i == focused;

      if (isReroute(node)) {
        _paintReroute(canvas, node, box, lit: lit, here: here);
        continue;
      }

      // The strip is worked out as a colour rather than laid on as a veil, so
      // the name written on it can be asked what it reads as. A tint whose
      // final colour nobody knows is a tint nothing can be read on.
      final strip = colours.strip(node.role, lit: lit);

      canvas
        ..drawRRect(
          RRect.fromRectAndRadius(box, const Radius.circular(_radius)),
          Paint()..color = colours.surface,
        )
        // The title strip carries the node's role, which is the one place a
        // role is worth a band rather than a line.
        ..drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(box.left, box.top, box.width, titleHeight),
            topLeft: const Radius.circular(_radius),
            topRight: const Radius.circular(_radius),
          ),
          Paint()..color = strip,
        )
        ..drawRRect(
          RRect.fromRectAndRadius(box, const Radius.circular(_radius)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = here ? 2.5 : (lit ? 2 : 1)
            ..color = lit ? colours.accent : role,
        );

      // The marks a reader asked for, at the far end of the title strip. They
      // are drawn first so the name knows how much room it has left.
      final marks = node.badges
          .map((badge) => kNodeBadges[badge.toLowerCase()])
          .whereType<IconData>()
          .toList();
      final ink = legibleOn(strip, theme);
      var edge = box.right - 6;
      for (final mark in marks.reversed) {
        final size = theme.fontSize;
        edge -= size;
        _icon(canvas, mark, Offset(edge, box.top + 6), ink, size);
        edge -= 2;
      }

      _text(
        canvas,
        node.caption,
        Offset(box.left + 8, box.top + 6),
        ink,
        theme.fontSize,
        maxWidth: math.max(24, edge - box.left - 12),
        weight: theme.strongFontWeight.weight,
      );

      // Folded: the strip and nothing else. The wires still arrive, at the
      // edge of what there is — which is what makes folding a way of reading a
      // big graph rather than a way of hiding half of it.
      if (_isCollapsed(node)) continue;

      // Half way through a fold the rows are taller than the box that is
      // closing over them, so they are clipped to it rather than spilling out
      // below. Clip *and* paint: the box paints, this clips what is inside it.
      final folding = foldOf(node) > 0;
      if (folding) {
        canvas
          ..save()
          ..clipRect(box);
      }

      var y = box.top + titleHeight + _padding;
      for (final pin in node.inputs) {
        _pin(canvas, Offset(box.left, y + rowHeight / 2), pin, left: true);
        _text(
          canvas,
          pin.caption,
          Offset(box.left + 10, y),
          colours.muted,
          theme.fontSize - 2,
          maxWidth: box.width / 2 - 12,
        );
        y += rowHeight;
      }
      for (final pin in node.outputs) {
        _pin(canvas, Offset(box.right, y + rowHeight / 2), pin, left: false);
        _text(
          canvas,
          pin.caption,
          Offset(box.left + 10, y),
          colours.muted,
          theme.fontSize - 2,
          maxWidth: box.width - 20,
          align: TextAlign.right,
        );
        y += rowHeight;
      }

      // The fields, which are most of what somebody opened the file to read.
      var fieldY = box.top + titleHeight + _padding;
      for (final field in node.fields) {
        _text(
          canvas,
          '${field.label}  ${field.value}',
          Offset(box.left + box.width / 2, fieldY),
          colours.ink.withValues(alpha: 0.85),
          theme.fontSize - 2,
          maxWidth: box.width / 2 - 10,
        );
        fieldY += rowHeight;
      }

      if (folding) canvas.restore();
    }
  }

  /// A bend in a wire: a dot in the colour of what travels through it.
  void _paintReroute(
    Canvas canvas,
    GraphNode node,
    Rect box, {
    required bool lit,
    required bool here,
  }) {
    final type = (node.outputs.isNotEmpty ? node.outputs.first.type : null) ??
        (node.inputs.isNotEmpty ? node.inputs.first.type : null);
    canvas
      ..drawCircle(
        box.center,
        box.width / 2 - 3,
        Paint()..color = colours.wire(type),
      )
      ..drawCircle(
        box.center,
        box.width / 2 - 3,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = here ? 2.5 : (lit ? 2 : 1)
          ..color = lit ? colours.accent : colours.surface,
      );
  }

  /// One icon from the interface's own set, drawn on the canvas.
  void _icon(
    Canvas canvas,
    IconData icon,
    Offset at,
    Color colour,
    double size,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: size,
          color: colour,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  void _pin(Canvas canvas, Offset at, GraphPin pin, {required bool left}) {
    canvas.drawCircle(at, 3.5, Paint()..color = colours.wire(pin.type));
  }

  /// One run of text, laid out in the application's own family and size.
  void _text(
    Canvas canvas,
    String text,
    Offset at,
    Color colour,
    double size, {
    double? maxWidth,
    FontWeight? weight,
    TextAlign align = TextAlign.left,
    int maxLines = 1,
  }) {
    if (text.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: colour,
          fontSize: size,
          fontFamily: theme.fileFamily,
          fontWeight: weight,
          decoration: TextDecoration.none,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? double.infinity);

    painter.paint(
      canvas,
      align == TextAlign.right && maxWidth != null
          ? Offset(at.dx + maxWidth - painter.width, at.dy)
          : at,
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(_NodeGraphPainter old) =>
      old.graph != graph ||
      old.scale != scale ||
      old.origin != origin ||
      old.hovered != hovered ||
      old.focused != focused ||
      old.theme != theme;
}

/// The wire the keyboard just walked, in words.
///
/// Drawn in the panel's own colours and at its own size, and quiet: it is a
/// caption on a movement, not a thing to be looked at. The graph is what is
/// being read.
class _Said extends StatelessWidget {
  const _Said({required this.text, required this.theme});

  final String text;
  final AppearanceSettings theme;

  @override
  Widget build(BuildContext context) {
    final fill = theme.panelBackground.withValues(alpha: 0.86);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(kMenuCornerRadius),
        border: Border.all(
          color: theme.panelForeground.withValues(alpha: 0.18),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: theme.panelForeground.withValues(alpha: 0.9),
            fontSize: theme.fontSize - 1,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}
