import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// A window drawn inside the commander's own client area.
///
/// The geometry lives on the model rather than in the widget, so a window
/// survives a rebuild: the panels underneath refresh on their own schedule, and
/// a drag must not be interrupted when they do.
///
/// Each window is a [ChangeNotifier] of its own. Dragging one therefore
/// repaints that window instead of every window on the desk.
class DeskWindow extends ChangeNotifier {
  DeskWindow({
    required this.id,
    required String title,
    required this.builder,
    this.icon,
    this.preferredSize = const Size(880, 600),
    this.minSize = const Size(320, 200),
    this.resizable = true,
    this.modal = false,
    this.onDismiss,
    this.origin,
  }) {
    _title = title;
  }

  /// Where on screen the window was asked for, if anything could say — the
  /// rectangle of the row the cursor was on, or of the control that was
  /// pressed. The layer turns that rectangle into this window and back again;
  /// see `kWindowArriveDuration`.
  ///
  /// Global coordinates, taken at the moment of opening: the row it names may
  /// have scrolled away or stopped existing by the time the window closes, and
  /// a journey back to where it *was* is the honest one.
  final Rect? origin;

  /// Identity of the window. Opening a second window with the same id brings
  /// the existing one forward instead of stacking a duplicate.
  final String id;

  /// The window's contents. Called on every rebuild of the window, so it must
  /// be cheap; anything expensive belongs in the widget's own state.
  final WidgetBuilder builder;

  final IconData? icon;

  /// Size the window opens at, shrunk to fit when the desk is smaller.
  final Size preferredSize;

  /// The window never resizes below this, unless the desk itself is smaller.
  final Size minSize;

  final bool resizable;

  /// A modal window puts a barrier over everything below it, so the answer it
  /// is waiting for cannot be sidestepped. Windows opened after it are not
  /// covered — the barrier belongs under the front-most modal, not on top of
  /// the whole desk.
  final bool modal;

  /// What Escape and the close button do, when closing outright is the wrong
  /// answer. A progress window uses this to cancel the operation instead of
  /// abandoning it with no way back to it.
  final VoidCallback? onDismiss;

  /// What Enter does — the window's default button.
  ///
  /// It lives here, next to [onDismiss], rather than being a shortcut inside
  /// the contents, because a default button belongs to the window and not to
  /// whichever control happens to hold the keyboard. As a binding under the
  /// contents it only fired when something inside was focused, so a
  /// confirmation with nothing to type into ignored Enter altogether.
  ///
  /// [WindowForm] fills this in; the frame runs it. A field that wants Enter
  /// for itself still handles the key first and it never gets this far.
  VoidCallback? onSubmit;

  /// Position in the opening sequence. New windows are cascaded by it so they
  /// do not land exactly on top of each other.
  int cascade = 0;

  final Completer<Object?> _result = Completer<Object?>();

  /// Set while the window is open, so its own contents can close it without
  /// having to reach back through the widget tree for the stack.
  WindowStack? _stack;

  /// Completes when the window closes, carrying whatever was passed to
  /// [WindowStack.close] — enough to use a window the way a dialog is used.
  Future<Object?> get result => _result.future;

  /// Closes this window, handing [result] to whoever is awaiting it.
  void close([Object? result]) => _stack?.close(this, result);

  late String _title;

  String get title => _title;

  set title(String value) {
    if (_title == value) return;
    _title = value;
    notifyListeners();
  }

  Rect? _bounds;

  /// Null until the window has been laid out against a desk for the first time.
  Rect? get bounds => _bounds;

  bool _maximized = false;

  bool get maximized => _maximized;

  /// Where a maximised window goes back to.
  Rect? _restore;

  /// Places the window the first time it is shown, and afterwards keeps it on
  /// the desk — the app window can be resized under it.
  ///
  /// Called from the layer's build, so it deliberately does not notify: the
  /// caller paints the value it has just computed.
  void layout(Size desk) {
    if (_maximized) {
      _bounds = Offset.zero & desk;
      return;
    }
    final current = _bounds;
    _bounds = _fit(current ?? _initialBounds(desk), desk);
  }

  /// Moves or resizes the window, keeping it inside [desk].
  void place(Rect rect, Size desk) {
    final fitted = _fit(rect, desk);
    if (fitted == _bounds) return;
    _bounds = fitted;
    // Dragging a maximised window is not the same gesture as moving a floating
    // one, so the frame never starts one; a programmatic move still means the
    // window is no longer filling the desk.
    _maximized = false;
    notifyListeners();
  }

  void toggleMaximized(Size desk) {
    if (_maximized) {
      _maximized = false;
      _bounds = _fit(_restore ?? _initialBounds(desk), desk);
    } else {
      _restore = _bounds;
      _maximized = true;
      _bounds = Offset.zero & desk;
    }
    notifyListeners();
  }

  /// The gap left around a window that opens at its preferred size, so the desk
  /// is still visible behind it and the frame reads as a window.
  static const double _margin = 24;

  Rect _initialBounds(Size desk) {
    final size = Size(
      math.min(preferredSize.width, desk.width - 2 * _margin),
      math.min(preferredSize.height, desk.height - 2 * _margin),
    );
    // Five steps is enough to tell a small pile of windows apart, and it keeps
    // the sixth from marching off the desk.
    //
    // **But not for a modal.** A modal is the one thing on the desk that can be
    // answered, and there is never a second one to tell it apart from — the
    // next question comes after this one is closed. Cascading them walked the
    // window down and across the screen with every collision in a copy, so by
    // the tenth file the question was no longer where the eye had left it.
    // Centred, it comes back in the same place every time.
    final step = modal ? 0.0 : 26.0 * (cascade % 5);
    return Rect.fromLTWH(
      (desk.width - size.width) / 2 + step,
      (desk.height - size.height) / 2 + step,
      size.width,
      size.height,
    );
  }

  /// Clamps a rectangle to the desk, respecting [minSize] except on a desk that
  /// is smaller than it.
  Rect _fit(Rect rect, Size desk) {
    final deskWidth = math.max(desk.width, 1.0);
    final deskHeight = math.max(desk.height, 1.0);

    final width = _clamp(
      rect.width,
      math.min(minSize.width, deskWidth),
      deskWidth,
    );
    final height = _clamp(
      rect.height,
      math.min(minSize.height, deskHeight),
      deskHeight,
    );

    return Rect.fromLTWH(
      _clamp(rect.left, 0, deskWidth - width),
      _clamp(rect.top, 0, deskHeight - height),
      width,
      height,
    );
  }

  static double _clamp(double value, double low, double high) =>
      high <= low ? low : value.clamp(low, high);
}

/// Hands the [DeskWindow] down to its own contents.
///
/// The frame puts it in; `WindowForm` reads it to register the default button.
/// Without it a form has no way to reach the window it is inside, since it is
/// built by a plain builder rather than pushed as a route.
class DeskWindowScope extends InheritedWidget {
  const DeskWindowScope({
    super.key,
    required this.window,
    required super.child,
  });

  final DeskWindow window;

  static DeskWindow? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeskWindowScope>()?.window;

  @override
  bool updateShouldNotify(DeskWindowScope oldWidget) =>
      oldWidget.window != window;
}

/// Every open internal window, bottom to top.
///
/// The last entry is the front window: the one that has the keyboard and the
/// one a phone-sized desk shows on its own.
class WindowStack extends ChangeNotifier {
  final List<DeskWindow> _windows = [];

  int _opened = 0;

  /// Bottom to top.
  List<DeskWindow> get windows => List.unmodifiable(_windows);

  bool get isEmpty => _windows.isEmpty;

  bool get isNotEmpty => _windows.isNotEmpty;

  int get length => _windows.length;

  /// The front window, or null when the desk is clear.
  DeskWindow? get top => _windows.isEmpty ? null : _windows.last;

  bool isTop(DeskWindow window) => identical(window, top);

  DeskWindow? byId(String id) {
    for (final window in _windows) {
      if (window.id == id) return window;
    }
    return null;
  }

  /// Shows [window], or brings the one already carrying its id to the front.
  ///
  /// The returned future completes when that window closes, so a caller can
  /// await a window the way it would await a dialog.
  Future<Object?> open(DeskWindow window) {
    final existing = byId(window.id);
    if (existing != null) {
      focus(existing);
      return existing.result;
    }

    // A window of the same name still on its way out is cut short rather than
    // allowed to finish: the layer draws both by id, and two of anything with
    // one key is not a picture, it is an error. Reopening the settings the
    // instant they were closed is the case.
    _leaving.removeWhere((leaving) => leaving.id == window.id);

    window.cascade = _opened++;
    window._stack = this;
    _windows.add(window);
    notifyListeners();
    return window.result;
  }

  /// Index of the front-most modal window, or -1 when none is open. The layer
  /// drops a barrier immediately below it.
  int get frontModalIndex {
    for (var i = _windows.length - 1; i >= 0; i--) {
      if (_windows[i].modal) return i;
    }
    return -1;
  }

  /// Whether something is being answered right now.
  ///
  /// Asked before a window nobody sent for is opened — the update offer, which
  /// arrives on a timer. A modal is a question with a barrier under it, and a
  /// second window over the top takes the keyboard away from a name half typed.
  bool get hasModal => frontModalIndex >= 0;

  /// Brings a window to the front. Does nothing if it is already there.
  void focus(DeskWindow window) {
    final index = _windows.indexOf(window);
    if (index < 0 || index == _windows.length - 1) return;
    _windows
      ..removeAt(index)
      ..add(window);
    notifyListeners();
  }

  void close(DeskWindow window, [Object? result]) {
    if (!_windows.remove(window)) return;
    window._stack = null;
    // The answer is given at once. Whoever was awaiting it is not made to wait
    // for an animation — the window going back to the row it came from is for
    // the reader's eye, not for the caller's logic.
    if (!window._result.isCompleted) window._result.complete(result);
    _leaving.add(window);
    notifyListeners();
  }

  /// Windows that have been closed and are on their way back to where they
  /// came from. They are no longer open — nothing can reach them, and their
  /// result is already given — but the layer goes on drawing them until the
  /// journey is over and it calls [finishedLeaving].
  ///
  /// A list of its own rather than a flag on the window, so every question
  /// about what is *open* — the front-most modal, whether a window with an id
  /// is already up — goes on being answered by [windows] alone.
  final List<DeskWindow> _leaving = [];

  List<DeskWindow> get leaving => List.unmodifiable(_leaving);

  /// Called by the layer when a leaving window has finished leaving.
  void finishedLeaving(DeskWindow window) {
    if (_leaving.remove(window)) notifyListeners();
  }

  /// Where a window opened from, asked of whoever knows.
  ///
  /// The commander screen installs this: it holds the key on the row the
  /// cursor is on, and that row is the origin of every window a file operation
  /// opens. Null — nobody installed one, or nothing has a cursor — and the
  /// window arrives about its own centre.
  Rect? Function()? originOf;

  void closeById(String id, [Object? result]) {
    final window = byId(id);
    if (window != null) close(window, result);
  }

  /// Escape closes the front window.
  void closeTop([Object? result]) {
    final window = top;
    if (window != null) close(window, result);
  }

  void closeAll() {
    if (_windows.isEmpty && _leaving.isEmpty) return;
    for (final window in _windows.toList()) {
      window._stack = null;
      if (!window._result.isCompleted) window._result.complete(null);
    }
    _windows.clear();
    // Nothing travels anywhere on the way out of here: this is the desk being
    // cleared, not a window being answered.
    _leaving.clear();
    notifyListeners();
  }
}
