import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../../core/settings/appearance_settings.dart';
import '../widgets/hint.dart';

/// The box a reading is searched through — and now a canvas too.
///
/// **One shape for "search inside what you are looking at."** It floats over
/// what it searches rather than pushing it down, because a bar that moves the
/// text moves the line somebody was reading; Escape puts it away; F3 and
/// Shift+F3 walk the matches without going back to it. Items 69 and 73 settled
/// all of that for a page of text, and a graph asks exactly the same question of
/// its nodes — so it asks it with the same box rather than a second one that
/// drifts.
class FindBox extends StatelessWidget {
  const FindBox({
    super.key,
    required this.query,
    required this.node,
    required this.theme,
    required this.matches,
    required this.current,
    this.hint,
    this.truncated = false,
    this.note,
    this.options = const [],
    required this.onChanged,
    required this.onStep,
    required this.onClose,
  });

  final TextEditingController query;
  final FocusNode node;
  final AppearanceSettings theme;
  final int matches;
  final int current;

  /// What the empty box says it will look through. Null is the reading's own
  /// words, which is what every caller but the canvas wants.
  final String? hint;

  final bool truncated;

  /// A line under the box about the search itself — still going, stopped
  /// short. Null says nothing.
  final String? note;

  /// Switches that change what is searched, drawn in a row under the field.
  /// A reading has none; a sheet has two.
  final List<FindOption> options;

  final ValueChanged<String> onChanged;
  final ValueChanged<int> onStep;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // The header's own ink, because the box is drawn on the header's own fill
    // — the same argument as the viewer's status strip. It was the *panel's*
    // ink, which was the same colour until the reading was given a pair of its
    // own and then was a third palette on a bar belonging to neither.
    final ink = theme.headerForeground;
    final said = query.text.isEmpty
        ? ''
        : matches == 0
        ? tr('nothing')
        : '$current/$matches';

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(6),
      color: theme.effectiveHeaderBackground,
      child: Container(
        width: 320,
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  // **Up and down walk what was found; left and right stay
                  // the field's.** A one-line field has no use for up and
                  // down, so while there is something found they are the
                  // way through it — the hand is already on the arrows, and
                  // reaching for F3 or the little buttons was the detour.
                  // With nothing found they go on up as before.
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: (_, event) {
                      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                        return KeyEventResult.ignored;
                      }
                      if (matches == 0) return KeyEventResult.ignored;
                      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                        onStep(1);
                        return KeyEventResult.handled;
                      }
                      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                        onStep(-1);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      controller: query,
                      focusNode: node,
                      autofocus: true,
                      style: TextStyle(color: ink, fontSize: theme.fontSize),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: hint ?? tr('Find in this file'),
                        hintStyle: TextStyle(
                          color: ink.withValues(alpha: 0.4),
                          fontSize: theme.fontSize,
                        ),
                      ),
                      onChanged: onChanged,
                    ),
                  ),
                ),
                Text(
                  said,
                  style: TextStyle(
                    color: ink.withValues(alpha: 0.6),
                    fontSize: theme.fontSize - 1,
                  ),
                ),
                Hint(
                  message: tr('Previous (Shift+F3)'),
                  child: IconButton(
                    icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                    visualDensity: VisualDensity.compact,
                    color: ink,
                    onPressed: matches == 0 ? null : () => onStep(-1),
                  ),
                ),
                Hint(
                  message: tr('Next (F3)'),
                  child: IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                    visualDensity: VisualDensity.compact,
                    color: ink,
                    onPressed: matches == 0 ? null : () => onStep(1),
                  ),
                ),
                Hint(
                  message: tr('Close (Esc)'),
                  child: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                    color: ink,
                    onPressed: onClose,
                  ),
                ),
              ],
            ),
            if (options.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final option in options)
                      _OptionChip(option: option, theme: theme),
                  ],
                ),
              ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(left: 2, top: 4),
                child: Text(
                  note!,
                  style: TextStyle(
                    color: ink.withValues(alpha: 0.55),
                    fontSize: theme.fontSize - 2,
                  ),
                ),
              ),
            if (truncated)
              Padding(
                padding: const EdgeInsets.only(left: 2, top: 2),
                child: Text(
                  // Never silently: the rest of the file was never read, so
                  // there is nothing here that could have found anything in it.
                  tr('Only as much of the file as was read.'),
                  style: TextStyle(
                    color: ink.withValues(alpha: 0.55),
                    fontSize: theme.fontSize - 2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One switch under a find box: a word that is on or off.
class FindOption {
  const FindOption({
    required this.label,
    required this.on,
    required this.onPressed,
    this.enabled = true,
  });

  final String label;
  final bool on;
  final bool enabled;
  final VoidCallback onPressed;
}

/// A switch drawn as a pill, filled in the accent while it is on — the shape
/// every other choice of this size already has here.
class _OptionChip extends StatelessWidget {
  const _OptionChip({required this.option, required this.theme});

  final FindOption option;
  final AppearanceSettings theme;

  @override
  Widget build(BuildContext context) {
    final ink = theme.headerForeground;
    final on = option.on && option.enabled;
    final fill = on
        ? theme.accentColor.withValues(alpha: 0.85)
        : ink.withValues(alpha: 0.07);
    final text = on
        ? (theme.accentColor.computeLuminance() > 0.5
              ? Colors.black
              : Colors.white)
        : ink.withValues(alpha: option.enabled ? 0.85 : 0.35);
    return MouseRegion(
      cursor: option.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: option.enabled ? option.onPressed : null,
        child: AnimatedContainer(
          duration: theme.animated(120),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Text(
            option.label,
            style: TextStyle(color: text, fontSize: theme.fontSize - 2),
          ),
        ),
      ),
    );
  }
}
