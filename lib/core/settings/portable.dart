/// A copy that keeps everything it writes beside itself.
///
/// A portable copy runs from any folder, a USB stick included, and leaves no
/// trace in `%APPDATA%` or anywhere else on the machine. It is switched on by a
/// folder named [folderName] next to the executable: the folder is both the
/// switch and the place. Nothing is written until it exists, so a copy that is
/// not meant to be portable never becomes one by accident.
///
/// Every path the application uses for its own data comes from
/// `getApplicationSupportDirectory()` — settings, plugins, the managed Python,
/// connections, the reading state — and so does `shared_preferences`. So the
/// whole change is two substitutions made once, before the first read, and none
/// of the places that ask for a folder know about it.
///
/// Windows only. The passwords in `connections` are encrypted for the Windows
/// account by DPAPI, so a portable folder carried to another machine or user
/// keeps everything but the passwords, which are asked for again.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

/// The name of the folder beside the executable that holds everything.
const String kPortableFolderName = 'UserSettings';

/// The portable data folder for a program at [resolvedExecutable], or null when
/// that copy is an ordinary one. Pure, so a test can ask about any path.
Directory? portableFolderFor(
  String resolvedExecutable, {
  bool Function(String path)? exists,
}) {
  // The style of the path it is given, so a test on any machine can ask about a
  // Windows path.
  final style = resolvedExecutable.contains(r'\') ? p.windows : p.posix;
  final path = style.join(style.dirname(resolvedExecutable), kPortableFolderName);
  final present = exists ?? (candidate) => Directory(candidate).existsSync();
  return present(path) ? Directory(path) : null;
}

/// Answers the support directory with the portable folder.
class PortablePathProvider extends PathProviderWindows {
  PortablePathProvider(this.folder);

  final Directory folder;

  @override
  Future<String?> getApplicationSupportPath() async {
    await folder.create(recursive: true);
    return folder.path;
  }
}

class Portable {
  const Portable._();

  /// The portable folder of the running copy, or null. Set by [apply].
  static Directory? folder;

  /// Called first in `main`, before anything reads a setting.
  ///
  /// Returns whether this copy is portable.
  static bool apply() {
    if (!Platform.isWindows) return false;
    final found = portableFolderFor(Platform.resolvedExecutable);
    if (found == null) return false;
    folder = found;
    final provider = PortablePathProvider(found);
    // The platform's own provider is replaced for our code, and handed to the
    // preferences store, which makes its own and would otherwise go on writing
    // to `%APPDATA%` beside everything else being moved.
    PathProviderPlatform.instance = provider;
    final store = SharedPreferencesWindows();
    // ignore: invalid_use_of_visible_for_testing_member
    store.pathProvider = provider;
    SharedPreferencesStorePlatform.instance = store;
    return true;
  }
}
