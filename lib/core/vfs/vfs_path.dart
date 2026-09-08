import 'dart:io' show Platform;

/// A location inside the virtual file system.
///
/// Every location in xverb is a URI. The scheme selects which
/// [FileSystemProvider] handles it, so the local disk (`file:`), an FTP server
/// (`ftp:`) and anything a plugin invents are all addressed the same way.
///
/// Paths are stored in a normalised form: no trailing slash, except on a root.
class VfsPath implements Comparable<VfsPath> {
  VfsPath(Uri uri) : uri = _normalise(uri);

  /// Parses a URI string such as `file:///C:/Users` or `ftp://host/pub`.
  factory VfsPath.parse(String value) => VfsPath(Uri.parse(value));

  /// Wraps a native path (`C:\Users\me`, `/home/me`) as a `file:` location.
  factory VfsPath.local(String nativePath) =>
      VfsPath(Uri.file(nativePath, windows: Platform.isWindows));

  final Uri uri;

  static const String localScheme = 'file';

  /// The scheme the ZIP plugin serves, and the one this application was written
  /// against first. **Not the only one**: a container is anything a plugin
  /// declares as one, so `tar:` and whatever comes after it are addressed the
  /// same way — see [insideArchive], which is told which scheme it is building.
  static const String archiveScheme = 'zip';

  /// The query a location inside a container carries: where the container
  /// itself lives.
  static const String hostQuery = 'from';

  /// The root of [archive], browsed as a directory under [scheme].
  ///
  /// They look like `zip:///inner/path?from=file:///C:/box.zip`: the path is
  /// the path within the archive, so [parent] and [child] work on it exactly
  /// as they do anywhere else, and the archive itself rides along in the
  /// query — which means an archive on FTP is addressed the same way as one on
  /// the local disk.
  ///
  /// The scheme is the caller's to supply and comes from the manifest of
  /// whichever plugin claimed the file type. It used to be `zip:` for
  /// everything, which meant a `.tar.gz` was handed to the ZIP plugin and
  /// opened as a dead end.
  factory VfsPath.insideArchive(VfsPath archive, String scheme) => VfsPath(
        Uri.parse(
          '$scheme:///?$hostQuery=${Uri.encodeComponent(archive.toString())}',
        ),
      );

  /// The archive this location lives in, or null when it is not in one.
  ///
  /// The `from=` query is what makes a location a container's, not the scheme:
  /// every plugin that serves one uses the same convention, and the host has
  /// no business knowing which schemes those are.
  VfsPath? get archiveHost {
    if (scheme == localScheme) return null;
    final from = uri.queryParameters[hostQuery];
    return from == null || from.isEmpty ? null : VfsPath.parse(from);
  }

  bool get isInsideArchive => archiveHost != null;

  /// What this location says it is pointing *at*, or null when it says nothing.
  ///
  /// **A convention, not a scheme's secret.** A location may carry `ref=` in
  /// its query — the git file system does, for a commit or a branch — and that
  /// is what the panel names the place after. Without it every commit in a
  /// repository was a panel saying `git:`, which is true of all of them at
  /// once and tells nobody which one they are standing in. Item 59: it should
  /// read as `git://a1b2c3d`.
  ///
  /// Shortened only where shortening is safe: a string of hex the length of a
  /// hash is cut to the seven characters everybody reads a commit by, and
  /// anything else — a branch, a tag — is left whole, slashes and all. **What
  /// goes in the URL is never shortened**; this is a label.
  String? get refLabel {
    final ref = uri.queryParameters['ref'];
    if (ref == null || ref.isEmpty) return null;
    final isHash = ref.length >= 20 &&
        RegExp(r'^[0-9a-fA-F]+$').hasMatch(ref);
    return isHash ? ref.substring(0, 7) : ref;
  }

  /// Scheme used to look up the provider that owns this location.
  String get scheme => uri.scheme;

  /// Path segments with the trailing empty segment removed.
  List<String> get segments => uri.pathSegments;

  /// True when this location has no parent to navigate up to.
  bool get isRoot {
    // Inside an archive there is always a way out: the folder holding it.
    if (isInsideArchive) return false;
    if (segments.isEmpty) return true;
    // On Windows a drive letter (`file:///C:/`) is a root of its own.
    return _isWindowsDrive && segments.length == 1;
  }

  bool get _isWindowsDrive =>
      scheme == localScheme &&
      segments.isNotEmpty &&
      segments.first.length == 2 &&
      segments.first.endsWith(':');

  /// Last path segment, or the authority/scheme when at a root.
  String get name {
    if (segments.isNotEmpty) return segments.last;
    if (uri.host.isNotEmpty) return uri.host;
    return scheme;
  }

  /// The containing directory, or null if this is already a root.
  VfsPath? get parent {
    if (isRoot) return null;
    // Stepping out of an archive's top level lands in the folder that holds
    // the archive file, which is where the user came from.
    if (segments.isEmpty) return archiveHost?.parent;
    return VfsPath(uri.replace(
      pathSegments: segments.sublist(0, segments.length - 1),
    ));
  }

  /// A child entry of this directory.
  VfsPath child(String childName) =>
      VfsPath(uri.replace(pathSegments: [...segments, childName]));

  /// The topmost location reachable by walking [parent] repeatedly.
  VfsPath get root {
    var current = this;
    while (!current.isRoot) {
      current = current.parent!;
    }
    return current;
  }

  /// This location and everything above it, root first.
  ///
  /// What a path bar walks to draw one button per level.
  List<VfsPath> get trail {
    final trail = <VfsPath>[this];
    var current = this;
    while (!current.isRoot) {
      final above = current.parent;
      if (above == null) break;
      trail.insert(0, above);
      current = above;
    }
    return trail;
  }

  /// Short label for a breadcrumb button: the folder name, or something that
  /// identifies the whole volume when this is a root — `C:` locally, the host
  /// for anything served over a network.
  String get label {
    // The top of an archive is named after the archive, not after the scheme.
    if (segments.isEmpty) {
      final archive = archiveHost;
      if (archive != null) return archive.name;
    }
    if (!isRoot) return name;
    if (scheme == localScheme) {
      return segments.isEmpty ? '/' : segments.first;
    }
    if (uri.host.isNotEmpty) return '$scheme://${uri.host}';
    // Somewhere that names what it is pointing at — a commit, a revision.
    final ref = refLabel;
    return ref == null ? '$scheme:' : '$scheme://$ref';
  }

  /// What to call the whole volume, for the pill at the head of the path bar.
  ///
  /// `C:` on Windows, where a drive letter is the volume and the trail starts
  /// below it. **Empty on POSIX**, where there is one tree and no drive
  /// letters: the root *is* `/`, so a pill saying `/` in front of a trail
  /// starting at `/` gave the path bar two of them — and the first one
  /// navigated nowhere, because the pill opens the list of volumes. With
  /// nothing to add, the pill is its icon and the trail owns the `/`.
  ///
  /// Anything not on the local disk is named by its own root — the host for a
  /// transport, the archive for an archive — which is already the most useful
  /// thing to call it.
  String get volumeLabel {
    if (scheme != localScheme) return root.label;
    return Platform.isWindows ? root.label : '';
  }

  /// True when [other] is this location or lives somewhere beneath it.
  /// Used to stop a copy from recursing into its own destination.
  bool contains(VfsPath other) {
    if (scheme != other.scheme || uri.authority != other.uri.authority) {
      return false;
    }
    // Two archives can hold the same inner path without one being inside the
    // other, so which archive it is has to match too.
    if (uri.query != other.uri.query) return false;
    if (other.segments.length < segments.length) return false;
    for (var i = 0; i < segments.length; i++) {
      if (segments[i] != other.segments[i]) return false;
    }
    return true;
  }

  /// Native path for local locations. Throws for any other scheme.
  String toNativePath() => uri.toFilePath(windows: Platform.isWindows);

  /// Human-readable form shown in the path bar.
  String get display {
    // Inside an archive, show it the way it is browsed — the archive followed
    // by the path within it, not the machinery that addresses it.
    final archive = archiveHost;
    if (archive != null) {
      if (segments.isEmpty) return archive.display;
      final separator = archive.scheme == localScheme && Platform.isWindows
          ? r'\'
          : '/';
      return '${archive.display}$separator${segments.join(separator)}';
    }
    if (scheme == localScheme) {
      final native = toNativePath();
      // `toFilePath` keeps the trailing separator on roots; keep it, it reads
      // better as `C:\` than as `C:`.
      return native;
    }
    return Uri.decodeFull(uri.toString());
  }

  static Uri _normalise(Uri uri) {
    final segments = List<String>.from(uri.pathSegments);
    while (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    return uri.replace(pathSegments: segments);
  }

  @override
  int compareTo(VfsPath other) => uri.toString().compareTo(other.uri.toString());

  @override
  bool operator ==(Object other) => other is VfsPath && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  /// The canonical string form, and the one every plugin is handed.
  ///
  /// A root is spelled **with** its trailing slash. On Windows `file:///C:` and
  /// `file:///C:/` are not the same place to anything that turns the URL back
  /// into a native path: `C:` names the current directory *on* drive C, not the
  /// drive itself. A plugin that read the path literally scanned its own folder
  /// and drew that as the contents of the disk.
  ///
  /// The slash lives here rather than in [uri], because a stored trailing slash
  /// is an empty last segment, and [segments] is what [name], [parent],
  /// [isRoot] and [contains] are all built on. [VfsPath.parse] normalises it
  /// away again, so this round-trips.
  /// The slash goes into the **path**, not onto the end of the string: a
  /// connection carries its options in the query, and `ftp://host?passive=true`
  /// ends in the value, not in the path.
  @override
  String toString() {
    if (!isRoot || uri.path.endsWith('/')) return uri.toString();
    return uri.replace(path: '${uri.path}/').toString();
  }
}
