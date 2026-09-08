import 'dart:math' as math;

import '../../core/plugins/graph.dart';

/// Where the nodes go when the file did not say.
///
/// **In the host, not in the reader**, and that is the same argument the canvas
/// itself rests on: a node is as wide as its text in the font the user chose, so
/// the only place that can space them is the place that measured them. It is
/// deliberately *not* the `lay_out()` the SDK gives a plugin for a commit graph
/// — that one places lanes, which are one character wide wherever they are.
///
/// Four steps, and the third and fourth are what make it look drawn rather than
/// computed:
///
/// 1. **Layer** by the longest path from a source, so a node always stands to
///    the right of everything that feeds it.
/// 2. **A wire that crosses more than one layer gets a lane of its own** — a
///    stand-in node in each layer it passes over. This is the piece the first
///    cut left out, and it is the one that shows: without it a long wire is
///    drawn straight through whatever happens to stand in the way, and since
///    wires are painted *under* boxes it disappears into one and comes out the
///    other side, which reads as a wire arriving at a socket that is not
///    there: the inputs and outputs stop matching the points they are drawn
///    at.
/// 3. **Order** within a layer by the barycentre of what each node is joined to,
///    then a pass of swapping neighbours while it helps. Not optimal — crossing
///    minimisation is NP-hard and nobody reading a workflow can tell a good
///    answer from the best one.
/// 4. **Straighten.** Each node is pulled to the middle of what it is joined to
///    and then pushed back apart until nothing overlaps, a few times over. A
///    chain comes out as a straight line, which is what the automatic layout
///    was missing when it came out crooked.
///
/// A cycle is not an error. Whatever is left when the layering runs out of
/// nodes goes into the next layer regardless: a graph that loops is still a
/// graph somebody wants to read, and refusing to draw it would be the one
/// outcome worse than drawing it slightly wrong.
class LayeredLayout {
  const LayeredLayout({this.gap = 70, this.rowGap = 28});

  /// Between one layer and the next, along the direction the graph reads.
  final double gap;

  /// Between two nodes of the same layer, across it.
  final double rowGap;

  /// How much room a wire's lane takes across the layer it is passing through.
  static const double _laneHeight = 12;

  /// How many times the straightening runs. Past a handful the picture stops
  /// changing; this is measured on the fixtures rather than argued about.
  static const int _passes = 6;

  /// Where everything goes, and how the long wires get there.
  ///
  /// **One direction is implemented and two are offered.** Everything below
  /// lays layers out across the page; a document that reads top to bottom — a
  /// scene tree, and anything else that is a tree rather than a pipeline — is
  /// laid out in a space turned on its side and turned back at the end. That
  /// costs one swap of each pair of numbers and leaves this with a single
  /// thing to get right.
  LayeredPlacement run(
    GraphDocument graph,
    Size2 Function(GraphNode node) sizeOf,
  ) {
    final nodes = graph.nodes;
    if (nodes.isEmpty) return const LayeredPlacement({}, {});

    final downwards = graph.direction == GraphDirection.topToBottom;
    if (downwards) {
      final turned = _turn(
        run(
          GraphDocument(
            nodes: graph.nodes,
            links: graph.links,
            groups: graph.groups,
            notes: graph.notes,
            layout: graph.layout,
            // The same graph, read the ordinary way, over sizes on their side.
          ),
          (node) {
            final size = sizeOf(node);
            return Size2(size.height, size.width);
          },
        ),
      );
      return turned;
    }

    final index = {for (var i = 0; i < nodes.length; i++) nodes[i].id: i};

    // The graph as it stands, before any stand-ins.
    final out = <int, List<int>>{for (var i = 0; i < nodes.length; i++) i: []};
    final into = <int, List<int>>{for (var i = 0; i < nodes.length; i++) i: []};
    for (final link in graph.links) {
      final from = index[link.from];
      final to = index[link.to];
      if (from == null || to == null || from == to) continue;
      out[from]!.add(to);
      into[to]!.add(from);
    }

    // **Back edges are left out of the layering.** A Godot scene is two graphs
    // drawn together: the tree, which runs from the root down, and the signals,
    // which run from a child back up to it. Layering over both put the root at
    // the *bottom*, under everything that signals it — which is upside down,
    // and the picture said so the first time a scene was drawn.
    //
    // So the wires that close a loop are found and set aside before the layers
    // are counted. They are still drawn, and they still get their lane: this
    // decides where the boxes stand, not what is joined to what.
    final backwards = _backEdges(nodes.length, out);
    final forwardsOut = <int, List<int>>{
      for (var i = 0; i < nodes.length; i++)
        i: [
          for (final to in out[i]!)
            if (!backwards.contains('$i>$to')) to,
        ],
    };
    final forwardsInto = <int, List<int>>{
      for (var i = 0; i < nodes.length; i++)
        i: [
          for (final from in into[i]!)
            if (!backwards.contains('$from>$i')) from,
        ],
    };

    final layer = _layers(nodes.length, forwardsOut, forwardsInto);

    // From here on everything works on *vertices*: the nodes themselves, and
    // the stand-ins that hold a lane open for a wire crossing a layer it has
    // no business stopping in.
    final width = <double>[];
    final height = <double>[];
    for (var i = 0; i < nodes.length; i++) {
      final size = sizeOf(nodes[i]);
      width.add(size.width);
      height.add(size.height);
    }

    final vertexLayer = List<int>.from(layer);
    final edgesOut = <int, List<int>>{
      for (var i = 0; i < nodes.length; i++) i: [],
    };
    final edgesInto = <int, List<int>>{
      for (var i = 0; i < nodes.length; i++) i: [],
    };

    int addStandIn(int depth) {
      final id = width.length;
      width.add(0);
      height.add(_laneHeight);
      vertexLayer.add(depth);
      edgesOut[id] = [];
      edgesInto[id] = [];
      return id;
    }

    void join(int from, int to) {
      edgesOut[from]!.add(to);
      edgesInto[to]!.add(from);
    }

    /// The stand-ins each long wire is threaded through, by its place in the
    /// document's own list of links.
    final chains = <int, List<int>>{};

    for (var i = 0; i < graph.links.length; i++) {
      final link = graph.links[i];
      final from = index[link.from];
      final to = index[link.to];
      if (from == null || to == null || from == to) continue;

      final span = vertexLayer[to] - vertexLayer[from];
      if (span <= 1) {
        join(from, to);
        continue;
      }

      final chain = <int>[];
      var previous = from;
      for (var depth = vertexLayer[from] + 1; depth < vertexLayer[to]; depth++) {
        final stand = addStandIn(depth);
        chain.add(stand);
        join(previous, stand);
        previous = stand;
      }
      join(previous, to);
      chains[i] = chain;
    }

    final rows = <int, List<int>>{};
    for (var i = 0; i < vertexLayer.length; i++) {
      rows.putIfAbsent(vertexLayer[i], () => []).add(i);
    }

    _order(rows, edgesInto, edgesOut, vertexLayer);

    // Across the layer: a first stacking, then the straightening.
    final top = List<double>.filled(width.length, 0);
    final depths = rows.keys.toList()..sort();
    for (final depth in depths) {
      var y = 0.0;
      for (final at in rows[depth]!) {
        top[at] = y;
        y += height[at] + rowGap;
      }
    }
    _straighten(rows, depths, edgesInto, edgesOut, top, height);

    // Along it: each layer starts where the widest of the last one ended.
    final columnX = <int, double>{};
    final columnWidth = <int, double>{};
    var x = 0.0;
    for (final depth in depths) {
      var widest = 0.0;
      for (final at in rows[depth]!) {
        widest = math.max(widest, width[at]);
      }
      columnX[depth] = x;
      columnWidth[depth] = widest;
      x += widest + gap;
    }

    // Nothing above the origin, so the canvas's own fit has an honest box to
    // work with.
    var highest = 0.0;
    for (var i = 0; i < top.length; i++) {
      highest = math.min(highest, top[i]);
    }

    final places = <String, Offset2>{};
    for (var i = 0; i < nodes.length; i++) {
      places[nodes[i].id] = Offset2(
        columnX[vertexLayer[i]]!,
        top[i] - highest,
      );
    }

    final routes = <int, List<Offset2>>{};
    for (final entry in chains.entries) {
      routes[entry.key] = [
        for (final stand in entry.value)
          Offset2(
            // The middle of the column it is passing through, so the wire
            // bends between the boxes rather than beside one of them.
            columnX[vertexLayer[stand]]! + columnWidth[vertexLayer[stand]]! / 2,
            top[stand] - highest + _laneHeight / 2,
          ),
      ];
    }

    // **A wire that goes back the way it came takes the long way round.**
    // A graph that loops has edges pointing left, and drawn straight one of
    // those is a diagonal across the whole picture that reads as a mistake.
    // Under the graph and back is how every editor draws a feedback loop, and
    // it says
    // what it is: this goes *back*.
    var lowest = 0.0;
    for (var i = 0; i < nodes.length; i++) {
      lowest = math.max(lowest, top[i] - highest + height[i]);
    }
    var returning = 0;
    for (var i = 0; i < graph.links.length; i++) {
      final link = graph.links[i];
      final from = index[link.from];
      final to = index[link.to];
      if (from == null || to == null || from == to) continue;
      if (vertexLayer[to] > vertexLayer[from]) continue;

      final under = lowest + rowGap * 2 + returning * 16;
      returning++;
      routes[i] = [
        Offset2(
          columnX[vertexLayer[from]]! + columnWidth[vertexLayer[from]]! + gap / 2,
          under,
        ),
        Offset2(columnX[vertexLayer[to]]! - gap / 2, under),
      ];
    }

    return LayeredPlacement(places, routes);
  }

  /// The wires that close a loop, as `from>to`.
  ///
  /// A walk over the graph, marking what it is standing inside: an edge back
  /// into something already on the walk is what makes the loop. Iterative
  /// rather than recursive because five thousand nodes deep is a stack this
  /// application does not get to run out of.
  Set<String> _backEdges(int count, Map<int, List<int>> out) {
    const white = 0;
    const grey = 1;
    const black = 2;
    final colour = List<int>.filled(count, white);
    final back = <String>{};

    // Sources first, so the walk goes the way the graph reads and the edges it
    // calls backwards are the ones a reader would call backwards too.
    final order = [
      for (var i = 0; i < count; i++)
        if (out[i]!.isNotEmpty) i,
    ];

    for (final start in [...order, for (var i = 0; i < count; i++) i]) {
      if (colour[start] != white) continue;
      final stack = <(int, int)>[(start, 0)];
      colour[start] = grey;
      while (stack.isNotEmpty) {
        final (at, next) = stack.removeLast();
        if (next >= out[at]!.length) {
          colour[at] = black;
          continue;
        }
        stack.add((at, next + 1));
        final child = out[at]![next];
        if (colour[child] == grey) {
          back.add('$at>$child');
          continue;
        }
        if (colour[child] == white) {
          colour[child] = grey;
          stack.add((child, 0));
        }
      }
    }
    return back;
  }

  /// The longest path from a source, per node.
  List<int> _layers(
    int count,
    Map<int, List<int>> out,
    Map<int, List<int>> into,
  ) {
    final layer = List<int>.filled(count, 0);
    final waiting = {
      for (var i = 0; i < count; i++) i: into[i]!.toSet().length,
    };
    final ready = [
      for (var i = 0; i < count; i++)
        if (waiting[i] == 0) i,
    ];

    // Nothing has an empty inbox: the whole graph is a cycle. Start it at the
    // first node rather than drawing nothing.
    if (ready.isEmpty) ready.add(0);

    final settled = <int>{};
    while (ready.isNotEmpty) {
      final at = ready.removeAt(0);
      if (!settled.add(at)) continue;
      for (final child in out[at]!) {
        layer[child] = math.max(layer[child], layer[at] + 1);
        waiting[child] = waiting[child]! - 1;
        if (waiting[child]! <= 0 && !settled.contains(child)) {
          ready.add(child);
        }
      }
    }

    // Whatever the cycle kept out is placed after whatever feeds it, which is
    // as true as anything can be about a loop.
    for (var i = 0; i < count; i++) {
      if (settled.contains(i)) continue;
      var deepest = 0;
      for (final parent in into[i]!) {
        if (settled.contains(parent)) {
          deepest = math.max(deepest, layer[parent] + 1);
        }
      }
      layer[i] = deepest;
    }

    _tighten(count, out, layer);
    return layer;
  }

  /// Pulls every node as far right as it can go without passing what it feeds.
  ///
  /// **This is the difference between a layout and a heap.** The longest path
  /// puts everything with no inbox in the first layer, and a real workflow is
  /// full of those: an n8n agent with sixteen tools hanging off it drew them as
  /// a column sixteen boxes tall at the far left, joined to something in the
  /// middle of the picture by sixteen wires the length of the page. Moved up
  /// against the node they feed, they read as what they are.
  ///
  /// Bounded rather than run to a fixed point: a cycle has no "as late as
  /// possible", and a few passes is all the difference there is to make.
  void _tighten(int count, Map<int, List<int>> out, List<int> layer) {
    for (var pass = 0; pass < 8; pass++) {
      var moved = false;
      for (var i = 0; i < count; i++) {
        final children = out[i]!;
        if (children.isEmpty) continue;
        var earliest = layer[children.first];
        for (final child in children) {
          earliest = math.min(earliest, layer[child]);
        }
        if (earliest - 1 > layer[i]) {
          layer[i] = earliest - 1;
          moved = true;
        }
      }
      if (!moved) return;
    }
  }

  /// Barycentre ordering, then a pass of swapping neighbours while it helps.
  ///
  /// The swap is what the barycentre on its own cannot do: two nodes with the
  /// same average sit in whatever order they arrived in, and one of the two is
  /// usually a crossing.
  void _order(
    Map<int, List<int>> rows,
    Map<int, List<int>> into,
    Map<int, List<int>> out,
    List<int> layer,
  ) {
    final depths = rows.keys.toList()..sort();

    for (var sweep = 0; sweep < 4; sweep++) {
      for (final depth in sweep.isEven ? depths : depths.reversed) {
        final column = rows[depth]!;
        final neighbours = sweep.isEven ? into : out;
        final places = <int, double>{};

        for (final at in column) {
          final joined = neighbours[at]!
              .where((other) => layer[other] != depth)
              .toList();
          if (joined.isEmpty) {
            places[at] = column.indexOf(at).toDouble();
            continue;
          }
          var total = 0.0;
          for (final other in joined) {
            total += rows[layer[other]]!.indexOf(other).toDouble();
          }
          places[at] = total / joined.length;
        }

        column.sort((a, b) => places[a]!.compareTo(places[b]!));
      }

      var swapped = false;
      for (final depth in depths) {
        final column = rows[depth]!;
        for (var i = 0; i + 1 < column.length; i++) {
          if (_crossings(column, i, rows, into, out, layer) >
              _crossings(column, i, rows, into, out, layer, swap: true)) {
            final keep = column[i];
            column[i] = column[i + 1];
            column[i + 1] = keep;
            swapped = true;
          }
        }
      }
      if (!swapped && sweep > 0) break;
    }
  }

  /// How many wires cross between these two neighbours, as they are or swapped.
  int _crossings(
    List<int> column,
    int at,
    Map<int, List<int>> rows,
    Map<int, List<int>> into,
    Map<int, List<int>> out,
    List<int> layer, {
    bool swap = false,
  }) {
    final first = column[swap ? at + 1 : at];
    final second = column[swap ? at : at + 1];

    int count(Map<int, List<int>> side) {
      var crossings = 0;
      for (final one in side[first]!) {
        for (final other in side[second]!) {
          final a = rows[layer[one]]?.indexOf(one) ?? 0;
          final b = rows[layer[other]]?.indexOf(other) ?? 0;
          if (a > b) crossings++;
        }
      }
      return crossings;
    }

    return count(into) + count(out);
  }

  /// Pulls every node to the middle of what it is joined to, then pushes the
  /// column back apart until nothing overlaps.
  ///
  /// This is the difference between a layered layout that looks laid out and
  /// one that looks like a spreadsheet: a chain of nodes ends up on one line,
  /// and a node feeding three others sits across from the middle of them.
  void _straighten(
    Map<int, List<int>> rows,
    List<int> depths,
    Map<int, List<int>> into,
    Map<int, List<int>> out,
    List<double> top,
    List<double> height,
  ) {
    double centre(int at) => top[at] + height[at] / 2;

    for (var pass = 0; pass < _passes; pass++) {
      final forward = pass.isEven;
      for (final depth in forward ? depths : depths.reversed.toList()) {
        final column = rows[depth]!;
        final side = forward ? into : out;

        for (final at in column) {
          final joined = side[at]!;
          if (joined.isEmpty) continue;
          final middles = [for (final other in joined) centre(other)]..sort();
          final median = middles.length.isOdd
              ? middles[middles.length ~/ 2]
              : (middles[middles.length ~/ 2 - 1] +
                        middles[middles.length ~/ 2]) /
                    2;
          top[at] = median - height[at] / 2;
        }

        // Down, then up: two sweeps settle a column that the pull above has
        // left overlapping, without undoing the order the crossings pass chose.
        for (var i = 1; i < column.length; i++) {
          final above = column[i - 1];
          final least = top[above] + height[above] + rowGap;
          if (top[column[i]] < least) top[column[i]] = least;
        }
        for (var i = column.length - 2; i >= 0; i--) {
          final below = column[i + 1];
          final most = top[below] - rowGap - height[column[i]];
          if (top[column[i]] > most) top[column[i]] = most;
        }
      }
    }
  }
}

/// Where the nodes went, and the way the long wires take to get there.
class LayeredPlacement {
  const LayeredPlacement(this.places, this.routes);

  /// By node id.
  final Map<String, Offset2> places;

  /// Waypoints for the wires that cross more than one layer, keyed by their
  /// index in the document's own list of links. A wire with no entry here goes
  /// straight from one box to the next, which is what a short wire should do.
  final Map<int, List<Offset2>> routes;
}

/// The same placement with every pair of numbers swapped: what was laid out
/// across the page now runs down it.
LayeredPlacement _turn(LayeredPlacement placement) => LayeredPlacement(
  {
    for (final at in placement.places.entries)
      at.key: Offset2(at.value.y, at.value.x),
  },
  {
    for (final route in placement.routes.entries)
      route.key: [for (final point in route.value) Offset2(point.y, point.x)],
  },
);

/// A point, without dragging `dart:ui` into a file that is pure arithmetic.
class Offset2 {
  const Offset2(this.x, this.y);

  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is Offset2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Offset2($x, $y)';
}

/// A size, for the same reason.
class Size2 {
  const Size2(this.width, this.height);

  final double width;
  final double height;
}
