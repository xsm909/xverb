import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_store.dart';

/// A path drawn as a row of buttons, each going back to that level.
///
/// The panel's location bar is one of these and a plugin view's trail is
/// another: a view that has walked into something has exactly the same problem
/// a panel does, and answering it twice would mean two things that look alike
/// but do not behave alike.
class TrailBar extends StatefulWidget {
  const TrailBar({
    super.key,
    required this.steps,
    required this.onGo,
    this.isActive = true,
    this.current,
    this.leadingSeparator = false,
  });

  /// Root first. The last one is where you are, unless [current] says else.
  final List<String> steps;

  /// Called with the index of the step pressed. The current one is not
  /// pressable, so it never arrives here.
  final ValueChanged<int> onGo;

  /// Dimmed when the thing holding the trail is not the one being worked in.
  final bool isActive;

  /// Which step is the one being shown. Defaults to the last.
  final int? current;

  /// Whether the first step gets a chevron before it. False where it sits
  /// against something that already reads as its parent, such as the panel's
  /// drive pill.
  final bool leadingSeparator;

  @override
  State<TrailBar> createState() => _TrailBarState();
}

class _TrailBarState extends State<TrailBar> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _parkAtEnd();
  }

  @override
  void didUpdateWidget(TrailBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.steps.length != widget.steps.length ||
        oldWidget.current != widget.current) {
      _parkAtEnd();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// A short path sits against the left; a long one scrolls, and is parked at
  /// its end so the level you are actually in is the one you can see.
  ///
  /// Only meaningful once the row has been laid out, hence the frame delay.
  void _parkAtEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (end > 0) _scroll.jumpTo(end);
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.current ?? widget.steps.length - 1;

    return ScrollConfiguration(
      behavior: const _DragScrollBehavior(),
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < widget.steps.length; i++)
              TrailStep(
                label: widget.steps[i],
                showSeparator: i > 0 || widget.leadingSeparator,
                isActive: widget.isActive,
                isCurrent: i == current,
                onTap: () => widget.onGo(i),
              ),
          ],
        ),
      ),
    );
  }
}

/// One level of the path, as a button that goes back to it.
class TrailStep extends StatefulWidget {
  const TrailStep({
    super.key,
    required this.label,
    required this.isActive,
    required this.isCurrent,
    required this.onTap,
    this.showSeparator = true,
  });

  final String label;
  final bool isActive;

  /// The chevron drawn before the label, dividing it from the step above.
  final bool showSeparator;

  /// The level actually being shown. It is drawn a little stronger, and going
  /// "back" to it would be a no-op.
  final bool isCurrent;

  final VoidCallback onTap;

  @override
  State<TrailStep> createState() => _TrailStepState();
}

class _TrailStepState extends State<TrailStep> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final foreground = widget.isActive
        ? theme.headerForeground
        : theme.headerForeground.withValues(alpha: 0.6);

    return Row(
      children: [
        if (widget.showSeparator)
          Icon(
            Icons.chevron_right,
            size: 14,
            color: theme.headerForeground.withValues(alpha: 0.35),
          ),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.isCurrent ? null : widget.onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              height: theme.chromeRowHeight,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hovered && !widget.isCurrent
                    ? theme.accentColor.withValues(alpha: 0.28)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                widget.label,
                maxLines: 1,
                style: TextStyle(
                  color: foreground,
                  fontSize: theme.fontSize,
                  // A path is names off a disk, so it is drawn in the family
                  // the listing is — item 43.
                  fontFamily: theme.fileFamily,
                  // A path is a row of directories, so it is drawn at the
                  // directory weight — and the level you are standing on is the
                  // one thing the trail is saying, so that one is emphasis.
                  fontWeight: widget.isCurrent
                      ? theme.strongFontWeight.weight
                      : theme.directoryFontWeight.weight,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A path bar scrolls by dragging as well as by wheel: it is one row high and
/// has no room for a scroll bar.
class _DragScrollBehavior extends MaterialScrollBehavior {
  const _DragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails d,
  ) =>
      child;
}
