// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
// **Flutter's windowing, which is experimental and private.** It is not
// exported from `package:flutter/widgets.dart`, it is marked internal and it
// promises breaking changes in patch versions. It is leaned on deliberately:
// several windows on one engine is the only way a detached view keeps the
// state it was showing, because a second engine is a second isolate and
// neither a file system, a plugin process nor a reading can be handed across
// one. See `lib/core/window/x_window.dart` for the other half of this — the
// window's look, which no plugin can own once there are several views.
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_macos.dart';
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:flutter/widgets.dart' show FocusScopeNode, WidgetBuilder;

import '../core/window/x_window.dart';

/// One window of the application: what it shows, and what closing it means.
///
/// **The first window is not like the others.** It was made by the runner
/// before any of this ran, it holds the commander and it is never closed by
/// the application itself; the rest were made by the windowing API, show one
/// detached thing each, and go when that thing is done with.
class ProgramWindow {
  ProgramWindow({
    required this.id,
    this.controller,
    this.isMain = false,
    this.title = '',
    this.content,
    this.onGone,
    this.holding,
  });

  /// What this window holds, by the name the rest of the application knows it
  /// by — a plugin view's id, or a file's path for a reading.
  ///
  /// **One view is one thing wherever it is.** The page claim already says so
  /// of the full screen, and a window is no different: asked for again while
  /// a window has it, that window comes forward. See
  /// [ProgramWindows.raiseIfHolding].
  final String? holding;

  /// Ours, not the platform's: it names the window in the application's own
  /// bookkeeping and survives the view being made and unmade.
  final String id;

  /// What made it and what it answers to. **Null for the window the
  /// application was started in**, which the runner made.
  final RegularWindowController? controller;

  /// The window the application was started in. **Said rather than worked
  /// out** — "the one with no controller" is also what a window made for a
  /// test looks like.
  final bool isMain;

  /// What the window is called, for its own title bar.
  final String title;

  /// What it draws. Null for the first window, which draws the commander.
  final WidgetBuilder? content;

  /// What to let go of once the window has gone — the state the content was
  /// built over, which belongs to whoever detached it rather than to the
  /// widget that happened to be drawing it.
  final VoidCallback? onGone;

  /// **The focus inside this window.**
  ///
  /// Flutter keeps one focus for the whole application rather than one per
  /// window: every key goes to whatever took it last, whichever window the
  /// hand is in. So each window keeps a scope of its own, and the window the
  /// platform gives the keyboard to is asked for the focus back — see
  /// [ProgramWindows.theKeyboardIsIn]. Held by the widget that draws the
  /// window, which is the only thing that can own a focus node's lifetime.
  FocusScopeNode? focus;

  /// **Whether this is the window being typed into.** Not whether the
  /// application is in front: with several windows the two are different
  /// facts, and it is this one that the fade over the interface means.
  /// Starts true because a window is opened in front.
  final ValueNotifier<bool> hasTheKeyboard = ValueNotifier(true);

  /// **Whether the runner means this window**, by the number it names windows
  /// with: nought is the window the application started in — which has no
  /// address on this side, because the runner holds it — and anything else is
  /// the address of a window the application opened.
  bool answersTo(int? handle) =>
      handle != null && (isMain ? handle == 0 : nativeHandle == handle);

  /// The platform's own window behind this one, as a number the runner can
  /// turn back into a window. **Null for the first window**, which the runner
  /// already holds, and on any platform whose windowing does not hand the
  /// pointer out.
  int? get nativeHandle {
    final controller = this.controller;
    if (controller == null) return null;
    if (controller is WindowControllerMacOS) {
      return (controller as WindowControllerMacOS).windowHandle.address;
    }
    // And the HWND on Windows, when that runner is taught this channel.
    if (controller is WindowControllerWin32) {
      return (controller as WindowControllerWin32).windowHandle.address;
    }
    return null;
  }
}

/// Every window the application has.
///
/// **One engine, several windows.** Everything the application owns — the
/// file systems, the plugin processes, the settings, the readings — stays in
/// the one isolate; a window is a view of it. So detaching a view is handing
/// one object to another window, and what it was showing never notices.
typedef OpenWindow = ProgramWindow Function(
  String title,
  Size size,
  WidgetBuilder content,
  VoidCallback? onGone,
  String? holding,
  void Function() gone,
);

class ProgramWindows extends ChangeNotifier {
  ProgramWindows({OpenWindow? open})
      : _open = open ?? _nativeWindow,
        _handedAWayToOpen = open != null {
    _windows.add(ProgramWindow(id: 'main', isMain: true));
  }

  /// **Whether a window can be detached at all on this machine.** The
  /// windowing API is only half of it: the other half is a runner that can
  /// take the platform's bar off a window the framework made, and that is
  /// the same answer as the window layer's own.
  static bool get canDetach => XWindow.isAvailable;

  /// **How a window is made.** The platform's, unless something else is
  /// handed in — which is how a test gets a second window with no windowing
  /// API to make one with.
  final OpenWindow _open;

  /// Whether a way of making windows was handed in. A machine that supplies
  /// one can open them whatever the runner says, which is what lets the
  /// behaviour here be tested on a machine whose runner cannot.
  final bool _handedAWayToOpen;

  /// Whether *this* object can open a window.
  bool get canOpen => _handedAWayToOpen || canDetach;

  static int _made = 0;

  static ProgramWindow _nativeWindow(
    String title,
    Size size,
    WidgetBuilder content,
    VoidCallback? onGone,
    String? holding,
    void Function() gone,
  ) {
    _made++;
    return ProgramWindow(
      id: 'window-$_made',
      title: title,
      content: content,
      onGone: onGone,
      holding: holding,
      controller: RegularWindowController(
        size: size,
        title: title,
        delegate: _Gone(gone),
      ),
    );
  }

  final List<ProgramWindow> _windows = [];

  List<ProgramWindow> get all => List.unmodifiable(_windows);

  /// The window the application was started in, which holds the commander and
  /// is never closed from here.
  ProgramWindow get main => _windows.first;

  int get detachedCount => _windows.length - 1;

  ProgramWindow? byId(String id) {
    for (final window in _windows) {
      if (window.id == id) return window;
    }
    return null;
  }

  /// Opens a window of the application's own, showing [content].
  ///
  /// [onGone] is called when the window has gone, by whichever road — the
  /// application closing it or somebody pressing its own button — and is
  /// where the state behind [content] is let go of. Nothing is disposed here:
  /// a window goes on drawing what it was given for an animation after it
  /// leaves this list, so anything it may still be drawing must outlive the
  /// moment it was closed.
  ProgramWindow? open({
    required String title,
    required WidgetBuilder content,
    Size size = defaultSize,
    VoidCallback? onGone,
    String? holding,
  }) {
    if (!canOpen) return null;
    late final ProgramWindow window;
    window =
        _open(title, size, content, onGone, holding, () => closed(window));
    _windows.add(window);
    notifyListeners();
    return window;
  }

  /// What a window made for one detached thing is worth looking at in — not
  /// the size of whatever window it came out of.
  static const Size defaultSize = Size(900, 650);

  /// **Brings forward the window holding [what]**, and answers whether there
  /// was one. The caller's own copy is not made when this answers true: that
  /// is the whole of the one-page rule, moved up to windows.
  bool raiseIfHolding(String what) {
    for (final window in _windows) {
      if (window.holding != what) continue;
      unawaited(XWindow.instance.raise(window.nativeHandle));
      return true;
    }
    return false;
  }

  /// **Moves the focus into the window the platform is being typed into.**
  ///
  /// [handle] is what the runner reports: nought for the window the
  /// application started in, an address for one it opened, null when none of
  /// them has the keyboard. The window that has it is asked for its focus
  /// back — and only if it has not got it, so that a window already being
  /// typed into is not pulled off the box the cursor is in.
  void theKeyboardIsIn(int? handle) {
    for (final window in _windows) {
      final its = window.answersTo(handle);
      window.hasTheKeyboard.value = its;
      if (!its) continue;
      final focus = window.focus;
      // A scope remembers what in it had the focus, so asking the scope puts
      // the keyboard back exactly where this window left it.
      if (focus != null && !focus.hasFocus) focus.requestFocus();
    }
  }

  /// Whether a window holds [what].
  bool holds(String what) =>
      _windows.any((window) => window.holding == what);

  /// Closes a window of the application's own.
  void close(ProgramWindow window) {
    if (window.isMain) return;
    window.controller?.destroy();
  }

  /// A window that has gone, whether the application closed it or somebody
  /// pressed its own button.
  void closed(ProgramWindow window) {
    if (window.isMain || !_windows.contains(window)) return;
    _windows.remove(window);
    notifyListeners();
    // **After the list, and after this frame.** The window is still being
    // drawn while it leaves, and whatever the content was built over is what
    // it is drawing; letting go of it in the same breath is how a view
    // reaches into a disposed object inside a build that has already begun.
    Future<void>.microtask(() => window.onGone?.call());
  }

  @override
  void dispose() {
    for (final window in _windows) {
      if (!window.isMain) window.controller?.destroy();
    }
    _windows.clear();
    super.dispose();
  }
}

/// How the application hears that one of its windows is gone — including the
/// one case it cannot see coming, somebody pressing the window's own close.
class _Gone extends RegularWindowControllerDelegate {
  _Gone(this.tell);

  final VoidCallback tell;

  /// Somebody asked the platform to close the window. **Nothing here is
  /// asked about first**: a detached window holds a reading, not unsaved
  /// work, and the thing it was showing is still where it came from.
  @override
  void onWindowCloseRequested(RegularWindowController controller) =>
      controller.destroy();

  @override
  void onWindowDestroyed() => tell();
}
