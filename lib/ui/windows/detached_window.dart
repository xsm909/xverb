import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/settings/window_service.dart';
import '../../core/window/x_window.dart';
import '../../state/window_stack.dart';

/// **Says that everything below it is drawn in a window of the application's
/// own**, holding one detached thing and nothing else.
///
/// What it carries is what "back" means there. A page in the first window
/// goes back by popping its route; in a window that holds only that page
/// there is no route underneath, so going back means the window closing. Both
/// are the same gesture to the hand — Escape, or the arrow in the bar — and
/// [leaveThePage] is the one call that gets it right in either place.
class DetachedWindowScope extends InheritedWidget {
  const DetachedWindowScope({
    super.key,
    required this.close,
    required this.handle,
    required super.child,
  });

  /// Closes the window this is in.
  final VoidCallback close;

  /// The window itself, as the runner knows it — what the three buttons in
  /// its bar and a drag of its bar act on. Null where the platform does not
  /// hand the address out.
  final int? handle;

  /// How to close the window this context is drawn in, or null in the first
  /// window, which is not closed by anything inside it.
  static VoidCallback? closeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DetachedWindowScope>()
      ?.close;

  static DetachedWindowScope? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DetachedWindowScope>();

  @override
  bool updateShouldNotify(DetachedWindowScope old) =>
      old.close != close || old.handle != handle;
}

/// **What the title bar's own buttons act on: the window they are drawn in.**
///
/// In the first window that is `WindowService`, which is where every other
/// part of the application reaches the window. In a window the application
/// opened it is that window, by its address — the same three acts, aimed one
/// window to the left.
class WindowActs {
  const WindowActs._(this.scope);

  final DetachedWindowScope? scope;

  static WindowActs of(BuildContext context) =>
      WindowActs._(DetachedWindowScope.maybeOf(context));

  bool get isDetached => scope != null;

  Future<void> minimize() async {
    final scope = this.scope;
    if (scope == null) return WindowService.minimize();
    await XWindow.instance.minimize(handle: scope.handle);
  }

  Future<void> toggleMaximize() async {
    final scope = this.scope;
    if (scope == null) return WindowService.toggleMaximize();
    await XWindow.instance.toggleMaximize(handle: scope.handle);
  }

  Future<void> startDragging() async {
    final scope = this.scope;
    if (scope == null) return WindowService.startDragging();
    await XWindow.instance.startDragging(handle: scope.handle);
  }

  /// Closing the first window is the application leaving — it asks, saves and
  /// destroys. Closing a detached one is only that window going.
  void close() {
    final scope = this.scope;
    if (scope == null) {
      unawaited(WindowService.close());
      return;
    }
    scope.close();
  }
}

/// **Leaves the page the ordinary way**: back a route while there is one to go
/// back to, and otherwise close the window the page is in.
///
/// Every full-screen page calls this instead of popping, so the same page can
/// be the whole of a detached window without knowing it.
void leaveThePage(BuildContext context) {
  final navigator = Navigator.maybeOf(context);
  if (navigator != null && navigator.canPop()) {
    navigator.maybePop();
    return;
  }
  DetachedWindowScope.closeOf(context)?.call();
}

/// **Which stack of internal windows this context's dialogs belong in.**
///
/// There is one desk per window: a form a view opened in a detached window
/// belongs over that window, not over the commander in the first one. The
/// first window provides the application's own stack through this as well, so
/// that [showDeskWindow] has one question to ask rather than two.
class WindowStackScope extends InheritedWidget {
  const WindowStackScope({
    super.key,
    required this.stack,
    required super.child,
  });

  final WindowStack stack;

  static WindowStack? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<WindowStackScope>()
      ?.stack;

  @override
  bool updateShouldNotify(WindowStackScope old) => old.stack != stack;
}
