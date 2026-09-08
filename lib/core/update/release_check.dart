/// Asking the release repository whether there is anything newer.
///
/// Nothing here downloads a release or touches the installed copy. It reads a
/// listing, picks the largest version, and says how that compares with the
/// version running. Everything that could change the machine belongs to the
/// step after this one.
///
/// The newest release is simply the largest version published — there is no
/// index to read, none to keep in step, and publishing a release is adding
/// files and nothing else.
///
/// **All four parts of `A.B.C.D` count, the build among them.** A version that
/// moves only `D` is an update like any other. Everything in the release
/// folder is put there by hand, one archive at a time, so a build reaching
/// anybody is already the decision that it should — and a one-line fix can be
/// the one somebody is waiting for. See `core/version.dart` for what each part
/// promises.
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

/// A four-part version, ordered by number rather than by text.
///
/// Compared part by part on purpose: as text, `1.0.10.0` sorts before
/// `1.0.9.0`, and the first release after the ninth would then look older than
/// the one it replaced.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.parts);

  /// Always four numbers. A version written with fewer is padded with zeros,
  /// so `1.0.2` and `1.0.2.0` are the same version rather than two.
  final List<int> parts;

  static ReleaseVersion? tryParse(String text) {
    final pieces = text.split('.');
    if (pieces.isEmpty || pieces.length > 4) return null;
    final numbers = <int>[];
    for (final piece in pieces) {
      final value = int.tryParse(piece);
      if (value == null || value < 0) return null;
      numbers.add(value);
    }
    while (numbers.length < 4) {
      numbers.add(0);
    }
    return ReleaseVersion(numbers);
  }

  @override
  int compareTo(ReleaseVersion other) {
    for (var i = 0; i < 4; i++) {
      final difference = parts[i].compareTo(other.parts[i]);
      if (difference != 0) return difference;
    }
    return 0;
  }

  bool operator >(ReleaseVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is ReleaseVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(parts);

  @override
  String toString() => parts.join('.');
}

/// One published file, as its name describes it.
///
/// The name is the whole of the metadata, deliberately: `package.dart` builds
/// it and the installer reads it, and a name cannot fall out of step with
/// itself the way a separate index can.
class ReleaseArchive {
  const ReleaseArchive({
    required this.name,
    required this.version,
    required this.platform,
    required this.arch,
  });

  final String name;
  final ReleaseVersion version;
  final String platform;
  final String arch;

  static final RegExp _shape = RegExp(
    r'^xverb-([0-9]+(?:\.[0-9]+){0,3})-([a-z0-9]+)-([a-z0-9_]+)\.(?:tar\.gz|zip)$',
  );

  /// Null for anything that is not a release archive — a checksum, a readme,
  /// the `.gitkeep` that holds the empty folder open. The listing is somebody
  /// else's directory and must not be assumed to hold only what we expect.
  static ReleaseArchive? tryParse(String fileName) {
    final match = _shape.firstMatch(fileName);
    if (match == null) return null;
    final version = ReleaseVersion.tryParse(match.group(1)!);
    if (version == null) return null;
    return ReleaseArchive(
      name: fileName,
      version: version,
      platform: match.group(2)!,
      arch: match.group(3)!,
    );
  }
}

/// Where the list of published files comes from.
///
/// An interface with two implementations rather than one function that knows
/// about GitHub: a directory standing in for the repository is how the whole
/// path is exercised without a network and without publishing anything.
abstract class ReleaseSource {
  /// Every file name in the release folder. Throws if the source cannot be
  /// read — which is not the same as a source holding no release, and the two
  /// must not be reported alike.
  Future<List<String>> fileNames();

  /// Puts one published file into [into].
  ///
  /// [onProgress] is called with a fraction where the size is known and null
  /// where it is not, so a caller can show a bar or a spinner without asking
  /// which it should be.
  Future<void> fetch(
    String name,
    File into, {
    void Function(double? fraction)? onProgress,
  });

  /// Named in whatever the person is told when something goes wrong.
  String get describe;
}

/// The public release repository, read through the contents endpoint, which
/// lists a directory without cloning it.
class GithubReleaseSource implements ReleaseSource {
  const GithubReleaseSource({
    this.repository = 'xsm909/xverb-release',
    this.folder = 'release',
    this.timeout = const Duration(seconds: 20),
  });

  final String repository;
  final String folder;
  final Duration timeout;

  @override
  String get describe => 'https://github.com/$repository/tree/main/$folder';

  @override
  Future<List<String>> fileNames() async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final url =
          Uri.https('api.github.com', '/repos/$repository/contents/$folder');
      final request = await client.getUrl(url);
      // GitHub answers some clients with 403 unless they name themselves, and
      // the JSON version header keeps the answer's shape from moving under us.
      request.headers.set(HttpHeaders.userAgentHeader, 'xverb');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! List) {
        throw const FormatException('The release listing is not a list.');
      }
      return [
        for (final entry in decoded)
          if (entry is Map && entry['name'] is String) entry['name'] as String,
      ];
    } finally {
      client.close(force: true);
    }
  }

  /// Read from `raw.githubusercontent.com` rather than through the API: the
  /// contents endpoint answers with base64 inside JSON and refuses outright
  /// over a megabyte, and a release is twenty.
  @override
  Future<void> fetch(
    String name,
    File into, {
    void Function(double? fraction)? onProgress,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final url = Uri.https(
          'raw.githubusercontent.com', '/$repository/main/$folder/$name');
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'xverb');
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      final total = response.contentLength;
      var received = 0;
      final sink = into.openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(total > 0 ? received / total : null);
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }
}

/// A directory standing in for the repository — for the self-tests, and for a
/// release folder on a share.
class DirectoryReleaseSource implements ReleaseSource {
  const DirectoryReleaseSource(this.directory);

  final Directory directory;

  @override
  String get describe => directory.path;

  @override
  Future<List<String>> fileNames() async {
    if (!await directory.exists()) {
      throw FileSystemException('No such directory', directory.path);
    }
    return [
      for (final entry in await directory.list().toList())
        entry.path.split(Platform.pathSeparator).last,
    ];
  }

  @override
  Future<void> fetch(
    String name,
    File into, {
    void Function(double? fraction)? onProgress,
  }) async {
    onProgress?.call(0);
    await File('${directory.path}${Platform.pathSeparator}$name').copy(into.path);
    onProgress?.call(1);
  }
}

/// What a release says for itself.
///
/// `xverb-1.0.1.0-notes.md`, beside the archives: one file per version
/// and not per archive, because the notes are the same on every platform.
/// `package.dart` writes it from the log — see there for why the log is the
/// changelog.
class ReleaseNotes {
  static String fileNameFor(ReleaseVersion version) =>
      'xverb-$version-notes.md';

  /// The first [most] lines, or none at all.
  ///
  /// **Never throws.** A release published without notes is still a release,
  /// and an update the person cannot take because a text file is missing would
  /// be the tail wagging the dog. The offer says so plainly instead.
  static Future<List<String>> fetch(
    ReleaseSource source,
    ReleaseVersion version, {
    int most = 5,
    Directory? temporary,
  }) async {
    final temp = temporary ?? Directory.systemTemp;
    final into = File('${temp.path}${Platform.pathSeparator}'
        'xverb-notes-$version.md');
    try {
      await source.fetch(fileNameFor(version), into);
      return readLines(await into.readAsString(), most: most);
    } on Object {
      return const [];
    } finally {
      try {
        if (await into.exists()) await into.delete();
      } on Object {
        // A file left in the temporary directory is not worth an error.
      }
    }
  }

  /// The bullets, in the order they were written. Pure, so the shape of the
  /// file is tested without a source and without a disk.
  static List<String> readLines(String text, {int most = 5}) {
    final lines = <String>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (!line.startsWith('- ')) continue;
      final said = line.substring(2).trim();
      if (said.isEmpty) continue;
      lines.add(said);
      if (lines.length == most) break;
    }
    return lines;
  }
}

/// The source a check reads when nobody hands it one.
///
/// `XVERB_RELEASE` names a directory to read instead of the repository —
/// the same substitution the installer's `--from` makes, and what makes the
/// whole update path runnable on a machine with no network and nothing
/// published. Read at the moment of the check rather than kept, so a folder
/// that appears later is seen.
ReleaseSource defaultReleaseSource() {
  final override = Platform.environment['XVERB_RELEASE'];
  if (override != null && override.isNotEmpty) {
    return DirectoryReleaseSource(Directory(override));
  }
  return const GithubReleaseSource();
}

/// What a check found. Four outcomes, and the last two are deliberately not
/// one: a repository that cannot be reached and a repository holding no
/// release call for different things from whoever is reading.
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

class UpToDate extends UpdateCheckResult {
  const UpToDate(this.running);
  final ReleaseVersion running;
}

class UpdateAvailable extends UpdateCheckResult {
  const UpdateAvailable(this.running, this.archive);
  final ReleaseVersion running;
  final ReleaseArchive archive;
}

class NoReleasePublished extends UpdateCheckResult {
  const NoReleasePublished(this.source);
  final String source;
}

class CheckFailed extends UpdateCheckResult {
  const CheckFailed(this.source, this.problem);
  final String source;
  final Object problem;
}

/// The platform name `package.dart` builds into an archive name.
String currentPlatformName() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return Platform.operatingSystem;
}

/// The architecture name `package.dart` builds into an archive name.
String currentArchName() => switch (Abi.current()) {
      Abi.macosArm64 || Abi.linuxArm64 || Abi.windowsArm64 => 'arm64',
      _ => 'x64',
    };

/// Reads the listing and says whether anything newer was published.
///
/// [arch] is matched only when the source offers something for this platform
/// at that architecture. A release built for the other architecture of the
/// same platform is not an update for this machine, and offering it would
/// install something that cannot run.
Future<UpdateCheckResult> checkForUpdate({
  required ReleaseSource source,
  required ReleaseVersion running,
  String? platform,
  String? arch,
}) async {
  final wantPlatform = platform ?? currentPlatformName();
  final wantArch = arch ?? currentArchName();

  List<String> names;
  try {
    names = await source.fileNames();
  } on Object catch (problem) {
    return CheckFailed(source.describe, problem);
  }

  ReleaseArchive? newest;
  for (final name in names) {
    final archive = ReleaseArchive.tryParse(name);
    if (archive == null) continue;
    if (archive.platform != wantPlatform || archive.arch != wantArch) continue;
    if (newest == null || archive.version > newest.version) newest = archive;
  }

  if (newest == null) return NoReleasePublished(source.describe);
  if (newest.version > running) return UpdateAvailable(running, newest);
  return UpToDate(running);
}
