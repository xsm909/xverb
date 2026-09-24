/// The window the copy performing an update shows while it does it.
///
/// This is the application, started from a temporary folder with a handoff
/// file beside it — so the palette, the wordmark and the title bar are the
/// real ones, and a release carries nothing extra to make that true.
///
/// It lists every step of the swap and marks each one as it goes, so that when
/// something goes wrong the window says *where*, and a person can repeat it —
/// the bar alone said only that something was still happening, including when
/// nothing was.
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
import '../../core/settings/motion.dart';
import '../../core/update/update_log.dart';
import '../../core/update/updater_handoff.dart';
import '../../core/update/updater_runner.dart';
import '../../core/version.dart';
import '../widgets/press_and_hold.dart' show kPressDevices;

/// Sets up a small centred window and runs the update in it.
Future<void> runUpdater({
  required UpdaterHandoff handoff,
  required AppearanceSettings appearance,
  UpdaterRunner? runner,
}) async {
  await windowManager.ensureInitialized();
  // Tall enough for every step and a failure under them, without the list
  // having to scroll: a step that has to be scrolled to is a step not read.
  const options = WindowOptions(
    size: Size(520, 460),
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
      home: UpdaterScreen(
        handoff: handoff,
        runner: runner,
        motion: appearance.animated(kUpdateStepDuration),
      ),
    );
  }
}

class UpdaterScreen extends StatefulWidget {
  const UpdaterScreen({
    super.key,
    required this.handoff,
    required this.runner,
    this.onFinished,
    this.motion = const Duration(milliseconds: kUpdateStepDuration ~/ 2),
  });

  final UpdaterHandoff handoff;
  final UpdaterRunner runner;

  /// Called when there is nothing left to do. Null in the application, where
  /// the window closes itself; a test passes one rather than being exited.
  final void Function(UpdateProgress last)? onFinished;

  /// How long a step's mark takes to change, already scaled by the speed
  /// setting.
  final Duration motion;

  @override
  State<UpdaterScreen> createState() => _UpdaterScreenState();
}

/// How one step stands.
enum _Mark { pending, underWay, done, failed }

/// The steps every update takes, in order. Putting the old copy back is not
/// one of them: it is listed only when it happens.
const _steps = [
  UpdateStage.waitingForExit,
  UpdateStage.movingAside,
  UpdateStage.placing,
  UpdateStage.starting,
  UpdateStage.waitingForWindow,
  UpdateStage.cleaning,
];

class _UpdaterScreenState extends State<UpdaterScreen> {
  final List<UpdateStage> _reached = [];
  UpdateProgress? _end;
  StreamSubscription<UpdateProgress>? _watching;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _watching = widget.runner.run().listen(
      (progress) {
        if (!mounted || _end != null) return;
        setState(() {
          if (progress.isEnd) {
            _end = progress;
          } else if (!_reached.contains(progress.stage)) {
            _reached.add(progress.stage);
          }
        });
        if (progress.isEnd) unawaited(_finish(progress));
      },
      // The runner turns what it throws into an end of its own, so this is the
      // failure nobody foresaw. It is an end all the same: an error on a stream
      // nobody listens to for errors is exactly how this window once ran its
      // bar for ever.
      onError: (Object problem) {
        if (_end != null) return;
        final last = UpdateProgress(
          UpdateStage.failed,
          'The update stopped.',
          problem: problem,
          at: _reached.isEmpty ? null : _reached.last,
        );
        if (mounted) setState(() => _end = last);
        unawaited(_finish(last));
      },
    );
  }

  Future<void> _finish(UpdateProgress last) async {
    // The one thing this copy writes into the data directory, and the reason
    // for the exception is the rest of this file: the window below is the only
    // place the second half of an update reports itself, and it is gone within
    // seconds of the update ending. A line in [UpdateLog] outlives it.
    unawaited(UpdateLog.write('updater: ${last.stage.name}'
        '${last.at == null ? '' : ' at ${last.at!.name}'} · ${last.note}'
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

  _Mark _markOf(UpdateStage row) {
    final end = _end;
    if (end != null && end.stage == UpdateStage.installed) return _Mark.done;
    if (end != null && row == end.at) return _Mark.failed;
    if (!_reached.contains(row)) return _Mark.pending;
    if (end == null && row == _reached.last) return _Mark.underWay;
    return _Mark.done;
  }

  /// What went wrong, with the step it stopped at and every step before it,
  /// onto the clipboard. There is no notice bar in this window, so the button
  /// says so itself.
  Future<void> _copyProblem() async {
    final end = _end;
    await Clipboard.setData(ClipboardData(
      text: [
        'xverb $kAppVersion → ${widget.handoff.version} · '
            '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        'stopped at: ${end?.at?.name ?? '-'}',
        'steps: ${_reached.map((stage) => stage.name).join(' > ')}',
        ?end?.note,
        '${end?.problem}',
        'target ${widget.handoff.target}',
        'staged ${widget.handoff.staged}',
      ].join('\n'),
    ));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final end = _end;
    final failed = end?.stage == UpdateStage.failed;
    final rows = [
      ..._steps,
      if (_reached.contains(UpdateStage.rollingBack)) UpdateStage.rollingBack,
    ];
    final String? outcome = end == null
        ? null
        : end.stage == UpdateStage.installed
            ? tr('Updated to {version}.', {'version': widget.handoff.version})
            : tr(end.note);
    final unclean = end != null && end.stage != UpdateStage.installed;

    return Scaffold(
      body: GestureDetector(
        // The window has no title bar of its own, so it is dragged by its face.
        // Not by the trackpad's scroll, though: see kPressDevices.
        supportedDevices: kPressDevices,
        onPanStart: (_) => windowManager.startDragging(),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(kAppTitle, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 2),
              Text(
                tr('Updating to {version}', {'version': widget.handoff.version}),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              // Not a percentage: what is left after the handover is a wait
              // and two renames, and a bar that jumps from nothing to
              // everything says less than the steps beneath it do.
              if (end == null)
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
              for (final row in rows)
                _StepRow(
                  label: tr(row.label),
                  mark: _markOf(row),
                  motion: widget.motion,
                ),
              if (outcome != null) ...[
                const SizedBox(height: 12),
                Text(
                  outcome,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: failed ? theme.colorScheme.error : null,
                  ),
                ),
              ],
              // Selectable and whole. It used to be three lines and an
              // ellipsis, which is the same as losing it: this window is the
              // only place the second half of an update ever reports itself,
              // and it is gone the moment it closes.
              if (unclean && end.problem != null) ...[
                const SizedBox(height: 6),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      '${end.problem}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              if (unclean)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (end.problem != null)
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

/// One step, and how it stands: a ring for not yet, a turning ring for under
/// way, a tick for done, a cross for where it stopped.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.mark,
    required this.motion,
  });

  final String label;
  final _Mark mark;
  final Duration motion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget sign = switch (mark) {
      _Mark.pending => Icon(Icons.radio_button_unchecked,
          size: 14, color: theme.hintColor),
      _Mark.underWay => const SizedBox.square(
          dimension: 12,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      _Mark.done => Icon(Icons.check, size: 16, color: scheme.primary),
      _Mark.failed => Icon(Icons.close, size: 16, color: scheme.error),
    };
    final style = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      color: switch (mark) {
        _Mark.pending => theme.hintColor,
        _Mark.failed => scheme.error,
        _ => null,
      },
      fontWeight: mark == _Mark.underWay || mark == _Mark.failed
          ? FontWeight.w600
          : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 18,
            child: Center(
              child: AnimatedSwitcher(
                duration: motion,
                child: KeyedSubtree(key: ValueKey(mark), child: sign),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: motion,
              style: style,
              child: Text(label),
            ),
          ),
        ],
      ),
    );
  }
}
