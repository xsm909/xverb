import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/vfs/file_operations.dart';
import '../../state/app_state.dart';
import '../../state/window_stack.dart';
import '../format.dart';
import '../text_scale.dart';
import '../windows/window_dialogs.dart';

/// Runs a long file operation behind a modal progress window.
///
/// The window owns the [CancellationToken], so Cancel stops the operation
/// cooperatively instead of leaving a half-written file behind.
Future<OperationResult> runWithProgress(
  BuildContext context, {
  required String title,
  required Future<OperationResult> Function(
    ProgressCallback onProgress,
    CancellationToken token,
  ) task,
}) async {
  final stack = context.read<AppState>().windows;
  final token = CancellationToken();
  final progress = ValueNotifier<OperationProgress?>(null);

  final future = task((value) => progress.value = value, token);

  final window = DeskWindow(
    id: 'progress',
    title: title,
    icon: Icons.sync,
    modal: true,
    resizable: false,
    // Escape and the close button stop the copy rather than hiding it: an
    // operation running with no window is worse than either outcome.
    onDismiss: token.cancel,
    preferredSize: const Size(520, 220),
    minSize: const Size(380, 200),
    builder: (_) => WindowForm(
      actions: [
        TextButton(onPressed: token.cancel, child: Text(tr('Cancel'))),
      ],
      child: ValueListenableBuilder<OperationProgress?>(
        valueListenable: progress,
        builder: (context, value, _) => _ProgressBody(progress: value),
      ),
    ),
  );

  // A short operation can finish before the window is even opened; the flag
  // keeps it from leaving one behind that nothing will ever close.
  var finished = false;
  unawaited(future.whenComplete(() {
    finished = true;
    stack.close(window);
  }));

  if (!finished) await stack.open(window);

  // The window's widgets outlive this frame, so the notifier cannot go yet.
  WidgetsBinding.instance.addPostFrameCallback((_) => progress.dispose());
  return future;
}

class _ProgressBody extends StatelessWidget {
  const _ProgressBody({required this.progress});

  final OperationProgress? progress;

  @override
  Widget build(BuildContext context) {
    final value = progress;
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;

    // Every row below has a fixed height. The path changes on every file, and
    // letting the window resize to fit it made the whole thing jitter.
    //
    // Two lines of it, so the box has to hold two: at 34 it was two pixels
    // short, and the file being copied was drawn with an overflow stripe across
    // the bottom of it.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 40,
          width: double.infinity,
          child: _CurrentPath(path: value?.currentPath),
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(value: value?.fraction),
        const SizedBox(height: 8),
        SizedBox(
          height: 16,
          width: double.infinity,
          child: Text(
            value == null
                ? ''
                : tr('{done} / {total} files · {bytesDone} / {bytesTotal}', {
                    'done': value.filesDone,
                    'total': value.filesTotal,
                    'bytesDone': formatSize(value.bytesDone),
                    'bytesTotal': formatSize(value.bytesTotal),
                  }),
            maxLines: 1,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// Shows the file name on one line and its directory on the next.
///
/// Splitting them keeps the interesting part — the name — visible, because a
/// plain ellipsis on a long path cuts off exactly the end you want to read.
class _CurrentPath extends StatelessWidget {
  const _CurrentPath({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (path == null) {
      return Text(tr('Preparing…'), style: theme.textTheme.bodySmall);
    }

    final separator = path!.lastIndexOf(RegExp(r'[/\\]'));
    final name = separator < 0 ? path! : path!.substring(separator + 1);
    final directory = separator < 0 ? '' : path!.substring(0, separator);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: context.uiWeight(FontWeight.w600)),
        ),
        Text(
          directory,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
