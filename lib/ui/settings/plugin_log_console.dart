import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_registry.dart';
import '../widgets/hint.dart';

/// The plugin log, held against the bottom of the tab like a console.
///
/// One line — the newest — until it is opened, and always in the same place.
/// It used to be a collapsed tile at the end of the feed, which hid the last
/// line and scrolled out of view with everything else: the one thing worth
/// seeing at a glance was the one thing you could not see.
class PluginLogConsole extends StatelessWidget {
  const PluginLogConsole({
    super.key,
    required this.plugins,
    required this.expanded,
    required this.onToggle,
  });

  final PluginRegistry plugins;
  final bool expanded;
  final VoidCallback onToggle;

  /// How tall the log gets when opened. Enough to read a traceback in, not so
  /// much that the feed disappears behind it.
  static const double openHeight = 190;

  @override
  Widget build(BuildContext context) {
    final log = plugins.log;
    if (log.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final last = log.last;
    final wrong = last.level == 'error' || last.level == 'stderr';

    return Material(
      color: scheme.surfaceContainerHighest,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1),
          InkWell(
            onTap: onToggle,
            child: SizedBox(
              height: 26,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Icon(
                    expanded ? Icons.expand_more : Icons.expand_less,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      expanded
                          ? tr('Plugin log ({count})', {'count': log.length})
                          : last.toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: wrong && !expanded ? scheme.error : null,
                      ),
                    ),
                  ),
                  Hint(
                    message: tr('Copy the log'),
                    child: IconButton(
                      iconSize: 14,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.copy),
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: log.join('\n'))),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            SizedBox(
              height: openHeight,
              child: ListView(
                // Newest at the bottom, and that end is what is shown: a log
                // is read from where it got to.
                reverse: true,
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                children: [
                  for (final record in log.reversed)
                    Text(
                      record.toString(),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: record.level == 'error' ? scheme.error : null,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
