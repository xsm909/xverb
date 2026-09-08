import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../../core/version.dart';
import '../../core/vfs/file_entry.dart';
import '../../core/vfs/file_operations.dart';
import '../format.dart';
import '../notice.dart';
import '../windows/window_dialogs.dart';

/// Asks for a single line of text — new folder name, rename, connection URL.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  String initialValue = '',
  String? hint,
  String confirmLabel = 'OK',

  /// Characters to preselect, used by rename to skip the extension.
  int? selectionEnd,

  /// Where the preselection starts. Copying under a new name prefills the whole
  /// destination path and selects only the name in it, so typing replaces the
  /// name while the folder stays there to be edited if it needs to be.
  int selectionStart = 0,
}) {
  final controller = TextEditingController(text: initialValue);
  controller.selection = TextSelection(
    baseOffset: selectionStart.clamp(0, initialValue.length),
    extentOffset: selectionEnd ?? initialValue.length,
  );

  return showDeskWindow<String>(
    context,
    title: title,
    icon: Icons.edit_outlined,
    preferredSize: const Size(460, 190),
    minSize: const Size(320, 160),
    builder: (window) => WindowForm(
      onSubmit: () => window.close(controller.text),
      actions: [
        TextButton(onPressed: window.close, child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: () => window.close(controller.text),
          child: Text(tr(confirmLabel)),
        ),
      ],
      child: Align(
        alignment: Alignment.topCenter,
        child: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: window.close,
        ),
      ),
    ),
  );
}

/// Yes/no confirmation. Returns false when dismissed.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'OK',
  bool destructive = false,
}) async {
  final result = await showDeskWindow<bool>(
    context,
    title: title,
    icon: destructive ? Icons.warning_amber_outlined : Icons.help_outline,
    preferredSize: const Size(480, 210),
    minSize: const Size(340, 170),
    builder: (window) => WindowForm(
      onSubmit: () => window.close(true),
      actions: [
        TextButton(
          onPressed: () => window.close(false),
          child: Text(tr('Cancel')),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          onPressed: () => window.close(true),
          child: Text(tr(confirmLabel)),
        ),
      ],
      child: Align(alignment: Alignment.topLeft, child: Text(message)),
    ),
  );
  return result ?? false;
}

/// A failure that stays until it has been read, and can be taken away whole.
///
/// **A remark along the bottom is the wrong shape for a failure.** It is right
/// for "no viewer for that one" — something noticed, not something to act on —
/// and it leaves after a second and a half with no way back to it. An update
/// that did not happen proved the difference: Windows said why, and the
/// sentence was gone before it could be read, so the reason was lost along
/// with any chance of acting on it.
///
/// So a window: it stays until it is closed, the text is selectable rather
/// than drawn, and Copy puts the whole of it — title, reason, detail, and
/// which build on which system this was — on the clipboard, because the thing
/// a person does next with a failure is send it to somebody.
///
/// Escape and Close both end it, and Enter does too: there is one way out of a
/// report and nothing to decide.
Future<void> showProblem(
  BuildContext context, {
  required String title,
  required String message,
  String? detail,
}) async {
  final full = [
    title,
    '',
    message,
    if (detail != null && detail.isNotEmpty) ...['', detail],
    '',
    'xverb $kAppVersion · ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}',
  ].join('\n');

  await showDeskWindow<void>(
    context,
    title: title,
    icon: Icons.error_outline,
    preferredSize: const Size(560, 320),
    minSize: const Size(360, 220),
    builder: (window) => WindowForm(
      onSubmit: window.close,
      actions: [
        TextButton(
          onPressed: () => unawaited(_copyProblem(context, full)),
          child: Text(tr('Copy')),
        ),
        FilledButton(onPressed: window.close, child: Text(tr('Close'))),
      ],
      // Scrolls rather than clips: a path on Windows is long, and a reason
      // half of which is off the edge of the window is the same failure as a
      // reason that left too soon.
      child: ListView(
        children: [
          SelectableText(message),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              detail,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    ),
  );
}

/// The report onto the desktop's clipboard, and a word that it went.
///
/// The window stays open, for the same reason the errors window does: the
/// point of copying is to take it somewhere else, and closing what was being
/// read is not part of that.
Future<void> _copyProblem(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showNotice(context, tr('Copied to the clipboard.'));
}

/// Asks for a word to be typed before the button will work.
///
/// A confirmation that is one press away is a confirmation the hand learns to
/// give without the eye; typing the word takes a moment of attention, which is
/// the whole of what is wanted here. It came out of the disk map's Clean up,
/// where a single press throws away everything under a wedge.
///
/// The word is asked for in the language the application is speaking, because
/// it has to be read before it can be typed.
/// Trimmed and compared without case: this is a pause, not a spelling test.
Future<bool> confirmByTyping(
  BuildContext context, {
  required String title,
  required String message,
  required String word,
  String confirmLabel = 'OK',
}) async {
  final controller = TextEditingController();

  final result = await showDeskWindow<bool>(
    context,
    title: title,
    icon: Icons.warning_amber_outlined,
    preferredSize: const Size(500, 260),
    minSize: const Size(360, 220),
    builder: (window) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final said =
            controller.text.trim().toLowerCase() == word.trim().toLowerCase();
        return WindowForm(
          // Enter is the button, and the button is not live until the word is
          // there — so Enter cannot get past this either.
          onSubmit: said ? () => window.close(true) : null,
          actions: [
            TextButton(
              onPressed: () => window.close(false),
              child: Text(tr('Cancel')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: said ? () => window.close(true) : null,
              child: Text(tr(confirmLabel)),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message),
              const SizedBox(height: 12),
              Text(tr('Type {word} to allow it', {'word': word})),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: word,
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
  return result ?? false;
}

/// An answer to one collision, and how far that answer reaches.
///
/// The checkbox in the window does not answer anything by itself: it says that
/// whichever button is pressed next stands for every collision still to come.
@immutable
class ConflictChoice {
  const ConflictChoice(this.action, {this.applyToAll = false});

  final ConflictAction action;
  final bool applyToAll;
}

/// Asks one collision, and is what a [ConflictPolicy] asks with.
typedef ConflictAsk = Future<ConflictChoice> Function(
  BuildContext context,
  FileEntry source,
  FileEntry existing,
);

/// One operation's memory of a collision already answered.
///
/// Eight hundred files landing on eight hundred that are already there is eight
/// hundred presses of Skip, and nobody presses Skip eight hundred times — they
/// press it twice and then abort the whole thing. So the window offers "Apply
/// to all", and this holds what that meant until the operation ends. A new one
/// is made for every command: what was decided about last night's copy has no
/// business deciding anything about this one.
///
/// Abort is never remembered. It ends the operation on the spot, so there is
/// nothing left for it to reach.
class ConflictPolicy {
  ConflictPolicy({ConflictAsk? ask}) : _ask = ask ?? askConflict;

  final ConflictAsk _ask;
  ConflictAction? _forEverything;

  /// True once an answer has been given for the whole operation.
  bool get isSettled => _forEverything != null;

  /// A [ConflictResolver] for [FileOperations]: asks, unless it already knows.
  Future<ConflictAction> resolve(
    BuildContext context,
    FileEntry source,
    FileEntry existing,
  ) async {
    final remembered = _forEverything;
    if (remembered != null) return remembered;

    final choice = await _ask(context, source, existing);
    if (choice.applyToAll && choice.action != ConflictAction.abort) {
      _forEverything = choice.action;
    }
    return choice.action;
  }
}

/// Shown when a target file already exists during a copy or move.
Future<ConflictChoice> askConflict(
  BuildContext context,
  FileEntry source,
  FileEntry existing,
) async {
  // Read at the moment a button is pressed, not before: the box can be ticked
  // after the eye has already chosen what to press.
  final applyToAll = ValueNotifier(false);
  ConflictChoice answer(ConflictAction action) =>
      ConflictChoice(action, applyToAll: applyToAll.value);

  final result = await showDeskWindow<ConflictChoice>(
    context,
    title: tr('File already exists'),
    icon: Icons.file_copy_outlined,
    // Room for the checkbox and its line of explanation, including the width
    // at which that line wraps: the window can be shrunk, and a question that
    // overflows at its smallest size is a question that cannot be read.
    preferredSize: const Size(560, 350),
    minSize: const Size(420, 330),
    builder: (window) => ListenableBuilder(
      listenable: applyToAll,
      builder: (context, _) => WindowForm(
        onSubmit: () => window.close(answer(ConflictAction.overwrite)),
        actions: [
          TextButton(
            onPressed: () => window.close(answer(ConflictAction.abort)),
            child: Text(tr('Abort')),
          ),
          TextButton(
            onPressed: () => window.close(answer(ConflictAction.skip)),
            child: Text(tr('Skip')),
          ),
          TextButton(
            onPressed: () => window.close(answer(ConflictAction.autoRename)),
            child: Text(tr('Rename')),
          ),
          FilledButton(
            onPressed: () => window.close(answer(ConflictAction.overwrite)),
            child: Text(tr('Overwrite')),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              existing.name,
              // Two lines and then an ellipsis. Measured at the size this
              // window can be shrunk to: a name allowed to wrap for as long as
              // it likes pushes the checkbox off the bottom.
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(tr('Source: {size}', {'size': formatSize(source.size)})),
            Text(
              tr('Target: {size} · {date}', {
                'size': formatSize(existing.size),
                'date': formatDate(existing.modified),
              }),
            ),
            const Spacer(),
            // Tab reaches it and Space ticks it: the answer for the rest of the
            // operation is not a thing only the mouse can give.
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(tr('Apply to all')),
              subtitle: Text(
                tr('The next button answers every collision left in this '
                    'operation'),
              ),
              value: applyToAll.value,
              onChanged: (value) => applyToAll.value = value ?? false,
            ),
          ],
        ),
      ),
    ),
  );
  applyToAll.dispose();
  // Dismissing the question is not permission to overwrite anything.
  return result ?? const ConflictChoice(ConflictAction.abort);
}

/// Reports how a finished operation went. Silent when everything succeeded.
void showOperationResult(BuildContext context, OperationResult result) {
  if (!result.hasErrors && !result.cancelled) return;

  final summary = result.cancelled
      ? tr('Cancelled after {count} item(s)', {'count': result.succeeded})
      : tr('{failed} of {total} item(s) failed', {
          'failed': result.errors.length,
          'total': result.errors.length + result.succeeded,
        });

  showNotice(
    context,
    summary,
    long: true,
    actionLabel: result.hasErrors ? tr('Details') : null,
    onAction: result.hasErrors
        ? () => showDeskWindow<void>(
            context,
            title: tr('Errors'),
            icon: Icons.error_outline,
            modal: false,
            preferredSize: const Size(560, 360),
            builder: (window) => WindowForm(
              actions: [
                // **A list of failures is no use inside a window.** Twenty
                // paths that could not be copied are the input to whatever
                // happens next — a script, a bug report, a question to
                // somebody — and reading them off the screen by hand is how a
                // list of twenty becomes a list of nineteen. JSON rather than
                // the lines as drawn, because the path and the reason are
                // separate things and taking them apart again afterwards is
                // guesswork.
                TextButton(
                  onPressed: () => unawaited(_copyResultAsJson(context, result)),
                  child: Text(tr('Copy as JSON')),
                ),
                TextButton(onPressed: window.close, child: Text(tr('Close'))),
              ],
              child: ListView(
                children: [
                  for (final error in result.errors)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SelectableText(error.text),
                    ),
                ],
              ),
            ),
          )
        : null,
  );
}

/// The whole outcome onto the desktop's clipboard, and a word that it went.
///
/// The window stays open: the point of this is to take the list somewhere else,
/// and closing what was being read is not part of copying it.
Future<void> _copyResultAsJson(
  BuildContext context,
  OperationResult result,
) async {
  await Clipboard.setData(
    ClipboardData(text: result.asJson(when: DateTime.now())),
  );
  if (context.mounted) {
    showNotice(
      context,
      tr('{count} failure(s) copied as JSON.',
          {'count': '${result.errors.length}'}),
    );
  }
}
