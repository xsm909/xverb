import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/plugins/viewer.dart';
import '../../core/settings/appearance_settings.dart';

/// The braid down the side of a history, drawn one row at a time.
///
/// One painter per row rather than one for the whole log, because a log is a
/// listing and a listing is built as it is scrolled: a painter that had to see
/// every commit would have to be handed every commit, and a repository has
/// more of those than a window has rows.
///
/// Everything here is geometry the plugin could not have known — how wide a
/// lane is at this font size, where the middle of a row falls, how a line
/// bends from one lane to the next — and the plugin sent only what it alone
/// knew: which lane, and what joins what. See [ListingGraph].
class CommitGraph extends StatelessWidget {
  const CommitGraph({
    super.key,
    required this.graph,
    required this.theme,
    required this.onCursor,
    this.lanes = 1,
  });

  final ListingGraph graph;
  final AppearanceSettings theme;

  /// How many lanes the whole column has to hold — the widest row's, not this
  /// row's. One scale for the table or the lines of a row would not line up
  /// with the lines of the one above it.
  final int lanes;

  /// True when the cursor is on this row. The braid is drawn over the cursor's
  /// own fill there, so it lightens rather than keeping colours that were
  /// chosen to sit on the panel.
  final bool onCursor;

  /// A lane at ease: wide enough for a mark with air around it. Scales with
  /// the font, like everything else that has to line up with text.
  static const double _roomy = 12;

  /// The narrowest a lane is allowed to get. Below this the marks stop being
  /// marks and the braid becomes hatching.
  static const double _tight = 5;

  /// How many lanes fit before the column has to start squeezing.
  static const int atEase = 10;

  /// How wide one lane is, in a column holding [lanes] of them.
  ///
  /// The column has a width, not the lane: a busy repository with every branch
  /// shown can stand twenty lines abreast, and the answer to that is thinner
  /// lanes, not a wider column — the subject of the commit is what a log is
  /// read for and it is not giving up half the row. Squeezed to [_tight] and
  /// no further; past that the column is full and says so by clipping.
  static double laneWidth(AppearanceSettings theme, [int lanes = 1]) {
    if (lanes <= atEase) return theme.scaled(_roomy);
    final squeezed = theme.scaled(_roomy * atEase) / lanes;
    final tight = theme.scaled(_tight);
    return squeezed < tight ? tight : squeezed;
  }

  /// The most lanes a column will ever show. Past this it stops being a
  /// picture and starts being a wall.
  static const int mostLanes = (_roomy * atEase) ~/ _tight;

  /// What a column of [lanes] lanes needs, with room for the mark's own edge.
  static double widthFor(AppearanceSettings theme, int lanes) {
    final held = lanes.clamp(1, mostLanes);
    return laneWidth(theme, held) * held + theme.scaled(4);
  }

  @override
  Widget build(BuildContext context) => ClipRect(
        // A history wider than the column is capped rather than allowed to
        // paint over the commit beside it. The cap is deliberate — see
        // `PluginTable` — and a picture that ran into the next column would
        // make it look like a fault rather than a limit.
        child: CustomPaint(
          painter: _GraphPainter(
            graph: graph,
            lane: laneWidth(theme, lanes),
            colours: GraphColours.of(theme, onCursor: onCursor),
          ),
          size: Size.infinite,
        ),
      );
}

/// The colours a braid is drawn in.
///
/// Derived, never declared. A plugin does not send a colour for a lane and
/// there is no setting for one: the hues are a fixed wheel — the same wheel the
/// ring chart takes its top-level colours off, and for the same reason, that
/// neighbouring lanes have to be as far apart as the wheel allows — and how
/// light they are is decided by the panel they are being drawn on.
class GraphColours {
  const GraphColours({required this.lanes, required this.mark});

  factory GraphColours.of(AppearanceSettings theme, {bool onCursor = false}) {
    final dark = ThemeData.estimateBrightnessForColor(
          onCursor ? theme.cursorColor : theme.panelBackground,
        ) ==
        Brightness.dark;

    return GraphColours(
      lanes: [
        for (final hue in _hues)
          HSLColor.fromAHSL(1, hue, dark ? 0.62 : 0.68, dark ? 0.66 : 0.42)
              .toColor(),
      ],
      // The mark on the commit itself, in the panel's own ink rather than in
      // its lane's colour: it is the row you are reading, not another line.
      mark: onCursor ? theme.cursorForeground : theme.panelForeground,
    );
  }

  /// Nine hues, evenly hostile to each other. Beyond nine lines at once they
  /// repeat, which is what every tool that draws this does — a history wide
  /// enough to run out of colours is one nobody is reading line by line.
  static const List<double> _hues = [
    212.0, 28.0, 145.0, 348.0, 265.0, 42.0, 178.0, 318.0, 95.0,
  ];

  final List<Color> lanes;
  final Color mark;

  /// The colour of a line, by the key the plugin gave it — not by its lane.
  /// A line that shifts sideways as branches end keeps its key, and so keeps
  /// its colour all the way down.
  Color of(int tint) => lanes[tint.abs() % lanes.length];
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.graph,
    required this.lane,
    required this.colours,
  });

  final ListingGraph graph;
  final double lane;
  final GraphColours colours;

  /// How thick a line is. Thin enough that eight of them in a row are still
  /// eight, heavy enough to read against a striped listing. Thinner in a
  /// squeezed column, where 1.6 of a five-wide lane is a third of the lane.
  double get _stroke => (lane * 0.14).clamp(0.9, 1.6);

  @override
  void paint(Canvas canvas, Size size) {
    final middle = size.height / 2;
    final radius = lane * 0.28;

    // One line, in the colour of the line it *is* — and where a bend joins two
    // different lines, in both, handed over along the bend. A merge is where
    // one line becomes another, and a colour that changed at a corner would
    // put the change in the wrong place: it happens over the whole bend.
    void draw(Path path, Offset from, Offset to, int fromTint, int toTint) {
      final pen = Paint()
        ..strokeWidth = _stroke
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true;
      final start = colours.of(fromTint);
      final end = colours.of(toTint);
      if (start == end) {
        pen.color = start;
      } else {
        pen.shader = ui.Gradient.linear(from, to, [start, end]);
      }
      canvas.drawPath(path, pen);
    }

    // Lines that only cross. Drawn first, so anything that ends at the mark
    // lands on top of them rather than under.
    for (final edge in graph.through) {
      final from = Offset(_x(edge.$1), 0);
      final to = Offset(_x(edge.$2), size.height);
      draw(
        _bend(from.dx, from.dy, to.dx, to.dy),
        from,
        to,
        graph.tintAbove(edge.$1),
        graph.tintBelow(edge.$2),
      );
    }

    if (graph.lane < 0) return;
    final x = _x(graph.lane);
    final own = graph.ownTint;

    // Arriving: the commit's own lane from above, and any branch merging in.
    for (final from in graph.closes) {
      final head = Offset(_x(from), 0);
      final mark = Offset(x, middle);
      draw(
        _bend(head.dx, head.dy, mark.dx, mark.dy),
        head,
        mark,
        graph.tintAbove(from),
        own,
      );
    }

    // Leaving: one line per parent. The first goes straight down its own lane;
    // the others peel off to wherever their lane is.
    for (final to in graph.parents) {
      final mark = Offset(x, middle);
      final foot = Offset(_x(to), size.height);
      draw(
        _bend(mark.dx, mark.dy, foot.dx, foot.dy),
        mark,
        foot,
        own,
        graph.tintBelow(to),
      );
    }

    final ink = Paint()
      ..color = colours.of(own)
      ..isAntiAlias = true;

    if (graph.merge) {
      // A ring. A merge is the commit people go looking for in a log, and it
      // is the one thing the braid can say about a commit without words.
      canvas.drawCircle(Offset(x, middle), radius, ink..style = PaintingStyle.fill);
      canvas.drawCircle(
        Offset(x, middle),
        radius * 0.45,
        Paint()
          ..color = colours.mark
          ..isAntiAlias = true,
      );
    } else {
      canvas.drawCircle(
        Offset(x, middle),
        radius,
        ink..style = PaintingStyle.fill,
      );
    }
  }

  double _x(int at) => lane * (at + 0.5);

  /// One line from a lane to a lane.
  ///
  /// A curve rather than the elbow `git log --graph` draws in characters,
  /// because the elbow is a limitation of drawing with `|` and `\` and this is
  /// not drawing with characters. The control points sit at the halfway line,
  /// which is what makes a line leave one lane vertically and arrive at the
  /// next vertically — so two lanes side by side never look like a crossing.
  Path _bend(double fromX, double fromY, double toX, double toY) {
    final path = Path()..moveTo(fromX, fromY);
    if ((fromX - toX).abs() < 0.01) {
      path.lineTo(toX, toY);
      return path;
    }
    final middle = (fromY + toY) / 2;
    path.cubicTo(fromX, middle, toX, middle, toX, toY);
    return path;
  }

  @override
  bool shouldRepaint(_GraphPainter old) =>
      old.graph != graph || old.lane != lane || old.colours.mark != colours.mark;
}
