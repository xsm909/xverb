/// The copy that performs the swap, and what it says while it does.
///
/// Every long thing — the download, the checksum, the unpacking — has already
/// happened in the copy that is being replaced, where there was a window to
/// show it in. What is left here is a wait, two renames and a launch, and it
/// takes seconds. It still says what it is doing: an application that vanishes
/// and comes back with nothing in between is indistinguishable from one that
/// crashed.
library;

import 'dart:async';
import 'dart:io';

import 'update_log.dart';
import 'update_swap.dart';
import 'updater_handoff.dart';

/// Where a run has got to.
///
/// The first seven are the steps, in the order they are taken — [rollingBack]
/// only when the new copy did not start — and the last three are ends. Each
/// step is shown as it is reached and written to [UpdateLog] at once, so a run
/// that stops anywhere, even one that never gets as far as an end, leaves the
/// name of the step it stopped at behind it.
enum UpdateStage {
  waitingForExit,
  movingAside,
  placing,
  starting,
  waitingForWindow,
  cleaning,
  rollingBack,
  installed,
  rolledBack,
  failed;

  bool get isEnd =>
      this == UpdateStage.installed ||
      this == UpdateStage.rolledBack ||
      this == UpdateStage.failed;

  /// The step as the window lists it. English, because it is also the key its
  /// translation is found by.
  String get label => switch (this) {
        UpdateStage.waitingForExit => 'Waiting for the running copy to close',
        UpdateStage.movingAside => 'Moving the old copy aside',
        UpdateStage.placing => 'Putting the new copy in place',
        UpdateStage.starting => 'Starting the new copy',
        UpdateStage.waitingForWindow =>
          'Waiting for the new copy to open its window',
        UpdateStage.cleaning => 'Removing the old copy',
        UpdateStage.rollingBack => 'Putting the old copy back',
        UpdateStage.installed ||
        UpdateStage.rolledBack ||
        UpdateStage.failed =>
          name,
      };
}

class UpdateProgress {
  const UpdateProgress(this.stage, this.note, {this.problem, this.at});
  final UpdateStage stage;
  final String note;
  final Object? problem;

  /// For an end that is not a clean install, the step it stopped at — the one
  /// a person reports when they say where it went wrong.
  final UpdateStage? at;

  bool get isEnd => stage.isEnd;
}

/// Whether a process is still running.
///
/// **By pid, never by name.** A debug build running out of a checkout is not
/// the copy being replaced, and matching on a name would wait for it for ever
/// or, worse, decide it had exited when it had not.
Future<bool> isProcessAlive(int pid) async {
  if (Platform.isWindows) {
    final result =
        await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return '${result.stdout}'.contains('$pid');
  }
  // Signal 0 asks the kernel the question without sending anything.
  final result = await Process.run('kill', ['-0', '$pid']);
  return result.exitCode == 0;
}

/// Starts an installed copy.
Future<void> launchInstalled(Directory app) async {
  if (Platform.isMacOS) {
    // `open` rather than running the binary: it registers the application with
    // the window server properly, which running the executable directly does
    // not always do.
    final result = await Process.run('open', ['-n', '-a', app.path]);
    if (result.exitCode != 0) {
      throw ProcessException('open', [app.path], '${result.stderr}');
    }
    return;
  }
  final executable = Platform.isWindows
      ? '${app.path}\\xverb.exe'
      : '${app.path}/xverb';
  // Started in its own folder, the way the Start menu shortcut starts it.
  // Inheriting ours would leave it standing in the updater's temporary folder
  // for as long as it runs, and that folder could not be swept.
  await Process.start(executable, const [],
      workingDirectory: app.path, mode: ProcessStartMode.detachedWithStdio);
}

/// Runs the swap and reports it.
///
/// Every piece of the outside world is handed in, so the whole sequence —
/// including both failures and the rollback — is reached by tests without a
/// process being started or a real application being moved.
class UpdaterRunner {
  UpdaterRunner({
    required this.handoff,
    Future<bool> Function(int pid)? alive,
    Future<void> Function(Directory app)? launch,
    this.exitTimeout = const Duration(seconds: 30),
    this.startTimeout = const Duration(seconds: 40),
    Future<void> Function(Duration)? sleep,
    Future<void> Function(String line)? log,
  })  : _alive = alive ?? isProcessAlive,
        _launch = launch ?? launchInstalled,
        _sleep = sleep ?? Future<void>.delayed,
        _log = log ?? UpdateLog.write;

  final UpdaterHandoff handoff;
  final Duration exitTimeout;
  final Duration startTimeout;
  final Future<bool> Function(int pid) _alive;
  final Future<void> Function(Directory app) _launch;
  final Future<void> Function(Duration) _sleep;
  final Future<void> Function(String line) _log;

  /// Every step as it is reached, then exactly one end.
  ///
  /// **Always an end, whatever happens.** This used to be a generator that let
  /// an exception out of the swap onto the stream, where nobody was listening
  /// for one: on Windows a folder that would not rename left the window on
  /// "Putting the new copy in place…" with its bar running for ever, and
  /// nothing in the log. Anything thrown now is a failure at the step it was
  /// thrown in.
  Stream<UpdateProgress> run() {
    final out = StreamController<UpdateProgress>();
    unawaited(_run(out));
    return out.stream;
  }

  Future<void> _run(StreamController<UpdateProgress> out) async {
    final marker = StartMarker(File(handoff.marker));
    UpdateStage? reached;
    UpdateStage? stoppedAt;

    void step(UpdateStage stage) {
      if (stage == reached) return;
      reached = stage;
      out.add(UpdateProgress(stage, stage.label));
      unawaited(_log('updater: ${stage.name}'));
    }

    void end(UpdateStage stage, String note, {Object? problem, UpdateStage? at}) =>
        out.add(UpdateProgress(stage, note, problem: problem, at: at));

    try {
      step(UpdateStage.waitingForExit);
      if (!await _waitForExit()) {
        end(
          UpdateStage.failed,
          'The running copy did not close.',
          problem: StateError('pid ${handoff.pid} is still running'),
          at: UpdateStage.waitingForExit,
        );
        return;
      }

      // The marker is the first thing written beside the installed copy, so a
      // folder that cannot be written to fails here, at the first step that
      // touches it, rather than one step later under a name that hides it.
      step(UpdateStage.movingAside);
      await marker.place(handoff.version);

      final swap = UpdateSwap(
        target: Directory(handoff.target),
        staged: Directory(handoff.staged),
        launch: _launch,
        waitForStart: (_) async =>
            marker.waitCleared(startTimeout, sleep: _sleep),
        onStep: (swapStep) {
          // Rolling back is not where it went wrong; the step before it is.
          if (swapStep == SwapStep.rollingBack) stoppedAt = reached;
          step(_stageOf(swapStep));
        },
      );
      final result = await swap.run();
      await _quietly(marker.clear);

      switch (result.outcome) {
        case SwapOutcome.installed:
          end(UpdateStage.installed, 'Updated to ${handoff.version}.');
        case SwapOutcome.rolledBack:
          end(
            UpdateStage.rolledBack,
            'The new copy would not start, so the old one is back.',
            problem: result.problem,
            at: stoppedAt,
          );
        case SwapOutcome.refused:
          end(UpdateStage.failed, 'Nothing was changed.',
              problem: result.problem, at: reached);
        case SwapOutcome.broken:
          end(UpdateStage.failed, 'Neither copy would start. Install it again.',
              problem: result.problem, at: reached);
      }
    } on Object catch (problem) {
      await _quietly(marker.clear);
      // Whether there is still an application where there was one is the
      // first thing the person needs, and it is one call to find out.
      final whole = await Directory(handoff.target).exists();
      end(
        UpdateStage.failed,
        whole
            ? 'The update stopped.'
            : 'The update stopped halfway. Install it again.',
        problem: problem,
        at: reached,
      );
    } finally {
      await out.close();
    }
  }

  static UpdateStage _stageOf(SwapStep step) => switch (step) {
        SwapStep.movingAside => UpdateStage.movingAside,
        SwapStep.placing => UpdateStage.placing,
        SwapStep.starting => UpdateStage.starting,
        SwapStep.waitingForWindow => UpdateStage.waitingForWindow,
        SwapStep.cleaning => UpdateStage.cleaning,
        SwapStep.rollingBack => UpdateStage.rollingBack,
      };

  /// Tidying must not turn an end into an exception.
  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } on Object {
      // Left behind, and harmless: the next update places its own.
    }
  }

  Future<bool> _waitForExit() async {
    final deadline = DateTime.now().add(exitTimeout);
    while (await _alive(handoff.pid)) {
      if (!DateTime.now().isBefore(deadline)) return false;
      await _sleep(const Duration(milliseconds: 200));
    }
    return true;
  }
}

/// Clears away the temporary folders an update leaves behind.
///
/// Done by the copy that was just started rather than by the updater deleting
/// itself: a running program cannot remove its own folder on Windows, and a
/// trick to make it possible is three platform-specific lines where this is
/// none. A folder still in use simply fails to go and is swept next time.
///
/// [olderThan] is not tidiness, it is the whole safety of this. The copy that
/// installed us is **still running out of one of these folders**, waiting to
/// see that we drew a window — and it is a Flutter application, which loads
/// from its own bundle lazily. Deleting the folder under it is the same
/// mistake as replacing an application while it runs. So only folders left by
/// an update that is long over are touched.
Future<int> sweepUpdaterLeftovers({
  Directory? temporary,
  Duration olderThan = const Duration(hours: 1),
}) async {
  final root = temporary ?? Directory.systemTemp;
  final before = DateTime.now().subtract(olderThan);
  var removed = 0;
  try {
    await for (final entry in root.list(followLinks: false)) {
      final name = entry.path.split(Platform.pathSeparator).last;
      if (!name.startsWith(kUpdaterFolderPrefix)) continue;
      try {
        if ((await entry.stat()).modified.isAfter(before)) continue;
        await entry.delete(recursive: true);
        removed++;
      } on Object {
        // In use, or not ours to remove. Next start will find it again.
      }
    }
  } on Object {
    // No temporary directory to read is not a reason to fail a start.
  }
  return removed;
}
