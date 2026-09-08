import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/platform/key_letters.dart';
import '../../core/plugins/facts.dart';
import '../../core/plugins/grammar.dart';
import '../../core/plugins/viewer.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../core/vfs/failure_text.dart';
import '../../core/vfs/file_entry.dart';
import '../../state/app_state.dart';
import '../../state/listing_cursor.dart';
import '../format.dart';
import '../keyboard_focus.dart';
import '../motion.dart';
import '../notice.dart';
import '../plugins/mesh3d_view.dart';
import '../plugins/node_graph_view.dart';
import '../plugins/plugin_form.dart';
import '../plugins/plugin_table.dart';
import '../plugins/split_view.dart';
import '../plugins/sunburst_chart.dart';
import '../widgets/context_menu.dart';
import '../widgets/escape_to_pop.dart';
import '../widgets/keyboard_scrollable.dart';
import '../widgets/slide_panel.dart';
import '../widgets/title_bar.dart';
import '../windows/window_layer.dart';
import 'audio_view.dart';
import 'code_syntax.dart';
import 'diff_syntax.dart';
import 'content_swap.dart';
import 'facts_panel.dart';
import 'film_strip.dart';
import 'image_view.dart';
import 'json_syntax.dart';
import 'markdown_view.dart';
import 'outline.dart';
import 'readable_text.dart';
import 'reading_colours.dart';
import 'reading_link.dart';
import 'structure_panel.dart';
import 'thumbnails.dart';
import 'vector_view.dart';
import 'zoom_canvas.dart';
import 'viewed_file.dart';

/// Renders whatever a viewer plugin returned for a file.
///
/// A pushed page rather than an internal window: viewing is a place you go to
/// and come back from, and it wants the whole panel area. It keeps the
/// application's own title bar on top, so the window can still be dragged from
/// inside the viewer — that is the one thing a full-screen route used to take
/// away.
///
/// The core does not know how to display anything on its own; it only knows how
/// to draw the handful of content shapes in [ViewerContentKind]. Understanding
/// the file format is entirely the plugin's job.
class PluginViewerPage extends StatefulWidget {
  const PluginViewerPage({
    super.key,
    required this.entry,
    required this.viewers,
    this.initialIndex = 0,
    this.siblings = const [],
    this.onWalked,
  });

  final FileEntry entry;

  /// Every viewer that claims this file, best match first. The page can
  /// switch between them without going back to the panels.
  final List<RegisteredViewer> viewers;
  final int initialIndex;

  /// What else was in the listing this file was opened from, **in the order
  /// the panel had it** — its sort, its filter, its hidden files.
  ///
  /// The page is handed the whole listing rather than a ready-made list of
  /// neighbours, and picks out the ones the viewer in use can open. Which
  /// means the rule lives in one place and answers again when the viewer is
  /// switched: "open with" a hex dump, and the neighbours become every file
  /// rather than only the pictures.
  ///
  /// Empty when the page was opened from somewhere with no listing behind it —
  /// a view's own request, a test — and then there is nothing to walk and no
  /// strip.
  final List<FileEntry> siblings;

  /// Told each time the reader walks to another file, so the panel behind can
  /// follow.
  ///
  /// **Not a value handed back on the way out.** Escape and the Back button
  /// leave by different roads and neither carries anything, and a page that
  /// only reported where it ended would tell nobody where it went if the
  /// application closed while it was open — which is the case this whole
  /// thing exists for.
  final void Function(FileEntry entry)? onWalked;

  @override
  State<PluginViewerPage> createState() => _PluginViewerPageState();
}

class _PluginViewerPageState extends State<PluginViewerPage> {
  late RegisteredViewer _viewer = widget.viewers[widget.initialIndex];

  /// The file on screen, which is not [PluginViewerPage.entry] once anything
  /// has been walked to.
  late FileEntry _entry = widget.entry;

  /// The viewers that claim [_entry]. Re-asked after a walk, but never waited
  /// on: see [_goTo].
  late List<RegisteredViewer> _viewers = widget.viewers;

  ViewerContent? _content;

  late final ThumbnailCache _thumbnails;

  /// Whether the strip along the bottom is up. Read once, then owned here —
  /// the setting is written when it is toggled.
  late bool _strip;

  /// The reach into the structure panel, which the content view holds — see
  /// [StructureHandle]. The page keeps a button and an Escape, not a panel.
  final StructureHandle _structure = StructureHandle();

  @override
  void initState() {
    super.initState();
    _structure.addListener(_structureMoved);
    final app = context.read<AppState>();
    _thumbnails = ThumbnailCache(
      fileSystems: app.fileSystems,
      // Whoever opens the file is who can draw it. Asked only about a file the
      // machine's own decoder has already refused — see [ThumbnailCache].
      askPlugin: (entry, pixels) async {
        for (final viewer in app.plugins.viewersFor(
          entry.typeName,
          name: entry.name,
        )) {
          final ask = viewer.thumbnail;
          if (ask == null) continue;
          final small = await ask(entry.path, pixels);
          if (small != null && small.isNotEmpty) return small;
        }
        return null;
      },
    );
    _strip = context.read<SettingsStore>().filmStripOpen;
    _findDescriber();
    _load();
  }

  /// Whether what is on screen is something a structure can be read out of —
  /// the button is offered only there.
  bool get _readableContent => switch (_content?.kind) {
    ViewerContentKind.text || ViewerContentKind.markdown =>
      (_content?.text ?? '').isNotEmpty,
    _ => false,
  };

  /// Who can say what the file on screen says about itself, or null.
  ///
  /// **Looked up once per file, and nothing is asked yet.** That a describer
  /// exists is all the button needs; reading the metadata is a call down the
  /// pipe and waits until somebody opens the panel — see
  /// [PluginContentView.facts]. Kept rather than made in `build`, because what
  /// is below uses its identity to know whether it has already read this file,
  /// and a fresh one every frame would be a fresh read every frame.
  FactsSource? _describer;

  void _findDescriber() {
    final entry = _entry;
    final describer = context.read<AppState>().plugins.describerFor(entry);
    _describer = describer == null
        ? null
        : FactsSource(
            title: describer.title,
            read: () => describer.describe(entry.path),
          );
  }

  void _structureMoved() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _structure
      ..removeListener(_structureMoved)
      ..dispose();
    _thumbnails.dispose();
    super.dispose();
  }

  /// Offers the other viewers that claimed this file, under the button.
  Future<void> _chooseViewer(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    await showAppContextMenu(
      context: context,
      anchorRect: box.localToGlobal(Offset.zero) & box.size,
      searchHint: tr('Search viewers'),
      nodes: [
        for (final viewer in _viewers)
          MenuItem(
            '${viewer.title} · ${viewer.pluginName}',
            checked: viewer.id == _viewer.id,
            onSelected: () => _switchTo(viewer),
          ),
      ],
    );
  }

  void _switchTo(RegisteredViewer viewer) {
    if (viewer.id == _viewer.id) return;
    setState(() {
      _viewer = viewer;
      _content = null;
    });
    _load();
  }

  Future<void> _load() async {
    final viewer = _viewer;
    try {
      final entry = _entry;
      final content = await viewer.open(entry.path);
      // A slow viewer may finish after the user switched away from it — to
      // another viewer, or to another file.
      if (mounted && viewer.id == _viewer.id && entry.path == _entry.path) {
        setState(() => _content = content);
      }
    } on Object catch (failure) {
      if (mounted && viewer.id == _viewer.id) {
        // In the application's own words — see [saidPlainly]. The page used to
        // show the exception's class name and its errno, which is true and is
        // not for the person reading it.
        setState(() => _content = ViewerContent.error(saidPlainly(failure)));
      }
    }
  }

  // ------------------------------------------------------- the neighbours

  /// The files beside this one that the viewer in use can open. The rule, and
  /// what it costs, is written down where it lives: [neighboursFor].
  List<FileEntry> get _neighbours => neighboursFor(
    widget.siblings,
    _viewer.spec,
    // Every viewer there is, so that the strip can leave out what another one
    // names as its own — see [neighboursFor].
    others: [
      for (final viewer in context.read<AppState>().plugins.viewers)
        viewer.spec,
    ],
  );

  /// Where [_entry] sits among them, or -1 if it is not there at all — which
  /// happens when a file is opened from somewhere with no listing behind it.
  int _indexIn(List<FileEntry> neighbours) =>
      neighbours.indexWhere((e) => e.path == _entry.path);

  /// Walks [by] places along the strip. Stops at both ends rather than
  /// wrapping: a folder has a first file and a last one, and arriving back at
  /// the beginning without having asked to is how a reader loses their place.
  void _step(int by) {
    final neighbours = _neighbours;
    final at = _indexIn(neighbours);
    if (at < 0) return;
    final to = at + by;
    if (to < 0 || to >= neighbours.length) return;
    _goTo(neighbours[to]);
  }

  /// Opens [entry] in place, without leaving the page.
  ///
  /// **The viewer in use is kept and asked straight away.** The alternative —
  /// resolving the viewers again first — costs a probe, which reads the head
  /// of the file, and an arrow key must not wait for that. The neighbours are
  /// files this viewer handles by construction, so it is the right one to ask.
  /// The *list* of candidates is refreshed afterwards, because the "open with"
  /// button has to be telling the truth about the file on screen.
  void _goTo(FileEntry entry) {
    if (entry.path == _entry.path) return;
    // **The picture on screen stays there until the next one is ready.**
    // Emptying the page here is what put a spinner between two photographs,
    // and walking a folder with an arrow key turned that into a blink per
    // press. What says the walk happened in the meantime is the name in the
    // title bar and the highlight in the strip, both of which move at once.
    setState(() {
      _entry = entry;
      _findDescriber();
    });
    _load();
    _refreshViewers(entry);
    widget.onWalked?.call(entry);
  }

  Future<void> _refreshViewers(FileEntry entry) async {
    final candidates = await context.read<AppState>().plugins.viewersForFile(
      entry,
    );
    if (!mounted || entry.path != _entry.path || candidates.isEmpty) return;
    setState(() => _viewers = candidates);
  }

  void _toggleStrip() {
    setState(() => _strip = !_strip);
    context.read<SettingsStore>().setFilmStripOpen(_strip);
  }

  /// The keys the page itself answers, after everything inside it has had its
  /// turn — a `Focus` above the content sees what the content ignored.
  ///
  /// **All four arrows walk the folder**, and the reason is the panel: Down in
  /// a listing is the next file, and pressing F3 on it must not change what
  /// Down means. The picture canvas is told to leave them alone while the
  /// strip is up ([ReservedArrows]) and gets them back the moment it is put
  /// away, so an arrow never means two things without the screen saying which.
  /// Shift with one still pans, which is how a magnified picture is walked
  /// around.
  KeyEventResult _onPageKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }

    // The strip itself, which is otherwise a button and nothing else — and a
    // control the keyboard cannot reach does not exist.
    //
    // **The key by its place on the board, not by the letter it composed.** On
    // a non-Latin layout the key marked `T` types something else, and asking
    // the layout what it wrote took the binding away the moment the language
    // changed. See
    // [layoutIndependentLetter], which the menus and the drive list already
    // answer this way.
    if (layoutIndependentLetter(event.physicalKey) == 't' &&
        _neighbours.length > 1) {
      _toggleStrip();
      return KeyEventResult.handled;
    }
    if (!_stripShowing) return KeyEventResult.ignored;
    if (keys.isShiftPressed) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowUp:
        _step(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.arrowDown:
        _step(1);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Whether the strip is actually on screen: it is asked for, and there is
  /// more than one file for it to be a strip *of*.
  bool get _stripShowing => _strip && _neighbours.length > 1;

  @override
  Widget build(BuildContext context) {
    final content = _content;
    final settings = context.watch<SettingsStore>();
    final theme = settings.appearance;
    // Said on the size line when the viewer only read part of the file.
    final cut = ' · ${tr('truncated')}';

    return EscapeToPop(
      // Escape unwinds one thing at a time: the panel's own filter and the
      // panel itself are answered inside it while it holds the keyboard; from
      // the text, an open panel is what Escape means before leaving.
      onEscape: _structure.close,
      // Everything below here is *reading*, and says so once rather than a
      // dozen widgets each working out which of the three places they are
      // being drawn in. A table or a graph reached from a panel finds no
      // surface above it and goes on drawing in the panel's colours.
      child: ReadingSurface(
        colours: ReadingColours.of(theme),
        child: ColoredBox(
        // The reading's own fill, backdrop and all. A page covers the route
        // below rather than floating over it, so what shows through a
        // translucent one is the window's own backdrop, not the listing.
        //
        // It was the *panel's* fill until 1.0.0.298, which meant the page a
        // file is read on could not be set apart from the listing it was
        // opened from — see [ReadingColours].
        color: theme.effectiveReadingBackground,
        child: Column(
          children: [
            // The viewer's chrome is the application's bar, the way a tool's
            // is: back and the file's name on the left, "open with" beside the
            // window buttons. A page filling the window with a second bar
            // under the first was the arrangement everything else has left.
            TitleBar(
              leading: [
                TitleBarButton(
                  icon: Icons.arrow_back,
                  tooltip: tr('Back'),
                  onPressed: Navigator.of(context).pop,
                ),
              ],
              title: Text(
                _entry.name,
                overflow: TextOverflow.ellipsis,
                style: TitleBar.titleStyle(theme),
              ),
              actions: [
                // The structure, for the hand that reached for the mouse. The
                // key is the way in — this is the same door with a handle on
                // it, and it is only offered where there is something to read
                // a structure out of.
                // One button and one key for one panel; what it is called and
                // what it draws follow what is in it. A document has an
                // outline, a photograph has what it says about itself, and
                // neither has both.
                if (_readableContent || _structure.offered)
                  TitleBarButton(
                    icon: _readableContent ? Icons.toc : Icons.info_outlined,
                    // The describer's own words: "About this picture" and
                    // "About this recording" are different sentences, and only
                    // what reads the format knows which it is looking at.
                    tooltip: _readableContent
                        ? '${tr('Structure')}  O'
                        : '${_describer?.title ?? tr('About this file')}'
                            '  O',
                    onPressed: _structure.toggle,
                  ),
                // The strip, for the hand that reached for the mouse. Offered
                // only where there is more than one file to walk, because a
                // strip of one is a row with nowhere to go.
                if (_neighbours.length > 1)
                  TitleBarButton(
                    icon: Icons.view_carousel_outlined,
                    tooltip: '${tr('Neighbouring files')}  T',
                    onPressed: _toggleStrip,
                  ),
                // The app's own menu, not Material's: a popup route makes this
                // page stop being the current one, and this page draws a
                // window layer of its own.
                if (_viewers.length > 1)
                  Builder(
                    builder: (context) => TitleBarButton(
                      icon: Icons.visibility_outlined,
                      tooltip: tr('Open with'),
                      onPressed: () => _chooseViewer(context),
                    ),
                  ),
              ],
            ),
            Expanded(
              // Its own window layer, so anything the viewer asks — an "open
              // with" picker, a question — floats over the page rather than
              // behind it. Only the front-most page draws the stack.
              child: ViewerZoomMode(
                // How a picture opens here, and where a change to it is
                // written down. A photograph fills the window by default: they
                // are all bigger than they are shown, and the window is the
                // frame. Fit — which never enlarges — is still one press away
                // and is what everything outside a viewer page keeps.
                mode: ZoomMode.byName(settings.viewerZoomMode),
                onChanged: (mode) => settings.setViewerZoomMode(mode.name),
                child: FolderWalk(
                taken: _stripShowing,
                onWalk: _stripShowing ? _step : null,
                child: Focus(
                  // Above the content rather than in it: a `Focus` sees what
                  // whatever holds the keyboard ignored, which is exactly the
                  // arrangement this wants — the canvas answers the arrows it
                  // has a use for and the strip gets the rest.
                  canRequestFocus: false,
                  onKeyEvent: _onPageKey,
                  child: WindowLayer(
                stack: context.read<AppState>().windows,
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: content == null
                      // **It says what it is doing, and to what.** A bare
                      // spinner on an empty page is the same picture whether a
                      // file opens in a frame or takes ten seconds — measured:
                      // `body.obj`, 28.9 MB, is nine and a half seconds of
                      // nothing before the model appears, and a reader with no
                      // word from the application assumes it has hung.
                      //
                      // Not a percentage yet: what takes the time here is a
                      // plugin reading the file in its own process, and it has
                      // no way to say how far along it is. That is a channel to
                      // build, not a number to invent — backlog 118.
                      ? _Loading(entry: _entry, viewer: _viewer)
                      // Inside the Scaffold rather than outside it: a Material
                      // sets a default text style of its own from the theme,
                      // so a style installed above one is the style nothing
                      // reads. This is what the markdown's prose is written
                      // in — it has no colour of its own and never had, which
                      // is how it came to be drawn in Material's guess.
                      : DefaultTextStyle.merge(
                          style: TextStyle(
                            color: theme.readingForeground,
                            decoration: TextDecoration.none,
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                // Keyed on the *content*, not on the file:
                                // walking sets the file at once and the picture
                                // arrives later, so keying on the file would
                                // fade one picture into itself and then swap
                                // the real one in without a fade at all.
                                child: ContentSwap(
                                  child: KeyedSubtree(
                                    key: ObjectKey(content),
                                    child: PluginContentView(
                                      content: content,
                                      pluginId: _viewer.pluginId,
                                      structure: _structure,
                                      facts: _describer,
                                    ),
                                  ),
                                ),
                              ),
                              // The neighbours hang *on* the picture rather
                              // than in a band under it: the picture runs the
                              // whole height of the window and passes
                              // underneath them. A bar would have taken height
                              // away from the thing being looked at in order
                              // to say nothing.
                              //
                              // Always in the tree while there is more than one
                              // file, so it can slide both ways — rule two —
                              // and told when it is away so that a strip
                              // nobody is looking at does not go on reading a
                              // folder of photographs.
                              if (_neighbours.length > 1)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: IgnorePointer(
                                    ignoring: !_strip,
                                    child: AnimatedSlide(
                                      // **Further than its own height.** One
                                      // is exactly the strip's box, which
                                      // leaves it resting on the edge it is
                                      // supposed to have gone past — and the
                                      // strip carries room below its pictures
                                      // for the one being picked up, so what
                                      // is left standing there is a band of
                                      // nothing that still reads as the panel
                                      // not having left.
                                      offset: _strip
                                          ? Offset.zero
                                          : const Offset(0, 1.3),
                                      duration: motionOf(
                                        context,
                                        kFilmStripDuration,
                                      ),
                                      curve: kBothCurve,
                                      child: FilmStrip(
                                        entries: _neighbours,
                                        current: _indexIn(_neighbours),
                                        thumbnails: _thumbnails,
                                        theme: theme,
                                        active: _strip,
                                        rows: settings.filmStripRows,
                                        fold: StripFold.named(
                                          settings.filmStripFold,
                                        ),
                                        onPick: (index) =>
                                            _goTo(_neighbours[index]),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
                  ),
                ),
                ),
              ),
            ),
            // The neighbours, and the reason they are drawn rather than merely
            // walked: a key that moves something invisible is a mode, and this
            // one would otherwise be fighting the canvas for the same arrow.
            // What it is and how big, along the bottom where a panel keeps the
            // same sentence about the same file.
            Material(
              type: MaterialType.transparency,
              child: Container(
                height: theme.chromeRowHeight,
                width: double.infinity,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                color: theme.effectiveHeaderBackground,
                child: Text(
                  '${formatSize(_entry.size)} · ${_viewer.title}'
                  '${content?.truncated ?? false ? cut : ''}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    // The header's own ink on the header's own fill. It was
                    // the *panel's* ink, which is a colour chosen to read on
                    // the page and not on this strip — item 24 gave the header
                    // an ink of its own precisely so chrome stops borrowing.
                    color: theme.headerForeground,
                    fontSize: theme.fontSize - 1,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// How far the plugin that produced this content wants its text shifted from
/// the interface's weight, on the appearance settings' own hundred scale.
///
/// A plugin's setting rather than the application's: a monospaced family reads
/// thinner than the interface at the same weight, and that is a fact about the
/// viewer rather than about the panels. Zero for a plugin that has not asked,
/// which is all of them but one.
int _weightOffsetOf(BuildContext context, String? pluginId) =>
    _pluginWeight(context, pluginId, 'weightOffset');

/// The same road, for the *coloured words* — item 77: keywords, types, strings
/// and constants take a font weight set in the plugin, one for all of them.
///
/// **One setting, not four.** A weight per role would be four knobs nobody turns
/// and a way to make a page look assembled. It is a second offset of the same
/// shape as [_weightOffsetOf] rather than an absolute weight, so it goes on
/// meaning "a step heavier than the page" however the page's own weight is set.
int _syntaxWeightOffsetOf(BuildContext context, String? pluginId) =>
    _pluginWeight(context, pluginId, 'syntaxWeightOffset');

/// One of a plugin's weight settings, kept on the scale.
int _pluginWeight(BuildContext context, String? pluginId, String key) {
  if (pluginId == null || pluginId.isEmpty) return 0;
  try {
    final value = context.read<AppState>().plugins.settingsFor(pluginId)[key];
    final asked = value is int ? value : int.tryParse('${value ?? ''}') ?? 0;
    return asked.clamp(
      -AppearanceSettings.weightOffsetLimit,
      AppearanceSettings.weightOffsetLimit,
    );
  } on ProviderNotFoundException {
    return 0;
  }
}

/// The grammar for what a plugin says this file is written in, or null.
///
/// Null covers three ordinary cases and no extraordinary one: the content
/// named no language, nothing has declared that language, or this view is
/// standing somewhere with no application around it — a test, a preview — in
/// which case a file is drawn plainly rather than the page failing to build.
SyntaxGrammar? _grammarFor(BuildContext context, String? language) {
  if (language == null || language.isEmpty) return null;
  try {
    return context.read<AppState>().plugins.grammarFor(language);
  } on ProviderNotFoundException {
    return null;
  }
}

/// Draws one of the handful of shapes a plugin may return — text, markdown,
/// an image, a table or an error.
///
/// Public because the viewer is no longer the only thing that shows plugin
/// content: a command invoked from the title bar returns the same shapes.
class PluginContentView extends StatefulWidget {
  const PluginContentView({
    super.key,
    required this.content,
    this.onActivateRow,
    this.onMarkRow,
    this.onButton,
    this.onDropRows,
    this.cursor,
    this.focusedPart = '',
    this.onFocusPart,
    this.isActive = true,
    this.pluginId,
    this.fullScreen = true,
    this.reading,
    this.structure,
    this.facts,
  });

  final ViewerContent content;

  /// Who to ask what this file says about itself, and what to call the panel
  /// while it is showing it. Null where nothing can say anything.
  ///
  /// **Asked, not given** — and only when the panel is opened. Walking a folder
  /// of photographs with an arrow key opens a file every time the key repeats,
  /// and reading the metadata of each of them on the way past would be a call
  /// down the pipe per press for something nobody has asked to see.
  final FactsSource? facts;

  /// Whose content this is, for the settings that are about how it is *drawn*
  /// rather than about what is in it — see [_weightOffsetOf]. Null where the
  /// caller has no plugin behind it, and then nothing is shifted.
  final String? pluginId;

  /// Where the keyboard is, asked for by part — a split has a cursor in each
  /// of them. Null leaves every table with a cursor of its own, which the
  /// mouse still moves: a viewer showing a file has no keys pointed at it.
  final ListingCursor? Function(String part)? cursor;

  /// Which part has the keyboard, for the mark down its edge.
  final String focusedPart;

  final void Function(String part)? onFocusPart;

  /// Whether this is the thing being worked in, for the cursor's own colour.
  final bool isActive;

  /// Whether this is a whole page or a panel's worth of it.
  ///
  /// A quick view in a panel is a quarter of the window, and content that
  /// wants to put a panel of its own over itself — the node canvas and its
  /// properties — has nowhere to put one. Only the pages say true.
  final bool fullScreen;

  /// The line to whatever is standing beside the reading. Given from outside
  /// only where somebody else wants to listen to it; otherwise this makes its
  /// own.
  final ReadingLink? reading;

  /// A way for the chrome around this — the viewer page's title bar, its
  /// Escape — to reach the structure panel this draws. Null in a side panel,
  /// which has no chrome of its own.
  final StructureHandle? structure;

  /// Called with the row index when a table row is pressed, and with the part
  /// it was in when the content is a split.
  ///
  /// Null for content that is only being read — a viewer showing a file has
  /// nowhere to send a click, and rows that highlight under the pointer and
  /// then do nothing are worse than rows that do not.
  final void Function(int row, String part)? onActivateRow;

  /// The secondary press on a row or a wedge.
  ///
  /// `at` is where the press landed, for the menu a view may want drawn there.
  /// It is null from a chart, which has no menu to draw: a wedge picked out is
  /// a wedge marked, and the disk map has meant that since before views could
  /// answer the press with anything at all.
  final void Function(int row, String part, Offset? at)? onMarkRow;

  /// A button the content declared was pressed, with whatever a form's fields
  /// held at that moment — empty from a chart, which has no fields.
  final void Function(String buttonId, Map<String, Object?> values)? onButton;

  /// Rows were carried out of one part of a split and let go over another.
  final void Function(String from, String to, List<int> rows)? onDropRows;

  @override
  State<PluginContentView> createState() => _PluginContentViewState();
}

/// Who can say what a file says about itself, and what to call the panel while
/// it is showing it.
///
/// A pair rather than a bare callback because the *name* is the describer's:
/// "About this picture" and "About this recording" are different sentences, and
/// only the plugin that reads the format knows which one it is looking at.
class FactsSource {
  const FactsSource({required this.title, required this.read});

  final String title;
  final Future<FileFacts> Function() read;
}

/// Where the structure panel lives, and why it lives here rather than on the
/// page above.
///
/// **It used to be the page's**, which meant a reading in a side panel could
/// not have one: the specification said a slide panel belonged to full view
/// mode and not to the panels, and there is room for it in a panel too.
/// Held here, both surfaces get the same panel, the same keys and
/// the same remembered width, because there is only one of it.
class _PluginContentViewState extends State<PluginContentView> {
  /// The line between the reading and the panel over it. Made here unless
  /// somebody outside wanted to hold it.
  late final ReadingLink _reading = widget.reading ?? ReadingLink();

  /// Where the keyboard goes when it is in the tree rather than the text.
  final FocusNode _tree = FocusNode(debugLabel: 'document structure');

  List<OutlineNode>? _outline;
  Object? _outlineOf;

  FileFacts? _facts;
  FactsSource? _factsOf;
  bool _readingFacts = false;

  bool _panel = false;
  bool _pinned = false;
  double _share = kSlidePanelFraction;
  bool _settingsRead = false;

  @override
  void initState() {
    super.initState();
    _tree.addListener(_focusMoved);
    widget.structure?.attach(
      owner: this,
      toggle: _togglePanel,
      close: _closePanel,
    );
  }

  @override
  void didUpdateWidget(PluginContentView old) {
    super.didUpdateWidget(old);
    if (old.structure != widget.structure) {
      old.structure?.detach(this);
      widget.structure?.attach(
        owner: this,
        toggle: _togglePanel,
        close: _closePanel,
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_settingsRead) return;
    _settingsRead = true;
    final store = _store();
    if (store == null) return;
    _share = store.outlinePanelShare ?? kSlidePanelFraction;
    _pinned = store.outlinePanelPinned;
    _panel = store.outlinePanelOpen && (_readable != null || _showsFacts);
    widget.structure?.report(_panel);
    // The panel was left open on the last file and this one is described: it
    // is open now, so it has to be reading now.
    if (_panel && _showsFacts) _readFacts();
  }

  @override
  void dispose() {
    widget.structure?.detach(this);
    _tree
      ..removeListener(_focusMoved)
      ..dispose();
    if (widget.reading == null) _reading.dispose();
    super.dispose();
  }

  void _focusMoved() {
    if (mounted) setState(() {});
  }

  /// **Whose keys these are** — item 93. The conflict between the panel's
  /// keyboard and the slide panel's is settled by whichever is active: no
  /// modifier and no mode, the tree has the focus or the reading does, and
  /// whichever has it takes the keys.
  ///
  /// Held here rather than in each reading's key handler, because there is one
  /// rule and three readings — a text, a markdown page and a node canvas — and
  /// three copies of it is three chances for one of them to drift. [_tree]
  /// tells this widget when the focus moves, so the readings are rebuilt
  /// without either of them having to watch the other.
  bool _readingTakesKeys(String part) =>
      widget.isActive && widget.focusedPart == part && !_tree.hasFocus;

  SettingsStore? _store() {
    try {
      return context.read<SettingsStore>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// Whether the panel on the left is showing facts rather than an outline.
  ///
  /// **One panel, two things in it.** A document has an outline and a
  /// photograph has none, so the two never want it at the same moment — and one
  /// panel with one width, one key and one Escape is one thing to learn rather
  /// than two. The outline wins wherever there is one.
  bool get _showsFacts => _readable == null && widget.facts != null;

  /// The text a structure would be read out of, or null where this content has
  /// none — a picture, a table, a node canvas.
  String? get _readable {
    final content = widget.content;
    return switch (content.kind) {
      ViewerContentKind.text || ViewerContentKind.markdown => content.text,
      _ => null,
    };
  }

  /// The outline of what is on screen, worked out once and kept.
  ///
  /// Built when the panel is asked for, never when the file is opened: a
  /// reading nobody opened a panel over pays nothing at all.
  List<OutlineNode> _built() {
    final content = widget.content;
    final text = _readable;
    if (text == null || text.isEmpty) return const [];
    final kept = _outline;
    if (kept != null && identical(_outlineOf, content)) return kept;
    final nodes = outlineOf(
      text,
      grammar: _grammarFor(context, content.language),
      language: content.language,
      markdown: content.kind == ViewerContentKind.markdown,
    );
    _outline = nodes;
    _outlineOf = content;
    return nodes;
  }

  /// Asks the describer, once, and only because somebody opened the panel.
  Future<void> _readFacts() async {
    final source = widget.facts;
    if (source == null || _readingFacts) return;
    if (identical(_factsOf, source) && _facts != null) return;
    setState(() {
      _readingFacts = true;
      _facts = null;
      _factsOf = source;
    });
    final found = await source.read();
    if (!mounted || !identical(_factsOf, source)) return;
    setState(() {
      _facts = found;
      _readingFacts = false;
    });
  }

  void _togglePanel() {
    if (_panel) {
      _closePanel();
      return;
    }
    if (_showsFacts) {
      // Nothing is known about the file yet — that is the point of asking only
      // now — so the panel opens and says it is reading.
      setState(() => _panel = true);
      widget.structure?.report(true);
      _store()?.setOutlinePanelOpen(true);
      _readFacts();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _panel) _tree.requestFocus();
      });
      return;
    }
    // A file with nothing in it gets no panel at all — **not an empty one**.
    // The key was pressed, so it is answered rather than ignored.
    if (_built().isEmpty) {
      showNotice(context, tr('Nothing to see in this one.'));
      return;
    }
    setState(() => _panel = true);
    widget.structure?.report(true);
    _store()?.setOutlinePanelOpen(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _panel) _tree.requestFocus();
    });
  }

  void _closePanel() {
    if (!_panel) return;
    setState(() => _panel = false);
    widget.structure?.report(false);
    _leaveTree();
    _store()?.setOutlinePanelOpen(false);
  }

  /// Hands the keyboard back to the reading. Setting it down is enough — the
  /// reading takes it as soon as it is told it is the thing being worked in.
  void _leaveTree() {
    if (_tree.hasFocus) {
      _tree.unfocus();
    }
    setState(() {});
  }

  /// The panel goes away when you come back to the text, unless it is pinned.
  ///
  /// The keys go back either way. A pinned panel stays on screen, and a press
  /// in the text still means the text is what is being worked in — which is
  /// the whole of the rule in [_readingTakesKeys].
  void _readingTouched() {
    _leaveTree();
    if (_pinned) return;
    _closePanel();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final command = keys.isControlPressed || keys.isMetaPressed;

    // **`O` on its own, in a full page.** The viewer's keys are single
    // letters — `T` puts the strip away, `F` fits, `1` is 1:1 — and a
    // three-finger chord in the middle of them was the odd one out. In a *panel* it stays a chord, because a bare letter there is the
    // panel's own quick search and a reading does not get to take it.
    //
    // Guarded twice over: not while the tree beside the reading has the
    // keyboard, where letters filter it, and not while anything is being
    // typed at all — a field takes its characters through the platform rather
    // than as key events, so a handler this high sees every letter of what is
    // going into the find box.
    final plainO = !command &&
        !keys.isAltPressed &&
        !keys.isShiftPressed &&
        widget.fullScreen &&
        !_tree.hasFocus &&
        !keyboardIsInAField();
    if ((plainO || (command && keys.isShiftPressed)) &&
        event.logicalKey == LogicalKeyboardKey.keyO) {
      // Facts count as something to open, which is what a picture has. Asking
      // only about the reading was why the key did nothing on a photograph
      // while the button beside it worked.
      if (_readable == null && !_showsFacts) return KeyEventResult.ignored;
      _togglePanel();
      return KeyEventResult.handled;
    }
    if (!_panel) return KeyEventResult.ignored;

    // The way *in*. Out again is the tree's own Tab, and the two together are
    // what the rule asks for: you can reach it and you can leave it.
    if (event.logicalKey == LogicalKeyboardKey.tab && !_tree.hasFocus) {
      _tree.requestFocus();
      setState(() {});
      return KeyEventResult.handled;
    }
    // The pin, which is otherwise a button and nothing else — and a control
    // the keyboard cannot reach does not exist.
    if (command && event.logicalKey == LogicalKeyboardKey.keyP) {
      setState(() => _pinned = !_pinned);
      _store()?.setOutlinePanelPinned(_pinned);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final drawn = _draw(context, widget.content, '');
    // Said after the frame: the chrome around this listens to the handle, and
    // telling it during a build is telling a widget to rebuild while it is
    // being built.
    // Only the reading this handle speaks for may answer this. Both are
    // mounted and both are built for the length of the fade, so without the
    // guard a picture on its way out spends it saying "nothing to read here"
    // over the Markdown page arriving behind it, and the two take it in turns
    // frame by frame. The arriving one happens to have the last word, which is
    // why nothing was ever seen to be wrong with it — but a rule that holds by
    // accident of build order is not a rule.
    final can = _readable != null || widget.facts != null;
    final structure = widget.structure;
    if (structure != null && structure.speaksFor(this) && structure.offered != can) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && structure.speaksFor(this)) structure.offer(can);
      });
    }
    // Content with nothing to read and nothing that can describe it is drawn
    // exactly as it was before any of this existed: a table, a canvas of nodes.
    if (_readable == null && !_showsFacts) return drawn;

    return Focus(
      onKeyEvent: _onKey,
      child: SlidePanel(
        open: _panel,
        pinned: _pinned,
        fraction: _share,
        onPinnedChanged: (pinned) {
          setState(() => _pinned = pinned);
          _store()?.setOutlinePanelPinned(pinned);
        },
        onFractionChanged: (share) {
          setState(() => _share = share);
          _store()?.setOutlinePanelShare(share);
        },
        // A press in the reading puts an unpinned panel away: it is not the
        // jump that closes it, it is coming back to the text.
        onContentPressed: (_) {
          _readingTouched();
          return true;
        },
        onClose: _closePanel,
        panel: (context) => _showsFacts
            ? FactsPanel(
                facts: _facts,
                loading: _readingFacts,
                focusNode: _tree,
                onLeave: () {
                  _leaveTree();
                  _readingTouched();
                },
                onClose: _closePanel,
              )
            : StructurePanel(
                nodes: _built(),
                link: _reading,
                focusNode: _tree,
                truncated: widget.content.truncated,
                onLeave: () {
                  _leaveTree();
                  _readingTouched();
                },
                onClose: _closePanel,
              ),
        child: drawn,
      ),
    );
  }

  /// Draws one content, stamping whatever it raises with the part it is in.
  ///
  /// Recursive only in the one direction that matters: a split holds contents,
  /// and one of those may be a split again. Nothing else nests.
  Widget _draw(BuildContext context, ViewerContent content, String part) {
    switch (content.kind) {
      case ViewerContentKind.file:
        final url = content.url;
        if (url == null || url.isEmpty) {
          return _Centered(
            icon: Icons.help_outline,
            message: tr('The view pointed at no file.'),
          );
        }
        // Drawn through this same renderer, so a picture inside a tool is the
        // picture the viewer would have shown. A file that turns out to be
        // another file is not a case worth having, so it is not one.
        return ViewedFile(
          url: url,
          draw: (inner) => inner.kind == ViewerContentKind.file
              ? const SizedBox.shrink()
              : _draw(context, inner, part),
        );

      case ViewerContentKind.split:
        return SplitView(
          content: content,
          focused: widget.focusedPart,
          onFocus: widget.onFocusPart,
          onButton: widget.onButton,
          onDropRows: widget.onDropRows,
          buildPart: (inner) => _draw(
            context,
            inner.content ?? const ViewerContent(kind: ViewerContentKind.text),
            inner.id,
          ),
        );

      case ViewerContentKind.error:
        return _Centered(
          icon: Icons.error_outline,
          message: content.message ?? tr('The viewer reported an error.'),
        );

      case ViewerContentKind.markdown:
        return KeyboardScrollable(
          hasKeyboard: _readingTakesKeys(part),
          builder: (controller) => MarkdownView(
            source: content.text ?? '',
            controller: controller,
            link: _reading,
          ),
        );

      case ViewerContentKind.text:
        final theme = appearanceOf(context);
        final page = readingColours(context);
        // The page's own ink, not Material's guess at it. The reading is
        // painted in the reading's fill, and the two settings are separate: a
        // dark page under light chrome drew black text on it.
        // The interface's own weight, shifted by however much this plugin
        // asked for. A monospaced family at the same number reads thinner than
        // the interface does, and a file of code is a page of it.
        final weight = FontWeightSpec(
          (theme.uiFontWeight.value + _weightOffsetOf(context, widget.pluginId)).clamp(
            AppearanceSettings.weightMinimum,
            AppearanceSettings.weightMaximum,
          ),
        );
        final syntaxWeight = _syntaxWeightOffsetOf(context, widget.pluginId);
        final style = TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          fontWeight: weight.weight,
          color: page.ink,
          decoration: TextDecoration.none,
        );
        final body = content.text ?? '';
        // The only hint the contract has ever carried, and it was written down
        // as "reserved for future highlighting" from the start. Two languages
        // answer to it now; anything else is drawn as it always was.
        final language = content.language?.toLowerCase();
        // Everything else is a grammar somebody shipped as data — see
        // [SyntaxGrammar]. Nothing is built in: a language nobody has declared
        // is drawn exactly as it always was.
        final grammar = _grammarFor(context, language);

        return ReadableText(
          body: body,
          style: style,
          hasKeyboard: _readingTakesKeys(part),
          truncated: content.truncated,
          // What holds a line up over the ones below it — item 70b. The reader
          // asks the grammar itself rather than being handed an answer,
          // because the question is only ever asked while somebody scrolls.
          grammar: grammar,
          language: language,
          link: _reading,
          spans: () => switch (language) {
            // These two are the host's own, and stay so: JSON's colouring
            // reads ahead to tell a name from a value, and a diff is
            // coloured by whole lines. Neither is a thing a word list can
            // say.
            'json' => jsonSpans(body, style, JsonColours.of(theme)),
            'diff' => diffSpans(body, style, DiffColours.of(theme)),
            _ when grammar != null && !grammar.isEmpty => codeSpans(
              body,
              grammar,
              style,
              CodeColours.of(theme),
              // The words the reader picks the page out by, one weight for all
              // of them — see [codeSpans]. Worked out from the weight the page
              // is already in, so the two settings stack rather than fight.
              wordWeight: syntaxWeight == 0
                  ? null
                  : FontWeightSpec(
                      (weight.value + syntaxWeight).clamp(
                        AppearanceSettings.weightMinimum,
                        AppearanceSettings.weightMaximum,
                      ),
                    ).weight,
            ),
            // Even a file nothing knows anything about is spans, so the search
            // has one thing to mark rather than two shapes to know about.
            _ => TextSpan(text: body, style: style),
          },
        );

      case ViewerContentKind.image:
        final bytes = content.bytes;
        if (bytes == null || bytes.isEmpty) {
          return _Centered(
            icon: Icons.broken_image_outlined,
            message: tr('The viewer returned no image data.'),
          );
        }
        return ImageView(
          bytes: bytes,
          hasKeyboard: _readingTakesKeys(part),
          detail: content.detail,
        );

      case ViewerContentKind.audio:
        return AudioView(
          content: content,
          hasKeyboard: _readingTakesKeys(part),
        );

      case ViewerContentKind.vector:
        final drawing = content.drawing;
        if (drawing == null || drawing.isEmpty) {
          return _Centered(
            icon: Icons.category_outlined,
            message: tr('There is nothing in this drawing to show.'),
          );
        }
        return VectorView(
          drawing: drawing,
          hasKeyboard: _readingTakesKeys(part),
          detail: content.detail,
        );

      case ViewerContentKind.form:
        return PluginForm(content: content, onSubmit: widget.onButton);

      case ViewerContentKind.mesh3d:
        return Mesh3dView(
          content: content,
          hasKeyboard: _readingTakesKeys(part),
        );

      case ViewerContentKind.nodes:
        final graph = content.nodeGraph;
        if (graph == null || graph.isEmpty) {
          return _Centered(
            icon: Icons.account_tree_outlined,
            message: tr('The reader found no nodes in this file.'),
          );
        }
        // The canvas takes the keyboard on the same terms the reading does:
        // only while this is the part being worked in, and never while the
        // structure panel has it.
        return NodeGraphView(
          graph: graph,
          hasKeyboard: _readingTakesKeys(part),
          fullScreen: widget.fullScreen,
        );

      case ViewerContentKind.chart:
        return SunburstChart(
          content: content,
          onActivate:
              widget.onActivateRow == null ? null : (row) => widget.onActivateRow!(row, part),
          onMark:
              widget.onMarkRow == null ? null : (row) => widget.onMarkRow!(row, part, null),
          onButton: widget.onButton == null ? null : (id) => widget.onButton!(id, const {}),
        );

      case ViewerContentKind.table:
        if (content.rows.isEmpty) {
          return _Centered(
            icon: Icons.table_rows_outlined,
            message: tr('Nothing to show.'),
          );
        }
        // The secondary press reaches a table row now. It always reached a
        // chart's wedges, and the omission meant the one thing a plugin could
        // say about a row — "press it with the other button" — did nothing at
        // all when the row was in a table.
        return PluginTable(
          content: content,
          cursor: widget.cursor?.call(part),
          part: part,
          // Only where there is somewhere to carry them to, and only where the
          // view can be worked in at all.
          canDrag: widget.onDropRows != null && widget.onActivateRow != null,
          onActivateRow: widget.onActivateRow == null
              ? null
              : (row) => widget.onActivateRow!(row, part),
          onMarkRow: widget.onMarkRow == null
              ? null
              : (row, at) => widget.onMarkRow!(row, part, at),
          // A part that does not have the keyboard shows a paler widget.cursor, the
          // way the panel that does not have it does. A table that is not in a
          // split has no part, and neither has the focus — so they match, and
          // it is active.
          isActive: widget.isActive && widget.focusedPart == part,
        );
    }
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  // Centred where there is room and scrolled where there is not. This stands
  // in a part of a split now, and a part is as short as the divider leaves it
  // — an icon and a line of text is more than a part three rows tall can hold,
  // and a striped edge saying so is worse than the message it covers.
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, room) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: room.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 32),
                    const SizedBox(height: 10),
                    Text(message, textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

/// The page while the file is still being read.
///
/// **A spinner on its own says nothing.** It is the same picture for a file
/// that opens between two frames and for one that takes ten seconds, and a
/// reader who is shown nothing for ten seconds concludes the application has
/// stopped. This says which file, how big it is, and which viewer is working on
/// it — three true things, and between them they turn a wait into a wait *for
/// something*.
///
/// There is no percentage, and inventing one would be worse than none: what
/// takes the time is a plugin reading the file in a process of its own, and it
/// has no way yet to say how far it has got. Backlog 118 is that channel.
class _Loading extends StatelessWidget {
  const _Loading({required this.entry, required this.viewer});

  final FileEntry entry;
  final RegisteredViewer viewer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final quiet = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 16),
          Text(entry.name, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          // The size, with no word in front of it: a wait does not need a
          // sentence when the spinner, the name and the number between them
          // have said everything.
          if (!entry.isDirectory && entry.size > 0)
            Text(formatSize(entry.size), style: quiet),
          const SizedBox(height: 2),
          Text(tr(viewer.spec.title), style: quiet),
        ],
      ),
    );
  }
}
