import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../i18n/plugin_strings.dart' as strings;
import 'package:path/path.dart' as p;

import '../i18n/i18n.dart';
import '../version.dart';
import 'grammar.dart';

/// API contract version understood by this build of xverb.
///
/// Plugins declare the version they were written against and are refused if it
/// does not match. It is the host's **major version** and not a number of its
/// own: a plugin declaring `apiVersion: 1` runs on every xverb `1.*.*.*`, and
/// the way to say "the protocol has broken" is to move the major. That is what
/// the major is *for* — see the head of `core/version.dart`.
///
/// Derived rather than written out a second time, deliberately: the two were
/// independent constants in two files, kept level by nothing but the intention
/// to remember.
const int kPluginApiVersion = kMajor;

/// A command a plugin contributes to the command palette and key bindings.
class PluginCommandSpec {
  const PluginCommandSpec({
    required this.id,
    required this.title,
    this.description,
    this.icon,
    this.inTitleBar = false,
  });

  factory PluginCommandSpec.fromJson(Map<String, dynamic> json) =>
      PluginCommandSpec(
        id: json['id'] as String,
        title: json['title'] as String? ?? json['id'] as String,
        description: json['description'] as String?,
        icon: json['icon'] as String?,
        inTitleBar: json['inTitleBar'] as bool? ?? false,
      );

  final String id;
  final String title;
  final String? description;

  /// Icon to draw for this command, from the set the host knows.
  final String? icon;

  /// Whether this command wants a button in the application's title bar.
  ///
  /// Off unless asked for. The title bar is small and shared, so appearing
  /// there is a claim a plugin has to make deliberately — most commands belong
  /// in the menu and nowhere else.
  final bool inTitleBar;
}

/// A place in the application a plugin's contribution can occupy.
///
/// The set is deliberately closed: a surface is somewhere the host already
/// knows how to put something, not a coordinate a plugin invents. What a
/// contribution declares here is what the user is then offered in its settings
/// — a viewer cannot be talked into the Tools menu, because being chosen from
/// a menu is not how a file gets viewed.
enum PluginSurface {
  /// A page of its own, over the whole client area.
  fullscreen,

  /// One of the two file panels, in place of its listing. The other panel goes
  /// on being a file panel, which is the point: navigate on one side, look at
  /// the result on the other.
  panel,

  /// The menu a panel drops on Alt+F1 / Alt+F2, under the drives and the saved
  /// connections. Somewhere a panel can be *sent*, so anything here has to be
  /// able to open in a panel as well.
  locations,

  /// The Tools menu, filed under the plugin's category.
  menu,

  /// An icon in the application's title bar. Small and shared, so it is asked
  /// for rather than assumed.
  titleBar;

  String get label => switch (this) {
        PluginSurface.fullscreen => tr('Full screen'),
        PluginSurface.panel => tr('Panel'),
        PluginSurface.locations => tr('Location menu'),
        PluginSurface.menu => tr('Tools menu'),
        PluginSurface.titleBar => tr('Title bar'),
      };

  static PluginSurface? parse(Object? name) {
    for (final surface in PluginSurface.values) {
      if (surface.name == name) return surface;
    }
    return null;
  }

  /// Parses a list of names, dropping anything this build does not know.
  ///
  /// Dropping rather than refusing is what lets a newer plugin load on an older
  /// app: it simply reaches fewer places than its author intended.
  static List<PluginSurface> parseAll(Object? json) => [
        for (final name in (json as List?) ?? const []) ?parse(name),
      ];
}

/// What a view wants to be pointed at as the user moves about.
enum ViewFollows {
  /// Nothing. The view is opened with a location and keeps it until it asks to
  /// move — a disk map does not want to reset every time a cursor twitches.
  none,

  /// The directory the other panel is in.
  location,

  /// The entry under the other panel's cursor. This is what makes a panel a
  /// viewport: navigate on the left, and the right side shows what is under
  /// the cursor.
  cursor;

  static ViewFollows parse(Object? name) {
    for (final value in ViewFollows.values) {
      if (value.name == name) return value;
    }
    return ViewFollows.none;
  }
}

/// A surface of a plugin's own: something the user opens and looks at, which is
/// not a file being viewed.
///
/// A viewer answers "what is in this file"; a view answers anything else — a
/// map of the disk, a comparison of two folders, a queue of transfers. It is a
/// separate contribution because the two are asked for in different ways: F3 on
/// a file resolves a viewer, whereas a view is chosen by name from a menu, sent
/// to a panel, or opened full screen.
class ViewSpec {
  const ViewSpec({
    required this.id,
    required this.title,
    this.description,
    this.icon,
    this.surfaces = const [PluginSurface.fullscreen],
    this.follows = ViewFollows.none,
    this.wantsKeys = false,
    this.wantsCursor = false,
  });

  factory ViewSpec.fromJson(Map<String, dynamic> json) {
    final declared = PluginSurface.parseAll(json['surfaces']);
    return ViewSpec(
      id: json['id'] as String,
      title: json['title'] as String? ?? json['id'] as String,
      description: json['description'] as String?,
      icon: json['icon'] as String?,
      // A view that names no surface is a full-screen one. That is the surface
      // with no prerequisites: it needs no panel to take over and nothing to
      // follow.
      surfaces:
          declared.isEmpty ? const [PluginSurface.fullscreen] : declared,
      follows: ViewFollows.parse(json['follows']),
      wantsKeys: json['keys'] as bool? ?? false,
      wantsCursor: json['cursor'] as bool? ?? false,
    );
  }

  final String id;
  final String title;
  final String? description;

  /// Icon to draw for this view, from the set the host knows.
  final String? icon;

  /// Where this view *can* appear. Also where it appears by default: a plugin
  /// that does not want to be in the location menu leaves it out, and the
  /// user's own choice can only narrow this, never widen it past what the view
  /// says it can do.
  final List<PluginSurface> surfaces;

  /// What the host re-points this view at as the user moves about the other
  /// panel. Only meaningful in [PluginSurface.panel].
  final ViewFollows follows;

  /// Whether key presses reach the view while it has the panel.
  ///
  /// Off by default, and that is the safe default: the panel's own keys — Tab,
  /// the function row, quick search — go on working, and a view only takes
  /// them over if it says it can use them.
  final bool wantsKeys;

  /// Whether the view is told when the cursor settles on a row of one of its
  /// tables.
  ///
  /// Off by default and asked for by name, because it costs a round trip every
  /// time somebody stops moving and most views have nothing to do with it. What
  /// it is *for* is a page of several parts: the log above, and what the
  /// commit under the cursor touched below, following along without anything
  /// being pressed. That is what a history tool feels like, and it cannot be
  /// built out of `activate` — which means Enter, and means the reader had to
  /// ask for each one.
  ///
  /// The settling is the host's and is not negotiable: holding an arrow key
  /// walks a listing a row at a time, and a plugin asked about every row on
  /// the way is a plugin that cannot keep up. Same 120 ms the panel viewport
  /// has always waited.
  final bool wantsCursor;

  bool canAppearIn(PluginSurface surface) => surfaces.contains(surface);

  /// True when the host can put this view in a panel, which the location menu
  /// also needs — that menu's entries are places a panel goes.
  bool get isPanelCapable => canAppearIn(PluginSurface.panel);
}

/// How a plugin's contributions are executed.
enum PluginRuntime {
  /// A Python process the host talks to over JSON-RPC. Desktop only.
  python,

  /// Pure data: the plugin names built-in render primitives and configures
  /// them. No code runs, so these load on every platform — including iOS,
  /// where executing downloaded code is not permitted.
  declarative,

  /// Something this build does not know how to run.
  unknown;

  static PluginRuntime parse(String? value) => switch (value) {
        'python' => PluginRuntime.python,
        'declarative' => PluginRuntime.declarative,
        _ => PluginRuntime.unknown,
      };

  String get label => switch (this) {
        PluginRuntime.python => 'Python',
        PluginRuntime.declarative => tr('Declarative'),
        PluginRuntime.unknown => tr('Unknown'),
      };
}

/// Kind of input a field a plugin declared wants.
enum PluginFieldType { text, password, integer, boolean, choice, remotePath }

/// One of the answers a [PluginFieldType.choice] field will accept.
class FieldOption {
  const FieldOption({required this.value, required this.label});

  factory FieldOption.fromJson(Object? json) {
    if (json is Map) {
      final map = Map<String, dynamic>.from(json);
      final value = map['value']?.toString() ?? '';
      return FieldOption(
        value: value,
        label: map['label'] as String? ?? value,
      );
    }
    // A bare string is both the stored value and the label, which is what most
    // choices are: `"options": ["left", "right"]`.
    final value = json?.toString() ?? '';
    return FieldOption(value: value, label: value);
  }

  final String value;
  final String label;
}

/// One input in a form a plugin declared — a connection's, or its own settings.
///
/// The same shape serves both because the principle is the same: the plugin
/// says what it needs, the host draws it. A transport asking for a host name
/// and a viewer asking for a tab width are the same problem.
class PluginField {
  const PluginField({
    required this.key,
    required this.label,
    this.type = PluginFieldType.text,
    this.hint,
    this.required = false,
    this.defaultValue,
    this.hiddenWhen,
    this.note,
    this.options = const [],
    this.minimum,
    this.maximum,
    this.step,
  });

  factory PluginField.fromJson(Map<String, dynamic> json) => PluginField(
        key: json['key'] as String,
        label: json['label'] as String? ?? json['key'] as String,
        type: switch (json['type'] as String?) {
          'password' => PluginFieldType.password,
          'integer' => PluginFieldType.integer,
          'boolean' => PluginFieldType.boolean,
          'choice' => PluginFieldType.choice,
          'remotePath' => PluginFieldType.remotePath,
          _ => PluginFieldType.text,
        },
        hint: json['hint'] as String?,
        required: json['required'] as bool? ?? false,
        defaultValue: json['default'],
        hiddenWhen: json['hiddenWhen'] as String?,
        note: json['note'] as String?,
        options: ((json['options'] as List?) ?? const [])
            .map(FieldOption.fromJson)
            .toList(),
        minimum: (json['minimum'] as num?)?.toInt(),
        maximum: (json['maximum'] as num?)?.toInt(),
        step: (json['step'] as num?)?.toInt(),
      );

  final String key;
  final String label;
  final PluginFieldType type;
  final String? hint;
  final bool required;
  final Object? defaultValue;

  /// The same field with its words in the user's language.
  ///
  /// A copy rather than a lookup at every drawing site: the form widgets are
  /// shared with the connection dialogs and with a plugin's own forms, and a
  /// plugin id threaded through all of them to reach three strings would be a
  /// parameter on everything for the sake of a translation.
  PluginField saidBy(String pluginId) => PluginField(
    key: key,
    label: strings.saidBy(pluginId, label),
    type: type,
    hint: strings.saidByOrNull(pluginId, hint),
    required: required,
    defaultValue: defaultValue,
    hiddenWhen: hiddenWhen,
    note: strings.saidByOrNull(pluginId, note),
    options: [
      for (final option in options)
        FieldOption(
          value: option.value,
          label: strings.saidBy(pluginId, option.label),
        ),
    ],
    minimum: minimum,
    maximum: maximum,
    step: step,
  );

  /// Key of a boolean field that hides this one when it is on — how "user name"
  /// disappears once anonymous login is ticked.
  final String? hiddenWhen;

  /// Small print under the input, e.g. a warning about stored passwords.
  final String? note;

  /// What a [PluginFieldType.choice] may be set to. Empty for every other kind.
  final List<FieldOption> options;

  /// The ends of a whole-number setting, and how far one move goes.
  ///
  /// **Declaring both ends is what turns a box into a slider.** A number with
  /// a range is a number somebody can be shown the whole of; a number without
  /// one — how many commits to read — has no end to draw. The step is what a
  /// meaningful move is, which only the plugin knows: a font weight moves by a
  /// hundred because that is the granularity a family has.
  final int? minimum;
  final int? maximum;
  final int? step;

  /// Whether this one is drawn as a slider rather than as something typed in.
  bool get hasRange =>
      type == PluginFieldType.integer &&
      minimum != null &&
      maximum != null &&
      maximum! > minimum!;
}

/// A kind of connection a plugin can open, described well enough for the host
/// to render the whole dialog.
///
/// The core has no idea what FTP needs; it only knows how to draw a form from
/// this and hand the answers back. That is what keeps transports in plugins
/// while still giving them a first-class connection manager.
class ConnectionSpec {
  const ConnectionSpec({
    required this.id,
    required this.title,
    required this.scheme,
    this.storeFile = 'connections.ini',
    this.fields = const [],
  });

  factory ConnectionSpec.fromJson(Map<String, dynamic> json) => ConnectionSpec(
        id: json['id'] as String,
        title: json['title'] as String? ?? json['id'] as String,
        scheme: json['scheme'] as String? ?? '',
        storeFile: json['storeFile'] as String? ?? 'connections.ini',
        fields: ((json['fields'] as List?) ?? const [])
            .map((e) =>
                PluginField.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );

  final String id;
  final String title;

  /// URI scheme the resulting connection lives under.
  final String scheme;

  /// INI file these connections are kept in, inside the app's connections
  /// directory. Each transport gets its own so the files stay hand-editable.
  final String storeFile;

  /// The form, in the order it should be shown.
  ///
  /// Four keys are structural and become parts of the URL: `host`, `port`,
  /// `user` and `password`, plus `remoteDir` for the starting path. Every
  /// other field is passed to the plugin as a query parameter, so a transport
  /// can add options without the host knowing anything about them.
  final List<PluginField> fields;

  static const String hostKey = 'host';
  static const String portKey = 'port';
  static const String userKey = 'user';
  static const String passwordKey = 'password';
  static const String pathKey = 'remoteDir';

  static const Set<String> structuralKeys = {
    hostKey,
    portKey,
    userKey,
    passwordKey,
    pathKey,
  };
}

/// A viewer a plugin contributes, claiming a set of file types.
///
/// The core has no viewer of its own — pressing F3 resolves one of these. A
/// plugin may register several (an image viewer and a text viewer, say), and
/// several plugins may claim the same extension; [priority] breaks the tie and
/// the user can always pick another with Shift+F3.
/// A plugin's offer to say what a file says about itself. See `facts.dart`.
///
/// **Claims by extension only.** There is no priority and no probe: a file has
/// one set of facts and the first plugin that understands the format answers
/// for it, so an order to settle would be an order between plugins that both
/// claim to read EXIF — which is a collision to report, not a race to run.
class DescriberSpec {
  const DescriberSpec({
    required this.id,
    required this.title,
    this.extensions = const [],
    this.names = const [],
  });

  factory DescriberSpec.fromJson(Map<String, dynamic> json) => DescriberSpec(
    id: json['id'] as String,
    title: json['title'] as String? ?? json['id'] as String,
    extensions: ((json['extensions'] as List?) ?? const [])
        .map((e) => e.toString().toLowerCase().replaceFirst('.', ''))
        .toList(),
    names: ((json['names'] as List?) ?? const [])
        .map((e) => e.toString().toLowerCase())
        .toList(),
  );

  final String id;

  /// What the panel is called while it is showing this — "About this picture",
  /// "About this recording". The plugin names it because the plugin knows what
  /// kind of thing it is describing.
  final String title;

  final List<String> extensions;
  final List<String> names;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'extensions': extensions,
    'names': names,
  };

  /// Whether this describer answers for a file called [fileName].
  bool claims(String fileName) {
    final lower = fileName.toLowerCase();
    if (names.contains(lower)) return true;
    final dot = lower.lastIndexOf('.');
    if (dot < 0 || dot == lower.length - 1) return false;
    return extensions.contains(lower.substring(dot + 1));
  }
}

class ViewerSpec {
  const ViewerSpec({
    required this.id,
    required this.title,
    this.extensions = const [],
    this.names = const [],
    this.priority = 0,
    this.fallback = false,
    this.probe = false,
    this.produces = '',
    this.thumbnails = false,
    this.render,
  });

  factory ViewerSpec.fromJson(Map<String, dynamic> json) => ViewerSpec(
        id: json['id'] as String,
        title: json['title'] as String? ?? json['id'] as String,
        extensions: ((json['extensions'] as List?) ?? const [])
            .cast<String>()
            .map((e) => e.toLowerCase().replaceFirst('.', ''))
            .toList(),
        names: ((json['names'] as List?) ?? const [])
            .map((e) => e.toString().toLowerCase())
            .toList(),
        priority: (json['priority'] as num?)?.toInt() ?? 0,
        fallback: json['fallback'] as bool? ?? false,
        probe: json['probe'] as bool? ?? false,
        produces: (json['produces'] as String? ?? '').trim().toLowerCase(),
        thumbnails: json['thumbnails'] as bool? ?? false,
        render: json['render'] is Map
            ? Map<String, dynamic>.from(json['render'] as Map)
            : null,
      );

  final String id;
  final String title;

  /// Only for declarative plugins: which built-in primitive to run and how.
  /// Ignored by Python plugins, which produce content themselves.
  final Map<String, dynamic>? render;

  /// Lower-case extensions without the dot. `*` claims everything, which is how
  /// a generic hex or text viewer offers itself as a last resort.
  final List<String> extensions;

  /// Whole file names this one is for, lower-cased.
  ///
  /// **Some files are known by their name and have no extension at all** —
  /// `LICENSE`, `Makefile`, `Dockerfile`, `COMMIT_EDITMSG`. Nothing could claim
  /// those, so they fell to whatever takes what is left, and a viewer with a
  /// grammar for them could not say so.
  final List<String> names;

  /// **What kind of thing this viewer gives back** — `picture`, `sound`,
  /// `document`, `drawing`, `model`. A free word, matched exactly, and the host
  /// has no list of them: what it is *for* is telling two viewers that they are
  /// in the same business.
  ///
  /// **Which the film strip is the whole reason for.** A folder of `.jpg`
  /// beside `.heic` was two strips, because those extensions belong to
  /// different plugins — the machine's own decoder reads one and a Python
  /// reader the other — and a strip that stops at the first `.heic` is a strip
  /// that lies about the folder. Walking "what this viewer opens" was right
  /// until two viewers opened the same *kind* of thing; now they walk it
  /// together.
  ///
  /// Empty means "this viewer is its own kind", which is what everything
  /// written before this existed says, and it keeps its old strip exactly.
  final String produces;

  /// **Whether this viewer will hand back a small copy of a file** — see
  /// [RegisteredViewer.thumbnail].
  ///
  /// The strip along the bottom of a viewer gets its pictures from the
  /// machine's own decoder, which is fast and knows nothing about the formats
  /// it does not read: `.xcf` nowhere, `.psd` and `.tga` on macOS only. Those
  /// got a name in the cell instead of a picture. A viewer that reads the
  /// format anyway can be asked, and most formats carry a cheap preview inside
  /// them for exactly this.
  ///
  /// Asked **only after the engine has refused**, because the engine costs no
  /// process and no pipe.
  final bool thumbnails;

  /// Higher wins when more than one viewer claims a file.
  final int priority;

  /// Declared with `"fallback": true`.
  final bool fallback;

  /// Whether this viewer wants to be **asked about the file itself** before the
  /// order is settled — `"probe": true`.
  ///
  /// The third way of claiming, and the one the other two cannot express. A
  /// claim by extension names a *type*; a fallback takes what is left; a probe
  /// says **"I know it when I see it"**. Every node-graph format in the world
  /// is a `.json`, and `.json` rightly belongs to the text viewer — a graph
  /// reader that won it outright would open `package.json` as an empty canvas.
  /// Asked with the first pages of the file, the reader can answer for that one
  /// file and nothing else.
  ///
  /// It costs one round trip, and only on a file whose extension is already
  /// contested by somebody who declared this. Everything else is untouched:
  /// the answer is worked out from the extension, as it always was.
  final bool probe;

  /// Whether this one will take a file nothing else claims.
  ///
  /// `"*"` among the extensions says the same thing, and said it first. The
  /// difference is that a viewer may now do **both**: name the types it is
  /// really for *and* offer itself for anything else — which is what a text
  /// viewer is. Before this it had to choose, so everything unknown fell to
  /// the hex dump — which is wrong: an unknown file is shown as text, and hex
  /// is a place to go from there.
  bool get isFallback => fallback || extensions.contains('*');

  /// Whether this viewer names this file itself, rather than taking it because
  /// it takes everything. What decides the order — see
  /// `PluginRegistry.viewersFor`.
  bool claims(String extension, {String name = ''}) =>
      (extension.isNotEmpty && extensions.contains(extension.toLowerCase())) ||
      (name.isNotEmpty && names.contains(name.toLowerCase()));

  bool handles(String extension, {String name = ''}) =>
      isFallback || claims(extension, name: name);
}

/// A file type a plugin can open as a folder.
///
/// This is what makes Enter on `box.zip` step *into* the archive instead of
/// launching it: the plugin says "these extensions are really directories,
/// served under this scheme", and the core turns the file's location into one
/// of that scheme. The core learns nothing about ZIP in the process — the same
/// declaration would work for ISO images, 7z, or a mail folder.
class ContainerSpec {
  const ContainerSpec({
    required this.scheme,
    this.extensions = const [],
    this.title,
    this.packs = const [],
  });

  factory ContainerSpec.fromJson(Map<String, dynamic> json) => ContainerSpec(
        scheme: json['scheme'] as String,
        title: json['title'] as String?,
        extensions: ((json['extensions'] as List?) ?? const [])
            .cast<String>()
            .map((e) => e.toLowerCase().replaceFirst('.', ''))
            .toList(),
        packs: [
          for (final item in (json['packs'] as List?) ?? const [])
            if (item is Map) PackOption.fromJson(Map<String, dynamic>.from(item)),
        ],
      );

  /// The scheme the plugin serves these under, e.g. `zip`.
  final String scheme;

  final String? title;

  /// Lower-case extensions without the dot.
  final List<String> extensions;

  /// What this container can be asked to **create**, which is not the same
  /// list as what it can open.
  ///
  /// A `.gz` opens perfectly well and there is nothing sensible to create under
  /// that name; a tarball can be made four ways and only the plugin knows which
  /// and what to call them. So [extensions] answers "walk into this" and this
  /// answers "make me one of these".
  ///
  /// **Empty means it cannot be created**, and that is not a formality. This
  /// used to fall back to the first extension a container claimed, which put
  /// *Playlist · .m3u* in the list of archive kinds — the playlist plugin opens
  /// an `.m3u` as a folder and has no idea how to write one, and there is no
  /// reading of "can be entered" that implies "can be made". A plugin that
  /// wants to be offered says so here.
  final List<PackOption> packs;

  bool handles(String extension) =>
      extension.isNotEmpty && extensions.contains(extension.toLowerCase());
}

/// One archive a container offers to create: the extension, and what to call it
/// where a person is choosing.
///
/// The title is the plugin's to write because only the plugin knows what the
/// difference *is* — "Tarball, gzip" against "Tarball, xz" is a sentence about
/// compression that the application has no business composing.
@immutable
class PackOption {
  const PackOption({required this.extension, required this.title});

  factory PackOption.fromJson(Map<String, dynamic> json) => PackOption(
        extension: (json['extension'] as String? ?? '')
            .toLowerCase()
            .replaceFirst('.', ''),
        title: json['title'] as String? ?? json['extension'] as String? ?? '',
      );

  /// Lower-case, without the dot.
  final String extension;

  final String title;
}

/// The `plugin.json` sitting next to a plugin's entry point.
/// One scheme a plugin serves, and what a panel standing in it can do.
///
/// **Read-only is a thing to be told, not a thing to find out.** It used to be
/// discovered by pressing F8 and reading the refusal that came back, which is
/// the panel offering something it knows will fail. A scheme that says so up
/// front lets the keys that cannot work go dim and the panel say where it is
/// standing.
///
/// Written as a bare string when there is nothing to add — `"schemes": ["ftp"]`
/// — or as an object when there is: `{"scheme": "git", "writable": false,
/// "icon": "history"}`. Both forms are read here, so no existing manifest has
/// to change.
class SchemeSpec {
  const SchemeSpec({
    required this.scheme,
    this.isWritable = true,
    this.icon,
  });

  factory SchemeSpec.parse(Object? value) {
    if (value is Map) {
      final json = Map<String, dynamic>.from(value);
      return SchemeSpec(
        scheme: json['scheme']?.toString() ?? '',
        // Writable unless the plugin says otherwise: a transport that says
        // nothing is the ordinary case, and every one written before this
        // existed is one.
        isWritable: json['writable'] as bool? ?? true,
        icon: json['icon'] as String?,
      );
    }
    return SchemeSpec(scheme: value?.toString() ?? '');
  }

  final String scheme;

  final bool isWritable;

  /// What the panel draws beside the path while it stands in this scheme, from
  /// the same table every other plugin icon is named out of. Null draws
  /// nothing, which is what a transport that is simply another disk wants.
  final String? icon;
}

class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.apiVersion,
    required this.runtime,
    required this.entry,
    required this.directory,
    this.description,
    this.author,
    this.homepage,
    this.schemes = const [],
    this.commands = const [],
    this.views = const [],
    this.viewers = const [],
    this.describers = const [],
    this.grammars = const [],
    this.connections = const [],
    this.containers = const [],
    this.settings = const [],
    this.platforms = const [],
    this.pythonMin,
    this.icon,
    this.declaredCategory,
    this.isBundled = false,
  });

  factory PluginManifest.fromJson(
    Map<String, dynamic> json,
    String directory, {
    bool isBundled = false,
  }) {
    return PluginManifest(
      id: json['id'] as String,
      name: json['name'] as String? ?? json['id'] as String,
      version: json['version'] as String? ?? '0.0.0',
      apiVersion: (json['apiVersion'] as num?)?.toInt() ?? 0,
      runtime: PluginRuntime.parse(json['runtime'] as String? ?? 'python'),
      entry: json['entry'] as String? ?? 'main.py',
      directory: directory,
      isBundled: isBundled,
      description: json['description'] as String?,
      author: json['author'] as String?,
      homepage: json['homepage'] as String?,
      schemes: [
        for (final scheme in (json['schemes'] as List?) ?? const [])
          if (SchemeSpec.parse(scheme).scheme.isNotEmpty)
            SchemeSpec.parse(scheme),
      ],
      commands: (json['commands'] as List?)
              ?.map((e) => PluginCommandSpec.fromJson(
                  Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
      views: (json['views'] as List?)
              ?.map(
                  (e) => ViewSpec.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
      viewers: (json['viewers'] as List?)
              ?.map((e) =>
                  ViewerSpec.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
      describers: (json['describers'] as List?)
              ?.map((e) =>
                  DescriberSpec.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
      grammars: [
        for (final grammar in (json['grammars'] as List?) ?? const [])
          if (grammar is Map)
            SyntaxGrammar.fromJson(Map<String, dynamic>.from(grammar)),
      ],
      connections: (json['connections'] as List?)
              ?.map((e) =>
                  ConnectionSpec.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
      containers: (json['containers'] as List?)
              ?.map((e) =>
                  ContainerSpec.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
      settings: (json['settings'] as List?)
              ?.map((e) =>
                  PluginField.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          const [],
      platforms: (json['platforms'] as List?)?.cast<String>() ?? const [],
      pythonMin: json['pythonMin'] as String?,
      icon: json['icon'] as String?,
      declaredCategory: json['category'] as String?,
    );
  }

  /// Reads and parses `plugin.json` from a plugin directory.
  static Future<PluginManifest> load(Directory directory) async {
    final file = File(p.join(directory.path, 'plugin.json'));
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return PluginManifest.fromJson(json, directory.path);
  }

  /// Reverse-DNS identifier, unique across installed plugins.
  final String id;
  final String name;

  /// [name] in the language now in force — see `plugin_strings.dart`.
  ///
  /// **Drawn everywhere the raw one used to be.** A plugin's own words are the
  /// one place the application went on speaking English while it was set to
  /// something else, and a getter beside the field is what makes fixing that a
  /// change of one word at each call rather than a rule to remember.
  String get displayName => strings.saidBy(id, name);

  /// [description] in the language now in force, or null where there is none.
  String? get displayDescription => strings.saidByOrNull(id, description);

  final String version;
  final int apiVersion;

  final PluginRuntime runtime;

  /// Entry script, relative to [directory]. Unused by declarative plugins.
  final String entry;

  /// Absolute path of the directory holding the plugin, or the asset directory
  /// for a bundled one.
  final String directory;

  /// True for extensions shipped inside the app rather than installed by the
  /// user. Bundled extensions can be switched off but not deleted.
  final bool isBundled;

  final String? description;
  final String? author;
  final String? homepage;

  /// URI schemes this plugin serves, e.g. `ftp` and `ftps`, with what a panel
  /// standing in each of them is able to do.
  final List<SchemeSpec> schemes;

  final List<PluginCommandSpec> commands;

  /// Surfaces of the plugin's own — a disk map, a comparison, a queue — as
  /// opposed to [viewers], which answer F3 on a file.
  final List<ViewSpec> views;

  /// File viewers this plugin offers to F3.
  final List<ViewerSpec> viewers;

  /// What this plugin can say about a file it may well not be drawing — see
  /// [DescriberSpec] and `facts.dart`.
  final List<DescriberSpec> describers;

  /// Languages this plugin knows how to colour, as data.
  ///
  /// A contribution rather than a feature: nothing here draws anything, and
  /// whichever viewer shows a file — this plugin's or another's — the host
  /// colours it with whatever grammar claims the language. That is what makes
  /// a new language a block of data instead of a build.
  final List<SyntaxGrammar> grammars;

  /// Connection kinds this plugin can open, with the fields their dialog needs.
  final List<ConnectionSpec> connections;

  /// File types this plugin can open as a folder rather than as a file.
  final List<ContainerSpec> containers;

  /// The plugin's own settings, declared the same way its connection form is.
  ///
  /// The host stores the answers, shows them in the plugin manager, and hands
  /// them to the plugin at startup and again whenever they change. No plugin
  /// has to write a settings screen, and none can put one somewhere the user
  /// would not think to look.
  final List<PluginField> settings;

  /// The values a plugin runs on when the user has changed nothing.
  Map<String, Object?> get settingDefaults => {
        for (final field in settings)
          if (field.defaultValue != null) field.key: field.defaultValue,
      };

  /// Platforms the plugin supports. Empty means "all".
  final List<String> platforms;

  /// Which shelf this belongs on. Required of anything published; a plugin
  /// that arrives without one is filed by what it contributes rather than
  /// dropped, so an older extension keeps working.
  String get category {
    final declared = declaredCategory?.trim();
    if (declared != null && declared.isNotEmpty) return declared;
    if (containers.isNotEmpty) return 'Archives';
    if (schemes.isNotEmpty) return 'Transports';
    if (viewers.isNotEmpty) return 'Viewers';
    return 'Tools';
  }

  /// Exactly what the manifest said, before the fallback below is applied.
  final String? declaredCategory;

  /// The icon to draw beside this plugin: either a **name** from the small set
  /// the host knows, or the **file name of a picture** the plugin ships beside
  /// its manifest.
  ///
  /// Null is the ordinary case: the manager then picks one from what the plugin
  /// claims, which is right often enough that most manifests should leave it
  /// alone.
  ///
  /// Both forms were already in use and only one of them worked. `git` has
  /// shipped an `icon.png` and named it here since it was written, and the host
  /// looked the string up in its table of names, failed, and drew the generic
  /// shape — so the one plugin with a picture of its own was the one plugin
  /// whose picture was never shown. The two are told apart by the extension,
  /// because that is what tells them apart; a name from the table has none.
  final String? icon;

  /// [icon] when it names a picture on disk, or null when it names one of the
  /// host's own.
  ///
  /// The file sits beside the manifest, so it is [directory] plus this — and
  /// that holds wherever the manifest came from: an installed plugin, one in
  /// the app bundle, one inside a downloaded repository, or one remembered by
  /// the catalogue cache.
  String? get iconFile {
    final named = icon;
    if (named == null || named.isEmpty) return null;
    final lower = named.toLowerCase();
    for (final kind in const ['.png', '.jpg', '.jpeg', '.webp', '.gif']) {
      if (lower.endsWith(kind)) return named;
    }
    return null;
  }

  /// Lowest Python this plugin will run on, as `major.minor`. Null means the
  /// host's own floor is enough, which is the normal case — a plugin only
  /// needs this if it uses something newer than the version everyone targets.
  ///
  /// Declaring it buys a clear refusal in the plugin manager instead of a
  /// process that starts and dies on syntax the interpreter cannot parse.
  final String? pythonMin;

  /// True when [pythonMin] is satisfied by an interpreter reporting [version].
  /// A plugin that declares nothing is always satisfied.
  bool acceptsPython(String version) {
    final required = pythonMin;
    if (required == null) return true;
    final wanted = _minorPair(required);
    final actual = _minorPair(version);
    if (wanted == null || actual == null) return true;
    if (actual.$1 != wanted.$1) return actual.$1 > wanted.$1;
    return actual.$2 >= wanted.$2;
  }

  /// Orders two version strings the way a release sequence runs: negative when
  /// [a] came first, positive when [b] did, zero when they are the same.
  ///
  /// Numeric parts are compared as numbers, so 1.10.0 is later than 1.9.0 —
  /// which a string comparison gets backwards, and which is exactly the case
  /// an update check must not get wrong. A part that is not a number (`1.0.0b`,
  /// `2.0-rc1`) falls back to comparing it as text, and a shorter version is
  /// the earlier one when everything up to that point matches.
  static int compareVersions(String a, String b) {
    final left = a.trim().split('.');
    final right = b.trim().split('.');

    for (var i = 0; i < left.length || i < right.length; i++) {
      final one = i < left.length ? left[i] : '0';
      final two = i < right.length ? right[i] : '0';
      if (one == two) continue;

      final oneNumber = int.tryParse(one);
      final twoNumber = int.tryParse(two);
      if (oneNumber != null && twoNumber != null) {
        if (oneNumber != twoNumber) return oneNumber.compareTo(twoNumber);
        continue;
      }
      return one.compareTo(two);
    }
    return 0;
  }

  static (int, int)? _minorPair(String version) {
    final match = RegExp(r'(\d+)\.(\d+)').firstMatch(version);
    if (match == null) return null;
    return (int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  String get entryPath => p.join(directory, entry);

  bool get isCompatible => apiVersion == kPluginApiVersion;

  /// Declarative plugins need no interpreter and no child process.
  bool get needsPythonRuntime => runtime == PluginRuntime.python;

  /// True when this plugin declares support for the platform we run on.
  bool supportsCurrentPlatform() {
    if (platforms.isEmpty) return true;
    return platforms.contains(currentPlatformName());
  }

  static String currentPlatformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }
}
