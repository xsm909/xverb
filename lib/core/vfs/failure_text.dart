import 'dart:io';

import '../i18n/i18n.dart';

/// What went wrong, in the application's own words.
///
/// **A Dart exception name is not a sentence.** With a file open and something
/// else moving it out from under the viewer, the page said
/// `PathNotFoundException: Cannot open file, path = '…' (OS Error: No such file
/// or directory, errno = 2)`. Every word of that is true and none of it is for
/// the reader, who wants to know that the file is gone — and the path, which
/// is in the title bar anyway.
///
/// So the handful of failures that actually happen to files get a sentence each,
/// and everything else falls back to what the exception said. **The fallback is
/// deliberate**: a wrong-but-friendly message for a failure nobody anticipated
/// is worse than a technical one, because it sends the reader looking in the
/// wrong place.
String saidPlainly(Object failure) {
  if (failure is PathNotFoundException) {
    return tr('The file is no longer there.');
  }
  if (failure is PathAccessException) {
    return tr('This file cannot be read: the system refused permission.');
  }
  if (failure is FileSystemException) {
    // The one that is worth telling apart from the rest: a directory handed to
    // something that reads files says "is a directory", which is a mistake with
    // an obvious next move rather than a fault.
    final os = failure.osError;
    if (os != null && os.errorCode == 21) {
      return tr('That is a folder, not a file.');
    }
    // `message` is the application-level half — "Cannot open file" — without
    // the class name and the path glued to it.
    final message = failure.message.trim();
    return message.isEmpty ? failure.toString() : '$message.';
  }
  return failure.toString();
}
