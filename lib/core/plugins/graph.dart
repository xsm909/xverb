/// The document a reader sends for [ViewerContentKind.nodes] — a graph of boxes
/// and the wires between them.
///
/// **Two halves, and keeping them apart is the whole design.** A plugin turns a
/// ComfyUI workflow, an n8n export or a Node-RED tab into *this*, and the host
/// owns the canvas that draws it: boxes, pins, wires, groups, notes, the
/// keyboard and every colour. The split that already worked twice — a grammar is
/// data and the scanner is the host's; a chart is a flat list of wedges and the
/// geometry is the host's — and for the same reason: a node's width depends on
/// the font the user chose, which no plugin can know.
///
/// Ordinary JSON, unpacked. A large workflow is hundreds of nodes, not the
/// quarter of a million numbers that made `mesh3d` base64 its floats.
library;

/// What a node is, as far as the palette is concerned.
///
/// **Roles, never colours** — the rule a grammar already follows for code and a
/// wedge for the disk map. A reader says `error`; it never says red, because on
/// some palettes red is what a directory is written in.
enum NodeRole {
  event,
  flow,
  pure,
  input,
  output,
  variable,
  note,
  group,
  error,
  normal;

  static NodeRole parse(Object? name) => switch (name) {
    'event' => NodeRole.event,
    'flow' => NodeRole.flow,
    'pure' => NodeRole.pure,
    'input' => NodeRole.input,
    'output' => NodeRole.output,
    'variable' => NodeRole.variable,
    'note' => NodeRole.note,
    'group' => NodeRole.group,
    'error' => NodeRole.error,
    _ => NodeRole.normal,
  };
}

/// Whether a wire carries an order of execution or a value.
enum LinkRole {
  flow,
  data;

  static LinkRole parse(Object? name) =>
      name == 'flow' ? LinkRole.flow : LinkRole.data;
}

/// Whether the file said where the nodes go, or the host has to work it out.
enum GraphLayout {
  /// The document carries coordinates, which is the common case: every format
  /// in the first phase but one has them.
  given,

  /// It does not — a Godot scene is a tree with no positions — so the host lays
  /// it out.
  layered;

  static GraphLayout parse(Object? name) =>
      name == 'layered' ? GraphLayout.layered : GraphLayout.given;
}

/// Which way a graph reads.
enum GraphDirection {
  leftToRight,
  topToBottom;

  static GraphDirection parse(Object? name) =>
      name == 'tb' ? GraphDirection.topToBottom : GraphDirection.leftToRight;
}

/// One socket on a node.
class GraphPin {
  const GraphPin({required this.id, this.label = '', this.type});

  factory GraphPin.fromJson(Map<String, dynamic> json) => GraphPin(
    id: json['id']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    type: json['type']?.toString(),
  );

  /// The plugin's own name for it. The host never interprets one.
  final String id;

  /// What is written beside it.
  final String label;

  /// What travels through it — `LATENT`, `MODEL`, `IMAGE`. It names a colour
  /// family; the colour itself comes off the palette.
  final String? type;

  /// What to draw. The id stands in where a reader had nothing better to say.
  String get caption => label.isEmpty ? id : label;
}

/// A value written on the face of a node.
///
/// **This is what makes a workflow readable.** The seed, the step count, the
/// prompt: most of what somebody opens the file to see. A node with no fields is
/// a box with a name on it, which is worth much less.
class GraphField {
  const GraphField({required this.label, required this.value});

  factory GraphField.fromJson(Map<String, dynamic> json) => GraphField(
    label: json['label']?.toString() ?? '',
    value: json['value']?.toString() ?? '',
  );

  final String label;
  final String value;
}

/// One box.
class GraphNode {
  const GraphNode({
    required this.id,
    this.title = '',
    this.subtitle,
    this.role = NodeRole.normal,
    this.x = 0,
    this.y = 0,
    this.width,
    this.collapsed = false,
    this.group,
    this.badges = const [],
    this.inputs = const [],
    this.outputs = const [],
    this.fields = const [],
  });

  factory GraphNode.fromJson(Map<String, dynamic> json) => GraphNode(
    id: json['id']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    subtitle: json['subtitle']?.toString(),
    role: NodeRole.parse(json['role']),
    x: (json['x'] as num?)?.toDouble() ?? 0,
    y: (json['y'] as num?)?.toDouble() ?? 0,
    width: (json['width'] as num?)?.toDouble(),
    collapsed: json['collapsed'] as bool? ?? false,
    group: json['group']?.toString(),
    badges: [
      for (final badge in (json['badges'] as List?) ?? const [])
        badge.toString(),
    ],
    inputs: [
      for (final pin in (json['inputs'] as List?) ?? const [])
        if (pin is Map) GraphPin.fromJson(Map<String, dynamic>.from(pin)),
    ],
    outputs: [
      for (final pin in (json['outputs'] as List?) ?? const [])
        if (pin is Map) GraphPin.fromJson(Map<String, dynamic>.from(pin)),
    ],
    fields: [
      for (final field in (json['fields'] as List?) ?? const [])
        if (field is Map) GraphField.fromJson(Map<String, dynamic>.from(field)),
    ],
  );

  /// The plugin's, and a string. The host never interprets one.
  final String id;

  final String title;
  final String? subtitle;
  final NodeRole role;

  /// Where the file says it goes. Ignored under [GraphLayout.layered].
  final double x;
  final double y;

  /// What the reader asked for, or null to let the host measure it — which is
  /// the usual answer, and the reason the canvas lives here rather than there.
  final double? width;

  final bool collapsed;

  /// An id from [GraphDocument.groups], or null.
  final String? group;

  /// Icon names from the host's own set.
  final List<String> badges;

  final List<GraphPin> inputs;
  final List<GraphPin> outputs;
  final List<GraphField> fields;

  /// What the box is called, falling back to the id so a node is never nameless.
  String get caption => title.isEmpty ? id : title;
}

/// One wire.
class GraphLink {
  const GraphLink({
    required this.from,
    required this.to,
    this.fromPin,
    this.toPin,
    this.role = LinkRole.data,
    this.type,
    this.label = '',
  });

  factory GraphLink.fromJson(Map<String, dynamic> json) => GraphLink(
    from: json['from']?.toString() ?? '',
    to: json['to']?.toString() ?? '',
    fromPin: json['fromPin']?.toString(),
    toPin: json['toPin']?.toString(),
    role: LinkRole.parse(json['role']),
    type: json['type']?.toString(),
    label: json['label']?.toString() ?? '',
  );

  final String from;
  final String to;

  /// **Optional, on purpose.** Node-RED joins nodes, not ports; without this a
  /// reader would have to invent ports to have its wires drawn at all, and the
  /// wire leaves the edge of the box instead.
  final String? fromPin;
  final String? toPin;

  final LinkRole role;

  /// Names a colour family, as a pin's type does.
  final String? type;

  /// Drawn at the midpoint, where there is one.
  final String label;
}

/// A box drawn behind a set of nodes, with a name on it.
class GraphGroup {
  const GraphGroup({
    required this.id,
    this.title = '',
    this.x = 0,
    this.y = 0,
    this.width = 0,
    this.height = 0,
  });

  factory GraphGroup.fromJson(Map<String, dynamic> json) => GraphGroup(
    id: json['id']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    x: (json['x'] as num?)?.toDouble() ?? 0,
    y: (json['y'] as num?)?.toDouble() ?? 0,
    width: (json['width'] as num?)?.toDouble() ?? 0,
    height: (json['height'] as num?)?.toDouble() ?? 0,
  );

  final String id;
  final String title;
  final double x;
  final double y;
  final double width;
  final double height;
}

/// A note somebody left on the canvas.
class GraphNote {
  const GraphNote({
    this.text = '',
    this.x = 0,
    this.y = 0,
    this.width = 200,
    this.height = 100,
  });

  factory GraphNote.fromJson(Map<String, dynamic> json) => GraphNote(
    text: json['text']?.toString() ?? '',
    x: (json['x'] as num?)?.toDouble() ?? 0,
    y: (json['y'] as num?)?.toDouble() ?? 0,
    width: (json['width'] as num?)?.toDouble() ?? 200,
    height: (json['height'] as num?)?.toDouble() ?? 100,
  );

  final String text;
  final double x;
  final double y;
  final double width;
  final double height;
}

/// The whole graph.
class GraphDocument {
  const GraphDocument({
    this.layout = GraphLayout.given,
    this.direction = GraphDirection.leftToRight,
    this.nodes = const [],
    this.links = const [],
    this.groups = const [],
    this.notes = const [],
    this.dangling = 0,
  });

  factory GraphDocument.fromJson(Map<String, dynamic> json) {
    final nodes = [
      for (final node in (json['nodes'] as List?) ?? const [])
        if (node is Map) GraphNode.fromJson(Map<String, dynamic>.from(node)),
    ];
    final known = {for (final node in nodes) node.id};

    // **A wire to a node that is not here is dropped, and counted.** Drawing it
    // to nowhere would be a lie about the graph; dropping it in silence would be
    // a different one. The page says how many went — the same rule the git log
    // follows when it stops short and the find box when a file was cut.
    final links = <GraphLink>[];
    var dangling = 0;
    for (final raw in (json['links'] as List?) ?? const []) {
      if (raw is! Map) continue;
      final wire = GraphLink.fromJson(Map<String, dynamic>.from(raw));
      if (known.contains(wire.from) && known.contains(wire.to)) {
        links.add(wire);
      } else {
        dangling++;
      }
    }

    return GraphDocument(
      layout: GraphLayout.parse(json['layout']),
      direction: GraphDirection.parse(json['direction']),
      nodes: nodes,
      links: links,
      dangling: dangling,
      groups: [
        for (final group in (json['groups'] as List?) ?? const [])
          if (group is Map)
            GraphGroup.fromJson(Map<String, dynamic>.from(group)),
      ],
      notes: [
        for (final note in (json['notes'] as List?) ?? const [])
          if (note is Map) GraphNote.fromJson(Map<String, dynamic>.from(note)),
      ],
    );
  }

  final GraphLayout layout;
  final GraphDirection direction;
  final List<GraphNode> nodes;
  final List<GraphLink> links;
  final List<GraphGroup> groups;
  final List<GraphNote> notes;

  /// How many wires named a node the document does not contain.
  final int dangling;

  bool get isEmpty => nodes.isEmpty;
}
