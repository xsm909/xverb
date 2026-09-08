import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/facts.dart';
import '../../core/settings/appearance_settings.dart';
import '../plugins/plugin_table.dart' show appearanceOf;
import 'reading_colours.dart';
import '../picture_filter.dart';

/// What the file being looked at says about itself, in the panel the structure
/// of a document uses.
///
/// **The same slide panel as a document's structure, and not a second kind of
/// thing.** Which is right for a reason beyond consistency: a document has an
/// outline and a
/// photograph has none, so the two never want the panel at the same moment,
/// and one panel with one width, one key and one Escape is one thing to learn.
///
/// **It knows nothing about cameras.** The groups, their order and their names
/// are the describer's, so the host does not grow an opinion about which of two
/// hundred EXIF tags matter — see `facts.dart`.
class FactsPanel extends StatefulWidget {
  const FactsPanel({
    super.key,
    required this.facts,
    required this.focusNode,
    required this.onLeave,
    required this.onClose,
    this.loading = false,
  });

  /// What was read, or null while it is still being read.
  final FileFacts? facts;

  /// Whether the answer is still on its way.
  final bool loading;

  /// The panel's own place in the focus order, shared with the structure — the
  /// page hands the keyboard back and forth and there is only ever one panel.
  final FocusNode focusNode;

  /// Give the reading the keyboard back — Tab.
  final VoidCallback onLeave;

  /// Put the panel away — Escape.
  final VoidCallback onClose;

  @override
  State<FactsPanel> createState() => _FactsPanelState();
}

class _FactsPanelState extends State<FactsPanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// The panel's own keys, and only the two it owes: Escape puts it away and
  /// Tab gives the reading back. There is nothing here to walk — a fact is not
  /// somewhere to go, which is the whole difference between this and the
  /// structure — so the arrows are the scroll's and stay that way.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      widget.onLeave();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = appearanceOf(context);
    final ink =
        DefaultTextStyle.of(context).style.color ?? readingColours(context).ink;
    final facts = widget.facts;

    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      onFocusChange: (_) => setState(() {}),
      child: SelectionArea(
        child: widget.loading || facts == null
            ? _Remark(text: tr('Reading…'), ink: ink, theme: theme)
            : ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                children: [
                  // The cover first, because it is what the eye goes to and
                  // because a picture under six lines of tags reads as an
                  // afterthought. Fitted to the panel and never taller than it
                  // is wide: a square sleeve and a tall poster both have to
                  // leave room for the words.
                  if (facts.picture != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.memory(
                        facts.picture!,
                        fit: BoxFit.contain,
                        filterQuality: pictureSmoothing,
                        // A cover that cannot be decoded is a missing cover,
                        // not a broken panel.
                        errorBuilder: (context, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  for (final group in facts.groups) ...[
                    if (group.facts.isNotEmpty)
                      _GroupTitle(title: group.title, ink: ink, theme: theme),
                    for (final fact in group.facts)
                      _FactRow(fact: fact, ink: ink, theme: theme),
                    const SizedBox(height: 12),
                  ],
                  if (facts.error != null)
                    _Remark(text: facts.error!, ink: ink, theme: theme)
                  else if (facts.note != null)
                    _Remark(text: facts.note!, ink: ink, theme: theme),
                ],
              ),
      ),
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle({
    required this.title,
    required this.ink,
    required this.theme,
  });

  final String title;
  final Color ink;
  final AppearanceSettings theme;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      title,
      style: TextStyle(
        color: ink,
        fontSize: theme.fontSize - 1,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

/// One label and what the file says for it.
///
/// Side by side while both are short, and the value under its own label when
/// the describer said it is a wide one — a comment or a description read as a
/// squeezed column of two words otherwise.
class _FactRow extends StatelessWidget {
  const _FactRow({required this.fact, required this.ink, required this.theme});

  final Fact fact;
  final Color ink;
  final AppearanceSettings theme;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      fact.label,
      style: TextStyle(
        color: ink.withValues(alpha: 0.6),
        fontSize: theme.fontSize - 1,
      ),
    );
    final value = Text(
      fact.value,
      style: TextStyle(color: ink, fontSize: theme.fontSize - 1),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: fact.wide
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [label, value],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A fixed share rather than the widest label: the labels differ
                // from file to file, and a column that moves as you walk a
                // folder is a column that flickers.
                SizedBox(width: 108, child: label),
                Expanded(child: value),
              ],
            ),
    );
  }
}

class _Remark extends StatelessWidget {
  const _Remark({required this.text, required this.ink, required this.theme});

  final String text;
  final Color ink;
  final AppearanceSettings theme;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Text(
      text,
      style: TextStyle(
        color: ink.withValues(alpha: 0.6),
        fontSize: theme.fontSize - 1,
      ),
    ),
  );
}
