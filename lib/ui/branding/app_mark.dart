import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'svg_path.dart';

/// The application's mark: a folder with an X across it.
///
/// **The drawing he gave, kept as the drawing he gave.** It arrived as an SVG
/// with one path in it, and that path is [outline] below — a string rather than
/// a page of `lineTo`s, so replacing the mark is replacing one constant with
/// whatever the next `d=` says. The alternative was to translate it into
/// canvas calls by hand, and a translation is a copy that can be wrong.
///
/// Drawn rather than shipped as an image, because it is wanted at a dozen sizes
/// and in more than one colour — 16 px in the title bar, 1024 px on a dock, the
/// bar's own ink on a bar somebody chose the colour of. A painter gives all of
/// that from one description, and `tool/render_icons.dart` renders the platform
/// icons from this same code, so the mark on the bar and the mark on the dock
/// can never drift apart.
class AppMarkPainter extends CustomPainter {
  const AppMarkPainter({
    required this.colour,
    this.background,
    this.plateRadius = 0.22,
  });

  /// Colour the mark is filled with.
  final Color colour;

  /// Filled behind the mark as a rounded square, the way a launcher icon
  /// wants. Null draws the mark alone on whatever is underneath, which is what
  /// the title bar wants.
  final Color? background;

  /// Corner radius of that plate, as a fraction of the side.
  final double plateRadius;

  /// The side of the square the mark is laid out in.
  static const double designSide = 512;

  /// The mark, exactly as the drawing gives it.
  ///
  /// Its own box is 565.44 × 491.94 — wider than it is tall — so it is centred
  /// and scaled to fit [designSide] rather than stretched to it. A mark
  /// stretched to a square is a different mark.
  static const double outlineWidth = 565.44;
  static const double outlineHeight = 491.94;

  static const String outline =
    'M504.59,46.32h-208.07c-7.56,0-14.83-2.93-20.29-8.18l-32.39-31.16c-4.6'
    '5-4.48-10.85-6.98-17.3-6.98H89.69C40.15,0,0,40.16,0,89.69v314.36c0,4'
    '8.54,39.35,87.89,87.89,87.89h389.79c48.47,0,87.76-39.29,87.76-87.76V1'
    '07.17c0-33.61-27.24-60.85-60.85-60.85ZM530.99,400.67c0,29.41-23.84,5'
    '3.25-53.24,53.25H87.69c-29.4,0-53.24-23.84-53.24-53.25V137.58c0-29.4'
    '1,23.84-53.25,53.24-53.25h390.06c29.4,0,53.24,23.84,53.24,53.25v263.0'
    '9ZM452,408.4h-81.19c-6.46,0-12.65-2.61-17.16-7.24l-70.92-72.74-70.92'
    ',72.74c-4.51,4.63-10.7,7.24-17.16,7.24h-81.19c-8.38,0-12.66-10.05-6.8'
    '7-16.1l117.91-123.6-117.49-120.49c-6.68-6.85-1.83-18.37,7.74-18.37h8'
    '2.77c7.01,0,13.71,2.87,18.55,7.94l66.66,69.87,66.66-69.87c4.84-5.07,1'
    '1.54-7.94,18.55-7.94h82.77c9.57,0,14.43,11.51,7.74,18.37l-117.49,120'
    '.49,117.91,123.6c5.8,6.05,1.51,16.1-6.87,16.1Z';

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(side / designSide);

    final plate = background;
    if (plate != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(0, 0, designSide, designSide),
          Radius.circular(designSide * plateRadius),
        ),
        Paint()..color = plate,
      );
    }

    // **Inset from the plate**, because a mark that runs to the edges of a
    // launcher icon reads as a crop rather than as a mark. A tenth either side
    // is what every platform's own icons leave.
    const margin = designSide * 0.16;
    const room = designSide - margin * 2;
    final scale = room / outlineWidth < room / outlineHeight
        ? room / outlineWidth
        : room / outlineHeight;

    canvas.translate(
      (designSide - outlineWidth * scale) / 2,
      (designSide - outlineHeight * scale) / 2,
    );
    canvas.scale(scale);
    canvas.drawPath(parseSvgPath(outline), Paint()..color = colour);

    canvas.restore();
  }

  @override
  bool shouldRepaint(AppMarkPainter old) =>
      old.colour != colour ||
      old.background != background ||
      old.plateRadius != plateRadius;

  /// Renders the mark to an image, for the platform icon files.
  Future<ui.Image> toImage(int pixels) {
    final recorder = ui.PictureRecorder();
    paint(Canvas(recorder), Size(pixels.toDouble(), pixels.toDouble()));
    return recorder.endRecording().toImage(pixels, pixels);
  }
}

/// The mark as a widget, for the title bar and anywhere else it is shown.
class AppMark extends StatelessWidget {
  const AppMark({
    super.key,
    required this.colour,
    this.size = 18,
    this.background,
  });

  final Color colour;
  final double size;
  final Color? background;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: AppMarkPainter(colour: colour, background: background),
        ),
      );
}
