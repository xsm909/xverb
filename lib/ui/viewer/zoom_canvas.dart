import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../motion.dart';
import '../widgets/viewport_chrome.dart';
import 'content_swap.dart';
import 'reading_colours.dart';

/// What the canvas is told about the folder it is standing in: that something
/// above it has taken the arrow keys, and how to walk to a neighbour.
///
/// **The strip of neighbours along the bottom of a viewer**, and it is the
/// only thing that ever sets this. A picture bigger than the window would
/// otherwise pan with all four arrows, so an arrow would mean two things —
/// move the picture, open the next file — with nothing on screen saying which.
/// The strip resolves that by *being* on screen.
///
/// **All four, not only the horizontal pair, and the reason is the panel.**
/// Down in a listing is the next file. Pressing F3 on that file and finding
/// that Down now moves the picture instead is the same key meaning two
/// different things either side of one press. So while the strip
/// is up the arrows walk the folder, exactly as they walked the listing, and
/// the picture is panned with Shift held or with the hand. Put the strip away
/// and all four are the canvas's again.
///
/// Inherited rather than a parameter because the canvas is three widgets below
/// the page that knows: the picture and the drawing would each have to carry a
/// flag they have no opinion about.
class FolderWalk extends InheritedWidget {
  const FolderWalk({
    super.key,
    required this.taken,
    required this.onWalk,
    required super.child,
  });

  /// Whether the arrows belong to the strip rather than to the canvas.
  final bool taken;

  /// Walks [by] places along the strip. Null where there is nowhere to walk —
  /// a preview in a panel, a test — and then the canvas keeps every gesture
  /// to itself.
  final void Function(int by)? onWalk;

  static FolderWalk? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FolderWalk>();

  @override
  bool updateShouldNotify(FolderWalk old) =>
      old.taken != taken || old.onWalk != onWalk;
}

/// How a thing arrives in the window, and what a resize does to it afterwards.
///
/// Three answers rather than two, and the third is the one a photograph wants.
/// [fit] never enlarges — a 16-pixel icon shown as a mural says nothing true
/// about it — and that is right for the general case of "look at this file".
/// A folder of photographs is not the general case: they are all bigger than
/// they are shown and the window is the frame, so [fill] is what a picture
/// viewer means by looking at one.
enum ZoomMode {
  /// The whole of it in the window, and never above 1:1.
  fit,

  /// **The window full, edge to edge, with whatever does not fit cropped.**
  ///
  /// Not "the whole of it, enlarged" — that was the first cut and it still
  /// left a band at two edges whenever the picture and the window were not the
  /// same shape, which is nearly always. A photograph shown with bands down
  /// the sides is not shown full size. What runs off the edge
  /// is still there: the arrows and the hand reach it.
  fill,

  /// One unit of the file on one pixel of the screen. Unmoved by a resize.
  actual;

  static ZoomMode byName(String? name) =>
      ZoomMode.values.firstWhere((m) => m.name == name, orElse: () => fill);
}

/// The mode a thing opens in, and where to write down a change to it.
///
/// Provided by the page, read by every canvas under it. Absent — a canvas in a
/// panel, a test — and the canvas opens fitted and remembers nothing, which is
/// what it did before there was anything to remember.
class ViewerZoomMode extends InheritedWidget {
  const ViewerZoomMode({
    super.key,
    required this.mode,
    required this.onChanged,
    required super.child,
  });

  /// What a thing opens in.
  final ZoomMode mode;

  /// Told when the reader presses one of the three, so that the next file and
  /// the next session open the same way. **Not** told about a zoom by hand:
  /// stepping the ladder is looking closer at *this* picture, not an answer to
  /// how pictures should open.
  final ValueChanged<ZoomMode> onChanged;

  static ViewerZoomMode? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ViewerZoomMode>();

  @override
  bool updateShouldNotify(ViewerZoomMode old) => old.mode != mode;
}

/// Something looked at whole and then looked into: fit, 1:1, zoom and panning.
///
/// **One canvas for two kinds of thing**, because a picture and a drawing are
/// looked at in exactly the same way and any difference between them would be
/// an accident of who wrote which file. What differs is one method — how the
/// thing paints itself into a rectangle — and everything else here is shared:
/// the magnification, the offset, the keys, the switches, the caption.
///
/// **What 1:1 means, and it is a decision rather than a detail.** One unit of
/// the file on one pixel of the screen — the magnification counts device
/// pixels, not points. On a display at two device pixels to the point that
/// draws a thousand-pixel picture across five hundred points, which looks small
/// and is the only reading of "1:1" that resamples nothing.
class ZoomCanvas extends StatefulWidget {
  const ZoomCanvas({
    super.key,
    required this.content,
    required this.paint,
    required this.caption,
    this.hasKeyboard = true,
    this.detail,
  });

  /// The natural size of what is being looked at, in its own units — a
  /// picture's pixels, a drawing's `viewBox`.
  final Size content;

  /// Draws it into [at], already scaled: [scale] is logical pixels per unit,
  /// and is passed for the sake of anything that has to decide how finely to
  /// draw rather than how big.
  final void Function(Canvas canvas, Rect at, double scale) paint;

  /// What the caption says, given the magnification it is being shown at.
  final String Function(double zoom) caption;

  /// Anything that was left out or could not be drawn, said beside the caption
  /// in the colour of a warning. Null when there is nothing to say.
  final String? detail;

  /// Whether this is the thing being worked in. A picture previewed in the
  /// panel beside the one being typed in must not take the arrow keys from it.
  final bool hasKeyboard;

  /// The magnifications the keys and the switches step between, as units of
  /// the file per pixel of the screen.
  ///
  /// A ladder rather than a factor, so the numbers that get read out are the
  /// ones people know — 50%, 100%, 200% — and so that stepping down and back up
  /// returns to where it started.
  static const List<double> ladder = [
    0.05, 0.0833, 0.125, 0.25, 0.3333, 0.5, 0.6667,
    1, 1.5, 2, 3, 4, 6, 8, 12, 16, 32,
  ];

  static double get minZoom => ladder.first;
  static double get maxZoom => ladder.last;

  @override
  State<ZoomCanvas> createState() => _ZoomCanvasState();
}

class _ZoomCanvasState extends State<ZoomCanvas>
    with SingleTickerProviderStateMixin {
  /// Units of the file per pixel of the screen. See the note on [ZoomCanvas].
  double _zoom = 1;

  /// Where the middle of the thing is, in logical pixels from the middle of
  /// the window.
  Offset _pan = Offset.zero;

  /// Which of the three the magnification is, or null once it is the reader's
  /// own.
  ///
  /// Kept as a mode instead of a number so that **resizing the window keeps a
  /// fitted thing fitted, and a filled one filled**. The moment anything is
  /// zoomed by hand it is the reader's answer and the window stops having an
  /// opinion.
  ZoomMode? _mode;

  /// What a thing opens in, from the page above — see [ViewerZoomMode]. Read in
  /// [build], where an inherited widget can be asked for.
  ZoomMode _opensIn = ZoomMode.fit;

  /// Whether the first build has happened. Without it the line that puts a
  /// newly arrived canvas into [_opensIn] would also undo every zoom by hand,
  /// because both states are `_mode == null`.
  bool _arrived = false;

  /// The room it was last given, and at what pixel ratio. Read by the keys,
  /// which have no layout of their own to ask.
  Size _room = Size.zero;
  double _ratio = 1;

  /// Whether the arrows belong to something above. Read in [build], where an
  /// inherited widget is asked for, and kept for the key handler, which runs
  /// outside one.
  bool _arrowsTaken = false;

  /// How to reach the neighbouring file, from the page above.
  void Function(int by)? _walk;

  /// The magnification a trackpad gesture began at. A pinch reports how far it
  /// has come *since it started*, not since the last frame, so this is what it
  /// is measured against.
  double _pinchFrom = 1;

  /// How much sideways travel a slide has to gather before it counts as asking
  /// for the next picture, in logical pixels.
  ///
  /// A threshold rather than the first pixel: two fingers never move on one
  /// axis alone, and a picture that changed the moment a hand drifted would be
  /// a folder nobody could look at.
  static const double _slideToWalk = 90;

  /// Made in [initState], **never lazily**: a `late final` controller that
  /// nothing has touched is created by `dispose()` instead, and creating one
  /// asks the tree for an inherited widget at the one moment it will not
  /// answer. The model canvas paid for this once already.
  late final AnimationController _glide;
  double _fromZoom = 1;
  double _toZoom = 1;
  Offset _fromPan = Offset.zero;
  Offset _toPan = Offset.zero;

  /// **Taken, not asked for** — the same as the model canvas and the reading.
  /// A viewer is not a route: it opens inside the scope F3 was pressed in, and
  /// `autofocus` lands nowhere.
  final FocusNode _keys = FocusNode(debugLabel: 'canvas');

  @override
  void initState() {
    super.initState();
    _glide = AnimationController(vsync: this);
    _takeKeyboard();
  }

  @override
  void didUpdateWidget(ZoomCanvas old) {
    super.didUpdateWidget(old);
    if (old.content != widget.content) {
      // A different picture is a fresh arrival: it opens the way pictures open
      // here, whatever the last one was left at.
      _mode = _opensIn;
      _pan = Offset.zero;
    }
    if (widget.hasKeyboard && !old.hasKeyboard) _takeKeyboard();
  }

  @override
  void dispose() {
    _glide.dispose();
    _keys.dispose();
    super.dispose();
  }

  void _takeKeyboard() {
    if (!widget.hasKeyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.hasKeyboard && !_keys.hasFocus) {
        _keys.requestFocus();
      }
    });
  }

  // ---------------------------------------------------------------- geometry

  /// The magnification [mode] asks for, given the room there is.
  ///
  /// The two window-answering modes differ by which way they take the pair.
  /// Fit takes the **smaller** of the two ratios, so the whole picture is
  /// inside the window; fill takes the **larger**, so the window is inside the
  /// picture and there is no band at any edge. Fit also has 1.0 in its list,
  /// which is what keeps it from enlarging a small file into a mural.
  /// The smallest magnification worth having: the one where the whole of it is
  /// in the window.
  ///
  /// **Zooming out past that shows nothing more.** The picture is already
  /// entirely on screen; every step further is the same picture smaller, in
  /// the middle of a growing field of nothing, until it is a stamp. So the
  /// floor is fit rather than the bottom of the ladder — and for something
  /// already smaller than the window, fit is 1:1, which means it cannot be
  /// shrunk at all. There is nothing to be learned by making a sixteen-pixel
  /// icon eight pixels.
  double get _floor => _zoomFor(ZoomMode.fit, _room, _ratio);

  double _zoomFor(ZoomMode mode, Size room, double ratio) {
    final content = widget.content;
    if (content.isEmpty || room.isEmpty) return 1;
    if (mode == ZoomMode.actual) return 1;
    final across = room.width * ratio / content.width;
    final down = room.height * ratio / content.height;
    final wanted = mode == ZoomMode.fill
        ? (across > down ? across : down)
        : [1.0, across, down].reduce((a, b) => a < b ? a : b);
    return wanted.clamp(ZoomCanvas.minZoom, ZoomCanvas.maxZoom);
  }

  double get _liveZoom => _glide.isAnimating
      ? _fromZoom + (_toZoom - _fromZoom) * _glide.value
      : _zoom;

  Offset get _livePan =>
      _glide.isAnimating ? Offset.lerp(_fromPan, _toPan, _glide.value)! : _pan;

  /// The offset with the thing kept in the window.
  ///
  /// An axis it does not fill is centred and cannot be moved at all; an axis it
  /// overflows may be moved until its edge reaches the edge of the window, and
  /// no further. Dragging a picture entirely off the screen and having to find
  /// it again is the one thing a pannable canvas must not do.
  Offset _held(Offset pan, double zoom) {
    final drawn = widget.content * (zoom / _ratio);
    double axis(double at, double length, double room) {
      if (length <= room) return 0;
      final slack = (length - room) / 2;
      return at.clamp(-slack, slack);
    }

    return Offset(
      axis(pan.dx, drawn.width, _room.width),
      axis(pan.dy, drawn.height, _room.height),
    );
  }

  // ----------------------------------------------------------------- moving

  /// A stepped change: the magnification and the offset travel together.
  void _travel(double zoom, Offset pan, {ZoomMode? mode}) {
    final was = _liveZoom;
    final wasPan = _livePan;
    final next = zoom.clamp(_floor, ZoomCanvas.maxZoom);
    final duration = motionOf(context, kImageZoomDuration);

    setState(() {
      _zoom = next;
      _pan = _held(pan, next);
      _mode = mode;
    });
    if (duration == Duration.zero) {
      // Off means off, not "very fast": nothing is run at all and it is simply
      // there at its new size.
      _glide.value = 1;
      return;
    }
    _fromZoom = was;
    _fromPan = wasPan;
    _toZoom = _zoom;
    _toPan = _pan;
    _glide.duration = duration;
    _glide.forward(from: 0);
  }

  /// Where the offset has to be for [about] — a point in the window — to stay
  /// over the same place in the file as the magnification changes.
  Offset _around(Offset about, double from, double to) {
    final away = about - Offset(_room.width / 2, _room.height / 2);
    final pan = _livePan;
    return away - (away - pan) * (to / from);
  }

  void _stepTo(double zoom, {Offset? about}) {
    final from = _liveZoom;
    final next = zoom.clamp(_floor, ZoomCanvas.maxZoom);
    final at = about ?? Offset(_room.width / 2, _room.height / 2);
    _travel(next, _around(at, from, next));
  }

  void _stepBy(int steps, {Offset? about}) {
    final from = _liveZoom;
    final ladder = ZoomCanvas.ladder;
    double next;
    if (steps > 0) {
      next = ladder.firstWhere((z) => z > from * 1.001, orElse: () => from);
    } else {
      next = ladder.lastWhere((z) => z < from * 0.999, orElse: () => from);
      // The rung below the floor is not a magnification anybody can have, and
      // the floor itself is worth arriving at exactly: one more press from
      // anywhere above it lands on the whole picture rather than stopping a
      // rung short of it.
      final floor = _floor;
      if (next < floor) next = from > floor ? floor : from;
    }
    if (next == from) return;
    _stepTo(next, about: about);
  }

  /// Puts it in [mode] and says so upwards, so the next file opens this way.
  void _put(ZoomMode mode) {
    _travel(_zoomFor(mode, _room, _ratio), Offset.zero, mode: mode);
    ViewerZoomMode.of(context)?.onChanged(mode);
  }

  /// Straight to the hand, with no animation: this follows a finger or a wheel
  /// and must arrive where they are, not where they were.
  void _drag(Offset by) {
    if (!_canMove) return;
    _glide.stop();
    setState(() {
      _zoom = _liveZoom;
      _pan = _held(_livePan + by, _zoom);
    });
  }

  void _wheel(Offset at, double delta) {
    _glide.stop();
    final from = _liveZoom;
    final next = (from * (delta > 0 ? 1 / 1.12 : 1.12))
        .clamp(_floor, ZoomCanvas.maxZoom);
    final pan = _around(at, from, next);
    setState(() {
      _zoom = next;
      _pan = _held(pan, next);
      _mode = null;
    });
  }

  // ------------------------------------------------------------- trackpad

  /// A trackpad gesture beginning: two fingers down, before either a pinch or
  /// a slide has declared itself.
  void _gestureStart() {
    _glide.stop();
    _pinchFrom = _liveZoom;
    _slid = Offset.zero;
  }

  /// How far the current slide has travelled without the picture being able to
  /// follow it — what decides that a sideways slide meant the next picture.
  Offset _slid = Offset.zero;

  /// Two fingers moving, and the pair of things they can mean.
  ///
  /// **A pinch is measured from where the gesture started**, not from the last
  /// frame: `scale` is cumulative, and multiplying frame by frame drifts.
  ///
  /// **A slide moves the picture while the picture has anywhere to go.** When
  /// it has not — it fits across, or it is already against the edge — a
  /// sideways slide is asking for the neighbouring file, which is the same
  /// rule the arrows keep and the same one every picture viewer on this
  /// machine keeps. The strip on screen is what makes it readable.
  void _gestureUpdate(Offset at, Offset moved, double scale) {
    final wanted = (_pinchFrom * scale).clamp(_floor, ZoomCanvas.maxZoom);
    final from = _liveZoom;
    if ((wanted - from).abs() > 0.0001) {
      _glide.stop();
      setState(() {
        _pan = _held(_around(at, from, wanted), wanted);
        _zoom = wanted;
        _mode = null;
      });
      return;
    }

    // A hand that turns round has started a new slide. Without this, pushing
    // right and then left would add up to nothing and a slide could never be
    // taken back.
    if (_slid.dx != 0 && moved.dx != 0 && _slid.dx.sign != moved.dx.sign) {
      _slid = Offset.zero;
    }

    final was = _livePan;
    if (_canMove) _drag(moved);
    // What the picture could not take up is what the fingers are asking for
    // somewhere else.
    _slid += moved - (_livePan - was);
    final walk = _walk;
    if (walk == null || _slid.dx.abs() < _slideToWalk) return;
    if (_slid.dx.abs() < _slid.dy.abs()) return;
    walk(_slid.dx > 0 ? -1 : 1);
    _slid = Offset.zero;
  }

  /// Whether there is anywhere to move to — something inside the window has no
  /// offset, so the arrow keys are not this canvas's to take.
  bool get _canMove {
    final drawn = widget.content * (_liveZoom / _ratio);
    return drawn.width > _room.width + 0.5 || drawn.height > _room.height + 0.5;
  }

  // --------------------------------------------------------------- keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (widget.content.isEmpty) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.equal:
      case LogicalKeyboardKey.add:
      case LogicalKeyboardKey.numpadAdd:
        _stepBy(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.minus:
      case LogicalKeyboardKey.numpadSubtract:
        _stepBy(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit1:
      case LogicalKeyboardKey.numpad1:
        _put(ZoomMode.actual);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.digit0:
      case LogicalKeyboardKey.numpad0:
        _put(ZoomMode.fit);
        return KeyEventResult.handled;
    }

    // Something that fits leaves the arrows alone, so that whatever else would
    // answer them still can.
    const step = 64.0;
    // The arrows are the strip's while the strip is up — unless Shift is held,
    // which is how the hand still reaches the edges of a magnified picture.
    if (_canMove && (!_arrowsTaken || keys.isShiftPressed)) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowLeft:
          _drag(const Offset(step, 0));
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight:
          _drag(const Offset(-step, 0));
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          _drag(const Offset(0, step));
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          _drag(const Offset(0, -step));
          return KeyEventResult.handled;
      }
    }

    // The letters, taken from what they say rather than from where they are on
    // the board — see the note in the commander screen about a binding being a
    // key and not the letter a layout made of it.
    switch (event.character?.toLowerCase()) {
      case 'f':
        _put(ZoomMode.fit);
        return KeyEventResult.handled;
      // The window as the frame. W for the window, because F was taken by the
      // one that will not enlarge and the two are a pair.
      case 'w':
        _put(ZoomMode.fill);
        return KeyEventResult.handled;
      case '+':
        _stepBy(1);
        return KeyEventResult.handled;
      case '-':
        _stepBy(-1);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------------ paint

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final arriving = Arriving.of(context);
    final folder = FolderWalk.of(context);
    _arrowsTaken = folder?.taken ?? false;
    _walk = folder?.onWalk;
    _opensIn = ViewerZoomMode.of(context)?.mode ?? ZoomMode.fit;
    // The first build is the arrival: whatever the page says pictures open in
    // is what this one opens in. `_mode` is only null again once the reader
    // has zoomed by hand.
    _mode ??= _arrived ? null : _opensIn;
    _arrived = true;
    if (widget.content.isEmpty) return const SizedBox.expand();

    return LayoutBuilder(
      builder: (context, room) {
        _room = Size(room.maxWidth, room.maxHeight);
        _ratio = MediaQuery.devicePixelRatioOf(context);
        // The window's answer, recomputed as the window changes — which is what
        // keeps a fitted thing fitted while a panel is dragged wider.
        final mode = _mode;
        if (mode != null && !_glide.isAnimating) {
          _zoom = _zoomFor(mode, _room, _ratio);
        }

        return Focus(
          focusNode: _keys,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent) return;
              // **A wheel and a trackpad are different devices and mean
              // different things.** A wheel notch is a step of magnification,
              // which is what it has always been here and what Windows
              // expects. Two fingers on a trackpad are a hand pushing the
              // picture about, and treating them as a wheel — which is what
              // this did — meant that scrolling on a Mac zoomed.
              if (event.kind == PointerDeviceKind.trackpad) {
                // **Not `_gestureStart` here.** A scroll event carries no
                // beginning and no end, so calling it would throw away what
                // the slide had gathered on every frame and a sideways slide
                // could never reach the length that means "the next picture".
                // What separates one slide from the next on this road is the
                // hand turning round, which [_gestureUpdate] watches for.
                _pinchFrom = _liveZoom;
                _gestureUpdate(event.localPosition, -event.scrollDelta, 1);
                return;
              }
              _wheel(event.localPosition, event.scrollDelta.dy);
            },
            // The other road the same gestures arrive by. macOS reports
            // trackpad pan and pinch as their own events where anything is
            // listening for them, and falls back to scroll events where
            // nothing is; both are answered, so it does not matter which the
            // machine chooses. Neither ever fires on Windows or Linux, which
            // is why none of this can cost them anything.
            onPointerPanZoomStart: (_) => _gestureStart(),
            onPointerPanZoomUpdate: (event) => _gestureUpdate(
              event.localPosition,
              event.panDelta,
              event.scale,
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Fitted and 1:1 are the two magnifications anybody wants, so the
              // press that means "the other one" swaps between them.
              // Between the way pictures open here and one pixel to one
              // pixel, which are the two things anybody double-presses for.
              onDoubleTap: () => _mode == ZoomMode.actual
                  ? _put(_opensIn == ZoomMode.actual ? ZoomMode.fill : _opensIn)
                  : _put(ZoomMode.actual),
              onPanUpdate: (details) => _drag(details.delta),
              child: AnimatedBuilder(
                animation: _glide,
                builder: (context, _) => CustomPaint(
                  painter: _CanvasPainter(
                    content: widget.content,
                    draw: widget.paint,
                    scale: _liveZoom / _ratio,
                    pan: _livePan,
                  ),
                  // **The furniture belongs to the picture on screen, not to
                  // the one arriving.** Two translucent panels stacked are
                  // darker than one, so a swap that drew both made the zoom
                  // and magnifier switches blink.
                  // The arriving canvas draws its picture and nothing
                  // else; the one being left keeps its switches and its caption
                  // until it goes, and since the two are identical and in the
                  // same place, the exchange has nothing in it to see. See
                  // [Arriving].
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: arriving
                              ? const SizedBox.shrink()
                              : _switches(),
                        ),
                      ),
                      const Spacer(),
                      // Where the model says what it is, and left rather than
                      // centred for the same reason: it is a caption on the
                      // window, not a title of the picture. Away while
                      // arriving, with the switches and for the same reason.
                      if (!arriving) Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  widget.caption(_liveZoom),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: readingColours(context).muted,
                                  ),
                                ),
                              ),
                              // What was left out, said where what was shown is
                              // said — the rule the model canvas keeps.
                              if (widget.detail?.isNotEmpty == true) ...[
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.broken_image_outlined,
                                  size: 12,
                                  color: theme.colorScheme.error
                                      .withValues(alpha: 0.8),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    tr(widget.detail!),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme.colorScheme.error
                                          .withValues(alpha: 0.8),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _switches() => ViewportChrome(
        children: [
          ViewportSwitch(
            icon: Icons.zoom_out,
            message: '${tr('Zoom out')}  −',
            onPressed: () => _stepBy(-1),
          ),
          ViewportSwitch(
            icon: Icons.zoom_in,
            message: '${tr('Zoom in')}  +',
            onPressed: () => _stepBy(1),
          ),
          const ViewportRule(),
          ViewportSwitch(
            icon: Icons.fit_screen_outlined,
            message: '${tr('Fit to the window')}  F',
            on: _mode == ZoomMode.fit,
            onPressed: () => _put(ZoomMode.fit),
          ),
          ViewportSwitch(
            icon: Icons.open_in_full,
            message: '${tr('Fill the window')}  W',
            on: _mode == ZoomMode.fill,
            onPressed: () => _put(ZoomMode.fill),
          ),
          ViewportSwitch(
            icon: Icons.photo_size_select_actual_outlined,
            message: '${tr('One pixel to one pixel')}  1',
            on: _mode == ZoomMode.actual ||
                (_mode == null && (_liveZoom - 1).abs() < 0.001),
            onPressed: () => _put(ZoomMode.actual),
          ),
        ],
      );
}

/// How much of the file you are seeing, as a percentage anybody would say.
String zoomPercent(double zoom) => zoom < 0.1
    ? (zoom * 100).toStringAsFixed(1)
    : (zoom * 100).round().toString();

class _CanvasPainter extends CustomPainter {
  const _CanvasPainter({
    required this.content,
    required this.draw,
    required this.scale,
    required this.pan,
  });

  final Size content;
  final void Function(Canvas canvas, Rect at, double scale) draw;

  /// Logical pixels per unit of the file — the magnification with the
  /// display's own ratio already taken out of it.
  final double scale;
  final Offset pan;

  @override
  void paint(Canvas canvas, Size size) {
    final drawn = content * scale;
    final at = Offset(
      (size.width - drawn.width) / 2 + pan.dx,
      (size.height - drawn.height) / 2 + pan.dy,
    );
    // Clipped, because a `CustomPaint` is not bounded by its widget: whatever
    // hangs off the edge would otherwise be painted over the page beside it,
    // which is a lesson the model canvas paid for in pixels.
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    draw(canvas, at & drawn, scale);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CanvasPainter old) =>
      old.content != content ||
      old.draw != draw ||
      old.scale != scale ||
      old.pan != pan;
}
