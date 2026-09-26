import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../../core/reading/reading_store.dart';
import '../../core/settings/appearance_settings.dart';
import '../motion.dart';
import '../plugins/plugin_table.dart' show appearanceOf;
import 'document_memory.dart';
import 'markdown_view.dart' show kMarkerColours;
import 'reading_colours.dart';
import 'reading_link.dart';

/// The panel beside a document, as a book reader has it: its contents, and
/// what has been marked in it — two tabs over one panel.
///
/// **One panel, one key, one Escape**, as before: the tabs are a choice inside
/// it rather than a second panel. A press on a tab or Ctrl+Tab changes which
/// is shown; the keyboard stays where it was.
class ReadingTabs extends StatefulWidget {
  const ReadingTabs({
    super.key,
    required this.contents,
    required this.memory,
    required this.link,
    required this.focusNode,
    required this.onNote,
  });

  /// The structure panel, as it is everywhere else.
  final Widget contents;

  final DocumentMemory memory;
  final ReadingLink link;

  /// The panel's own focus — the same one the contents use, so that Tab into
  /// the panel and Escape out of it work whichever tab is showing.
  final FocusNode focusNode;

  /// Asks for a highlight's note to be written.
  final void Function(Highlight highlight) onNote;

  @override
  State<ReadingTabs> createState() => _ReadingTabsState();
}

class _ReadingTabsState extends State<ReadingTabs> {
  /// Which tab was last shown, for the whole session: somebody going through
  /// what they marked in one book goes on doing it in the next.
  static bool _marks = false;

  void _switch() => setState(() => _marks = !_marks);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.tab &&
        HardwareKeyboard.instance.isControlPressed) {
      _switch();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = appearanceOf(context);
    final ink =
        DefaultTextStyle.of(context).style.color ?? readingColours(context).ink;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
            child: Row(
              children: [
                _Tab(
                  label: tr('Contents'),
                  chosen: !_marks,
                  ink: ink,
                  theme: theme,
                  onTap: () => setState(() => _marks = false),
                ),
                const SizedBox(width: 4),
                ListenableBuilder(
                  listenable: widget.memory,
                  builder: (context, _) => _Tab(
                    label: widget.memory.highlights.isEmpty
                        ? tr('Highlights')
                        : '${tr('Highlights')} ${widget.memory.highlights.length}',
                    chosen: _marks,
                    ink: ink,
                    theme: theme,
                    onTap: () => setState(() => _marks = true),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: motionOf(context, kOutlineRowDuration),
              child: _marks
                  ? HighlightsList(
                      key: const ValueKey('marks'),
                      memory: widget.memory,
                      link: widget.link,
                      focusNode: widget.focusNode,
                      onNote: widget.onNote,
                    )
                  : KeyedSubtree(
                      key: const ValueKey('contents'),
                      child: widget.contents,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.chosen,
    required this.ink,
    required this.theme,
    required this.onTap,
  });

  final String label;
  final bool chosen;
  final Color ink;
  final AppearanceSettings theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: motionOf(context, kOutlineRowDuration),
        curve: kArrivingCurve,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: chosen ? ink.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: theme.fontSize - 1,
            color: ink.withValues(alpha: chosen ? 1 : 0.65),
            fontWeight: chosen ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    ),
  );
}

/// Everything marked in the document, in reading order: the passage, its
/// colour, its note. Enter goes there, N writes the note, Delete takes the
/// mark away.
class HighlightsList extends StatefulWidget {
  const HighlightsList({
    super.key,
    required this.memory,
    required this.link,
    required this.focusNode,
    required this.onNote,
  });

  final DocumentMemory memory;
  final ReadingLink link;
  final FocusNode focusNode;
  final void Function(Highlight highlight) onNote;

  @override
  State<HighlightsList> createState() => _HighlightsListState();
}

class _HighlightsListState extends State<HighlightsList> {
  int _cursor = 0;
  final Map<String, GlobalKey> _keys = {};

  List<Highlight> get _ordered {
    final list = [...widget.memory.highlights];
    list.sort((a, b) {
      final block = a.start.block.compareTo(b.start.block);
      return block != 0 ? block : a.start.offset.compareTo(b.start.offset);
    });
    return list;
  }

  void _go(Highlight highlight) => widget.link.goToMark(highlight.id);

  void _move(int by, int count) {
    if (count == 0) return;
    setState(() => _cursor = (_cursor + by).clamp(0, count - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final list = _ordered;
      if (_cursor >= list.length) return;
      final row = _keys[list[_cursor].id]?.currentContext;
      if (row != null) {
        Scrollable.ensureVisible(
          row,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          duration: motionOf(context, kOutlineRowDuration),
        );
        Scrollable.ensureVisible(
          row,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          duration: motionOf(context, kOutlineRowDuration),
        );
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final list = _ordered;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1, list.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1, list.length);
      return KeyEventResult.handled;
    }
    if (list.isEmpty || event is! KeyDownEvent) return KeyEventResult.ignored;
    final current = list[_cursor.clamp(0, list.length - 1)];
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _go(current);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      widget.memory.remove(current.id);
      setState(() => _cursor = _cursor.clamp(0, (list.length - 2).clamp(0, 1 << 30)));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyN) {
      widget.onNote(current);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = appearanceOf(context);
    final ink =
        DefaultTextStyle.of(context).style.color ?? readingColours(context).ink;
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      onFocusChange: (_) => setState(() {}),
      child: ListenableBuilder(
        listenable: widget.memory,
        builder: (context, _) {
          final list = _ordered;
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  tr('Nothing is marked yet. Select a passage to mark it.'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ink.withValues(alpha: 0.6),
                    fontSize: theme.fontSize - 1,
                  ),
                ),
              ),
            );
          }
          final cursor = _cursor.clamp(0, list.length - 1);
          final keyboard = widget.focusNode.hasFocus;
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final highlight = list[i];
              return _HighlightRow(
                key: _keys.putIfAbsent(highlight.id, GlobalKey.new),
                highlight: highlight,
                ink: ink,
                theme: theme,
                cursor: i == cursor && keyboard,
                onTap: () {
                  setState(() => _cursor = i);
                  widget.focusNode.requestFocus();
                  _go(highlight);
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _HighlightRow extends StatelessWidget {
  const _HighlightRow({
    super.key,
    required this.highlight,
    required this.ink,
    required this.theme,
    required this.cursor,
    required this.onTap,
  });

  final Highlight highlight;
  final Color ink;
  final AppearanceSettings theme;
  final bool cursor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colour =
        kMarkerColours[highlight.colour.clamp(0, kMarkerColours.length - 1)];
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: motionOf(context, kOutlineRowDuration),
          curve: kArrivingCurve,
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          decoration: BoxDecoration(
            color: cursor ? theme.cursorColor.withValues(alpha: 0.45) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: colour,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        highlight.text.replaceAll('\n', ' '),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ink.withValues(alpha: 0.92),
                          fontSize: theme.fontSize - 1,
                          height: 1.3,
                        ),
                      ),
                      if (highlight.note.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          highlight.note,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: ink.withValues(alpha: 0.65),
                            fontSize: theme.fontSize - 1.5,
                            fontStyle: FontStyle.italic,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
