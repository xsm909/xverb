import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../../core/sheet/cell_range.dart';
import '../../core/sheet/sheet_source.dart';

/// A small picture of a sheet, for the strip along the bottom of a viewer:
/// the head of the table as it would open — the column letters, the first
/// rows, bold where the file is bold, numbers to the right.
///
/// **A page, not a screenshot.** The strip holds pictures of all sorts of
/// files side by side, and a sheet reads as a sheet there when it looks like
/// a printed one: pale paper, a grey grid, dark writing. The theme of the
/// window is the strip's business, not the picture's.
///
/// Waits at most [wait] for the rows; a source that has none by then gives
/// no picture, and the strip draws what it draws for any file without one.
Future<Uint8List?> sheetThumbnail(
  SheetSource source,
  int pixels, {
  Duration wait = const Duration(seconds: 3),
}) async {
  const rows = 14;
  try {
    await source.ensure(0, rows).timeout(wait);
  } on TimeoutException {
    return null;
  }
  final count = math.min(rows, source.rowCount);
  if (count == 0 || source.columnCount == 0) return null;

  final values = <List<Object?>>[
    for (var r = 0; r < count; r++) source.rowAt(r) ?? const [],
  ];
  final names = source.columnNames;
  final kinds = source.columnKinds;

  // Laid out at a size a person could read, then scaled down to [pixels]:
  // the proportions of a real sheet, not of a thumbnail.
  // One page whatever the size asked for — a strip cell and a larger one
  // show the same rows and columns, only smaller or larger.
  const width = 260.0;
  const height = width * 0.75;
  final scale = pixels / width;
  const letterSize = 9.0;
  const cellSize = 10.0;
  const rowHeight = 15.0;
  const head = 14.0;
  const gutter = 22.0;

  // Columns as wide as what is in them, a little, to the edge of the page.
  final columns = <double>[];
  var used = gutter;
  for (var c = 0; c < source.columnCount && used < width; c++) {
    var chars = names != null && c < names.length ? names[c].length : 1;
    for (final row in values) {
      if (c < row.length) chars = math.max(chars, sheetText(row[c]).length);
    }
    final w = (math.min(chars, 14) * cellSize * 0.55 + 8).clamp(22.0, 90.0);
    columns.add(w);
    used += w;
  }

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  const paper = Color(0xFFFCFCFB);
  const band = Color(0xFFEDF0F2);
  const line = Color(0xFFD5DADF);
  const ink = Color(0xFF23282D);
  const quiet = Color(0xFF8A939B);
  canvas.drawRect(Rect.fromLTWH(0, 0, width, height), Paint()..color = paper);
  canvas.drawRect(Rect.fromLTWH(0, 0, width, head), Paint()..color = band);
  canvas.drawRect(Rect.fromLTWH(0, 0, gutter, height), Paint()..color = band);

  final grid = Paint()
    ..color = line
    ..strokeWidth = 1;
  var x = gutter;
  for (final w in columns) {
    canvas.drawLine(Offset(x, 0), Offset(x, height), grid);
    x += w;
  }
  canvas.drawLine(Offset(x, 0), Offset(x, height), grid);
  for (var y = head; y <= height; y += rowHeight) {
    canvas.drawLine(Offset(0, y), Offset(width, y), grid);
  }

  void write(String text, TextStyle style, Rect cell, {bool right = false}) {
    if (text.isEmpty) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, cell.width - 6));
    final dx = right ? cell.right - 3 - painter.width : cell.left + 3;
    painter.paint(
      canvas,
      Offset(dx, cell.top + (cell.height - painter.height) / 2),
    );
    painter.dispose();
  }

  const letter = TextStyle(color: quiet, fontSize: letterSize);
  const plain = TextStyle(color: ink, fontSize: cellSize);
  final strong = plain.copyWith(fontWeight: FontWeight.w700);
  x = gutter;
  for (var c = 0; c < columns.length; c++) {
    final name = names != null && c < names.length ? names[c] : '';
    write(
      name.isEmpty ? columnLetters(c) : name,
      name.isEmpty ? letter : strong.copyWith(fontSize: letterSize),
      Rect.fromLTWH(x, 0, columns[c], head),
    );
    x += columns[c];
  }
  for (var r = 0; r < count; r++) {
    final top = head + r * rowHeight;
    if (top > height) break;
    write('${r + 1}', letter, Rect.fromLTWH(0, top, gutter, rowHeight));
    x = gutter;
    final row = values[r];
    for (var c = 0; c < columns.length; c++) {
      if (c < row.length) {
        final value = row[c];
        final role = value is SheetCell ? value.role : null;
        write(
          sheetText(value).replaceAll('\n', ' '),
          role == 'strong' || role == 'total' ? strong : plain,
          Rect.fromLTWH(x, top, columns[c], rowHeight),
          right: c < kinds.length && kinds[c] == SheetColumnKind.number,
        );
      }
      x += columns[c];
    }
  }

  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(pixels, (pixels * 0.75).round());
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}
