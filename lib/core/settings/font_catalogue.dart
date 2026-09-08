import 'package:flutter/painting.dart';

/// The font families offered in the appearance settings.
///
/// Flutter cannot enumerate the fonts a machine has installed, so this is a
/// list of the families a file manager is likely to be set to, filtered down
/// to the ones that are actually there — see [available]. Anything not on the
/// list can still be typed in by hand.
class FontCatalogue {
  const FontCatalogue._();

  /// Monospaced first: this is a file listing, and columns want to line up.
  static const List<String> candidates = [
    'monospace',
    'Cascadia Code',
    'Cascadia Mono',
    'Consolas',
    'Courier New',
    'DejaVu Sans Mono',
    'Fira Code',
    'IBM Plex Mono',
    'Iosevka',
    'JetBrains Mono',
    'Lucida Console',
    'Menlo',
    'Monaco',
    'Roboto Mono',
    'SF Mono',
    'Source Code Pro',
    'Ubuntu Mono',
    'Arial',
    'Calibri',
    'Georgia',
    'Helvetica',
    'Inter',
    'Roboto',
    'Segoe UI',
    'Tahoma',
    'Times New Roman',
    'Verdana',
  ];

  static List<String>? _available;

  /// The candidates this machine can actually draw, worked out once.
  static List<String> available() =>
      _available ??= candidates.where(exists).toList(growable: false);

  /// Whether [family] resolves to a real font.
  ///
  /// There is no API that answers this, so it is measured: a family the engine
  /// cannot find falls back to the default face, and then a line set in it is
  /// exactly as wide as the same line set in a family that certainly does not
  /// exist. Different width, real font.
  static bool exists(String family) {
    if (family.trim().isEmpty) return false;
    return _width(family) != _widthOfNone;
  }

  /// A family name nothing will ever be installed under.
  static const String _absent = '__xverb_missing_family__';

  static double? _widthOfNoneCache;

  static double get _widthOfNone => _widthOfNoneCache ??= _width(_absent);

  static double _width(String family) {
    // Letters with very different metrics between faces, so two real fonts are
    // unlikely to measure the same.
    final painter = TextPainter(
      text: TextSpan(
        text: 'MWiil1[]{}gq',
        style: TextStyle(fontFamily: family, fontSize: 64),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}
