import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/viewer.dart';
import 'zoom_canvas.dart';

/// A drawing, drawn as shapes.
///
/// Whoever read the file has already done everything a format knows about —
/// transforms applied, styles cascaded, arcs cut into curves, gradients turned
/// into two points and a list of stops — so this builds four kinds of verb into
/// a path and paints it. See [VectorDrawing].
///
/// The paths are built **once**, in the drawing's own coordinates, and the
/// canvas is scaled around them. That is what keeps the lines sharp at any
/// magnification and what makes a magnified drawing cost the same as a small
/// one: a stroke a tenth of a unit wide is still a tenth of a unit wide at
/// sixteen times, and the rasteriser draws it at whatever size the transform
/// says.
class VectorView extends StatefulWidget {
  const VectorView({
    super.key,
    required this.drawing,
    this.hasKeyboard = true,
    this.detail,
  });

  final VectorDrawing drawing;
  final bool hasKeyboard;
  final String? detail;

  @override
  State<VectorView> createState() => _VectorViewState();
}

class _VectorViewState extends State<VectorView> {
  late List<_Drawn> _shapes = _build(widget.drawing);

  @override
  void didUpdateWidget(VectorView old) {
    super.didUpdateWidget(old);
    if (!identical(old.drawing, widget.drawing)) {
      _shapes = _build(widget.drawing);
    }
  }

  static List<_Drawn> _build(VectorDrawing drawing) {
    final out = <_Drawn>[];
    for (final shape in drawing.shapes) {
      if (shape.isText) {
        out.add(_Drawn(path: ui.Path(), shape: shape, words: _words(shape)));
        continue;
      }
      final path = ui.Path()
        ..fillType = shape.evenOdd ? ui.PathFillType.evenOdd : ui.PathFillType.nonZero;
      var at = 0;
      for (final verb in shape.verbs) {
        switch (verb) {
          case 0:
            if (at + 2 > shape.points.length) break;
            path.moveTo(shape.points[at], shape.points[at + 1]);
            at += 2;
          case 1:
            if (at + 2 > shape.points.length) break;
            path.lineTo(shape.points[at], shape.points[at + 1]);
            at += 2;
          case 2:
            if (at + 6 > shape.points.length) break;
            path.cubicTo(
              shape.points[at], shape.points[at + 1],
              shape.points[at + 2], shape.points[at + 3],
              shape.points[at + 4], shape.points[at + 5],
            );
            at += 6;
          case 3:
            path.close();
        }
      }
      out.add(_Drawn(
        path: path,
        shape: shape,
        fill: _shader(shape.fillGradient),
        stroke: _shader(shape.strokeGradient),
      ));
    }
    return out;
  }

  /// A run of text, laid out once. Laying it out per frame would do the whole
  /// of the typesetting on every drag of the canvas.
  static TextPainter _words(VectorShape shape) {
    final painter = TextPainter(
      text: TextSpan(
        text: shape.text,
        style: TextStyle(
          // The size is in the drawing's own units, and the canvas is scaled
          // around it — so the letters grow with everything else.
          fontSize: shape.size,
          color: Color(shape.fill ?? 0xFF000000),
          fontWeight: FontWeight.values[
              ((shape.weight ~/ 100) - 1).clamp(0, FontWeight.values.length - 1)],
          fontStyle: shape.italic ? FontStyle.italic : FontStyle.normal,
          fontFamily: switch (shape.family) {
            'mono' => 'monospace',
            'serif' => 'serif',
            _ => null,
          },
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter;
  }

  /// A gradient as a shader, in the drawing's own coordinates — which is the
  /// space the canvas is scaled into, so it needs no transform of its own.
  static ui.Shader? _shader(VectorGradient? gradient) {
    if (gradient == null) return null;
    final colours = [for (final colour in gradient.colours) Color(colour)];
    final tile = switch (gradient.spread) {
      'reflect' => TileMode.mirror,
      'repeat' => TileMode.repeated,
      _ => TileMode.clamp,
    };
    final from = Offset(gradient.from[0], gradient.from[1]);
    final to = Offset(gradient.to[0], gradient.to[1]);
    if (!gradient.radial) {
      return ui.Gradient.linear(from, to, colours, gradient.offsets, tile);
    }
    if (gradient.radius <= 0) return null;
    return ui.Gradient.radial(
      from,
      gradient.radius,
      colours,
      gradient.offsets,
      tile,
      null,
      // Where the light of it comes from, which is the centre again unless the
      // file moved it.
      from == to ? null : to,
      0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final drawing = widget.drawing;
    return ZoomCanvas(
      content: Size(drawing.width, drawing.height),
      hasKeyboard: widget.hasKeyboard,
      detail: widget.detail,
      caption: (zoom) =>
          '${_round(drawing.width)} × ${_round(drawing.height)}'
          ' · ${tr('{count} shape(s)', {'count': drawing.shapes.length})}'
          ' · ${zoomPercent(zoom)}%',
      paint: (canvas, at, scale) {
        canvas.save();
        canvas.translate(at.left, at.top);
        canvas.scale(scale);
        for (final drawn in _shapes) {
          final words = drawn.words;
          if (words != null) {
            _write(canvas, drawn.shape, words);
            continue;
          }
          final fill = drawn.shape.fill;
          if (fill != null || drawn.fill != null) {
            canvas.drawPath(
              drawn.path,
              Paint()
                ..color = Color(fill ?? 0xFF000000)
                ..shader = drawn.fill
                ..isAntiAlias = true,
            );
          }
          final stroke = drawn.shape.stroke;
          if ((stroke != null || drawn.stroke != null) &&
              drawn.shape.strokeWidth > 0) {
            canvas.drawPath(
              drawn.path,
              Paint()
                ..color = Color(stroke ?? 0xFF000000)
                ..shader = drawn.stroke
                ..style = PaintingStyle.stroke
                // In the drawing's own units, so the canvas's own scale makes
                // it the right number of pixels — which is the whole point.
                ..strokeWidth = drawn.shape.strokeWidth
                ..strokeCap = _cap(drawn.shape.cap)
                ..strokeJoin = _join(drawn.shape.join)
                ..isAntiAlias = true,
            );
          }
        }
        canvas.restore();
      },
    );
  }

  /// One run of text, under its own transform and off its own baseline.
  static void _write(Canvas canvas, VectorShape shape, TextPainter words) {
    final at = shape.at.length >= 2 ? shape.at : const [0.0, 0.0];
    canvas.save();
    if (shape.matrix.length == 6) {
      final m = shape.matrix;
      canvas.transform(Float64List.fromList([
        m[0], m[1], 0, 0,
        m[2], m[3], 0, 0,
        0, 0, 1, 0,
        m[4], m[5], 0, 1,
      ]));
    }
    // The drawing names the baseline; a painter starts from the top of the
    // line, so the difference is taken off. Without it every label sits a
    // line's height too low, which reads as the whole drawing being wrong.
    final baseline = words.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final shift = switch (shape.anchor) {
      'middle' => -words.width / 2,
      'end' => -words.width,
      _ => 0.0,
    };
    words.paint(canvas, Offset(at[0] + shift, at[1] - baseline));
    canvas.restore();
  }

  static String _round(double value) =>
      value == value.roundToDouble() ? value.round().toString() : value.toStringAsFixed(1);

  static StrokeCap _cap(String name) => switch (name) {
        'round' => StrokeCap.round,
        'square' => StrokeCap.square,
        _ => StrokeCap.butt,
      };

  static StrokeJoin _join(String name) => switch (name) {
        'round' => StrokeJoin.round,
        'bevel' => StrokeJoin.bevel,
        _ => StrokeJoin.miter,
      };
}

class _Drawn {
  const _Drawn({
    required this.path,
    required this.shape,
    this.fill,
    this.stroke,
    this.words,
  });

  final ui.Path path;
  final VectorShape shape;

  /// Built once with the path rather than per frame: a shader is a compiled
  /// thing, and this canvas repaints on every drag.
  final ui.Shader? fill;
  final ui.Shader? stroke;

  /// Set once, for the same reason.
  final TextPainter? words;
}
