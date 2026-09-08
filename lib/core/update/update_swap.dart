/// Putting a new copy in place of the installed one, and putting the old one
/// back when the new one will not start.
///
/// This is the part that cannot be done by the copy being replaced, and the
/// whole of it is arranged around one rule: **at every instant there must be a
/// copy that runs.** So the old copy is moved aside by a rename, which is
/// instant and reversible, and never overwritten — a copy takes time, and a
/// machine that loses power in the middle of one is left with neither version.
///
/// Nothing here downloads or verifies anything. It is handed a folder that has
/// already been checked, and its only decisions are about moving folders and
/// about whether the new copy started.
library;

import 'dart:async';
import 'dart:io';

/// How a swap ended.
enum SwapOutcome {
  /// The new copy is in place and it started.
  installed,

  /// The new copy would not start, so the old one is back and running.
  rolledBack,

  /// Nothing was changed — the swap refused before it began.
  refused,

  /// The new copy would not start and neither would the old one. The worst
  /// case, and it is reported rather than hidden: whoever is reading has to be
  /// told that the application on this machine needs installing again.
  broken,
}

class SwapResult {
  const SwapResult(this.outcome, [this.problem]);
  final SwapOutcome outcome;
  final Object? problem;

  @override
  String toString() =>
      problem == null ? '$outcome' : '$outcome ($problem)';
}

/// Replaces [target] with [staged], and puts [target] back if the new copy
/// does not get as far as a window.
///
/// [launch] and [waitForStart] are handed in rather than done here. That is
/// what makes the whole of this testable without installing anything: the
/// tests give it folders in a temporary directory and functions that succeed
/// or fail on demand, and every branch below is reached without a build.
class UpdateSwap {
  UpdateSwap({
    required this.target,
    required this.staged,
    required this.launch,
    required this.waitForStart,
  });

  /// The installed copy, the thing being replaced.
  final Directory target;

  /// The new copy, already verified and unpacked, on the same volume as
  /// [target] so that moving it is a rename and not a copy.
  final Directory staged;

  /// Starts the copy at that path. Throwing counts as not starting.
  final Future<void> Function(Directory app) launch;

  /// Answers true when the copy that was launched said it was up — by deleting
  /// the marker it was started with. Not "the process is still alive": an
  /// application that starts and then fails to draw anything would pass that,
  /// and it is exactly the failure worth rolling back from.
  final Future<bool> Function(Directory app) waitForStart;

  /// Where the old copy waits while the new one proves itself.
  Directory get previous => Directory('${target.path}.prev');

  /// Recovers from a run that was killed between the two renames.
  ///
  /// There is one instant where the target does not exist: after the old copy
  /// has been moved aside and before the new one is moved in. A machine that
  /// dies there leaves `.prev` and no application. This is the only repair
  /// needed, and it is done before anything else — including on an ordinary
  /// start, which is why it is separate and public.
  static Future<bool> repairInterrupted(Directory target) async {
    final previous = Directory('${target.path}.prev');
    if (await target.exists() || !await previous.exists()) return false;
    await previous.rename(target.path);
    return true;
  }

  Future<SwapResult> run() async {
    if (!await staged.exists()) {
      return SwapResult(
        SwapOutcome.refused,
        StateError('There is nothing staged at ${staged.path}.'),
      );
    }
    await repairInterrupted(target);

    // A leftover from an earlier update that was never cleared. It is the old
    // copy of an older version and has no claim on anything now.
    if (await previous.exists()) {
      await previous.delete(recursive: true);
    }

    final hadTarget = await target.exists();
    if (hadTarget) {
      await target.rename(previous.path);
    }

    try {
      await staged.rename(target.path);
    } on Object catch (problem) {
      // The new copy could not be moved into place. Nothing has been lost:
      // put the old one back and say why.
      if (hadTarget) await previous.rename(target.path);
      return SwapResult(SwapOutcome.refused, problem);
    }

    Object? trouble;
    var started = false;
    try {
      await launch(target);
      started = await waitForStart(target);
    } on Object catch (problem) {
      trouble = problem;
    }

    if (started) {
      if (await previous.exists()) {
        await previous.delete(recursive: true);
      }
      return const SwapResult(SwapOutcome.installed);
    }

    // It did not start. The new copy goes, the old one comes back.
    if (!hadTarget) {
      // There was nothing here before, so there is nothing to go back to.
      return SwapResult(SwapOutcome.broken, trouble);
    }
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    await previous.rename(target.path);
    try {
      await launch(target);
      if (await waitForStart(target)) {
        return SwapResult(SwapOutcome.rolledBack, trouble);
      }
    } on Object catch (problem) {
      trouble ??= problem;
    }
    // The old copy is back on disk even here — it simply did not answer in
    // time, which on a loaded machine is not the same as being broken.
    return SwapResult(SwapOutcome.broken, trouble);
  }
}

/// The file a copy is started with, and deletes once it has drawn something.
///
/// A file rather than a port or a pipe: the two processes do not overlap — the
/// one that starts the other has already exited — and a file survives that,
/// costs nothing, and can be looked at afterwards by a person wondering what
/// happened.
class StartMarker {
  const StartMarker(this.file);

  final File file;

  Future<void> place(String note) => file.writeAsString(note);

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }

  /// True as soon as the marker is gone, false if [timeout] passes first.
  Future<bool> waitCleared(
    Duration timeout, {
    Duration every = const Duration(milliseconds: 200),
    Future<void> Function(Duration)? sleep,
  }) async {
    final rest = sleep ?? Future<void>.delayed;
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (!await file.exists()) return true;
      if (!DateTime.now().isBefore(deadline)) return false;
      await rest(every);
    }
  }
}
