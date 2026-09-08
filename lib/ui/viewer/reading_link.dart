import 'package:flutter/foundation.dart';

/// The line between a reading and whatever is standing beside it.
///
/// Two questions and nothing else: **where is the reader**, which the reading
/// answers as it scrolls, and **take them there**, which the reading obeys.
/// The structure panel asks both and knows nothing else about how a document
/// is drawn — which is what lets the same panel stand over a page of code and
/// over a rendered markdown document, two widgets that have nothing in common
/// but this.
///
/// A [ChangeNotifier] rather than a callback in each direction, so the panel
/// can follow the reading without the page rebuilding the reading every time
/// somebody scrolls it.
class ReadingLink extends ChangeNotifier {
  /// The line of the file at the top of what is on screen, from zero.
  int get top => _top;
  int _top = 0;

  /// Set by the reading, and only when it has moved: the panel highlights the
  /// node this falls inside, and a notification a frame is a rebuild a frame.
  void report(int line) {
    if (line == _top) return;
    _top = line;
    notifyListeners();
  }

  /// Registered by the reading. Null while nothing is drawn — a jump asked for
  /// then is a jump into a document that is not there, and is dropped.
  void Function(int line)? reveal;

  /// Take the reader to [line]. Silently does nothing if nothing is listening,
  /// which is the honest answer while a file is still being read.
  void goTo(int line) => reveal?.call(line);

  @override
  void dispose() {
    reveal = null;
    super.dispose();
  }
}
