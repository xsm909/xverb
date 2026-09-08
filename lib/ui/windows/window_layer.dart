import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_store.dart';
import '../../state/window_stack.dart';
import '../widgets/context_menu.dart';
import 'window_arrival.dart';
import 'window_frame.dart';

/// Draws the internal windows over the desk — the panels, the console and the
/// command bar — and keeps the application's own title bar clear, so the app
/// window can still be dragged while a settings or viewer window is open.
///
/// Below [minimumWindowedDesk] there is no room to float anything: the front
/// window fills the desk instead, which is what a phone wants anyway.
class WindowLayer extends StatelessWidget {
  const WindowLayer({super.key, required this.stack, required this.child});

  final WindowStack stack;

  /// The desk itself. Windows are stacked over it.
  final Widget child;

  /// Smallest desk that still gets floating windows.
  static const Size minimumWindowedDesk = Size(720, 480);

  @override
  Widget build(BuildContext context) {
    // Only the page on top draws the windows.
    //
    // Every full-screen page carries a layer of its own, because a page is a
    // route and a route covers whatever is under it — a colour picker opened
    // from the settings page was landing in the commander's layer, underneath,
    // and only turned up once the settings were closed. They share one stack,
    // so exactly one layer may draw it, and the one on top is the right one.
    final route = ModalRoute.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge([stack, contextMenuIsOpen]),
      // Handed through rather than built inside, so opening or closing a
      // window does not rebuild the page underneath it.
      child: child,
      builder: (context, child) {
        // The shape of this tree never changes: ListenableBuilder, then
        // LayoutBuilder, then Stack, with the desk as the first child.
        //
        // Returning the desk bare while nothing was open looked like the
        // obvious saving, and it cost the page its *state*. The first window
        // to open moved the desk from being this widget's child to being a
        // Stack's, and Flutter discards the element of a widget that moved.
        // Two bugs came out of that: the settings tab jumping back to
        // Appearance, and — much worse — anything awaiting a dialog waking up
        // with `mounted == false`, so "Install Python" asked for confirmation
        // and then silently did nothing.
        //
        // The desk is deliberately *not* positioned: a Stack takes its size
        // from its non-positioned children, and one made only of Positioned
        // widgets collapses to nothing wherever the constraints are loose.
        // A context menu is a route, so the page below stops being "current"
        // while one is open. It covers nothing, so treat it as if it were not
        // there — otherwise opening a menu from inside a window destroys the
        // window.
        final drawsWindows =
            route == null || route.isCurrent || contextMenuIsOpen.value;
        final windows = drawsWindows ? stack.windows : const <DeskWindow>[];
        // Windows that have been answered and are on their way back to the row
        // they came from. Drawn under the live ones: a window on its way out
        // must not cover one that has just opened.
        final leaving = drawsWindows ? stack.leaving : const <DeskWindow>[];

        return LayoutBuilder(
          builder: (context, constraints) {
            final desk = Size(constraints.maxWidth, constraints.maxHeight);
            final fullScreen =
                desk.width < minimumWindowedDesk.width ||
                desk.height < minimumWindowedDesk.height;

            // Everything below the front-most modal window is out of reach
            // until it is answered.
            final barrier = stack.frontModalIndex;

            // The desk's own place on the screen, so a window's origin — taken
            // in global coordinates, at the moment it was asked for — can be
            // read in the same coordinates the windows are placed in.
            final box = context.findRenderObject();
            final deskOrigin = box is RenderBox && box.hasSize
                ? box.localToGlobal(Offset.zero)
                : Offset.zero;

            return Stack(
              children: [
                child!,
                for (final window in leaving)
                  _slot(
                    window,
                    desk,
                    deskOrigin: deskOrigin,
                    fullScreen: fullScreen,
                    leaving: true,
                  ),
                for (var i = 0; i < windows.length; i++) ...[
                  if (i == barrier)
                    const Positioned.fill(
                      key: ValueKey('modal-barrier'),
                      child: ModalBarrier(
                        dismissible: false,
                        color: Color(0x59000000),
                      ),
                    ),
                  _slot(
                    windows[i],
                    desk,
                    deskOrigin: deskOrigin,
                    fullScreen: fullScreen,
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  /// One window. Keyed by id so that bringing a window to the front reorders
  /// the stack's children without re-creating their state — a viewer must not
  /// reload because something was clicked in front of it.
  Widget _slot(
    DeskWindow window,
    Size desk, {
    required Offset deskOrigin,
    required bool fullScreen,
    bool leaving = false,
  }) {
    return ListenableBuilder(
      // The same key whether it is open or on its way out, so the frame's own
      // state — and with it the contents it last built — survives the move
      // from one list to the other. A new element here would build the window
      // again, and its contents no longer belong to anybody.
      key: ValueKey(window.id),
      listenable: window,
      builder: (context, _) {
        // A window on its way out is nobody's front window, whatever the stack
        // now says: it wears the inactive edge while it goes.
        final active = !leaving && stack.isTop(window);
        final frame = WindowFrame(
          window: window,
          desk: desk,
          active: active,
          fullScreen: fullScreen,
          leaving: leaving,
          onFocus: () => stack.focus(window),
          // A window that owns something in flight gets to decide what
          // "close" means — see DeskWindow.onDismiss.
          onClose: window.onDismiss ?? () => stack.close(window),
        );

        if (fullScreen) {
          // Offstage rather than dropped: a window behind the front one keeps
          // its state, so switching back does not reload it. Nothing travels
          // here — a window that fills the desk has nowhere to come from, and
          // a bar growing to cover everything is a claim about the desk rather
          // than about the row.
          if (leaving) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => stack.finishedLeaving(window),
            );
            return const Positioned.fill(child: SizedBox.shrink());
          }
          return Positioned.fill(
            child: Offstage(offstage: !active, child: frame),
          );
        }

        window.layout(desk);
        final bounds = window.bounds!;
        return Positioned(
          left: bounds.left,
          top: bounds.top,
          width: bounds.width,
          height: bounds.height,
          child: WindowArrival(
            from: window.origin?.shift(-deskOrigin),
            bounds: bounds,
            head: WindowFrame.titleHeight,
            motion: context.watch<SettingsStore>().appearance.windowArriveMotion,
            leaving: leaving,
            onLeft: () => stack.finishedLeaving(window),
            child: frame,
          ),
        );
      },
    );
  }
}
