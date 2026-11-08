import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
// **Flutter's windowing, experimental and private.** See
// `state/program_windows.dart` for what it is and why it is leaned on.
// ignore: implementation_imports, invalid_use_of_internal_member
import 'package:flutter/src/widgets/_window.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/plugins/plugin_registry.dart';
import 'core/settings/appearance_settings.dart';
import 'core/settings/backdrop_channel.dart';
import 'core/settings/settings_store.dart';
import 'core/settings/window_log.dart';
import 'core/settings/window_service.dart';
import 'core/window/x_window.dart';
import 'core/vfs/fs_registry.dart';
import 'state/app_state.dart';
import 'state/program_windows.dart';
import 'state/window_stack.dart';
import 'ui/commander_screen.dart';
import 'ui/motion.dart';
import 'ui/windows/detached_window.dart';
import 'ui/page_transition.dart';
import 'ui/text_scale.dart';

/// Wires the runtime state into the widget tree and builds the theme from the
/// user's appearance settings.
class XverbApp extends StatefulWidget {
  const XverbApp({super.key, required this.state});

  final AppState state;

  @override
  State<XverbApp> createState() => _XverbAppState();
}

class _XverbAppState extends State<XverbApp> with WindowListener {
  /// Every window the application has. The first one is the commander and is
  /// always there; the rest are views somebody detached.
  final ProgramWindows _windows = ProgramWindows();

  late WindowBackdrop _backdrop = widget.state.settings.appearance.backdrop;
  late bool _dark = widget.state.settings.appearance.darkChrome;
  late Color _tint = widget.state.settings.appearance.panelBackground;

  /// Whether the window is filling the screen, and so wants square corners.
  /// See [_rounded].
  bool _maximized = false;

  /// Whether this window has the focus. Starts true: the window is raised with
  /// it, and a blur arrives if it is not.
  final ValueNotifier<bool> _inFront = ValueNotifier(true);

  /// **The one place anything gets written on the way out.**
  ///
  /// The folder history is kept in memory while the application runs, at his
  /// word — walking a tree is thousands of navigations and a counter that
  /// touched the disk on each one would put a write between every folder and
  /// the next. That trade is only worth making if the write on the way out
  /// actually happens, which is what this is for.
  ///
  /// `onExitRequested` is the platform asking whether it may close, and it is
  /// the last moment there is. `onDetach` catches the rest — a window torn down
  /// without asking first — and is allowed to be too late on some platforms,
  /// because the alternative to a save that might not land is no save at all.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onExitRequested: () async {
      await _leave();
      return AppExitResponse.exit;
    },
    onDetach: () => unawaited(widget.state.saveOnExit()),
    // **The folder history counts time, and time behind another window is not
    // time spent in a folder.** Without this, leaving the application open on a
    // Friday afternoon would hand whatever folder was on screen the whole
    // weekend, and the top of that list would be decided by where somebody
    // stopped rather than by where they work. The platform's own signal rather
    // than an idle timer of ours: a timer would need a length, and any length
    // is a guess.
    onStateChange: (state) {
      final inFront = state == AppLifecycleState.resumed;
      widget.state.history.inFront(inFront);
      // **And write it down on the way out of the window**, not only on the way
      // out of the application. Switching to another program is a leaving: the
      // clock has just stopped, the time is banked, and this is the cheapest
      // moment there will ever be to put it on disk. Still not a poll — it
      // happens when somebody goes somewhere else, which is exactly when the
      // history has stopped changing.
      if (!inFront) unawaited(widget.state.saveOnExit());
      // **Coming back is when the drives are worth asking about.** Plugging a
      // stick in takes the person away from this window — the desktop pops up,
      // or the disk's own window does — and coming back is the moment they
      // expect it to be there. Cheaper and more accurate than any poll: it
      // happens exactly when somebody has been somewhere else.
      if (inFront) unawaited(widget.state.fileSystems.refreshRoots());
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle;
    widget.state.settings.addListener(_onSettingsChanged);
    _hearTheWindow();
    _tellInactiveOpacity();

    // The backdrop goes on after Flutter has painted; doing it earlier races
    // with the surface being created. See WindowService.revealAfterFirstFrame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WindowService.revealAfterFirstFrame(widget.state.settings.appearance);
      _rememberShape();
      // Startup has just applied it; the focus that follows must not race
      // with that by applying it a second time.
      _sinceBackdrop.reset();
    });
  }

  /// **Where the window's news comes from.**
  ///
  /// The same four facts either way — the keyboard arriving, the keyboard
  /// leaving, the shape changing and the window being asked to close. On a
  /// machine whose runner owns the window they come from it; everywhere else
  /// they are still `window_manager`'s, and the methods below are the same
  /// methods in both cases. See [XWindow] for why the window stopped being a
  /// plugin's.
  void _hearTheWindow() {
    if (!WindowService.isSupported) return;
    if (XWindow.isAvailable) {
      final window = XWindow.instance;
      window.focused.addListener(_frontChanged);
      window.maximized.addListener(_shapeChanged);
      window.keyboardIn.addListener(_keyboardMoved);
      window.onCloseRequested = onWindowClose;
      return;
    }
    windowManager.addListener(this);
  }

  void _stopHearingTheWindow() {
    if (!WindowService.isSupported) return;
    if (XWindow.isAvailable) {
      final window = XWindow.instance;
      window.focused.removeListener(_frontChanged);
      window.maximized.removeListener(_shapeChanged);
      window.keyboardIn.removeListener(_keyboardMoved);
      if (window.onCloseRequested == onWindowClose) {
        window.onCloseRequested = null;
      }
      return;
    }
    windowManager.removeListener(this);
  }

  void _frontChanged() {
    if (XWindow.instance.focused.value) {
      onWindowFocus();
    } else {
      onWindowBlur();
    }
  }

  void _shapeChanged() {
    _rememberShape();
    _restoreBackdrop('shape');
  }

  /// **The keyboard has moved to another of the application's windows.**
  ///
  /// Flutter's focus is one thing for the whole application, so it has to be
  /// carried: without this the commander's own keys were acted on by a
  /// detached window while the hand was in the commander — F3 opened nothing
  /// and Ctrl+Q did nothing until something was clicked. See
  /// [ProgramWindows.theKeyboardIsIn].
  void _keyboardMoved() =>
      _windows.theKeyboardIsIn(XWindow.instance.keyboardIn.value);

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.state.settings.removeListener(_onSettingsChanged);
    _stopHearingTheWindow();
    _inFront.dispose();
    _windows.dispose();
    super.dispose();
  }

  // Windows drops the composition effect when the window changes state, so it
  // has to be put back. Without this the acrylic survives startup and then
  // quietly disappears the first time the window is maximised or restored,
  // which reads as the feature breaking at random.
  /// **The window signals, which are the ones that arrive.**
  ///
  /// The folder history stops counting while the application is behind
  /// something else, and it was hung on `AppLifecycleListener` for that.
  /// Measured on macOS 2026-09-06: one run reported no lifecycle event at all,
  /// and the next reported `inactive` when focus left and never reported
  /// `resumed`. `window_manager` reports both halves, every time, and it is the
  /// listener this class already mixes in.
  ///
  /// The lifecycle listener stays as well. Two sources for one fact is fine
  /// when the fact is a boolean and both agree — and on a platform without a
  /// window manager it is the only one there is.
  @override
  void onWindowBlur() {
    _inFront.value = false;
    widget.state.history.inFront(false);
    unawaited(widget.state.saveOnExit());
  }

  /// The window has been asked to close, and is waiting to be told it may.
  ///
  /// **This is the way out that was missing.** `onExitRequested` covers the
  /// platform asking — Cmd+Q, a log-out — and covered nothing else: the button
  /// on our own title bar called `close()` straight through, and so did the
  /// system's. Everything kept in memory until the way out was therefore kept
  /// until the way out that never came.
  ///
  /// **It must always destroy.** A window that asks and is never answered is a
  /// window nobody can close, so the writing is wrapped and the destroying is
  /// not conditional on it.
  @override
  void onWindowClose() {
    unawaited(() async {
      await _leave();
      await WindowService.destroy();
      WindowLog.write('leaving: the window was asked to go');
    }());
  }

  /// What is owed on the way out, and nothing that can hold it up for long.
  ///
  /// **Both ways out come through here.** The window being asked to close and
  /// the platform asking whether it may are the same leaving, and the second
  /// one used to owe less than the first: it wrote the history down and left
  /// ten Python interpreters to be noticed by somebody else.
  ///
  /// **Speed is the whole point of the second half.** A plugin runs in a
  /// process of its own and does not end when this one decides to; it ends
  /// when its end of the pipe closes, which happens deep inside the engine
  /// shutting down — and on Windows the window stands on the screen, unpainted
  /// and answering nothing, for the whole of that. Killing them here, all at
  /// once and on a short leash, is what turns the wait into nothing worth
  /// watching. Every step says how long it took, because the next time this is
  /// slow the only useful question is which step it was.
  Future<void> _leave() async {
    final clock = Stopwatch()..start();

    try {
      await widget.state.saveOnExit();
    } on Object catch (error) {
      WindowLog.write('leaving: the save failed: $error');
    }
    WindowLog.write('leaving: saved, ${clock.elapsedMilliseconds}ms');

    // Wrapped and bounded for the same reason the destroying is unconditional:
    // a plugin that will not die is not a reason for a window nobody can
    // close. Whatever is still up when this gives in dies with the process.
    try {
      await widget.state
          .shutdown(patience: _pluginPatienceOnClose)
          .timeout(_shutdownPatience);
    } on Object catch (error) {
      WindowLog.write('leaving: the plugins did not stop: $error');
    }
    WindowLog.write('leaving: plugins stopped, ${clock.elapsedMilliseconds}ms');
  }

  /// How long one plugin is given to answer `shutdown` on the way out, and
  /// then to die once it has been killed. They are stopped together, so this
  /// is close to what stopping all of them costs.
  static const Duration _pluginPatienceOnClose = Duration(milliseconds: 400);

  /// And the whole of it, plugins and the connections they hold, is given this
  /// much before the window goes anyway.
  static const Duration _shutdownPatience = Duration(seconds: 2);

  @override
  void onWindowMaximize() {
    _rememberShape();
    _restoreBackdrop('maximize');
  }

  @override
  void onWindowUnmaximize() {
    _rememberShape();
    _restoreBackdrop('unmaximize');
  }

  @override
  void onWindowRestore() {
    _rememberShape();
    _restoreBackdrop('restore');
  }

  /// Asks the window whether it is maximised, because only it knows: the
  /// events say something changed, not what it changed to — a restore can land
  /// on either shape depending on what the window was before it was minimised.
  Future<void> _rememberShape() async {
    final maximized = await WindowService.isMaximized();
    WindowLog.write('shape: maximized=$maximized');
    if (mounted && maximized != _maximized) {
      setState(() => _maximized = maximized);
    }
  }

  /// Rounds the window's own corners, on the one platform where nothing else
  /// will.
  ///
  /// Windows and macOS round a window themselves, and go on doing it for a
  /// window whose frame has been hidden to make room for our title bar. The
  /// Linux window is left a rectangle, and what makes the corners ours to draw
  /// is that the window is transparent wherever this application does not
  /// paint — see [WindowService]. So the interface is clipped to a rounded
  /// rectangle and the corners are genuinely empty, rather than filled with a
  /// colour that would only look right against one wallpaper.
  ///
  /// Square again when the window fills the screen: rounded corners there
  /// leave four notches of desktop at the corners of the display, which is why
  /// every platform squares them off in exactly this case.
  Widget _rounded(Widget? child, {required ProgramWindow window}) {
    final content = child ?? const SizedBox.shrink();
    // **A detached window is never the maximised one.** The shape is reported
    // for the first window only — the runner tells Dart about that one, and a
    // detached window's own news does not arrive yet — so the others are
    // drawn as the ordinary rounded windows they are.
    final maximized = window.isMain && _maximized;
    final cutCorners = Platform.isLinux && !maximized;
    return Stack(
      children: [
        Positioned.fill(child: content),
        if (cutCorners)
          const Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: _CutCorners())),
          ),
        // **The window has a line round it**, like everything else in it. It
        // is drawn here rather than by the runner because the three platforms
        // round the window themselves and none of them will say by how much —
        // see [windowCornerRadius] for the numbers and how they were got.
        Positioned.fill(
          child: IgnorePointer(
            child: Consumer<SettingsStore>(
              builder: (context, settings, _) => CustomPaint(
                painter: _WindowOutline(
                  colour: settings.appearance.elementColor,
                  radius: maximized ? 0 : windowCornerRadius(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void onWindowMinimize() => WindowLog.write('event: minimize');

  /// Locking the session, a remote-desktop connection and DWM restarting all
  /// drop the window's composition attribute, and none of them announce
  /// themselves — the app simply loses its backdrop while nobody is looking.
  /// Regaining focus is the one signal that arrives afterwards in every one of
  /// those cases, so the backdrop is re-asserted there.
  ///
  /// Re-asserting the same effect does not blank the window first, so this is
  /// invisible when nothing was wrong. The throttle only keeps alt-tabbing
  /// from doing it dozens of times a minute.
  ///
  /// The wait exists because pressing the title bar to drag the window raises
  /// a focus event *before* the drag itself starts. Deferring lets the move
  /// announce itself and call the re-apply off.
  @override
  void onWindowFocus() {
    // **Said before anything else here can decline to do it.** The rest of this
    // method is about the backdrop and gives up early on a drag; the history
    // and the drives are about being back, and being back has happened.
    _inFront.value = true;
    widget.state.history.inFront(true);
    unawaited(widget.state.fileSystems.refreshRoots());

    if (_dragging || _sinceGesture.elapsed < _gestureGrace) {
      WindowLog.write('event: focus (drag; ignored)');
      return;
    }
    WindowLog.write('event: focus');
    if (_sinceBackdrop.elapsed < const Duration(seconds: 3)) return;

    Future<void>.delayed(_gestureGrace, () {
      if (!mounted || _dragging || _sinceGesture.elapsed < _gestureGrace) {
        WindowLog.write('focus: a drag followed; not re-applying');
        return;
      }
      _restoreBackdrop('focus');
    });
  }

  /// How long a focus event waits to see whether it was the start of a drag,
  /// and how long after one the next focus is still treated as part of it.
  static const Duration _gestureGrace = Duration(milliseconds: 400);

  /// Whether the user currently has the window by its title bar or an edge.
  bool _dragging = false;

  /// Time since that gesture ended.
  ///
  /// Moving or resizing the window raises `WM_NCACTIVATE`, which arrives here
  /// as a focus event — and a focus event otherwise means "the backdrop was
  /// dropped, put it back". Re-asserting it in the middle of a drag is at best
  /// wasted work and, while the package was doing the applying, was a visible
  /// flash of the bare window every time the user moved it. A drag is not a
  /// lost backdrop, so the focus belonging to one is ignored.
  final Stopwatch _sinceGesture = Stopwatch()..start();

  /// `WM_MOVING`/`WM_SIZING`, so these arrive on every mouse move. Only the
  /// first is logged: writing a line per event would stall the drag it is
  /// meant to be diagnosing.
  void _gestureStarted(String what) {
    _sinceGesture.reset();
    if (_dragging) return;
    _dragging = true;
    WindowLog.write('event: $what started');
  }

  void _gestureEnded(String what) {
    _dragging = false;
    _sinceGesture.reset();
    WindowLog.write('event: $what');
  }

  @override
  void onWindowMove() => _gestureStarted('move');

  @override
  void onWindowResize() => _gestureStarted('resize');

  @override
  void onWindowResized() => _gestureEnded('resized');

  @override
  void onWindowEnterFullScreen() => _restoreBackdrop('fullscreen');

  @override
  void onWindowLeaveFullScreen() => _restoreBackdrop('leave fullscreen');

  @override
  void onWindowMoved() => _gestureEnded('moved');

  /// Time since the backdrop was last put back, so a burst of events cannot
  /// turn into a burst of native calls.
  final Stopwatch _sinceBackdrop = Stopwatch()..start();

  void _restoreBackdrop(String reason) {
    final appearance = widget.state.settings.appearance;
    WindowLog.write('event: $reason');
    if (appearance.backdrop == WindowBackdrop.opaque) return;
    _sinceBackdrop.reset();
    WindowService.reapplyBackdrop(appearance, reason: reason);
  }

  /// What the runner was last told about the inactive opacity, so a settings
  /// change that is about something else does not resend it.
  (double, double, Duration)? _toldInactive;

  void _tellInactiveOpacity() {
    if (!BackdropChannel.fadesWholeWindow) return;
    final appearance = widget.state.settings.appearance;
    final told = (
      appearance.inactiveGlassOpacity,
      appearance.inactiveInterfaceOpacity,
      appearance.animated(kWindowFocusFadeDuration),
    );
    if (told == _toldInactive) return;
    _toldInactive = told;
    unawaited(
      BackdropChannel.setInactiveOpacity(told.$1, told.$2, told.$3),
    );
  }

  /// **How strongly the interface is drawn**, now that the window is or is not
  /// in front — the drawing's layer of the fade, and nothing of the window's.
  ///
  /// Three answers, by how much of the fade the platform's runner could take:
  ///
  /// - **macOS** fades the Flutter view itself, per window, so there is
  ///   nothing to do here and this stays solid.
  /// - **Windows** has one layered alpha for a whole window and nothing to aim
  ///   at the drawing alone, so the drawing's half is done here.
  /// - **Linux** has no native half at all, so the interface carries the whole
  ///   figure and the backdrop behind it does not move.
  double _interfaceOpacity(AppearanceSettings appearance,
      {required bool inFront}) {
    if (inFront || BackdropChannel.fadesTheDrawing) return 1;
    if (BackdropChannel.fadesWholeWindow) {
      return appearance.inactiveInterfaceOpacity;
    }
    return appearance.inactiveWindowOpacity;
  }

  /// Re-applies the native backdrop when the user changes it, rather than
  /// making them restart.
  void _onSettingsChanged() {
    _tellInactiveOpacity();
    final appearance = widget.state.settings.appearance;
    // The panel colour is the backdrop's tint, so it has to re-apply too;
    // otherwise changing the palette leaves the window tinted with the old one.
    if (appearance.backdrop == _backdrop &&
        appearance.darkChrome == _dark &&
        appearance.panelBackground == _tint) {
      return;
    }
    _backdrop = appearance.backdrop;
    _dark = appearance.darkChrome;
    _tint = appearance.panelBackground;
    WindowService.reapplyBackdrop(appearance, reason: 'settings changed');
    _carryBackdropToTheOthers();
  }

  /// **A backdrop chosen in the settings is the application's, not one
  /// window's.** `WindowService` speaks to the window the application started
  /// in; the windows it opened are told here, so a detached view does not sit
  /// in the look the application had when it was detached.
  void _carryBackdropToTheOthers() {
    if (!XWindow.isAvailable) return;
    final appearance = widget.state.settings.appearance;
    for (final window in _windows.all) {
      if (window.isMain) continue;
      unawaited(
        WindowService.applyBackdropTo(appearance,
            handle: window.nativeHandle),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: widget.state),
        ChangeNotifierProvider<SettingsStore>.value(
          value: widget.state.settings,
        ),
        ChangeNotifierProvider<PluginRegistry>.value(
          value: widget.state.plugins,
        ),
        ChangeNotifierProvider<FileSystemRegistry>.value(
          value: widget.state.fileSystems,
        ),
        ChangeNotifierProvider<ProgramWindows>.value(value: _windows),
      ],
      // **Every window the application has, drawn from one tree.** What
      // stands above this line is inherited widgets and nothing else, which
      // is the whole rule for being above a set of views: a widget with a
      // render object of its own has no single tree to draw into. One state,
      // one set of settings, one plugin registry — and as many windows as
      // somebody has detached views into. Below here everything belongs to
      // one window.
      child: ListenableBuilder(
        listenable: _windows,
        builder: (context, _) => ViewCollection(
          views: [for (final window in _windows.all) _inItsView(window)],
        ),
      ),
    );
  }

  /// One window, in the view that belongs to it.
  ///
  /// The first window's view is the one the runner made and the engine was
  /// handed; a window the application opened carries its own, and
  /// `RegularWindow` keeps the two in step.
  Widget _inItsView(ProgramWindow window) {
    final root = KeyedSubtree(
      key: ValueKey(window.id),
      child: _OneWindow(window: window, app: this),
    );
    final controller = window.controller;
    if (controller == null) {
      return View(view: firstWindowView(), child: root);
    }
    // ignore: invalid_use_of_internal_member
    return RegularWindow(controller: controller, child: root);
  }

  /// Everything inside one window: its theme, its pages, its own fade and its
  /// own outline. Called by [_OneWindow], which is a widget so that each
  /// window has a place of its own to keep state in.
  Widget _buildWindow(
    BuildContext context,
    ProgramWindow window, {
    WindowStack? desk,
  }) {
    return Consumer<SettingsStore>(
        builder: (context, settings, _) {
          final appearance = settings.appearance;
          final theme = ThemeData(
              useMaterial3: true,
              brightness: appearance.darkChrome
                  ? Brightness.dark
                  : Brightness.light,
              colorSchemeSeed: appearance.accentColor,
              visualDensity: VisualDensity.compact,
              // The chosen family is the application's font, not the file
              // listing's. Setting it only on the panel rows was the reason
              // changing it read as doing nothing: the column headers, the
              // path bar, the status bar and the function keys all carried on
              // in the platform default, and a listing is a small part of the
              // window. Places that genuinely need fixed pitch — the command
              // line, the viewers, plugin output — ask for 'monospace'
              // explicitly and still get it.
              fontFamily: appearance.uiFamily,
              // A chosen font is a Latin font, and a language it cannot draw
              // comes out as rows of boxes. The fallback stack is what the
              // platforms ship with the glyphs — named rather than detected,
              // because the alternative is finding out at the user's end that
              // the family they picked has no kanji in it.
              fontFamilyFallback: settings.resolvedLanguage.needsWideCoverage
                  ? _wideCoverageFontsFor(settings.resolvedLanguage.code)
                  : null,
              // A backdrop effect only shows through if nothing paints over it.
              scaffoldBackgroundColor:
                  appearance.backdrop == WindowBackdrop.opaque
                  ? null
                  : Colors.transparent,
              // Which is also why the page transition is ours: the stock ones
              // paint over the backdrop for the length of the animation and
              // then stop, which is what made going to the settings look like
              // three separate events. See BackdropPageTransitionsBuilder.
              pageTransitionsTheme: kPageTransitions,
              // **A switch that picks one of a few is an outlined pill**, not
              // a bright tile. Material's own answer is a block of colour with
              // corners of its own inside a rounded box — two shapes, neither
              // agreeing with the other's radius, which at a settings page's
              // reading distance looks like a sticker stuck onto the control.
              // One line round all of them, and the chosen one carries a
              // breath of the accent: enough to say *this one*, and it leaves
              // the accent to mean what it means everywhere else.
              segmentedButtonTheme: SegmentedButtonThemeData(
                style: ButtonStyle(
                  shape: const WidgetStatePropertyAll(StadiumBorder()),
                  side: WidgetStatePropertyAll(
                    BorderSide(color: appearance.chromeRule),
                  ),
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? appearance.accentColor.withValues(alpha: 0.22)
                        : Colors.transparent,
                  ),
                  foregroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? appearance.panelForeground
                        : appearance.panelForeground.withValues(alpha: 0.7),
                  ),
                  overlayColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                ),
              ),
              // **A scroll bar is a line.** Three pixels at rest, six under
              // the pointer — narrow, because what it is next to is the thing
              // being read; and it says where it is by growing rather than by
              // taking a band of colour along the edge.
              scrollbarTheme: ScrollbarThemeData(
                thickness: WidgetStateProperty.resolveWith(
                  (states) =>
                      states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.dragged)
                      ? 6.0
                      : 3.0,
                ),
                thumbColor: WidgetStateProperty.resolveWith(
                  (states) => appearance.panelForeground.withValues(
                    alpha:
                        states.contains(WidgetState.hovered) ||
                            states.contains(WidgetState.dragged)
                        ? 0.45
                        : 0.25,
                  ),
                ),
                radius: const Radius.circular(3),
                crossAxisMargin: 2,
                mainAxisMargin: 2,
                interactive: true,
              ),
          );

          return MaterialApp(
            title: 'xverb',
            debugShowCheckedModeBanner: false,
            // No cross-fade between themes. `MaterialApp` lerps a theme change
            // over `kThemeAnimationDuration` by default, and while a slider is
            // being dragged every new value restarts that 200ms — so the text
            // theme spent the whole drag chasing and never arrived, and the
            // settings form looked as though it were ignoring its own slider.
            // The panels read the settings directly and moved at once, which is
            // what made the two halves of the window disagree.
            themeAnimationDuration: Duration.zero,
            // The chosen size is the application's size, exactly as the family
            // above is the application's font — and for the same reason, found
            // the same way. Setting it on the panels alone left the menus, the
            // dialogs and the settings forms at Material's own sizes, so
            // turning the listing up to 20 grew the listing and nothing it
            // opened. A factor rather than a size: the theme carries a dozen of
            // them in proportion to each other, and that proportion is
            // Material's to keep, not ours to re-decide.
            //
            // On the *typography*, not on `textTheme`, and the difference is
            // the whole of why this took three goes. `ThemeData.textTheme`
            // holds styles with no size at all — the sizes live in the
            // typography's geometry and `ThemeData.localize` merges them in
            // afterwards. Scaling the text theme therefore scaled almost
            // nothing and the form went on being drawn at 16.
            //
            // At the default size the factor is 1 and the typography is handed
            // back untouched, which is what makes this safe to add to a design
            // that was drawn without it.
            //
            // The interface weight rides along, and for the third time it is
            // the same lesson: a weight set on the panels is a weight the
            // menus and the forms never hear about. It goes on as a shift of
            // Material's own weights rather than one weight over all of them,
            // so the theme's hierarchy — body, then labels a step above it —
            // survives being moved. See `AppearanceSettings.uiWeightShift`.
            theme: theme.copyWith(
              typography: scaledTypography(
                theme.typography,
                appearance.fontScale,
                appearance.uiWeightShift,
              ),
            ),
            // **A window behind another says so**, in two layers that
            // multiply: the window itself steps back half as far as the
            // interface drawn on it — see `kWindowShareOfTheFade`. The
            // window's layer is always the runner's; this is the interface's,
            // and which figure it takes depends on how much the runner could
            // carry. See [_interfaceOpacity].
            // **Whether *this* window is in front.** With several windows
            // the application being in front and this window having the
            // keyboard are different facts, and the fade means the second
            // one: a window somebody has just detached a view into must not
            // be drawn as though it were the one behind.
            builder: (context, child) => ValueListenableBuilder<bool>(
              valueListenable:
                  window.isMain ? _inFront : window.hasTheKeyboard,
              builder: (context, inFront, content) => AnimatedOpacity(
                opacity: _interfaceOpacity(appearance, inFront: inFront),
                duration: appearance.animated(kWindowFocusFadeDuration),
                curve: inFront ? kArrivingCurve : kLeavingCurve,
                child: content,
              ),
              child: _rounded(child, window: window),
            ),
            // **What the window is for.** The first one is the commander; a
            // window somebody detached a view into shows that view and
            // nothing else, and never becomes a second file manager.
            home: window.content == null
                // The first window: its dialogs are the application's own
                // desk, offered through the same scope a detached window
                // offers its own, so nothing has two questions to ask.
                ? WindowStackScope(
                    stack: widget.state.windows,
                    child: const CommanderScreen(),
                  )
                // **A window that holds one detached thing.** What "back"
                // means in it is the window closing, which is what the scope
                // carries — see [leaveThePage].
                // **And a desk of its own.** A detached page lives by
                // itself: what the commander is busy with — a folder being
                // read, a copy, a question — is the commander's, and never
                // comes up over a view that was taken out of it.
                : DetachedWindowScope(
                    close: () => _windows.close(window),
                    handle: window.nativeHandle,
                    child: WindowStackScope(
                      stack: desk ?? WindowStack(),
                      child: Builder(builder: window.content!),
                    ),
                  ),
          );
        },
      );
  }
}

/// One window of the application, as a widget.
///
/// It exists so that every window has a place of its own to keep state in —
/// which, when a window is adopted and sized, is where that happens. What it
/// draws is the application's, and comes from [_XverbAppState._buildWindow].
class _OneWindow extends StatefulWidget {
  const _OneWindow({required this.window, required this.app});

  final ProgramWindow window;
  final _XverbAppState app;

  @override
  State<_OneWindow> createState() => _OneWindowState();
}

class _OneWindowState extends State<_OneWindow> {
  /// **This window's own focus.** One scope per window, because Flutter's
  /// focus is one thing for the whole application: the window the platform
  /// gives the keyboard to is asked for this back, and a scope remembers
  /// what in it last had it. Owned here because a widget's state is what can
  /// own a focus node's lifetime.
  late final FocusScopeNode _focus = FocusScopeNode(
    debugLabel: 'window ${widget.window.id}',
  );

  /// **This window's desk**, the stack its internal windows open on. The
  /// first window's is the application's own; every other window has one of
  /// its own, owned here for the same reason as the focus.
  late final WindowStack? _desk =
      widget.window.isMain ? null : WindowStack();

  @override
  void initState() {
    super.initState();
    final window = widget.window;
    window.focus = _focus;
    if (window.isMain) return;
    // **A window the framework made comes up as the platform's**: its own
    // title bar over an unpainted view, and none of the application's look.
    // The runner is the only side holding the window, so it is told where
    // this one is and does to it what it did to the first — after the first
    // frame, because the address is good once the window is really there.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final handle = window.nativeHandle;
      await XWindow.instance.adopt(handle);
      if (!mounted) return;
      // Taking the platform's bar off gives the drawing its full height, so
      // the size is said again in what the application draws.
      await XWindow.instance
          .setClientSize(handle, ProgramWindows.defaultSize);
      if (!mounted) return;
      await WindowService.applyBackdropTo(
        context.read<SettingsStore>().appearance,
        handle: handle,
      );
    });
  }

  @override
  void dispose() {
    if (widget.window.focus == _focus) widget.window.focus = null;
    _focus.dispose();
    _desk?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusScope(
        node: _focus,
        child: widget.app._buildWindow(context, widget.window, desk: _desk),
      );
}

/// **How much the platform rounds this window by.**
///
/// Nothing reports it, so each number is what the platform actually does: a
/// line drawn at a smaller radius than the window's has its corner cut off by
/// the window's own shape, and one drawn at a larger radius pulls inside and
/// leaves a bare crescent beyond it. Both read as a defect rather than as a
/// style.
///
/// - **macOS** rounds at 16 from Tahoe (major 26) and at 10 before it.
/// - **Windows 11** rounds at 8; Windows 10 — build below 22000 — does not
///   round at all, so the line is a rectangle there.
/// - **Linux** is not rounded by anybody: the corners are ours, cut in
///   [_CutCorners], and the line follows that radius.
double windowCornerRadius() {
  if (Platform.isLinux) return _CutCorners.radius;
  final version = Platform.operatingSystemVersion;
  if (Platform.isMacOS) {
    final major = int.tryParse(
      RegExp(r'(\d+)').firstMatch(version)?.group(1) ?? '',
    );
    return (major ?? 0) >= 26 ? 16 : 10;
  }
  final build = int.tryParse(
    RegExp(r'Build (\d+)').firstMatch(version)?.group(1) ?? '',
  );
  return (build ?? 0) >= 22000 ? 8 : 0;
}

/// The line round the window, drawn over everything and answering no presses.
///
/// Inset by half its own width, because a stroke straddles the path it is
/// given: laid on the window's very edge, half of it would be outside the
/// shape the platform masks and the line would come out half as strong as
/// every other line in the window.
class _WindowOutline extends CustomPainter {
  const _WindowOutline({required this.colour, required this.radius});

  final Color colour;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_WindowOutline old) =>
      old.colour != colour || old.radius != radius;
}

/// Takes the four corners out of the window, softly.
///
/// Three ways were tried. [ClipRRect] rounds the corner and leaves a
/// staircase: a clip is a yes-or-no decision per pixel, and Impeller makes it
/// without antialiasing here. `BlendMode.clear` does the same, for the same
/// reason — it ignores how much of the pixel the shape actually covers and
/// takes all of it.
///
/// [BlendMode.dstOut] is the one that works. It multiplies what is already
/// there by what the shape does *not* cover, and the coverage along a curve is
/// a fraction — so the pixels on the curve keep a fraction of their alpha, and
/// the corner reads as round instead of as steps. Antialiasing itself is fine
/// on this platform; a circle drawn here comes out smooth. It was only ever
/// the two ways of taking pixels away that were not.
class _CutCorners extends CustomPainter {
  const _CutCorners();

  /// The radius the whole interface is rounded by. Linux repeats it in
  /// `linux/runner/my_application.cc`, which asks KWin to blur the same shape
  /// behind the window: the two live on opposite sides of the engine and
  /// neither can ask the other, so they are kept in step by hand.
  static const double radius = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final corners = Path.combine(
      PathOperation.difference,
      Path()..addRect(rect),
      Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius))),
    );
    canvas.drawPath(
      corners,
      Paint()
        // Opaque, because `dstOut` takes away as much as this paint covers:
        // a transparent one would take away nothing.
        ..color = const Color(0xFFFFFFFF)
        ..blendMode = BlendMode.dstOut
        ..isAntiAlias = true
        // And blurred by half a pixel, which is what actually softens the
        // curve. Antialiasing would have, and does not here: coverage is
        // rounded to all or nothing before it reaches the alpha channel. A
        // blur puts the fraction in the paint itself instead, where nothing
        // can round it away.
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.6),
    );
  }

  @override
  bool shouldRepaint(_CutCorners old) => false;
}

/// Faces to fall back to for a language the interface font cannot draw.
///
/// One per platform, in the order they are likely to exist; anything absent is
/// skipped. These are the families the systems themselves use, so the
/// application looks like the machine it is running on rather than carrying a
/// megabyte of font in the bundle to look the same everywhere.
///
/// **Both scripts are listed, because neither covers the other.** The Japanese
/// faces a system ships have no Hangul in them, and the Korean ones no kana —
/// Hiragino Sans and Apple SD Gothic Neo are two different families, as are Yu
/// Gothic and Malgun Gothic. The fallback is walked per glyph, so a list that
/// names both answers for either language and a list that names one leaves the
/// other in boxes. Chinese has faces of its own — see [_wideCoverageFontsFor].
List<String> _wideCoverageFontsFor(String language) =>
    language.startsWith('zh') ? _chineseFirstFonts : _wideCoverageFonts;

/// The faces the systems ship for Simplified Chinese.
const List<String> _chineseFaces = [
  'PingFang SC', // macOS
  'Microsoft YaHei UI', // Windows
  'Microsoft YaHei',
  'Noto Sans CJK SC', // Linux
  'Noto Sans SC',
  'Source Han Sans SC',
];

/// **Ahead of the rest, because the order decides how a character is drawn**,
/// not only whether. The Japanese and Korean faces carry Han characters too,
/// in their own forms, and the fallback takes the first face that has the
/// glyph: listed after Hiragino, a Chinese interface would be set in Japanese
/// shapes, and the simplified characters Hiragino has not got would drop to
/// the next face — one word in two typefaces.
const List<String> _chineseFirstFonts = [
  ..._chineseFaces,
  ..._wideCoverageFonts,
];

const List<String> _wideCoverageFonts = [
  'Hiragino Sans', // macOS, Japanese
  'Hiragino Kaku Gothic ProN', // macOS, older
  'Apple SD Gothic Neo', // macOS, Korean
  'Yu Gothic UI', // Windows, Japanese
  'Meiryo', // Windows, older
  'Malgun Gothic', // Windows, Korean
  'Noto Sans CJK JP', // Linux
  'Noto Sans CJK KR',
  'Noto Sans JP',
  'Noto Sans KR',
  'Source Han Sans JP',
  'Source Han Sans KR',
];
