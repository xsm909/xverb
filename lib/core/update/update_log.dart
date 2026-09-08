/// What happened the last few times an update was attempted.
///
/// An update is the one operation that **ends the process it is reported in**.
/// The application hands over and exits; the copy that performs the swap draws
/// a window for a couple of seconds and then it too is gone. So an account of
/// a failure that lives only on the screen is an account that is lost — which
/// is exactly what happened on Windows on 2026-09-08: a message said why the
/// update had not worked, and it was gone before it could be read.
///
/// Appended, never replaced, because the two halves of an update are two
/// processes and the interesting failures are in the half that no longer
/// exists. Trimmed from the front when it grows, so a file nobody ever looks
/// at cannot become a file nobody can open.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class UpdateLog {
  const UpdateLog._();

  static const String fileName = 'update.log';

  /// How much is kept. A few attempts, and each is a dozen short lines.
  static const int keepBytes = 64 * 1024;

  static Future<File?> _file() async {
    try {
      final support = await getApplicationSupportDirectory();
      return File(p.join(support.path, fileName));
    } on Object {
      return null;
    }
  }

  /// Where the log is, for the window that reports a failure to point at.
  /// Null when there is no data directory to hold one, which is not an error.
  static Future<String?> path() async => (await _file())?.path;

  /// One line, stamped. **Never throws**: diagnostics must not be the reason
  /// something fails.
  static Future<void> write(String message) async {
    try {
      final file = await _file();
      if (file == null) return;
      await file.parent.create(recursive: true);
      final stamp = DateTime.now().toIso8601String();
      await file.writeAsString('$stamp  $message\n', mode: FileMode.append);
      await _trim(file);
    } on Object {
      // A locked or full disk is not worth a failed update.
    }
  }

  /// The head of a new attempt, so the lines under it can be read as one.
  static Future<void> begin(String what) => write(
        '\n=== $what · ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}',
      );

  static Future<void> _trim(File file) async {
    try {
      if (await file.length() <= keepBytes) return;
      final text = await file.readAsString();
      await file.writeAsString(text.substring(text.length - keepBytes ~/ 2));
    } on Object {
      // Unreadable as text — a log worth keeping is one we can rewrite, and
      // one we cannot is one to leave alone.
    }
  }
}
