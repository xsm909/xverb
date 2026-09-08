/// Taking an update: the guard, the staging, and the handover.
///
/// Shared on purpose. There are two ways in — the button in Settings and the
/// offer the application makes by itself once a day — and "install it" must not
/// be two implementations that can drift apart. What differs between them is
/// only how the progress is shown, which is why that arrives as a callback.
library;

import 'dart:async';
import 'dart:io';

import '../i18n/i18n.dart';
import '../settings/window_service.dart';
import 'release_check.dart';
import 'update_installer.dart';
import 'update_log.dart';
import 'updater_handoff.dart';

class UpdateStart {
  /// A copy installed by a package manager belongs to that package manager.
  ///
  /// Replacing it by hand leaves brew with a checksum that no longer matches
  /// anything, and the first `brew upgrade` after that fails for a reason
  /// nobody would connect to this. One line, and the wrong moment to find it
  /// out is afterwards.
  static bool ownedByPackageManager(String path) =>
      path.contains('/Caskroom/') || path.contains('/Cellar/');

  /// Why the installed copy could not be replaced where it stands, or null.
  ///
  /// **Asked before anything is downloaded.** Putting a new version in place
  /// is a rename inside the folder that holds the installed copy, and whether
  /// this process may write there is knowable in a millisecond. Found out at
  /// the end instead, it costs a fifteen-megabyte download and reports itself
  /// as whatever the operating system says about a directory nobody mentioned.
  ///
  /// It is the Windows case that makes this worth a check of its own: the
  /// installer offers Program Files when it is run as an administrator, and an
  /// application started normally afterwards cannot write there at all. The
  /// same shape exists on the other two — /Applications owned by another
  /// account, a copy under /opt — and the answer is the same sentence.
  static Future<String?> whyCannotReplace(Directory target) async {
    if (!await target.exists()) {
      return tr('There is no installed copy at {path} to replace.',
          {'path': target.path});
    }

    final probe = Directory('${target.parent.path}'
        '${Platform.pathSeparator}.xverb-write-test-'
        '${DateTime.now().microsecondsSinceEpoch}');
    try {
      await probe.create(recursive: true);
      await probe.delete(recursive: true);
      return null;
    } on Object catch (problem) {
      return [
        tr(
          'The new version has to be put into {folder}, and this copy is not '
          'allowed to write there.',
          {'folder': target.parent.path},
        ),
        if (Platform.isWindows)
          tr('It is installed for everyone on this machine. Start xverb as an '
              'administrator to update it, or install it again under your own '
              'account, where updating needs nobody\'s permission.')
        else
          tr('Whoever owns that folder can update it; this account cannot.'),
        '$problem',
      ].join('\n\n');
    }
  }

  /// Downloads, verifies and unpacks, then hands over to a copy of this
  /// application running from a temporary folder and closes this one.
  ///
  /// Everything slow happens here, where there is still a window to show it
  /// in. What the other copy does afterwards is a wait and two renames.
  ///
  /// [installedAt] and [handOver] are null in the application, where the copy
  /// to replace is the one running and the other copy is really started; a
  /// test hands in both and nothing is installed.
  static Future<void> run({
    required ReleaseSource source,
    required ReleaseArchive archive,
    Directory? installedAt,
    void Function(StageStep step)? onStep,
    Future<void> Function(PreparedUpdate)? handOver,
  }) async {
    final running = bundleRootOf(Platform.resolvedExecutable);
    final target = installedAt ?? running;

    // Written down as it goes. The half of an update that happens after the
    // handover is in another process and the window it reports in lives for
    // seconds, so the file is the only account that outlives either — see
    // [UpdateLog].
    await UpdateLog.begin('updating to ${archive.version} from '
        '${source.describe}');
    await UpdateLog.write('target $target');

    try {
      if (ownedByPackageManager(target.path)) {
        throw StateError(tr('This copy was installed by Homebrew. Update it '
            'with `brew upgrade --cask xverb`.'));
      }

      final refused = await whyCannotReplace(target);
      if (refused != null) throw StateError(refused);

      final prepared = await UpdateInstaller.prepare(
        source: source,
        archive: archive,
        target: target,
        running: running,
        version: '${archive.version}',
        onProgress: (progress) {
          onStep?.call(progress.step);
          if (progress.fraction == null) {
            unawaited(UpdateLog.write(progress.step.name));
          }
        },
      );

      if (handOver != null) {
        await handOver(prepared);
        return;
      }
      await UpdateLog.write('handing over to ${prepared.updaterBundle.path}');
      await UpdateInstaller.handOver(prepared);
    } on Object catch (problem) {
      await UpdateLog.write('FAILED  $problem');
      rethrow;
    }
    // Closed rather than killed, so that anything with unsaved state gets its
    // ordinary shutdown. The copy just started is waiting for exactly this.
    await WindowService.close();
  }
}
