// **A hairline figure, carried in rather than depended on.**
//
// The drawing is a port of Hairline's (MIT, Lucas Marques,
// https://github.com/lucasmarkes/hairline) made for x-isoline, which is a
// private repository of his: a public program cannot depend on one, so the
// two files the figure needs live here instead, as x-isoline's README says a
// figure may be used — copied, self-contained, Flutter and nothing else.
//
// MIT licence, Copyright (c) 2026 Lucas Marques. The permission notice
// travels with the code: see `docs/third-party.md`.
//
// Keep it as it is. A change here is a change to somebody else's drawing, and
// the next version of the figure would be a merge rather than a copy.

// The x-isoline kernel, after the Hairline kernel (github.com/lucasmarkes/hairline, MIT):
// camera, springs, rounded solids, the frame loop, and the figure shell. Figures live in
// their own files and only draw.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// The five tones every figure is drawn in (kernel.js LIGHT / DARK).
class HairlinePalette {
  const HairlinePalette({
    required this.plate,
    required this.hi,
    required this.edge,
    required this.mid,
    required this.lo,
    this.stroke = 0.9,
  });

  /// Plates are filled, not transparent: this must match the background.
  final Color plate, hi, edge, mid, lo;

  /// The line weight in CSS pixels. Light strokes on a dark ground look thinner, so dark is heavier.
  final double stroke;

  static const light = HairlinePalette(
    plate: Color(0xFFFFFFFF),
    hi: Color(0xFF1B1B1F),
    edge: Color(0xFF8C8C96),
    mid: Color(0xFFAAAAB3),
    lo: Color(0xFFC6C6CE),
    stroke: 0.95,
  );
  static const dark = HairlinePalette(
    plate: Color(0xFF08090A),
    hi: Color(0xFFF2F4F8),
    edge: Color(0xFF9A9DA8),
    mid: Color(0xFF7C7F8A),
    lo: Color(0xFF5E616B),
    stroke: 1.2,
  );
}

// ---------------------------------------------------------------- kernel ----

/// Isometric camera: azimuth, tilt k, scale S. z is up; paint by ascending x + y.
class HlCam {
  HlCam(double azDeg, this.k, this.s)
    : c = math.cos(azDeg * math.pi / 180),
      sn = math.sin(azDeg * math.pi / 180),
      zf = math.sqrt(1 - k * k);

  final double k, s, c, sn, zf;
  double ox = 0, oy = 0;

  Offset call(double x, double y, double z) =>
      Offset(ox + s * (x * c - y * sn), oy + s * ((x * sn + y * c) * k - z * zf));

  /// The ground point (z = 0) under a screen point.
  Offset unproj(Offset p) {
    final bx = (p.dx - ox) / s, by = (p.dy - oy) / s / k;
    return Offset(bx * c + by * sn, -bx * sn + by * c);
  }

  /// The world (x, y) of the point on the horizontal plane at height [z] that projects to [p].
  Offset unprojAt(Offset p, double z) => unproj(Offset(p.dx, p.dy + s * z * zf));

  /// Centres the bounding box of [pts] on (cx, cy). Never scales.
  void fit(List<List<double>> pts, double cx, double cy) {
    ox = oy = 0;
    final q = [for (final p in pts) this(p[0], p[1], p[2])];
    final minX = q.map((e) => e.dx).reduce(math.min);
    final maxX = q.map((e) => e.dx).reduce(math.max);
    final minY = q.map((e) => e.dy).reduce(math.min);
    final maxY = q.map((e) => e.dy).reduce(math.max);
    ox = cx - (minX + maxX) / 2;
    oy = cy - (minY + maxY) / 2;
  }

  /// Whether a ground normal faces the viewer.
  bool faces(double nx, double ny) => nx * sn + ny * c > 0;
}

/// The kernel's default spring: stiffness and damping.
const hlSpringK = 100.0, hlSpringC = 18.0;

class HlSpring {
  HlSpring(this.x, {this.eps = 0.01, this.k = hlSpringK, this.c = hlSpringC}) : t = x;
  double x, v = 0, t;
  final double eps;

  /// Stiffness and damping. The default (100, 18) is the kernel's; softer, under-damped
  /// values (60, 6) make a body wobble and settle, as the basket does.
  final double k, c;

  /// Advances by dt seconds in 240 Hz sub-steps; true while still moving.
  bool step(double dt) {
    if ((x - t).abs() < eps && v.abs() < eps) {
      x = t;
      v = 0;
      return false;
    }
    var left = dt;
    while (left > 0) {
      final h = math.min(left, 1 / 240);
      v += (-k * (x - t) - c * v) * h;
      x += v * h;
      left -= h;
    }
    if ((x - t).abs() < eps && v.abs() < eps) {
      x = t;
      v = 0;
      return false;
    }
    return true;
  }
}

/// A rounded rectangle as samples with outward normals, clockwise from the top left.
class HlRing {
  HlRing(double x0, double y0, double x1, double y1, double r, int steps) {
    final corners = [
      (x1 - r, y0 + r, -90.0),
      (x1 - r, y1 - r, 0.0),
      (x0 + r, y1 - r, 90.0),
      (x0 + r, y0 + r, 180.0),
    ];
    for (final (cx, cy, a0) in corners) {
      for (var i = 0; i <= steps; i++) {
        final a = (a0 + 90 * i / steps) * math.pi / 180;
        final nx = math.cos(a), ny = math.sin(a);
        pts.add([cx + r * nx, cy + r * ny, nx, ny]);
      }
    }
  }
  final List<List<double>> pts = [];
}

List<Offset> hlHull(List<Offset> p) {
  final a = [...p]..sort((u, v) => u.dx != v.dx ? u.dx.compareTo(v.dx) : u.dy.compareTo(v.dy));
  double cross(Offset o, Offset u, Offset v) =>
      (u.dx - o.dx) * (v.dy - o.dy) - (u.dy - o.dy) * (v.dx - o.dx);
  final lo = <Offset>[], up = <Offset>[];
  for (final q in a) {
    while (lo.length >= 2 && cross(lo[lo.length - 2], lo.last, q) <= 0) {
      lo.removeLast();
    }
    lo.add(q);
  }
  for (final q in a.reversed) {
    while (up.length >= 2 && cross(up[up.length - 2], up.last, q) <= 0) {
      up.removeLast();
    }
    up.add(q);
  }
  return [...lo..removeLast(), ...up..removeLast()];
}

/// A box of two rounded rings: a hull silhouette plus one dim crease on the lid.
class HlSolid {
  HlSolid(this.sil, this.crease);
  final Path sil;
  final Path crease;
}

HlSolid hlPrism(HlCam cam, HlRing outer, HlRing inner, double z0, double z1) {
  final pts = [
    for (final p in outer.pts) cam(p[0], p[1], z1),
    for (final p in outer.pts) cam(p[0], p[1], z0),
  ];
  final sil = Path()..addPolygon(hlHull(pts), true);
  // The one cyclic run of inner samples that face the viewer.
  final n = inner.pts.length;
  final on = [for (final p in inner.pts) cam.faces(p[2], p[3])];
  var start = on.indexWhere((e) => e);
  final crease = Path();
  if (start >= 0) {
    while (on[(start - 1 + n) % n]) {
      start = (start - 1 + n) % n;
      if (on.every((e) => e)) break;
    }
    var first = true;
    for (var i = 0; i < n && on[(start + i) % n]; i++) {
      final p = inner.pts[(start + i) % n];
      final o = cam(p[0], p[1], z1);
      first ? crease.moveTo(o.dx, o.dy) : crease.lineTo(o.dx, o.dy);
      first = false;
    }
  }
  return HlSolid(sil, crease);
}


/// The frame loop of one figure: a Ticker that sleeps when nothing moves.
class HlLoop {
  HlLoop(TickerProvider vsync, this.step) {
    _ticker = vsync.createTicker(_tick);
  }

  /// Advances the figure by dt seconds; returns true while something still moves.
  final bool Function(double dt, bool snap) step;
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  /// prefers-reduced-motion: springs jump to their targets.
  bool reduceMotion = false;

  void _tick(Duration t) {
    final dt = math.min((t - _last).inMicroseconds / 1e6, 0.05);
    _last = t;
    if (!step(dt, reduceMotion)) _ticker.stop();
  }

  void wake() {
    if (_ticker.isActive) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void dispose() => _ticker.dispose();
}

/// Maps a point in a widget of [size] to the 400 × 320 viewBox the figure is drawn in.
Offset hlViewBoxPoint(Offset local, Size size) {
  final sc = hlScale(size);
  return Offset(
    (local.dx - (size.width - hlVbW * sc) / 2) / sc,
    (local.dy - (size.height - hlVbH * sc) / 2) / sc,
  );
}

const hlVbW = 400.0, hlVbH = 320.0;
double hlScale(Size size) => math.min(size.width / hlVbW, size.height / hlVbH);

// -------------------------------------------------------------- helpers ----

/// A closed polygon path from projected points.
Path hlPoly(Iterable<Offset> pts) => Path()..addPolygon(pts.toList(), true);

/// An open polyline path (empty for fewer than two points).
Path hlOpen(Iterable<Offset> pts) {
  final l = pts.toList();
  return l.length < 2 ? Path() : (Path()..addPolygon(l, false));
}

/// Rounds the corners of a closed polygon: one quadratic arc of [n] steps per vertex, [radii]
/// per vertex (clamped to half of each adjacent edge).
List<Offset> hlFillet(List<Offset> pts, List<double> radii, [int n = 4]) {
  final m = pts.length, out = <Offset>[];
  for (var i = 0; i < m; i++) {
    final a = pts[(i + m - 1) % m], p = pts[i], b = pts[(i + 1) % m];
    final la = (a - p).distance, lb = (b - p).distance;
    final t = math.min(radii[i], math.min(la / 2, lb / 2));
    final p1 = p + (a - p) / la * t, p2 = p + (b - p) / lb * t;
    for (var k = 0; k <= n; k++) {
      final s = k / n, w = 1 - s;
      out.add(p1 * (w * w) + p * (2 * w * s) + p2 * (s * s));
    }
  }
  return out;
}

double hlLerp(double a, double b, double t) => a + (b - a) * t;

/// Smoothstep: 0 → 1 with zero slope at both ends.
double hlSmooth(double t) => t * t * (3 - 2 * t);

/// A value that eases toward a target in about 90 ms: a stroke changing between bright and dim.
class HlGlow {
  HlGlow([double v = 0]) : x = v, t = v;
  double x, t;

  /// True while still moving. [snap] jumps (reduced motion).
  bool step(double dt, bool snap) {
    final d = t - x;
    if (d == 0) return false;
    x = snap || d.abs() < 0.001 ? t : x + d * math.min(1, dt / 0.09);
    return x != t;
  }
}

// ------------------------------------------------------------ figure shell ----
// Everything a figure shares: the ticker, the viewBox scaling, the pointer, the
// read-out and the palette. A figure is a model (state + drawing) and nothing else.

enum HlPhase { hover, down, move, up, leave }

/// A tween on the figure clock: 700 ms ease-out by default (kernel.js EASE_LIFT).
class HlTween {
  HlTween(double v, {this.dur = 0.7}) : from = v, to = v;
  double from, to, start = -1e9;
  final double dur;
  static const _ease = Cubic(0.32, 0.72, 0, 1);

  double at(double now) {
    final t = ((now - start) / dur).clamp(0.0, 1.0);
    return from + (to - from) * _ease.transform(t);
  }

  bool moving(double now) => now - start < dur;

  /// Starts toward [v] from wherever it is now.
  void go(double now, double v) {
    if (v == to) return;
    from = at(now);
    to = v;
    start = now;
  }

  /// Jumps (prefers-reduced-motion, first frame).
  void jump(double v) {
    from = to = v;
    start = -1e9;
  }
}

/// Drawing context handed to [HlFigureModel.paint]: viewBox units, plates that cut.
class HlPaint {
  HlPaint(this.canvas, this.pal, this.width);
  final Canvas canvas;
  final HairlinePalette pal;

  /// The stroke in viewBox units, so it is [strokeWidth] CSS pixels at any size.
  final double width;

  final Paint cut = Paint()..blendMode = BlendMode.clear;

  Paint line(Color c) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round
    ..color = c;

  /// A plate: cut out of what is behind it, then outlined with [edge], then its crease.
  void solid(HlSolid s, [Color? edge, Color? crease]) {
    canvas.drawPath(s.sil, cut);
    canvas.drawPath(s.sil, line(edge ?? pal.edge));
    canvas.drawPath(s.crease, line(crease ?? pal.mid));
  }

  /// An outline plate from any closed path.
  void plate(Path p, [Color? edge]) {
    canvas.drawPath(p, cut);
    canvas.drawPath(p, line(edge ?? pal.edge));
  }

  /// Strokes [path] dashed: [on] drawn, [off] gap, in stroke widths (default 1 on, 3 off).
  void dashed(Path path, Color color, {double on = 1, double off = 3}) {
    final paint = line(color), a = on * width / 0.9, b = (on + off) * width / 0.9;
    for (final m in path.computeMetrics()) {
      for (var t = 0.0; t < m.length; t += b) {
        canvas.drawPath(m.extractPath(t, math.min(t + a, m.length)), paint);
      }
    }
  }

  void dot(Offset c, double r, Color color) => canvas.drawCircle(c, r, Paint()..color = color);
}

abstract class HlFigureModel extends ChangeNotifier {
  /// Seconds since the figure mounted; advanced by the view before [step].
  double now = 0;

  /// The corner read-out. Keep it short; no text inside the drawing.
  final read = ValueNotifier('');

  /// Set by the view: call after any input so the loop wakes.
  late VoidCallback wake;

  /// Asks the painter to redraw.
  void repaint() => notifyListeners();

  /// Advance by [dt] seconds. [snap] (reduced motion) means jump to targets.
  /// Return true while anything still moves; false lets the loop sleep.
  bool step(double dt, bool snap);

  /// Draw in the 400 × 320 viewBox, back to front.
  void paint(HlPaint p);

  /// The pointer, already in viewBox coordinates.
  void pointer(HlPhase phase, Offset vb, {bool touch = false});

  @override
  void dispose() {
    read.dispose();
    super.dispose();
  }
}

class _FigurePainter extends CustomPainter {
  _FigurePainter(this.m, this.pal, this.stroke) : super(repaint: m);
  final HlFigureModel m;
  final HairlinePalette pal;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    // Plates are cut out of the layer, so the backdrop blur shows through them.
    canvas.saveLayer(Offset.zero & size, Paint());
    final sc = hlScale(size);
    canvas.translate((size.width - hlVbW * sc) / 2, (size.height - hlVbH * sc) / 2);
    canvas.scale(sc);
    m.paint(HlPaint(canvas, pal, stroke / sc));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FigurePainter old) => old.pal != pal || old.stroke != stroke;
}

/// Hosts a figure model: ticker, pointer, read-out, palette. [create] runs once.
class HlFigureView extends StatefulWidget {
  const HlFigureView({super.key, required this.create, this.sync, this.label = 'Figure', this.palette, this.stroke});
  final HlFigureModel Function() create;

  /// Parametric figures: called with the live model whenever the widget is rebuilt with new
  /// parameters. Retarget springs here (never rebuild the model), then the loop wakes.
  final void Function(HlFigureModel model)? sync;
  final String label;
  final HairlinePalette? palette;

  /// Overrides the palette's line weight.
  final double? stroke;

  @override
  State<HlFigureView> createState() => _HlFigureViewState();
}

class _HlFigureViewState extends State<HlFigureView> with SingleTickerProviderStateMixin {
  late final HlFigureModel _m = widget.create();
  late final HlLoop _loop = HlLoop(this, (dt, snap) {
    _m.now += dt;
    final moving = _m.step(dt, snap);
    _m.repaint();
    return moving;
  });
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _m.wake = _loop.wake;
    _m.step(0, true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop.reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(HlFigureView old) {
    super.didUpdateWidget(old);
    widget.sync?.call(_m);
    _loop.wake();
  }

  @override
  void dispose() {
    _loop.dispose();
    _m.dispose();
    super.dispose();
  }

  void _send(HlPhase phase, PointerEvent e) {
    _m.pointer(phase, hlViewBoxPoint(e.localPosition, _size), touch: e.kind != PointerDeviceKind.mouse);
    _loop.wake();
  }

  @override
  Widget build(BuildContext context) {
    final pal = widget.palette ?? (Theme.of(context).brightness == Brightness.dark ? HairlinePalette.dark : HairlinePalette.light);
    return Semantics(
      label: widget.label,
      child: AspectRatio(
        aspectRatio: hlVbW / hlVbH,
        child: LayoutBuilder(
          builder: (context, box) {
            _size = box.biggest;
            return MouseRegion(
              onHover: (e) => _send(HlPhase.hover, e),
              onExit: (e) => _send(HlPhase.leave, e),
              child: Listener(
                onPointerDown: (e) => _send(HlPhase.down, e),
                onPointerMove: (e) => _send(HlPhase.move, e),
                onPointerUp: (e) => _send(HlPhase.up, e),
                onPointerCancel: (e) => _send(HlPhase.leave, e),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(painter: _FigurePainter(_m, pal, widget.stroke ?? pal.stroke)),
                    Positioned(
                      left: 10,
                      bottom: 8,
                      child: ValueListenableBuilder(
                        valueListenable: _m.read,
                        builder: (_, s, _) => Text(
                          s,
                          style: TextStyle(fontSize: 11, color: pal.edge, decoration: TextDecoration.none),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
