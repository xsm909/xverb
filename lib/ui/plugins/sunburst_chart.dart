import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/viewer.dart';
import '../motion.dart';
import '../widgets/press_and_hold.dart' show kMenuHoldDevices;

/// A ring chart a plugin describes and the host draws.
///
/// The plugin sends a flat list of wedges and what each is worth; everything
/// else — where they sit, what colour they are, how they move when the user
/// goes a level deeper — is decided here, because it depends on the size of
/// the widget and the theme, neither of which a plugin in another process can
/// see. That division is the one the four older primitives already make: the
/// plugin says what it means, the application says how it looks.
class SunburstChart extends StatefulWidget {
  const SunburstChart({
    super.key,
    required this.content,
    this.onActivate,
    this.onMark,
    this.onButton,
  });

  final ViewerContent content;

  /// A wedge was opened. -1 is the middle: the way back out.
  final void Function(int segment)? onActivate;

  /// A wedge was picked out — the secondary press, or a long press where
  /// there is no second button.
  final void Function(int segment)? onMark;

  final void Function(String buttonId)? onButton;

  @override
  State<SunburstChart> createState() => _SunburstChartState();
}

class _SunburstChartState extends State<SunburstChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    // The chart fills the panel, so its re-arranging is a page-sized event
    // rather than something happening in a corner of one.
    duration: Duration(milliseconds: kDiskMapAnimationDuration),
    value: 1,
  );

  _Layout _layout = _Layout.empty;
  _Layout _previous = _Layout.empty;
  int _hovered = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = motionOf(context, kDiskMapAnimationDuration);
    _rebuild(animate: false);
  }

  @override
  void didUpdateWidget(SunburstChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.content, widget.content)) _rebuild(animate: true);
  }

  /// Rebuilds the geometry, keeping the old one so the two can be tweened.
  ///
  /// A scan pushing an update a second would otherwise flick the whole ring
  /// every time one arrived. Recognising a wedge in the next answer and moving
  /// it into place is what makes a growing chart look like one thing settling
  /// rather than a slideshow.
  void _rebuild({required bool animate}) {
    final next = _Layout.of(widget.content.segments, Theme.of(context));
    setState(() {
      _previous = animate ? _layout : _Layout.empty;
      _layout = next;
      _hovered = -1;
    });
    if (animate) {
      _controller.forward(from: 0);
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final buttons = widget.content.buttons;

    return Column(
      children: [
        if (buttons.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                for (final button in buttons)
                  _ChartButton(
                    button: button,
                    onPressed: widget.onButton == null
                        ? null
                        : () => widget.onButton!(button.id),
                  ),
              ],
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final legend = _buildLegend(context);
              if (legend == null) return _buildRing(context);

              // A panel is too narrow to put a list beside a circle, so there
              // the list goes underneath — the ring shrinks, but a legend that
              // is two words wide is no legend at all.
              if (constraints.maxWidth >= 640) {
                return Row(
                  children: [
                    Expanded(child: _buildRing(context)),
                    SizedBox(width: 260, child: legend),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: _buildRing(context)),
                  SizedBox(
                    height: math.min(200, constraints.maxHeight * 0.42),
                    child: legend,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// The list beside the ring: what this level is made of, biggest first.
  ///
  /// Built from the innermost ring rather than from anything the plugin sends
  /// separately — the two would drift apart, and a legend that disagrees with
  /// the chart beside it is worse than none.
  Widget? _buildLegend(BuildContext context) {
    final rows = [
      for (var i = 0; i < _layout.wedges.length; i++)
        if (_layout.wedges[i].ring == 0) i,
    ];
    if (rows.isEmpty) return null;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
      itemCount: rows.length,
      itemBuilder: (context, position) {
        final index = rows[position];
        final wedge = _layout.wedges[index];
        return _LegendRow(
          wedge: wedge,
          highlighted: index == _hovered,
          onEnter: () => _setHovered(index),
          onExit: () => _setHovered(-1),
          onTap: () => widget.onActivate?.call(wedge.segment),
          onSecondary: () => widget.onMark?.call(wedge.segment),
        );
      },
    );
  }

  Widget _buildRing(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 320,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 320,
        );
        final geometry = _Geometry(size, _layout.rings);

        return MouseRegion(
          onHover: (event) =>
              _setHovered(_layout.hitTest(geometry, event.localPosition)),
          onExit: (_) => _setHovered(-1),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) =>
                _press(geometry, details.localPosition, secondary: false),
            onSecondaryTapUp: (details) =>
                _press(geometry, details.localPosition, secondary: true),
            // The hold is a finger's stand-in for that right button, and a
            // finger's only — see kMenuHoldDevices. Its own detector, opaque
            // and wrapping the same child, so `localPosition` still measures
            // from the same box the taps above measure from.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              supportedDevices: kMenuHoldDevices,
              onLongPressStart: (details) =>
                  _press(geometry, details.localPosition, secondary: true),
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  size: size,
                  painter: _SunburstPainter(
                    layout: _layout,
                    previous: _previous,
                    progress: kArrivingCurve.transform(_controller.value),
                    hovered: _hovered,
                    geometry: geometry,
                    centre: _centre(),
                    theme: Theme.of(context),
                    empty: tr('Nothing to show.'),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// What the middle says: the wedge under the pointer when there is one, and
  /// otherwise what the plugin named. Hovering is how a ring chart answers
  /// "which one is that" without labelling every sliver.
  _Centre _centre() {
    if (_hovered >= 0 && _hovered < _layout.wedges.length) {
      final wedge = _layout.wedges[_hovered];
      return _Centre(wedge.label, wedge.detail);
    }
    return _Centre(widget.content.label, widget.content.detail);
  }

  void _setHovered(int index) {
    if (index == _hovered) return;
    setState(() => _hovered = index);
  }

  void _press(_Geometry geometry, Offset position, {required bool secondary}) {
    final hit = _layout.hitTest(geometry, position);

    // The middle is the way back out — and a plain press only: there is
    // nothing in there to pick out.
    if (hit == _Layout.centreHit) {
      if (!secondary) widget.onActivate?.call(-1);
      return;
    }
    if (hit < 0) return;

    final segment = _layout.wedges[hit].segment;
    if (secondary) {
      widget.onMark?.call(segment);
    } else {
      widget.onActivate?.call(segment);
    }
  }
}

class _Centre {
  const _Centre(this.label, this.detail);
  final String? label;
  final String? detail;
}

/// How much of a name a wedge can hold, and when it is not worth drawing.
///
/// Every name follows the ring — see [_SunburstPainter._paintLabel] for why —
/// and this is the part of that with a decision in it, kept where it can be
/// asked questions without rendering anything.
class SunburstLabels {
  const SunburstLabels._();

  /// A ring thinner than this has no room for text of any size.
  static const double minimumBand = 15;

  /// Taken off the arc so a name never runs into the wedge's own edges.
  static const double margin = 10;

  /// What is left of the arc for the name.
  static double roomOn({required double sweep, required double radius}) =>
      sweep * radius - margin;

  /// Whether a name is worth drawing in [room] at all.
  ///
  /// Cut hard rather than refused: a wedge that can hold three letters and an
  /// ellipsis shows them, because in a chart of a disk the first letters are
  /// usually enough to recognise a folder you already know. What is refused is
  /// the case where nothing but the ellipsis would fit — a lone `…` says less
  /// than the wedge's own size and colour already do.
  static bool worthDrawing({
    required double room,
    required double band,
    required double ellipsisWidth,
  }) =>
      band >= minimumBand && room > ellipsisWidth * 2;
}

/// One drawn wedge: where it sits and what it stands for.
class _Wedge {
  const _Wedge({
    required this.segment,
    required this.key,
    required this.start,
    required this.sweep,
    required this.ring,
    required this.color,
    required this.marked,
    required this.label,
    this.detail,
  });

  /// Index into the content's segment list — what an event reports.
  final int segment;

  /// What this wedge stands for, used to recognise it in the next answer. The
  /// URL when there is one: a folder that moved from the third ring to the
  /// first is still the same folder, and should travel rather than blink.
  final String key;

  final double start;
  final double sweep;
  final int ring;
  final Color color;
  final bool marked;
  final String label;
  final String? detail;
}

/// The wedges of one answer, laid out as angles.
class _Layout {
  const _Layout({required this.wedges, required this.rings, required this.byKey});

  static const _Layout empty = _Layout(wedges: [], rings: 0, byKey: {});

  /// Hit-test answer for the hole in the middle.
  static const int centreHit = -2;

  /// Where the first ring starts. Twelve o'clock, going clockwise, because
  /// that is where every ring chart anyone has seen starts.
  static const double origin = -math.pi / 2;

  /// Wedges thinner than this are dropped rather than drawn as hairlines that
  /// cannot be pointed at.
  static const double minimumSweep = 0.012;

  final List<_Wedge> wedges;
  final int rings;
  final Map<String, _Wedge> byKey;

  /// Turns the plugin's flat list into angles.
  ///
  /// A wedge's children divide *its* arc, and by its own value rather than by
  /// their sum — so the part of a folder that is loose files, or has not been
  /// scanned yet, stays visibly empty instead of the children stretching to
  /// fill an arc they do not fill.
  factory _Layout.of(List<ChartSegment> segments, ThemeData theme) {
    if (segments.isEmpty) return _Layout.empty;

    final children = <int, List<int>>{};
    for (var i = 0; i < segments.length; i++) {
      final parent = segments[i].parent;
      // A parent index pointing at nothing, or at itself, would either drop
      // the wedge or hang the walk. Treat it as a root.
      final safe = parent >= 0 && parent < segments.length && parent != i
          ? parent
          : -1;
      (children[safe] ??= []).add(i);
    }

    final wedges = <_Wedge>[];
    var rings = 0;

    void place(int parent, double start, double sweep, int ring, Color? parentColor) {
      final kids = children[parent] ?? const [];
      if (kids.isEmpty || ring > 5) return;

      var total = parent < 0
          ? kids.fold<double>(0, (sum, i) => sum + math.max(0, segments[i].value))
          : math.max(0, segments[parent].value);
      final used =
          kids.fold<double>(0, (sum, i) => sum + math.max(0, segments[i].value));
      if (used > total) total = used;
      if (total <= 0) return;

      var angle = start;
      for (var index = 0; index < kids.length; index++) {
        final i = kids[index];
        final segment = segments[i];
        final share = math.max(0.0, segment.value) / total * sweep;
        if (share < minimumSweep) {
          angle += share;
          continue;
        }

        final color = segment.color != null
            ? Color(segment.color!)
            : _paletteColor(theme, parentColor, ring, index);

        wedges.add(_Wedge(
          segment: i,
          key: segment.url ?? '$ring/${segment.label}/$i',
          start: angle,
          sweep: share,
          ring: ring,
          color: color,
          marked: segment.marked,
          label: segment.label,
          detail: segment.detail,
        ));
        rings = math.max(rings, ring + 1);
        place(i, angle, share, ring + 1, color);
        angle += share;
      }
    }

    place(-1, origin, 2 * math.pi, 0, null);

    return _Layout(
      wedges: wedges,
      rings: rings,
      byKey: {for (final wedge in wedges) wedge.key: wedge},
    );
  }

  /// Which wedge is under a point, [centreHit] for the hole, -1 for nothing.
  int hitTest(_Geometry geometry, Offset position) {
    final delta = position - geometry.centre;
    final distance = delta.distance;
    if (distance <= geometry.hole) return centreHit;
    if (distance > geometry.radius) return -1;

    final ring = ((distance - geometry.hole) / geometry.thickness).floor();
    var angle = math.atan2(delta.dy, delta.dx);
    // Everything is measured from twelve o'clock, so bring the answer into
    // the same turn before comparing it with a wedge's own angles.
    while (angle < origin) {
      angle += 2 * math.pi;
    }

    for (var i = 0; i < wedges.length; i++) {
      final wedge = wedges[i];
      if (wedge.ring != ring) continue;
      if (angle >= wedge.start && angle < wedge.start + wedge.sweep) return i;
    }
    return -1;
  }

  /// The colour a wedge gets when the plugin did not choose one.
  ///
  /// Top-level wedges take hues off a fixed wheel; deeper ones keep their
  /// parent's hue and step lighter, which is what makes a branch read as a
  /// branch instead of a heap of unrelated colours.
  static Color _paletteColor(
    ThemeData theme,
    Color? parent,
    int ring,
    int index,
  ) {
    final dark = theme.brightness == Brightness.dark;
    if (parent == null) {
      // By position on the innermost ring, not by how many wedges have been
      // laid out so far: the hues have to be as far apart as the wheel allows
      // for the neighbours the eye actually compares.
      const hues = [212.0, 28.0, 145.0, 348.0, 265.0, 42.0, 178.0, 318.0, 95.0];
      return HSLColor.fromAHSL(
        1,
        hues[index % hues.length],
        dark ? 0.52 : 0.58,
        dark ? 0.50 : 0.56,
      ).toColor();
    }

    final base = HSLColor.fromColor(parent);
    final lightness = (base.lightness + 0.075 * ring + (index.isOdd ? 0.035 : 0))
        .clamp(0.18, 0.86);
    return base
        .withLightness(lightness.toDouble())
        .withSaturation((base.saturation - 0.05 * ring).clamp(0.15, 1).toDouble())
        .toColor();
  }
}

/// Where the rings sit inside the widget. Shared by the painter and the hit
/// test, so the two can never disagree about what was pressed.
class _Geometry {
  const _Geometry(this.size, this.rings);

  final Size size;
  final int rings;

  Offset get centre => Offset(size.width / 2, size.height / 2);

  double get radius =>
      math.max(30, math.min(size.width, size.height) / 2 - 12);

  /// The hole in the middle, which carries the label and is the way back out.
  double get hole => radius * 0.34;

  double get thickness => (radius - hole) / math.max(1, rings);
}

class _SunburstPainter extends CustomPainter {
  const _SunburstPainter({
    required this.layout,
    required this.previous,
    required this.progress,
    required this.hovered,
    required this.geometry,
    required this.centre,
    required this.theme,
    required this.empty,
  });

  final _Layout layout;
  final _Layout previous;
  final double progress;
  final int hovered;
  final _Geometry geometry;
  final _Centre centre;
  final ThemeData theme;
  final String empty;

  @override
  void paint(Canvas canvas, Size size) {
    // Wedges that were there a moment ago and are not any more fade out where
    // they stood, so a folder that has just been deleted visibly leaves.
    if (progress < 1) {
      for (final wedge in previous.wedges) {
        if (layout.byKey.containsKey(wedge.key)) continue;
        // No name on a wedge that is leaving: it would sit on top of the name
        // of whatever is arriving in its place, and neither would be readable.
        _paintWedge(
          canvas,
          wedge,
          previous.rings,
          opacity: 1 - progress,
          named: false,
        );
      }
    }

    for (var i = 0; i < layout.wedges.length; i++) {
      final wedge = layout.wedges[i];
      final before = previous.byKey[wedge.key];
      _paintWedge(
        canvas,
        before == null ? wedge : _tween(before, wedge, progress),
        layout.rings,
        opacity: before == null ? progress : 1,
        highlighted: i == hovered,
      );
    }

    _paintCentre(canvas);
  }

  /// A wedge on its way from where it was to where it now belongs.
  _Wedge _tween(_Wedge from, _Wedge to, double t) => _Wedge(
        segment: to.segment,
        key: to.key,
        start: ui.lerpDouble(from.start, to.start, t)!,
        sweep: ui.lerpDouble(from.sweep, to.sweep, t)!,
        // Rings are whole numbers to the hit test but not to the eye: a wedge
        // that changed ring slides across the gap.
        ring: to.ring,
        color: Color.lerp(from.color, to.color, t)!,
        marked: to.marked,
        label: to.label,
        detail: to.detail,
      );

  void _paintWedge(
    Canvas canvas,
    _Wedge wedge,
    int rings, {
    double opacity = 1,
    bool highlighted = false,
    bool named = true,
  }) {
    if (opacity <= 0.01 || wedge.sweep <= 0) return;

    final thickness = (geometry.radius - geometry.hole) / math.max(1, rings);
    final inner = geometry.hole + wedge.ring * thickness;
    final outer = inner + thickness;
    if (outer > geometry.radius + 0.5) return;

    // A hairline gap between neighbours, but never one wide enough to swallow
    // a thin wedge whole.
    final gap = math.min(0.012, wedge.sweep * 0.12);
    final start = wedge.start + gap / 2;
    final sweep = wedge.sweep - gap;
    if (sweep <= 0) return;

    final path = Path()
      ..addArc(
        Rect.fromCircle(center: geometry.centre, radius: outer),
        start,
        sweep,
      )
      ..arcTo(
        Rect.fromCircle(center: geometry.centre, radius: inner),
        start + sweep,
        -sweep,
        false,
      )
      ..close();

    var color = wedge.color;
    if (highlighted) {
      color = Color.alphaBlend(Colors.white.withValues(alpha: 0.22), color);
    }
    if (wedge.marked) {
      // Far enough towards the warning colour that it cannot be mistaken for a
      // wedge that merely happens to be red — this one is on its way out.
      color = Color.lerp(
        HSLColor.fromColor(color).withSaturation(0.10).toColor(),
        theme.colorScheme.error,
        0.75,
      )!;
    }

    canvas.drawPath(
      path,
      Paint()..color = color.withValues(alpha: color.a * opacity),
    );

    if (wedge.marked || highlighted) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = wedge.marked ? 1.6 : 1.2
          ..color = (wedge.marked
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface)
              .withValues(alpha: opacity),
      );
    }

    if (named) _paintLabel(canvas, wedge, inner, outer, start, sweep, opacity);
  }

  /// The wedge's name, set **along its arc** — every letter turned to stand on
  /// the curve, the way a word is set round a seal. Always: one rule for every
  /// wedge, whatever its size.
  ///
  /// 1.0.0.99 laid a name flat where the wedge looked wide enough, and that was
  /// a mistake twice over. The room it measured was the chord across the wedge,
  /// which is only the room a *horizontal* word has when the wedge sits at the
  /// top or the bottom of the ring; at the sides, horizontal runs along the
  /// radius, where the room is the ring's thickness and nothing like as much —
  /// so long names were approved and drawn straight out over their neighbours.
  /// And with two orientations in play the same folder was set flat in one part
  /// of the ring and turned in another, which reads as the chart having no rule
  /// at all.
  ///
  /// A name too long for its arc is cut, with an ellipsis, rather than laid out
  /// somewhere it fits: in a chart of a disk the first letters are usually enough
  /// to recognise a folder, and a consistent ring is worth more than an
  /// occasional whole word.
  ///
  /// Names are drawn while the ring is moving as well as at rest. They used not
  /// to be, and that is what made them flicker: a scan pushes what it has found
  /// twice a second, each push restarts a 320 ms tween, so for two thirds of
  /// every second there were no names at all. The reason they were skipped was
  /// the cost of laying out a glyph at a time on every frame — so the widths are
  /// now remembered between frames, which removes the measuring pass entirely
  /// and leaves one layout per glyph actually drawn.
  void _paintLabel(
    Canvas canvas,
    _Wedge wedge,
    double inner,
    double outer,
    double start,
    double sweep,
    double opacity,
  ) {
    if (wedge.label.isEmpty) return;

    final band = outer - inner;
    final radius = (inner + outer) / 2;
    if (band < 15) return;

    final size = math.min(11.0, band * 0.44);
    final style = TextStyle(
      fontSize: size,
      color: _readableOn(wedge.color).withValues(alpha: opacity),
    );

    // One painter, re-laid out per letter: a chart of a hundred wedges would
    // otherwise build a thousand of them every time the pointer moves.
    final painter = TextPainter(textDirection: TextDirection.ltr);

    final middle = start + sweep / 2;
    final room = SunburstLabels.roomOn(sweep: sweep, radius: radius);
    final ellipsis = _widthOf('…', size, style, painter);
    if (!SunburstLabels.worthDrawing(
      room: room,
      band: band,
      ellipsisWidth: ellipsis,
    )) {
      painter.dispose();
      return;
    }

    final glyphs = <String>[];
    final widths = <double>[];
    var total = 0.0;

    for (final rune in wedge.label.runes) {
      final glyph = String.fromCharCode(rune);
      final width = _widthOf(glyph, size, style, painter);
      if (total + width > room) {
        // What is left does not fit, so say so rather than cutting mid-word.
        while (glyphs.isNotEmpty && total + ellipsis > room) {
          total -= widths.removeLast();
          glyphs.removeLast();
        }
        if (glyphs.isEmpty) {
          painter.dispose();
          return;
        }
        glyphs.add('…');
        widths.add(ellipsis);
        total += ellipsis;
        break;
      }
      glyphs.add(glyph);
      widths.add(width);
      total += width;
    }
    if (glyphs.isEmpty) {
      painter.dispose();
      return;
    }

    // On the lower half of the ring the same turn would write every letter
    // upside down, so the word is set the other way round the circle.
    final upright = math.atan2(math.sin(middle), math.cos(middle));
    final flipped = upright > 0 && upright < math.pi;

    var angle = flipped ? middle + total / radius / 2 : middle - total / radius / 2;

    for (var i = 0; i < glyphs.length; i++) {
      final step = widths[i] / radius;
      final at = flipped ? angle - step / 2 : angle + step / 2;

      painter
        ..text = TextSpan(text: glyphs[i], style: style)
        ..layout();

      canvas.save();
      canvas.translate(
        geometry.centre.dx + math.cos(at) * radius,
        geometry.centre.dy + math.sin(at) * radius,
      );
      canvas.rotate(flipped ? at - math.pi / 2 : at + math.pi / 2);
      painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
      canvas.restore();

      angle += flipped ? -step : step;
    }
    painter.dispose();
  }

  /// How wide one glyph is at this size, remembered between frames.
  ///
  /// Widths do not depend on the colour, and the colour is the only thing about
  /// a label that changes from frame to frame during a tween — so measuring is
  /// work that can be done once for the whole session. This is what pays for
  /// drawing names while the ring is moving: the measuring pass costs nothing
  /// after the first frame, and only the glyphs actually drawn are laid out.
  static double _widthOf(
    String glyph,
    double size,
    TextStyle style,
    TextPainter painter,
  ) {
    final key = '$size $glyph';
    final known = _glyphWidths[key];
    if (known != null) return known;

    painter
      ..text = TextSpan(text: glyph, style: style)
      ..layout();
    // Bounded: distinct glyphs times distinct sizes is small, but a font full of
    // CJK and a user dragging the font size would otherwise grow it for ever.
    if (_glyphWidths.length > 4096) _glyphWidths.clear();
    return _glyphWidths[key] = painter.width;
  }

  static final Map<String, double> _glyphWidths = {};

  /// Black or white, whichever can be read on a wedge of this colour.
  static Color _readableOn(Color background) =>
      background.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;



  void _paintCentre(Canvas canvas) {
    canvas.drawCircle(
      geometry.centre,
      geometry.hole,
      Paint()..color = theme.colorScheme.surface.withValues(alpha: 0.92),
    );
    canvas.drawCircle(
      geometry.centre,
      geometry.hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = theme.colorScheme.onSurface.withValues(alpha: 0.18),
    );

    final label = centre.label ?? (layout.wedges.isEmpty ? empty : null);
    final lines = <TextPainter>[
      if (label != null && label.isNotEmpty)
        _line(label, bold: true, size: 13),
      if (centre.detail != null && centre.detail!.isNotEmpty)
        _line(centre.detail!, bold: false, size: 11),
    ];
    if (lines.isEmpty) return;

    final width = geometry.hole * 1.7;
    for (final line in lines) {
      line.layout(maxWidth: width);
    }
    final height = lines.fold<double>(0, (sum, l) => sum + l.height + 2);

    var y = geometry.centre.dy - height / 2;
    for (final line in lines) {
      line.paint(canvas, Offset(geometry.centre.dx - line.width / 2, y));
      y += line.height + 2;
      line.dispose();
    }
  }

  TextPainter _line(String text, {required bool bold, required double size}) =>
      TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: size,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
            color: theme.colorScheme.onSurface
                .withValues(alpha: bold ? 1 : 0.7),
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 2,
        ellipsis: '…',
      );

  @override
  bool shouldRepaint(_SunburstPainter old) =>
      old.layout != layout ||
      old.previous != previous ||
      old.progress != progress ||
      old.hovered != hovered ||
      old.centre != centre ||
      old.geometry.size != geometry.size;
}

/// One line of the legend: the wedge's colour, its name and what it is worth.
class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.wedge,
    required this.highlighted,
    required this.onEnter,
    required this.onExit,
    required this.onTap,
    required this.onSecondary,
  });

  final _Wedge wedge;
  final bool highlighted;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final VoidCallback onTap;
  final VoidCallback onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final marked = wedge.marked;

    return MouseRegion(
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onSecondaryTap: onSecondary,
        // The hold belongs to the devices with no second button — see
        // kMenuHoldDevices. On its own detector, because the two above must go
        // on answering the mouse.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          supportedDevices: kMenuHoldDevices,
          onLongPress: onSecondary,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: highlighted
                  ? theme.colorScheme.onSurface.withValues(alpha: 0.07)
                  : null,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: wedge.color,
                    borderRadius: BorderRadius.circular(3),
                    border: marked
                        ? Border.all(color: theme.colorScheme.error, width: 1.5)
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    wedge.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: marked
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface,
                      decoration: marked ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
                if (wedge.detail != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    wedge.detail!,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.65,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartButton extends StatelessWidget {
  const _ChartButton({required this.button, this.onPressed});

  final ContentButton button;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (!button.danger) {
      return OutlinedButton(onPressed: onPressed, child: Text(button.label));
    }
    final colors = Theme.of(context).colorScheme;
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: colors.error,
        foregroundColor: colors.onError,
      ),
      onPressed: onPressed,
      child: Text(button.label),
    );
  }
}
