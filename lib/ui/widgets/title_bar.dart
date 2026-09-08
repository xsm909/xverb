import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/i18n/i18n.dart';
import '../../core/platform/modifier_keys.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../core/settings/window_service.dart';
import '../../core/version.dart';
import '../branding/app_mark.dart';
import '../text_scale.dart';
import 'context_menu.dart';
import 'title_bar_plugins.dart';
import 'hint.dart';

/// Our own title bar, replacing the system one.
///
/// It still behaves like a title bar: drag to move, double-click to maximise,
/// and the usual buttons. On macOS the platform keeps its traffic lights, so we
/// leave room for them instead of drawing our own.
class TitleBar extends StatefulWidget implements PreferredSizeWidget {
  const TitleBar({
    super.key,
    this.menus = const [],
    this.actions = const [],
    this.menuKeys,
    this.leading = const [],
    this.title,
  });

  /// Drop-down menus shown inline, the way Fork puts its menu bar in the title
  /// bar rather than on a row of its own.
  ///
  /// A full-screen view brings its own and they stand here instead of the
  /// application's — see `PluginViewPage`. Empty is a real answer: the strip
  /// shows nothing, which is what a view that declares no menu asks for.
  final List<TitleBarMenu> menus;

  /// Lets a key binding open one of them. See [TitleBarMenus].
  final TitleBarMenus? menuKeys;

  /// Between the wordmark and the menus: the way back out of wherever this is,
  /// and the switch between full screen and a panel.
  final List<Widget> leading;

  /// What is open — a view's name, or the trail it has walked.
  ///
  /// After the menus rather than before them, so the menu strip is in the same
  /// place whether or not a view is up, and the title takes what is left.
  final Widget? title;

  /// Extra controls shown to the left of the window buttons.
  final List<Widget> actions;

  static const double height = 49;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  /// How a page writes what is open, in the bar's own voice.
  ///
  /// Every full-screen page had this style copied out by hand, so a change to
  /// the bar's type meant finding four of them. See [TitleBarButton] for the
  /// same argument about the icons.
  static TextStyle titleStyle(AppearanceSettings theme) => TextStyle(
    color: theme.headerForeground,
    fontSize: theme.scaled(12.5),
    fontWeight: theme.uiWeightFor(FontWeight.w500),
  );

  @override
  State<TitleBar> createState() => _TitleBarState();
}

/// One icon in the title bar, in the bar's colours rather than Material's.
///
/// Back, "show in the panel", a view's own commands, the viewer's "open with":
/// all of them are this, and they were four private copies of the same six
/// lines before it moved here. The colour comes from the appearance settings
/// rather than the caller, because there is only ever one right answer and a
/// caller that passes something else has made the bar inconsistent.
class TitleBarButton extends StatelessWidget {
  const TitleBarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;

  /// Null disables the button, the way it does for any [IconButton].
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Hint(
    message: tooltip,
    child: IconButton(
      iconSize: 16,
      visualDensity: VisualDensity.compact,
      color: context.watch<SettingsStore>().appearance.headerForeground,
      icon: Icon(icon),
      onPressed: onPressed,
    ),
  );
}

class _TitleBarState extends State<TitleBar> with WindowListener {
  bool _maximized = false;

  /// The stretch of bar that moves the window — the title and the corner the
  /// version sits in.
  final GlobalKey _dragArea = GlobalKey();

  /// The mark at the left end, which moves it too. Its own key because a
  /// `GlobalKey` belongs to one widget, and [_onPressWhileMenuOpen] is about
  /// the main stretch.
  final GlobalKey _wordmarkDrag = GlobalKey();

  /// A press that lands on the drag strip while a menu is open should both
  /// dismiss the menu and start the drag. Without this the modal barrier eats
  /// the press and the window only moves on a second attempt.
  void _onPressWhileMenuOpen(Offset position) {
    final box = _dragArea.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    if (!(box.localToGlobal(Offset.zero) & box.size).contains(position)) return;

    Navigator.of(context).maybePop();
    unawaited(WindowService.startDragging());
  }

  @override
  void initState() {
    super.initState();
    if (WindowService.isSupported) {
      windowManager.addListener(this);
      _refreshMaximized();
    }
  }

  @override
  void dispose() {
    if (WindowService.isSupported) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => _refreshMaximized();

  @override
  void onWindowUnmaximize() => _refreshMaximized();

  Future<void> _refreshMaximized() async {
    final value = await WindowService.isMaximized();
    if (mounted && value != _maximized) setState(() => _maximized = value);
  }

  /// What the drag handle keeps for itself when something else has the bar,
  /// at the default font size. Enough for the version and a hold on the window.
  static const double _dragReserve = 96;

  /// Anything on the bar that is not a control moves the window, and
  /// double-clicking it maximises.
  ///
  /// **Translucent, not opaque.** The title of a plugin's view has a button in
  /// it, and an opaque detector over the title would eat the press. Translucent
  /// puts this in the arena *alongside* whatever is underneath: a press that
  /// does not move is the button's, and a press that travels is the window's —
  /// which is how every real title bar behaves.
  Widget _draggable({required Widget child, Key? key}) => GestureDetector(
        key: key ?? _dragArea,
        behavior: HitTestBehavior.translucent,
        onPanStart: (_) => WindowService.startDragging(),
        onDoubleTap: WindowService.toggleMaximize,
        child: child,
      );

  /// The version, in the corner of the bar. Worth a corner of a window's title
  /// bar, not worth any of a phone's.
  Widget _versionCorner(AppearanceSettings theme, Color foreground) => Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 10),
          child: WindowService.isSupported
              ? Text(
                  kAppVersion,
                  maxLines: 1,
                  // The reserve is a width, and at the largest font setting
                  // the version outgrows it. Better a clipped version than
                  // an overflowing bar.
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: theme.scaled(10),
                    color: foreground.withValues(alpha: 0.45),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    // The bar's own ink — item 24. Its background could be set and its writing
    // could not, so a dark header under a light palette was a bar with
    // invisible words on it.
    final foreground = theme.headerForeground;

    return SizedBox(
      height: TitleBar.height,
      // Its own Material, because the bar is not always inside one. Under a
      // `MaterialApp` with no Material above it, text picks up the framework's
      // error style, and a label that sets a colour and a size but no
      // decoration inherits the rest of it: the wordmark and the version came
      // out with yellow double underlines on the settings page, where the bar
      // sits above the Scaffold rather than inside it.
      child: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.effectiveHeaderBackground,
            border: Border(
              // The line between the menu and the panels — see
              // [AppearanceSettings.chromeRule].
              bottom: BorderSide(color: theme.chromeRule),
            ),
          ),
          child: Row(
            children: [
              // The wordmark belongs to a window title bar. On a phone the
              // system already says whose app this is, and the hundred pixels
              // it costs are the difference between the menus being on the bar
              // and being three taps deep behind one button.
              if (WindowService.isSupported) ...[
                // The mark drags the window as well. It is the one part of the
                // bar that is unmistakably not a control, and a title bar with
                // a dead patch at the left end is a title bar somebody will
                // grab by and wonder about.
                _draggable(
                  key: _wordmarkDrag,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10, right: 12),
                    child: _Wordmark(
                      accent: theme.accentColor,
                      foreground: foreground,
                    ),
                  ),
                ),
              ] else
                const SizedBox(width: 6),
              // The menus and the drag handle share what is left between the
              // wordmark and the window buttons. Giving the strip a bounded width
              // is what lets it fold titles away instead of overrunning the bar,
              // which it did at the window's own minimum size.
              if (widget.leading.isNotEmpty)
                ExcludeFocus(child: Row(children: widget.leading)),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: [
                      ExcludeFocus(
                        child: _MenuStrip(
                          menus: widget.menus,
                          menuKeys: widget.menuKeys,
                          foreground: foreground,
                          style: menuAppearanceFrom(theme),
                          onPressOutside: _onPressWhileMenuOpen,
                          // Measured out here, because a Row hands a child that is
                          // neither Expanded nor Flexible an *unbounded* main-axis
                          // constraint — which is why the strip overflowed rather
                          // than folding, and why it cannot measure itself.
                          available: constraints.maxWidth,
                          // Nothing is kept back for dragging where there is
                          // no window to drag.
                          dragArea: WindowService.isSupported
                              ? _MenuStrip.minimumDragArea
                              : 0,
                        ),
                      ),
                      // What is open, after the menus — and it takes the whole
                      // bar rather than a share of it.
                      //
                      // **Expanded, not Flexible**, and the drag handle beside
                      // it stops being Expanded at the same time. Two flexible
                      // children of one flex each split the free space in half,
                      // which is exactly what a path bar looked like: a trail
                      // ending halfway along an empty bar, reading as a path
                      // with nowhere left to go. The handle keeps a fixed
                      // reserve instead — the bar must always have somewhere to
                      // take hold of the window by, and that is a width, not a
                      // half.
                      // **The title drags the window too.** Without that,
                      // dragging a settings page by its bar worked only
                      // sometimes: measured on a 1200-pixel window with a
                      // title, only about eight per cent of the bar moved it —
                      // a strip around the version, between the end of the
                      // title's Expanded and the window buttons. Everywhere
                      // else did nothing, so whether it worked came down to
                      // where the pointer happened to land. The panels have no
                      // title, all of their bar dragged, and that is why it
                      // only ever went wrong on a page.
                      if (widget.title != null)
                        Expanded(
                          child: _draggable(
                            child: Row(
                              children: [
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: widget.title,
                                  ),
                                ),
                                SizedBox(
                                  width: theme.scaled(_dragReserve),
                                  child: _versionCorner(theme, foreground),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        // Nothing else wants the bar, so all of it drags.
                        Expanded(
                          child: _draggable(
                            child: _versionCorner(theme, foreground),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Plugins sit between the app's own actions and the window
              // buttons: they belong to the application, not to the window.
              ExcludeFocus(
                child: TitleBarPluginItems(
                  foreground: foreground,
                  menuKeys: widget.menuKeys,
                ),
              ),
              // A rule between the tools and whatever is open now. Two rows of
              // icons with nothing between them read as one row, and these are
              // different things: the tools are always there, and the buttons
              // beside them belong to the view that happens to be up.
              if (widget.actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: SizedBox(
                    height: 18,
                    child: VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: foreground.withValues(alpha: 0.22),
                    ),
                  ),
                ),
              ExcludeFocus(child: Row(children: widget.actions)),
              if (WindowService.drawsOwnButtons)
                ExcludeFocus(
                  child: Row(
                    children: [
                      _WindowButton(
                        icon: Icons.remove,
                        color: foreground,
                        tooltip: tr('Minimise'),
                        onPressed: WindowService.minimize,
                      ),
                      _WindowButton(
                        icon: _maximized
                            ? Icons.filter_none_outlined
                            : Icons.crop_square,
                        color: foreground,
                        tooltip: _maximized ? tr('Restore') : tr('Maximise'),
                        iconSize: _maximized ? 12 : 14,
                        onPressed: WindowService.toggleMaximize,
                      ),
                      _WindowButton(
                        icon: Icons.close,
                        color: foreground,
                        tooltip: tr('Close'),
                        danger: true,
                        onPressed: WindowService.close,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One drop-down in the title bar's menu strip.
class TitleBarMenu {
  const TitleBarMenu(this.label, this.build, {this.accelerator});

  final String label;

  /// The letter that opens it with Alt held, lower case.
  ///
  /// Given rather than taken from the label, because two of these begin with the
  /// same letter — Commands and Console — and a menu bar whose accelerators
  /// depend on the order the titles happen to be in is a menu bar whose keys
  /// move when a title is added.
  final String? accelerator;

  /// Built on open, so the entries reflect the current state. It must not do
  /// any I/O — the menu has to appear on the click, not after it.
  final List<MenuNode> Function() build;
}

/// Opens a title bar menu from outside the bar — from a key binding.
///
/// The strip owns which menu is showing, and a key press arrives at the
/// commander's key handler, which is nowhere near it. This is the wire between
/// them: the strip attaches itself while it is mounted, and answers false when
/// there is nothing to open, so a binding can fall through rather than pretend.
///
/// It also holds the selector F10 leaves on the bar — see [enter]. That lives
/// here rather than in the strip because the ring it walks is longer than the
/// strip: the menu titles and the tools icons are two widgets at opposite ends
/// of the bar, and one selector has to cross both.
class TitleBarMenus extends ChangeNotifier {
  bool Function(String accelerator)? _open;

  void attach(bool Function(String accelerator) open) => _open = open;

  void detach(bool Function(String accelerator) open) {
    if (_open == open) _open = null;
  }

  /// Opens the menu claiming [accelerator]. False when no menu claims it, or
  /// when there is no menu bar on screen at all.
  bool open(String accelerator) =>
      _open?.call(accelerator.toLowerCase()) ?? false;

  // --- The selector, F10 --------------------------------------------------

  _BarSection? _menus;
  _BarSection? _tools;

  int? _selected;

  /// Where the selector is standing, or null while the bar has no keyboard.
  int? get selected => _selected;

  /// Whether the bar has the keyboard at all. While it has, the panels must not
  /// see the arrows: F10 is a state, not a keystroke.
  bool get selecting => _selected != null;

  int get _menuCount => _menus?.count ?? 0;

  int get _length => _menuCount + (_tools?.count ?? 0);

  /// Told by the strip and by the tools icons, every time they lay out.
  ///
  /// Deliberately silent — this runs during a build, and a notification from
  /// there is a rebuild inside a rebuild. Nothing is watching for the *count*;
  /// what is watched is where the selector stands.
  void registerMenus(int count, void Function(int index) activate) =>
      _menus = _BarSection(count, activate);

  void registerTools(int count, void Function(int index) activate) =>
      _tools = _BarSection(count, activate);

  /// F10: the bar takes the keyboard **without opening anything**. False when
  /// there is no bar to enter.
  bool enter() {
    if (_length == 0) return false;
    _selected = 0;
    notifyListeners();
    return true;
  }

  /// Escape, or F10 again. Gives the keyboard back to whatever had it.
  void leave() {
    if (_selected == null) return;
    _selected = null;
    notifyListeners();
  }

  /// Left and Right, in a circle: from the first title Left reaches the last
  /// tools icon if there is one, and the last title otherwise.
  void step(int delta) {
    final length = _length;
    if (length == 0) return;
    final at = ((_selected ?? 0) + delta) % length;
    _selected = at < 0 ? at + length : at;
    notifyListeners();
  }

  /// Down, or Enter: unrolls the menu the selector is on, or presses the icon.
  ///
  /// A menu keeps the selector — the open menu has the keyboard, and Escape out
  /// of it lands back on the title it came from rather than on the panel. An
  /// icon is an action and there is nothing to come back to, so it gives the
  /// keyboard up.
  void activateSelected() {
    final at = _selected;
    if (at == null) return;
    if (at < _menuCount) {
      _menus?.activate(at);
      return;
    }
    final tools = _tools;
    leave();
    tools?.activate(at - _menuCount);
  }

  /// Whether the selector is on title [index] of the strip.
  bool isMenuSelected(int index) => _selected == index;

  /// Whether the selector is on tools icon [index].
  bool isToolSelected(int index) => _selected == _menuCount + index;
}

/// One run of things the selector walks — the titles, then the tools icons.
class _BarSection {
  const _BarSection(this.count, this.activate);

  final int count;
  final void Function(int index) activate;
}

/// The row of menu titles.
///
/// It owns which one is open, because the behaviour people expect from a menu
/// bar is a property of the row, not of a button: once any menu is showing,
/// moving the pointer across the titles walks between them.
class _MenuStrip extends StatefulWidget {
  const _MenuStrip({
    required this.menus,
    required this.menuKeys,
    required this.foreground,
    required this.style,
    required this.onPressOutside,
    required this.available,
    required this.dragArea,
  });

  /// The wire a key binding opens a menu through, if there is one.
  final TitleBarMenus? menuKeys;

  /// Width the strip has, worked out by the bar. See the note at the call site
  /// for why the strip is not trusted to measure this itself.
  final double available;

  /// How much of it to leave for dragging the window by, when that can be
  /// afforded. Zero where there is no window to drag.
  final double dragArea;

  /// The bar always keeps somewhere to take hold of the window by. Without
  /// this the menus would grow into the whole strip and leave nothing to drag.
  static const double minimumDragArea = 72;

  final List<TitleBarMenu> menus;
  final Color foreground;
  final MenuAppearance style;

  Color get accent => style.accent;

  /// Presses that reach the modal barrier while a menu is open.
  final ValueChanged<Offset> onPressOutside;

  @override
  State<_MenuStrip> createState() => _MenuStripState();
}

class _MenuStripState extends State<_MenuStrip> {
  final Map<int, GlobalKey> _keys = {};

  int? _open;
  int? _hovered;

  /// Whether the open menu has a row picked out. Once something inside the
  /// menu is, the selector on the title goes and only the bare outline is
  /// left: two selectors at once is two answers to "where am I".
  bool _menuHasHighlight = false;

  /// Set when a hover asks to switch; acted on once the old menu has closed.
  int? _pending;

  GlobalKey _keyFor(int index) => _keys.putIfAbsent(index, GlobalKey.new);

  /// Whether Alt is down right now, so the letters can be shown.
  bool _altHeld = false;
  Timer? _altWatch;

  /// What a menu that is *not* joined to its title leaves between them.
  static const double _detachedGap = 5;

  /// How often the keyboard is asked about Alt.
  ///
  /// Asked rather than counted from the key events, because on Windows a lone Alt
  /// press only reaches the application every other time — see [ModifierKeys].
  /// Twelve times a second is quick enough that the letters appear with the press
  /// and cheap enough to be beneath noticing: one call into `user32` that reads a
  /// keyboard state the OS is keeping anyway.
  static const Duration _altPoll = Duration(milliseconds: 80);

  @override
  void initState() {
    super.initState();
    widget.menuKeys?.attach(_openByAccelerator);
    widget.menuKeys?.addListener(_onSelectorMoved);
    _altWatch = Timer.periodic(_altPoll, (_) => _readAlt());
  }

  void _onSelectorMoved() {
    if (mounted) setState(() {});
  }

  void _readAlt() {
    if (!mounted) return;
    final held = ModifierKeys.altAlone;
    if (held != _altHeld) setState(() => _altHeld = held);
  }

  @override
  void didUpdateWidget(_MenuStrip old) {
    super.didUpdateWidget(old);
    if (old.menuKeys != widget.menuKeys) {
      old.menuKeys?.detach(_openByAccelerator);
      old.menuKeys?.removeListener(_onSelectorMoved);
      widget.menuKeys?.attach(_openByAccelerator);
      widget.menuKeys?.addListener(_onSelectorMoved);
    }
  }

  @override
  void dispose() {
    _altWatch?.cancel();
    widget.menuKeys?.detach(_openByAccelerator);
    widget.menuKeys?.removeListener(_onSelectorMoved);
    super.dispose();
  }

  /// Alt+F and the rest. False when no title claims the letter, so the binding
  /// can leave the key to whatever else wants it.
  ///
  /// A folded-away title has no rectangle to hang a menu off, so its entries are
  /// reached through the overflow button — which is where they are on screen too,
  /// and the keyboard should not go somewhere the pointer cannot.
  bool _openByAccelerator(String accelerator) {
    final index = _indexFor(accelerator);
    if (index == null) return false;
    unawaited(_show(index));
    return true;
  }

  /// The same letter, pressed while a menu is already open — item 82.
  ///
  /// **It goes the way a hover does, and deliberately so.** Opening the next
  /// menu directly would leave two `_show` calls in flight: the one being
  /// closed finishes last and clears `_open`, so the menu that just opened
  /// would be drawn with no title lit under it. The queue that the pointer
  /// walking the row already uses has exactly this shape, and it is tested.
  ///
  /// The same letter again closes what is open, which is what a menu bar does
  /// everywhere.
  bool _switchByAccelerator(String accelerator) {
    final index = _indexFor(accelerator);
    if (index == null) return false;
    if (index != _open) _pending = index;
    Navigator.of(context).maybePop();
    return true;
  }

  /// Which title claims [accelerator], folded into the overflow if the row is
  /// too narrow to show it. Null when no title claims it, or when even the
  /// overflow button is not on screen.
  int? _indexFor(String accelerator) {
    for (var i = 0; i < widget.menus.length; i++) {
      if (widget.menus[i].accelerator?.toLowerCase() != accelerator) continue;
      final index = _rectFor(i) != null ? i : _overflowIndex;
      return _rectFor(index) == null ? null : index;
    }
    return null;
  }

  Rect? _rectFor(int index) {
    final box = _keys[index]?.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// The folded-away titles live behind one more button at the end of the row,
  /// which takes the index just past the real menus.
  int get _overflowIndex => widget.menus.length;

  /// How many titles the last layout had room for.
  ///
  /// Only [_onHoverWhileOpen] reads it, to know whether the overflow button is
  /// on screen. It is written during layout, which is why nothing rebuilds on
  /// the strength of it.
  int _shown = 0;

  Future<void> _show(int index) async {
    final rect = _rectFor(index);
    if (rect == null) return;

    final folded = index == _overflowIndex;
    setState(() {
      _open = index;
      _menuHasHighlight = false;
    });
    await showAppContextMenu(
      context: context,
      anchorRect: rect,
      // The title and its menu are one shape — see `_MenuOutline`. Unless the
      // monolith is turned off, and then they are two panels as before — and
      // two panels stand apart: touching along an edge, they read as one that
      // failed to join, so the menu drops five pixels.
      joined: widget.style.monolith,
      gap: widget.style.monolith ? 0 : _detachedGap,
      onHighlighted: (has) {
        if (mounted) setState(() => _menuHasHighlight = has);
      },
      // A folded title keeps its own menu, one level in, rather than having
      // its entries poured into a single flat list.
      nodes: folded
          ? [
              for (var i = _shown; i < widget.menus.length; i++)
                MenuGroup(widget.menus[i].label, widget.menus[i].build()),
            ]
          : widget.menus[index].build(),
      searchHint: folded
          ? tr('Search the menus')
          : tr('Search {menu}',
              {'menu': widget.menus[index].label.toLowerCase()}),
      style: widget.style,
      onPointerHover: _onHoverWhileOpen,
      onPointerDown: widget.onPressOutside,
      onAccelerator: _switchByAccelerator,
    );
    if (!mounted) return;
    setState(() {
      _open = null;
      _menuHasHighlight = false;
    });

    // Hovering a sibling closed this one and queued the next.
    final next = _pending;
    _pending = null;
    if (next != null) await _show(next);
  }

  /// The open menu forwards every hover, including over its modal barrier,
  /// which is the only way this row can see the pointer at all while a menu
  /// is up.
  void _onHoverWhileOpen(Offset position) {
    final current = _open;
    if (current == null || _pending != null) return;

    // Up to and including the overflow button, so walking the row reaches the
    // folded titles too. A title that is not on screen has no rectangle and is
    // skipped.
    for (var i = 0; i <= _overflowIndex; i++) {
      if (i == current) continue;
      final rect = _rectFor(i);
      if (rect != null && rect.contains(position)) {
        _pending = i;
        Navigator.of(context).maybePop();
        return;
      }
    }
  }

  void _onTap(int index) {
    // Clicking the open title closes it, as menu bars do everywhere.
    if (_open == index) {
      Navigator.of(context).maybePop();
      return;
    }
    unawaited(_show(index));
  }

  /// Padding a title carries either side of its text: the outer gap between
  /// titles plus the pill's own.
  static const double _titleChrome = 3 * 2 + 11 * 2;

  /// What the overflow button occupies once it is needed.
  static const double _overflowWidth = 16 + _titleChrome;

  double _titleWidth(String label, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + _titleChrome;
  }

  /// How many titles fit, folding from the right: the last menus are the ones
  /// a file manager can most afford to put a click further away.
  int _titlesThatFit(double available, TextStyle style) {
    final widths = [
      for (final menu in widget.menus) _titleWidth(menu.label, style),
    ];
    var total = 0.0;
    for (final width in widths) {
      total += width;
    }
    if (total <= available) return widths.length;

    // Once anything folds, the button to reach it has to fit as well.
    var used = _overflowWidth;
    var count = 0;
    for (final width in widths) {
      if (used + width > available) break;
      used += width;
      count++;
    }
    return count;
  }

  Color _labelColour(int index) => _open == index
      ? (widget.accent.computeLuminance() > 0.5 ? Colors.black : Colors.white)
      : widget.foreground;

  /// One title, with its Alt letter underlined while Alt is held.
  ///
  /// Underlined only then, which is what Windows has always done and the reason
  /// it works: the letters are out of the way until the moment they are the
  /// question being asked. Documented in the key bindings as well, but a binding
  /// that has to be looked up is a binding nobody uses.
  ///
  /// The underline goes on the *first* occurrence of the letter, so `Console`
  /// with `o` marks the `o` and not some other letter that happens to be there.
  /// A title whose letter is not in its label at all is simply drawn plain rather
  /// than having a mark put somewhere misleading.
  Widget _title(TitleBarMenu menu, TextStyle style) {
    final accelerator = menu.accelerator;
    final at = accelerator == null
        ? -1
        : menu.label.toLowerCase().indexOf(accelerator.toLowerCase());
    if (!_altHeld || at < 0) return Text(menu.label, style: style);

    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: menu.label.substring(0, at)),
          TextSpan(
            text: menu.label.substring(at, at + 1),
            style: const TextStyle(decoration: TextDecoration.underline),
          ),
          TextSpan(text: menu.label.substring(at + 1)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Measured in the face the titles are actually drawn in, so a font change
    // does not quietly leave the strip measuring the old one.
    final style = TextStyle(
      fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
      fontSize: context.watch<SettingsStore>().appearance.scaled(12.5),
      fontWeight: context.uiWeight(FontWeight.w500),
    );

    // Ask for the room to drag by, but not at the price of the whole menu. On
    // a narrow bar that reserve was swallowing every title, and a menu bar
    // entirely behind one button costs three taps to reach anything.
    _shown = widget.available <= 0
        ? 0
        : _titlesThatFit(widget.available - widget.dragArea, style);
    if (_shown == 0 && widget.dragArea > 0) {
      _shown = _titlesThatFit(widget.available, style);
    }

    // What the F10 selector may stand on: the titles the strip has room for,
    // and the button the folded ones live behind — which is where they are for
    // the pointer too, and the keyboard does not go where the pointer cannot.
    final anyFolded = _shown < widget.menus.length;
    widget.menuKeys?.registerMenus(
      _shown + (anyFolded ? 1 : 0),
      (index) => unawaited(_show(index == _shown ? _overflowIndex : index)),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _shown; i++)
          _pill(
            index: i,
            selected: widget.menuKeys?.isMenuSelected(i) ?? false,
            child: _title(
              widget.menus[i],
              // The weight never changes. Switching to a bolder face on open
              // re-measured the text and shifted it by a pixel.
              style.copyWith(color: _labelColour(i)),
            ),
          ),
        if (anyFolded)
          _pill(
            index: _overflowIndex,
            selected: widget.menuKeys?.isMenuSelected(_shown) ?? false,
            tooltip: tr('More menus'),
            child: Icon(
              Icons.more_horiz,
              size: 16,
              color: _labelColour(_overflowIndex),
            ),
          ),
      ],
    );
  }

  /// One title in the row: the hover and open states, and the accent pill that
  /// matches the one the menu itself puts under the row you are on.
  ///
  /// [selected] is the F10 selector standing on it with nothing unrolled yet. It
  /// is drawn as the hover is, with an outline on top: the fill alone would say
  /// "the pointer is here" when the pointer is nowhere near, and a bar entered
  /// from the keyboard has to show where the keyboard is.
  Widget _pill({
    required int index,
    required Widget child,
    bool selected = false,
    String? tooltip,
  }) {
    Widget button = MouseRegion(
      onEnter: (_) => setState(() => _hovered = index),
      onExit: (_) => setState(() => _hovered = null),
      child: GestureDetector(
        onTap: () => _onTap(index),
        child: Container(
          height: TitleBar.height,
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
          alignment: Alignment.center,
          // **The key is on the pill, not on the cell it sits in.** A menu
          // hangs off whatever this measures, and the cell is the full height
          // of the bar — so the menu opened at the bar's bottom edge with the
          // pill floating six pixels above it, looking like a menu belonging
          // to nothing in particular. The menu hangs directly under the
          // selector's pill instead.
          child: Container(
            key: _keyFor(index),
            // Ten and a one-pixel border, which is the eleven the row was
            // measured with — see [_titleChrome].
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // Open, the fill is the selector — until something *inside* the
              // menu is picked out, when the title takes **the menu's own
              // fill** and the two become one element: there is one selector
              // on screen and it is the row, not the title. The line round
              // both is drawn in `_MenuOutline`; nothing here draws it.
              color: _open == index
                  ? (_menuHasHighlight && widget.style.monolith
                        ? widget.style.surface
                        : widget.accent.withValues(alpha: 0.85))
                  : _hovered == index || selected
                  ? widget.accent.withValues(alpha: 0.28)
                  : Colors.transparent,
              // Always drawn, and merely invisible when there is nothing to
              // say: a border that comes and goes is a title that moves two
              // pixels every time the selector walks past it.
              border: Border.all(
                color: selected && _open != index
                    ? widget.accent
                    : Colors.transparent,
              ),
              // **The menu's own radius**, not a rounder one of its own: two
              // corner radii in one shape is two shapes, so the title takes
              // the radius the menu under it has.
              //
              // Square along the bottom only once the selection has moved
              // *inside* the menu: then the title is no longer the thing
              // selected, it is the top of the panel, and it runs into it.
              // While nothing in there is chosen the fill is still a
              // selector, and a selector is a pill.
              borderRadius:
                  _open == index && _menuHasHighlight && widget.style.monolith
                  ? const BorderRadius.vertical(
                      top: Radius.circular(kMenuCornerRadius),
                    )
                  : BorderRadius.circular(kMenuCornerRadius),
            ),
            child: child,
          ),
        ),
      ),
    );

    if (tooltip != null) {
      button = Hint(
        message: tooltip,
        wait: const Duration(milliseconds: 600),
        child: button,
      );
    }
    return button;
  }
}

/// The application's mark, and the name beside it.
///
/// The mark is the icon in the dock, drawn from the same painter rather than
/// copied — see [AppMarkPainter]. It takes the accent colour here instead of
/// the icon's blue, because the bar is whatever colour the user made it and a
/// fixed blue on a blue bar is a hole.
///
/// The name is [kAppTitle], in one colour. One constant, so the bar, the window
/// title and the About card cannot disagree about what the application is
/// called — and since 1.0.0.428 one colour in all three of them. A short name
/// written in two colours reads as two things, and the mark beside it already
/// carries the accent.
class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.accent, required this.foreground});

  final Color accent;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    // Set light and tracked wide. A title bar is not where an application
    // shouts its own name, and the mark beside it already carries the weight;
    // written this way the name reads as a label on the window rather than as
    // a logo stamped on it.
    //
    // Larger and looser than the old semibold on purpose: a light face set
    // small and tight reads as faint rather than as light.
    // Scaled with everything else. The weights below are the design and stay
    // put — the mark is set light on purpose — but its *size* is a size like
    // any other, and a name that stayed at 16 while the window around it grew
    // would read as the one thing that had shrunk.
    final style = TextStyle(
      fontSize: context.watch<SettingsStore>().appearance.scaled(16),
      letterSpacing: 1.4,
    );

    return Row(
      children: [
        AppMark(colour: accent, size: 24),
        const SizedBox(width: 9),
        // The bar's own ink, which is what every other word on the bar is
        // written in. The accent is on the mark to the left of it — a name that
        // borrowed the accent as well would be saying the same thing twice, an
        // inch apart.
        Text(
          kAppTitle,
          style: style.copyWith(
            fontWeight: FontWeight.w200,
            color: foreground,
          ),
        ),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 14,
    this.danger = false,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;

  /// Close gets the familiar red hover treatment.
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final background = !_hovered
        ? Colors.transparent
        : widget.danger
        ? const Color(0xFFC42B1C)
        : widget.color.withValues(alpha: 0.12);

    return Hint(
      message: widget.tooltip,
      wait: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 44,
            height: TitleBar.height,
            color: background,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hovered && widget.danger ? Colors.white : widget.color,
            ),
          ),
        ),
      ),
    );
  }
}
