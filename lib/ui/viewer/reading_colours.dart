import 'package:flutter/material.dart';

import '../../core/settings/appearance_settings.dart';
import '../plugins/plugin_table.dart' show appearanceOf;

/// The colours a page of content is read on.
///
/// **Two settings, and everything else derived from them**, and it is worth
/// saying why that holds rather than growing into a list. A page of reading
/// is one surface with one ink on it; the plaque behind a block of code, the
/// rule under a table heading, the wash inside an inline pill are not colours
/// anybody chooses, they are that ink at a distance. Given the pair, every one
/// of them can be worked out, and each one that is worked out here is one that
/// cannot drift out of step with the other twelve.
///
/// What is deliberately **not** derived is the syntax colouring. Keywords,
/// strings and numbers go on taking [AppearanceSettings.directoryColor],
/// [AppearanceSettings.markedColor] and [AppearanceSettings.accentColor]:
/// three hues answering to two knobs is a loss of control dressed up as
/// simplicity.
///
/// Before this existed the page was painted in the panel's fill, the code on it
/// was written in the panel's ink, and the markdown on it took Material's
/// `ColorScheme` — seeded from the accent and brightened by `darkChrome`. So
/// the reading could not be set at all, and its own halves disagreed: a dark
/// page under light chrome drew a cream plaque and near-black prose on it.
@immutable
class ReadingColours {
  const ReadingColours({
    required this.paper,
    required this.ink,
    required this.accent,
  });

  /// The pair as the settings hold it — what the viewer page installs.
  factory ReadingColours.of(AppearanceSettings theme) => ReadingColours(
    paper: theme.readingBackground,
    ink: theme.readingForeground,
    accent: theme.accentColor,
  );

  /// The pair *in force* on whatever surface [theme] describes.
  ///
  /// [appearanceOf] hands back the reading's colours in place of the panel's
  /// wherever a [ReadingSurface] is above, so this reads the right pair in both
  /// places without asking which it is in: the page inside a reading, the
  /// listing's own colours in a panel or a test harness.
  factory ReadingColours.surface(AppearanceSettings theme) => ReadingColours(
    paper: theme.panelBackground,
    ink: theme.panelForeground,
    accent: theme.accentColor,
  );

  /// The page itself.
  final Color paper;

  /// The body: prose, plain code, a table cell. Everything quieter than the
  /// body is this colour with alpha taken off it.
  final Color ink;

  /// Links, the bar beside a quote, the marks that are not text.
  final Color accent;

  /// A caption, a quotation, the address after a link: present, but not the
  /// line being read.
  Color get quiet => ink.withValues(alpha: 0.72);

  /// A comment — the part of a file that is explicitly *not* the reading.
  Color get faint => ink.withValues(alpha: 0.45);

  /// Punctuation, and anything holding text apart rather than saying it.
  Color get muted => ink.withValues(alpha: 0.55);

  /// A rule: under a table's heading, between sections, round a block.
  Color get rule => ink.withValues(alpha: 0.20);

  /// The plaque a block of code sits on. Blended rather than left translucent,
  /// because it is painted over the page and sometimes over a blurred bar, and
  /// a translucent fill would come out two different colours in the two places.
  Color get plaque => Color.alphaBlend(ink.withValues(alpha: 0.07), paper);

  /// The same, a shade further — a pinned heading, a cell that is being
  /// pointed at.
  Color get raised => Color.alphaBlend(ink.withValues(alpha: 0.13), paper);

  /// Legible on [accent] — what a filled accent chip is written in.
  Color get onAccent =>
      accent.computeLuminance() > 0.5 ? Colors.black : Colors.white;

  /// Whether the page is a dark one. Asked when a colour has to go the *other*
  /// way from the paper: a diff's green and red, a chart's fill.
  bool get isDark => paper.computeLuminance() < 0.5;

  @override
  bool operator ==(Object other) =>
      other is ReadingColours &&
      other.paper == paper &&
      other.ink == ink &&
      other.accent == accent;

  @override
  int get hashCode => Object.hash(paper, ink, accent);
}

/// Marks everything below it as being *on a page* rather than in a panel.
///
/// Content widgets are reached from three places — the viewer page, a panel's
/// view pane, a plugin's own command output — and only the first of them is a
/// reading. Rather than every widget asking which of the three it is in, the
/// page says so once and [readingColours] answers accordingly: the reading pair
/// under a page, the panel's pair anywhere else.
class ReadingSurface extends InheritedWidget {
  const ReadingSurface({
    super.key,
    required this.colours,
    required super.child,
  });

  final ReadingColours colours;

  @override
  bool updateShouldNotify(ReadingSurface old) => old.colours != colours;
}

/// The colours the content under [context] should be drawn in.
///
/// The page's pair under a reading, the panel's anywhere else — the choice is
/// [appearanceOf]'s, made once, and this is only the arithmetic on top of it.
ReadingColours readingColours(BuildContext context, {bool watch = true}) =>
    ReadingColours.surface(appearanceOf(context, watch: watch));
