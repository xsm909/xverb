/// How a copy of the application knows it was started to update another one.
///
/// Not through command-line arguments. The three desktop runners hand argv to
/// Dart by three different routes and one of them is a Flutter version away
/// from changing; a file beside the bundle arrives the same way everywhere and
/// can be read back afterwards by a person wondering what happened.
///
/// The copy that updates is the *installed application itself*, copied into a
/// temporary folder. That is the whole of the design: it already has the
/// engine, the palette, the title bar and the wordmark, so the progress the
/// user sees is the application's own and not an approximation of it, and
/// nothing is added to a release to get it.
library;

import 'dart:convert';
import 'dart:io';

/// The folder that holds the running program.
///
/// macOS puts the executable three levels inside the bundle; Linux and Windows
/// put it in the folder itself. Pure, and takes the path and the platform, so
/// a test can ask about all three from any one of them.
Directory bundleRootOf(String resolvedExecutable, {String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final separator = os == 'windows' ? r'\' : '/';
  var parts = resolvedExecutable.split(separator);
  // xverb.app/Contents/MacOS/xverb -> xverb.app
  final up = os == 'macos' ? 4 : 2;
  if (parts.length < up) return Directory(resolvedExecutable);
  parts = parts.sublist(0, parts.length - (up - 1));
  final path = parts.join(separator);
  return Directory(path.isEmpty ? separator : path);
}

/// The name every temporary updater folder starts with.
///
/// Checked as well as the file, so that a stray `handoff.json` somebody drops
/// beside an installed copy cannot turn an ordinary start into an update.
const String kUpdaterFolderPrefix = 'xverb-update-';

const String kHandoffFileName = 'handoff.json';

/// The marker a newly installed copy deletes once it has drawn a window.
///
/// Named in one place because two of them have to agree without ever meeting:
/// the copy that installs writes it, and the copy that is installed clears it.
const String kUpdatePendingMarker = '.xverb-update-pending';

/// What one copy tells the other.
class UpdaterHandoff {
  const UpdaterHandoff({
    required this.pid,
    required this.target,
    required this.staged,
    required this.marker,
    required this.version,
  });

  /// The installed copy's process, to wait for. **By pid and never by name** —
  /// a debug build running out of a checkout is not the copy being replaced.
  final int pid;

  /// The installed copy, the thing being replaced.
  final String target;

  /// The new copy, already downloaded, verified and unpacked.
  final String staged;

  /// The file the new copy deletes once it has drawn something.
  final String marker;

  /// What is being installed, to show while it happens.
  final String version;

  Map<String, Object?> toJson() => {
        'pid': pid,
        'target': target,
        'staged': staged,
        'marker': marker,
        'version': version,
      };

  static UpdaterHandoff? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    final pid = decoded['pid'];
    final target = decoded['target'];
    final staged = decoded['staged'];
    final marker = decoded['marker'];
    final version = decoded['version'];
    if (pid is! int ||
        target is! String ||
        staged is! String ||
        marker is! String ||
        version is! String) {
      return null;
    }
    return UpdaterHandoff(
      pid: pid,
      target: target,
      staged: staged,
      marker: marker,
      version: version,
    );
  }

  /// Where the file sits: beside the copied bundle, in the temporary folder.
  static File fileBeside(Directory bundleRoot) =>
      File('${bundleRoot.parent.path}${Platform.pathSeparator}$kHandoffFileName');

  Future<void> writeBeside(Directory bundleRoot) =>
      fileBeside(bundleRoot).writeAsString(const JsonEncoder.withIndent('  ')
          .convert(toJson()));

  /// The handoff this running copy was started with, or null for an ordinary
  /// start — which is every start but one in the life of an installation.
  ///
  /// Both conditions must hold: the folder is one we made, and the file reads.
  /// Neither alone is enough to turn a start into an update.
  static Future<UpdaterHandoff?> forRunningCopy({
    String? resolvedExecutable,
    String? operatingSystem,
  }) async {
    final root = bundleRootOf(
      resolvedExecutable ?? Platform.resolvedExecutable,
      operatingSystem: operatingSystem,
    );
    final holder = root.parent;
    final name = holder.path.split(Platform.pathSeparator).last;
    if (!name.startsWith(kUpdaterFolderPrefix)) return null;
    final file = fileBeside(root);
    if (!await file.exists()) return null;
    try {
      return fromJson(jsonDecode(await file.readAsString()));
    } on FormatException {
      return null;
    }
  }
}
