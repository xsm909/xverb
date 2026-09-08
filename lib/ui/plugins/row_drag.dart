/// Rows on their way from one part of a page to another.
///
/// The whole payload of a drag inside a view: which list they were picked up
/// from, and which rows they were. Nothing about what they *are* — the plugin
/// knows that, and a host that started carrying file names around would be a
/// host with an opinion about what a listing lists.
class RowDrag {
  const RowDrag({required this.part, required this.rows});

  /// The part the rows were picked up from. A drop back into the same one is
  /// refused: it is not a move, and something has to say so before the plugin
  /// is asked to make sense of it.
  final String part;

  /// Which rows, by index into the page as it was drawn. The marked ones, or
  /// the one under the pointer when none are — the same rule every press in a
  /// listing follows.
  final List<int> rows;

  bool get isEmpty => rows.isEmpty;
}
