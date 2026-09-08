import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import 'context_menu.dart';

/// One of the answers a [ChoiceButton] will take.
class ChoiceOption<T> {
  const ChoiceOption(this.value, this.label, {this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// Picks one value out of a few, using the application's own menu.
///
/// Material's `DropdownButton` cannot be used inside an internal window.
/// It opens a route, and a route makes the page underneath stop being the
/// current one — which is how `WindowLayer` decides whether to draw the
/// windows. Every dropdown on the settings page therefore sent the settings
/// window away the moment it was pressed: still in the stack, still reachable
/// from the Window menu, but gone from under the pointer.
///
/// Ours is the one route the layer knows to ignore, and it brings a tick on
/// the current value and a search over the options with it — which a list of
/// two hundred font families needs and a dropdown never had.
class ChoiceButton<T> extends StatefulWidget {
  const ChoiceButton({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.width,
    this.searchHint,
    this.placeholder = '',
  });

  final T value;
  final List<ChoiceOption<T>> options;
  final ValueChanged<T> onChanged;

  /// Fixed width, for a row of controls that should line up. Null lets the
  /// button take whatever its parent gives it.
  final double? width;

  final String? searchHint;

  /// Shown when [value] is not among [options] — a font that has since been
  /// uninstalled, say.
  final String placeholder;

  @override
  State<ChoiceButton<T>> createState() => _ChoiceButtonState<T>();
}

class _ChoiceButtonState<T> extends State<ChoiceButton<T>> {
  final GlobalKey _anchor = GlobalKey();

  Future<void> _open() async {
    final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    await showAppContextMenu(
      context: context,
      anchorRect: box.localToGlobal(Offset.zero) & box.size,
      searchHint: widget.searchHint ?? tr('Search'),
      nodes: [
        for (final option in widget.options)
          MenuItem(
            option.label,
            icon: option.icon,
            // **A tick on the one that is chosen, and nothing on the rest.**
            // `checked: false` draws an empty box, so a list of five kinds of
            // archive came up as five checkboxes — a form asking five
            // questions, where this asks one. Passing null leaves the slot to
            // the option's own icon, and keeps every label on the same margin.
            checked: option.value == widget.value ? true : null,
            onSelected: () => widget.onChanged(option.value),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.options
        .where((option) => option.value == widget.value)
        .firstOrNull;
    final theme = Theme.of(context);

    final button = InkWell(
      key: _anchor,
      onTap: _open,
      child: InputDecorator(
        decoration: const InputDecoration(isDense: true),
        child: Row(
          children: [
            if (selected?.icon != null) ...[
              Icon(selected!.icon, size: 16),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                selected?.label ?? widget.placeholder,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: selected == null
                    ? TextStyle(color: theme.hintColor)
                    : null,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );

    final width = widget.width;
    return width == null ? button : SizedBox(width: width, child: button);
  }
}
