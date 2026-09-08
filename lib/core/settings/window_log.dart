import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A short trace of everything done to the window.
///
/// The backdrop has had three separate causes for the same symptom, and each
/// was diagnosed by guessing. This records what was applied and why, so the
/// next report can be read rather than theorised about: the file says whether
/// the effect was set, what set it last, and what the window was doing at the
/// time.
class WindowLog {
  const WindowLog._();

  static File? _file;
  static final List<String> _pending = [];
  static final Stopwatch _since = Stopwatch()..start();

  /// Opens the log, replacing the previous run's.
  static Future<void> start() async {
    try {
      final support = await getApplicationSupportDirectory();
      final file = File(p.join(support.path, 'window.log'));
      await file.writeAsString(
        'xverb window log\n'
        '${Platform.operatingSystemVersion}\n\n',
      );
      _file = file;
      for (final line in _pending) {
        await file.writeAsString(line, mode: FileMode.append);
      }
      _pending.clear();
    } on Object {
      // Diagnostics must never be the reason something fails.
    }
  }

  static void write(String message) {
    final line = '${_since.elapsedMilliseconds.toString().padLeft(6)}ms  '
        '$message\n';
    final file = _file;
    if (file == null) {
      _pending.add(line);
      return;
    }
    try {
      file.writeAsStringSync(line, mode: FileMode.append);
    } on Object {
      // Ignore: a locked or full disk is not worth a crash.
    }
  }

  static Future<String?> path() async {
    try {
      return p.join(
        (await getApplicationSupportDirectory()).path,
        'window.log',
      );
    } on Object {
      return null;
    }
  }
}
