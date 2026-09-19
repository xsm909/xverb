import 'package:flutter/foundation.dart';

import 'cell_range.dart';

/// What a column holds, guessed from what is in it. It decides which way the
/// cells lean — numbers right, text left — and whether a selection of them can
/// be added up.
enum SheetColumnKind { text, number, boolean }

/// One cell as a source that knows more than its text sends it.
///
/// Most cells are not this: a CSV has nothing but text, and a row of them is
/// a list of strings, because a million rows of wrapper objects would be the
/// memory a paged source exists to save. A value in a row is a `String`, a
/// `num`, a `bool`, null, or one of these when there is a shown text or a role
/// to go with it — a number formatted by the spreadsheet it came from, a total.
class SheetCell {
  const SheetCell(this.value, {this.text, this.role});

  final Object? value;

  /// How the source wants it shown, when that is not the value as it stands.
  final String? text;

  /// `strong`, `dim`, `accent`, `total` or `error` — described, never a colour.
  final String? role;
}

/// The text a value in a row is shown as.
String sheetText(Object? value) => switch (value) {
  null => '',
  final String s => s,
  final SheetCell c => c.text ?? sheetText(c.value),
  final double d when d == d.roundToDouble() && d.abs() < 1e15 =>
    d.toInt().toString(),
  _ => value.toString(),
};

/// The number a value in a row stands for, or null when it is not one.
num? sheetNumber(Object? value, {bool decimalComma = false}) => switch (value) {
  final num n => n,
  final SheetCell c => sheetNumber(c.value, decimalComma: decimalComma),
  final String s => parseSheetNumber(s, decimalComma: decimalComma),
  _ => null,
};

final _plainNumber = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');
final _thousands = RegExp(r'^[+-]?\d{1,3}(,\d{3})+(\.\d+)?$');

/// A number as people write one in a table.
///
/// `1 250`, `1 250,5` and `-3.2e5` are numbers; `12:30`, `2026-09-01` and
/// `+7 900 123-45-67` are not, which is why the rule is a whole-string match
/// and not "whatever parses". Spaces of any width between the digits are
/// thousands. [decimalComma] is the file's convention, not the cell's: a
/// semicolon-separated file is one written where the comma is the decimal
/// point, and `1,5` there is one and a half, where in a comma-separated file
/// it could not have been left unquoted at all.
num? parseSheetNumber(String text, {bool decimalComma = false}) {
  var s = text.trim();
  if (s.isEmpty || s.length > 40) return null;
  s = s.replaceAll(RegExp('[    ]'), '');
  if (decimalComma) {
    if (s.contains(',')) {
      if (','.allMatches(s).length > 1) return null;
      s = s.replaceAll('.', '').replaceAll(',', '.');
    }
  } else if (_thousands.hasMatch(s)) {
    s = s.replaceAll(',', '');
  }
  if (!_plainNumber.hasMatch(s)) return null;
  return num.tryParse(s);
}

/// A table somebody can scroll through without it all being in memory.
///
/// **Paged, never whole.** A source says how big it is — and may still be
/// counting, growing as it goes — and hands over rows when asked. [rowAt]
/// answers from what is already here and asks for the rest in the same
/// breath; the listeners hear when it arrives, and the grid draws the row
/// then. Nothing waits for the whole file.
abstract class SheetSource extends ChangeNotifier {
  /// Which file this is, when it is one — what the view remembers the
  /// column widths of it by, for as long as the application runs.
  String? identity;

  /// Data rows known so far — not counting a header row.
  int get rowCount;

  int get columnCount;

  /// Still finding out how many rows there are. [rowCount] only grows while
  /// this is true.
  bool get counting;

  /// Why nothing more can be read, in a sentence; null while all is well.
  String? get error;

  /// Whether the first row names the columns. Guessed; [setHasHeader] is the
  /// reader overruling the guess.
  bool get hasHeader;

  void setHasHeader(bool value);

  /// The column names when there is a header, or null when there is not.
  List<String>? get columnNames;

  /// What each column holds, as far as a sample of it says.
  List<SheetColumnKind> get columnKinds;

  /// Whether `1,5` is one and a half in this file.
  bool get decimalComma => false;

  /// Cells joined into one, in the rows of the source (a header row not
  /// counted): the first cell's text across all of them.
  List<CellRange> get merges => const [];

  /// Notes on cells, by row of the source and column.
  Map<(int, int), String> get notes => const {};

  /// Rows and columns the file keeps hidden. Rows in the source's own
  /// numbering.
  Set<int> get hiddenRows => const {};
  Set<int> get hiddenColumns => const {};

  /// Rows of the menu the source adds to the sheet's own, known before the
  /// menu opens — a menu is never made to wait for its rows.
  List<SheetMenuItem> get menuItems => const [];

  /// Whether the source wants to hear where the selection has settled.
  bool get wantsSelection => false;

  /// Whether Enter and a double click on a cell mean something to the source.
  bool get wantsActivate => false;

  /// One of [menuItems] was chosen, with the selection it was chosen on.
  Future<SheetAction?> press(String id, Map<String, Object?> selection) async =>
      null;

  /// The selection has settled here.
  void selected(Map<String, Object?> selection) {}

  /// Enter, or a double click, on [row] and [column] of the file.
  Future<SheetAction?> activate(int row, int column) async => null;

  /// The names of the sheets in the file, when there is more than one to
  /// choose from — a workbook's pages. Empty for a file that is one sheet.
  List<String> get sheetTitles => const [];

  /// Which of [sheetTitles] is being shown.
  int get sheetIndex => 0;

  /// Shows another sheet of the same file. Everything about the last one —
  /// its size, its rows, whether it has a header — is forgotten, and the
  /// listeners hear once the new one is here.
  Future<void> selectSheet(int index) async {}

  /// The values of [row], or null when they are not here yet — in which case
  /// they have been asked for.
  List<Object?>? rowAt(int row);

  /// Resolves once rows [from] to `from + count` are here, or there is nothing
  /// more to wait for.
  Future<void> ensure(int from, int count);

  /// Rows [from] to `from + count`, for something going straight through the
  /// sheet — a search, a copy — rather than scrolling it.
  ///
  /// Not kept: a search through a million rows must not push the rows on
  /// screen out of what is kept for scrolling. A row past the end is not
  /// there, so the list can be shorter than asked for.
  Future<List<List<Object?>>> readRows(int from, int count) async {
    await ensure(from, count);
    final out = <List<Object?>>[];
    for (var row = from; row < from + count && row < rowCount; row++) {
      out.add(rowAt(row) ?? const []);
    }
    return out;
  }
}

/// Whether the first row is a header, from the rows under it.
///
/// A header is words over data: most cells of it filled with text, none of
/// them numbers and none the same. Where a column is text over numbers that settles it; where
/// everything is text there is nothing to tell them apart by, and the answer
/// is yes — most CSV files have one, and a wrong guess is one press away from
/// being overruled.
bool guessHeader(List<List<String>> records, {bool decimalComma = false}) {
  if (records.length < 2) return false;
  final first = records.first;
  // A gap or two is allowed: a workbook often leaves the cell over its own
  // column of row numbers empty. Most of the row has to be named, though.
  final names = first.where((s) => s.trim().isNotEmpty).toList();
  if (names.isEmpty || names.length * 10 < first.length * 6) return false;
  if (names.any(
    (s) => parseSheetNumber(s, decimalComma: decimalComma) != null,
  )) {
    return false;
  }
  return names.toSet().length == names.length;
}

/// What each column holds, from a sample of rows.
///
/// A column is numbers when nine in ten of its filled cells are — a stray
/// "n/a" does not turn a column of prices back into text.
List<SheetColumnKind> guessColumnKinds(
  List<List<Object?>> rows,
  int columns, {
  bool decimalComma = false,
}) {
  return [
    for (var column = 0; column < columns; column++)
      _kindOf(rows, column, decimalComma),
  ];
}

SheetColumnKind _kindOf(List<List<Object?>> rows, int column, bool comma) {
  var filled = 0;
  var numbers = 0;
  var booleans = 0;
  for (final row in rows) {
    if (column >= row.length) continue;
    final value = row[column];
    final text = sheetText(value).trim();
    if (text.isEmpty) continue;
    filled++;
    if (value is bool) {
      booleans++;
    } else if (sheetNumber(value, decimalComma: comma) != null) {
      numbers++;
    } else {
      final lower = text.toLowerCase();
      if (lower == 'true' || lower == 'false') booleans++;
    }
  }
  if (filled == 0) return SheetColumnKind.text;
  if (booleans == filled) return SheetColumnKind.boolean;
  if (numbers * 10 >= filled * 9) return SheetColumnKind.number;
  return SheetColumnKind.text;
}

/// A row a source adds to the sheet's menu.
class SheetMenuItem {
  const SheetMenuItem(this.id, this.label, {this.enabled = true});

  final String id;
  final String label;
  final bool enabled;
}

/// What a source asks the host to do when something it offered was used:
/// say a sentence, or put text on the clipboard. Intentions, carried out by
/// the host — a plugin cannot drive the window itself.
class SheetAction {
  const SheetAction({this.notice, this.copy});

  factory SheetAction.fromJson(Object? json) {
    if (json is! Map) return const SheetAction();
    return SheetAction(
      notice: json['notice'] as String?,
      copy: json['copy'] as String?,
    );
  }

  final String? notice;
  final String? copy;
}
