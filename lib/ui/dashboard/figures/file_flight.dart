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

// Copying files, seen almost head-on: two manila pocket folders hang in the air, side by side.
// An A4 sheet slips out of the left one, flutters over, and drops into the right one, while
// the original stays. The folders rock on soft springs when a sheet leaves or lands, and lean
// toward the pointer. Parametric: `progress` (0 – 1) and `files` drive it, or leave
// `progress` null for an endless loop. Hover a folder to read its name and count.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'hairline_kernel.dart';

class HlFileFlight extends StatelessWidget {
  const HlFileFlight({
    super.key,
    this.progress,
    this.files = 8,
    this.from = 'source',
    this.to = 'destination',
    this.palette,
    this.stroke,
  });

  /// 0 – 1 of the whole copy, or null to loop forever. Out-of-range values are clamped.
  final double? progress;

  /// How many files are copied. Any count is fine: the sheets in the air stay few.
  final int files;

  /// Folder names for the read-out.
  final String from, to;

  final HairlinePalette? palette;
  final double? stroke;

  @override
  Widget build(BuildContext context) => HlFigureView(
    label: 'Copying $files files from $from to $to',
    palette: palette,
    stroke: stroke,
    create: () => _Flight(this),
    sync: (m) => (m as _Flight).sync(this),
  );
}

// A pocket folder, as in a 3D icon: a tall front panel with a notch at the top left, rounded
// everywhere, leaning open; the back panel shows above it and a rounded fold shows at the right.
// A4 sheets sit between the panels. Units are viewBox-ish.
const _w = 46.0, _hf = 34.0, _backRise = 4.0, _notchW = 15.0, _notchD = 7.0, _lean = 7.0;
const _yBack = -9.0, _yHinge = 6.0, _ySheet = -2.0;
const _gap = 100.0; // centre to centre
const _sheetW = 20.0, _sheetH = 28.3, _seat = 22.0; // A4 is 1 : 1.414; _seat is the centre height when seated
const _arc = 40.0, _span = 1.6;

/// A soft spring: under-damped, so a kick makes the folder rock and settle (the basket's wobble).
class _Rock {
  double x = 0, v = 0, t = 0;
  static const k = 70.0, c = 5.5;

  bool step(double dt) {
    if (x.abs() < 0.0006 && v.abs() < 0.004 && t.abs() < 0.0006) {
      x = v = 0;
      return false;
    }
    var left = dt;
    while (left > 0) {
      final h = math.min(left, 1 / 240);
      v += (-k * (x - t) - c * v) * h;
      x += v * h;
      left -= h;
    }
    return true;
  }

  void kick(double impulse) => v = (v + impulse).clamp(-1.2, 1.2);
}

class _Flight extends HlFigureModel {
  _Flight(this.w) {
    cam = HlCam(13, 0.5, 2.3)
      ..fit([
        [-_w / 2 - 6, _yBack, 0],
        [_gap + _w / 2 + 6, _yBack, 0],
        [-_w / 2 - 6, _yHinge + _lean, 0],
        [_gap + _w / 2 + 6, _yHinge + _lean, 0],
        [0, _yBack, _seat + _arc + _sheetH / 2 + 4],
      ], 200, 166);
    pos = _target;
    _dep = _departed;
    _arr = arrived;
  }

  HlFileFlight w;
  late final HlCam cam;
  double pos = 0;
  int? over;
  var _readKey = '';
  final rock = [_Rock(), _Rock()];
  late int _dep, _arr;

  int get n => math.max(1, w.files);

  /// Where the copy stands, in files: file k is in the air while 0 < pos - k < span.
  double get _target => w.progress == null ? pos : (w.progress!.isFinite ? w.progress!.clamp(0.0, 1.0) : 0.0) * (n + _span - 1);

  void sync(HlFileFlight next) {
    w = next;
    wake();
  }

  int get arrived => pos < _span ? 0 : math.min(n, (pos - _span).floor() + 1);
  int get _departed => math.min(n, math.max(0, pos.ceil()));

  /// A point of folder [i] (centre x = i * gap), rolled about its base by the folder's rock.
  Offset _f(int i, double x, double y, double z) {
    final cx = i * _gap, a = rock[i].x, ca = math.cos(a), sa = math.sin(a), dx = x - cx;
    return cam(cx + dx * ca - z * sa, y, dx * sa + z * ca);
  }

  Offset _p(double x, double y, double z) => cam(x, y, z);

  Path _poly(Iterable<Offset> pts) => Path()..addPolygon(pts.toList(), true);

  @override
  bool step(double dt, bool snap) {
    var moving = false;
    if (w.progress == null) {
      // Indeterminate: loop, with a beat of rest after the last file lands.
      pos = snap ? 0 : (pos + dt * 1.8) % (n + _span + 1);
      moving = !snap;
    } else {
      final t = _target;
      if (snap || (t - pos).abs() < 0.002) {
        moving = pos != t && !snap;
        pos = t;
      } else {
        pos += (t - pos) * (1 - math.exp(-6 * dt));
        moving = true;
      }
    }
    // A sheet leaving or landing nudges its folder; many in a row would pile up, so clamp.
    final dep = _departed, arr = arrived;
    if (!snap) {
      if (dep > _dep) rock[0].kick(-0.55);
      if (arr > _arr) rock[1].kick(0.55);
    }
    _dep = dep;
    _arr = arr;
    for (var i = 0; i < 2; i++) {
      final r = rock[i];
      if (snap) {
        r.x = r.t;
        r.v = 0;
      } else if (r.step(dt) || (dt == 0 && (r.x - r.t).abs() > 0.0006)) {
        moving = true;
      }
    }
    _readout();
    return moving;
  }

  void _readout() {
    final o = over;
    final s = o == null ? '$arrived / $n' : (o == 0 ? '${w.from} · $n files' : '${w.to} · $arrived files');
    if (s != _readKey) {
      _readKey = s;
      read.value = s;
    }
  }

  Rect _bounds(int i) {
    final cx = i * _gap;
    final pts = [
      for (final x in [cx - _w / 2, cx + _w / 2])
        for (final y in [_yBack, _yHinge + _lean])
          for (final z in [0.0, _hf + _backRise]) _p(x, y, z),
    ];
    return Rect.fromPoints(
      Offset(pts.map((e) => e.dx).reduce(math.min), pts.map((e) => e.dy).reduce(math.min)),
      Offset(pts.map((e) => e.dx).reduce(math.max), pts.map((e) => e.dy).reduce(math.max)),
    ).inflate(4);
  }

  @override
  void pointer(HlPhase phase, Offset vb, {bool touch = false}) {
    int? hit;
    if (phase != HlPhase.leave) {
      for (var i = 0; i < 2; i++) {
        if (_bounds(i).contains(vb)) hit = i;
      }
    }
    // Lean toward the pointer, a little, like the basket does.
    for (var i = 0; i < 2; i++) {
      final b = _bounds(i);
      rock[i].t = hit == i ? ((vb.dx - b.center.dx) / b.width * 0.16).clamp(-0.08, 0.08) : 0;
    }
    if (hit != over) {
      over = hit;
      _readKey = '';
      _readout();
    }
    wake();
  }

  // ------------------------------------------------------------------ drawing

  /// A closed outline of rounded corners: [v] is (u, z, radius) per vertex, [map] puts (u, z) in space.
  Path _loop(List<(double, double, double)> v, Offset Function(double u, double z) map) {
    final pts = <Offset>[];
    for (var k = 0; k < v.length; k++) {
      final (x, z, r) = v[k];
      final (px, pz, _) = v[(k - 1 + v.length) % v.length];
      final (nx, nz, _) = v[(k + 1) % v.length];
      final d1 = math.sqrt((px - x) * (px - x) + (pz - z) * (pz - z)), d2 = math.sqrt((nx - x) * (nx - x) + (nz - z) * (nz - z));
      final t = math.min(r, math.min(d1, d2) / 2);
      if (t <= 0) {
        pts.add(map(x, z));
        continue;
      }
      final ax = x + (px - x) / d1 * t, az = z + (pz - z) / d1 * t, bx = x + (nx - x) / d2 * t, bz = z + (nz - z) / d2 * t;
      for (var s = 0; s <= 5; s++) {
        final q = s / 5, m = 1 - q;
        pts.add(map(m * m * ax + 2 * m * q * x + q * q * bx, m * m * az + 2 * m * q * z + q * q * bz));
      }
    }
    return _poly(pts);
  }

  /// The back panel: a rounded rectangle a little taller than the front, so a rim shows above it.
  void _back(HlPaint p, int i, Color c) {
    final cx = i * _gap, l = cx - _w / 2, r = cx + _w / 2, top = _hf + _backRise;
    p.plate(_loop([(l, 0, 3), (r, 0, 3), (r, top, 3), (l, top, 3)], (u, z) => _f(i, u, _yBack, z)), c);
  }

  /// The fold at the right: from the back panel round to the front. Its front edge starts where the
  /// front panel's straight right edge starts (below its rounded corners), so the two outlines meet
  /// without a tail, and one large radius at the bottom makes a single smooth curve (no bulge below the panel: that left a tail).
  void _fold(HlPaint p, int i, Color c) {
    final x = i * _gap + _w / 2;
    const e = 5.0; // the front panel's corner radius, plus a little
    double yAt(double z) => _yHinge + _lean * (z / _hf);
    // (y, z, r): u is the depth here.
    final v = <(double, double, double)>[
      (_yBack, 0, 9),
      (yAt(e), e, 0),
      (yAt(_hf - e), _hf - e, 1),
      (_yBack, _hf + _backRise, 3),
    ];
    p.plate(_loop(v, (y, z) => _f(i, x, y, z)), c);
  }

  /// The front panel, leaning open, with the notch cut from its top left.
  void _front(HlPaint p, int i, Color c) {
    final cx = i * _gap, l = cx - _w / 2, r = cx + _w / 2;
    Offset map(double u, double z) => _f(i, u, _yHinge + _lean * (z / _hf), z);
    p.plate(
      _loop([(l, 0, 3.5), (r, 0, 3.5), (r, _hf, 3.5), (l + _notchW, _hf, 3), (l + _notchW, _hf - _notchD, 3), (l, _hf - _notchD, 3)], map),
      c,
    );
  }

  /// A sheet as a card facing the viewer, turned by [angle] about its centre: an outline with a
  /// folded corner, and three ruled lines standing for text (strokes, not letters). [folder]
  /// is the folder it sits in (it rocks with it), or null in the air.
  ({Path outline, Path lines}) _sheet(double cx, double cz, double angle, {double y = _ySheet, int? folder}) {
    final ca = math.cos(angle), sa = math.sin(angle);
    Offset q(double dx, double dz) {
      final x = cx + dx * ca - dz * sa, z = cz + dx * sa + dz * ca;
      return folder == null ? _p(x, y, z) : _f(folder, x, y, z);
    }

    const hw = _sheetW / 2, hh = _sheetH / 2, ear = 5.5;
    final outline = _poly([q(-hw, -hh), q(hw, -hh), q(hw, hh - ear), q(hw - ear, hh), q(-hw, hh)]);
    outline
      ..moveTo(q(hw - ear, hh).dx, q(hw - ear, hh).dy)
      ..lineTo(q(hw - ear, hh - ear).dx, q(hw - ear, hh - ear).dy)
      ..lineTo(q(hw, hh - ear).dx, q(hw, hh - ear).dy);
    final lines = Path();
    for (final r in [0.0, 5.0, 10.0, 15.0]) {
      final a = q(-hw + 3.5, hh - 11 - r), b = q(hw - 3.5 - (r == 15.0 ? 7 : 0), hh - 11 - r);
      lines
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy);
    }
    return (outline: outline, lines: lines);
  }

  void _draw(HlPaint p, ({Path outline, Path lines}) s, Color c) {
    p.canvas.drawPath(s.outline, p.cut);
    p.canvas.drawPath(s.outline, p.line(c));
    p.canvas.drawPath(s.lines, p.line(p.pal.lo));
  }

  void _stack(HlPaint p, int i, int count, double rise) {
    // Sheets sitting in a folder, each a touch higher and to the side of the last, back to front.
    for (var k = 0; k < count; k++) {
      _draw(p, _sheet(i * _gap + (k - (count - 1) / 2) * 1.8, _seat + 2.4 * k + rise, 0, y: _ySheet - 0.5 * (count - k), folder: i), p.pal.edge);
    }
  }

  /// A sheet in the air, file k, with its progress t (0 – 1).
  ({double x, double z, double a}) _fly(int k, double t) {
    final e = t * t * (3 - 2 * t);
    final flutter = 0.42 * math.sin(2 * math.pi * t) * (k.isEven ? 1 : -1);
    return (x: _gap * e, z: _seat + _arc * math.sin(math.pi * t), a: flutter);
  }

  @override
  void paint(HlPaint p) {
    final c = p.pal;
    final flying = <int>[
      for (var k = math.max(0, (pos - _span).floor() + 1); k < math.min(n, pos.ceil()); k++)
        if (pos - k > 0 && pos - k < _span) k,
    ];
    final lead = flying.isEmpty ? null : flying.last;
    final done = arrived >= n;
    Color tone(int i) => over == i ? c.hi : c.edge;

    // The route, faint and dashed, behind everything so the folders cover it.
    final route = Path();
    for (var s = 0; s <= 24; s++) {
      final f = _fly(0, s / 24);
      final q = _p(f.x, _ySheet, f.z + _sheetH / 2 + 3);
      s == 0 ? route.moveTo(q.dx, q.dy) : route.lineTo(q.dx, q.dy);
    }
    for (final m in route.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 6) {
        p.canvas.drawPath(m.extractPath(d, math.min(d + 2.5, m.length)), p.line(c.lo));
      }
    }

    // Depth, near to far: the viewer looks along -y. Sheets sit between a folder's back panel and
    // its front panel, in the pocket or in the air, so the order is the same for all of them:
    // back panels and folds first, then the sheets, then the front panels. That alone hides the
    // part of a sheet still in the pocket behind the front panel.
    final m = math.min(4, arrived);
    for (var i = 0; i < 2; i++) {
      _back(p, i, tone(i));
      _fold(p, i, tone(i));
    }
    _stack(p, 0, 3, 0);
    if (m > 0) _stack(p, 1, m, 6 * arrived / n);
    for (final k in flying) {
      final f = _fly(k, (pos - k) / _span);
      _draw(p, _sheet(f.x, f.z, f.a), k == lead ? c.hi : c.edge);
    }
    for (var i = 0; i < 2; i++) {
      final bright = i == 1 ? (over == 1 || (lead == null && over == null && done)) : (over == 0 || (lead == null && over == null && !done));
      _front(p, i, bright ? c.hi : c.edge);
    }
  }
}
