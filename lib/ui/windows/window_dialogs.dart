import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/window_stack.dart';

/// Counts the throwaway windows, so two questions asked in a row cannot land
/// on the same id and collapse into one window.
int _nextId = 0;

/// Opens an internal window whose contents hand a value back, the way a dialog
/// does — and returns that value.
///
/// [builder] is given the window itself, so the contents can close it with a
/// result: `window.close(true)`. Escape and the close button both answer null.
///
/// Pass an [id] only when the window is one of a kind — settings, the search,
/// a viewer on a particular file. Asking for an id that is already open brings
/// that window forward instead of opening a second one. Anything transient
/// should leave it out and get a fresh window every time.
Future<T?> showDeskWindow<T>(
  BuildContext context, {
  String? id,
  required String title,
  required Widget Function(DeskWindow window) builder,
  IconData? icon,
  Size preferredSize = const Size(460, 250),
  Size minSize = const Size(320, 150),
  bool modal = true,
  bool resizable = true,

  /// Where the window comes out of, when the caller knows better than the two
  /// guesses below. Global coordinates.
  Rect? origin,
}) async {
  final windows = context.read<AppState>().windows;

  // The contents need the window they live in, and the window needs the
  // contents; `late` is what ties the knot.
  late final DeskWindow window;
  window = DeskWindow(
    id: id ?? 'window-${_nextId++}',
    title: title,
    icon: icon,
    preferredSize: preferredSize,
    minSize: minSize,
    modal: modal,
    resizable: resizable,
    origin: origin ?? windows.originOf?.call() ?? _focusedRect(),
    builder: (_) => builder(window),
  );

  final result = await windows.open(window);
  return result is T ? result : null;
}

/// The rectangle of whatever has the keyboard, as a last resort.
///
/// The cursor row answers first — the commander screen installs
/// [WindowStack.originOf] and it knows where the cursor is. This is for the
/// windows opened from somewhere else: a button on a settings page, a row in
/// the plugin list. In an application the keyboard comes first in, what holds
/// the focus *is* where the user was standing when they asked.
Rect? _focusedRect() {
  final context = FocusManager.instance.primaryFocus?.context;
  final box = context?.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  final size = box.size;
  // A focus node wrapping half the window says nothing about where the user
  // was; better to arrive from nowhere than to fly out of the whole desk.
  if (size.isEmpty || size.width > 900 || size.height > 700) return null;
  return box.localToGlobal(Offset.zero) & size;
}

/// The usual shape of a window that asks something: a body, and a row of
/// buttons along the bottom.
///
/// [onSubmit] is what the primary button does, and what Enter does — a
/// question with an obvious answer should not need the mouse.
class WindowForm extends StatefulWidget {
  const WindowForm({
    super.key,
    required this.child,
    this.actions = const [],
    this.onSubmit,
    this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 12),
  });

  final Widget child;
  final List<Widget> actions;
  final VoidCallback? onSubmit;
  final EdgeInsets padding;

  @override
  State<WindowForm> createState() => _WindowFormState();
}

class _WindowFormState extends State<WindowForm> {
  DeskWindow? _window;

  /// Registers the default button on the window itself.
  ///
  /// It used to be a `CallbackShortcuts` around this form, which only sees the
  /// keys of the focused node and its ancestors. On a window with nothing to
  /// type into the keyboard stayed on the frame — above this — so Enter never
  /// arrived. The frame owns the key now; this only says what it should do.
  void _register() {
    final window = DeskWindowScope.maybeOf(context);
    if (identical(window, _window)) {
      _window?.onSubmit = widget.onSubmit;
      return;
    }
    _window?.onSubmit = null;
    _window = window;
    _window?.onSubmit = widget.onSubmit;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _register();
  }

  @override
  void didUpdateWidget(WindowForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onSubmit != widget.onSubmit) _register();
  }

  @override
  void dispose() {
    _window?.onSubmit = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final actions = widget.actions;
    final padding = widget.padding;
    final child = widget.child;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(padding: padding, child: child),
        ),
        if (actions.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.4),
                ),
              ),
            ),
            // A Wrap and not a Row: three buttons fit in English and do not
            // fit in German, and a window is narrow whenever somebody has
            // made it narrow. Wrapping puts the extra one on a line of its
            // own; a Row cuts it off and says nothing.
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 6,
              children: actions,
            ),
          ),
      ],
    );
  }
}
