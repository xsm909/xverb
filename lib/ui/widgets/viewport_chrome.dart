import 'package:flutter/material.dart';

import 'hint.dart';

/// The row of switches that stands *on* a viewport rather than beside it.
///
/// The switches belong over the viewport rather than in a bar of their own.
/// Two viewports want them now — the model and the picture — and a second
/// hand-made copy of the same eight numbers is how two things that should look
/// alike stop looking alike.
///
/// It has its own quiet surface because what is behind it is somebody else's
/// file: a model in any colour, a photograph of anything at all.
class ViewportChrome extends StatelessWidget {
  const ViewportChrome({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// One switch in a [ViewportChrome].
///
/// [on] is what it is *now*, not what pressing it does: a switch drawn in the
/// accent colour says "this is the state you are in", which is the only thing
/// a row of icons standing on a picture can usefully say.
class ViewportSwitch extends StatelessWidget {
  const ViewportSwitch({
    super.key,
    required this.icon,
    required this.message,
    required this.onPressed,
    this.on = false,
  });

  final IconData icon;

  /// What it is, and the key that does the same thing — every one of these has
  /// a letter, because a switch only the mouse can reach is not a control.
  final String message;

  final bool on;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Hint(
      message: message,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          child: Icon(
            icon,
            size: 16,
            color: on
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}

/// What separates a choice from a thing of its own inside a [ViewportChrome].
///
/// A row of identical buttons says they are all of a kind, and usually they are
/// not: three ways of looking at a model and then the bones over it, or the
/// zoom and then what the zoom is measured against.
class ViewportRule extends StatelessWidget {
  const ViewportRule({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 18,
        child: VerticalDivider(
          width: 5,
          thickness: 1,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.14),
        ),
      );
}
