import 'package:flutter/material.dart';

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
