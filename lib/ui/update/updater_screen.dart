/// The window the copy performing an update shows while it does it.
///
/// This is the application, started from a temporary folder with a handoff
/// file beside it — so the palette, the wordmark and the title bar are the
/// real ones, and a release carries nothing extra to make that true.
///
/// It touches none of the user's data. Settings are read for the colours and
/// never written; no plugins are started; no window geometry is saved. The
/// copy exists for a few seconds and must leave no trace but the update.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/i18n/i18n.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/update/update_log.dart';
import '../../core/update/updater_handoff.dart';
import '../../core/update/updater_runner.dart';
import '../../core/version.dart';

/// Sets up a small centred window and runs the update in it.
Future<void> runUpdater({
  required UpdaterHandoff handoff,
  required AppearanceSettings appearance,
  UpdaterRunner? runner,
}) async {
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(460, 230),
    center: true,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(UpdaterApp(
    handoff: handoff,
    appearance: appearance,
    runner: runner ?? UpdaterRunner(handoff: handoff),
  ));
}

class UpdaterApp extends StatelessWidget {
  const UpdaterApp({
    super.key,
    required this.handoff,
    required this.appearance,
    required this.runner,
  });

  final UpdaterHandoff handoff;
  final AppearanceSettings appearance;
  final UpdaterRunner runner;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness:
            appearance.darkChrome ? Brightness.dark : Brightness.light,
        colorSchemeSeed: appearance.accentColor,
        visualDensity: VisualDensity.compact,
        fontFamily: appearance.uiFamily,
      ),
      home: UpdaterScreen(handoff: handoff, runner: runner),
    );
  }
}

class UpdaterScreen extends StatefulWidget {
  const UpdaterScreen({
    super.key,
    required this.handoff,
    required this.runner,
    this.onFinished,
  });

  final UpdaterHandoff handoff;
  final UpdaterRunner runner;

  /// Called when there is nothing left to do. Null in the application, where
  /// the window closes itself; a test passes one rather than being exited.
  final void Function(UpdateProgress last)? onFinished;

  @override
  State<UpdaterScreen> createState() => _UpdaterScreenState();
}

class _UpdaterScreenState extends State<UpdaterScreen> {
  UpdateProgress _progress =
      const UpdateProgress(UpdateStage.waitingForExit, 'Starting…');
  StreamSubscription<UpdateProgress>? _watching;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _watching = widget.runner.run().listen((progress) {
      if (!mounted) return;
      setState(() => _progress = progress);
      if (progress.isEnd) _finish(progress);
    });
  }

  Future<void> _finish(UpdateProgress last) async {
    // The one thing this copy writes into the data directory, and the reason
    // for the exception is the rest of this file: the window below is the only
    // place the second half of an update reports itself, and it is gone within
    // seconds of the update ending. A line in [UpdateLog] outlives it.
    unawaited(UpdateLog.write('updater: ${last.stage.name} · ${last.note}'
        '${last.problem == null ? '' : ' · ${last.problem}'}'));

    final told = widget.onFinished;
    if (told != null) {
      told(last);
      return;
    }
    // Long enough to be read, short enough not to be in the way. Anything but
    // a clean install stays until it is dismissed — those are the outcomes
    // somebody has to act on, and closing them for the person would take away
    // the only account of what happened.
    if (last.stage == UpdateStage.installed) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await windowManager.close();
    }
  }

  @override
  void dispose() {
    _watching?.cancel();
    super.dispose();
  }

  /// What went wrong, with what it was doing, onto the clipboard. There is no
  /// notice bar in this window, so the button says so itself.
  Future<void> _copyProblem() async {
    await Clipboard.setData(ClipboardData(
      text: [
        'xverb $kAppVersion \u2192 ${widget.handoff.version} \u00b7 '
            '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        _progress.note,
        '${_progress.problem}',
        'target ${widget.handoff.target}',
        'staged ${widget.handoff.staged}',
      ].join('\n'),
    ));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = _progress.stage == UpdateStage.failed;
    final done = _progress.isEnd;
    return Scaffold(
      body: GestureDetector(
        // The window has no title bar of its own, so it is dragged by its face.
        onPanStart: (_) => windowManager.startDragging(),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(kAppTitle, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text(
                tr('Updating to {version}', {'version': widget.handoff.version}),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              // Not a percentage: what is left after the handover is a wait
              // and two renames, and a bar that jumps from nothing to
              // everything says less than the sentence beneath it does.
              if (!done)
                const LinearProgressIndicator(minHeight: 3)
              else
                Divider(
                  height: 3,
                  thickness: 3,
                  color: failed
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              const SizedBox(height: 14),
              Text(
                tr(_progress.note),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: failed ? theme.colorScheme.error : null,
                ),
              ),
              // Selectable and whole. It used to be three lines and an
              // ellipsis, which is the same as losing it: this window is the
              // only place the second half of an update ever reports itself,
              // and it is gone the moment it closes.
              if (failed && _progress.problem != null) ...[
                const SizedBox(height: 6),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      '${_progress.problem}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              if (done && _progress.stage != UpdateStage.installed)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_progress.problem != null)
                      TextButton(
                        onPressed: () => unawaited(_copyProblem()),
                        child: Text(_copied ? tr('Copied') : tr('Copy')),
                      ),
                    TextButton(
                      onPressed: () => windowManager.close(),
                      child: Text(tr('Close')),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
