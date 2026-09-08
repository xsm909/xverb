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

import 'update_swap.dart';
import 'updater_handoff.dart';

/// Where a run has got to. The last three are ends.
enum UpdateStage {
  waitingForExit,
  swapping,
  starting,
  installed,
  rolledBack,
  failed,
}

class UpdateProgress {
  const UpdateProgress(this.stage, this.note, {this.problem});
  final UpdateStage stage;
  final String note;
  final Object? problem;

  bool get isEnd =>
      stage == UpdateStage.installed ||
      stage == UpdateStage.rolledBack ||
      stage == UpdateStage.failed;
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
  await Process.start(executable, const [],
      mode: ProcessStartMode.detachedWithStdio);
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
  })  : _alive = alive ?? isProcessAlive,
        _launch = launch ?? launchInstalled,
        _sleep = sleep ?? Future<void>.delayed;

  final UpdaterHandoff handoff;
  final Duration exitTimeout;
  final Duration startTimeout;
  final Future<bool> Function(int pid) _alive;
  final Future<void> Function(Directory app) _launch;
  final Future<void> Function(Duration) _sleep;

  Stream<UpdateProgress> run() async* {
    yield const UpdateProgress(
        UpdateStage.waitingForExit, 'Waiting for the running copy to close…');

    if (!await _waitForExit()) {
      yield UpdateProgress(
        UpdateStage.failed,
        'The running copy did not close.',
        problem: StateError('pid ${handoff.pid} is still running'),
      );
      return;
    }

    yield const UpdateProgress(UpdateStage.swapping, 'Putting the new copy in place…');

    final marker = StartMarker(File(handoff.marker));
    await marker.place(handoff.version);

    final swap = UpdateSwap(
      target: Directory(handoff.target),
      staged: Directory(handoff.staged),
      launch: _launch,
      waitForStart: (_) async =>
          marker.waitCleared(startTimeout, sleep: _sleep),
    );

    // Nothing is yielded between these two, and that is deliberate: the swap
    // is two renames and a launch. Announcing "starting" before the launch
    // would be a message the user reads while the thing has already happened.
    final result = await swap.run();
    await marker.clear();

    yield switch (result.outcome) {
      SwapOutcome.installed => UpdateProgress(
          UpdateStage.installed, 'Updated to ${handoff.version}.'),
      SwapOutcome.rolledBack => UpdateProgress(
          UpdateStage.rolledBack,
          'The new copy would not start, so the old one is back.',
          problem: result.problem),
      SwapOutcome.refused => UpdateProgress(
          UpdateStage.failed, 'Nothing was changed.',
          problem: result.problem),
      SwapOutcome.broken => UpdateProgress(
          UpdateStage.failed,
          'Neither copy would start. Install it again.',
          problem: result.problem),
    };
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
