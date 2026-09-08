import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_registry.dart';
import '../../core/plugins/viewer.dart';
import '../../core/settings/settings_store.dart';
import '../../state/app_state.dart';
import '../notice.dart';
import '../page_transition.dart';
import '../viewer/plugin_viewer_page.dart';
import '../widgets/escape_to_pop.dart';
import '../widgets/title_bar.dart';
import '../windows/window_layer.dart';

/// Runs a plugin command and shows whatever it returned, as a page.
///
/// A command may legitimately return nothing — it did something rather than
/// produced something — so a null result closes the loop quietly instead of
/// opening an empty page. Shared by every surface a command can be invoked
/// from, so a command behaves the same wherever it was pressed.
Future<void> runPluginCommand(
  BuildContext context,
  PluginCommand command,
) async {
  final title = command.title;
  final app = context.read<AppState>();

  // One page per command. Claimed before the command is even run, because the
  // slow ones are exactly the ones whose icon gets pressed twice.
  if (!app.claimPage(command.spec.id)) return;

  try {
    ViewerContent content;
    try {
      final result = await command.invoke(const {});
      if (result is! Map) return;
      content = ViewerContent.fromJson(Map<String, dynamic>.from(result));
    } on Object catch (e) {
      content = ViewerContent.error(
          tr('{name} failed: {error}', {'name': title, 'error': e}));
    }
    if (!context.mounted) return;

    await PluginCommandPage.open(
      context,
      title: title,
      content: content,
      command: command,
    );
  } finally {
    app.releasePage(command.spec.id);
  }
}

/// What a plugin command produced, as a page you go to and come back from.
///
/// A page rather than a floating window: this is a report to be read and
/// usually copied, and a window that has to be moved out of the way to read the
/// rest of it is in the way. It follows the settings page in drawing its own
/// [TitleBar] — a route covers the whole client area, and with the system bar
/// hidden that is the only thing left to drag the window by.
class PluginCommandPage extends StatefulWidget {
  const PluginCommandPage({
    super.key,
    required this.title,
    required this.content,
    this.command,
  });

  final String title;
  final ViewerContent content;

  /// The command that produced this, so the page can go back to it.
  ///
  /// **What makes a form worth sending.** A plugin could already return one and
  /// the page could already draw it — but the button pressed at the end of it
  /// went nowhere, so the answer never got home and the form was a picture of a
  /// form. This is the way back: the same command, invoked again, carrying which
  /// button was pressed and what every field held.
  ///
  /// Null where there is nothing to go back to, which is how a plain report
  /// behaves and how a test can draw one page without a plugin behind it.
  final PluginCommand? command;

  static Future<void> open(
    BuildContext context, {
    required String title,
    required ViewerContent content,
    PluginCommand? command,
  }) =>
      Navigator.of(context).push(
        MotionPageRoute<void>.of(
          context,
          builder: (_) => PluginCommandPage(
            title: title,
            content: content,
            command: command,
          ),
        ),
      );

  @override
  State<PluginCommandPage> createState() => _PluginCommandPageState();
}

class _PluginCommandPageState extends State<PluginCommandPage> {
  late ViewerContent _content = widget.content;

  /// True while the plugin is thinking about what was just pressed.
  ///
  /// The button goes quiet rather than the page: what was typed stays on
  /// screen, because a plugin that takes two seconds must not look as though it
  /// threw the sentence away.
  bool _asking = false;

  String get title => widget.title;

  ViewerContent get content => _content;

  /// A button on the page was pressed: back to the plugin with what it held.
  ///
  /// What comes back replaces the page — a form can answer with another form,
  /// or with the report of what it did. **Nothing** at all means the command is
  /// over and the page goes away, which is the same rule as the first call:
  /// a command that returns nothing did something rather than produced
  /// something.
  ///
  /// A failure keeps the page exactly as it is and says so in a remark. The
  /// fields still hold what was typed, which is the whole point — an error is
  /// the moment somebody is most likely to want to press the button again.
  Future<void> _answer(String buttonId, Map<String, Object?> values) async {
    final command = widget.command;
    if (command == null || _asking) return;

    setState(() => _asking = true);
    try {
      final result = await command.invoke({
        'button': buttonId,
        'values': values,
      });
      if (!mounted) return;
      if (result is! Map) {
        Navigator.of(context).pop();
        return;
      }
      setState(() =>
          _content = ViewerContent.fromJson(Map<String, dynamic>.from(result)));
    } on Object catch (e) {
      if (!mounted) return;
      showNotice(
        context,
        tr('{name} failed: {error}', {'name': widget.title, 'error': e}),
        long: true,
      );
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// The source behind the page, for the clipboard. Markdown and text carry it
  /// directly; a table is worth having as text too, so it is written out as
  /// one rather than refusing to copy.
  String? get _copyable => switch (content.kind) {
        ViewerContentKind.markdown ||
        ViewerContentKind.text =>
          content.text,
        ViewerContentKind.error => content.message,
        ViewerContentKind.table => content.rows
            .map((row) => row.text.join('\t'))
            .join('\n'),
        // A picture and a ring chart are both shapes, not text. There is
        // nothing honest to put on the clipboard for either — and neither is
        // a page of several things, whose parts each want a different answer,
        // nor a form, whose text is the user's own and not the page's.
        ViewerContentKind.form ||
        ViewerContentKind.image ||
        ViewerContentKind.chart ||
        ViewerContentKind.mesh3d ||
        ViewerContentKind.nodes ||
        ViewerContentKind.vector ||
        ViewerContentKind.audio ||
        ViewerContentKind.split ||
        ViewerContentKind.file =>
          null,
      };

  Future<void> _copy(BuildContext context) async {
    final text = _copyable;
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) showNotice(context, tr('Copied to the clipboard.'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final canCopy = (_copyable ?? '').isNotEmpty;

    return EscapeToPop(
      child: ColoredBox(
        color: theme.effectivePanelBackground,
        child: Column(
          children: [
            // The application's bar carries this page's chrome, the way it
            // does for a view: back and the title on the left, the page's own
            // button beside the window's. A command declares no menu of its
            // own, so the strip is simply empty — which is the answer, not an
            // omission. The application's menus are about a listing that is
            // not on screen.
            TitleBar(
              leading: [
                TitleBarButton(
                  icon: Icons.arrow_back,
                  tooltip: tr('Back'),
                  onPressed: Navigator.of(context).pop,
                ),
              ],
              title: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: TitleBar.titleStyle(theme),
              ),
              actions: [
                TitleBarButton(
                  icon: Icons.copy,
                  tooltip: tr('Copy'),
                  onPressed: canCopy ? () => _copy(context) : null,
                ),
              ],
            ),
            Expanded(
              child: WindowLayer(
                stack: context.read<AppState>().windows,
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: PluginContentView(
                    content: content,
                    pluginId: widget.command?.pluginId,
                    // Only where there is a plugin to answer: a page with
                    // nothing behind it draws its form dead rather than
                    // pretending to take an answer.
                    onButton: widget.command == null || _asking
                        ? null
                        : (id, values) => unawaited(_answer(id, values)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
