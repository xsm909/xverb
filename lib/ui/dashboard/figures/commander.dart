// **The two-panel window itself, as a hairline figure.**
//
// Built on x-isoline's `HlPanels` (example/lib/figures/panels.dart at 3b4bad6,
// https://github.com/xsm909/x-isoline), which is a private repository: a
// public program cannot depend on it, so the figure lives here, on the kernel
// copied beside it (`hairline_kernel.dart`). From `HlPanels` it takes the slab,
// the rounded prisms, the springs and the rule that the pointer is tested on
// the face and never on the lifted pose. The drawing itself follows a design
// of this window made for the purpose ("panel.fig"): a title row with three
// dots, a menu row with the tool icons at its right, two panels each with a
// location bar, column heads and rows of folders and files in three columns,
// and six command buttons across the foot. Its measurements are kept in the
// design's own units below (651 by 411, y down) and scaled once.
//
// Hairline's drawing rules and kernel are MIT, Copyright (c) 2026 Lucas
// Marques; see `docs/third-party.md`.
//
// **It is parametric, and what it is given is true**: the rows are the first
// entries of the two real panels — a folder is drawn as a folder, a file as a
// file, and a name's dash is as long as the name — the panel in front is the
// active one and its cursor is where the panel's cursor is. The pointer picks
// a row: that panel comes forward, the row lifts off the face under a cursor
// plate and its neighbours follow on a falloff. Hovering is nearly the whole of the
// interaction, as in `HlPanels`, but for one thing: a press on a row is handed
// to the host (`onPicked`), which takes the real panel there.
//
// The slab stands in the x-z plane and faces +y, so the figure draws in its
// own frame: u across, v up, w out of the face, P2(u, v, w) = P(u, w, v).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'hairline_kernel.dart';

/// One row of a panel, as the figure needs it.
@immutable
class HlCommanderRow {
  const HlCommanderRow(this.name, {this.isFolder = false});

  final String name;
  final bool isFolder;

  @override
  bool operator ==(Object other) =>
      other is HlCommanderRow &&
      other.name == name &&
      other.isFolder == isFolder;

  @override
  int get hashCode => Object.hash(name, isFolder);
}

class HlCommander extends StatelessWidget {
  const HlCommander({
    super.key,
    this.left = const [],
    this.right = const [],
    this.leftActive = true,
    this.leftCursor = 0,
    this.rightCursor = 0,
    this.onPicked,
    this.palette,
    this.stroke,
  });

  /// The first rows of each panel. More than [hlCommanderRows] are not drawn.
  final List<HlCommanderRow> left, right;

  /// Which panel is the one being worked in.
  final bool leftActive;

  /// Where each panel's cursor is, as an index into its rows.
  final int leftCursor, rightCursor;

  /// A row was pressed: which panel (`true` for the left) and which of its
  /// rows. The figure keeps only hover; what a press means is the host's.
  final void Function(bool left, int row)? onPicked;

  final HairlinePalette? palette;
  final double? stroke;

  @override
  Widget build(BuildContext context) => HlFigureView(
    label:
        'The two panels of this window. The pointer picks a row; '
        'that panel comes forward and the row lifts.',
    palette: palette,
    stroke: stroke,
    create: () => _Commander(_params),
    sync: (m) => (m as _Commander).setParams(_params),
  );

  _Params get _params => _Params(
    [left, right],
    leftActive ? 0 : 1,
    [leftCursor, rightCursor],
    onPicked,
  );
}

/// How many rows a panel shows in the figure: the design's seven.
const hlCommanderRows = 7;

@immutable
class _Params {
  const _Params(this.rows, this.active, this.cursors, this.onPicked);
  final List<List<HlCommanderRow>> rows;
  final int active;
  final List<int> cursors;
  final void Function(bool left, int row)? onPicked;
}

// ------------------------------------------------------------- the design --

// The design's units: the window is 651 across and 411 down, y down. Every
// place below is read off it; [_u] and [_v] turn one into the face's frame.
const _dw = 651.0, _dh = 411.0, _k = 0.3;
double _u(double x) => x * _k;
double _v(double y) => (_dh - y) * _k;

const _w = _dw * _k, _h = _dh * _k;

// How thick the slab is, and how far every frame on the face stands out.
const _slab = 3.0, _hb = 1.4;

// The two panels' left edges and their width; a row's pitch and its first
// centre; the three columns, from a panel's left edge.
const _panelX = [14.0, 339.0], _panelW = 298.0;
const _rowPitch = 32.0, _row0 = 156.5;
const _nameX = 41.0, _nameMax = 100.0, _sizeX = 201.0, _dateX = 252.0;

// How far a row rises under the pointer, how far that reaches along its
// neighbours, and how far it reaches at rest.
const _liftMax = 5.2, _spread = 2.2, _restReach = 1.3;

double _clamp(double v, double a, double b) => math.max(a, math.min(b, v));
double _falloff(int d, double r) => _clamp(1 - d / r, 0, 1);

/// A ring sample on the slab's face: [u, v, nu, nv].
typedef _Ring = List<List<double>>;

_Ring _rrect(
  double u0,
  double v0,
  double u1,
  double v1,
  double r, [
  int n = 4,
]) {
  r = math.max(0, math.min(r, math.min((u1 - u0) / 2, (v1 - v0) / 2)));
  final out = <List<double>>[];
  for (final (cu, cv, a0) in [
    (u1 - r, v1 - r, 0.0),
    (u0 + r, v1 - r, 90.0),
    (u0 + r, v0 + r, 180.0),
    (u1 - r, v0 + r, 270.0),
  ]) {
    for (var k = 0; k <= n; k++) {
      final a = (a0 + 90 * k / n) * math.pi / 180;
      final ca = math.cos(a), sa = math.sin(a);
      out.add([cu + r * ca, cv + r * sa, ca, sa]);
    }
  }
  return out;
}

/// A rounded rectangle given in the design's units (y down), as the outer and
/// inner rings of a prism.
(_Ring, _Ring) _box(
  double x0,
  double y0,
  double x1,
  double y1,
  double r, [
  double b = 0.6,
]) {
  final u0 = _u(x0), u1 = _u(x1), v0 = _v(y1), v1 = _v(y0), rr = r * _k;
  return (
    _rrect(u0, v0, u1, v1, rr),
    _rrect(u0 + b, v0 + b, u1 - b, v1 - b, math.max(0.3, rr - b)),
  );
}

class _Row {
  _Row(this.side, this.j) : sp = HlSpring(0);
  final int side, j;
  final HlSpring sp;
  HlCommanderRow? data;

  /// The cursor plate under this row, rebuilt when the lift changes.
  HlSolid? plate;
  double drawn = double.nan;

  /// The design's y of this row's middle.
  double get y => _row0 + j * _rowPitch;
}

class _Commander extends HlFigureModel {
  _Commander(_Params params) : _p = params {
    cam = HlCam(45, 0.5, 1.42);
    List<double> w3(double u, double v, double w) => [u, w, v];
    cam.fit(
      [
        w3(0, 0, -_slab),
        w3(_w, 0, -_slab),
        w3(0, _h, -_slab),
        w3(_w, _h, -_slab),
        // The most extreme pose: a row of the right-hand panel at full lift.
        w3(_w - _u(14), _v(_row0), _liftMax + _hb),
      ],
      200,
      166,
    );

    final (sr, si) = _box(0, 0, _dw, _dh, 20, 2);
    slab = _prism(sr, si, -_slab, 0);

    for (var i = 0; i < 3; i++) {
      final x = 14.0 + i * 18;
      final (r, ri) = _box(x, 16, x + 11, 27, 5.5, 0.4);
      dots.add(_prism(r, ri, 0, i == 0 ? 1.2 : 0.8));
    }
    for (var side = 0; side < 2; side++) {
      final x = _panelX[side];
      final (r, ri) = _box(x, 88, x + _panelW, 114, 8);
      bars.add(_prism(r, ri, 0, _hb));
    }
    for (var i = 0; i < 6; i++) {
      final x = 14.0 + i * 106;
      final (r, ri) = _box(x, 381, x + 93, 402, 7);
      buttons.add(_prism(r, ri, 0, _hb));
    }

    for (var side = 0; side < 2; side++) {
      for (var j = 0; j < hlCommanderRows; j++) {
        rows.add(_Row(side, j));
      }
    }
    _apply(params);
    for (final r in rows) {
      r.sp.x = r.sp.t;
    }
    step(0, true);
    ready = true;
  }

  _Params _p;
  late final HlCam cam;
  late final HlSolid slab;
  final dots = <HlSolid>[], bars = <HlSolid>[], buttons = <HlSolid>[];
  final rows = <_Row>[];
  bool ready = false;

  /// Which panel the pointer is in and which row it is on; null when the
  /// pointer is not on the rows, and the rest pose then comes from the data.
  int? hoverSide, hoverRow;

  int get side => hoverSide ?? _p.active;
  int get lit => hoverRow ?? _cursorOf(_p.active);

  int _cursorOf(int side) {
    final n = _p.rows[side].length;
    if (n == 0) return -1;
    return _p.cursors[side].clamp(0, math.min(n, hlCommanderRows) - 1);
  }

  Offset p2(double u, double v, double w) => cam(u, w, v);

  /// A point given in the design's units, on the plane [w].
  Offset _at(double x, double y, double w) => p2(_u(x), _v(y), w);

  void setParams(_Params params) {
    _apply(params);
    wake();
  }

  void _apply(_Params params) {
    _p = params;
    for (final r in rows) {
      final list = _p.rows[r.side];
      r.data = r.j < list.length ? list[r.j] : null;
    }
    if (hoverSide != null && hoverRow != null) {
      // The row the pointer was on may have gone with the new listing.
      if (_p.rows[hoverSide!].length <= hoverRow!) _rest();
    }
    _retarget();
  }

  /// A ring sample faces the camera: its normal, in the slab's u-v plane,
  /// against the view direction of the kernel's camera, written out for this
  /// frame. Taken from `HlPanels`.
  bool _front(List<double> q) => 0.612 * q[2] + 0.5 * q[3] > 0;

  /// A rounded prism along w: the hull of its two faces and one crease on the
  /// lid.
  HlSolid _prism(_Ring ring, _Ring inner, double w0, double w1) {
    final pts = [
      for (final q in ring) p2(q[0], q[1], w1),
      for (final q in ring) p2(q[0], q[1], w0),
    ];
    final sil = Path()..addPolygon(hlHull(pts), true);
    final n = inner.length;
    final facing = [for (final q in inner) _front(q)];
    final crease = Path();
    var start = -1;
    for (var i = 0; i < n; i++) {
      if (facing[i] && !facing[(i + n - 1) % n]) {
        start = i;
        break;
      }
    }
    final idx = <int>[];
    if (start < 0) {
      if (facing[0]) idx.addAll([for (var i = 0; i < n; i++) i]);
    } else {
      for (var k = 0; k < n && facing[(start + k) % n]; k++) {
        idx.add((start + k) % n);
      }
    }
    for (var k = 0; k < idx.length; k++) {
      final q = inner[idx[k]], o = p2(q[0], q[1], w1);
      k == 0 ? crease.moveTo(o.dx, o.dy) : crease.lineTo(o.dx, o.dy);
    }
    return HlSolid(sil, crease);
  }

  void _buildPlate(_Row r) {
    if (r.sp.x == r.drawn) return;
    r.drawn = r.sp.x;
    final x = _panelX[r.side];
    final (ring, inner) = _box(x + 2, r.y - 13, x + _panelW - 2, r.y + 13, 6);
    r.plate = _prism(ring, inner, r.sp.x, r.sp.x + _hb);
  }

  /// The face point (u, v) under a viewBox point, on the plane [w].
  Offset _onFace(Offset s, double w) {
    final o = p2(0, 0, w), a = p2(1, 0, w) - o, b = p2(0, 1, w) - o;
    final d = a.dx * b.dy - a.dy * b.dx, q = s - o;
    return Offset(
      (q.dx * b.dy - q.dy * b.dx) / d,
      (a.dx * q.dy - a.dy * q.dx) / d,
    );
  }

  /// **Hit-tested on the face, never on the lifted pose**: a row that has
  /// risen under the pointer must not change the answer the pointer gets.
  void _hit(Offset p) {
    final q = _onFace(p, 0);
    final x = q.dx / _k, y = _dh - q.dy / _k;
    final top = _row0 - _rowPitch / 2;
    final bottom = _row0 + (hlCommanderRows - 0.5) * _rowPitch;
    if (y < top || y > bottom) return _rest();
    final s = x < _panelX[1] - 13 ? 0 : 1;
    if (x < _panelX[s] || x > _panelX[s] + _panelW) return _rest();
    final j = ((y - _row0) / _rowPitch).round().clamp(0, hlCommanderRows - 1);
    if (j >= _p.rows[s].length) return _rest();
    hoverSide = s;
    hoverRow = j;
  }

  void _rest() {
    hoverSide = null;
    hoverRow = null;
  }

  void _retarget() {
    final s = side, l = lit;
    final hovering = hoverSide != null;
    final name = (l >= 0 && l < _p.rows[s].length) ? _p.rows[s][l].name : '';
    read.value = hovering ? name : '';
    final reach = hovering ? _spread : _restReach;
    for (final r in rows) {
      r.sp.t = r.side == s && r.data != null && l >= 0
          ? _liftMax * _falloff((r.j - l).abs(), reach)
          : 0;
    }
    if (ready) wake();
  }

  @override
  bool step(double dt, bool snap) {
    var moving = false;
    for (final r in rows) {
      if (snap) {
        r.sp.x = r.sp.t;
        r.sp.v = 0;
      } else if (r.sp.step(dt)) {
        moving = true;
      }
      _buildPlate(r);
    }
    return moving;
  }

  // --------------------------------------------------------- drawing ----

  void _line(HlPaint p, Color c, double w, List<(double, double)> pts) {
    p.canvas.drawPath(
      hlOpen([for (final (x, y) in pts) _at(x, y, w)]),
      p.line(c),
    );
  }

  void _dash(HlPaint p, Color c, double w, double x0, double x1, double y) =>
      _line(p, c, w, [(x0, y), (x1, y)]);

  /// The three marks of the title row and the tools of the menu row: ruled
  /// lines for the words, and the window's own small marks at the right.
  void _head(HlPaint p) {
    final pal = p.pal;
    _dash(p, pal.lo, 0, 274, 343, 21.5);
    _dash(p, pal.lo, 0, 351, 374, 21.5);
    _dash(p, pal.mid, 0, 600, 612, 21.5);
    _line(p, pal.mid, 0, [(623, 16), (634, 27)]);
    _line(p, pal.mid, 0, [(634, 16), (623, 27)]);
    for (final (a, b) in [
      (19.0, 44.0),
      (58.0, 90.0),
      (104.0, 129.0),
      (143.0, 179.0),
      (193.0, 223.0),
    ]) {
      _dash(p, pal.mid, 0, a, b, 57.5);
    }
    for (final x in [526.0, 531.5, 537.0]) {
      _line(p, pal.lo, 0, [(x, 51), (x, 64)]);
    }
    _line(p, pal.lo, 0, [
      (558, 51),
      (572, 51),
      (572, 64),
      (558, 64),
      (558, 51),
    ]);
    for (final y in [51.0, 57.5, 64.0]) {
      _dash(p, pal.lo, 0, 590, 604, y);
    }
    _dash(p, pal.lo, 0, 620, 634, 57.5);
    _line(p, pal.lo, 0, [(627, 51), (627, 64)]);
  }

  /// What a location bar carries on its lid: the button that goes up, the
  /// path in pieces with the steps between them, and the list it drops.
  void _barMarks(HlPaint p, int s, Color c) {
    final x = _panelX[s], w = _hb;
    _line(p, c, w, [(x + 30, 88), (x + 30, 114)]);
    _line(p, c, w, [(x + 15, 108), (x + 15, 95)]);
    _line(p, c, w, [(x + 10, 100), (x + 15, 95), (x + 20, 100)]);
    final pieces = s == 0
        ? [(43.0, 73.0), (100.0, 152.0), (179.0, 217.0)]
        : [(43.0, 70.0), (97.0, 138.0), (165.0, 219.0)];
    for (var i = 0; i < pieces.length; i++) {
      final (a, b) = pieces[i];
      _dash(p, c, w, x + a, x + b, 101);
      if (i < pieces.length - 1) {
        final cx = x + b + 13;
        _line(p, c, w, [(cx - 2, 96.5), (cx + 2.5, 101), (cx - 2, 105.5)]);
      }
    }
    _line(p, c, w, [(x + 276, 99), (x + 281, 104), (x + 286, 99)]);
  }

  void _columnHeads(HlPaint p, int s, Color c) {
    final x = _panelX[s];
    _dash(p, c, 0, x + 6, x + 42, 133.5);
    _line(p, c, 0, [(x + 51, 136), (x + 55, 131.5), (x + 59, 136)]);
    _dash(p, c, 0, x + _sizeX, x + 225, 133.5);
    _dash(p, c, 0, x + _dateX, x + 287, 133.5);
    _dash(p, p.pal.mid, 0, x, x + _panelW, 140);
  }

  /// A folder: the pocket with its tab on the left, as the design has it.
  void _folder(HlPaint p, double x, double y, double w, Color c) {
    final pts = [
      (x, y - 9.5),
      (x + 8, y - 9.5),
      (x + 11, y - 5.5),
      (x + 22, y - 5.5),
      (x + 22, y + 9.5),
      (x, y + 9.5),
    ];
    p.plate(hlPoly([for (final (a, b) in pts) _at(a, b, w)]), c);
    _dash(p, c, w, x, x + 22, y - 3);
  }

  /// A file: a sheet with its corner turned and two lines of text.
  void _file(HlPaint p, double x, double y, double w, Color c) {
    final pts = [
      (x, y - 10),
      (x + 12, y - 10),
      (x + 18, y - 4),
      (x + 18, y + 10),
      (x, y + 10),
    ];
    p.plate(hlPoly([for (final (a, b) in pts) _at(a, b, w)]), c);
    _line(p, c, w, [(x + 12, y - 10), (x + 12, y - 4), (x + 18, y - 4)]);
    _dash(p, c, w, x + 4, x + 13, y + 2);
    _dash(p, c, w, x + 4, x + 10, y + 6);
  }

  /// One row: its icon and its three columns, at the height it has risen to.
  /// The name's dash is as long as the name; the other two vary a little by
  /// the name, so a column of them reads as values rather than a fence.
  void _rowMarks(HlPaint p, _Row r, double w, Color c) {
    final data = r.data!;
    final x = _panelX[r.side], y = r.y;
    if (data.isFolder) {
      _folder(p, x + 7, y, w, c);
    } else {
      _file(p, x + 10, y, w, c);
    }
    final len = _clamp(data.name.length / 24, 0.18, 1) * _nameMax;
    _dash(p, c, w, x + _nameX, x + _nameX + len, y);
    final h = data.name.hashCode;
    _dash(p, c, w, x + _sizeX, x + _sizeX + 19 + (h % 3) * 3.5, y);
    _dash(p, c, w, x + _dateX, x + _dateX + 33, y);
  }

  @override
  void paint(HlPaint p) {
    final pal = p.pal;
    final s = side, l = lit;
    p.solid(slab);

    // The face's own lines go first, so everything standing on it cuts them.
    _dash(p, pal.mid, 0, 0, _dw, 39);
    _dash(p, pal.mid, 0, 0, _dw, 76);
    _dash(p, pal.mid, 0, 0, _dw, 371);
    _line(p, pal.mid, 0, [(325, 76), (325, 371)]);
    _head(p);
    for (var i = 0; i < dots.length; i++) {
      p.solid(dots[i], pal.mid);
    }

    // The panel behind first, then the one in front.
    for (final side in [1 - s, s]) {
      final front = side == s;
      p.solid(bars[side], front ? pal.edge : pal.mid);
      _barMarks(p, side, front ? pal.edge : pal.lo);
      _columnHeads(p, side, front ? pal.mid : pal.lo);
      // The rows first and the cursor's row last: it stands furthest out of
      // the face, so its plate covers what its neighbours put behind it.
      final at = front ? l : _cursorOf(side);
      _Row? cursor;
      for (final r in rows) {
        if (r.side != side || r.data == null) continue;
        if (r.j == at) {
          cursor = r;
          continue;
        }
        _rowMarks(p, r, r.sp.x, front ? pal.edge : pal.lo);
      }
      if (cursor != null) {
        // The cursor is a plate the row stands on. In the panel in front it
        // is the one bright thing; in the other it lies flat and dim, which is
        // what a cursor in a panel not being worked in looks like.
        p.solid(
          cursor.plate!,
          front ? pal.hi : pal.lo,
          front ? pal.mid : pal.lo,
        );
        _rowMarks(p, cursor, cursor.sp.x + _hb, front ? pal.edge : pal.lo);
      }
    }

    for (final b in buttons) {
      p.solid(b, pal.mid);
    }
    for (var i = 0; i < buttons.length; i++) {
      final x = 14.0 + i * 106;
      _dash(p, pal.lo, _hb, x + 10, x + 18, 391.5);
      _dash(p, pal.lo, _hb, x + 30, x + 78, 391.5);
    }
  }

  /// The row a press lands on goes out to the host. Tested on the face like
  /// the hover, so the row that answers is the row that was lit.
  void _pick() {
    final s = hoverSide, j = hoverRow, picked = _p.onPicked;
    if (s == null || j == null || picked == null) return;
    picked(s == 0, j);
  }

  @override
  void pointer(HlPhase phase, Offset vb, {bool touch = false}) {
    switch (phase) {
      case HlPhase.hover:
        _hit(vb);
      case HlPhase.down || HlPhase.move:
        // A finger cannot hover, so while it is down it stands in for one.
        if (touch || phase == HlPhase.move) _hit(vb);
        // A mouse picks on the press, as a row in a list does.
        if (phase == HlPhase.down && !touch) {
          _hit(vb);
          _pick();
        }
      case HlPhase.up:
        if (!touch) return;
        // A finger picks where it is lifted, after it has been seen to light.
        _pick();
        _rest();
      case HlPhase.leave:
        _rest();
    }
    _retarget();
  }
}
