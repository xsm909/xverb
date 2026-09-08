import 'dart:convert';
import 'dart:io';

import '../i18n/i18n.dart';
import 'package:path/path.dart' as p;

/// Moves local files to the platform's recycle bin instead of destroying them.
///
/// Every platform does this differently and none of it is in `dart:io`, so each
/// one gets the least fragile implementation available: a batched shell call on
/// Windows and macOS, and the freedesktop.org spec — which is just file moves —
/// on Linux.
class Trash {
  const Trash._();

  /// Whether this platform has somewhere to move deleted files to.
  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// A human-readable name for the destination, used in confirmations.
  static String get name =>
      Platform.isWindows ? tr('Recycle Bin') : tr('Trash');

  /// Whether a native path is already inside the recycle bin.
  ///
  /// Deleting something that is already there cannot mean "move it there", so
  /// the only honest offer is a permanent delete — and saying "move to the
  /// recycle bin" and then destroying the file is the worst kind of surprise.
  /// Emptying the bin from the panel is an ordinary thing to want to do.
  static bool isInside(String nativePath) {
    final path = p.normalize(nativePath);
    for (final root in _roots()) {
      if (p.equals(path, root) || p.isWithin(root, path)) return true;
    }
    return false;
  }

  /// Where the bin lives, as far as this platform is concerned.
  ///
  /// Windows keeps one per volume at the root, so every drive letter counts.
  static List<String> _roots() {
    if (Platform.isWindows) {
      final roots = <String>[];
      for (var letter = 'A'.codeUnitAt(0); letter <= 'Z'.codeUnitAt(0); letter++) {
        roots.add('${String.fromCharCode(letter)}:\\\$Recycle.Bin');
        roots.add('${String.fromCharCode(letter)}:\\RECYCLER');
      }
      return roots;
    }

    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return const [];
    if (Platform.isMacOS) return [p.join(home, '.Trash')];

    final dataHome = Platform.environment['XDG_DATA_HOME']?.isNotEmpty ?? false
        ? Platform.environment['XDG_DATA_HOME']!
        : p.join(home, '.local', 'share');
    return [p.join(dataHome, 'Trash')];
  }

  /// Sends [nativePaths] to the recycle bin.
  ///
  /// Returns the paths it could not move, so the caller can report them rather
  /// than silently pretending they are gone. Throws nothing.
  static Future<List<String>> send(List<String> nativePaths) async {
    if (nativePaths.isEmpty) return const [];
    if (!isSupported) return List.of(nativePaths);

    try {
      if (Platform.isWindows) return await _windows(nativePaths);
      if (Platform.isMacOS) return await _macos(nativePaths);
      return await _freedesktop(nativePaths);
    } on Object {
      return List.of(nativePaths);
    }
  }

  /// Uses the VB.NET file-system helper, which is the documented way to reach
  /// the shell's recycle operation without hand-rolling `SHFileOperationW`.
  /// The whole batch goes through one PowerShell start-up, not one per file.
  static Future<List<String>> _windows(List<String> paths) async {
    final listFile = File(p.join(
      Directory.systemTemp.path,
      'xverb-trash-$pid-${paths.length}.txt',
    ));
    await listFile.writeAsString(paths.join('\n'), encoding: utf8);

    const script = r'''
Add-Type -AssemblyName Microsoft.VisualBasic
$failed = @()
foreach ($line in [System.IO.File]::ReadAllLines($env:XC_TRASH_LIST, [System.Text.Encoding]::UTF8)) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  try {
    if (Test-Path -LiteralPath $line -PathType Container) {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
        $line, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } else {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
        $line, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
  } catch { $failed += $line }
}
$failed -join "`n"
''';

    try {
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script],
        environment: {'XC_TRASH_LIST': listFile.path},
      );
      if (result.exitCode != 0) return List.of(paths);
      return _nonEmptyLines(result.stdout.toString());
    } finally {
      try {
        await listFile.delete();
      } on FileSystemException {
        // A stray temp file is not worth reporting.
      }
    }
  }

  static Future<List<String>> _macos(List<String> paths) async {
    final quoted = paths
        .map((path) => 'POSIX file "${path.replaceAll('"', r'\"')}"')
        .join(', ');
    final result = await Process.run(
      'osascript',
      ['-e', 'tell application "Finder" to delete { $quoted }'],
    );
    return result.exitCode == 0 ? const [] : List.of(paths);
  }

  /// The freedesktop.org trash spec: move the file into `~/.local/share/Trash`
  /// and drop a `.trashinfo` beside it recording where it came from.
  static Future<List<String>> _freedesktop(List<String> paths) async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return List.of(paths);

    final dataHome = Platform.environment['XDG_DATA_HOME']?.isNotEmpty ?? false
        ? Platform.environment['XDG_DATA_HOME']!
        : p.join(home, '.local', 'share');

    final files = Directory(p.join(dataHome, 'Trash', 'files'));
    final info = Directory(p.join(dataHome, 'Trash', 'info'));
    await files.create(recursive: true);
    await info.create(recursive: true);

    final failed = <String>[];
    for (final path in paths) {
      try {
        final target = _uniqueIn(files, p.basename(path));
        final stamp = DateTime.now().toIso8601String().split('.').first;

        await File(p.join(info.path, '${p.basename(target)}.trashinfo'))
            .writeAsString(
          '[Trash Info]\nPath=${Uri.encodeFull(path)}\nDeletionDate=$stamp\n',
        );

        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await Directory(path).rename(target);
        } else {
          await File(path).rename(target);
        }
      } on Object {
        failed.add(path);
      }
    }
    return failed;
  }

  /// Trash entries must not collide, so a taken name gains a numeric suffix.
  static String _uniqueIn(Directory directory, String name) {
    var candidate = p.join(directory.path, name);
    if (!FileSystemEntity.typeSync(candidate, followLinks: false)
        .toString()
        .contains('notFound')) {
      final extension = p.extension(name);
      final stem = p.basenameWithoutExtension(name);
      for (var index = 1; index < 10000; index++) {
        candidate = p.join(directory.path, '$stem.$index$extension');
        if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
            FileSystemEntityType.notFound) {
          break;
        }
      }
    }
    return candidate;
  }

  static List<String> _nonEmptyLines(String output) => output
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}
