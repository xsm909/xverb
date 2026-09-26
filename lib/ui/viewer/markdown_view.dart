import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/document_pictures.dart';
import '../../core/reading/reading_store.dart';
import '../keyboard_focus.dart';
import '../motion.dart';
import '../widgets/context_menu.dart';
import '../widgets/hint.dart';
import 'document_memory.dart';
import 'note_editor.dart';
import 'pinned_surface.dart';
import 'reading_colours.dart';
import 'reading_link.dart';

/// The marker colours, the hues a reader on a Mac or an iPhone already knows
/// from Books: yellow, green, blue, pink, purple.
const List<Color> kMarkerColours = [
  Color(0xFFFFD60A),
  Color(0xFF30D158),
  Color(0xFF0A84FF),
  Color(0xFFFF375F),
  Color(0xFFBF5AF2),
];

const List<String> _markerNames = ['Yellow', 'Green', 'Blue', 'Pink', 'Purple'];

/// What a marker lays under the words: its colour, thin enough that the ink
/// on top reads on a light page and a dark one alike.
Color markerFill(int colour) =>
    kMarkerColours[colour.clamp(0, kMarkerColours.length - 1)]
        .withValues(alpha: 0.38);

/// A passage as Markdown to paste somewhere else: the words as a quotation,
/// each line of them quoted, and the note under it as a paragraph of its own.
String markdownQuote(String passage, [String note = '']) {
  final quoted = [
    for (final line in passage.trim().split('\n')) '> ${line.trim()}',
  ].join('\n>\n');
  return note.trim().isEmpty ? '$quoted\n' : '$quoted\n\n${note.trim()}\n';
}

/// A line of body text in anything that is not a document read as a book —
/// a README, a note — as it has always been drawn.
const double kDefaultLineHeight = 1.5;

/// A line's height for a line spacing as a word processor counts it:
/// single is the font's own line, about 1.2 of its size, and 1.5 is half as
/// tall again.
double lineHeightFor(double spacing) => 1.2 * spacing;

/// The line height of the reading being drawn, handed down to its blocks.
class _LineHeight extends InheritedWidget {
  const _LineHeight({required this.value, required super.child});

  final double value;

  @override
  bool updateShouldNotify(_LineHeight old) => old.value != value;
}

double _lineHeight(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_LineHeight>()?.value ??
    kDefaultLineHeight;

/// A book's page: how wide a line of a document is allowed to be, in points
/// at a zoom of one. About seventy letters of body text — the length a line
/// is set at in print, because the eye loses its place going back from a
/// longer one.
const double kBookMeasure = 600;

/// The narrowest a page of a two-page spread may be, in points at a zoom of
/// one. A window wide enough for two of these shows a spread, as a book
/// reader does, rather than one page with room to spare either side.
const double kSpreadPageNarrowest = 440;

/// A small, dependency-free Markdown renderer.
///
/// It covers the CommonMark subset that actually turns up in files people open
/// in a file manager: headings, emphasis, code, lists, quotes, rules, links and
/// pipe tables. Anything it does not understand falls through as literal text,
/// so a document never disappears because of one exotic construct.
///
/// A full CommonMark implementation belongs in a plugin, not here — this is a
/// render primitive, and primitives stay small on purpose.
class MarkdownView extends StatefulWidget {
  const MarkdownView({
    super.key,
    required this.source,
    this.textScale = 1.0,
    this.controller,
    this.link,
    this.pictures,
    this.measure,
    this.memory,
    this.paged = false,
    this.lineHeight = kDefaultLineHeight,
  });

  final String source;
  final double textScale;

  /// Whoever is driving the scrolling from outside — the arrow keys, say.
  final ScrollController? controller;

  /// The line to the structure panel: which line of the source is at the top,
  /// and "take me to this one". Null where nothing is standing beside the
  /// document.
  final ReadingLink? link;

  /// Who holds the pictures the document names, or null — and then a picture
  /// is shown by its caption, as it always was.
  final DocumentPictures? pictures;

  /// How wide a line of the reading may be, in points at a zoom of one — a
  /// book's page rather than the window's width — or null for the whole
  /// width. The column stands in the middle, grows with the zoom, and moves
  /// between the two over [kReadingMeasureDuration].
  final double? measure;

  /// Where this document was left and what is marked in it, or null for a
  /// reading nobody keeps anything about. See [DocumentMemory].
  final DocumentMemory? memory;

  /// How tall a line of body text is, as a multiple of its size — what the
  /// reader's line spacing comes to. See [lineHeightFor].
  final double lineHeight;

  /// Read a page at a time, as a book reader does — two pages side by side
  /// where the window has room for them — rather than scrolled.
  final bool paged;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  final GlobalKey _list = GlobalKey();

  late _Document _document = _parseBlocks(splitLines(widget.source));
  List<_Block> get _blocks => _document.blocks;

  /// Which block the panel asked for, and the key that finds it once the list
  /// has built it. Null while nothing has been asked for.
  int? _target;
  final GlobalKey _targetKey = GlobalKey();

  /// Which heading is holding the top of the page, by its line in the source.
  int? _pinnedLine;

  /// Whether a jump is in flight. **Every section passed on the way holds the
  /// top for a moment**, and each would say so; while this is set they are not
  /// listened to, and the arrival has the last word.
  bool _travelling = false;

  /// The blocks the list has built, by number — which is what is on screen
  /// and just around it. Asked which one stands at the top.
  final Map<int, BuildContext> _built = {};

  /// Each block's text as it is drawn — the words of a link and of a code pill
  /// included — which is what a place and a highlight are counted in.
  List<String>? _plainCache;
  List<String> get _plainTexts =>
      _plainCache ??= [for (final block in _blocks) block.plain];

  /// Each built block's selection, by number: what a selection covers is
  /// asked of these when the pointer lets go.
  final Map<int, SelectionListenerNotifier> _selections = {};

  final GlobalKey<SelectionAreaState> _selectionArea = GlobalKey();

  /// Where the pointer last went down, to tell a click from a drag.
  Offset? _pressedAt;

  /// The marked passages laid on the blocks they cover, worked out once for
  /// each set of marks and each reading.
  Map<int, List<_Mark>>? _marksCache;

  /// What was selected when the menu opened. **Taken then, not when a colour
  /// is chosen**: the menu takes the keyboard, and a selection gives itself up
  /// with the focus — by the time a colour was pressed there was nothing
  /// selected to mark. Drawn in the selection's colour while the menu is up,
  /// so the passage being coloured stays in sight.
  List<({int block, int start, int end})>? _pending;

  @override
  void initState() {
    super.initState();
    _attach(widget.link);
    widget.memory?.addListener(_marksChanged);
    if (widget.paged) {
      _openPaged();
    } else {
      _returnToPlace();
    }
  }

  void _marksChanged() {
    if (mounted) setState(() => _marksCache = null);
  }

  Map<int, List<_Mark>> get _marks => _marksCache ??= _layMarks();

  /// Where each highlight falls now: its start found again by its words, its
  /// end kept the same distance from it, and the blocks between filled whole.
  Map<int, List<_Mark>> _layMarks() {
    final memory = widget.memory;
    final found = <int, List<_Mark>>{};
    if (memory == null) return found;
    final texts = _plainTexts;
    for (final part in _pending ?? const <({int block, int start, int end})>[]) {
      (found[part.block] ??= []).add(
        _Mark(part.start, part.end, 0, '', pending: true),
      );
    }
    for (final h in memory.highlights) {
      final start = ReadingDocument.settle(h.start, texts);
      if (start == null) continue;
      final shift = start.block - h.start.block;
      final endBlock = math.min(h.end.block + shift, texts.length - 1);
      final endOffset = h.end.block == h.start.block
          ? start.offset + (h.end.offset - h.start.offset)
          : h.end.offset;
      for (var block = start.block; block <= endBlock; block++) {
        final length = texts[block].length;
        final from = block == start.block ? start.offset : 0;
        final to = block == endBlock ? endOffset : length;
        if (to <= from) continue;
        (found[block] ??= []).add(_Mark(
          from.clamp(0, length),
          to.clamp(0, length),
          h.colour,
          h.id,
          noted: block == endBlock && h.note.isNotEmpty ? h.note : null,
        ));
      }
    }
    return found;
  }

  /// The text of [block] as it was drawn inside [box] — the paragraph whose
  /// words are the block's own, not a list item's bullet beside it.
  RenderParagraph? _bodyOf(RenderBox box, int block) {
    final length = _plainTexts[block].length;
    RenderParagraph? body;
    void visit(RenderObject node) {
      if (body != null) return;
      if (node is RenderParagraph) {
        if (node.text.toPlainText().length == length) body = node;
        return;
      }
      node.visitChildren(visit);
    }

    box.visitChildren(visit);
    return body;
  }

  /// The mark under [point], if it is on one.
  ///
  /// **Asked, not listened for.** A mark used to carry a tap of its own on
  /// its words, and a selection will not begin on words that answer a tap —
  /// that is how a link stays pressable — so no marked letter could start a
  /// selection, and a passage could not be marked again from where it began.
  /// The press is found here instead: the character under it, in the text of
  /// whichever block it fell in, and the mark that covers that character.
  String? _markAt(Offset point) {
    for (final built in [_built, _spread.leftBuilt, _spread.rightBuilt]) {
      for (final entry in built.entries) {
        final marks = _marks[entry.key];
        if (marks == null || marks.isEmpty) continue;
        final box = entry.value.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        final inside = box.globalToLocal(point);
        if (!(Offset.zero & box.size).contains(inside)) continue;
        final paragraph = _bodyOf(box, entry.key);
        if (paragraph == null) continue;
        final local = paragraph.globalToLocal(point);
        if (!(Offset.zero & paragraph.size).contains(local)) continue;
        final at = paragraph.getPositionForOffset(local).offset;
        for (final mark in marks) {
          if (!mark.pending && mark.start <= at && at < mark.end) return mark.id;
        }
      }
    }
    return null;
  }

  /// What the selection covers, block by block, in the offsets the marks are
  /// counted in.
  List<({int block, int start, int end})> _selected() {
    // A block cut by a page's end is on two pages, and selected on each in
    // part: the two are one selection of it.
    final byBlock = <int, ({int start, int end})>{};
    for (final map in [
      _selections,
      _spread.leftSelections,
      _spread.rightSelections,
    ]) {
      for (final entry in map.entries) {
        final notifier = entry.value;
        if (!notifier.registered) continue;
        final selection = notifier.selection;
        final range = selection.range;
        if (selection.status == SelectionStatus.none || range == null) continue;
        final length = _plainTexts[entry.key].length;
        final start = math.min(range.startOffset, range.endOffset).clamp(0, length);
        final end = math.max(range.startOffset, range.endOffset).clamp(0, length);
        if (end <= start) continue;
        final had = byBlock[entry.key];
        byBlock[entry.key] = had == null
            ? (start: start, end: end)
            : (start: math.min(had.start, start), end: math.max(had.end, end));
      }
    }
    final found = [
      for (final entry in byBlock.entries)
        (block: entry.key, start: entry.value.start, end: entry.value.end),
    ];
    found.sort((a, b) => a.block.compareTo(b.block));
    return found;
  }

  /// Marks [parts] — what is selected now, when none are given — in
  /// [colour], and lets the selection go.
  Highlight? _mark(int colour, [List<({int block, int start, int end})>? given]) {
    final memory = widget.memory;
    final parts = given ?? _selected();
    if (memory == null || parts.isEmpty) return null;
    final texts = _plainTexts;
    var from = (block: parts.first.block, offset: parts.first.start);
    var to = (block: parts.last.block, offset: parts.last.end);
    int order(({int block, int offset}) a, ({int block, int offset}) b) =>
        a.block != b.block ? a.block.compareTo(b.block) : a.offset.compareTo(b.offset);

    // Where every mark lies now, from its first character to its last.
    final lying = <String, ({({int block, int offset}) from, ({int block, int offset}) to})>{};
    for (final entry in _marks.entries) {
      for (final mark in entry.value) {
        if (mark.pending || mark.id.isEmpty) continue;
        final start = (block: entry.key, offset: mark.start);
        final end = (block: entry.key, offset: mark.end);
        final had = lying[mark.id];
        lying[mark.id] = had == null
            ? (from: start, to: end)
            : (
                from: order(start, had.from) < 0 ? start : had.from,
                to: order(end, had.to) > 0 ? end : had.to,
              );
      }
    }

    // **A mark laid over another takes it in**: one passage, not two over
    // the same words. The new colour wins, and no note is lost — the notes of
    // what was taken in are kept, one after another. Gone round until nothing
    // more is touched, because taking one in can reach the next.
    final absorbed = <Highlight>[];
    var grew = true;
    while (grew) {
      grew = false;
      for (final other in memory.highlights) {
        if (absorbed.any((h) => h.id == other.id)) continue;
        final at = lying[other.id];
        if (at == null) continue;
        if (order(at.to, from) >= 0 && order(at.from, to) <= 0) {
          absorbed.add(other);
          if (order(at.from, from) < 0) from = at.from;
          if (order(at.to, to) > 0) to = at.to;
          grew = true;
        }
      }
    }

    final opening = texts[from.block].substring(from.offset);
    final highlight = Highlight(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      start: ReadingAnchor(
        from.block,
        from.offset,
        opening.substring(0, math.min(40, opening.length)),
      ),
      end: ReadingAnchor(to.block, to.offset, ''),
      text: [
        for (var block = from.block; block <= to.block; block++)
          texts[block].substring(
            block == from.block ? from.offset : 0,
            block == to.block ? to.offset : texts[block].length,
          ),
      ].where((piece) => piece.isNotEmpty).join('\n'),
      colour: colour,
      note: [
        for (final other in absorbed)
          if (other.note.trim().isNotEmpty) other.note.trim(),
      ].join('\n\n'),
      made: DateTime.now(),
    );
    for (final other in absorbed) {
      memory.remove(other.id);
    }
    memory.add(highlight);
    _selectionArea.currentState?.selectableRegion.clearSelection();
    return highlight;
  }

  Future<void> _writeNote(Highlight highlight) async {
    final memory = widget.memory;
    if (memory == null) return;
    final note = await promptForNote(
      context,
      passage: highlight.text,
      initialValue: highlight.note,
    );
    if (note == null) return;
    final current = memory.highlights.where((h) => h.id == highlight.id);
    if (current.isEmpty) return;
    memory.replace(current.first.copyWith(note: note.trim()));
  }

  Widget _swatch(int colour, {bool chosen = false}) => Center(
    child: Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: kMarkerColours[colour],
        shape: BoxShape.circle,
        border: chosen ? Border.all(color: Colors.white, width: 2) : null,
      ),
    ),
  );

  /// The menu a selection opens when the pointer lets go of it, the way a
  /// book reader's does: a colour, a note, a copy.
  Future<void> _offerMark(Offset at, {bool click = false}) async {
    final memory = widget.memory;
    if (memory == null || !mounted || _pending != null) return;
    final parts = _selected();
    if (parts.isEmpty) {
      // A press that did not move, on a marked passage, opens that mark.
      final id = click ? _markAt(at) : null;
      if (id != null) _openMark(id, at);
      return;
    }
    setState(() {
      _pending = parts;
      _marksCache = null;
    });
    final texts = _plainTexts;
    final words = [
      for (final part in parts) texts[part.block].substring(part.start, part.end),
    ].join('\n');
    await showAppContextMenu(
      context: context,
      globalPosition: at,
      nodes: [
        for (var c = 0; c < kMarkerColours.length; c++)
          MenuItem(
            tr(_markerNames[c]),
            leading: _swatch(c),
            accelerator: '${c + 1}',
            onSelected: () => _mark(c, parts),
          ),
        const MenuSeparator(),
        MenuItem(
          tr('Note…'),
          icon: Icons.sticky_note_2_outlined,
          accelerator: 'n',
          onSelected: () {
            final made = _mark(DocumentMemory.lastColour, parts);
            if (made != null) _writeNote(made);
          },
        ),
        MenuItem(
          tr('Copy'),
          icon: Icons.copy_outlined,
          accelerator: 'c',
          onSelected: () => Clipboard.setData(ClipboardData(text: words)),
        ),
        MenuItem(
          tr('Copy as Markdown'),
          icon: Icons.format_quote_outlined,
          accelerator: 'm',
          onSelected: () =>
              Clipboard.setData(ClipboardData(text: markdownQuote(words))),
        ),
      ],
    );
    if (!mounted) return;
    setState(() {
      _pending = null;
      _marksCache = null;
    });
  }

  /// The menu a marked passage opens when it is pressed: another colour, its
  /// note, a copy, or taking the mark away.
  void _openMark(String id, Offset at) {
    final memory = widget.memory;
    if (memory == null) return;
    final found = memory.highlights.where((h) => h.id == id);
    if (found.isEmpty) return;
    final highlight = found.first;
    unawaited(showAppContextMenu(
      context: context,
      globalPosition: at,
      nodes: [
        for (var c = 0; c < kMarkerColours.length; c++)
          MenuItem(
            tr(_markerNames[c]),
            leading: _swatch(c),
            checked: c == highlight.colour,
            accelerator: '${c + 1}',
            onSelected: () => memory.replace(highlight.copyWith(colour: c)),
          ),
        const MenuSeparator(),
        MenuItem(
          highlight.note.isEmpty ? tr('Note…') : tr('Edit note…'),
          icon: Icons.sticky_note_2_outlined,
          accelerator: 'n',
          onSelected: () => _writeNote(highlight),
        ),
        MenuItem(
          tr('Copy'),
          icon: Icons.copy_outlined,
          accelerator: 'c',
          onSelected: () =>
              Clipboard.setData(ClipboardData(text: highlight.text)),
        ),
        MenuItem(
          tr('Copy as Markdown'),
          icon: Icons.format_quote_outlined,
          accelerator: 'm',
          onSelected: () => Clipboard.setData(
            ClipboardData(text: markdownQuote(highlight.text, highlight.note)),
          ),
        ),
        MenuItem(
          tr('Remove highlight'),
          icon: Icons.format_color_reset_outlined,
          accelerator: 'd',
          onSelected: () => memory.remove(id),
        ),
      ],
    ));
  }

  /// H marks the selection in the last colour used, N marks it and asks for
  /// a note — the keyboard's way to the same two things the menu offers.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || widget.memory == null) return KeyEventResult.ignored;
    if (keyboardIsInAField()) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyH && _selected().isNotEmpty) {
      _mark(DocumentMemory.lastColour);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyN && _selected().isNotEmpty) {
      final made = _mark(DocumentMemory.lastColour);
      if (made != null) _writeNote(made);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Opens the document where it was left, at once: arriving somewhere by a
  /// glide through the whole book would be a movement that says nothing.
  void _returnToPlace() {
    final place = widget.memory?.place;
    if (place == null) return;
    final found = ReadingDocument.settle(place, _plainTexts);
    if (found == null || (found.block <= 0 && found.offset <= 0)) return;
    final length = _plainTexts[found.block].length;
    _target = found.block;
    _travelling = true;
    _bring(
      found.block,
      40,
      instant: true,
      within: length == 0 ? 0 : found.offset / length,
    );
  }

  /// Writes down which block stands at the top, once the scrolling has
  /// stopped.
  /// Writes down where the reading stands: the block across the top of the
  /// page and how far down it the top has come, as a character in its text —
  /// so a long paragraph is come back to at its line, not at its start.
  ///
  /// **Counted in the scroll's own units**, from where each built block is in
  /// the list, not from where it is on the screen: the list also keeps the
  /// first paragraph of every section it has laid out, far off the page, and
  /// on screen those have no honest position to be asked about.
  void _notePlace() {
    final memory = widget.memory;
    final controller = widget.controller;
    if (memory == null || _travelling || controller == null || !controller.hasClients) {
      return;
    }
    final top = controller.position.pixels;
    int? best;
    double bestTop = 0, bestHeight = 0;
    int? after;
    double afterTop = double.infinity;
    for (final entry in _built.entries) {
      final box = entry.value.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final start = _offsetOf(entry.value);
      if (start == null) continue;
      final end = start + box.size.height;
      if (start <= top && end > top) {
        if (best == null || start > bestTop) {
          best = entry.key;
          bestTop = start;
          bestHeight = box.size.height;
        }
      } else if (start > top && start < afterTop) {
        after = entry.key;
        afterTop = start;
      }
    }
    final block = best ?? after;
    if (block == null) return;
    final text = _plainTexts[block];
    var at = 0;
    if (best != null && bestHeight > 0 && text.isNotEmpty) {
      at = ((top - bestTop) / bestHeight * text.length).floor();
      // Back to the start of the word, so the quote is a quote.
      while (at > 0 && at < text.length && text[at - 1] != ' ') {
        at--;
      }
      at = at.clamp(0, text.length);
    }
    final rest = text.substring(at);
    memory.place = ReadingAnchor(block, at, rest.substring(0, math.min(40, rest.length)));
  }

  void _attach(ReadingLink? link) {
    link?.reveal = _goTo;
    link?.revealMark = _goToMark;
    link?.keys = widget.paged ? _pageKey : null;
    if (link == null) return;
    // Where the reading starts, before anything has been pinned: the panel
    // beside it has to light something up the moment it opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pinnedLine == null) link.report(0);
    });
  }

  @override
  void dispose() {
    if (widget.link?.reveal == _goTo) widget.link!.reveal = null;
    if (widget.link?.revealMark == _goToMark) widget.link!.revealMark = null;
    if (widget.link?.keys == _pageKey) widget.link!.keys = null;
    _wheelQuiet?.cancel();
    widget.memory?.removeListener(_marksChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(MarkdownView old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source ||
        old.textScale != widget.textScale ||
        old.lineHeight != widget.lineHeight) {
      _pageHeight = 0;
      _pageWidth = 0;
    }
    if (old.source != widget.source) {
      _document = _parseBlocks(splitLines(widget.source));
      _plainCache = null;
      _marksCache = null;
      _pinnedLine = null;
      _target = null;
    }
    if (old.link != widget.link) {
      if (old.link?.reveal == _goTo) old.link!.reveal = null;
      if (old.link?.revealMark == _goToMark) old.link!.revealMark = null;
      _attach(widget.link);
    }
    // Another document in the same place — the next file on the strip — is
    // opened where it was left, as the first one was.
    if (old.memory != widget.memory) {
      old.memory?.removeListener(_marksChanged);
      widget.memory?.addListener(_marksChanged);
      _marksCache = null;
      if (widget.paged) {
        _openPaged();
      } else {
        _returnToPlace();
      }
    } else if (old.paged != widget.paged) {
      // From one way of reading to the other, at the same place: what one
      // wrote down is what the other opens on.
      widget.link?.keys = widget.paged ? _pageKey : null;
      if (widget.paged) {
        _openPaged();
      } else {
        _returnToPlace();
      }
    }
  }

  /// The block that holds source line [line] — the last one that starts at or
  /// before it.
  int _blockAt(int line) {
    var found = 0;
    for (var i = 0; i < _document.lines.length; i++) {
      if (_document.lines[i] > line) break;
      found = i;
    }
    return found;
  }

  /// Takes the reader to the block holding [line].
  ///
  /// **A list that builds as it goes cannot be told to scroll to an item it
  /// has not built**, so this closes in: jump to where the item ought to be by
  /// what the list already knows of its own length, and once the item exists,
  /// finish exactly and gliding. Two or three frames, and it is over before
  /// anybody has read a word.
  /// Takes the reader to the passage marked [id], where it lies now.
  ///
  /// **The passage in the middle of the page**, not its paragraph at the top:
  /// a mark half way down a long paragraph would otherwise be brought to just
  /// below the bottom edge.
  void _goToMark(String id) {
    for (final entry in _marks.entries) {
      for (final mark in entry.value) {
        if (mark.id != id) continue;
        final length = _plainTexts[entry.key].length;
        if (widget.paged) {
          _seekTo(entry.key, length == 0 ? 0 : mark.start / length);
          return;
        }
        setState(() => _target = entry.key);
        _bring(
          entry.key,
          40,
          within: length == 0 ? 0 : mark.start / length,
          centred: true,
        );
        return;
      }
    }
  }

  void _goTo(int line) {
    final index = _blockAt(line);
    if (widget.paged) {
      _seekTo(index, 0);
      return;
    }
    setState(() => _target = index);
    _bring(index, 40);
  }

  /// Brings block [index] to the top of the page — [within] of the way down
  /// it, for a place in a long paragraph.
  ///
  /// **Steered by the blocks the list has already laid out.** A block not yet
  /// built has no position, so the list is moved to where it ought to be: from
  /// the nearest block that *has* one, at the average height of the blocks
  /// before it. Each move lays out new blocks nearer the target, so the guess
  /// closes in. The old guess — the block's share of the whole — landed on the
  /// same wrong page every time in a book whose paragraphs differ in length,
  /// and gave up there.
  void _bring(
    int index,
    int tries, {
    bool instant = false,
    double within = 0,
    bool centred = false,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_target != index) return;
      final controller = widget.controller;
      if (controller == null || !controller.hasClients) {
        if (tries > 0) {
          _bring(index, tries - 1,
              instant: instant, within: within, centred: centred);
          WidgetsBinding.instance.scheduleFrame();
        } else {
          _gaveUp();
        }
        return;
      }
      final position = controller.position;

      final target = _targetKey.currentContext;
      final offset = target == null ? null : _offsetOf(target);
      if (offset != null) {
        setState(() => _target = null);
        // Said when the travelling is over, not before it: on the way there
        // every section passed holds the top for a moment and says so, and the
        // last of those would otherwise be the answer.
        void arrived() {
          _travelling = false;
          _pinnedLine = _document.lines[index];
          widget.link?.report(_document.lines[index]);
        }

        _travelling = true;
        final box = target!.findRenderObject();
        final height = box is RenderBox && box.hasSize ? box.size.height : 0.0;
        // One pixel past where the section starts, not exactly on it: a
        // heading holds the top from the first pixel of its own section, and
        // landing on the boundary leaves the one before it holding.
        // Centred: the place a little above the middle, where the eye goes.
        final lift = centred ? position.viewportDimension * 0.4 : 0.0;
        final to = (offset + 1 + within * height - lift).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (instant || !motionOn(context)) {
          controller.jumpTo(to);
          arrived();
        } else {
          controller
              .animateTo(
                to,
                duration: motionOf(context, kOutlineJumpDuration),
                curve: kArrivingCurve,
              )
              .then((_) {
                if (mounted) arrived();
              });
        }
        return;
      }
      if (tries <= 0) {
        _gaveUp();
        return;
      }
      // The nearest block the list has laid out, and where it is.
      int? near;
      double nearAt = 0;
      for (final entry in _built.entries) {
        final at = _offsetOf(entry.value);
        if (at == null) continue;
        if (near == null || (entry.key - index).abs() < (near - index).abs()) {
          near = entry.key;
          nearAt = at;
        }
      }
      double guess;
      if (near != null && near > 0) {
        guess = nearAt + (index - near) * (nearAt / near);
      } else {
        final share = _blocks.isEmpty ? 0.0 : index / _blocks.length;
        guess = position.maxScrollExtent * share;
      }
      // Never the same place twice: if the guess stands still, a page's
      // length towards the target.
      if ((guess - position.pixels).abs() < 1) {
        final towards = near == null || index > near ? 1 : -1;
        guess = position.pixels + towards * position.viewportDimension * 0.8;
      }
      controller.jumpTo(
        guess.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      _bring(index, tries - 1,
          instant: instant, within: within, centred: centred);
    });
  }

  /// The block could not be reached: stop travelling, so the place goes on
  /// being written down from wherever the reader now is.
  void _gaveUp() {
    _travelling = false;
    if (mounted) setState(() => _target = null);
  }

  /// Where a block sits in the scroll, in the scroll's own units.
  ///
  /// **Asked of the sliver that holds it**, not of `ensureVisible`: a heading
  /// is a *pinned* sliver now, and a pinned sliver is at the top of the screen
  /// whenever it is built — so "make it visible" is already true and moves
  /// nothing. What is wanted is where its section begins, and the sliver knows
  /// that exactly: `precedingScrollExtent`, plus the child's own offset inside
  /// a list.
  static double? _offsetOf(BuildContext target) {
    var node = target.findRenderObject();
    var inside = 0.0;
    while (node != null) {
      final data = node.parentData;
      if (node is RenderSliver) {
        return node.constraints.precedingScrollExtent + inside;
      }
      if (data is SliverMultiBoxAdaptorParentData) {
        inside = data.layoutOffset ?? 0;
      }
      node = node.parent;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // **No ground of its own.** The page under a reading is the panel's, which
    // is as see-through as every other panel in the window. Painting a ground
    // here made the viewer a solid slab in a translucent window. A pinned
    // heading is told apart from the page by its own colour and its hairline
    // rather than by the page being opaque; see [pinnedSurface].
    final marking = widget.memory != null;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Listener(
        // The pointer letting go of a selection opens its menu, as a book
        // reader's does — after the frame, when the selection has settled.
        onPointerDown: !marking ? null : (event) => _pressedAt = event.position,
        onPointerUp: !marking
            ? null
            : (event) {
                if (event.kind == PointerDeviceKind.mouse &&
                    event.buttons != 0) {
                  return;
                }
                final at = event.position;
                final pressed = _pressedAt;
                final click = pressed != null && (at - pressed).distance < 4;
                WidgetsBinding.instance
                  ..addPostFrameCallback((_) => _offerMark(at, click: click))
                  ..scheduleFrame();
              },
        child: SelectionArea(
      key: _selectionArea,
      // A right press on a selection opens the same menu the left one's
      // letting go does, in place of the platform's own.
      contextMenuBuilder: !marking
          ? null
          : (context, region) => const SizedBox.shrink(),
      child: _LineHeight(
        value: widget.lineHeight,
        child: _MarksScope(
        marks: _marks,
        onNote: (id) {
          final found = widget.memory?.highlights.where((h) => h.id == id);
          if (found != null && found.isNotEmpty) _writeNote(found.first);
        },
        child: _PicturesScope(
        pictures: widget.pictures,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: widget.measure == null ? 0 : 1),
          duration: motionOf(context, kReadingMeasureDuration),
          curve: kArrivingCurve,
          builder: (context, narrow, _) => LayoutBuilder(
            builder: (context, room) {
              // The margin either side: the usual twenty, or as much as it
              // takes to bring the column down to the measure — and every
              // step between while it moves.
              // A scroll and pages are two ways of drawing the same reading,
              // and going from one to the other is shown as that: the one
              // fades and settles back as the other rises into its place.
              return AnimatedSwitcher(
                duration: motionOf(context, kReadingModeDuration),
                switchInCurve: kArrivingCurve,
                switchOutCurve: kLeavingCurve,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween(begin: 0.96, end: 1.0).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey(widget.paged),
                  child: widget.paged
                      ? _pages(context, room)
                      : _scrolled(context, room, narrow),
                ),
              );
            },
          ),
        ),
      ),
      ),
      ),
        ),
      ),
    );
  }

  /// The reading as one scroll, the column narrowed to [narrow] of the way
  /// towards the page's measure.
  Widget _scrolled(BuildContext context, BoxConstraints room, double narrow) {
    // The margin either side: the usual twenty, or as much as it takes to
    // bring the column down to the measure — and every step between while it
    // moves.
    final measure = (widget.measure ?? 0) * widget.textScale;
    final centred = math.max(_margin, (room.maxWidth - measure) / 2);
    final side = _margin + (centred - _margin) * narrow;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        // After the frame: the scroll has ended, but the list is still laid
        // out where it was until the next one.
        WidgetsBinding.instance
          ..addPostFrameCallback((_) {
            if (mounted) _notePlace();
          })
          ..scheduleFrame();
        return false;
      },
      child: CustomScrollView(
        key: _list,
        controller: widget.controller,
        slivers: _slivers(context, room.maxWidth - 2 * side, side),
      ),
    );
  }

  // --- Pages -------------------------------------------------------------

  /// The spread on screen: where it begins, and — once its left page has been
  /// laid out — where its pages end and where the spreads either side begin.
  late _Spread _spread = _Spread(const _At(0, 0), 0);
  int _generation = 0;

  /// Which way the last turn went — forward 1, back -1, a jump 0 — for which
  /// way the pages slide.
  int _turn = 0;

  /// A block being looked for — the place the book was left, a heading, a
  /// mark — and how far down it.
  ({int block, double within, int? char})? _seek;

  double _pageHeight = 0;
  double _pageWidth = 0;
  bool _twoPages = false;

  /// How tall each block is at the pages' present shape, as far as any page
  /// has laid it out. What a page puts above itself is measured by these.
  final Map<int, double> _heights = {};

  /// Where every page of the book begins, once the book has been gone
  /// through; null until then. **The same measure the pages are turned by**,
  /// run from the first page to the last out of sight, so a page's number is
  /// the page it is and a turn moves it by one.
  List<_At>? _pageStarts;

  /// Whether the book is being gone through, and which going-through it is:
  /// a window that changed its shape starts a new one.
  bool _counting = false;
  int _countingGeneration = 0;

  /// The page's margins: above, below — where the place in the book is said
  /// — and between the two of a spread.
  static const double _pageTop = 28;
  static const double _pageBottom = 40;
  static const double _pageGap = 64;

  double _wheel = 0;
  Timer? _wheelQuiet;
  bool _wheelSpent = false;

  /// Starts going through the book again — a window that changed its shape
  /// has changed every page.
  void _recount() {
    _pageStarts = null;
    _counting = true;
    _countingGeneration++;
    _heights.clear();
  }

  void _counted(List<_At> starts) {
    if (!mounted) return;
    // Only the number under the page changes: **the page on screen stays
    // where it is.** Putting it on its counted page here moved the book a
    // second after it opened, off the page it had been left on; a spread that
    // is not on a counted page is put on one by the next turn instead.
    setState(() {
      _pageStarts = List.unmodifiable(starts);
      _counting = false;
    });
  }

  /// Whether the book's last block is laid out in [built] and ends by [end].
  bool _endsTheBook(Map<int, BuildContext> built, double end) {
    final last = built[_blocks.length - 1];
    if (last == null) return false;
    final box = last.findRenderObject();
    final at = _offsetOf(last);
    if (box is! RenderBox || !box.hasSize || at == null) return false;
    return at + box.size.height <= end + 1;
  }

  /// The page holding [at], counted from nought.
  int _pageOf(_At at) {
    final starts = _pageStarts!;
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (starts[mid].compareTo(at) <= 0 || starts[mid].near(at)) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The page a spread holding page [page] begins on: itself on one page, the
  /// odd page before it on two — as a printed book is opened.
  int _spreadOf(int page) => _twoPages ? page - page % 2 : page;


  /// Opens the pages on the place the book was left, or on its first page.
  void _openPaged() {
    final place = widget.memory?.place;
    final found =
        place == null ? null : ReadingDocument.settle(place, _plainTexts);
    if (found == null) {
      _jump(const _At(0, 0), 0);
      return;
    }
    final length = _plainTexts[found.block].length;
    _seekTo(
      found.block,
      length == 0 ? 0 : found.offset / length,
      char: found.offset,
    );
  }

  /// Goes to the page holding block [block], [within] of the way down it.
  void _seekTo(int block, double within, {int? char}) {
    _seek = (block: block, within: within, char: char);
    _jump(_At(block, 0), 0);
  }

  void _jump(_At start, int turn) {
    if (!mounted) return;
    setState(() {
      _turn = turn;
      _generation++;
      _spread = _Spread(start, _generation);
    });
  }

  /// The first block a page anchored at [block] lays out: enough before it
  /// to hold two pages, so the pages before can be measured — **and no
  /// more**. A page is a window onto a list, and a list opened at a place it
  /// has never laid out lays out everything before it: at page 1275 of a
  /// long book that was every paragraph of the book, on every turn.
  (int, double) _lead(int block) {
    var first = block;
    var above = 0.0;
    while (first > 0 && above < 2.2 * _pageHeight && block - first < 80) {
      first--;
      above += _heights[first] ?? 60;
    }
    return (first, above);
  }

  /// Every line [built] has laid out, in its own column's units: its top and
  /// its bottom, from the text as it was drawn — so a page ends between two
  /// lines and never through one. A block with no text of its own — a
  /// picture, a rule — is one line, and so is kept whole. The blocks' heights
  /// are noted on the way.
  List<(double, double)> _lines(Map<int, BuildContext> built) {
    final out = <(double, double)>[];
    for (final entry in built.entries) {
      final box = entry.value.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final at = _offsetOf(entry.value);
      if (at == null) continue;
      _heights[entry.key] = box.size.height;
      final block = _blocks[entry.key];
      final paragraphs = <RenderParagraph>[];
      void visit(RenderObject node) {
        if (node is RenderParagraph) {
          paragraphs.add(node);
          return;
        }
        node.visitChildren(visit);
      }

      if (block is! _Picture && block is! _Rule) box.visitChildren(visit);
      if (paragraphs.isEmpty) {
        out.add((at, at + box.size.height));
        continue;
      }
      final origin = box.localToGlobal(Offset.zero).dy;
      for (final paragraph in paragraphs) {
        if (!paragraph.attached || !paragraph.hasSize) continue;
        final base = at + paragraph.localToGlobal(Offset.zero).dy - origin;
        final length = paragraph.text.toPlainText().length;
        if (length == 0) continue;
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: length),
        )..sort((a, b) => a.top.compareTo(b.top));
        double? top, bottom;
        for (final one in boxes) {
          if (top == null || one.top >= bottom! - 0.5) {
            if (top != null) out.add((base + top, base + bottom!));
            top = one.top;
            bottom = one.bottom;
          } else {
            top = math.min(top, one.top);
            bottom = math.max(bottom, one.bottom);
          }
        }
        if (top != null) out.add((base + top, base + bottom!));
      }
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// [y], in [built]'s column, as a block and a distance down it.
  static _At? _atOf(Map<int, BuildContext> built, double y) {
    _At? found;
    for (final entry in built.entries) {
      final box = entry.value.findRenderObject();
      final at = _offsetOf(entry.value);
      if (box is! RenderBox || !box.hasSize || at == null) continue;
      if (at <= y + 0.5 && y < at + box.size.height - 0.5) {
        if (found == null || entry.key > found.block) {
          found = _At(entry.key, math.max(0, y - at));
        }
      }
    }
    return found;
  }

  /// The bottom of the last whole line of a page starting at [start].
  static double _endOf(List<(double, double)> lines, double start, double height) {
    double? best;
    for (final (top, bottom) in lines) {
      if (top >= start - 0.5 && bottom <= start + height + 0.5) {
        best = math.max(best ?? bottom, bottom);
      }
    }
    return best ?? start + height;
  }

  /// The top of the first line at or after [at] — so a page begins with text,
  /// not with the space between two paragraphs.
  static double? _nextLine(List<(double, double)> lines, double at) {
    for (final (top, _) in lines) {
      if (top >= at - 0.5) return top;
    }
    return null;
  }

  /// Where a page ending at [end] begins: the first line from which
  /// everything up to [end] fits.
  static double _startBefore(List<(double, double)> lines, double end, double height) {
    for (final (top, _) in lines) {
      if (top >= end - height - 0.5 && top < end - 0.5) return top;
    }
    return math.max(0, end - height);
  }

  /// The left page has been laid out and stands at [start] in its column:
  /// find where its pages end and where the spreads either side begin — or,
  /// when a place is being looked for, the page that holds it.
  void _measured(Map<int, BuildContext> built, double start) {
    if (!mounted) return;
    final lines = _lines(built);

    final seek = _seek;
    if (seek != null) {
      _seek = null;
      final context = built[seek.block];
      final box = context?.findRenderObject();
      final at = context == null ? null : _offsetOf(context);
      if (box is RenderBox && box.hasSize && at != null) {
        // The page holding the place, once the pages are known; until then
        // the line holding it begins the page.
        final y = at + seek.within * box.size.height;
        var top = at;
        for (final (lineTop, _) in lines) {
          if (lineTop <= y + 0.5 && lineTop >= at - 0.5) top = lineTop;
        }
        // **The line of the very letter the page began with**, where there is
        // one: a share of the block's height is an estimate, and one that
        // falls a hair short lands on the line before — the page opened one
        // earlier than it was left on.
        final char = seek.char;
        final body = char == null ? null : _bodyOf(box, seek.block);
        if (body != null) {
          final length = body.text.toPlainText().length;
          if (length > 0) {
            final at0 = char!.clamp(0, length - 1);
            final boxes = body.getBoxesForSelection(
              TextSelection(baseOffset: at0, extentOffset: at0 + 1),
            );
            if (boxes.isNotEmpty) {
              top = at +
                  body.localToGlobal(Offset(0, boxes.first.top)).dy -
                  box.localToGlobal(Offset.zero).dy;
            }
          }
        }
        var target = _At(seek.block, top - at);
        final starts = _pageStarts;
        if (starts != null) target = starts[_spreadOf(_pageOf(target))];
        if (!target.near(_spread.start)) {
          _jump(target, 0);
          return;
        }
      }
    }

    final height = _pageHeight;
    final leftEnd = _endOf(lines, start, height);
    double? rightStart, rightEnd;
    if (_twoPages) {
      rightStart = _nextLine(lines, leftEnd);
      if (rightStart != null) rightEnd = _endOf(lines, rightStart, height);
    }
    final last = rightEnd ?? leftEnd;
    final next = _nextLine(lines, last);
    _At? previous;
    final atStart = _spread.start.block == 0 && _spread.start.dy < 0.5;
    if (!atStart) {
      final right = _startBefore(lines, start, height);
      final before = _twoPages ? _startBefore(lines, right, height) : right;
      previous = _atOf(built, before) ?? const _At(0, 0);
    }
    setState(() {
      _spread
        ..leftLength = leftEnd - start
        ..rightStart = rightStart == null ? null : _atOf(built, rightStart)
        ..rightLength = rightStart == null || rightEnd == null
            ? null
            : rightEnd - rightStart
        ..next = next == null ? null : _atOf(built, next)
        ..previous = previous;
    });
    _notePagePlace();
  }

  /// Writes down the page's first line as the place, and tells the structure
  /// panel which section it is in.
  void _notePagePlace() {
    final start = _spread.start;
    final block = start.block;
    if (block >= _blocks.length) return;
    final text = _plainTexts[block];
    var offset = 0;
    // The first letter of the page's first line, read off the text as it was
    // drawn — exactly, so the book opens on this page again and not the one
    // before it.
    final context = _spread.leftBuilt[block];
    final box = context?.findRenderObject();
    final body = box is RenderBox && box.hasSize ? _bodyOf(box, block) : null;
    if (body != null && box is RenderBox) {
      final down = start.dy -
          (body.localToGlobal(Offset.zero).dy - box.localToGlobal(Offset.zero).dy);
      if (down >= 0 && down <= body.size.height) {
        offset = body
            .getPositionForOffset(Offset(1, down + 1))
            .offset
            .clamp(0, text.length);
      }
    } else {
      final height = _heights[block];
      if (height != null && height > 0 && text.isNotEmpty) {
        offset = (start.dy / height * text.length).floor().clamp(0, text.length);
      }
    }
    final rest = text.substring(offset);
    widget.memory?.place =
        ReadingAnchor(block, offset, rest.substring(0, math.min(40, rest.length)));
    widget.link?.report(_document.lines[block]);
  }

  void _forward() {
    if (_seek != null) return;
    final starts = _pageStarts;
    if (starts != null) {
      final page = _spreadOf(_pageOf(_spread.start)) + (_twoPages ? 2 : 1);
      if (page < starts.length) _jump(starts[page], 1);
      return;
    }
    final next = _spread.next;
    if (next != null) _jump(next, 1);
  }

  void _back() {
    if (_seek != null) return;
    final starts = _pageStarts;
    if (starts != null) {
      final page = _spreadOf(_pageOf(_spread.start));
      // A spread opened part way into a counted page goes back to where that
      // page begins before it goes back a page.
      if (!starts[page].near(_spread.start)) {
        _jump(starts[page], -1);
      } else if (page > 0) {
        _jump(starts[math.max(0, page - (_twoPages ? 2 : 1))], -1);
      }
      return;
    }
    final previous = _spread.previous;
    if (previous != null) _jump(previous, -1);
  }

  KeyEventResult _pageKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (keyboardIsInAField()) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown ||
        (key == LogicalKeyboardKey.space && !shift)) {
      _forward();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp ||
        (key == LogicalKeyboardKey.space && shift)) {
      _back();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _jump(const _At(0, 0), -1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      final starts = _pageStarts;
      if (starts != null) {
        _jump(starts[_spreadOf(starts.length - 1)], 1);
      } else {
        _seekTo(_blocks.length - 1, 0);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The wheel and the trackpad turn pages: enough of a push one way is one
  /// page, and nothing more until the push has stopped.
  void _push(double by) {
    _wheelQuiet?.cancel();
    _wheelQuiet = Timer(const Duration(milliseconds: 220), () {
      _wheel = 0;
      _wheelSpent = false;
    });
    if (_wheelSpent) return;
    _wheel += by;
    if (_wheel.abs() < 48) return;
    _wheelSpent = true;
    if (_wheel > 0) {
      _forward();
    } else {
      _back();
    }
  }

  /// The blocks from [first] on, as a page lays them out.
  List<Widget> _pageSlivers(
    int first,
    Map<int, BuildContext> built,
    Map<int, SelectionListenerNotifier> selections,
  ) => [
    SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) => _Tracked(
          index: first + i,
          built: built,
          selections: selections,
          builder: (context) =>
              _blocks[first + i].build(context, widget.textScale),
        ),
        childCount: _blocks.length - first,
      ),
    ),
  ];

  Widget _pages(BuildContext context, BoxConstraints room) {
    final scale = widget.textScale;
    // Two pages side by side as soon as two pages of the narrowest a page may
    // be fit — narrower than the scroll's measure, as a book reader's spread
    // is — and one page, at the measure, when they do not.
    final full = kBookMeasure * scale;
    final two = room.maxWidth >= 2 * kSpreadPageNarrowest * scale + _pageGap + 2 * _margin;
    final width = two
        ? math.min(full, (room.maxWidth - _pageGap - 2 * _margin) / 2)
        : math.max(120.0, math.min(full, room.maxWidth - 2 * _margin));
    final height = math.max(80.0, room.maxHeight - _pageTop - _pageBottom);
    if (two != _twoPages ||
        (height - _pageHeight).abs() > 0.5 ||
        (width - _pageWidth).abs() > 0.5) {
      // A window that has changed its shape has changed every page: the
      // spread is measured again from where it begins, and the book is gone
      // through again for its page numbers.
      final reshaped = (height - _pageHeight).abs() > 0.5 ||
          (width - _pageWidth).abs() > 0.5 ||
          !_counting && _pageStarts == null;
      _twoPages = two;
      _pageHeight = height;
      _pageWidth = width;
      if (reshaped) _recount();
      if (_spread.measured) {
        final start = _spread.start;
        WidgetsBinding.instance.addPostFrameCallback((_) => _jump(start, 0));
      }
    }
    final spread = _spread;
    final page = readingColours(context);

    Widget window({
      required _At anchor,
      required double? length,
      required Map<int, BuildContext> built,
      required Map<int, SelectionListenerNotifier> selections,
      required bool left,
    }) {
      final shown = length == null ? height : length.clamp(0.0, height);
      final (first, above) = _lead(anchor.block);
      return SizedBox(
        width: width,
        height: height,
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            height: shown,
            child: _PageWindow(
              key: ValueKey('${left ? 'L' : 'R'}${spread.generation}'),
              anchor: anchor,
              first: first,
              estimate: above + anchor.dy,
              cache: 2 * height,
              built: built,
              onReady: left ? (y) => _measured(built, y) : null,
              slivers: (first) => _pageSlivers(first, built, selections),
            ),
          ),
        ),
      );
    }

    final spreadView = Opacity(
      key: ValueKey(spread.generation),
      opacity: spread.measured ? 1 : 0,
      child: Align(
        alignment: Alignment.topCenter,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            window(
              anchor: spread.start,
              length: spread.leftLength,
              built: spread.leftBuilt,
              selections: spread.leftSelections,
              left: true,
            ),
            if (two) ...[
              const SizedBox(width: _pageGap),
              if (spread.rightStart != null)
                window(
                  anchor: spread.rightStart!,
                  length: spread.rightLength,
                  built: spread.rightBuilt,
                  selections: spread.rightSelections,
                  left: false,
                )
              else
                SizedBox(width: width, height: height),
            ],
          ],
        ),
      ),
    );

    final starts = _pageStarts;
    String where;
    if (starts == null) {
      final share = _blocks.isEmpty
          ? 0
          : (spread.start.block / _blocks.length * 100).clamp(0, 100).round();
      where = '$share%';
    } else {
      final first = _pageOf(spread.start) + 1;
      final shown = spread.rightStart != null && first < starts.length;
      where = shown
          ? tr('Pages {first}–{second} of {total}', {
              'first': first,
              'second': first + 1,
              'total': starts.length,
            })
          : tr('Page {page} of {total}', {'page': first, 'total': starts.length});
    }

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          final delta = event.scrollDelta;
          _push(delta.dy.abs() >= delta.dx.abs() ? delta.dy : delta.dx);
        }
      },
      onPointerPanZoomUpdate: (event) {
        final delta = event.panDelta;
        _push(-(delta.dy.abs() >= delta.dx.abs() ? delta.dy : delta.dx));
      },
      child: Stack(
        children: [
          // The book being gone through for its page numbers: a page of the
          // same shape, laid out and never drawn.
          if (_counting)
            Positioned(
              left: 0,
              top: _pageTop,
              width: width,
              height: height,
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: SelectionContainer.disabled(
                    child: Opacity(
                      opacity: 0,
                      child: _PageCounter(
                        key: ValueKey('count$_countingGeneration'),
                        height: height,
                        lines: _lines,
                        atOf: _atOf,
                        endsBook: _endsTheBook,
                        onDone: _counted,
                        slivers: (built, selections) =>
                            _pageSlivers(0, built, selections),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: _pageTop,
            bottom: _pageBottom,
            child: AnimatedSwitcher(
              duration: motionOf(context, kPageTurnDuration),
              switchInCurve: kArrivingCurve,
              switchOutCurve: kLeavingCurve,
              // Forward, the spread going leaves to the left and the next
              // comes in from the right; back, the other way round. A jump —
              // the place the book was left, a heading, a mark — is not a
              // turn: it settles in where it is.
              transitionBuilder: (child, animation) {
                final coming = child.key == spreadView.key;
                if (_turn == 0) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween(begin: 0.97, end: 1.0).animate(animation),
                      child: child,
                    ),
                  );
                }
                final from = (coming ? 1 : -1) * _turn * kPageTurnTravel;
                return FadeTransition(
                  opacity: CurvedAnimation(
                    parent: animation,
                    curve: const Interval(0, 0.8),
                  ),
                  child: SlideTransition(
                    position: Tween(
                      begin: Offset(from, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: spreadView,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Center(
              child: Text(
                where,
                style: TextStyle(fontSize: 11 * scale, color: page.faint),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The document as slivers, so that **the heading itself stays** rather than
  /// a strip that looks like it.
  ///
  /// Pinning is not a piece of UI of its own: the area itself is held, and not
  /// only a section but the head of a table.
  ///
  /// **A chain, and every link of it is what was drawn** — heading, subheading,
  /// table head. Reading a table deep in a document, what has to stay is the
  /// chapter, the section inside it, and the names of the columns.
  ///
  /// So a section holds what is under it and ends where the next heading of
  /// its own level or shallower begins; a table pins its head *inside* the
  /// section that owns it rather than closing it. What is left out is the
  /// pile: a heading only ever stays while the reader is inside the thing it
  /// heads, so eight of them can never stack up — the first cut had exactly
  /// that, with nothing to end them.
  /// The margin either side of a reading that fills the window.
  static const double _margin = 20;

  List<Widget> _slivers(BuildContext context, double width, double side) {
    final root = <Widget>[];
    final open = <_Section>[];
    var plain = <int>[];

    List<Widget> into() => open.isEmpty ? root : open.last.slivers;

    void flush() {
      if (plain.isEmpty) return;
      final held = plain;
      plain = <int>[];
      into().add(
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: side),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => KeyedSubtree(
                key: held[i] == _target ? _targetKey : null,
                child: _Tracked(
                  index: held[i],
                  built: _built,
                  selections: _selections,
                  // Built under the block's number, so the text inside can
                  // ask which block it is and draw that block's marks.
                  builder: (context) =>
                      _blocks[held[i]].build(context, widget.textScale),
                ),
              ),
              childCount: held.length,
            ),
          ),
        ),
      );
    }

    /// Closes the innermost section and hands it to whoever holds it.
    void close() {
      final section = open.removeLast();
      into().add(SliverMainAxisGroup(slivers: section.slivers));
    }

    for (var i = 0; i < _blocks.length; i++) {
      final block = _blocks[i];

      if (block is _Heading) {
        flush();
        // A heading ends every section at its own level or deeper: `##` after
        // `###` is a new chapter, not another line of the old one.
        while (open.isNotEmpty && open.last.level >= block.level) {
          close();
        }
        open.add(
          _Section(block.level, [
            SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedHeading(
                heading: block,
                scale: widget.textScale,
                width: width,
                side: side,
                index: i,
                built: _built,
                selections: _selections,
                line: _document.lines[i],
                onPinned: _pinned,
                targetKey: i == _target ? _targetKey : null,
              ),
            ),
          ]),
        );
        continue;
      }

      if (block is _Table) {
        flush();
        // Its own group *inside* the section that owns it: the head of the
        // columns joins the chain rather than replacing it, and leaves with
        // the last of its own rows.
        into().add(
          SliverMainAxisGroup(
            slivers: block.slivers(context, widget.textScale, width, side),
          ),
        );
        continue;
      }

      plain.add(i);
    }

    flush();
    while (open.isNotEmpty) {
      close();
    }

    return [
      const SliverPadding(padding: EdgeInsets.only(top: 16)),
      ...root,
      const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
    ];
  }

  /// A heading has taken the top of the page: that is where the reader is, and
  /// it is what the structure panel lights up.
  ///
  /// Said after the frame, because this is called while the sliver is being
  /// laid out and nothing may be told to rebuild from inside a layout.
  void _pinned(int line) {
    if (_travelling || _pinnedLine == line) return;
    _pinnedLine = line;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pinnedLine == line) widget.link?.report(line);
    });
  }
}

/// Names the heading holding the top of the page, so a test can ask which one
/// it is rather than counting how many times a word is on screen.
const Key pinnedHeadingKey = Key('markdown-pinned-heading');

/// A heading that stops at the top of the page and lets the reading go under
/// it — **the heading itself**, not a copy of it in a strip.
///
/// The strip that came before was a second widget wearing the heading's
/// clothes, kept in step by measuring the scroll;
/// this is the sliver the heading is drawn in, told to stay.
///
/// It carries the page's own ground while it is pinned and nothing at all
/// before that: a heading in the middle of a document has no bar behind it,
/// and it should not grow one on the way past. `overlapsContent` is exactly
/// the moment it does.
class _PinnedHeading extends SliverPersistentHeaderDelegate {
  const _PinnedHeading({
    required this.heading,
    required this.scale,
    required this.width,
    required this.side,
    required this.index,
    required this.built,
    required this.selections,
    required this.line,
    required this.onPinned,
    this.targetKey,
  });

  final _Heading heading;
  final double scale;
  final double width;

  /// The margin either side, which is the page's measure at work.
  final double side;

  /// Which block the heading is, and where it says so: a heading is text
  /// like any other, and selecting it has to open the same menu.
  final int index;
  final Map<int, BuildContext> built;
  final Map<int, SelectionListenerNotifier> selections;

  /// Which line of the source it came from, for the structure panel.
  final int line;
  final void Function(int line) onPinned;
  final Key? targetKey;

  @override
  double get maxExtent => heading.height(scale, width);

  /// **What is drawn is what sticks**, rather than shrinking into a bar on the
  /// way up.
  ///
  /// So the pinned height is the drawn height — no shrinking, no bar, no
  /// second styling to keep in step with the first. The heading stops where
  /// the reading goes under it and is, to the pixel, the heading that was
  /// written there.
  @override
  double get minExtent => maxExtent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    // Held when the reading has begun to pass under it, which is what the
    // structure panel lights up.
    if (shrinkOffset > 0 || overlaps) onPinned(line);
    final held = shrinkOffset > 0 || overlaps;

    return KeyedSubtree(
      key: targetKey,
      child: pinnedSurface(
        context,
        held: held,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: Align(
            alignment: Alignment.centerLeft,
            child: KeyedSubtree(
              key: held ? pinnedHeadingKey : null,
              child: _Tracked(
                index: index,
                built: built,
                selections: selections,
                builder: (context) => heading.build(context, scale),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_PinnedHeading old) =>
      old.heading.text != heading.text ||
      old.heading.level != heading.level ||
      old.scale != scale ||
      old.width != width ||
      old.side != side ||
      old.line != line ||
      old.targetKey != targetKey;
}

/// Anything in a document that answers the pointer.
///
/// Item 60: the md interface answers the mouse over its different pieces.
/// One helper for all of them, so a link, a pill, a row of a table and a block
/// of code all warm at the same rate — an interface where each piece has its
/// own timing is an interface that feels assembled.
///
/// It gives the builder how far in it is, 0 to 1, rather than a boolean: the
/// piece decides what to do with it, and everything it does is a lerp, so
/// nothing snaps.
class _Live extends StatefulWidget {
  const _Live({required this.builder, this.cursor = MouseCursor.defer});

  final Widget Function(BuildContext context, double warm) builder;
  final MouseCursor cursor;

  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  bool _over = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: widget.cursor,
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: _over ? 1 : 0),
          duration: motionOf(context, kMarkdownHoverDuration),
          curve: _over ? kArrivingCurve : kLeavingCurve,
          builder: (context, warm, _) => widget.builder(context, warm),
        ),
      );
}

// --- Block model ----------------------------------------------------------

sealed class _Block {
  const _Block();

  Widget build(BuildContext context, double scale);

  /// The block's text as it is drawn, or nothing for a block with no text of
  /// its own to mark — a rule, a table, a picture.
  String get plain => '';
}

/// A place in the reading, as a page is anchored to it: a block, and how far
/// down it in points. **Not a distance from the top of the book**, which a
/// page could only be opened at by laying out everything above it.
class _At implements Comparable<_At> {
  const _At(this.block, this.dy);

  final int block;
  final double dy;

  @override
  int compareTo(_At other) =>
      block != other.block ? block.compareTo(other.block) : dy.compareTo(other.dy);

  bool near(_At other) => block == other.block && (dy - other.dy).abs() < 0.5;
}

/// One spread of pages: where it begins, and — once the left page has been
/// laid out — how long its pages are and where the spreads either side begin.
/// Its pages' registries are its own: a spread sliding away while the next
/// arrives has laid out its blocks in a column of its own.
class _Spread {
  _Spread(this.start, this.generation);

  final _At start;
  final int generation;
  final Map<int, BuildContext> leftBuilt = {};
  final Map<int, BuildContext> rightBuilt = {};
  final Map<int, SelectionListenerNotifier> leftSelections = {};
  final Map<int, SelectionListenerNotifier> rightSelections = {};
  double? leftLength;
  _At? rightStart;
  double? rightLength;
  _At? next;
  _At? previous;

  bool get measured => leftLength != null;
}

/// The book gone through for its page numbers, out of sight: one hidden page
/// that is moved down the column — never made again — so each step lays out
/// only what it has not seen, and nothing on screen is rebuilt while it goes.
/// Each step takes every page that lies wholly inside what is laid out, by the
/// same measure the pages are turned by.
class _PageCounter extends StatefulWidget {
  const _PageCounter({
    super.key,
    required this.height,
    required this.lines,
    required this.atOf,
    required this.endsBook,
    required this.onDone,
    required this.slivers,
  });

  final double height;
  final List<(double, double)> Function(Map<int, BuildContext> built) lines;
  final _At? Function(Map<int, BuildContext> built, double y) atOf;
  final bool Function(Map<int, BuildContext> built, double end) endsBook;
  final void Function(List<_At> starts) onDone;
  final List<Widget> Function(
    Map<int, BuildContext> built,
    Map<int, SelectionListenerNotifier> selections,
  ) slivers;

  @override
  State<_PageCounter> createState() => _PageCounterState();
}

class _PageCounterState extends State<_PageCounter> {
  final ScrollController _scroll = ScrollController();
  final Map<int, BuildContext> _built = {};
  final Map<int, SelectionListenerNotifier> _selections = {};
  final List<double> _starts = [0];
  final List<_At> _found = [const _At(0, 0)];
  late final List<Widget> _slivers = widget.slivers(_built, _selections);

  @override
  void initState() {
    super.initState();
    _next();
  }

  void _next() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _step())
      ..scheduleFrame();
  }

  void _done() => widget.onDone(_found);

  void _step() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    final height = widget.height;
    final lines = widget.lines(_built);
    // What is laid out reliably: the page itself and two pages below it.
    final reach = position.pixels + 3 * height - 1;
    var from = _starts.last;
    final found = _starts.length;
    while (true) {
      final end = _MarkdownViewState._endOf(lines, from, height);
      if (end > reach) break;
      final next = _MarkdownViewState._nextLine(lines, end);
      if (next == null) {
        // No line after this page among what is laid out. **That is the end
        // of the book only if its last block is laid out and ends on this
        // page** — otherwise it is only the end of what is laid out, and a
        // book of 230 000 words came out as 89 pages.
        if (widget.endsBook(_built, end)) {
          _done();
          return;
        }
        break;
      }
      if (next <= from + 0.5) break;
      final at = widget.atOf(_built, next);
      if (at == null) break;
      _starts.add(next);
      _found.add(at);
      from = next;
    }
    // Nothing found this time: on by a page regardless, so the hidden page
    // can never stand still over a gap it cannot see across.
    var to = from;
    if (_starts.length == found) {
      to = position.pixels + height;
      if (to >= position.maxScrollExtent + height) {
        _done();
        return;
      }
    }
    _scroll.jumpTo(to.clamp(0.0, position.maxScrollExtent));
    _next();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
    controller: _scroll,
    physics: const NeverScrollableScrollPhysics(),
    // The old name on purpose — see [_PageWindow].
    // ignore: deprecated_member_use
    cacheExtent: 2 * widget.height,
    slivers: _slivers,
  );
}

/// A page: a window onto the blocks from [first] on, brought to [anchor] and
/// not scrolled by the reader. It keeps two pages' worth of text laid out
/// either side of itself, which is what the spread's other page, and the
/// pages before and after, are measured from.
///
/// It opens at [estimate] — where the anchor ought to be by the heights
/// measured so far — then finds its anchor's block and stands exactly on it.
class _PageWindow extends StatefulWidget {
  const _PageWindow({
    super.key,
    required this.anchor,
    required this.first,
    required this.estimate,
    required this.cache,
    required this.built,
    required this.slivers,
    this.onReady,
  });

  final _At anchor;
  final int first;
  final double estimate;
  final double cache;
  final Map<int, BuildContext> built;
  final List<Widget> Function(int first) slivers;
  final void Function(double y)? onReady;

  @override
  State<_PageWindow> createState() => _PageWindowState();
}

class _PageWindowState extends State<_PageWindow> {
  /// Fixed for the page's life: its column is the blocks from here on.
  late final int _first = widget.first;
  late final ScrollController _scroll =
      ScrollController(initialScrollOffset: widget.estimate);
  late final List<Widget> _slivers = widget.slivers(_first);
  int _tries = 0;

  @override
  void initState() {
    super.initState();
    _again();
  }

  void _again() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _align())
      ..scheduleFrame();
  }

  void _align() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    final context = widget.built[widget.anchor.block];
    final at = context == null ? null : _MarkdownViewState._offsetOf(context);
    if (at == null) {
      // Not laid out yet: towards it from the nearest block that is.
      if (++_tries > 12) return;
      int? near;
      double nearAt = 0;
      for (final entry in widget.built.entries) {
        final y = _MarkdownViewState._offsetOf(entry.value);
        if (y == null) continue;
        if (near == null ||
            (entry.key - widget.anchor.block).abs() <
                (near - widget.anchor.block).abs()) {
          near = entry.key;
          nearAt = y;
        }
      }
      final guess = near == null
          ? position.pixels + position.viewportDimension
          : nearAt + (widget.anchor.block - near) * 60;
      _scroll.jumpTo(guess.clamp(0.0, position.maxScrollExtent));
      _again();
      return;
    }
    final y = at + widget.anchor.dy;
    if ((y - position.pixels).abs() > 0.5 && _tries++ < 12) {
      _scroll.jumpTo(y.clamp(0.0, position.maxScrollExtent));
      _again();
      return;
    }
    widget.onReady?.call(position.pixels);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
    controller: _scroll,
    physics: const NeverScrollableScrollPhysics(),
    // The old name on purpose: `scrollCacheExtent` is newer than the Flutter
    // the other machines build with, and this has to build on all three.
    // ignore: deprecated_member_use
    cacheExtent: widget.cache,
    slivers: _slivers,
  );
}

/// Keeps [built] told which block is on the list while it is.
class _Tracked extends StatefulWidget {
  const _Tracked({
    required this.index,
    required this.built,
    required this.selections,
    required this.builder,
  });

  final int index;
  final Map<int, BuildContext> built;
  final Map<int, SelectionListenerNotifier> selections;
  final WidgetBuilder builder;

  @override
  State<_Tracked> createState() => _TrackedState();
}

class _TrackedState extends State<_Tracked> {
  final SelectionListenerNotifier _selection = SelectionListenerNotifier();

  void _register() {
    widget.built[widget.index] = context;
    widget.selections[widget.index] = _selection;
  }

  void _unregister(_Tracked from) {
    if (from.built[from.index] == context) from.built.remove(from.index);
    if (from.selections[from.index] == _selection) {
      from.selections.remove(from.index);
    }
  }

  @override
  void initState() {
    super.initState();
    _register();
  }

  @override
  void didUpdateWidget(_Tracked old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index || old.built != widget.built) {
      _unregister(old);
      _register();
    }
  }

  @override
  void dispose() {
    _unregister(widget);
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = _MarksScope.of(context);
    final notes = [
      for (final mark in scope?.marks[widget.index] ?? const <_Mark>[])
        if (mark.noted != null) mark,
    ];
    Widget child = SelectionListener(
      selectionNotifier: _selection,
      child: _BlockIndex(
        index: widget.index,
        child: Builder(builder: widget.builder),
      ),
    );
    if (notes.isNotEmpty) {
      // A note is a mark in the margin beside its passage, as in a book
      // reader: its words on the pointer resting there, the note itself on a
      // press.
      child = Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          Positioned(
            left: -19,
            top: 7,
            child: _NoteMark(
              colour: notes.first.colour,
              note: notes.map((m) => m.noted).join('\n\n'),
              onTap: () => scope!.onNote(notes.first.id),
            ),
          ),
        ],
      );
    }
    return child;
  }
}

/// One marked passage's share of one block.
class _Mark {
  const _Mark(
    this.start,
    this.end,
    this.colour,
    this.id, {
    this.noted,
    this.pending = false,
  });

  /// Not a mark yet: what the menu open over it is about to colour.
  final bool pending;

  final int start;
  final int end;
  final int colour;
  final String id;

  /// The note, on the block where the passage ends; null elsewhere.
  final String? noted;
}

/// The marks of the whole reading, handed down to the blocks that draw them.
class _MarksScope extends InheritedWidget {
  const _MarksScope({
    required this.marks,
    required this.onNote,
    required super.child,
  });

  final Map<int, List<_Mark>> marks;
  final void Function(String id) onNote;

  static _MarksScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MarksScope>();

  @override
  bool updateShouldNotify(_MarksScope old) => old.marks != marks;
}

/// Which block the text below belongs to.
class _BlockIndex extends InheritedWidget {
  const _BlockIndex({required this.index, required super.child});

  final int index;

  static int? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_BlockIndex>()?.index;

  @override
  bool updateShouldNotify(_BlockIndex old) => old.index != index;
}

/// The small mark in the margin that says a passage has a note.
class _NoteMark extends StatelessWidget {
  const _NoteMark({required this.colour, required this.note, required this.onTap});

  final int colour;
  final String note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SelectionContainer.disabled(
    child: Hint(
      message: note,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Icon(
            Icons.sticky_note_2,
            size: 14,
            color: kMarkerColours[colour.clamp(0, kMarkerColours.length - 1)],
          ),
        ),
      ),
    ),
  );
}

class _Heading extends _Block {
  const _Heading(this.level, this.text);

  final int level;
  final String text;

  @override
  String get plain => _plain(text);

  static const List<double> _sizes = [26, 22, 18, 16, 14, 13];

  /// How tall it is when drawn — which a pinned sliver has to be told **up
  /// front**, before it is built.
  ///
  /// Measured rather than guessed: a heading long enough to wrap is two lines
  /// tall, and a delegate that lied about it would cut the second one off.
  /// The words are laid out plainly here — the emphasis inside them changes
  /// the letters, not their size.
  double height(double scale, double width) {
    final size = _sizes[(level - 1).clamp(0, 5)] * scale;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, fontWeight: FontWeight.w700,
            height: 1.25),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width < 40 ? 40 : width);
    // The paddings this draws itself with, and the rule under the top two.
    return painter.height + (level <= 2 ? 20 + 6 + 6 + 1 : 14 + 6);
  }

  @override
  Widget build(BuildContext context, double scale) {
    final size = _sizes[(level - 1).clamp(0, 5)] * scale;

    return Padding(
      padding: EdgeInsets.only(top: level <= 2 ? 20 : 14, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            _inline(context, text, TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w700,
              height: 1.25,
            )),
          ),
          // A rule under the top two levels, the way most renderers do it.
          if (level <= 2)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Divider(
                height: 1,
                color: readingColours(context).rule,
              ),
            ),
        ],
      ),
    );
  }
}

class _Paragraph extends _Block {
  const _Paragraph(this.text);

  final String text;

  @override
  String get plain => _plain(text);

  @override
  Widget build(BuildContext context, double scale) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Text.rich(
          _inline(context, text, TextStyle(fontSize: 14 * scale, height: _lineHeight(context))),
        ),
      );
}

/// Hands the document's pictures down to the blocks that draw them, which are
/// built by a list far below the view and know nothing else of it.
class _PicturesScope extends InheritedWidget {
  const _PicturesScope({required this.pictures, required super.child});

  final DocumentPictures? pictures;

  static DocumentPictures? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PicturesScope>()?.pictures;

  @override
  bool updateShouldNotify(_PicturesScope old) => old.pictures != pictures;
}

class _Picture extends _Block {
  const _Picture(this.caption, this.ref);

  final String caption;
  final String ref;

  @override
  Widget build(BuildContext context, double scale) {
    final pictures = _PicturesScope.of(context);
    if (pictures == null || !pictures.holds(ref)) {
      return _Paragraph('![$caption]($ref)').build(context, scale);
    }
    return _PictureView(
      key: ValueKey(ref),
      pictures: pictures,
      ref: ref,
      caption: caption,
      scale: scale,
    );
  }
}

/// Key of the room a document picture is drawn in, for tests.
const Key documentPictureKey = Key('markdown-picture');

/// One picture of a document: its room kept at its size from the first frame,
/// the bytes asked for when the list first builds it — which is when it comes
/// near the screen — and the picture fading into the room when they arrive.
class _PictureView extends StatefulWidget {
  const _PictureView({
    super.key,
    required this.pictures,
    required this.ref,
    required this.caption,
    required this.scale,
  });

  final DocumentPictures pictures;
  final String ref;
  final String caption;
  final double scale;

  @override
  State<_PictureView> createState() => _PictureViewState();
}

class _PictureViewState extends State<_PictureView> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.pictures.load(widget.ref).then((bytes) {
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _failed = bytes == null;
      });
    });
  }

  /// A picture whose size is not known is given this much height until it
  /// arrives, the one case where the text below it moves.
  static const double _unknownHeight = 160;

  @override
  Widget build(BuildContext context) {
    final page = readingColours(context);
    final scale = widget.scale;
    final caption = widget.caption;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LayoutBuilder(
        builder: (context, room) {
          final natural = widget.pictures.sizeOf(widget.ref);
          // One pixel of the picture to one point of the page, grown with the
          // reading's own zoom, and never wider than the column.
          double width = room.maxWidth;
          double? height;
          if (natural != null) {
            width = math.min(natural.width * scale, room.maxWidth);
            height = width * natural.height / natural.width;
          } else if (_bytes == null) {
            height = _unknownHeight * scale;
          }
          final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
          final bytes = _bytes;

          final Widget body;
          if (_failed) {
            body = Center(
              child: Text(
                caption.isEmpty ? '[image]' : '[image: $caption]',
                style: TextStyle(fontSize: 13 * scale, color: page.accent),
              ),
            );
          } else {
            body = TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: bytes == null ? 0 : 1),
              duration: motionOf(context, kPictureArrivalDuration),
              curve: kArrivingCurve,
              builder: (context, t, _) => Stack(
                fit: natural == null && bytes != null
                    ? StackFit.loose
                    : StackFit.expand,
                alignment: Alignment.center,
                children: [
                  if (t < 1)
                    Positioned.fill(
                      child: Opacity(
                        opacity: 1 - t,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: page.plaque,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  if (bytes != null)
                    Opacity(
                      opacity: t,
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        width: natural == null ? null : width,
                        // Decoded at the size it is drawn, not the size it was
                        // saved at: a scan of a page is 5000 pixels across.
                        cacheWidth: natural != null &&
                                natural.width > width * ratio
                            ? (width * ratio).round()
                            : null,
                        gaplessPlayback: true,
                        errorBuilder: (context, _, _) => Center(
                          child: Text(
                            caption.isEmpty ? '[image]' : '[image: $caption]',
                            style: TextStyle(
                              fontSize: 13 * scale,
                              color: page.accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          }

          return Column(
            children: [
              SizedBox(
                key: documentPictureKey,
                width: width,
                height: _failed ? 24 * scale : height,
                child: body,
              ),
              if (caption.isNotEmpty && !_failed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    caption,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5 * scale,
                      height: 1.4,
                      color: page.quiet,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CodeBlock extends _Block {
  const _CodeBlock(this.code, this.language);

  final String code;

  @override
  String get plain => code;
  final String? language;

  @override
  Widget build(BuildContext context, double scale) {
    final page = readingColours(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: _Live(
        builder: (context, warm) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: page.plaque,
          borderRadius: BorderRadius.circular(6),
          // The edge comes up under the pointer. A block of code in a document
          // is a thing you reach for — to read it, to take it — and an edge
          // that answers says so before anything is pressed.
          border: Border.all(
            color: Color.lerp(page.rule, page.accent, warm * 0.6)!,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (language != null && language!.isNotEmpty)
              // The language's name is a label, not the code: out of the
              // selection, so a mark in the code lands where it was made.
              SelectionContainer.disabled(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                  child: Text(
                    language!,
                    style: TextStyle(
                      fontSize: 10 * scale,
                      color: page.quiet,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              child: Text.rich(
                _markedPlain(
                  context,
                  code,
                  TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.5 * scale,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _ListItem extends _Block {
  const _ListItem(this.text, this.depth, this.marker);

  final String text;

  @override
  String get plain => _plain(text);
  final int depth;

  /// Bullet glyph, or `1.` style number for ordered lists.
  final String marker;

  @override
  Widget build(BuildContext context, double scale) => Padding(
        padding: EdgeInsets.fromLTRB(6 + depth * 18.0, 2, 0, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The bullet or the number is not the item's text: selected with
            // it, every mark in a list came out one letter later than the
            // words it was made on.
            SelectionContainer.disabled(
              child: SizedBox(
                width: 22,
                child: Text(
                  marker,
                  style: TextStyle(fontSize: 14 * scale, height: _lineHeight(context)),
                ),
              ),
            ),
            Expanded(
              child: Text.rich(
                _inline(
                  context,
                  text,
                  TextStyle(fontSize: 14 * scale, height: _lineHeight(context)),
                ),
              ),
            ),
          ],
        ),
      );
}

class _Quote extends _Block {
  const _Quote(this.text);

  final String text;

  @override
  String get plain => _plain(text);

  @override
  Widget build(BuildContext context, double scale) {
    final page = readingColours(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: _Live(
        builder: (context, warm) => Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        decoration: BoxDecoration(
          border: Border(
            // The one mark a quote has, so it is the one that answers.
            left: BorderSide(
              color: page.accent.withValues(alpha: 0.5 + 0.5 * warm),
              width: 3,
            ),
          ),
        ),
        child: Text.rich(
          _inline(
            context,
            text,
            TextStyle(
              fontSize: 14 * scale,
              height: _lineHeight(context),
              color: page.quiet,
            ),
          ),
        ),
        ),
      ),
    );
  }
}

class _Rule extends _Block {
  const _Rule();

  @override
  Widget build(BuildContext context, double scale) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Divider(color: readingColours(context).rule),
      );
}

class _Table extends _Block {
  const _Table(this.header, this.rows);

  final List<String> header;
  final List<List<String>> rows;

  /// Whether this table has a head at all.
  ///
  /// **A blank head row is a table with no head, not a table with a blank
  /// one.** GFM has no way to write a headless table — the divider row is what
  /// makes a table a table — so a writer who has none says so with empty
  /// cells, and drawing an empty bar over the rows would be showing a heading
  /// nobody wrote. It matters for a PDF read as a document: most tables in one
  /// have no head, and promoting the first row of data into that bar would
  /// move a line of the document somewhere it never was.
  bool get hasHead => header.any((cell) => cell.trim().isNotEmpty);

  /// A table drawn as slivers, so that **its header stays** while the rows go
  /// past under it.
  ///
  /// Not only a section is pinned, but a table's head. It was
  /// a Material `DataTable` inside the list before, header and all, so the
  /// names of the columns left the screen with the first screenful of rows —
  /// which is the moment a table stops being readable.
  ///
  /// The columns are fitted to the width rather than scrolled sideways. A
  /// table that scrolls horizontally *inside* a page that scrolls vertically
  /// is two scrolls fighting over one gesture, and the header and the rows
  /// would then have to be kept in step by hand.
  List<Widget> slivers(
      BuildContext context, double scale, double width, double side) {
    final widths = _widths(context, scale, width);
    final style = TextStyle(fontSize: 13 * scale);

    return [
      if (hasHead)
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedRow(
            height: 36 * scale,
            side: side,
            builder: (context, overlaps) => pinnedSurface(
              context,
              held: overlaps,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: side),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: readingColours(context).rule),
                    ),
                  ),
                  child: _row(
                    context,
                    header,
                    widths,
                    style.copyWith(fontWeight: FontWeight.w700),
                    36 * scale,
                  ),
                ),
              ),
            ),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.only(left: side, right: side, bottom: 10),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => _row(context, rows[i], widths, style, null),
            childCount: rows.length,
          ),
        ),
      ),
    ];
  }

  /// One line of the table, cell by cell.
  Widget _row(
    BuildContext context,
    List<String> cells,
    List<double> widths,
    TextStyle style,
    double? height,
  ) => SizedBox(
    height: height,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < widths.length; i++)
          SizedBox(
            width: widths[i],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Text.rich(
                _inline(
                    context, _unwrapped(i < cells.length ? cells[i] : ''), style),
              ),
            ),
          ),
      ],
    ),
  );

  /// A cell's text with its line breaks back.
  ///
  /// A pipe table is one line per row, so a cell with two lines in it has no
  /// way to say so but `<br>` — which is what GFM settled on and what every
  /// writer of one uses. Only inside a cell: elsewhere a blank line is
  /// available and there is nothing to work around.
  static String _unwrapped(String cell) => cell.replaceAll(_breakPattern, '\n');

  /// How wide each column is: by what is in it, and then squeezed to fit.
  ///
  /// The longest cell decides, capped so that one paragraph in one cell cannot
  /// take the whole table; what is left over is shared out in proportion.
  List<double> _widths(BuildContext context, double scale, double width) {
    final wanted = <double>[];
    for (var column = 0; column < header.length; column++) {
      var widest = 0.0;
      for (final cells in [header, ...rows]) {
        final text = column < cells.length ? cells[column] : '';
        final painter = TextPainter(
          text: TextSpan(text: text, style: TextStyle(fontSize: 13 * scale)),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        widest = math.max(widest, painter.width);
      }
      wanted.add(math.min(widest + 12, width * 0.5));
    }

    final total = wanted.fold<double>(0, (sum, one) => sum + one);
    if (total <= width || total == 0) return wanted;
    return [for (final one in wanted) one * width / total];
  }

  @override
  Widget build(BuildContext context, double scale) {
    // Drawn as one piece where it is not the document's own — a table inside a
    // quote or a list item, where there are no slivers to hang a header on.
    return LayoutBuilder(
      builder: (context, room) {
        final widths = _widths(context, scale, room.maxWidth);
        final style = TextStyle(fontSize: 13 * scale);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(
                context,
                header,
                widths,
                style.copyWith(fontWeight: FontWeight.w700),
                36 * scale,
              ),
              Divider(height: 1, color: readingColours(context).rule),
              for (final row in rows) _row(context, row, widths, style, null),
            ],
          ),
        );
      },
    );
  }
}

/// A row of a table, told to stay at the top while its own rows go past.
class _PinnedRow extends SliverPersistentHeaderDelegate {
  const _PinnedRow({
    required this.height,
    required this.side,
    required this.builder,
  });

  final double height;

  /// Asked for only to know when to build again: the page narrowing moves
  /// the row with it.
  final double side;
  final Widget Function(BuildContext context, bool overlaps) builder;

  @override
  double get maxExtent => height;

  @override
  double get minExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      builder(context, overlaps);

  @override
  bool shouldRebuild(_PinnedRow old) =>
      old.height != height || old.side != side;
}


// --- Block parsing --------------------------------------------------------

final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _rulePattern = RegExp(r'^ {0,3}([-*_])( *\1){2,} *$');
final RegExp _bulletPattern = RegExp(r'^(\s*)([-*+])\s+(.*)$');
final RegExp _orderedPattern = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final RegExp _picturePattern = RegExp(r'^\s*!\[([^\]]*)\]\(([^)\s]+)\)\s*$');
final RegExp _fencePattern = RegExp(r'^\s*(```|~~~)\s*(\w*)\s*$');
final RegExp _tableDividerPattern = RegExp(r'^\s*\|?[\s:|-]+\|[\s:|-]*$');

/// The one HTML tag a pipe table cannot do without: a line break inside a cell.
final RegExp _breakPattern = RegExp(r'<br\s*/?>', caseSensitive: false);

/// [source] as lines, however the file that carried it ended them.
///
/// **Carriage returns are line breaks, not characters.** A file written on
/// Windows ends its lines `\r\n`, one written on a Mac before OS X ends them
/// `\r`, and a damaged one has both — and splitting on `\n` alone leaves the
/// `\r` sitting inside the line. That costs more than an invisible character:
/// `\r` is a line terminator to a regular expression, so `.*$` stops dead at
/// it and a heading with one in it stops being a heading. Reported against a
/// README where everything ran together on one line while Xcode, beside it,
/// showed the lines it actually has.
List<String> splitLines(String source) =>
    source.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

/// A section being built: the level of the heading that opened it, and the
/// slivers inside it. It becomes one `SliverMainAxisGroup`, which is what
/// makes its heading leave when the section does.
class _Section {
  _Section(this.level, this.slivers);

  final int level;
  final List<Widget> slivers;
}


class _Document {
  const _Document(this.blocks, this.lines);

  final List<_Block> blocks;
  final List<int> lines;
}

_Document _parseBlocks(List<String> lines) {
  final blocks = <_Block>[];
  final at = <int>[];
  final paragraph = <String>[];
  var paragraphAt = 0;

  void add(_Block block, int line) {
    blocks.add(block);
    at.add(line);
  }

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    add(_Paragraph(paragraph.join(' ')), paragraphAt);
    paragraph.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];

    // Fenced code runs verbatim until the closing fence or end of file.
    final fence = _fencePattern.firstMatch(line);
    if (fence != null) {
      flushParagraph();
      final start = i;
      final marker = fence.group(1)!;
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith(marker)) {
        code.add(lines[i]);
        i++;
      }
      add(_CodeBlock(code.join('\n'), fence.group(2)), start);
      continue;
    }

    if (line.trim().isEmpty) {
      flushParagraph();
      continue;
    }

    if (_rulePattern.hasMatch(line)) {
      flushParagraph();
      add(const _Rule(), i);
      continue;
    }

    // A picture on a line of its own is a block: drawn at its size, with its
    // caption under it. One inside a sentence stays a caption in the text.
    final picture = _picturePattern.firstMatch(line);
    if (picture != null) {
      flushParagraph();
      add(_Picture(picture.group(1)!.trim(), picture.group(2)!), i);
      continue;
    }

    final heading = _headingPattern.firstMatch(line);
    if (heading != null) {
      flushParagraph();
      add(_Heading(heading.group(1)!.length, heading.group(2)!.trim()), i);
      continue;
    }

    // A pipe table is only a table if the next line is its divider.
    if (line.contains('|') &&
        i + 1 < lines.length &&
        _tableDividerPattern.hasMatch(lines[i + 1])) {
      flushParagraph();
      final start = i;
      final header = _splitRow(line);
      final rows = <List<String>>[];
      i += 2;
      while (i < lines.length && lines[i].contains('|')) {
        rows.add(_splitRow(lines[i]));
        i++;
      }
      i--;
      add(_Table(header, rows), start);
      continue;
    }

    if (line.trimLeft().startsWith('>')) {
      flushParagraph();
      final start = i;
      final quote = <String>[];
      while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
        quote.add(lines[i].trimLeft().substring(1).trim());
        i++;
      }
      i--;
      add(_Quote(quote.join(' ')), start);
      continue;
    }

    final bullet = _bulletPattern.firstMatch(line);
    if (bullet != null) {
      flushParagraph();
      add(_ListItem(bullet.group(3)!, bullet.group(1)!.length ~/ 2, '•'), i);
      continue;
    }

    final ordered = _orderedPattern.firstMatch(line);
    if (ordered != null) {
      flushParagraph();
      add(
        _ListItem(
        ordered.group(3)!,
        ordered.group(1)!.length ~/ 2,
        '${ordered.group(2)}.',
        ),
        i,
      );
      continue;
    }

    if (paragraph.isEmpty) paragraphAt = i;
    paragraph.add(line.trim());
  }

  flushParagraph();
  return _Document(blocks, at);
}

List<String> _splitRow(String line) {
  var text = line.trim();
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|') && !text.endsWith('\\|')) {
    text = text.substring(0, text.length - 1);
  }
  // `\|` is a bar inside a cell, not the edge of one; it stays escaped here
  // and becomes a bar when the cell's text is drawn.
  final cells = <String>[];
  var from = 0;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '\\') {
      i++;
    } else if (text[i] == '|') {
      cells.add(text.substring(from, i).trim());
      from = i + 1;
    }
  }
  cells.add(text.substring(from).trim());
  return cells;
}

/// [text] with each escaped character standing for itself — for the pieces
/// drawn as a whole rather than walked mark by mark: emphasis, a link's words.
String _unescape(String text) {
  if (!text.contains('\\')) return text;
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '\\' &&
        i + 1 < text.length &&
        _escapable.contains(text[i + 1])) {
      i++;
    }
    out.write(text[i]);
  }
  return out.toString();
}

/// The characters a backslash makes literal: CommonMark's ASCII punctuation.
const String _escapable = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

// --- Inline parsing -------------------------------------------------------

/// [text] as it stands, with no marks of Markdown read in it — code — and
/// its block's highlights laid on it.
TextSpan _markedPlain(BuildContext context, String text, TextStyle style) {
  final block = _BlockIndex.of(context);
  final scope = block == null ? null : _MarksScope.of(context);
  final marks = scope?.marks[block] ?? const <_Mark>[];
  if (marks.isEmpty) return TextSpan(text: text, style: style);
  final page = readingColours(context);
  final spans = <TextSpan>[];
  var from = 0;
  while (from < text.length) {
    _Mark? inside;
    var next = text.length;
    for (final mark in marks) {
      if (mark.start <= from && from < mark.end) {
        inside = mark;
        next = math.min(next, mark.end);
      } else if (mark.start > from) {
        next = math.min(next, mark.start);
      }
    }
    next = next.clamp(from + 1, text.length);
    spans.add(TextSpan(
      text: text.substring(from, next),
      style: inside == null
          ? null
          : TextStyle(
              backgroundColor: inside.pending
                  ? page.accent.withValues(alpha: 0.30)
                  : markerFill(inside.colour),
            ),
    ));
    from = next;
  }
  return TextSpan(style: style, children: spans);
}

/// [source]'s text as [_inline] draws it, marks and all taken out: what a
/// selection's offsets are counted in, the words inside a link and a code
/// pill included, because the selection counts them too.
String _plain(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    if (source[i] == '\\' &&
        i + 1 < source.length &&
        _escapable.contains(source[i + 1])) {
      out.write(source[i + 1]);
      i += 2;
      continue;
    }
    final rest = source.substring(i);
    if (rest.startsWith('`')) {
      final end = source.indexOf('`', i + 1);
      if (end > i) {
        out.write(source.substring(i + 1, end));
        i = end + 1;
        continue;
      }
    }
    if (rest.startsWith('![') || rest.startsWith('[')) {
      final isImage = rest.startsWith('!');
      final start = i + (isImage ? 2 : 1);
      final closeText = source.indexOf(']', start);
      if (closeText > 0 &&
          closeText + 1 < source.length &&
          source[closeText + 1] == '(') {
        final closeUrl = source.indexOf(')', closeText + 2);
        if (closeUrl > 0) {
          final label = _unescape(source.substring(start, closeText));
          final url = source.substring(closeText + 2, closeUrl);
          if (isImage) {
            out.write('[image: $label]');
          } else {
            out.write(label);
            if (url != label) out.write(' ($url)');
          }
          i = closeUrl + 1;
          continue;
        }
      }
    }
    final emphasis = _matchEmphasis(source, i);
    if (emphasis != null) {
      out.write(emphasis.text);
      i = emphasis.end;
      continue;
    }
    out.write(source[i]);
    i++;
  }
  return out.toString();
}

/// Renders `**bold**`, `*italic*`, `` `code` ``, `~~strike~~` and `[text](url)`.
///
/// Unmatched markers are emitted literally rather than swallowed, so a stray
/// asterisk in prose still shows up.
TextSpan _inline(BuildContext context, String source, TextStyle base) {
  final page = readingColours(context);
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();

  // The marked passages on this block, and how far into its drawn text the
  // spans have come — counted the way [_plain] counts, so a mark made on a
  // selection lands on the words that were selected.
  final block = _BlockIndex.of(context);
  final scope = block == null ? null : _MarksScope.of(context);
  final marks = scope?.marks[block] ?? const <_Mark>[];
  var at = 0;

  /// [text] as spans, cut where a mark begins or ends and the marked pieces
  /// laid on their colour, answering a press.
  void emit(String text, [TextStyle? style]) {
    if (marks.isEmpty) {
      spans.add(TextSpan(text: text, style: style));
      at += text.length;
      return;
    }
    var from = 0;
    while (from < text.length) {
      final here = at + from;
      _Mark? inside;
      var next = text.length;
      for (final mark in marks) {
        if (mark.start <= here && here < mark.end) {
          inside = mark;
          next = math.min(next, mark.end - at);
        } else if (mark.start > here) {
          next = math.min(next, mark.start - at);
        }
      }
      next = next.clamp(from + 1, text.length);
      spans.add(TextSpan(
        text: text.substring(from, next),
        style: inside == null
            ? style
            : (style ?? const TextStyle()).copyWith(
                backgroundColor: inside.pending
                    ? page.accent.withValues(alpha: 0.30)
                    : markerFill(inside.colour),
              ),
      ));
      from = next;
    }
    at += text.length;
  }

  void flush() {
    if (buffer.isEmpty) return;
    emit(buffer.toString());
    buffer.clear();
  }

  var i = 0;
  while (i < source.length) {
    // A backslash before punctuation is that character and nothing more, as
    // in CommonMark: `\*` is an asterisk, not the start of emphasis. What a
    // converted document leans on — a Word file is full of asterisks and
    // underscores that were never meant as marks.
    if (source[i] == '\\' &&
        i + 1 < source.length &&
        _escapable.contains(source[i + 1])) {
      buffer.write(source[i + 1]);
      i += 2;
      continue;
    }

    final rest = source.substring(i);

    // Inline code wins over every other marker, as in CommonMark.
    if (rest.startsWith('`')) {
      final end = source.indexOf('`', i + 1);
      if (end > i) {
        flush();
        final code = source.substring(i + 1, end);
        spans.add(_codePill(context, code, base));
        at += code.length;
        i = end + 1;
        continue;
      }
    }

    if (rest.startsWith('![') || rest.startsWith('[')) {
      final isImage = rest.startsWith('!');
      final start = i + (isImage ? 2 : 1);
      final closeText = source.indexOf(']', start);
      if (closeText > 0 &&
          closeText + 1 < source.length &&
          source[closeText + 1] == '(') {
        final closeUrl = source.indexOf(')', closeText + 2);
        if (closeUrl > 0) {
          flush();
          final label = _unescape(source.substring(start, closeText));
          final url = source.substring(closeText + 2, closeUrl);
          if (isImage) {
            emit('[image: $label]', TextStyle(color: page.accent));
          } else {
            at += label.length;
          }
          if (!isImage) {
            spans.add(
                // A link is the one thing a pointer expects an answer from, so
                // it is a widget rather than coloured text: the underline
                // fills in and the ink warms as the pointer crosses it. Still
                // not clickable — the viewer has no business opening a browser
                // — which is exactly why it has to *say* what it is instead.
              WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: _Live(
                      cursor: SystemMouseCursors.basic,
                      builder: (context, warm) => Text(
                        label,
                        style: base.copyWith(
                          color: Color.lerp(
                            page.accent,
                            page.accent.withValues(alpha: 1),
                            warm,
                          ),
                          decoration: TextDecoration.underline,
                          decorationColor: page.accent.withValues(
                            alpha: 0.5 + 0.5 * warm,
                          ),
                          decorationThickness: 1 + warm,
                        ),
                      ),
                    ),
                  ),
            );
          }
          if (!isImage && url != label) {
            emit(
              ' ($url)',
              TextStyle(fontSize: base.fontSize! * 0.85, color: page.quiet),
            );
          }
          i = closeUrl + 1;
          continue;
        }
      }
    }

    final emphasis = _matchEmphasis(source, i);
    if (emphasis != null) {
      flush();
      emit(emphasis.text, emphasis.style);
      i = emphasis.end;
      continue;
    }

    buffer.write(source[i]);
    i++;
  }

  flush();
  return TextSpan(style: base, children: spans);
}

class _Emphasis {
  const _Emphasis(this.text, this.style, this.end);

  final String text;
  final TextStyle style;
  final int end;
}

/// Matches the longest emphasis marker starting at [start], or null.
_Emphasis? _matchEmphasis(String source, int start) {
  const markers = <String, TextStyle>{
    '***': TextStyle(fontWeight: FontWeight.w700, fontStyle: FontStyle.italic),
    '**': TextStyle(fontWeight: FontWeight.w700),
    '__': TextStyle(fontWeight: FontWeight.w700),
    '~~': TextStyle(decoration: TextDecoration.lineThrough),
    '*': TextStyle(fontStyle: FontStyle.italic),
    '_': TextStyle(fontStyle: FontStyle.italic),
  };

  for (final entry in markers.entries) {
    final marker = entry.key;
    if (!source.startsWith(marker, start)) continue;

    final contentStart = start + marker.length;
    var end = source.indexOf(marker, contentStart);
    // An escaped marker does not close anything.
    while (end > 0 && source[end - 1] == '\\') {
      end = source.indexOf(marker, end + 1);
    }
    // An empty span such as `**` on its own is not emphasis.
    if (end <= contentStart) continue;

    return _Emphasis(
      _unescape(source.substring(contentStart, end)),
      entry.value,
      end + marker.length,
    );
  }
  return null;
}

/// `` `code` `` drawn as one of the application's pills.
///
/// Things like `` `file:` `` in a README read as pills. A background colour
/// behind the characters is a rectangle with the
/// text jammed against its ends; the same shape everything else in this
/// application uses for a small named thing — a branch, a tag, a scheme — is a
/// stadium with room either side of the word. It costs a `WidgetSpan`, because
/// only a widget can have a shape.
///
/// Selectable like the prose around it: the child is a `Text`, and the whole
/// document is already inside a `SelectionArea`.
InlineSpan _codePill(BuildContext context, String code, TextStyle base) {
  final page = readingColours(context);
  final size = (base.fontSize ?? 14) * 0.92;

  return WidgetSpan(
    // By the middle rather than the baseline: the pill is taller than the line
    // it sits in, and hanging it from the baseline pushes the whole row down.
    alignment: PlaceholderAlignment.middle,
    child: _Live(
      builder: (context, warm) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          // **Outlined, not filled**, like the annotations. A filled pill in
          // the middle of a
          // sentence is a block of colour the eye stops at; an outline names
          // the thing and lets the line go on. The fill stays as the faintest
          // wash, so it is still a thing rather than a word in a box — and it
          // comes up under the pointer, which is the whole of what "alive"
          // means here.
          decoration: ShapeDecoration(
            color: page.ink.withValues(alpha: 0.04 + 0.10 * warm),
            shape: StadiumBorder(
              side: BorderSide(
                color: page.ink.withValues(alpha: 0.28 + 0.32 * warm),
              ),
            ),
          ),
          child: Text(
            code,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: size,
              height: 1.1,
              color: page.ink.withValues(alpha: 0.85 + 0.15 * warm),
            ),
          ),
        ),
      ),
    ),
  );
}
