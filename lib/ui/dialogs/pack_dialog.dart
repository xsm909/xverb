import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_registry.dart';
import '../../core/vfs/archive_actions.dart';
import '../widgets/choice_button.dart';
import '../windows/window_dialogs.dart';

/// Where a new archive goes and what kind it is.
///
/// **Two ways to say one thing.** The kind is a list to pick from, and the name
/// carries an extension — and the extension is the truth, because it is what
/// decides which plugin writes the file and it is what the user sees. Picking a
/// kind therefore *edits the name*, and typing an extension by hand shows which
/// kind that is. There is no third state where the two disagree: they cannot,
/// because there is only one value.
///
/// Which is why the list can say "as the name says". Somebody who types
/// `.tar.bz2` has asked for something no entry in the list offers as a default,
/// and the honest answer is to stop claiming otherwise rather than to correct
/// what they typed.
Future<String?> askPackTarget(
  BuildContext context, {
  required String initialValue,
  required int selectionStart,
  required int selectionEnd,
  required List<PackFormat> formats,
  required int count,
}) {
  final controller = TextEditingController(text: initialValue);
  controller.selection = TextSelection(
    baseOffset: selectionStart.clamp(0, initialValue.length),
    extentOffset: selectionEnd.clamp(0, initialValue.length),
  );

  return showDeskWindow<String>(
    context,
    title: tr('Pack {count} item(s)', {'count': '$count'}),
    icon: Icons.archive_outlined,
    preferredSize: const Size(560, 230),
    minSize: const Size(380, 200),
    builder: (window) => _PackForm(
      controller: controller,
      formats: formats,
      onSubmit: () => window.close(controller.text),
      onCancel: window.close,
    ),
  );
}

class _PackForm extends StatefulWidget {
  const _PackForm({
    required this.controller,
    required this.formats,
    required this.onSubmit,
    required this.onCancel,
  });

  final TextEditingController controller;
  final List<PackFormat> formats;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  @override
  State<_PackForm> createState() => _PackFormState();
}

class _PackFormState extends State<_PackForm> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_typed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_typed);
    super.dispose();
  }

  /// The name changed, so which kind is selected may have changed with it.
  void _typed() => setState(() {});

  /// The extension the name ends in, or an empty string.
  String get _extension => archiveExtensionOf(widget.controller.text);

  /// The kind the name says it is, or null for one the list does not offer.
  PackFormat? get _chosen {
    final extension = _extension;
    for (final format in widget.formats) {
      if (format.extension == extension) return format;
    }
    return null;
  }

  /// Picking a kind rewrites the name, keeping the folder and the stem.
  ///
  /// The caret is left at the end of the stem rather than wherever it was: the
  /// extension has just moved under it, and a caret standing in the middle of
  /// the new one would be somewhere nobody put it.
  void _pick(String extension) {
    final rewritten = withArchiveExtension(widget.controller.text, extension);
    final dot = rewritten.lastIndexOf('.');
    widget.controller.value = TextEditingValue(
      text: rewritten,
      selection: TextSelection.collapsed(
        offset: dot > 0 ? dot : rewritten.length,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chosen = _chosen;

    return WindowForm(
      onSubmit: widget.onSubmit,
      actions: [
        TextButton(onPressed: widget.onCancel, child: Text(tr('Cancel'))),
        FilledButton(onPressed: widget.onSubmit, child: Text(tr('Pack'))),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: widget.controller,
            autofocus: true,
            decoration: InputDecoration(labelText: tr('Archive')),
            onSubmitted: (_) => widget.onSubmit(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(tr('Kind')),
              const SizedBox(width: 12),
              Expanded(
                child: ChoiceButton<String>(
                  value: chosen?.extension ?? '',
                  placeholder: tr('As the name says'),
                  // **The title alone.** The extension used to be spelled out
                  // after every one of them — *ZIP archive · .zip* — and it is
                  // said twice already: the name being packed is on the line
                  // above and ends in it, and picking a kind is what rewrites
                  // that ending. The title is the plugin's own sentence and is
                  // the part that means something; the suffix was noise wide
                  // enough to push *Tarball, no compression* off the end of its
                  // own row. Reported 2026-09-06.
                  //
                  // The icon is gone with it: a list where every row carries the
                  // same picture says nothing with it, and the menu draws the
                  // tick in that slot anyway.
                  options: [
                    for (final format in widget.formats)
                      ChoiceOption(format.extension, format.title),
                  ],
                  onChanged: _pick,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
