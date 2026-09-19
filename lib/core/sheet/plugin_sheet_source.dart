import 'dart:async';
import 'dart:collection';

import 'cell_range.dart';
import 'sheet_source.dart';

/// Asks the plugin behind a sheet for something: `sheet.rows`, `sheet.open`.
typedef SheetCall =
    Future<Object?> Function(String method, Map<String, Object?> params);

/// A sheet a plugin reads — a workbook's page, say — handed over a piece at
/// a time over the plugin's own pipe.
///
/// **The same paging as a CSV, with the file on the other side of a pipe.**
/// The plugin says how big the sheet is and sends the first rows with the
/// content; the rest it sends when asked, `sheet.rows` from a row for so
/// many. A workbook of five sheets is five of these in turn: [selectSheet]
/// asks for another and everything here starts again.
///
/// The plugin's rows are the file's rows, a header row included. Whether the
/// first one *is* a header is guessed here, the way it is for a CSV, unless
/// the plugin knows and says — the reader overrules either with one press.
class PluginSheetSource extends SheetSource {
  PluginSheetSource(Map<String, dynamic> json, this._call)
    : _handle = '${json['handle'] ?? ''}',
      _titles = [for (final t in (json['sheets'] as List? ?? const [])) '$t'],
      _menu = [
        for (final item in (json['menu'] as List? ?? const []))
          if (item is Map)
            SheetMenuItem(
              '${item['id'] ?? ''}',
              '${item['label'] ?? ''}',
              enabled: item['enabled'] != false,
            ),
      ],
      _wantsSelection = json['selection'] == true,
      _wantsActivate = json['activate'] == true {
    _take(json);
  }

  final List<SheetMenuItem> _menu;
  final bool _wantsSelection;
  final bool _wantsActivate;

  // What the file says about the sheet besides its cells, in the file's own
  // rows — turned into the source's rows, which leave out a header row,
  // when asked for.
  List<List<int>> _mergesInFile = const [];
  Map<(int, int), String> _notesInFile = const {};
  Set<int> _hiddenRowsInFile = const {};
  Set<int> _hiddenColumns = const {};

  @override
  List<CellRange> get merges => [
    for (final m in _mergesInFile)
      if (m[2] - _offset >= 0)
        CellRange(
          top: (m[0] - _offset).clamp(0, 1 << 30),
          left: m[1],
          bottom: m[2] - _offset,
          right: m[3],
        ),
  ];

  @override
  Map<(int, int), String> get notes => {
    for (final e in _notesInFile.entries)
      if (e.key.$1 - _offset >= 0) (e.key.$1 - _offset, e.key.$2): e.value,
  };

  @override
  Set<int> get hiddenRows => {
    for (final r in _hiddenRowsInFile)
      if (r - _offset >= 0) r - _offset,
  };

  @override
  Set<int> get hiddenColumns => _hiddenColumns;

  /// Takes whatever of the sheet's extras [json] carries; a field left out
  /// leaves what was known.
  void _extras(Map<Object?, Object?> json) {
    final merges = json['merges'];
    if (merges is List) {
      _mergesInFile = [
        for (final m in merges)
          if (m is List && m.length == 4)
            [for (final v in m) (v as num).toInt()],
      ];
    }
    final notes = json['notes'];
    if (notes is List) {
      _notesInFile = {
        for (final n in notes)
          if (n is List && n.length == 3)
            ((n[0] as num).toInt(), (n[1] as num).toInt()): '${n[2]}',
      };
    }
    final rows = json['hiddenRows'];
    if (rows is List) {
      _hiddenRowsInFile = {for (final r in rows) (r as num).toInt()};
    }
    final columns = json['hiddenColumns'];
    if (columns is List) {
      _hiddenColumns = {for (final c in columns) (c as num).toInt()};
    }
  }

  @override
  List<SheetMenuItem> get menuItems => _menu;

  @override
  bool get wantsSelection => _wantsSelection;

  @override
  bool get wantsActivate => _wantsActivate;

  @override
  Future<SheetAction?> press(String id, Map<String, Object?> selection) =>
      _ask('sheet.press', {'id': id, 'selection': selection});

  @override
  void selected(Map<String, Object?> selection) {
    if (!_wantsSelection) return;
    unawaited(_ask('sheet.select', {'selection': selection}));
  }

  @override
  Future<SheetAction?> activate(int row, int column) =>
      _ask('sheet.activate', {'row': row, 'column': column});

  /// Asks the plugin about something the reader did. A failure is said, in
  /// the plugin's own words, rather than thrown at a menu that has closed.
  Future<SheetAction?> _ask(String method, Map<String, Object?> params) async {
    final call = _call;
    if (call == null || _disposed) return null;
    try {
      final answer = await call(method, {
        'handle': _handle,
        'sheet': _sheet,
        ...params,
      });
      return answer == null ? null : SheetAction.fromJson(answer);
    } on Object catch (e) {
      return SheetAction(notice: '$e');
    }
  }

  final String _handle;
  final SheetCall? _call;
  final List<String> _titles;

  /// Rows asked for and kept together.
  static const int chunkRows = 256;

  /// Pieces kept for scrolling back before the oldest is let go.
  static const int keptChunks = 48;

  int _sheet = 0;
  int _records = 0;
  int _columns = 0;
  bool _hasHeader = false;
  bool? _saidHeader;
  List<SheetColumnKind>? _saidKinds;
  List<SheetColumnKind> _kinds = const [];
  List<String>? _names;
  String? _error;
  bool _opening = false;
  bool _disposed = false;

  /// The plugin is still reading this sheet: the rows here are the ones it
  /// has so far, and more are coming.
  bool _reading = false;
  Timer? _poll;

  /// How often a sheet still being read is asked how far it has got.
  static const Duration pollEvery = Duration(milliseconds: 400);

  final LinkedHashMap<int, List<List<Object?>>> _chunks = LinkedHashMap();
  final Map<int, Future<void>> _loading = {};

  /// Bumped whenever a different sheet is taken, so an answer about the last
  /// one that arrives late is recognised and dropped.
  int _generation = 0;

  @override
  List<String> get sheetTitles => _titles;

  @override
  int get sheetIndex => _sheet;

  @override
  int get rowCount => _records > _offset ? _records - _offset : 0;

  @override
  int get columnCount => _columns;

  /// Still being read by the plugin, or another sheet being opened.
  @override
  bool get counting => _opening || _reading;

  @override
  String? get error => _error;

  @override
  bool get hasHeader => _hasHeader;

  @override
  List<String>? get columnNames => _hasHeader ? _names : null;

  @override
  List<SheetColumnKind> get columnKinds => _kinds;

  int get _offset => _hasHeader ? 1 : 0;

  @override
  void setHasHeader(bool value) {
    if (value == _hasHeader) return;
    _hasHeader = value;
    _rekind();
    notifyListeners();
  }

  @override
  Future<void> selectSheet(int index) async {
    if (index < 0 || index >= _titles.length || index == _sheet) return;
    final call = _call;
    if (call == null) return;
    _generation++;
    final generation = _generation;
    _opening = true;
    _sheet = index;
    _chunks.clear();
    _loading.clear();
    _records = 0;
    _columns = 0;
    _error = null;
    _reading = false;
    _poll?.cancel();
    notifyListeners();
    try {
      final answer = await call('sheet.open', {
        'handle': _handle,
        'sheet': index,
      });
      if (_disposed || generation != _generation) return;
      if (answer is! Map) throw const FormatException('no sheet came back');
      _take(Map<String, dynamic>.from(answer));
    } on Object catch (e) {
      if (_disposed || generation != _generation) return;
      _error = '$e';
    }
    _opening = false;
    notifyListeners();
  }

  @override
  List<Object?>? rowAt(int row) {
    if (row < 0) return null;
    final record = row + _offset;
    if (record >= _records) return null;
    final chunk = record ~/ chunkRows;
    final rows = _chunks.remove(chunk);
    if (rows == null) {
      unawaited(_load(chunk));
      return null;
    }
    _chunks[chunk] = rows;
    final at = record - chunk * chunkRows;
    if (at >= rows.length) {
      // Kept when the sheet was shorter than it is now: read it again.
      _chunks.remove(chunk);
      unawaited(_load(chunk));
      return null;
    }
    return rows[at];
  }

  @override
  Future<void> ensure(int from, int count) async {
    if (count <= 0) return;
    final first = (from + _offset) ~/ chunkRows;
    final last = (from + _offset + count - 1) ~/ chunkRows;
    await Future.wait([for (var c = first; c <= last; c++) _load(c)]);
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }

  /// What every answer says about how far the plugin has got: the rows it
  /// has, whether it is still reading, how wide the sheet has grown.
  void _progress(Map<Object?, Object?> answer) {
    _extras(answer);
    final rows = (answer['rows'] as num?)?.toInt();
    if (rows != null && rows > _records) _records = rows;
    final columns = (answer['columns'] as num?)?.toInt();
    if (columns != null && columns > _columns) _columns = columns;
    final reading = answer['counting'] == true;
    if (reading != _reading) {
      _reading = reading;
      if (!reading) {
        // The last piece may have been kept short while it was still
        // growing; ask for it again whole.
        _chunks.remove(_records ~/ chunkRows);
      }
    }
    _schedulePoll();
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (!_reading || _disposed || _call == null) return;
    final generation = _generation;
    _poll = Timer(pollEvery, () async {
      if (_disposed || generation != _generation) return;
      try {
        final answer = await _call('sheet.rows', {
          'handle': _handle,
          'sheet': _sheet,
          'from': _records,
          'count': 0,
        });
        if (_disposed || generation != _generation || answer is! Map) return;
        _progress(answer);
        notifyListeners();
      } on Object catch (e) {
        if (_disposed || generation != _generation) return;
        _reading = false;
        _error = '$e';
        notifyListeners();
      }
    });
  }

  /// What the plugin said about a sheet: its size, perhaps its header and its
  /// kinds, and the first rows of it.
  void _take(Map<String, dynamic> json) {
    _sheet = (json['sheet'] as num?)?.toInt() ?? _sheet;
    _records = (json['rows'] as num?)?.toInt() ?? 0;
    _columns = (json['columns'] as num?)?.toInt() ?? 0;
    final message = json['message'];
    if (message is String && message.isNotEmpty) _error = message;
    _saidHeader = json['header'] is bool ? json['header'] as bool : null;
    final kinds = json['kinds'];
    _saidKinds = kinds is List
        ? [
            for (final k in kinds)
              switch ('$k') {
                'number' => SheetColumnKind.number,
                'boolean' => SheetColumnKind.boolean,
                _ => SheetColumnKind.text,
              },
          ]
        : null;

    _mergesInFile = const [];
    _notesInFile = const {};
    _hiddenRowsInFile = const {};
    _hiddenColumns = const {};
    _extras(json);
    final from = (json['from'] as num?)?.toInt() ?? 0;
    final first = _cells(json['cells']);
    _chunks.clear();
    _reading = json['counting'] == true;
    _store(from, first);
    _schedulePoll();

    final sample = [
      for (final row in first.take(200)) [for (final v in row) sheetText(v)],
    ];
    _hasHeader = _saidHeader ?? guessHeader(sample);
    _sample = first.take(500).toList();
    _rekind();
  }

  List<List<Object?>> _sample = const [];

  void _rekind() {
    final sample = _sample;
    final width = sample.fold<int>(0, (w, r) => r.length > w ? r.length : w);
    if (width > _columns) _columns = width;
    _names = sample.isEmpty
        ? null
        : [
            for (var c = 0; c < _columns; c++)
              c < sample.first.length ? sheetText(sample.first[c]) : '',
          ];
    _kinds =
        _saidKinds ?? guessColumnKinds(sample.skip(_offset).toList(), _columns);
  }

  /// Rows starting at record [from], cut into the pieces they are kept in.
  void _store(int from, List<List<Object?>> rows) {
    var at = 0;
    while (at < rows.length) {
      final record = from + at;
      final chunk = record ~/ chunkRows;
      final start = record - chunk * chunkRows;
      // Only whole pieces are kept: a piece that starts part-way is asked
      // for again in full when it is wanted.
      if (start != 0) {
        at += chunkRows - start;
        continue;
      }
      final end = at + chunkRows > rows.length ? rows.length : at + chunkRows;
      // A short piece is the end of the sheet only once the plugin has
      // finished reading it; before then it is where the reading had got to.
      if (end - at == chunkRows || (!_reading && from + end >= _records)) {
        _chunks[chunk] = rows.sublist(at, end);
      }
      at = end;
    }
    while (_chunks.length > keptChunks) {
      _chunks.remove(_chunks.keys.first);
    }
  }

  Future<void> _load(int chunk) {
    if (_chunks.containsKey(chunk)) return Future.value();
    return _loading[chunk] ??= _fetch(chunk).whenComplete(() {
      _loading.remove(chunk);
    });
  }

  Future<void> _fetch(int chunk) async {
    final call = _call;
    if (call == null || _error != null) return;
    final generation = _generation;
    final from = chunk * chunkRows;
    if (from >= _records) return;
    try {
      final answer = await call('sheet.rows', {
        'handle': _handle,
        'sheet': _sheet,
        'from': from,
        'count': chunkRows,
      });
      if (_disposed || generation != _generation) return;
      if (answer is! Map) return;
      _progress(answer);
      _store(
        (answer['from'] as num?)?.toInt() ?? from,
        _cells(answer['cells']),
      );
    } on Object catch (e) {
      if (_disposed || generation != _generation) return;
      _error = '$e';
    }
    notifyListeners();
  }

  /// Rows as they came over the pipe: a cell is a plain value, or an object
  /// with the value, the text to show and a role.
  static List<List<Object?>> _cells(Object? json) {
    if (json is! List) return const [];
    return [
      for (final row in json)
        if (row is List)
          [
            for (final cell in row)
              if (cell is Map)
                SheetCell(
                  cell['v'],
                  text: cell['t'] as String?,
                  role: cell['r'] as String?,
                )
              else
                cell,
          ]
        else
          const <Object?>[],
    ];
  }
}
