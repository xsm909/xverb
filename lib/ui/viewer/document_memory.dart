import 'package:flutter/foundation.dart';

import '../../core/reading/reading_store.dart';

/// What a reading remembers about the document on screen: where it was left
/// and what was marked in it — one document's share of the [ReadingStore].
///
/// A door rather than the store itself, so that the Markdown reader asks only
/// for what it draws and knows nothing of files, keys or where it is written.
class DocumentMemory extends ChangeNotifier {
  DocumentMemory(this._store, this._document) {
    _store.addListener(notifyListeners);
  }

  final ReadingStore _store;
  final ReadingDocument _document;

  /// The last marker colour used, so a second passage is marked the way the
  /// first was — which is what somebody going through a book with one colour
  /// expects.
  static int lastColour = 0;

  ReadingAnchor? get place => _document.place;

  set place(ReadingAnchor? value) {
    if (value != null) _store.setPlace(_document, value);
  }

  List<Highlight> get highlights => List.unmodifiable(_document.highlights);

  void add(Highlight highlight) {
    lastColour = highlight.colour;
    _store.addHighlight(_document, highlight);
  }

  void replace(Highlight highlight) {
    lastColour = highlight.colour;
    _store.replaceHighlight(_document, highlight);
  }

  void remove(String id) => _store.removeHighlight(_document, id);

  @override
  void dispose() {
    _store.removeListener(notifyListeners);
    super.dispose();
  }
}
