import '../vfs/vfs_path.dart';
import '../i18n/plugin_strings.dart';
import 'plugin_manifest.dart';
import 'viewer.dart';

/// What a view is pointed at, and where it was opened.
///
/// Handed over on `view.open` and again whenever the host re-points a view that
/// [ViewSpec.follows] something. A plugin gets the location rather than a file
/// handle on purpose: the location may be on any transport, and reading it goes
/// back through the host.
class ViewContext {
  const ViewContext({
    required this.session,
    required this.surface,
    this.path,
    this.otherPath,
    this.isDirectory = false,
    this.selection = const [],
  });

  /// Identifies this open copy of the view. The same view can be open in both
  /// panels and full screen at once, and each has its own state, so every call
  /// says which one it is about.
  final String session;

  final PluginSurface surface;

  /// Where the view is looking: the directory it was opened on, or the entry
  /// under the other panel's cursor for a view that follows one.
  final VfsPath? path;

  /// Where the *other* panel is pointing.
  ///
  /// This application has two sides, and some tools are about both of them at
  /// once — comparing two folders is the whole of one. A view could not find
  /// this out for itself: it is another process, and which panel is "the other
  /// one" is a question about the screen.
  ///
  /// Which panel that is follows the rule everything else here follows. In a
  /// panel it is the panel not holding the view, which is what makes one side
  /// a viewport onto the other; full screen it is the panel that was not
  /// active when the view was opened.
  final VfsPath? otherPath;

  /// True when [path] is a directory. A view that draws folders and a view that
  /// reads files both need to know, and asking the host again would be a round
  /// trip for something already known.
  final bool isDirectory;

  /// What was marked in the panel the view was opened from, if anything.
  final List<VfsPath> selection;

  ViewContext withPath(VfsPath? path, {bool isDirectory = false}) => ViewContext(
        session: session,
        surface: surface,
        path: path,
        otherPath: otherPath,
        isDirectory: isDirectory,
        selection: selection,
      );

  /// The same context with the other side moved. Separate from [withPath]
  /// because the two move for different reasons: one is the view being
  /// re-pointed, the other is the panel beside it being walked somewhere.
  ViewContext withOtherPath(VfsPath? path) => ViewContext(
        session: session,
        surface: surface,
        path: this.path,
        otherPath: path,
        isDirectory: isDirectory,
        selection: selection,
      );

  Map<String, dynamic> toJson() => {
        'session': session,
        'surface': surface.name,
        if (path != null) 'url': path.toString(),
        if (otherPath != null) 'otherUrl': otherPath.toString(),
        'isDirectory': isDirectory,
        if (selection.isNotEmpty)
          'selection': [for (final path in selection) path.toString()],
      };
}

/// Something the user did inside a view.
///
/// Deliberately few: a view is not a widget toolkit, and every event here is
/// one the host can raise from any of the shapes a plugin can return.
class ViewEvent {
  const ViewEvent({
    required this.type,
    this.row,
    this.key,
    this.id,
    this.accepted,
    this.part = '',
    this.paths = const [],
    this.values = const {},
    this.marked = const [],
    this.from = '',
  });

  /// A row of a table, or a wedge of a chart, was opened — clicked, or Enter
  /// on it. Row -1 is the middle of a chart: the way back out.
  factory ViewEvent.activate(int row,
          {String part = '', List<int> marked = const []}) =>
      ViewEvent(type: 'activate', row: row, part: part, marked: marked);

  /// The cursor came to rest on a row. Only sent to a view that asked for it,
  /// and only once the cursor has stopped — see [ViewSpec.wantsCursor].
  factory ViewEvent.cursor(int row, {String part = ''}) =>
      ViewEvent(type: 'cursor', row: row, part: part);

  /// The secondary press: the user picked a row out rather than opening it.
  /// What being picked out *means* is the view's business — a disk map puts it
  /// on the list to delete, another view might do nothing at all.
  factory ViewEvent.mark(int row,
          {String part = '', List<int> marked = const []}) =>
      ViewEvent(type: 'mark', row: row, part: part, marked: marked);

  /// One of the buttons the content declared was pressed.
  ///
  /// [values] is what a form's fields held at that moment, by field id, and is
  /// empty from anywhere else. Nothing is sent while it is being typed: a round
  /// trip per keystroke would put a pipe between a key and the letter.
  factory ViewEvent.button(String id, {Map<String, Object?> values = const {}}) =>
      ViewEvent(type: 'button', id: id, values: values);

  /// The host finished deleting what the view asked it to. Only the paths that
  /// actually went are named, so a view can trust the list: a cancelled
  /// confirmation sends no event at all.
  factory ViewEvent.deleted(List<VfsPath> paths) =>
      ViewEvent(type: 'deleted', paths: paths);

  /// A level of the view's own trail was pressed — the way back up, in the
  /// place a panel keeps its path.
  factory ViewEvent.step(int index) => ViewEvent(type: 'step', row: index);

  /// The user went back a page — Escape, Back, or the view's own `back`
  /// action. [row] is how many pages are still stacked over the first, so a
  /// view that pushed more than one knows where it has landed.
  ///
  /// Sent *after* the page underneath is already drawn. It is not a request:
  /// the host has the page and does not need the plugin to send it again.
  factory ViewEvent.back(int depth) => ViewEvent(type: 'back', row: depth);

  /// Rows were carried out of one part and let go over another.
  ///
  /// [part] is where they landed and [from] is where they were picked up;
  /// [marked] is which rows, by index into the source part as it was drawn —
  /// the marked ones, or the one under the hand when none were. **What it
  /// means is the view's**: the host knows only that they were moved.
  factory ViewEvent.drop(String from, String to, List<int> rows) =>
      ViewEvent(type: 'drop', part: to, from: from, marked: rows);

  /// A key press. Only sent to a view that set `keys` in its manifest.
  factory ViewEvent.key(String key) => ViewEvent(type: 'key', key: key);

  /// The user answered a question the view asked. [accepted] is what they
  /// said, and it is sent either way — "no" is an answer, and a view that is
  /// only told about "yes" cannot tell it apart from a question that got lost.
  factory ViewEvent.answered(String id, bool accepted) =>
      ViewEvent(type: 'answered', id: id, accepted: accepted);

  final String type;

  /// Index into the rows — or the segments — the view last returned.
  final int? row;

  /// The key, named the way the manifest documents: `enter`, `escape`,
  /// `backspace`, `up`, `down`, `left`, `right`, or the character typed.
  final String? key;

  /// Which button was pressed, for a `button` event.
  final String? id;

  /// Which part of a split the event came from, empty when the content is not
  /// one. A row number answers "which row" and says nothing about which of
  /// three lists it was in — see [ContentPart].
  final String part;

  /// What the user said, for an `answered` event.
  final bool? accepted;

  /// What was deleted, for a `deleted` event.
  final List<VfsPath> paths;

  /// What a form held when its button was pressed, by field id.
  final Map<String, Object?> values;

  /// Where a `drop` came from. Empty for every other event.
  final String from;

  /// Which rows of [part] are picked out, in the order they are drawn.
  ///
  /// **Sent with every event from a listing**, so a view that can act on
  /// several rows never has to ask which ones: what is marked is what the
  /// press is about, exactly as it is in a panel. Empty when nothing is
  /// marked, which is the ordinary case and means "the row it happened on".
  final List<int> marked;

  Map<String, dynamic> toJson() => {
        'type': type,
        if (row != null) 'row': row,
        if (key != null) 'key': key,
        if (id != null) 'id': id,
        if (accepted != null) 'accepted': accepted,
        if (part.isNotEmpty) 'part': part,
        if (paths.isNotEmpty)
          'urls': [for (final path in paths) path.toString()],
        if (values.isNotEmpty) 'values': values,
        if (marked.isNotEmpty) 'marked': marked,
        if (from.isNotEmpty) 'from': from,
      };
}

/// Which panel a [HostAction] is about.
enum ActionTarget {
  /// The panel the view is in — which for a full-screen view is the active one.
  self,

  /// The other panel. What a view in a panel usually means: the user pressed
  /// something here, so show it over there.
  ///
  /// A full-screen view has no panel beside it, so there is nothing for this
  /// to contrast with; there it means the panel that was being worked in —
  /// the one the user comes back to when the view is closed.
  other,

  left,
  right;

  static ActionTarget parse(Object? name) {
    for (final target in ActionTarget.values) {
      if (target.name == name) return target;
    }
    return ActionTarget.other;
  }
}

/// What a view asks the host to do after handling an event.
///
/// A plugin cannot drive the application directly — it is a separate process
/// that cannot draw and does not know what else is on screen. It returns
/// intentions instead, and the host carries out the ones that make sense where
/// the view happens to be: "go to this folder" means something different full
/// screen than it does in the left panel, and the host is what knows which.
enum HostActionKind {
  /// Put a question to the user and tell the view what they said.
  ///
  /// **The one way a plugin gets to ask anything.** A plugin cannot draw, so
  /// it cannot put up a dialog; and a plugin that could would be a plugin
  /// whose dialogs look like nothing else in the application. It describes the
  /// question, the host asks it in its own words and its own shapes, and the
  /// answer comes back as an `answered` event — the same round trip `delete`
  /// already makes, and for the same reason: what the user said is a fact, not
  /// something to be assumed.
  ask,

  /// Send a panel to a location.
  navigate,

  /// Open a file in the viewer, as F3 would.
  view,

  /// A line of feedback along the bottom of the window.
  notice,

  /// Re-read the panel the action is aimed at.
  refresh,

  /// Close the view itself.
  close,

  /// Put what comes with this answer on top of what is on screen, as a page of
  /// its own.
  ///
  /// A view is one page, and that was enough until a page had a second thing
  /// to do — a log, and the commit being written out of it. The host keeps
  /// what was there, draws Back where a full-screen view already has it, and
  /// Escape goes back a page before it closes anything. **The plugin does not
  /// have to draw its way out again**: the page underneath is held here, so
  /// going back is drawing rather than another round trip.
  page,

  /// Go back a page, as Escape would. What a view asks for when the page it
  /// pushed is finished — a commit written, a form cancelled.
  back,

  /// Take the view out of the panel it is in and give it the whole window.
  ///
  /// The same thing Ctrl+Shift+Enter does, asked for by the view rather than
  /// by the user: what it is for is a page that does not fit in half a window
  /// — a form beside two lists and a difference — and a tool that drew one
  /// there anyway would be a tool nobody could read. Ignored when the view is
  /// already full screen, and when it has no full-screen surface to go to.
  fullscreen,

  /// Delete a set of paths. The *host* does it: it asks the user first, sends
  /// what it can to the recycle bin, and reports the result — the same path a
  /// press of F8 takes. A plugin that could delete on its own would be a
  /// plugin that could delete without asking.
  delete,

  /// Something a newer app understands and this one does not.
  unknown;

  static HostActionKind parse(Object? name) {
    for (final kind in HostActionKind.values) {
      if (kind != HostActionKind.unknown && kind.name == name) return kind;
    }
    return HostActionKind.unknown;
  }
}

/// One instruction from a view to the host.
class HostAction {
  const HostAction({
    required this.kind,
    this.target = ActionTarget.other,
    this.path,
    this.message,
    this.paths = const [],
    this.id,
    this.title,
    this.confirmLabel,
    this.danger = false,
    this.name,
    this.back,
  });

  factory HostAction.fromJson(Map<String, dynamic> json) {
    final url = json['url'] as String?;
    return HostAction(
      kind: HostActionKind.parse(json['type']),
      target: ActionTarget.parse(json['panel']),
      path: url == null || url.isEmpty ? null : VfsPath.parse(url),
      message: json['message'] as String?,
      id: json['id'] as String?,
      title: json['title'] as String?,
      name: json['name'] as String?,
      back: json['back'] as String?,
      confirmLabel: json['confirm'] as String?,
      danger: json['danger'] as bool? ?? false,
      paths: [
        for (final url in (json['urls'] as List?) ?? const [])
          if (url is String && url.isNotEmpty) VfsPath.parse(url),
      ],
    );
  }

  final HostActionKind kind;
  final ActionTarget target;
  final VfsPath? path;
  final String? message;

  /// For [HostActionKind.ask]: what the answer is about, handed back with it.
  /// Without one the view would have to guess which question was answered.
  final String? id;

  /// The question itself. [message] is the line under it.
  final String? title;

  /// What the button that agrees says — "Switch", "Discard", "Stage".
  ///
  /// A plugin names it because only the plugin knows what agreeing *does*, and
  /// a dialog whose buttons say Yes and No makes the reader work out which one
  /// they want from the question they have just read.
  final String? confirmLabel;

  /// Whether agreeing cannot be undone. The host draws it differently and does
  /// not make it the easy answer.
  final bool danger;

  /// For [HostActionKind.navigate]: the row to leave the cursor on once the
  /// panel gets there.
  ///
  /// **"Show me this file" is a place plus a name.** A panel can only be sent
  /// to somewhere that lists, so a tool pointing at a file sends the folder it
  /// is in and says which row it means — and the host does not have to ask a
  /// provider what kind of thing it was, which for a plugin's own file system
  /// is a round trip to another process to learn what the plugin already knew.
  final String? name;

  /// For [HostActionKind.navigate] onto the view's *own* panel: what the way
  /// back out of it should be called.
  ///
  /// **A view that hands its panel over is a view that has gone.** The panel
  /// cannot be in a folder and hold a tool at once, so sending itself
  /// somewhere is the tool closing — and until now that was a one-way door:
  /// the git tool put a panel into a commit and there was nothing left on
  /// screen that knew a log had ever been there.
  ///
  /// The host remembers the way back; the *view* names it, because only the
  /// view knows what it was — "Back to commits", not "Back". Left out, the
  /// host uses the view's own title.
  final String? back;

  /// The set an action works on, for the ones that take more than one thing.
  final List<VfsPath> paths;
}

/// A view's answer: what to draw now, and what to ask of the host.
///
/// Both parts are optional. A view that only wants the other panel moved
/// returns actions and no content, and the host leaves what is on screen alone
/// rather than blanking it.
/// A button a view puts in the application's title bar.
///
/// Sits between the tools icons and the window buttons, which is where the
/// application's own actions have always gone — a view full screen *is* the
/// application for as long as it is up. Pressing one raises the same `button`
/// event a chart button does, so a plugin has one kind of thing to answer.
class ViewCommand {
  const ViewCommand({
    required this.id,
    required this.label,
    this.icon,
    this.tooltip,
    this.items = const [],
  });

  factory ViewCommand.fromJson(Map<String, dynamic> json) => ViewCommand(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        icon: json['icon'] as String?,
        tooltip: json['tooltip'] as String?,
        items: [
          for (final item in (json['items'] as List?) ?? const [])
            if (item is Map)
              ViewMenuItem.fromJson(Map<String, dynamic>.from(item)),
        ],
      );

  final String id;
  final String label;

  /// A name from the host's icon set, as everywhere else a plugin names one.
  /// Without one the [label] is drawn instead, as a pill.
  final String? icon;

  final String? tooltip;

  /// What drops out of it when it is pressed.
  ///
  /// A command with items is the shape the path bar's own drive button has:
  /// **it says where you are and opens the way to somewhere else**, in one
  /// button rather than in a list down the side of the window. Picking a row
  /// raises the same `button` event a plain command does, carrying that row's
  /// id — so a plugin answers a pill the way it answers everything else.
  final List<ViewMenuItem> items;

  /// A command with no icon is drawn as a pill saying its label. There is
  /// nothing to be gained from a plugin declaring which of the two it wants:
  /// an icon is a glyph and a label is words, and a button cannot be both
  /// without being wider than either is worth.
  bool get isPill => icon == null && label.isNotEmpty;
}

/// One row of a [ViewMenu].
///
/// A row with no [id] and no [items] is a separator, which is how a plugin
/// writes one without a second shape to send. [items] makes it a submenu.
class ViewMenuItem {
  const ViewMenuItem({
    this.id,
    this.label = '',
    this.shortcut,
    this.enabled = true,
    this.checked,
    this.items = const [],
  });

  factory ViewMenuItem.fromJson(Map<String, dynamic> json) => ViewMenuItem(
        id: json['id'] as String?,
        label: json['label']?.toString() ?? '',
        shortcut: json['shortcut'] as String?,
        enabled: json['enabled'] as bool? ?? true,
        checked: json['checked'] as bool?,
        items: [
          for (final item in (json['items'] as List?) ?? const [])
            if (item is Map) ViewMenuItem.fromJson(Map<String, dynamic>.from(item)),
        ],
      );

  final String? id;
  final String label;

  /// Shown right-aligned. Informational: the host does not bind it, because a
  /// key the host does not own is a key it cannot promise.
  final String? shortcut;

  final bool enabled;

  /// Non-null draws a checkbox, for the settings a view keeps of its own.
  final bool? checked;

  final List<ViewMenuItem> items;

  bool get isSeparator => id == null && items.isEmpty;
}

/// A drop-down a view puts in the title bar while it is full screen.
///
/// **A view's menu replaces the application's, it does not join it.** Full
/// screen, the application is the view; File, Mark and Commands are about a
/// listing that is not on screen. A view that declares none leaves the strip
/// empty — the mark and the title, and nothing else.
class ViewMenu {
  const ViewMenu({
    required this.label,
    this.accelerator,
    this.items = const [],
  });

  factory ViewMenu.fromJson(Map<String, dynamic> json) => ViewMenu(
        label: json['label']?.toString() ?? '',
        accelerator: (json['accelerator'] as String?)?.toLowerCase(),
        items: [
          for (final item in (json['items'] as List?) ?? const [])
            if (item is Map) ViewMenuItem.fromJson(Map<String, dynamic>.from(item)),
        ],
      );

  final String label;

  /// The letter that opens it with Alt held. Given rather than taken from the
  /// label, for the reason `TitleBarMenu` gives: accelerators that depend on
  /// the order of the titles move when a title is added.
  final String? accelerator;

  final List<ViewMenuItem> items;
}

class ViewResponse {
  const ViewResponse({
    this.content,
    this.title,
    this.status,
    this.trail = const [],
    this.actions = const [],
    this.menus = const [],
    this.commands = const [],
    this.contextMenu = const [],
    this.saidTrail = false,
    this.saidMenus = false,
    this.saidCommands = false,
  });

  /// Reads either shape a plugin may return.
  ///
  /// A bare content object — the same thing `viewer.open` returns — is the
  /// common answer and is accepted as one, so a view that draws and asks for
  /// nothing reads exactly like a viewer. The envelope with `content`,
  /// `actions`, `title` and `status` is for when it wants more.
  factory ViewResponse.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('kind') && !json.containsKey('content')) {
      return ViewResponse(content: ViewerContent.fromJson(json));
    }

    final content = json['content'];
    return ViewResponse(
      // Whether the view *mentioned* each of these, which is not the same as
      // whether it sent any. Kept-until-replaced is right — a view answering a
      // click should not have to send its whole chrome again — but it left no
      // way to take one away, and a tool that walks out of a repository has to
      // be able to put the branch pill away with it.
      saidTrail: json.containsKey('trail'),
      saidMenus: json.containsKey('menus'),
      saidCommands: json.containsKey('commands'),
      content: content is Map
          ? ViewerContent.fromJson(Map<String, dynamic>.from(content))
          : null,
      title: json['title'] as String?,
      status: json['status'] as String?,
      trail: [
        for (final step in (json['trail'] as List?) ?? const [])
          if (step != null) step.toString(),
      ],
      actions: [
        for (final action in (json['actions'] as List?) ?? const [])
          if (action is Map)
            HostAction.fromJson(Map<String, dynamic>.from(action)),
      ],
      menus: [
        for (final menu in (json['menus'] as List?) ?? const [])
          if (menu is Map) ViewMenu.fromJson(Map<String, dynamic>.from(menu)),
      ],
      commands: [
        for (final command in (json['commands'] as List?) ?? const [])
          if (command is Map)
            ViewCommand.fromJson(Map<String, dynamic>.from(command)),
      ],
      contextMenu: [
        for (final item in (json['contextMenu'] as List?) ?? const [])
          if (item is Map) ViewMenuItem.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
  }

  factory ViewResponse.error(String message) =>
      ViewResponse(content: ViewerContent.error(message));

  final ViewerContent? content;

  /// A title the view chose for itself — the folder it is showing, say. Null
  /// leaves whatever the spec declared.
  final String? title;

  /// One line along the bottom of the view: totals, progress, what is selected.
  final String? status;

  /// What to put under the pointer, for a `mark` event and nothing else.
  ///
  /// **The secondary press asks a question rather than doing a thing.** It
  /// used to be a gesture whose meaning each view chose in private — in the
  /// git log it sent the other panel into a commit, and two rows lower, in the
  /// working tree, the same press staged a file. Neither said so. A view that
  /// answers `mark` with items gets them drawn where the user clicked, and
  /// picking one raises the ordinary `button` event; a view that answers with
  /// none keeps whatever it did before.
  final List<ViewMenuItem> contextMenu;

  /// Where the view has walked to, outermost first, drawn where a panel keeps
  /// its path — and pressed the same way, raising `step` with the index.
  ///
  /// A view that has gone into something has the panel's own problem, so it
  /// gets the panel's own answer rather than an idea of its own. Empty leaves
  /// the plain [title] in its place.
  final List<String> trail;

  final List<HostAction> actions;

  /// The view's own main menu, shown while it is full screen.
  ///
  /// Omitting it leaves whatever was there: a view that answers a click with
  /// new content should not have to send its menu again to keep it. **Sending
  /// an empty one takes it away** — see [saidMenus].
  final List<ViewMenu> menus;

  /// Buttons for the title bar and the pills for the path bar.
  final List<ViewCommand> commands;

  /// Whether the answer mentioned the trail at all, however empty.
  final bool saidTrail;
  final bool saidMenus;
  final bool saidCommands;
}

/// A view redrawing itself, without having been asked.
///
/// The one thing a request/response protocol cannot express, and the thing a
/// disk map needs most: a scan of a whole drive takes longer than any sensible
/// call timeout, so the view answers at once with what little it knows and
/// pushes the rest as it finds it. [session] says which open copy it is about,
/// and an update for a session nobody is holding is simply dropped.
class ViewUpdate {
  const ViewUpdate({
    required this.viewId,
    required this.session,
    required this.response,
  });

  final String viewId;
  final String session;
  final ViewResponse response;
}

/// A view offered by a loaded plugin, ready to be opened.
class RegisteredView {
  const RegisteredView({
    required this.spec,
    required this.pluginId,
    required this.pluginName,
    required this.open,
    required this.handle,
    required this.close,
    required this.updates,
  });

  final ViewSpec spec;
  final String pluginId;
  final String pluginName;

  /// Asks the plugin to draw the view for a context.
  final Future<ViewResponse> Function(ViewContext context) open;

  /// Hands the plugin something the user did.
  final Future<ViewResponse> Function(ViewContext context, ViewEvent event)
      handle;

  /// Tells the plugin the session is over, so it can drop whatever it cached.
  final Future<void> Function(String session) close;

  /// Redraws the plugin pushed for this view, of its own accord.
  final Stream<ViewUpdate> updates;

  String get id => spec.id;

  /// What to call this view, in the language now in force.
  String get title => saidBy(pluginId, spec.title);
}
