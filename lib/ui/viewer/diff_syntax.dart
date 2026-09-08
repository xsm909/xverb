import 'package:flutter/material.dart';

import '../../core/settings/appearance_settings.dart';
import 'reading_colours.dart';

/// Colouring a unified diff — the thing `git diff` prints.
///
/// A diff read in one colour is a wall of text with plus and minus signs in
/// it. What makes it readable is that the two sides are told apart before a
/// word of it is read, which is a job for colour and nothing else.
///
/// Beside `json_syntax.dart` rather than inside it: they answer to the same
/// `language` hint on a text answer, and each is a small pure function of a
/// string, which is what makes both of them testable without a widget.

/// What a line of a diff is.
enum DiffPart {
  /// `--- a/x` and `+++ b/x`: which files this is about.
  file,

  /// `@@ -1,4 +1,6 @@`: where in them.
  hunk,

  added,
  removed,

  /// Carried over unchanged, and the reason a diff is readable at all.
  context,
}

/// [line] as one of the five. The first character decides, as it does in every
/// tool that has ever printed one — with the file headers checked first,
/// because they begin with the same characters as an added and a removed line.
DiffPart partOf(String line) {
  if (line.startsWith('+++ ') || line.startsWith('--- ')) return DiffPart.file;
  if (line.startsWith('@@')) return DiffPart.hunk;
  if (line.startsWith('+')) return DiffPart.added;
  if (line.startsWith('-')) return DiffPart.removed;
  return DiffPart.context;
}

/// The colours a diff is drawn in.
///
/// **Green and red, and not from the palette** — the one place in this
/// application where that is the right answer. Everywhere else a colour is the
/// user's choice pressed out of the preview; here the two colours *are* the
/// meaning, and every tool that prints a diff has agreed on them for forty
/// years. A diff drawn in somebody's accent and marked colours would be a diff
/// nobody can read at a glance, which is the only thing it is for.
///
/// Two pairs rather than one, because a green that reads on a dark panel is
/// invisible on a light one. Which pair is decided by what is behind them, not
/// by the theme's own idea of itself: a panel can be light under a dark
/// application.
class DiffColours {
  const DiffColours({
    required this.added,
    required this.removed,
    required this.hunk,
    required this.file,
    required this.context,
  });

  /// The two sides are read off the *page*, not the panel: green and red have
  /// to carry on whatever the file is being read on, and a diff shown on a
  /// pale page under a dark listing was the case that got this wrong.
  factory DiffColours.of(AppearanceSettings theme) {
    final page = ReadingColours.surface(theme);
    final dark = page.isDark;
    return DiffColours(
      added: dark ? const Color(0xFF7EE787) : const Color(0xFF1A7F37),
      removed: dark ? const Color(0xFFFF7B72) : const Color(0xFFCF222E),
      // The one line of a diff that is neither side: where in the file this
      // is. The accent, because it is the application's own voice.
      hunk: theme.accentColor,
      file: page.ink,
      context: page.quiet,
    );
  }

  final Color added;
  final Color removed;
  final Color hunk;
  final Color file;
  final Color context;

  Color colourOf(DiffPart part) => switch (part) {
        DiffPart.added => added,
        DiffPart.removed => removed,
        DiffPart.hunk => hunk,
        DiffPart.file => file,
        DiffPart.context => context,
      };
}

/// [source] as one span per line, coloured by what the line is.
///
/// A span per line rather than per run: every line of a diff is one thing all
/// the way across, and the newline is kept inside the span so the text is the
/// file it came from, character for character.
TextSpan diffSpans(String source, TextStyle base, DiffColours colours) {
  // Two steps heavier than the body, for the one line that says where in the
  // file this is. Taken from whatever the body is drawn at, so it follows the
  // interface weight rather than pinning a number of its own.
  final heading = shiftFontWeight(base.fontWeight ?? FontWeight.w400, 2);
  final lines = source.split('\n');

  return TextSpan(
    children: [
      for (var i = 0; i < lines.length; i++)
        () {
          final part = partOf(lines[i]);
          return TextSpan(
            // The newline stays inside the span, so the text drawn is the
            // text that came in, character for character.
            text: i == lines.length - 1 ? lines[i] : '${lines[i]}\n',
            style: base.copyWith(
              color: colours.colourOf(part),
              fontWeight: part == DiffPart.hunk ? heading : base.fontWeight,
            ),
          );
        }(),
    ],
  );
}
