/// Formatting helpers shared by the panels and dialogs.
library;

const List<String> _units = ['B', 'K', 'M', 'G', 'T', 'P'];

/// Compact size for a panel column: `1 023 B`, `4.7 M`.
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${_units[unit]}';
}

/// Full size with thousands separators, for status lines.
String formatBytes(int bytes) {
  final digits = bytes.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return '$buffer bytes';
}

/// `2026-08-08 14:03` — sortable and unambiguous in any locale.
String formatDate(DateTime? date) {
  if (date == null) return '';
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
