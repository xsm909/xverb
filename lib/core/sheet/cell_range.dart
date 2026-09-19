/// Where something is in a sheet, and how it is written down.
///
/// Rows and columns are counted from zero here and nowhere else. What a reader
/// sees is Excel's notation — `C2`, `C2:D9`, `C:C`, `4:4` — because that is
/// what an address will be pasted next to, and a sheet that invented its own
/// would be the one place the notation had to be translated.
library;

/// One cell: a row and a column, both from zero.
class CellAddress {
  const CellAddress(this.row, this.column);

  final int row;
  final int column;

  /// `C2` for row 1, column 2.
  String get label => '${columnLetters(column)}${row + 1}';

  @override
  bool operator ==(Object other) =>
      other is CellAddress && other.row == row && other.column == column;

  @override
  int get hashCode => Object.hash(row, column);

  @override
  String toString() => label;
}

/// A rectangle of cells, inclusive at both ends.
///
/// **A whole row or a whole column is a range with no end, not a range that
/// ends where the sheet does today.** A sheet can still be counting its rows
/// while somebody selects a column, and a column that stopped at row 12 000
/// because that was all that had been counted when it was pressed would be a
/// column that lied as soon as the count went on. So [allRows] and
/// [allColumns] say "every one there is", and [clampTo] turns that into
/// numbers only at the moment something needs them.
class CellRange {
  const CellRange({
    required this.top,
    required this.left,
    required this.bottom,
    required this.right,
    this.allRows = false,
    this.allColumns = false,
  });

  /// From one corner to the other, in whichever order they came.
  factory CellRange.between(CellAddress a, CellAddress b) => CellRange(
    top: a.row < b.row ? a.row : b.row,
    bottom: a.row < b.row ? b.row : a.row,
    left: a.column < b.column ? a.column : b.column,
    right: a.column < b.column ? b.column : a.column,
  );

  factory CellRange.cell(CellAddress at) => CellRange.between(at, at);

  /// Rows [from] to [to], every column of them.
  factory CellRange.rows(int from, int to) => CellRange(
    top: from < to ? from : to,
    bottom: from < to ? to : from,
    left: 0,
    right: 0,
    allColumns: true,
  );

  /// Columns [from] to [to], every row of them.
  factory CellRange.columns(int from, int to) => CellRange(
    top: 0,
    bottom: 0,
    left: from < to ? from : to,
    right: from < to ? to : from,
    allRows: true,
  );

  static const CellRange everything = CellRange(
    top: 0,
    left: 0,
    bottom: 0,
    right: 0,
    allRows: true,
    allColumns: true,
  );

  final int top;
  final int left;

  /// Meaningless when [allRows] is set.
  final int bottom;

  /// Meaningless when [allColumns] is set.
  final int right;

  /// Every row there is: the range is one or more whole columns.
  final bool allRows;

  /// Every column there is: the range is one or more whole rows.
  final bool allColumns;

  bool get isEverything => allRows && allColumns;

  bool get isSingleCell =>
      !allRows && !allColumns && top == bottom && left == right;

  bool containsRow(int row) => allRows || (row >= top && row <= bottom);

  bool containsColumn(int column) =>
      allColumns || (column >= left && column <= right);

  bool contains(int row, int column) =>
      containsRow(row) && containsColumn(column);

  /// Whether every cell of [other] is in this range too.
  bool covers(CellRange other) =>
      (allRows ||
          (!other.allRows && other.top >= top && other.bottom <= bottom)) &&
      (allColumns ||
          (!other.allColumns && other.left >= left && other.right <= right));

  /// The same range in the numbers of a sheet this big. Null when nothing of
  /// it is left inside — a range on a sheet with no rows, or one that began
  /// past the end of a sheet that got shorter.
  CellRange? clampTo(int rows, int columns) {
    if (rows <= 0 || columns <= 0) return null;
    final t = allRows ? 0 : top;
    final l = allColumns ? 0 : left;
    if (t >= rows || l >= columns) return null;
    final b = allRows ? rows - 1 : (bottom < rows ? bottom : rows - 1);
    final r = allColumns
        ? columns - 1
        : (right < columns ? right : columns - 1);
    return CellRange(top: t, left: l, bottom: b, right: r);
  }

  /// How many cells, on a sheet this big.
  int cellCount(int rows, int columns) {
    final c = clampTo(rows, columns);
    if (c == null) return 0;
    return (c.bottom - c.top + 1) * (c.right - c.left + 1);
  }

  /// Excel's way of writing it: `C2`, `C2:D9`, `C:D`, `4:7`, `A:A` style for
  /// columns and `1:1` style for rows. Everything is written as the rows it
  /// covers on a sheet of [rows] — Excel writes `1:1048576` for the same thing.
  String label({int rows = 0}) {
    if (isEverything) return '1:${rows > 0 ? rows : 1}';
    if (allRows) return '${columnLetters(left)}:${columnLetters(right)}';
    if (allColumns) return '${top + 1}:${bottom + 1}';
    final from = CellAddress(top, left).label;
    if (isSingleCell) return from;
    return '$from:${CellAddress(bottom, right).label}';
  }

  /// The shape a plugin is told: an end that is not there is null.
  Map<String, Object?> toJson() => {
    'top': allRows ? 0 : top,
    'left': allColumns ? 0 : left,
    'bottom': allRows ? null : bottom,
    'right': allColumns ? null : right,
  };

  @override
  bool operator ==(Object other) =>
      other is CellRange &&
      other.allRows == allRows &&
      other.allColumns == allColumns &&
      (allRows || (other.top == top && other.bottom == bottom)) &&
      (allColumns || (other.left == left && other.right == right));

  @override
  int get hashCode => Object.hash(
    allRows,
    allColumns,
    allRows ? 0 : top,
    allRows ? 0 : bottom,
    allColumns ? 0 : left,
    allColumns ? 0 : right,
  );

  @override
  String toString() => label();
}

/// `A` for 0, `Z` for 25, `AA` for 26 — bijective base 26, which is why it is
/// not a plain conversion: there is no letter for zero.
String columnLetters(int column) {
  var n = column + 1;
  final letters = <int>[];
  while (n > 0) {
    final rest = (n - 1) % 26;
    letters.add(0x41 + rest);
    n = (n - 1) ~/ 26;
  }
  return String.fromCharCodes(letters.reversed);
}

/// The column [letters] name, or null when they are not letters of A to Z.
int? columnFromLetters(String letters) {
  if (letters.isEmpty) return null;
  var n = 0;
  for (final unit in letters.toUpperCase().codeUnits) {
    if (unit < 0x41 || unit > 0x5A) return null;
    n = n * 26 + (unit - 0x40);
  }
  return n - 1;
}

final _cell = RegExp(r'^([A-Za-z]+)(\d+)$');
final _column = RegExp(r'^[A-Za-z]+$');
final _row = RegExp(r'^\d+$');

/// What was typed into *Go to*: `C12`, `c12`, `C2:D9`, `B:D`, `B`, `40`,
/// `4:7`. Null for anything else — including a row 0, which no reader has
/// ever meant.
///
/// A lone number is a row and a lone word is a column, because that is what
/// somebody means by "go to 40" or "go to D"; Excel wants `40:40` and `D:D` for
/// the same thing, and both are read too.
CellRange? parseCellRange(String typed) {
  final text = typed.trim().replaceAll(' ', '');
  if (text.isEmpty) return null;
  final parts = text.split(':');
  if (parts.length > 2) return null;

  final a = parts.first;
  final b = parts.length == 2 ? parts.last : parts.first;

  final ca = _cell.firstMatch(a);
  final cb = _cell.firstMatch(b);
  if (ca != null && cb != null) {
    final from = _address(ca);
    final to = _address(cb);
    if (from == null || to == null) return null;
    return CellRange.between(from, to);
  }
  if (_column.hasMatch(a) && _column.hasMatch(b)) {
    final from = columnFromLetters(a);
    final to = columnFromLetters(b);
    if (from == null || to == null) return null;
    return CellRange.columns(from, to);
  }
  if (_row.hasMatch(a) && _row.hasMatch(b)) {
    final from = int.parse(a);
    final to = int.parse(b);
    if (from < 1 || to < 1) return null;
    return CellRange.rows(from - 1, to - 1);
  }
  return null;
}

CellAddress? _address(RegExpMatch match) {
  final column = columnFromLetters(match.group(1)!);
  final row = int.parse(match.group(2)!);
  if (column == null || row < 1) return null;
  return CellAddress(row - 1, column);
}
