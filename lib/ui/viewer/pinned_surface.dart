import 'package:flutter/material.dart';

import '../plugins/plugin_table.dart' show appearanceOf;

/// The ground under something that is holding the top of a reading — a
/// heading, a table's head, the line a scope opened on.
///
/// **It is the page, and nothing else.** A held heading needs no ground of its
/// own and the text under it must not show through; what follows it reads as
/// the continuation it is, and there are no strips beyond the ones the design
/// asks for. So what is held stays exactly as it was drawn, standing on the
/// paper it was written on, and the reading passing beneath it is simply not
/// seen. No fill of its own, no hairline, no blur: a held heading is a heading
/// that stopped moving, not a toolbar that grew under it.
///
/// **Painted rather than clipped, and the difference is only in the how.** A
/// pinned heading is a sliver: the viewport paints the scrolling content and
/// then the header over it, and nothing in that arrangement lets a child clip
/// the viewport behind itself. Laying the page's own colour down is the same
/// answer to the eye — the text under the heading is gone rather than dimmed —
/// and it needs neither a second scroll view nor the headings lifted out of the
/// one they belong to.
///
/// What was here before and is worth not repeating: a lifted fill closed with a
/// hairline, blurred, at 0.62 opacity. Every part of that was reasoned about
/// carefully and the whole of it was a bar the design never asked for.
Widget pinnedSurface(
  BuildContext context, {
  required bool held,
  required Widget child,
}) {
  if (!held) return child;
  return CustomPaint(
    // **The surface it is standing on, not the reading's by name.** The same
    // strip holds up a file being read on a page and a file being read in a
    // panel, and those are two different fills; `appearanceOf` already answers
    // whichever one is behind this context.
    painter: _Erase(appearanceOf(context).effectivePanelBackground),
    child: child,
  );
}

/// Puts the page back where a held line stands, over whatever had been drawn
/// there.
///
/// `BlendMode.src` **replaces** rather than covers: the pixels behind the
/// heading become the page's own fill at the page's own opacity, which is the
/// same thing as the reading not having been drawn there at all. Painting the
/// same colour the ordinary way would lay a second coat over the page and read
/// as the bar the design does not have — on a window at 0.55 that is not a
/// subtlety, it is a visible band.
class _Erase extends CustomPainter {
  const _Erase(this.page);

  final Color page;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..color = page
          ..blendMode = BlendMode.src,
      );

  @override
  bool shouldRepaint(_Erase old) => old.page != page;
}
