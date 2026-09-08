import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;
import '../../i18n/i18n.dart';
import 'package:path_provider/path_provider.dart';

/// Progress of an in-flight install, for the settings page.
class InstallProgress {
  const InstallProgress(this.message, {this.fraction});

  final String message;

  /// 0..1 while downloading, null while doing something unmeasurable.
  final double? fraction;
}

/// Downloads the interpreter that plugins are guaranteed to run on.
///
/// One pinned build, the same language version on every platform — see
/// "Target Python version" in `docs/plugins.md`. It unpacks into the app's
/// support directory: no administrator rights, no PATH changes, no registry,
/// nothing to uninstall but a folder.
///
/// The source is python-build-standalone rather than python.org because
/// python.org publishes a self-contained build for Windows only, and its 3.12
/// line stopped at 3.12.10 when that branch went security-only. One project
/// covers Windows, macOS and Linux with the *same* patch release, which is the
/// whole point of pinning.
class PythonInstaller {
  const PythonInstaller._();

  /// The language version plugins are written against. Also the floor the
  /// runtime enforces — see `PythonRuntime.meetsFloor`.
  static const int targetMajor = 3;
  static const int targetMinor = 12;

  /// The exact build. Both halves move together: an asset only exists under
  /// the release it was published in, so a version without its tag is a 404.
  static const String pinnedVersion = '3.12.13';
  static const String pinnedRelease = '20260807';

  /// Human-readable form for dialogs and the plugin manager.
  static String get pinnedLabel => 'Python $pinnedVersion';

  /// Available wherever a child process can be spawned and the pinned release
  /// publishes a build. Every desktop architecture we support is covered.
  static bool get isSupported => _target != null;

  /// python-build-standalone's target triple for this machine, or null when it
  /// publishes nothing for it.
  static String? get _target => switch (Abi.current()) {
        Abi.windowsX64 => 'x86_64-pc-windows-msvc',
        Abi.windowsArm64 => 'aarch64-pc-windows-msvc',
        Abi.windowsIA32 => 'i686-pc-windows-msvc',
        Abi.macosArm64 => 'aarch64-apple-darwin',
        Abi.macosX64 => 'x86_64-apple-darwin',
        Abi.linuxX64 => 'x86_64-unknown-linux-gnu',
        Abi.linuxArm64 => 'aarch64-unknown-linux-gnu',
        _ => null,
      };

  /// `install_only` is the stripped distribution: an interpreter and its
  /// standard library, without the build artefacts the full archive carries.
  static String? get assetName => switch (_target) {
        final String target =>
          'cpython-$pinnedVersion+$pinnedRelease-$target-install_only.tar.gz',
        _ => null,
      };

  /// The URL that will be used, so the dialog can show it before downloading.
  static String? get plannedUrl => switch (assetName) {
        final String asset =>
          'https://github.com/astral-sh/python-build-standalone/releases/'
              'download/$pinnedRelease/$asset',
        _ => null,
      };

  /// Where a managed interpreter lives, whether or not it is installed.
  static Future<Directory> directory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'python'));
  }

  /// The interpreter inside an unpacked archive. Every target unpacks to a
  /// single `python/` directory; only where the executable sits differs.
  static String interpreterIn(Directory root) => Platform.isWindows
      ? p.join(root.path, 'python', 'python.exe')
      : p.join(root.path, 'python', 'bin', 'python3');

  /// Path to the managed interpreter, or null when it is not installed.
  static Future<String?> installed() async {
    final exe = File(interpreterIn(await directory()));
    return await exe.exists() ? exe.path : null;
  }

  /// Downloads and unpacks. Returns the interpreter path, or throws with a
  /// message worth showing.
  static Future<String> install({
    void Function(InstallProgress progress)? onProgress,
  }) async {
    final url = plannedUrl;
    if (url == null) {
      throw StateError(
        'No pinned Python build is published for this machine '
        '(${Abi.current()}).',
      );
    }

    final target = await directory();
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);

    final archive = File(p.join(target.path, 'python.tar.gz'));
    await _download(url, archive, onProgress);

    onProgress?.call(InstallProgress(tr('Unpacking the interpreter…')));
    await _unpack(archive, target);
    await archive.delete();

    onProgress?.call(InstallProgress(tr('Checking that it runs…')));

    final exe = File(interpreterIn(target));
    if (!await exe.exists()) {
      throw StateError(tr('The archive did not contain {file}.',
          {'file': p.basename(exe.path)}));
    }

    // Prove it runs before reporting success. A half-extracted interpreter
    // that is merely present would fail later, somewhere less obvious.
    final check = await Process.run(exe.path, ['-c', 'print(1)']);
    if (check.exitCode != 0) {
      throw StateError(tr('The downloaded interpreter did not run: {error}',
          {'error': check.stderr}));
    }

    onProgress?.call(
        InstallProgress(tr('Installed {version}.', {'version': pinnedLabel})));
    return exe.path;
  }

  static Future<void> _download(
    String url,
    File destination,
    void Function(InstallProgress)? onProgress,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      onProgress?.call(InstallProgress(
          tr('Downloading {version}…', {'version': pinnedLabel})));

      // The release asset is served from a redirect, which HttpClient follows
      // by default; the status below is the one at the end of the chain.
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode} for $url');
      }

      final total = response.contentLength;
      var received = 0;
      final sink = destination.openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          // Says how far along it is in megabytes as well as by the bar. A
          // 25 MB download over a slow line looks stuck otherwise, and the
          // honest answer to "is it doing anything" is a number that moves.
          onProgress?.call(InstallProgress(
            total > 0
                ? tr('Downloading {version} — {done} of {total} MB', {
                    'version': pinnedLabel,
                    'done': _mb(received),
                    'total': _mb(total),
                  })
                : tr('Downloading {version} — {done} MB',
                    {'version': pinnedLabel, 'done': _mb(received)}),
            fraction: total > 0 ? received / total : null,
          ));
        }
      } finally {
        await sink.close();
      }

      // The build is tens of megabytes; anything tiny is an error page that
      // happened to come back with a 200.
      if (await destination.length() < 1 << 20) {
        throw StateError('The download from $url was too small to be real.');
      }
    } finally {
      client.close(force: true);
    }
  }

  static String _mb(int bytes) => (bytes / (1 << 20)).toStringAsFixed(1);

  /// `tar` rather than a zip dependency: it ships with macOS and Linux, and
  /// Windows has carried bsdtar in System32 since Windows 10 1803.
  static Future<void> _unpack(File archive, Directory target) async {
    final result = await Process.run(
      'tar',
      ['-xzf', archive.path, '-C', target.path],
    );
    if (result.exitCode != 0) {
      throw StateError(
          tr('Unpacking failed: {error}', {'error': result.stderr}));
    }
  }

  /// Removes a managed interpreter.
  static Future<void> uninstall() async {
    final target = await directory();
    if (await target.exists()) await target.delete(recursive: true);
  }
}
