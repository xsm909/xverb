import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/settings/appearance_settings.dart';
import '../widgets/hint.dart';
import '../viewer/reading_colours.dart';

/// Something in the preview that has a colour of its own.
///
/// Pressing one is the same as finding its row in the list below — which is
/// the point: the colours are named after what they are, and the preview is
/// where you can see which is which.
enum PreviewTarget {
  panel,
  header,
  fileText,
  directoryText,
  marked,
  cursor,
  accent,
  window,
  windowHeader,

  /// The strip under the panels, and the ordinary text on it.
  ///
  /// **The preview grew a console rather than these two becoming an
  /// exception.** A colour in this application is something you press where it
  /// is used ([[appearance-colours-are-pressed]]), and the answer to "but the
  /// preview has no console in it" is to put one there — which is also the
  /// answer to the same question the next colour will ask.
  console,
  consoleText,

  /// The title *written on* that strip, as against the strip itself. Pressing
  /// the word picks the one, pressing the rest of the bar picks the other.
  windowHeaderText,

  /// What is written on the header strips — the column headings, the path, the
  /// status line. Same arrangement as the dialog's title: press the word for
  /// the ink, press the bar around it for the background.
  headerText,

  /// The surface a menu is drawn on, and the rows written on it.
  ///
  /// **The preview grew a menu**, the way it grew a console, once the menu had
  /// a colour pair of its own. A colour in this application is pressed where it
  /// is used, so the answer to "the preview has no menu in it" is to put one
  /// there.
  menu,
  menuText,

  /// The page a file is *read* on, and the ink on it.
  ///
  /// **The preview grew a page**, the way it grew a console and then a menu,
  /// and for the third time the same answer: a colour in this application is
  /// pressed where it is used, so the answer to "the preview has no reading in
  /// it" is to put one there — two settings, and they decide the palette a
  /// file is read in.
  ///
  /// The plaque, the rule and the quiet line drawn beside them are not targets
  /// of their own and never will be: they are the ink at a distance, worked out
  /// in [ReadingColours] from these two.
  reading,
  readingText,

  /// The bubble that says what something is when the pointer rests on it, and
  /// the writing in it.
  ///
  /// The fourth time the preview has grown a thing rather than a colour list
  /// growing a row — and the plainest case for it: a hint belongs to no
  /// surface, so the only way to judge its pair is to see it standing on one.
  hint,
  hintText,
}

/// A small standing-in panel, drawn with the settings being edited.
///
/// The settings window covers the panels it is describing, and the ones it
/// does not cover are showing whatever happens to be on disk — which is rarely
/// a marked file next to a cursor row next to a shaded one. This shows all of
/// them at once, so a colour can be judged where it is used rather than as a
/// chip in a list.
///
/// It takes [AppearanceSettings] directly rather than reading the store, so it
/// can also preview a scheme that has not been applied.
class AppearancePreview extends StatelessWidget {
  const AppearancePreview({super.key, required this.theme, this.onPick});

  final AppearanceSettings theme;

  /// Called with whatever was pressed. Null makes the preview a picture.
  final ValueChanged<PreviewTarget>? onPick;

  static const _rows = [
    (name: '..', ext: '', size: '[..]', kind: _Row.parent),
    (name: 'reports', ext: '', size: '<DIR>', kind: _Row.directory),
    (name: 'invoice', ext: 'pdf', size: '184 K', kind: _Row.cursor),
    (name: 'notes', ext: 'txt', size: '2.1 K', kind: _Row.plain),
    (name: 'holiday', ext: 'jpg', size: '3.4 M', kind: _Row.marked),
    (name: 'archive', ext: 'zip', size: '18 M', kind: _Row.plain),
  ];

  @override
  Widget build(BuildContext context) {
    final font = TextStyle(
      fontFamily: theme.fileFamily,
      fontSize: theme.fontSize,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
      children: [
        // The frame is the accent colour, so the frame is how you pick it.
        _pickable(
          PreviewTarget.accent,
          'Accent',
          Container(
            decoration: BoxDecoration(
              color: theme.panelBackground,
              borderRadius: BorderRadius.circular(
                AppearanceSettings.panelCornerRadius,
              ),
            ),
            // **The frame goes on last, and that is the whole fix.** It used to
            // be part of the decoration above, which a `Container` paints
            // *before* its child — and the clip below cuts the child to the
            // panel's **outer** edge, not to the inside of the frame. So at
            // each corner the header and status strips reached out over the
            // arc and painted it out: the two straight sides met with no curve
            // between them, and the corner read as broken. Measured at 20× on
            // 2026-08-13, and again after a save layer alone did not mend it —
            // the layer smoothed the cut edge, which was never the complaint.
            //
            // As `foregroundDecoration` the stroke lands on top of whatever the
            // child put there, which is also how the real panel draws its ring
            // (`file_panel.dart`) and why the real panel never had this.
            foregroundDecoration: BoxDecoration(
              border: Border.all(
                color: theme.accentColor,
                width: theme.panelBorderWidth.toDouble(),
              ),
              borderRadius: BorderRadius.circular(
                AppearanceSettings.panelCornerRadius,
              ),
            ),
            // What the border used to reserve for itself. Written out because
            // it is no longer in the decoration to be counted: without it the
            // listing would slide out under the frame and every row would grow
            // by the frame's width.
            padding: EdgeInsets.all(theme.panelBorderWidth.toDouble()),
            // Kept with the save layer: the clip is masked in whole device
            // pixels otherwise, and while the frame now covers that edge at the
            // corners, a one-pixel frame does not cover much. It is a small
            // static widget, which is the one place the layer costs nothing.
            clipBehavior: Clip.antiAliasWithSaveLayer,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _pickable(
                  PreviewTarget.header,
                  'Header background',
                  _header(font),
                ),
                for (var i = 0; i < _rows.length; i++) _row(i, font),
                // Empty listing, which is the only place the panel's own
                // colour can be pressed — everywhere else something is drawn
                // on top of it. It is also where the dialog sits.
                _pickable(
                  PreviewTarget.panel,
                  'Panel background',
                  const SizedBox(height: 62, width: double.infinity),
                ),
                _pickable(
                  PreviewTarget.header,
                  'Header background',
                  _status(font),
                ),
              ],
            ),
          ),
        ),
        // A menu over the listing, because that is where a menu is: the right
        // button opens one on a row, and the row underneath is what it has to
        // stay readable against.
        Positioned(right: 14, top: 34, child: _menu(font)),
        // And a hint on the other side, over the listing for the same reason:
        // it floats over whatever is underneath, and what is underneath is
        // what it has to be told apart from.
        Positioned(left: 14, top: 34, child: _hint(font)),
        // A dialog over the panels, because that is where dialogs are and
        // because their colour is the one thing a panel preview cannot show.
        Positioned(
          left: 26,
          right: 26,
          bottom: 8,
          child: _dialog(font),
        ),
      ],
        ),
        const SizedBox(height: 10),
        // And under the panel, the page that panel opens: Ctrl+Q on the row
        // the cursor is on. Below rather than over, because a reading *is* the
        // panel for as long as it is up — drawing it as something floating
        // would be the one thing about it that is not true.
        _reading(font),
      ],
    );
  }

  /// A file open for reading, in miniature: the strip with its name, a heading,
  /// a line of prose, a block of code and a line of comment.
  ///
  /// It shows the derived colours as much as the two chosen ones, which is the
  /// point of it — the plaque and the rule are the ink at a distance, and the
  /// only way to know whether they came out right is to see them next to the
  /// prose. The code on it is deliberately coloured from the *palette*: the
  /// keyword and the string are the listing's directory and marked colours, so
  /// the preview says out loud which colours the page governs and which it
  /// does not.
  Widget _reading(TextStyle font) {
    final page = ReadingColours.of(theme);

    return ClipRRect(
      borderRadius: BorderRadius.circular(
        AppearanceSettings.panelCornerRadius,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The viewer's own chrome, which is the header's colour — the same
          // pair as the strips above, pressed here as well because this is
          // also where it is used.
          _pickable(
            PreviewTarget.header,
            'Header background',
            Container(
              height: theme.chromeRowHeight,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.centerLeft,
              color: theme.headerBackground,
              child: Row(
                children: [
                  Icon(
                    Icons.arrow_back,
                    size: theme.fontSize,
                    color: theme.headerForeground,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _pickable(
                        PreviewTarget.headerText,
                        'Header text',
                        _cell(
                          'readme.md',
                          font,
                          theme.headerForeground,
                          1,
                          sizeDelta: -1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _pickable(
            PreviewTarget.reading,
            'Reading background',
            Container(
              color: page.paper,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The heading, and under it the rule the top two levels are
                  // drawn with — which is the ink at a fifth, and the first
                  // place a badly chosen pair shows itself.
                  _cell(
                    tr('Extensions'),
                    font,
                    page.ink,
                    1,
                    sizeDelta: 2,
                    weightOverride: theme.strongFontWeight,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 3, bottom: 5),
                    child: Container(height: 1, color: page.rule),
                  ),
                  // The ink is pressed on a word of the prose, not on the page
                  // around it: an Align keeps the detector the size of what it
                  // is about, so the paper can still be reached. Same argument
                  // as the dialog's title.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _pickable(
                      PreviewTarget.readingText,
                      'Reading text',
                      _cell(
                          tr('A plugin is a folder with a'), font, page.ink, 1),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // The plaque. Nothing here is a setting: the fill is the ink
                  // at a fifteenth over the paper and the edge is the rule,
                  // while the two words on it come from the palette.
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
                    decoration: BoxDecoration(
                      color: page.plaque,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: page.rule),
                    ),
                    child: Row(
                      children: [
                        _cell(
                          'import',
                          font,
                          theme.directoryColor,
                          1,
                          sizeDelta: -1,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: _cell(
                            "'plugin.json'",
                            font,
                            theme.markedColor,
                            1,
                            sizeDelta: -1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 5),
                  // A comment: the ink at a little under half, and the thing
                  // that disappears first when the pair is too close together.
                  _cell(tr('# and an entry script'), font, page.faint, 1,
                      sizeDelta: -1),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(TextStyle font) => Container(
        height: theme.chromeRowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        color: theme.headerBackground,
        child: Row(
          children: [
            // The column header is one of the places the strong weight goes, so
            // the preview draws it at the strong weight too.
            //
            // The first heading is where the header's *ink* is pressed, the way
            // the dialog's title is: Align, so the detector is the size of the
            // word and the bar around it still reaches the background — see the
            // note on the dialog's title for what an Expanded did there.
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _pickable(
                  PreviewTarget.headerText,
                  'Header text',
                  _cell(
                    tr('Name'),
                    font,
                    theme.headerForeground,
                    0.7,
                    weightOverride: theme.strongFontWeight,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 40,
              child: _cell(
                'Ext',
                font,
                theme.headerForeground,
                0.7,
                weightOverride: theme.strongFontWeight,
              ),
            ),
            SizedBox(
              width: 64,
              child: _cell(
                'Size',
                font,
                theme.headerForeground,
                0.7,
                align: TextAlign.right,
                weightOverride: theme.strongFontWeight,
              ),
            ),
          ],
        ),
      );

  Widget _status(TextStyle font) => Container(
        height: theme.chromeRowHeight,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.centerLeft,
        color: theme.headerBackground,
        child: _cell(
          tr('3.4 M / 21 M in 1 / 5 selected'),
          font,
          theme.markedColor,
          1,
          sizeDelta: -1,
        ),
      );

  /// The internal windows, in miniature: a title strip and a body.
  Widget _dialog(TextStyle font) {
    final foreground = theme.panelForeground;
    final titleText = theme.effectiveWindowHeaderForeground;

    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(6),
      color: theme.effectiveWindowBackground,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _pickable(
            PreviewTarget.windowHeader,
            'Dialog title bar',
            Container(
              height: theme.chromeRowHeight,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: theme.effectiveWindowHeaderBackground,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(6),
                ),
              ),
              child: Row(
                children: [
                  // Nested inside the strip's own pickable, so the word takes
                  // the press and the bar around it takes the rest.
                  //
                  // The Align is what makes that true. `_pickable` hit-tests
                  // opaque, and an opaque detector handed an Expanded fills the
                  // whole width of the strip — so every press on the bar landed
                  // on the *text* target and the title background could not be
                  // reached at all. Align gives the child loose constraints, so
                  // the detector ends up the size of the word it is on.
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _pickable(
                        PreviewTarget.windowHeaderText,
                        'Dialog title text',
                        _cell('Rename', font, titleText, 1, sizeDelta: -1),
                      ),
                    ),
                  ),
                  Icon(Icons.close, size: theme.fontSize, color: titleText),
                ],
              ),
            ),
          ),
          _pickable(
            PreviewTarget.window,
            'Dialog background',
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: theme.chromeRowHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: foreground.withValues(alpha: 0.3),
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: _cell(
                        'invoice.pdf',
                        font,
                        foreground,
                        1,
                        sizeDelta: -1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.accentColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: _cell(
                      'OK',
                      font,
                      theme.accentColor.computeLuminance() > 0.5
                          ? Colors.black
                          : Colors.white,
                      1,
                      sizeDelta: -1,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _console(font),
        ],
      ),
    );
  }

  /// The strip under the panels: a prompt, a line of output, and nothing else.
  ///
  /// Two things are pressable here and they are different questions — the fill
  /// and the *default* ink, which is what a line is written in when it is not
  /// a prompt, a failure or a remark.
  Widget _console(TextStyle font) {
    final ink = theme.effectiveConsoleForeground;

    return _pickable(
      PreviewTarget.console,
      'Console background',
      Container(
        color: theme.effectiveConsoleBackground,
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _cell('> dir', font, theme.accentColor, 1, sizeDelta: -2),
            Align(
              alignment: Alignment.centerLeft,
              child: _pickable(
                PreviewTarget.consoleText,
                'Console text',
                _cell(tr('3 files, 1 folder'), font, ink, 1, sizeDelta: -2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What the pointer resting on something puts on the screen.
  ///
  /// Drawn as a picture here rather than waited for, so the pair can be judged
  /// without hovering and holding still — though hovering *this* shows a real
  /// one in the same colours, which is a fair second opinion.
  Widget _hint(TextStyle font) => _pickable(
    PreviewTarget.hint,
    'Hint background',
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.hintBackground,
        borderRadius: BorderRadius.circular(4),
        // The edge is the ink at a fifth, as it is in the bubble itself.
        border: Border.all(
          color: theme.hintForeground.withValues(alpha: 0.18),
        ),
      ),
      // The ink is pressed on the words, the fill on the padding round them —
      // the same arrangement as the menu's and the dialog's title.
      child: Align(
        alignment: Alignment.centerLeft,
        child: _pickable(
          PreviewTarget.hintText,
          'Hint text',
          _cell(tr('Copy  F5'), font, theme.hintForeground, 1, sizeDelta: -1),
        ),
      ),
    ),
  );

  /// A menu in miniature: a highlighted row and a plain one.
  ///
  /// Two things are pressable and they are different questions — the surface
  /// and the ink the rows are written in. Drawn at the menu's own opacity over
  /// the panel, so what is judged here is what will be seen: a menu at 60% on a
  /// dark listing is not the colour it was picked as.
  Widget _menu(TextStyle font) {
    final ink = theme.effectiveMenuForeground;

    Widget row(String label, {bool highlighted = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      color: highlighted
          ? theme.accentColor.withValues(alpha: 0.85)
          : Colors.transparent,
      child: _cell(
        label,
        font,
        highlighted
            ? (theme.accentColor.computeLuminance() > 0.5
                  ? Colors.black
                  : Colors.white)
            : ink,
        1,
        sizeDelta: -1,
      ),
    );

    return _pickable(
      PreviewTarget.menu,
      'Menu background',
      Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        color: Color.alphaBlend(
          theme.effectiveMenuBackground.withValues(alpha: theme.menuOpacity),
          theme.panelBackground,
        ),
        child: SizedBox(
          width: 116,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              row('Copy', highlighted: true),
              // The ink is pressed on a word, not on the strip: an Align keeps
              // the detector the size of what it is about, so the surface
              // around it can still be reached. Same argument as the dialog's
              // title.
              Align(
                alignment: Alignment.centerLeft,
                child: _pickable(
                  PreviewTarget.menuText,
                  'Menu text',
                  row('View'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(int index, TextStyle font) {
    final row = _rows[index];
    final striped = theme.alternateRowShading && index.isOdd;

    final colour = row.kind == _Row.cursor && theme.invertCursorText
        ? theme.cursorForeground
        : switch (row.kind) {
            _Row.directory || _Row.parent => theme.directoryColor,
            _Row.marked => theme.markedColor,
            _ => theme.panelForeground,
          };
    final background = row.kind == _Row.cursor
        ? theme.cursorColor
        : striped
        ? theme.alternateRowColor
        : Colors.transparent;

    final (target, label) = switch (row.kind) {
      _Row.cursor => (PreviewTarget.cursor, 'Cursor row'),
      _Row.marked => (PreviewTarget.marked, 'Marked entries'),
      _Row.directory || _Row.parent => (
          PreviewTarget.directoryText,
          'Directory text',
        ),
      _Row.plain => (PreviewTarget.fileText, 'File text'),
    };

    return _pickable(
      target,
      label,
      Container(
        color: background,
        padding: EdgeInsets.symmetric(
          horizontal: 6,
          vertical: theme.density.verticalPadding,
        ),
        child: Row(
          children: [
            Icon(
              switch (row.kind) {
                _Row.parent => Icons.subdirectory_arrow_left,
                _Row.directory => Icons.folder,
                _ => Icons.insert_drive_file_outlined,
              },
              size: theme.fontSize + 2,
              color: colour,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _cell(
                row.name,
                font,
                colour,
                1,
                weightOverride:
                    row.kind == _Row.directory || row.kind == _Row.parent
                    ? theme.directoryFontWeight
                    : theme.fileFontWeight,
              ),
            ),
            SizedBox(width: 40, child: _cell(row.ext, font, colour, 1)),
            SizedBox(
              width: 64,
              child: _cell(row.size, font, colour, 1, align: TextAlign.right),
            ),
          ],
        ),
      ),
    );
  }

  /// Makes one part of the preview answer to a press.
  ///
  /// Without [onPick] this adds nothing at all — no gesture, no cursor, no
  /// tooltip — so the preview stays a picture wherever it is only illustrating
  /// something, such as a scheme that has not been applied.
  Widget _pickable(PreviewTarget target, String label, Widget child) {
    final pick = onPick;
    if (pick == null) return child;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => pick(target),
        child: Hint(
          message: '${tr(label)}…',
          wait: const Duration(milliseconds: 600),
          child: child,
        ),
      ),
    );
  }

  Widget _cell(
    String text,
    TextStyle font,
    Color colour,
    double opacity, {
    TextAlign? align,
    FontWeightSpec? weightOverride,
    double sizeDelta = 0,
  }) {
    final weight = weightOverride ?? theme.fileFontWeight;
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: font.copyWith(
        color: colour.withValues(alpha: colour.a * opacity),
        fontSize: font.fontSize! + sizeDelta,
        // The weights the listing itself uses, not a fixed pair standing in for
        // them. The preview is where a weight is judged — the whole reason it
        // exists is that a family without the face you asked for draws the one
        // it has, and there is no way to know that but to look.
        fontWeight: weight.weight,
      ),
    );
  }
}

enum _Row { parent, directory, plain, cursor, marked }
