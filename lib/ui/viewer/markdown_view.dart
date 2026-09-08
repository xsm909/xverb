import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../motion.dart';
import 'pinned_surface.dart';
import 'reading_colours.dart';
import 'reading_link.dart';

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
  });

  final String source;
  final double textScale;

  /// Whoever is driving the scrolling from outside — the arrow keys, say.
  final ScrollController? controller;

  /// The line to the structure panel: which line of the source is at the top,
  /// and "take me to this one". Null where nothing is standing beside the
  /// document.
  final ReadingLink? link;

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

  @override
  void initState() {
    super.initState();
    _attach(widget.link);
  }

  void _attach(ReadingLink? link) {
    link?.reveal = _goTo;
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
    super.dispose();
  }

  @override
  void didUpdateWidget(MarkdownView old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) {
      _document = _parseBlocks(splitLines(widget.source));
      _pinnedLine = null;
      _target = null;
    }
    if (old.link != widget.link) {
      if (old.link?.reveal == _goTo) old.link!.reveal = null;
      _attach(widget.link);
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
  void _goTo(int line) {
    final index = _blockAt(line);
    setState(() => _target = index);
    _bring(index, 8);
  }

  void _bring(int index, int tries) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _target != index) return;
      final controller = widget.controller;
      if (controller == null || !controller.hasClients) return;
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
        // One pixel past where the section starts, not exactly on it: a
        // heading holds the top from the first pixel of its own section, and
        // landing on the boundary leaves the one before it holding.
        final to = (offset + 1).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (!motionOn(context)) {
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
        setState(() => _target = null);
        return;
      }
      // Not built yet: where it ought to be, by the share of the document it
      // stands at. The list's own estimate of its length is what there is.
      final share = _blocks.isEmpty ? 0.0 : index / _blocks.length;
      final guess = (position.maxScrollExtent * share).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      controller.jumpTo(guess);
      _bring(index, tries - 1);
    });
  }

  /// Where a block sits in the scroll, in the scroll's own units.
  ///
  /// **Asked of the sliver that holds it**, not of `ensureVisible`: a heading
  /// is a *pinned* sliver now, and a pinned sliver is at the top of the screen
  /// whenever it is built — so "make it visible" is already true and moves
  /// nothing. What is wanted is where its section begins, and the sliver knows
  /// that exactly: `precedingScrollExtent`, plus the child's own offset inside
  /// a list.
  double? _offsetOf(BuildContext target) {
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
    return SelectionArea(
      child: LayoutBuilder(
        builder: (context, room) => CustomScrollView(
          key: _list,
          controller: widget.controller,
          slivers: _slivers(context, room.maxWidth - 40),
        ),
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
  List<Widget> _slivers(BuildContext context, double width) {
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
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => KeyedSubtree(
                key: held[i] == _target ? _targetKey : null,
                child: _blocks[held[i]].build(context, widget.textScale),
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
            slivers: block.slivers(context, widget.textScale, width),
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
    required this.line,
    required this.onPinned,
    this.targetKey,
  });

  final _Heading heading;
  final double scale;
  final double width;

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
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: KeyedSubtree(
              key: held ? pinnedHeadingKey : null,
              child: heading.build(context, scale),
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
}

class _Heading extends _Block {
  const _Heading(this.level, this.text);

  final int level;
  final String text;

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
  Widget build(BuildContext context, double scale) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Text.rich(
          _inline(context, text, TextStyle(fontSize: 14 * scale, height: 1.5)),
        ),
      );
}

class _CodeBlock extends _Block {
  const _CodeBlock(this.code, this.language);

  final String code;
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
              Padding(
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
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              child: Text(
                code,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5 * scale,
                  height: 1.45,
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
  final int depth;

  /// Bullet glyph, or `1.` style number for ordered lists.
  final String marker;

  @override
  Widget build(BuildContext context, double scale) => Padding(
        padding: EdgeInsets.fromLTRB(6 + depth * 18.0, 2, 0, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              child: Text(
                marker,
                style: TextStyle(fontSize: 14 * scale, height: 1.5),
              ),
            ),
            Expanded(
              child: Text.rich(
                _inline(
                  context,
                  text,
                  TextStyle(fontSize: 14 * scale, height: 1.5),
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
              height: 1.5,
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
  List<Widget> slivers(BuildContext context, double scale, double width) {
    final widths = _widths(context, scale, width);
    final style = TextStyle(fontSize: 13 * scale);

    return [
      if (hasHead)
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedRow(
            height: 36 * scale,
            builder: (context, overlaps) => pinnedSurface(
              context,
              held: overlaps,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
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
        padding: const EdgeInsets.only(left: 20, right: 20, bottom: 10),
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
  const _PinnedRow({required this.height, required this.builder});

  final double height;
  final Widget Function(BuildContext context, bool overlaps) builder;

  @override
  double get maxExtent => height;

  @override
  double get minExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      builder(context, overlaps);

  @override
  bool shouldRebuild(_PinnedRow old) => old.height != height;
}


// --- Block parsing --------------------------------------------------------

final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _rulePattern = RegExp(r'^ {0,3}([-*_])( *\1){2,} *$');
final RegExp _bulletPattern = RegExp(r'^(\s*)([-*+])\s+(.*)$');
final RegExp _orderedPattern = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
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
  if (text.endsWith('|')) text = text.substring(0, text.length - 1);
  return text.split('|').map((cell) => cell.trim()).toList();
}

// --- Inline parsing -------------------------------------------------------

/// Renders `**bold**`, `*italic*`, `` `code` ``, `~~strike~~` and `[text](url)`.
///
/// Unmatched markers are emitted literally rather than swallowed, so a stray
/// asterisk in prose still shows up.
TextSpan _inline(BuildContext context, String source, TextStyle base) {
  final page = readingColours(context);
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) return;
    spans.add(TextSpan(text: buffer.toString()));
    buffer.clear();
  }

  var i = 0;
  while (i < source.length) {
    final rest = source.substring(i);

    // Inline code wins over every other marker, as in CommonMark.
    if (rest.startsWith('`')) {
      final end = source.indexOf('`', i + 1);
      if (end > i) {
        flush();
        spans.add(_codePill(context, source.substring(i + 1, end), base));
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
          final label = source.substring(start, closeText);
          final url = source.substring(closeText + 2, closeUrl);
          spans.add(
            isImage
                ? TextSpan(
                    text: '[image: $label]',
                    style: TextStyle(color: page.accent),
                  )
                // A link is the one thing a pointer expects an answer from, so
                // it is a widget rather than coloured text: the underline
                // fills in and the ink warms as the pointer crosses it. Still
                // not clickable — the viewer has no business opening a browser
                // — which is exactly why it has to *say* what it is instead.
                : WidgetSpan(
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
          if (!isImage && url != label) {
            spans.add(TextSpan(
              text: ' ($url)',
              style: TextStyle(
                fontSize: base.fontSize! * 0.85,
                color: page.quiet,
              ),
            ));
          }
          i = closeUrl + 1;
          continue;
        }
      }
    }

    final emphasis = _matchEmphasis(source, i);
    if (emphasis != null) {
      flush();
      spans.add(TextSpan(
        text: emphasis.text,
        style: emphasis.style,
      ));
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
    final end = source.indexOf(marker, contentStart);
    // An empty span such as `**` on its own is not emphasis.
    if (end <= contentStart) continue;

    return _Emphasis(
      source.substring(contentStart, end),
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
