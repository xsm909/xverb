import 'dart:isolate';
import 'dart:typed_data';

import 'sheet_source.dart';

/// The order a sheet is shown in when it is sorted by one column — for
/// looking, never for the file, which keeps its own.
///
/// Numbers are compared as numbers wherever the column is taken for numbers,
/// text as text folded to lower case, and an empty cell goes to the end
/// whichever way round, because a sort that put a thousand blanks first
/// would show a thousand blanks. Rows that compare equal keep their order in
/// the file, so sorting by a second column after a first is a sort within.
///
/// The keys are gathered here, on the way through the sheet; the sorting
/// itself runs on another isolate — a million comparisons in the one that
/// draws the window is a window that stops for a second.
class SheetSort {
  SheetSort(this.source, this.column, {this.descending = false});

  final SheetSource source;
  final int column;
  final bool descending;

  bool _cancelled = false;
  void cancel() => _cancelled = true;

  /// The rows of the source in the new order, or null when cancelled.
  Future<Int32List?> run() async {
    // A sheet still counting has not got all its rows yet, and a sort of
    // part of it would be put back together wrong when the rest arrived.
    while (source.counting && !_cancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (_cancelled) return null;
    final n = source.rowCount;
    final kinds = source.columnKinds;
    final numeric =
        column < kinds.length && kinds[column] == SheetColumnKind.number;
    final comma = source.decimalComma;
    final numbers = Float64List(n);
    final texts = List<String>.filled(n, '');
    // 0 empty, 1 a number, 2 text.
    final what = Uint8List(n);

    for (var from = 0; from < n; from += 4096) {
      final rows = await source.readRows(from, 4096);
      if (_cancelled) return null;
      for (var i = 0; i < rows.length && from + i < n; i++) {
        final row = rows[i];
        final value = column < row.length ? row[column] : null;
        final text = sheetText(value);
        if (text.trim().isEmpty) continue;
        final at = from + i;
        final number = numeric ? sheetNumber(value, decimalComma: comma) : null;
        if (number != null) {
          numbers[at] = number.toDouble();
          what[at] = 1;
        } else {
          texts[at] = text.toLowerCase();
          what[at] = 2;
        }
      }
    }
    final down = descending;
    return Isolate.run(() => _order(numbers, texts, what, down));
  }
}

Int32List _order(
  Float64List numbers,
  List<String> texts,
  Uint8List what,
  bool descending,
) {
  final n = what.length;
  final order = List<int>.generate(n, (i) => i);
  order.sort((a, b) {
    final wa = what[a];
    final wb = what[b];
    if (wa == 0 || wb == 0) {
      if (wa == wb) return a - b;
      return wa == 0 ? 1 : -1;
    }
    int c;
    if (wa == 1 && wb == 1) {
      c = numbers[a].compareTo(numbers[b]);
    } else if (wa == 1) {
      c = -1;
    } else if (wb == 1) {
      c = 1;
    } else {
      c = texts[a].compareTo(texts[b]);
    }
    if (descending) c = -c;
    return c != 0 ? c : a - b;
  });
  return Int32List.fromList(order);
}
