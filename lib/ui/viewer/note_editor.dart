import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../viewer/reading_colours.dart';
import '../windows/window_dialogs.dart';

/// Asks for the note written to a marked passage, showing the passage above
/// it. Enter starts a new line — a note is written in sentences — and
/// Cmd+Enter, or Ctrl+Enter, keeps it; Escape leaves it as it was.
///
/// Answers the note, which may be empty to take it away, or null when the
/// window was closed without keeping anything.
Future<String?> promptForNote(
  BuildContext context, {
  required String passage,
  String initialValue = '',
}) {
  final controller = TextEditingController(text: initialValue)
    ..selection = TextSelection.collapsed(offset: initialValue.length);

  return showDeskWindow<String>(
    context,
    title: tr('Note'),
    icon: Icons.sticky_note_2_outlined,
    preferredSize: const Size(520, 340),
    minSize: const Size(360, 260),
    builder: (window) => WindowForm(
      // Reached by Cmd+Enter only: the field keeps a plain Enter for itself.
      onSubmit: () => window.close(controller.text),
      actions: [
        TextButton(onPressed: window.close, child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: () => window.close(controller.text),
          child: Text(tr('Save')),
        ),
      ],
      child: Builder(
        builder: (context) {
          final page = readingColours(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                passage,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: page.quiet,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: null,
                  expands: true,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(hintText: tr('Write a note')),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
