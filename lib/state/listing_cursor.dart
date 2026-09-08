import 'package:flutter/foundation.dart';

/// Where the keyboard is in a table, kept outside the widget that draws it.
///
/// The cursor has to outlive the drawing. A plugin answers a keypress with a
/// fresh page of content and the widget is rebuilt from nothing; a cursor
/// living in that widget's state would go back to the top every time the view
/// redrew itself, which is the one thing a keyboard-driven listing may never
/// do. It also has to be reachable from outside: the keys arrive at the
/// commander screen or at the full-screen page, neither of which can see
/// inside a widget.
class ListingCursor extends ChangeNotifier {
  int _index = 0;
  int _count = 0;

  /// The rows picked out, by index into the page as it was last drawn.
  ///
  /// The panel's own idiom, in a plugin's listing: Insert picks a row out and
  /// steps down, and what is picked out is what the next thing done applies
  /// to. Held beside the cursor rather than in the drawing for the same reason
  /// the cursor is — the content is replaced wholesale whenever the plugin
  /// answers, and marks that lived in the widget would be lost on every
  /// keystroke.
  final Set<int> _marked = {};

  /// The row the keyboard is on. Never negative once there are rows.
  int get index => _index;

  /// How many rows the table last drew. What Page Down and End are measured
  /// against, and the reason those keys can be answered without the widget.
  int get count => _count;

  /// How many rows fit on screen, told by whoever draws them — the same
  /// arrangement `PanelController.visibleRows` has, and for the same reason:
  /// a key handler has no idea how tall the window is.
  int visibleRows = 12;

  /// A page of the table, or one row if it is somehow shorter than that.
  int get pageStep => visibleRows > 1 ? visibleRows - 1 : 1;

  /// Which rows are marked, in the order the table draws them.
  List<int> get marked => _marked.toList()..sort();

  bool isMarked(int index) => _marked.contains(index);

  bool get hasMarks => _marked.isNotEmpty;

  /// Marks a row or unmarks it. Insert does this and steps down, which is how
  /// a run of files is picked out with one finger.
  void toggleMark(int index) {
    if (index < 0 || index >= _count) return;
    if (!_marked.remove(index)) _marked.add(index);
    notifyListeners();
  }

  void markRange(int from, int to) {
    if (_count == 0) return;
    final first = (from < to ? from : to).clamp(0, _count - 1);
    final last = (from < to ? to : from).clamp(0, _count - 1);
    for (var at = first; at <= last; at++) {
      _marked.add(at);
    }
    notifyListeners();
  }

  /// Forgets every mark. What acting on them does afterwards, and what a page
  /// that is no longer the page they were made on does.
  void clearMarks() {
    if (_marked.isEmpty) return;
    _marked.clear();
    notifyListeners();
  }

  void moveTo(int index) {
    final next = _count == 0 ? 0 : index.clamp(0, _count - 1);
    if (next == _index) return;
    _index = next;
    notifyListeners();
  }

  void move(int by) => moveTo(_index + by);

  /// New content arrived. The cursor stays where it was if the new page is
  /// long enough to hold it, because a table that is re-read — F5, a push from
  /// the plugin — is the same table and the eye is still where it was.
  void resize(int count) {
    var next = count == 0 ? 0 : _index.clamp(0, count - 1);

    // A row was asked for before there were any. See [wantRow]: this is where
    // it lands, because this is the first moment it can be true.
    final wanted = _wanted;
    if (wanted != null && wanted < count) {
      next = wanted;
      _wanted = null;
    }

    // A page that got shorter cannot keep a mark on a row that is not there.
    // The rest stay: this is the same table re-read, and what was picked out
    // is still picked out.
    final dropped = _marked.where((at) => at >= count).toList();
    _marked.removeAll(dropped);
    if (count == _count && next == _index && dropped.isEmpty) return;
    _count = count;
    _index = next;
    notifyListeners();
  }

  /// A row asked for before the table has been drawn.
  int? _wanted;

  /// Put the cursor here, now or as soon as there is a row to put it on.
  ///
  /// **Content arrives before it is measured.** A view answers with a table
  /// and the count is still whatever the last one was — nothing at all, for a
  /// tool that has just opened — so asking for row 40 would clamp to 0 and the
  /// request would be gone by the time the rows existed. Held instead, and
  /// spent at the next [resize] that can honour it.
  ///
  /// What this is for: coming back to where you were. A tool that sent the
  /// panel into a commit and is being opened again says which commit, and the
  /// reader lands on the row they left from rather than at the top of the log.
  void wantRow(int index) {
    if (index < 0) return;
    if (index < _count) {
      _wanted = null;
      moveTo(index);
      return;
    }
    _wanted = index;
  }

  /// A different page altogether: the view walked into something, so the
  /// cursor starts at the top of what it walked into.
  ///
  /// Silent when it was already there. A cursor that announced a move it did
  /// not make would have anything listening for one — a view being told where
  /// the cursor came to rest — answering the same question over and over.
  void rewind() {
    final had = _marked.isNotEmpty;
    _marked.clear();
    if (_index == 0) {
      if (had) notifyListeners();
      return;
    }
    _index = 0;
    notifyListeners();
  }
}
