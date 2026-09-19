import 'dart:convert';

import 'sheet_source.dart';

/// What a selection becomes on the clipboard.
///
/// Two shapes. **Tab-separated text** is what every spreadsheet puts there and
/// takes back — paste it into Excel or Numbers and it lands in cells. **JSON**
/// is for everything else a table ends up in: a request, a test, a script.
///
/// The grid given here is already the selection laid out as it stands in the
/// sheet: several ranges become the rows and columns they cover between them,
/// and a cell no range holds is null.

/// Rows of cells as tab-separated text, the way a spreadsheet copies them: the
/// text each cell is shown as, and a cell that holds a tab, a line end or a
/// quote put in quotes with its own quotes doubled.
String sheetTsv(List<List<Object?>> grid) {
  final out = StringBuffer();
  for (var r = 0; r < grid.length; r++) {
    if (r > 0) out.write('\r\n');
    final row = grid[r];
    for (var c = 0; c < row.length; c++) {
      if (c > 0) out.write('\t');
      final text = sheetText(row[c]);
      if (text.contains(RegExp('[\t\r\n"]'))) {
        out
          ..write('"')
          ..write(text.replaceAll('"', '""'))
          ..write('"');
      } else {
        out.write(text);
      }
    }
  }
  return out.toString();
}

/// The same cells as JSON.
///
/// With [names] — the sheet has a header — each row is an object keyed by the
/// column's name; without, an array. One cell alone is just its value. A
/// number is a number: a formatted one gives the number behind the format, and
/// a column the sheet takes for numbers gives numbers even from a CSV, where
/// every cell arrived as text.
String sheetJson(
  List<List<Object?>> grid, {
  List<String>? names,
  List<SheetColumnKind> kinds = const [],
  bool decimalComma = false,
}) {
  Object? value(Object? cell, int column) {
    final kind = column < kinds.length ? kinds[column] : SheetColumnKind.text;
    final raw = cell is SheetCell ? cell.value : cell;
    if (raw == null) return null;
    if (raw is num || raw is bool) return raw;
    final text = '$raw';
    if (text.isEmpty) return null;
    if (kind == SheetColumnKind.number) {
      return parseSheetNumber(text, decimalComma: decimalComma) ?? text;
    }
    if (kind == SheetColumnKind.boolean) {
      final lower = text.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    return text;
  }

  const encoder = JsonEncoder.withIndent('  ');
  if (grid.length == 1 && grid.first.length == 1 && names == null) {
    return encoder.convert(value(grid.first.first, 0));
  }
  final rows = [
    for (final row in grid)
      if (names != null)
        {
          for (var c = 0; c < row.length; c++)
            (c < names.length && names[c].isNotEmpty ? names[c] : '${c + 1}'):
                value(row[c], c),
        }
      else
        [for (var c = 0; c < row.length; c++) value(row[c], c)],
  ];
  return encoder.convert(rows);
}

/// Rows of cells as CSV: commas, and a cell holding a comma, a quote or a
/// line end put in quotes with its own quotes doubled — RFC 4180, which is
/// what anything that reads CSV reads.
String sheetCsv(List<List<Object?>> grid, {List<String>? names}) {
  String field(String text) => text.contains(RegExp('[,"\r\n]'))
      ? '"${text.replaceAll('"', '""')}"'
      : text;
  final out = StringBuffer();
  if (names != null) {
    out
      ..write(names.map(field).join(','))
      ..write('\r\n');
  }
  for (var r = 0; r < grid.length; r++) {
    if (r > 0) out.write('\r\n');
    out.write([for (final v in grid[r]) field(sheetText(v))].join(','));
  }
  return out.toString();
}

/// Rows of cells as a Markdown table, for pasting into a document or a
/// message. A table there must have a head, so a sheet without one gets its
/// column letters.
String sheetMarkdown(
  List<List<Object?>> grid, {
  required List<String> names,
  List<SheetColumnKind> kinds = const [],
}) {
  String cell(String text) => text
      .replaceAll('|', r'\|')
      .replaceAll('\r\n', '<br>')
      .replaceAll(RegExp('[\r\n]'), '<br>');
  final out = StringBuffer()
    ..write('| ${names.map(cell).join(' | ')} |\n')
    ..write('|');
  for (var c = 0; c < names.length; c++) {
    final number = c < kinds.length && kinds[c] == SheetColumnKind.number;
    out.write(number ? ' ---: |' : ' --- |');
  }
  out.write('\n');
  for (final row in grid) {
    out.write('| ');
    out.write(
      [
        for (var c = 0; c < names.length; c++)
          cell(c < row.length ? sheetText(row[c]) : ''),
      ].join(' | '),
    );
    out.write(' |\n');
  }
  return out.toString();
}
