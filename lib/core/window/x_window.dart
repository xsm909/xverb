import 'dart:async';
import 'dart:io';
import 'dart:ui' show FlutterView;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

/// The application's own window, spoken to directly.
///
/// **Why not a plugin.** `window_manager` and `flutter_acrylic` are plugins,
/// and a plugin reaches its window through `registrar.view?.window`. The
/// moment the engine is told to accept several views there is no such view:
/// `window_manager` force unwraps it and the application dies inside
/// `ensureInitialized()` before a single frame is drawn — *Swift runtime
/// failure: force unwrapped a nil value*, measured here on 3.47.2, not read.
/// Several views is the whole of detaching a view into a window of its own,
/// so the window is done in the runner, where the `NSWindow` is in hand.
///
/// **It is one platform at a time, deliberately.** [isAvailable] answers for
/// the platforms whose runner has the channel; everywhere else
/// `WindowService` goes on using the packages exactly as before, and nothing
/// about those machines changes until their runner answers too. See
/// `macos/Runner/MainFlutterWindow.swift`, `WindowChannel`, and
/// `windows/runner/window_channel.cpp`.
class XWindow extends ChangeNotifier {
  XWindow._() {
    if (isAvailable) _channel.setMethodCallHandler(_fromTheWindow);
  }

  static final XWindow instance = XWindow._();

  static const MethodChannel _channel = MethodChannel('xverb/window');

  /// Whether the runner on this machine answers this channel.
  ///
  /// macOS and Windows. The Linux runner still leaves the window to
  /// `window_manager`, and the detaching that needs this is gated on the
  /// same answer.
  static bool get isAvailable => Platform.isMacOS || Platform.isWindows;

  /// **Whether the glass is this channel's too.** On the Mac the runner puts
  /// the material on ([applyBackdrop]); on Windows the accent has had a
  /// channel of its own since before any of this, `xverb/backdrop`, which
  /// takes a window's address as well. See `WindowService.applyBackdropTo`.
  static bool get ownsTheGlass => Platform.isMacOS;

  /// Whether the window has the keyboard. The interface fades a little when
  /// it has not, to say the window is behind another.
  final ValueNotifier<bool> focused = ValueNotifier(true);

  /// **Which of the application's windows is being typed into**, by the
  /// address the runner knows it by: nought for the window the application
  /// started in, and null when none of them has the keyboard.
  ///
  /// **Because Flutter's focus is one thing for the whole application**, not
  /// one per window. Every key goes to whatever took the focus last, wherever
  /// that is, so a view detached into a window of its own takes the keyboard
  /// with it and the commander's own keys are acted on by the detached window
  /// while the hand is in the first one. The platform knows which window is
  /// being typed into; this is it saying so, and
  /// `ProgramWindows.theKeyboardIsIn` is what moves the focus there.
  final ValueNotifier<int?> keyboardIn = ValueNotifier<int?>(0);

  /// Whether the window fills the screen, which decides whether its corners
  /// are rounded. Reported by the runner rather than asked for: the events
  /// say something changed, and only the window knows what it changed to.
  final ValueNotifier<bool> maximized = ValueNotifier(false);

  /// **The window has been asked to close and is waiting to be told it may.**
  ///
  /// Everything held in memory until the way out — the folder history above
  /// all — is written here, and [destroy] is what finally closes it. A window
  /// that asks and is never answered is a window nobody can close, so
  /// whoever listens must always end at [destroy].
  VoidCallback? onCloseRequested;

  Future<void> _fromTheWindow(MethodCall call) async {
    switch (call.method) {
      case 'focus':
        focused.value = true;
      case 'blur':
        focused.value = false;
      case 'shape':
        final args = call.arguments as Map<Object?, Object?>? ?? const {};
        maximized.value = args['maximized'] as bool? ?? false;
      case 'keyboard':
        final args = call.arguments as Map<Object?, Object?>? ?? const {};
        keyboardIn.value = (args['handle'] as num?)?.toInt();
      case 'closing':
        onCloseRequested?.call();
    }
    notifyListeners();
  }

  /// Puts the window on screen. **Called once Flutter has painted**: a window
  /// that comes up grey and fills a moment later is the application jumping
  /// in front of whoever opened it.
  Future<void> show() => _invoke('show');

  /// **The three acts and the drag take a window.** Null is the window the
  /// application started in; an address is one of the windows it opened, and
  /// the buttons in *that* window's bar have to act on it rather than on the
  /// first one. That was the whole reason a plugin could not be left in
  /// charge of this.
  Future<void> minimize({int? handle}) =>
      _invoke('minimize', {'handle': ?handle});

  Future<void> toggleMaximize({int? handle}) =>
      _invoke('toggleMaximize', {'handle': ?handle});

  Future<bool> isMaximized() async =>
      await _ask<bool>('isMaximized') ?? maximized.value;

  /// Asks the window to close, which raises [onCloseRequested] rather than
  /// closing anything. This is what the platform's own ways out do as well —
  /// Cmd+W, the menu — so there is one way out and it is the tested one.
  Future<void> requestClose() => _invoke('requestClose');

  /// Closes it for real, once whoever was asked has finished.
  Future<void> destroy() => _invoke('destroy');

  Future<void> startDragging({int? handle}) =>
      _invoke('startDrag', {'handle': ?handle});

  /// Glass or paint, as the appearance says.
  ///
  /// [backdrop] is the index of `WindowBackdrop`, and the runner maps it to
  /// the same `NSVisualEffectView` material the package used to set, so the
  /// window looks exactly as it did. The tint and the dark flag are not sent
  /// because `flutter_acrylic` on macOS ignored both: it set a material and
  /// nothing else, and matching today's window means doing the same.
  /// Answers with what the window says it is made of — the material behind
  /// it, whether it is opaque, whether the glass really is below the drawing
  /// — which goes into the window log. The window cannot be photographed
  /// from outside without a permission this machine does not give, so it is
  /// asked instead.
  Future<String?> applyBackdrop(int backdrop, {int? handle}) async {
    if (!ownsTheGlass) return null;
    try {
      return await _channel.invokeMethod<String>('backdrop', {
        'backdrop': backdrop,
        'handle': ?handle,
      });
    } on Object {
      return null;
    }
  }

  /// **Takes a window the framework made into the application's own look.**
  /// A window opened by the windowing API comes up with the platform's title
  /// bar on it, and this application draws its own; the runner is the only
  /// side that holds an `NSWindow`, so it is told the address of the new one
  /// and does to it what it did to the first.
  ///
  /// The address is a pointer the windowing API hands out and is good only
  /// while the window is alive, which is why it is read and used in the same
  /// breath rather than kept.
  /// Brings one of the application's own windows forward.
  Future<void> raise(int? handle) async {
    if (handle == null) return;
    await _invoke('raise', {'handle': handle});
  }

  Future<void> adopt(int? handle) async {
    if (handle == null) return;
    await _invoke('adopt', {'handle': handle});
  }

  /// Makes what a window draws this big, keeping its top left where it is.
  /// The windowing API's own size is worked out for a frame with a title bar
  /// this application has taken off, and comes out a bar's height wrong.
  Future<void> setClientSize(int? handle, Size size) async {
    if (handle == null) return;
    await _invoke('setClientSize', {
      'handle': handle,
      'width': size.width,
      'height': size.height,
    });
  }

  /// **The first window, this big and in the middle of its screen.** Only
  /// the updater asks: it is a small window in the same program, made by the
  /// runner at the commander's size. Windows only — the Mac's `show` puts
  /// the starting size back.
  Future<void> placeFirstWindow(Size size) => _invoke('setClientSize', {
        'width': size.width,
        'height': size.height,
        'center': true,
      });

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    if (!isAvailable) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on Object {
      // A window call that fails must never be the reason the application
      // stops: every one of these is about how the window looks or behaves,
      // and none of them is worth a crash.
    }
  }

  Future<T?> _ask<T>(String method) async {
    if (!isAvailable) return null;
    try {
      return await _channel.invokeMethod<T>(method);
    } on Object {
      return null;
    }
  }
}

/// The view that has a window behind it.
///
/// With one view there is the implicit one and it is the window's; with
/// several, the engine keeps an implicit view that nothing is attached to and
/// the window's view beside it. The first view that is not the implicit one is
/// the right answer in both cases, and falling back to the implicit one keeps
/// a machine with no windowing drawing as it always did.
///
/// **Decided once, before any other window exists.** On Windows the first
/// window's view *is* the implicit one, so the search would fall through to
/// it — until a view is detached. Then the detached window's view is the
/// first one that is not implicit, both windows draw into it, and every frame
/// fails on every key they share ("Multiple widgets used the same
/// GlobalKey"), for as long as the second window lives. Found in xConsole,
/// paid for there, not here.
FlutterView firstWindowView() => _firstWindowView ??= _findFirstWindowView();

FlutterView? _firstWindowView;

FlutterView _findFirstWindowView() {
  final dispatcher = WidgetsBinding.instance.platformDispatcher;
  final implicit = dispatcher.implicitView;
  for (final view in dispatcher.views) {
    if (view != implicit) return view;
  }
  return implicit!;
}
