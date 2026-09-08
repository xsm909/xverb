/// Getting a release onto the machine, up to the moment of handing over.
///
/// Everything slow is here, in the copy that is still running and still has a
/// window: the download, the checksum, the unpacking, and copying itself out
/// to the folder it will be replaced from. What happens after this takes
/// seconds — see [UpdaterRunner].
///
/// The order matters and is not arbitrary: **nothing is unpacked before the
/// checksum matches**, and nothing is moved until the copy that will move it
/// is already outside the folder being replaced.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'release_check.dart';
import 'updater_handoff.dart';

enum StageStep { downloading, verifying, unpacking, copying, ready }

class StageProgress {
  const StageProgress(this.step, {this.fraction});
  final StageStep step;

  /// Null where the size is not known — a caller shows a spinner rather than
  /// a bar, and does not have to ask which it should be.
  final double? fraction;
}

/// What has been prepared, and everything the updater needs to know.
class PreparedUpdate {
  const PreparedUpdate({
    required this.staged,
    required this.updaterFolder,
    required this.updaterBundle,
    required this.handoff,
  });

  /// The new copy, beside the installed one so that putting it in place is a
  /// rename. See [UpdateInstaller.prepare] for why that decides where it goes.
  final Directory staged;

  /// The temporary folder holding the copy that will perform the swap.
  final Directory updaterFolder;

  /// The copy itself, inside that folder.
  final Directory updaterBundle;

  final UpdaterHandoff handoff;
}

class UpdateInstaller {
  /// What an installed copy is called on this platform.
  static String bundleName([String? operatingSystem]) =>
      (operatingSystem ?? Platform.operatingSystem) == 'macos'
          ? 'xverb.app'
          : 'xverb';

  static String _suffix() {
    final random = Random();
    return List.generate(8, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  /// Downloads, checks, unpacks, and copies this application out to a folder
  /// it can run the swap from.
  ///
  /// [target] is the installed copy. The new one is unpacked **beside it**,
  /// not into the data directory: putting it in place has to be a rename, a
  /// rename cannot cross a filesystem, and the only place guaranteed to be on
  /// the same one as the target is next to the target.
  static Future<PreparedUpdate> prepare({
    required ReleaseSource source,
    required ReleaseArchive archive,
    required Directory target,
    required Directory running,
    Directory? temporary,
    String version = '',
    void Function(StageProgress)? onProgress,
  }) async {
    final temp = temporary ?? Directory.systemTemp;
    final work = Directory(
        '${temp.path}${Platform.pathSeparator}xverb-download-${_suffix()}');
    await work.create(recursive: true);

    try {
      onProgress?.call(const StageProgress(StageStep.downloading));
      final local = File('${work.path}${Platform.pathSeparator}${archive.name}');
      await source.fetch(archive.name, local,
          onProgress: (fraction) => onProgress
              ?.call(StageProgress(StageStep.downloading, fraction: fraction)));

      onProgress?.call(const StageProgress(StageStep.verifying));
      final sums = File('${local.path}.sha256');
      await source.fetch('${archive.name}.sha256', sums);
      final want = (await sums.readAsString()).trim().split(RegExp(r'\s+')).first;
      final got = await sha256OfFile(local);
      if (want.toLowerCase() != got.toLowerCase()) {
        // Not a warning. The file goes and the machine is not touched.
        throw StateError(
          'The download does not match its checksum.\n'
          '  published $want\n  received  $got',
        );
      }

      onProgress?.call(const StageProgress(StageStep.unpacking));
      final stagingRoot = Directory(
          '${target.parent.path}${Platform.pathSeparator}.xverb-staged-${_suffix()}');
      await stagingRoot.create(recursive: true);
      await unpack(local, stagingRoot);
      final staged = Directory(
          '${stagingRoot.path}${Platform.pathSeparator}${bundleName()}');
      if (!await staged.exists()) {
        throw StateError('That archive holds no ${bundleName()}.');
      }

      // Only now, with a verified copy unpacked, is this application copied
      // out. Doing it earlier would mean copying fifty megabytes to find out
      // afterwards that the download was bad.
      onProgress?.call(const StageProgress(StageStep.copying));
      final updaterFolder = Directory(
          '${temp.path}${Platform.pathSeparator}$kUpdaterFolderPrefix${_suffix()}');
      await updaterFolder.create(recursive: true);
      final updaterBundle = Directory(
          '${updaterFolder.path}${Platform.pathSeparator}${bundleName()}');
      await copyTree(running, updaterBundle);

      final handoff = UpdaterHandoff(
        pid: pid,
        target: target.path,
        staged: staged.path,
        marker: '${target.parent.path}'
            '${Platform.pathSeparator}$kUpdatePendingMarker',
        version: version.isEmpty ? '${archive.version}' : version,
      );
      await handoff.writeBeside(updaterBundle);

      onProgress?.call(const StageProgress(StageStep.ready));
      return PreparedUpdate(
        staged: staged,
        updaterFolder: updaterFolder,
        updaterBundle: updaterBundle,
        handoff: handoff,
      );
    } finally {
      if (await work.exists()) await work.delete(recursive: true);
    }
  }

  /// Starts the copy that will do the swap. The caller then exits — normally,
  /// so that anything with unsaved state gets its ordinary shutdown.
  static Future<void> handOver(PreparedUpdate prepared) async {
    if (Platform.isMacOS) {
      final result =
          await Process.run('open', ['-n', '-a', prepared.updaterBundle.path]);
      if (result.exitCode != 0) {
        throw ProcessException(
            'open', [prepared.updaterBundle.path], '${result.stderr}');
      }
      return;
    }
    final executable = Platform.isWindows
        ? '${prepared.updaterBundle.path}\\xverb.exe'
        : '${prepared.updaterBundle.path}/xverb';
    await Process.start(executable, const [],
        mode: ProcessStartMode.detachedWithStdio);
  }

  /// SHA-256 read in chunks: a release is twenty megabytes and there is no
  /// reason to hold it in memory as well as on disk.
  static Future<String> sha256OfFile(File file) async {
    Digest? result;
    final input = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback(
          (digests) => result = digests.single),
    );
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return result.toString();
  }

  /// The platform's own unpacker, because the archive shapes differ and
  /// because a Dart one would lose what matters: the symlinks inside a macOS
  /// framework and the executable bit everywhere.
  static Future<void> unpack(File archive, Directory into) async {
    final result = archive.path.endsWith('.zip')
        ? await Process.run('powershell', [
            '-NoProfile',
            '-Command',
            "Expand-Archive -Path '${archive.path}' "
                "-DestinationPath '${into.path}' -Force",
          ])
        : await Process.run('tar', ['-xzf', archive.path, '-C', into.path]);
    if (result.exitCode != 0) {
      throw StateError('The download is not a readable archive: '
          '${result.stderr}');
    }
  }

  /// The platform's own copy, for the same reason.
  static Future<void> copyTree(Directory from, Directory to) async {
    await to.parent.create(recursive: true);
    final ProcessResult result;
    if (Platform.isMacOS) {
      // ditto keeps symlinks, permissions and extended attributes, which a
      // bundle needs and cp -R does not promise.
      result = await Process.run('ditto', [from.path, to.path]);
    } else if (Platform.isWindows) {
      result = await Process.run('robocopy', [from.path, to.path, '/E', '/NFL',
          '/NDL', '/NJH', '/NJS', '/NP']);
      // robocopy says 0 for "nothing to do" and 1 for "copied", and anything
      // below 8 is a success it has opinions about.
      if (result.exitCode < 8) return;
    } else {
      result = await Process.run('cp', ['-a', from.path, to.path]);
    }
    if (result.exitCode != 0) {
      throw StateError('Could not copy ${from.path}: ${result.stderr}');
    }
  }
}
