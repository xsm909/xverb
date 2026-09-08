import 'dart:convert';
import 'dart:typed_data';

import '../i18n/plugin_strings.dart';
import '../vfs/file_entry.dart';
import '../vfs/vfs_path.dart';
import 'facts.dart';
import 'graph.dart';
import 'plugin_manifest.dart';

/// The shapes a viewer plugin can return.
///
/// Plugins run in Python and cannot draw Flutter widgets, so a viewer produces
/// *content* and the host renders it. Keeping the set of shapes small is what
/// makes that trade work: a plugin decides how to interpret a file, the app
/// decides how it looks.
enum ViewerContentKind {
  text,
  markdown,
  image,
  table,
  chart,
  mesh3d,

  /// Fields to fill in and buttons to press. See [ContentField] — this is the
  /// only content a plugin can be *told* something through, and it exists
  /// because a commit message is typed text and `ask` is yes or no.
  form,

  /// A graph of boxes and the wires between them — a ComfyUI workflow, an n8n
  /// flow, a Node-RED tab. See [GraphDocument].
  nodes,

  /// A drawing made of shapes rather than of pixels. See [VectorDrawing].
  vector,

  /// A sound: played by the machine's own engine, drawn as its own waveform.
  ///
  /// The plugin names the file in [ViewerContent.url] and says whatever it
  /// knows about it in [ViewerContent.rows]; it does not decode anything and it
  /// cannot — playing is a thing the machine does, exactly as decoding a
  /// picture is. See `AudioChannel`.
  audio,

  /// Several of the above at once, with a divider between them. See
  /// [ContentPart].
  split,

  /// A file, drawn by whichever viewer claims it. See [ViewerContent.url].
  file,
  error,
}

/// One mesh of a [ViewerContentKind.mesh3d]: triangles, and how they face.
///
/// The numbers arrive packed rather than as JSON arrays. A mesh of twenty
/// thousand triangles is a quarter of a million numbers, and as decimal digits
/// that is megabytes of text to parse before anything can be drawn; as float32
/// it is a memory copy.
///
/// Positions are in world space and Y-up, whatever the file said — a plugin
/// that draws nothing still knows which way its format calls up, and the host
/// has no business learning that.
class MeshGeometry {
  const MeshGeometry({
    required this.name,
    required this.positions,
    required this.normals,
    required this.indices,
    this.uvs,
    this.bones,
    this.boneParents,
    this.image = -1,
    this.color,
    this.joints = 0,
    this.jointIndices,
    this.jointWeights,
  });

  factory MeshGeometry.fromJson(Map<String, dynamic> json) => MeshGeometry(
        name: json['name']?.toString() ?? '',
        positions: _floats(json['positions']),
        normals: _floats(json['normals']),
        indices: _indices(json['indices']),
        uvs: _floats(json['uvs']),
        bones: _floats(json['bones']),
        boneParents: _signedShorts(json['boneParents']),
        image: (json['image'] as num?)?.toInt() ?? -1,
        color: ChartSegment._parseColor(json['color']),
        joints: (json['joints'] as num?)?.toInt() ?? 0,
        jointIndices: _shorts(json['jointIndices']),
        jointWeights: _floats(json['jointWeights']),
      );

  final String name;

  /// Three floats per vertex.
  final Float32List positions;

  /// Three floats per vertex, matching [positions] one for one.
  final Float32List normals;

  /// Three indices per triangle.
  final Uint32List indices;

  /// Two floats per vertex — where in [image] this vertex reads from, 0..1
  /// across and down. Empty when the mesh has no picture on it.
  ///
  /// Down, not up: the plugin turns them over, because every format writes
  /// them running up from the bottom and every image is drawn from the top.
  final Float32List? uvs;

  /// Three floats per bone: where it rests, in the same space as
  /// [positions] — so posing it is the same arithmetic as posing a vertex.
  ///
  /// The baked matrices cannot say where a bone *is*: they carry its change
  /// since the bind pose. This is what a skeleton is drawn from.
  final Float32List? bones;

  /// One index per bone: which bone it hangs from, or −1 for a root.
  final Int16List? boneParents;

  /// Which of [ViewerContent.images] paints this mesh, or −1 for none.
  ///
  /// An index rather than the bytes, because one picture usually paints
  /// several meshes and a plugin splits a mesh per material.
  final int image;

  /// What the material said, as `0xAARRGGBB`, if it said anything. Null takes
  /// the theme's. An `int` rather than a `Color` for the same reason a chart's
  /// is: nothing in `core` imports Flutter.
  final int? color;

  /// How many bones may pull on this mesh.
  final int joints;

  /// Four per vertex, into this mesh's own joints. Null when nothing skins it.
  final Uint16List? jointIndices;

  /// Four per vertex, summing to one where anything pulls at all.
  final Float32List? jointWeights;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;

  /// Whether this mesh has both a picture and somewhere on it to read from.
  bool get isPainted => image >= 0 && (uvs?.length ?? 0) >= vertexCount * 2;

  bool get isSkinned =>
      joints > 0 &&
      (jointIndices?.length ?? 0) >= vertexCount * 4 &&
      (jointWeights?.length ?? 0) >= vertexCount * 4;

  static Float32List _floats(Object? value) {
    if (value is! String || value.isEmpty) return Float32List(0);
    final bytes = base64Decode(value);
    return bytes.buffer.asFloat32List(0, bytes.lengthInBytes ~/ 4);
  }

  /// How many bones this mesh's skeleton has, if it came with one.
  int get boneCount => (boneParents?.length ?? 0);

  static Int16List? _signedShorts(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final bytes = base64Decode(value);
    return bytes.buffer.asInt16List(0, bytes.lengthInBytes ~/ 2);
  }

  static Uint16List? _shorts(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final bytes = base64Decode(value);
    return bytes.buffer.asUint16List(0, bytes.lengthInBytes ~/ 2);
  }

  static Uint32List _indices(Object? value) {
    if (value is! String || value.isEmpty) return Uint32List(0);
    final bytes = base64Decode(value);
    return bytes.buffer.asUint32List(0, bytes.lengthInBytes ~/ 4);
  }
}

/// One clip of a [ViewerContentKind.mesh3d]: where every bone is, per frame.
///
/// Baked rather than described. Curves, rotation orders and pivots are the
/// plugin's problem and stay there; what crosses is a matrix per joint per
/// frame, ready to be blended. Playback is the host's, because thirty frames a
/// second down a pipe is not playback.
class MeshClip {
  const MeshClip({
    required this.name,
    required this.frames,
    required this.fps,
    required this.seconds,
    required this.tracks,
  });

  factory MeshClip.fromJson(Map<String, dynamic> json) => MeshClip(
        name: json['name']?.toString() ?? '',
        frames: (json['frames'] as num?)?.toInt() ?? 0,
        fps: (json['fps'] as num?)?.toDouble() ?? 30,
        seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
        tracks: [
          for (final track in (json['tracks'] as List?) ?? const [])
            MeshGeometry._floats(track),
        ],
      );

  final String name;
  final int frames;
  final double fps;
  final double seconds;

  /// One entry per mesh, in the order the meshes came: frames x joints x 16
  /// floats, or empty for a mesh this clip does not move.
  final List<Float32List> tracks;

  bool get isEmpty => frames <= 0 || tracks.every((t) => t.isEmpty);
}

/// Which edge of its column a cell is drawn against.
enum ListingAlign {
  start,
  end,
  centre;

  static ListingAlign parse(Object? name) {
    for (final align in ListingAlign.values) {
      if (align.name == name) return align;
    }
    // Both spellings, because a plugin author types the one their language
    // uses and being told "centre, not center" is not a thing a contract
    // should spend a round trip on.
    if (name == 'center') return ListingAlign.centre;
    if (name == 'right') return ListingAlign.end;
    if (name == 'left') return ListingAlign.start;
    return ListingAlign.start;
  }
}

/// What a column holds, which is how the host knows how to draw it.
///
/// Not a style: a plugin says *what the thing is* and the host decides what
/// that looks like, the same bargain every other part of this contract makes.
enum ListingCellKind {
  /// Words, in the listing's own font.
  text,

  /// Fixed-pitch — a hash, a size, anything read column by column.
  mono,

  /// Pills: branch names, tags, whatever labels the row rather than fills it.
  chips,

  /// A single glyph from the host's set, centred.
  icon,

  /// Somebody: a ring with their initials in it, and their name beside it.
  ///
  /// The cell's text is the person's *name* — the host takes the initials from
  /// it. **Nothing here goes and fetches a face**: a picture of somebody lives
  /// on a server, and a log that opened a connection because it drew a row
  /// would be a log that hangs on a repository you walked past.
  avatar,

  /// The braid down the side of a history. See [ListingGraph].
  graph,

  /// A path, written short when it does not fit: the first folder, an
  /// ellipsis, and the file's own name.
  ///
  /// Item 68: the rule is `<first folder if there is one>...<file name>`, with
  /// the whole of it in a hint under the pointer. Cutting a
  /// path at the end — which is what an ellipsis does on its own — throws away
  /// the file's name, which is the half anybody is looking for; cutting it in
  /// the middle keeps both ends of what identifies it.
  path;

  static ListingCellKind parse(Object? name) {
    for (final kind in ListingCellKind.values) {
      if (kind.name == name) return kind;
    }
    return ListingCellKind.text;
  }
}

/// What a row *is*, said in the application's own vocabulary rather than in
/// colours.
///
/// A plugin knows a commit has not been pushed; it does not know what colour
/// this palette gives to "worth noticing", and it must not — see the rule the
/// appearance settings are built on. So a row names its part and the host
/// paints it.
enum ListingRowRole {
  normal,

  /// Heavier. The row the eye should land on first: the working tree at the
  /// head of a log, a total at the foot of a list.
  strong,

  /// Quieter. There, but not the point — a heading over the rows under it.
  dim,

  /// Not written down yet. A row that is real but is not part of the record:
  /// a change that has not been committed, a draft, anything the list is
  /// showing before it becomes a fact.
  ///
  /// Drawn a fifth lighter rather than half — it is still to be read, and the
  /// fading says only that it is not settled. `dim` is for what may be
  /// skipped; this is for what has not happened yet.
  pending,

  /// In the accent colour. Something is different about this one.
  accent;

  static ListingRowRole parse(Object? name) {
    for (final role in ListingRowRole.values) {
      if (role.name == name) return role;
    }
    return ListingRowRole.normal;
  }
}

/// One column of a [ViewerContentKind.table].
///
/// **The plugin declares the shape, the host does the arithmetic.** A git log
/// is the case that proves the need: the graph must not stretch, the subject
/// must, and the date must not wrap. None of that can be said with a list of
/// header strings, which is all this contract used to carry.
class ListingColumn {
  const ListingColumn({
    required this.label,
    this.flex = 0,
    this.width,
    this.align = ListingAlign.start,
    this.kind = ListingCellKind.text,
  });

  /// A bare string is a column too — every plugin written before this existed
  /// sent a list of them, and they all still work.
  factory ListingColumn.fromJson(Object? value) {
    if (value is! Map) {
      return ListingColumn(label: value?.toString() ?? '', flex: 1);
    }
    final json = Map<String, dynamic>.from(value);
    final flex = (json['flex'] as num?)?.toInt() ?? 0;
    final width = (json['width'] as num?)?.toDouble();
    final kind = ListingCellKind.parse(json['kind']);
    return ListingColumn(
      label: json['label']?.toString() ?? '',
      // Neither given means "take what is going", which is what a column with
      // nothing said about it has always done — **unless** what it holds has a
      // width of its own. A glyph is one glyph wide and a braid is as wide as
      // its lanes, and stretching either is stretching a picture.
      flex: flex > 0 || width != null || _hasOwnWidth(kind) ? flex : 1,
      width: width,
      align: ListingAlign.parse(json['align']),
      kind: kind,
    );
  }

  /// Whether this kind knows how wide it wants to be without being told.
  static bool _hasOwnWidth(ListingCellKind kind) =>
      kind == ListingCellKind.icon || kind == ListingCellKind.graph;

  static List<ListingColumn> list(List<String> labels) =>
      [for (final label in labels) ListingColumn(label: label, flex: 1)];

  final String label;

  /// Share of whatever width is left once the fixed columns have had theirs.
  /// Zero is a fixed column, and then [width] is what it takes.
  final int flex;

  /// Its width when it does not stretch. Null lets the host pick one from
  /// [kind], which is right often enough that most columns need not say.
  final double? width;

  final ListingAlign align;
  final ListingCellKind kind;

  bool get isFlexible => flex > 0;
}

/// A pill inside a cell: a branch, a tag, the ref a commit is the tip of.
///
/// [kind] is what it *is*, not what colour to make it — `branch`, `remote`,
/// `tag`, `head`, or anything else, which is drawn plainly.
class ListingChip {
  const ListingChip({required this.text, this.kind = ''});

  factory ListingChip.fromJson(Object? value) {
    if (value is! Map) return ListingChip(text: value?.toString() ?? '');
    final json = Map<String, dynamic>.from(value);
    return ListingChip(
      text: json['text']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
    );
  }

  final String text;
  final String kind;
}

/// One cell. A plain string is the whole of it in the ordinary case.
class ListingCell {
  const ListingCell({
    this.text = '',
    this.chips = const [],
    this.icon,
    this.email,
  });

  factory ListingCell.fromJson(Object? value) {
    if (value is! Map) return ListingCell(text: value?.toString() ?? '');
    final json = Map<String, dynamic>.from(value);
    return ListingCell(
      text: json['text']?.toString() ?? '',
      chips: [
        for (final chip in (json['chips'] as List?) ?? const [])
          ListingChip.fromJson(chip),
      ],
      icon: json['icon'] as String?,
      email: json['email'] as String?,
    );
  }

  final String text;

  /// Drawn in front of [text], which may well be empty.
  final List<ListingChip> chips;

  /// A name from the host's icon set, or a file beside the plugin's manifest.
  final String? icon;

  /// The address of the person an `avatar` cell names.
  ///
  /// **Sending one is asking for their picture to be fetched**, and the host
  /// will go to Gravatar for it. So do not send one because you happen to have
  /// it: send it when your user has said they want pictures. Without it the
  /// ring carries their initials and nothing leaves the machine.
  final String? email;

  bool get isEmpty => text.isEmpty && chips.isEmpty && icon == null;
}

/// What the braid does at one row of a history.
///
/// **The lanes are the plugin's and the drawing is the host's**, and the line
/// between the two is where it has to be. Which lane a commit belongs in is a
/// question about the repository — what its parents are, which branch tips are
/// still open above it — and only the plugin can answer it. Where that lane
/// falls in pixels, how a line bends from one to the next, and what colour any
/// of it is are questions about a widget and a palette, which the plugin
/// cannot see and must not guess at.
///
/// A row describes what crosses it, in lanes:
///
/// - [closes] — lines arriving at the **top** edge that end at this commit.
///   Its own lane is one of them, unless this commit is a tip nothing points
///   at yet; the others are branches being merged in.
/// - [parents] — lanes at the **bottom** edge that this commit's parents
///   carry on down.
/// - [through] — everything else crossing the row, as `[top, bottom]`. The
///   two differ when a lane shifted along, and a shift is drawn as a bend
///   rather than as a break.
///
/// Nothing here is a line of drawing on its own. `git log --graph` prints rows
/// that are only the picture, and the log used to keep them as empty rows
/// because dropping them broke the lines; described this way there is nothing
/// to drop — a row is a commit, and the picture is the row's own.
class ListingGraph {
  const ListingGraph({
    this.lane = -1,
    this.closes = const [],
    this.parents = const [],
    this.through = const [],
    this.merge = false,
    this.tint = -1,
    this.entering = const [],
    this.leaving = const [],
  });

  factory ListingGraph.fromJson(Map<String, dynamic> json) => ListingGraph(
        lane: (json['lane'] as num?)?.toInt() ?? -1,
        closes: _lanes(json['closes']),
        parents: _lanes(json['parents']),
        through: [
          for (final edge in (json['through'] as List?) ?? const [])
            if (edge is List && edge.length >= 2)
              (
                (edge[0] as num?)?.toInt() ?? 0,
                (edge[1] as num?)?.toInt() ?? 0,
              ),
        ],
        merge: json['merge'] as bool? ?? false,
        tint: (json['tint'] as num?)?.toInt() ?? -1,
        entering: _lanes(json['entering']),
        leaving: _lanes(json['leaving']),
      );

  static List<int> _lanes(Object? value) => [
        for (final lane in (value as List?) ?? const [])
          if (lane is num) lane.toInt(),
      ];

  /// Where this commit's own mark sits. -1 draws the lines and no mark, which
  /// is what a row that is not a commit looks like.
  final int lane;

  final List<int> closes;
  final List<int> parents;

  /// `(top, bottom)` for every line that crosses without touching the mark.
  final List<(int, int)> through;

  /// True when more than one line ends here. Drawn differently, because a
  /// merge is the one commit in a log people go looking for.
  final bool merge;

  /// Which line this commit belongs to, if the plugin said. **Not a colour** —
  /// the host picks the colour; this only says which lines are the same line.
  /// Lanes are packed as branches end, so a line drifts sideways down a long
  /// history and a colour taken from the lane would change with nothing having
  /// happened.
  final int tint;

  /// The tint of each line at the top edge, by lane, and the same at the
  /// bottom. Short, or holding -1, wherever the plugin left it out: the lane
  /// stands in for the line then, which is what every table did before tints.
  final List<int> entering;
  final List<int> leaving;

  /// The colour key for a line arriving at [lane] from above.
  int tintAbove(int lane) => _tintIn(entering, lane);

  /// The colour key for a line leaving at [lane] below.
  int tintBelow(int lane) => _tintIn(leaving, lane);

  /// This commit's own, falling back to its lane.
  int get ownTint => tint >= 0 ? tint : lane;

  static int _tintIn(List<int> tints, int lane) {
    if (lane < 0 || lane >= tints.length) return lane;
    return tints[lane] >= 0 ? tints[lane] : lane;
  }

  /// How many lanes wide this row is, which is what the column has to fit.
  int get width {
    var widest = lane;
    for (final at in closes) {
      if (at > widest) widest = at;
    }
    for (final at in parents) {
      if (at > widest) widest = at;
    }
    for (final edge in through) {
      if (edge.$1 > widest) widest = edge.$1;
      if (edge.$2 > widest) widest = edge.$2;
    }
    return widest + 1;
  }

  bool get isEmpty =>
      lane < 0 && closes.isEmpty && parents.isEmpty && through.isEmpty;
}

/// One row: its cells, and what kind of row it is.
///
/// Either shape reads: a bare list of cells, which is what every table has
/// always sent, or `{"cells": [...], "role": "accent"}` when the row has
/// something to say about itself.
class ListingRow {
  const ListingRow({
    this.cells = const [],
    this.role = ListingRowRole.normal,
    this.graph,
  });

  factory ListingRow.of(List<String> cells) =>
      ListingRow(cells: [for (final cell in cells) ListingCell(text: cell)]);

  factory ListingRow.fromJson(Object? value) {
    if (value is List) {
      return ListingRow(cells: [for (final cell in value) ListingCell.fromJson(cell)]);
    }
    if (value is! Map) return const ListingRow();
    final json = Map<String, dynamic>.from(value);
    final graph = json['graph'];
    return ListingRow(
      cells: [
        for (final cell in (json['cells'] as List?) ?? const [])
          ListingCell.fromJson(cell),
      ],
      role: ListingRowRole.parse(json['role']),
      graph: graph is Map
          ? ListingGraph.fromJson(Map<String, dynamic>.from(graph))
          : null,
    );
  }

  final List<ListingCell> cells;
  final ListingRowRole role;

  /// What the braid does at this row, for a table with a `graph` column.
  ///
  /// On the row rather than in the cell because it is about the row's whole
  /// height — where a line enters at the top and leaves at the bottom. The
  /// column only says *where* to draw it.
  final ListingGraph? graph;

  /// The row as it used to be — the words in it, in order. What a command page
  /// copies to the clipboard, and what a test reads.
  List<String> get text => [for (final cell in cells) cell.text];

  ListingCell cellAt(int index) =>
      index >= 0 && index < cells.length ? cells[index] : const ListingCell();
}

/// Which way a [ViewerContentKind.split] is cut.
enum SplitDirection {
  /// One part above another. What a log with its detail underneath is.
  vertical,

  /// Side by side. What a list of files with a diff beside it is.
  horizontal;

  static SplitDirection parse(Object? name) {
    for (final direction in SplitDirection.values) {
      if (direction.name == name) return direction;
    }
    return SplitDirection.vertical;
  }
}

/// One part of a [ViewerContentKind.split].
///
/// **A part has a name, and that is the whole reason this works.** Everything a
/// view could be told before — a row was pressed, a row was marked — carried a
/// row number and nothing else, which is an answer to "which row" and no answer
/// at all to "which of the three lists". So every event from inside a split
/// carries the [id] of the part it came from, and a plugin that draws a log
/// above its files can tell a commit being opened from a file being opened
/// without keeping track of what it last drew.
class ContentPart {
  const ContentPart({
    required this.id,
    this.content,
    this.weight = 1,
    this.title,
    this.tabs = const [],
    this.tab,
  });

  factory ContentPart.fromJson(Map<String, dynamic> json) {
    final content = json['content'];
    return ContentPart(
      id: json['id']?.toString() ?? '',
      content: content is Map
          ? ViewerContent.fromJson(Map<String, dynamic>.from(content))
          : null,
      weight: (json['weight'] as num?)?.toDouble() ?? 1,
      title: json['title'] as String?,
      tabs: [
        for (final tab in (json['tabs'] as List?) ?? const [])
          if (tab is Map) ContentTab.fromJson(Map<String, dynamic>.from(tab)),
      ],
      tab: json['tab'] as String?,
    );
  }

  /// What this part is called, and what its events are stamped with.
  final String id;

  final ViewerContent? content;

  /// Its share of the room, before anybody drags the divider. Relative to the
  /// other parts, like a column's flex — a plugin has no idea how tall the
  /// window is and should not be made to guess.
  final double weight;

  /// A line above the part saying what it is. Null draws no strip at all,
  /// which is right when what the part holds says so for itself.
  final String? title;

  /// The ways of looking at this part, drawn in the strip the [title] uses.
  ///
  /// **The host draws the strip; the plugin owns what is behind it.** Pressing
  /// a tab raises the ordinary `button` event carrying its id, and the plugin
  /// answers with the part drawn a different way — which is the same round
  /// trip every other press makes. The host does not keep three contents in
  /// hand and swap between them: it cannot know what the other two would be,
  /// and pretending it does is how a tab comes to show a stale answer.
  final List<ContentTab> tabs;

  /// Which of [tabs] is the one being shown. Null takes the first.
  final String? tab;

  bool get isCurrent => tabs.isEmpty;
}

/// One tab of a [ContentPart].
class ContentTab {
  const ContentTab({required this.id, required this.label, this.detail});

  factory ContentTab.fromJson(Map<String, dynamic> json) => ContentTab(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        detail: json['detail'] as String?,
      );

  /// Raised as a `button` when the tab is pressed. The plugin's own name for
  /// it, so it needs no second vocabulary to answer in.
  final String id;

  final String label;

  /// A small count beside the label — how many files, how many changes. What
  /// a tab is worth looking at for before it is looked at.
  final String? detail;
}

/// One wedge of a [ViewerContentKind.chart].
///
/// Segments arrive as a flat list and form a tree through [parent], an index
/// into that same list — a shape that survives JSON without any nesting, and
/// one a plugin can append to as it discovers more. What each wedge is *worth*
/// is [value]; where it sits is worked out by the host, because the geometry
/// depends on the size of the widget and a plugin cannot know that.
class ChartSegment {
  const ChartSegment({
    required this.label,
    required this.value,
    this.parent = -1,
    this.url,
    this.color,
    this.marked = false,
    this.isDirectory = false,
    this.detail,
  });

  factory ChartSegment.fromJson(Map<String, dynamic> json) => ChartSegment(
        label: json['label']?.toString() ?? '',
        value: (json['value'] as num?)?.toDouble() ?? 0,
        parent: (json['parent'] as num?)?.toInt() ?? -1,
        url: json['url'] as String?,
        color: _parseColor(json['color']),
        marked: json['marked'] as bool? ?? false,
        isDirectory: json['folder'] as bool? ?? false,
        detail: json['detail'] as String?,
      );

  final String label;

  /// How much of its parent's arc this wedge takes. Any unit the plugin likes:
  /// only the ratios matter.
  final double value;

  /// Index of the wedge this one sits inside, or -1 for the innermost ring.
  final int parent;

  /// What the wedge stands for, if anything — a folder to navigate to, a file
  /// to mark. A wedge without one is drawn but is not pressable.
  final String? url;

  /// `#RRGGBB` or `#AARRGGBB`. Null lets the host colour it from the palette,
  /// which is the usual case and the one that keeps a plugin out of theming.
  final int? color;

  /// Struck through and dimmed: the user has put it on the list to go.
  final bool marked;

  final bool isDirectory;

  /// A second line for the tooltip and the centre — a formatted size, say.
  final String? detail;

  static int? _parseColor(Object? value) {
    if (value is num) return value.toInt();
    if (value is! String || !value.startsWith('#')) return null;
    final digits = value.substring(1);
    final parsed = int.tryParse(digits, radix: 16);
    if (parsed == null) return null;
    return digits.length <= 6 ? 0xFF000000 | parsed : parsed;
  }
}

/// A button a chart offers along its top edge.
///
/// The one thing a view could not ask for before: "do the thing I have been
/// building up to". Pressing one raises a `button` event carrying [id], and
/// what it means is entirely the plugin's business.
class ContentButton {
  const ContentButton({
    required this.id,
    required this.label,
    this.danger = false,
    this.primary = false,
    this.items = const [],
  });

  factory ContentButton.fromJson(Map<String, dynamic> json) => ContentButton(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        danger: json['danger'] as bool? ?? false,
        primary: json['primary'] as bool? ?? false,
        items: [
          for (final item in (json['items'] as List?) ?? const [])
            if (item is Map)
              ContentButton.fromJson(Map<String, dynamic>.from(item)),
        ],
      );

  final String id;
  final String label;

  /// Drawn in the warning colour. For the button that deletes things.
  final bool danger;

  /// The one Ctrl+Enter presses, and the one a form greys out while a field it
  /// cannot do without is empty. A page with two of these has none.
  final bool primary;

  /// The same thing, with more of it. A button carrying these is drawn with an
  /// arrow beside it: the button itself does the usual thing, and the arrow
  /// offers the others — commit, or commit and push. Each raises its own id,
  /// carrying what the fields held, exactly as the button does.
  final List<ContentButton> items;
}

/// One thing a [ViewerContentKind.form] asks for.
///
/// A plugin describes what it needs and the host draws it, exactly as with
/// everything else here: no plugin knows what a text field looks like in this
/// application, and none should have to.
class ContentField {
  const ContentField({
    required this.id,
    this.kind = ContentFieldKind.text,
    this.label = '',
    this.value = '',
    this.hint = '',
    this.lines = 1,
    this.checked = false,
    this.required = false,
  });

  factory ContentField.fromJson(Map<String, dynamic> json) => ContentField(
        id: json['id']?.toString() ?? '',
        kind: switch (json['kind']?.toString()) {
          'lines' => ContentFieldKind.lines,
          'check' => ContentFieldKind.check,
          _ => ContentFieldKind.text,
        },
        label: json['label']?.toString() ?? '',
        value: json['value']?.toString() ?? '',
        hint: json['hint']?.toString() ?? '',
        lines: (json['lines'] as num?)?.toInt() ?? 1,
        checked: json['checked'] as bool? ?? false,
        required: json['required'] as bool? ?? false,
      );

  final String id;
  final ContentFieldKind kind;

  /// What it is called, above it. A field with no label is its hint alone,
  /// which is what a message box wants.
  final String label;

  /// What it holds. **The user's own typing wins** while the declared value
  /// stays as it was: a view that redraws because a file was staged must not
  /// take back the sentence being written beside it.
  final String value;

  final String hint;

  /// How tall a `lines` field starts. It grows into whatever room the part
  /// gives it.
  final int lines;

  final bool checked;

  /// Whether the primary button waits for it. Answered by the host rather than
  /// by a round trip per keystroke.
  final bool required;
}

enum ContentFieldKind { text, lines, check }

/// A drawing, as the shapes it is made of.
///
/// **The point of the shape being this and not a picture:** a drawing made of
/// paths stays sharp however far into it you go, which is the only reason
/// anybody keeps a drawing as a drawing. Rasterising it in the plugin would
/// hand the host a picture, and a picture magnified is mush.
///
/// The plugin does all of the arcana — transforms composed and applied, styles
/// inherited and cascaded, arcs cut into curves, every kind of shape turned
/// into a path — so this end knows four verbs and no geometry at all. It is the
/// same division of labour [MeshGeometry] keeps: the plugin bakes, the host
/// draws.
class VectorDrawing {
  const VectorDrawing({
    required this.width,
    required this.height,
    required this.shapes,
  });

  factory VectorDrawing.fromJson(Map<String, dynamic> json) => VectorDrawing(
        width: (json['width'] as num?)?.toDouble() ?? 0,
        height: (json['height'] as num?)?.toDouble() ?? 0,
        shapes: [
          for (final shape in (json['shapes'] as List?) ?? const [])
            if (shape is Map)
              VectorShape.fromJson(Map<String, dynamic>.from(shape)),
        ],
      );

  /// The drawing's own coordinate space — its `viewBox`, with the corner moved
  /// to the origin by whoever read it.
  final double width;
  final double height;

  final List<VectorShape> shapes;

  bool get isEmpty => shapes.isEmpty || width <= 0 || height <= 0;
}

/// A gradient, in the drawing's own coordinates.
///
/// **Already resolved.** Whoever read the file has turned fractions of the
/// shape's own box into real coordinates, composed the gradient's transform
/// with the shape's, followed a reference to wherever the stops really live,
/// and sorted them. A gradient it could not express that way — a round one on
/// a stretched shape — never arrives: it comes as a flat colour instead, and
/// the drawing says so.
class VectorGradient {
  const VectorGradient({
    required this.radial,
    required this.from,
    required this.to,
    required this.radius,
    required this.offsets,
    required this.colours,
    this.spread = 'pad',
  });

  static VectorGradient? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = Map<String, dynamic>.from(value);
    final radial = json['kind'] == 'radial';
    final offsets = <double>[];
    final colours = <int>[];
    for (final stop in (json['stops'] as List?) ?? const []) {
      if (stop is! Map) continue;
      final colour = VectorShape.parseColour(stop['colour'] as String?);
      if (colour == null) continue;
      offsets.add((stop['at'] as num?)?.toDouble() ?? 0);
      colours.add(colour);
    }
    // One stop is a colour, not a gradient, and no stops is nothing at all.
    if (colours.length < 2) return null;
    final from = _point(json[radial ? 'centre' : 'from']);
    final to = _point(json[radial ? 'focus' : 'to']);
    if (from == null || to == null) return null;
    return VectorGradient(
      radial: radial,
      from: from,
      to: to,
      radius: (json['radius'] as num?)?.toDouble() ?? 0,
      offsets: offsets,
      colours: colours,
      spread: json['spread'] as String? ?? 'pad',
    );
  }

  static List<double>? _point(Object? value) {
    if (value is! List || value.length < 2) return null;
    return [
      (value[0] as num?)?.toDouble() ?? 0,
      (value[1] as num?)?.toDouble() ?? 0,
    ];
  }

  final bool radial;

  /// Where it starts, or the centre of a round one.
  final List<double> from;

  /// Where it ends, or the focus of a round one — which is the centre again
  /// unless the file moved it.
  final List<double> to;

  final double radius;

  /// Where each colour sits along it, 0 to 1.
  final List<double> offsets;
  final List<int> colours;

  /// What happens past the ends: `pad`, `reflect` or `repeat`.
  final String spread;
}

/// One path of a [VectorDrawing], with its paint already decided.
class VectorShape {
  const VectorShape({
    required this.verbs,
    required this.points,
    this.fill,
    this.stroke,
    this.fillGradient,
    this.strokeGradient,
    this.text,
    this.at = const [],
    this.size = 16,
    this.family = 'sans',
    this.weight = 400,
    this.italic = false,
    this.anchor = 'start',
    this.matrix = const [],
    this.strokeWidth = 1,
    this.evenOdd = false,
    this.cap = 'butt',
    this.join = 'miter',
  });

  factory VectorShape.fromJson(Map<String, dynamic> json) => VectorShape(
        text: json['text'] as String?,
        at: [
          for (final value in (json['at'] as List?) ?? const [])
            (value as num?)?.toDouble() ?? 0,
        ],
        size: (json['size'] as num?)?.toDouble() ?? 16,
        family: json['family'] as String? ?? 'sans',
        weight: (json['weight'] as num?)?.toInt() ?? 400,
        italic: json['italic'] as bool? ?? false,
        anchor: json['anchor'] as String? ?? 'start',
        matrix: [
          for (final value in (json['matrix'] as List?) ?? const [])
            (value as num?)?.toDouble() ?? 0,
        ],
        verbs: json['verbs'] is String
            ? base64Decode(json['verbs'] as String)
            : Uint8List(0),
        points: MeshGeometry._floats(json['points']),
        fill: parseColour(json['fill'] as String?),
        stroke: parseColour(json['stroke'] as String?),
        fillGradient: VectorGradient.fromJson(json['fillGradient']),
        strokeGradient: VectorGradient.fromJson(json['strokeGradient']),
        strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 1,
        evenOdd: json['evenOdd'] as bool? ?? false,
        cap: json['cap'] as String? ?? 'butt',
        join: json['join'] as String? ?? 'miter',
      );

  /// `#rrggbbaa` as an ARGB value, or null where there is nothing to paint.
  ///
  /// The plugin decides colours — including what a gradient it cannot draw
  /// averages to — so this end never sees a colour name or a `url(#…)`.
  static int? parseColour(String? value) {
    if (value == null || value.length != 9 || !value.startsWith('#')) return null;
    final rgb = int.tryParse(value.substring(1, 7), radix: 16);
    final alpha = int.tryParse(value.substring(7, 9), radix: 16);
    if (rgb == null || alpha == null) return null;
    return (alpha << 24) | rgb;
  }

  /// One byte a verb: 0 move, 1 line, 2 cubic, 3 close. Everything curved
  /// arrives cubic, so there is nothing else to know.
  final Uint8List verbs;

  /// Two floats a point, in the drawing's own space. A move and a line take
  /// one point, a cubic three, a close none.
  final Float32List points;

  final int? fill;
  final int? stroke;

  /// Painted instead of [fill] and [stroke] where the file asked for one.
  final VectorGradient? fillGradient;
  final VectorGradient? strokeGradient;

  /// A run of text instead of a path, where the drawing had words in it.
  ///
  /// **Words, not outlines.** Turning letters into shapes would need the font
  /// the file names, and a drawing may not bring one; so what arrives is what
  /// it says, where it sits and how big it is, and the host sets it in a face
  /// it has. The drawing says that a substitution happened.
  final String? text;

  /// Where the text sits — and [at] names the **baseline**, which is where
  /// every format that has text puts it and where no drawing API starts from.
  final List<double> at;

  final double size;

  /// `sans`, `serif` or `mono` — the file's own family already reduced to what
  /// an application can promise to have.
  final String family;

  final int weight;
  final bool italic;

  /// `start`, `middle` or `end`: which part of the run [at] names.
  final String anchor;

  /// The transform to draw the text under. A path has this baked into its
  /// points; letters cannot have, so it travels with them.
  final List<double> matrix;

  bool get isText => text != null && text!.isNotEmpty;

  final double strokeWidth;
  final bool evenOdd;
  final String cap;
  final String join;
}

/// One rendered result handed back by `viewer.open`.
class ViewerContent {
  const ViewerContent({
    required this.kind,
    this.text,
    this.language,
    this.bytes,
    this.mimeType,
    this.columns = const [],
    this.rows = const [],
    this.segments = const [],
    this.fields = const [],
    this.buttons = const [],
    this.meshes = const [],
    this.clips = const [],
    this.images = const [],
    this.parts = const [],
    this.nodeGraph,
    this.drawing,
    this.direction = SplitDirection.vertical,
    this.url,
    this.label,
    this.detail,
    this.message,
    this.truncated = false,
    this.cursor = -1,
  });

  factory ViewerContent.fromJson(Map<String, dynamic> json) {
    final kind = switch (json['kind'] as String?) {
      'markdown' => ViewerContentKind.markdown,
      'image' => ViewerContentKind.image,
      'table' => ViewerContentKind.table,
      'chart' => ViewerContentKind.chart,
      'form' => ViewerContentKind.form,
      'mesh3d' => ViewerContentKind.mesh3d,
      'nodes' => ViewerContentKind.nodes,
      'vector' => ViewerContentKind.vector,
      'audio' => ViewerContentKind.audio,
      'split' => ViewerContentKind.split,
      'file' => ViewerContentKind.file,
      'error' => ViewerContentKind.error,
      _ => ViewerContentKind.text,
    };

    return ViewerContent(
      kind: kind,
      text: json['text'] as String?,
      language: json['language'] as String?,
      bytes: json['data'] is String
          ? base64Decode(json['data'] as String)
          : null,
      mimeType: json['mimeType'] as String?,
      cursor: (json['cursor'] as num?)?.toInt() ?? -1,
      columns: [
        for (final column in (json['columns'] as List?) ?? const [])
          ListingColumn.fromJson(column),
      ],
      rows: [
        for (final row in (json['rows'] as List?) ?? const [])
          ListingRow.fromJson(row),
      ],
      segments: [
        for (final segment in (json['segments'] as List?) ?? const [])
          if (segment is Map)
            ChartSegment.fromJson(Map<String, dynamic>.from(segment)),
      ],
      fields: [
        for (final field in (json['fields'] as List?) ?? const [])
          if (field is Map)
            ContentField.fromJson(Map<String, dynamic>.from(field)),
      ],
      buttons: [
        for (final button in (json['buttons'] as List?) ?? const [])
          if (button is Map)
            ContentButton.fromJson(Map<String, dynamic>.from(button)),
      ],
      meshes: [
        for (final mesh in (json['meshes'] as List?) ?? const [])
          if (mesh is Map) MeshGeometry.fromJson(Map<String, dynamic>.from(mesh)),
      ],
      clips: [
        for (final clip in (json['clips'] as List?) ?? const [])
          if (clip is Map) MeshClip.fromJson(Map<String, dynamic>.from(clip)),
      ],
      images: [
        for (final image in (json['images'] as List?) ?? const [])
          if (image is Map && image['data'] is String)
            base64Decode(image['data'] as String),
      ],
      parts: [
        for (final part in (json['parts'] as List?) ?? const [])
          if (part is Map) ContentPart.fromJson(Map<String, dynamic>.from(part)),
      ],
      // The graph reads the same object it arrived in: `nodes`, `links` and
      // the rest are top-level keys, not a nested document.
      nodeGraph: kind == ViewerContentKind.nodes
          ? GraphDocument.fromJson(json)
          : null,
      // Same arrangement as the graph: the drawing's own keys are top level,
      // not a document nested inside the answer.
      drawing: kind == ViewerContentKind.vector
          ? VectorDrawing.fromJson(json)
          : null,
      direction: SplitDirection.parse(json['direction']),
      url: json['url'] as String?,
      label: json['label'] as String?,
      detail: json['detail'] as String?,
      message: json['message'] as String?,
      truncated: json['truncated'] as bool? ?? false,
    );
  }

  factory ViewerContent.error(String message) =>
      ViewerContent(kind: ViewerContentKind.error, message: message);

  final ViewerContentKind kind;

  /// Body for [ViewerContentKind.text] and the source for
  /// [ViewerContentKind.markdown].
  final String? text;

  /// Optional syntax hint, e.g. `json`. Reserved for future highlighting.
  final String? language;

  /// The shapes of a [ViewerContentKind.vector].
  final VectorDrawing? drawing;

  /// Raw bytes for [ViewerContentKind.image].
  final Uint8List? bytes;
  final String? mimeType;

  /// Header and body for [ViewerContentKind.table] — used by viewers that
  /// present structure rather than prose, such as an archive listing.
  ///
  /// Both halves accept the shape they always had: a column may be a bare
  /// label and a row a bare list of strings. What the richer shapes add is
  /// everything a listing needs and a grid of text cannot say — which column
  /// stretches, which is read as a hash, which row is worth noticing.
  final List<ListingColumn> columns;
  final List<ListingRow> rows;

  /// Wedges for [ViewerContentKind.chart], innermost ring first. Pressing one
  /// raises `activate` with its index, exactly as pressing a table row does —
  /// a chart is a listing drawn round instead of down, and the protocol treats
  /// it as one.
  final List<ChartSegment> segments;

  /// What a [ViewerContentKind.form] asks for, in the order it is drawn.
  final List<ContentField> fields;

  /// Buttons: along the top of a chart, along the bottom of a form.
  final List<ContentButton> buttons;

  /// The boxes and wires of a [ViewerContentKind.nodes], or null for anything
  /// else. See [GraphDocument].
  ///
  /// Not `graph`: a listing cell already has one of those and it is the braid
  /// beside a commit. Two different pictures should not share a name.
  final GraphDocument? nodeGraph;

  /// The parts of a [ViewerContentKind.mesh3d], already in world space.
  final List<MeshGeometry> meshes;

  /// What moves, baked frame by frame. Empty for a model that does not.
  final List<MeshClip> clips;

  /// The pictures the meshes are painted with, in the order they index by.
  ///
  /// Encoded as they arrived — a PNG or a JPEG, whatever was in the file —
  /// and decoded by whoever draws them, once.
  final List<Uint8List> images;

  /// The parts of a [ViewerContentKind.split], in the order they are laid out.
  final List<ContentPart> parts;

  final SplitDirection direction;

  /// What a [ViewerContentKind.file] points at.
  ///
  /// **The plugin names the file; the host finds who can draw it.** A tool
  /// that showed a picture would have to carry a picture decoder, and then a
  /// second one for the next format — while the application already knows
  /// which of its viewers claims a `.png`, because that is the question it
  /// answers every time somebody presses F3.
  ///
  /// So a plugin with something it cannot draw says where it is instead, on
  /// any transport the host can read — including one the plugin serves itself.
  /// A git tool points at a blob inside a commit and gets whatever the image
  /// viewer of the day makes of it, without knowing that viewer exists.
  final String? url;

  /// What the middle of a chart says, and the line under it. For a disk map:
  /// the folder being shown, and how big it is.
  final String? label;
  final String? detail;

  /// Text for [ViewerContentKind.error].
  final String? message;

  /// True when the plugin returned only part of the file.
  final bool truncated;

  /// Which row a table's cursor should be on, or -1 to leave it alone.
  ///
  /// **Say it once, not on every draw.** A view redraws itself whenever the
  /// cursor moves, so a table that named the cursor every time would drag it
  /// back where the view last put it and the arrow keys would fight the
  /// plugin. It is for the answer that *opens* a page: a tool coming back from
  /// having sent the panel somewhere says which row the reader left from, so
  /// they land there instead of at the top.
  final int cursor;
}

/// A viewer offered by a loaded plugin, ready to be invoked.
/// Whether the viewer reading a folder should hand this file over to another.
///
/// **A picture is not text, whatever is reading the folder.** A viewer that
/// takes everything — the text viewer is the fallback, and that is what makes
/// it useful — walks a folder that has pictures in it, and pressing one of
/// them opened a `.png` as a wall of bytes, which is nonsense whichever way
/// you look at it.
///
/// So the rule is about *naming*: a viewer keeps a file it names, and gives it
/// up to one that names it when all it was doing was taking what is left. A
/// walk through a folder of text stays with the text viewer and costs nothing;
/// landing on a picture hands it to the picture viewer.
bool givesWayTo(ViewerSpec reading, ViewerSpec other, FileEntry file) =>
    !reading.claims(file.extension, name: file.name) &&
    other.claims(file.extension, name: file.name) &&
    // **Unless the two are in the same business.** A viewer that produces the
    // same kind of thing is not somebody to give way to, it is somebody to
    // walk alongside: `.heic` belongs to a Python reader and `.jpg` to the
    // machine's own decoder, and a strip that stopped at the first `.heic`
    // was telling the reader the folder ended there.
    !opensTheSameKind(reading, other);

/// Whether two viewers give back the same kind of thing — see
/// [ViewerSpec.produces].
///
/// A viewer that says nothing is its own kind, and never the same as anybody
/// else's: everything written before `produces` existed keeps the strip it had.
bool opensTheSameKind(ViewerSpec one, ViewerSpec other) =>
    one.produces.isNotEmpty && one.produces == other.produces;

class RegisteredViewer {
  const RegisteredViewer({
    required this.spec,
    required this.pluginId,
    required this.pluginName,
    required this.open,
    this.probe,
    this.thumbnail,
  });

  final ViewerSpec spec;
  final String pluginId;
  final String pluginName;

  /// Asks the plugin to render [path].
  final Future<ViewerContent> Function(VfsPath path) open;

  /// Asks the plugin whether it claims *this* file, given its first pages —
  /// see [ViewerSpec.probe] for why the question exists.
  ///
  /// Null wherever nothing can answer it: a viewer that never declared a probe,
  /// or a runtime with no way to ask. A viewer that cannot be asked is ordered
  /// by its extension, exactly as before.
  final Future<bool> Function(VfsPath path, List<int> head)? probe;

  /// Asks the plugin for a small copy of [path], at most `pixels` across.
  ///
  /// **Only where the machine's own decoder has already refused.** The engine
  /// decodes *to* a size and costs no process; this costs a call down the pipe
  /// and a plugin doing real work, and it exists for the formats the engine
  /// does not read at all — `.xcf` anywhere, `.psd` and `.tga` off macOS.
  ///
  /// Null wherever nothing can answer: a viewer that did not declare
  /// `thumbnails`, or a runtime with no way to ask.
  final Future<Uint8List?> Function(VfsPath path, int pixels)? thumbnail;

  String get id => spec.id;

  /// What to call this viewer, in the language now in force — it is drawn in
  /// "open with" and in the title bar's list of readings.
  String get title => saidBy(pluginId, spec.title);
}

/// A plugin that can say what a file says about itself — see `facts.dart`.
class RegisteredDescriber {
  const RegisteredDescriber({
    required this.spec,
    required this.pluginId,
    required this.pluginName,
    required this.describe,
  });

  final DescriberSpec spec;
  final String pluginId;
  final String pluginName;

  /// Asks the plugin what [path] says about itself.
  final Future<FileFacts> Function(VfsPath path) describe;

  String get id => spec.id;

  /// What to call the panel while it is showing this, in the user's language.
  String get title => saidBy(pluginId, spec.title);
}
