import 'dart:math' as math;

import 'cell_range.dart';
import 'sheet_source.dart';

/// What the status line says about a selection: how many cells have
/// something in them, and for the ones that are numbers their sum, their
/// average, the least and the most.
class SheetStats {
  const SheetStats({
    this.filled = 0,
    this.numbers = 0,
    this.sum = 0,
    this.min,
    this.max,
    this.complete = true,
  });

  final int filled;
  final int numbers;
  final double sum;
  final double? min;
  final double? max;

  /// False when it stopped at [SheetMeasure.limit] cells: the figures are of
  /// the part it read, and the line says so.
  final bool complete;

  double? get average => numbers == 0 ? null : sum / numbers;
}

/// Adds up a selection, reading the rows it covers — the ones not read yet
/// among them — so a whole column of a million rows has a true sum, the way
/// a spreadsheet gives one.
class SheetMeasure {
  SheetMeasure(
    this.source,
    this.ranges, {
    required this.rowOf,
    this.skipColumn,
  });

  final SheetSource source;

  /// The ranges, in the rows on screen.
  final List<CellRange> ranges;

  /// Which row of the source a row on screen is.
  final int Function(int view) rowOf;

  /// A column not to count — one the reader has hidden.
  final bool Function(int column)? skipColumn;

  /// The most cells read for one answer.
  static const int limit = 5000000;

  bool _cancelled = false;
  void cancel() => _cancelled = true;

  Future<SheetStats?> run(int rows, int columns) async {
    final clamped = [for (final r in ranges) ?r.clampTo(rows, columns)];
    if (clamped.isEmpty) return const SheetStats();
    final top = clamped.map((r) => r.top).reduce(math.min);
    final bottom = clamped.map((r) => r.bottom).reduce(math.max);
    final comma = source.decimalComma;
    var filled = 0;
    var numbers = 0;
    var sum = 0.0;
    double? least;
    double? most;
    var read = 0;
    var view = top;
    while (view <= bottom) {
      if (_cancelled) return null;
      // A run of rows on screen that are together in the file, read at once.
      final first = rowOf(view);
      var length = 1;
      while (view + length <= bottom &&
          length < 4096 &&
          rowOf(view + length) == first + length) {
        length++;
      }
      final values = await source.readRows(first, length);
      if (_cancelled) return null;
      for (var i = 0; i < length; i++) {
        final row = view + i;
        final cells = i < values.length ? values[i] : const <Object?>[];
        for (final r in clamped) {
          if (row < r.top || row > r.bottom) continue;
          for (var c = r.left; c <= r.right && c < cells.length; c++) {
            if (skipColumn?.call(c) ?? false) continue;
            // A cell two ranges share is counted once: only by the first
            // range that holds it.
            if (!identical(clamped.firstWhere((o) => o.contains(row, c)), r)) {
              continue;
            }
            final value = cells[c];
            if (sheetText(value).trim().isEmpty) continue;
            filled++;
            final number = sheetNumber(value, decimalComma: comma);
            if (number == null) continue;
            final d = number.toDouble();
            numbers++;
            sum += d;
            least = least == null ? d : math.min(least, d);
            most = most == null ? d : math.max(most, d);
          }
        }
        read += cells.length;
      }
      view += length;
      if (read > limit) {
        return SheetStats(
          filled: filled,
          numbers: numbers,
          sum: sum,
          min: least,
          max: most,
          complete: false,
        );
      }
    }
    return SheetStats(
      filled: filled,
      numbers: numbers,
      sum: sum,
      min: least,
      max: most,
    );
  }
}
