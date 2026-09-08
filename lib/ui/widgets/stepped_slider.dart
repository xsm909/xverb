import 'package:flutter/material.dart';

/// A slider over whole numbers that moves in steps, with the number beside it.
///
/// **Stepped rather than free, and the step is the point.** The appearance
/// settings' weights move by a hundred because that is the granularity a font
/// family actually has; a slider finer than the thing it controls slides
/// without the screen changing, which is how a setting comes to look broken.
/// The same is true of anything else declared with a range: whoever declares it
/// knows what a meaningful move is, and says so.
///
/// Shared, because a plugin's own ranged setting must look and behave exactly
/// like one of the application's: a weight drawn as a text box in one place and
/// as a slider in the other is two settings pages in one application.
class SteppedSlider extends StatelessWidget {
  const SteppedSlider({
    super.key,
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.onChanged,
    this.step = 1,
    this.signed = false,
    this.floor,
    this.trailingStyle,
    this.note,
  });

  final String label;
  final int value;
  final int minimum;
  final int maximum;
  final ValueChanged<int> onChanged;

  /// How far one move goes. Never zero, and never wider than the whole range.
  final int step;

  /// Shows a leading `+` above zero, for a number that is a shift rather than
  /// a quantity.
  final bool signed;

  /// The lowest value that may be *chosen*. Below it the track is still there
  /// and still the same length — it simply cannot be dragged to.
  ///
  /// A floor rather than a higher [minimum], and the difference is the whole
  /// point: moving the minimum shortens the scale under the thumb, so the same
  /// value sits in a different place depending on what another slider is set
  /// to.
  final int? floor;

  /// How the number beside the slider is drawn — the one place a weight
  /// setting can show itself at the weight it is asking for.
  final TextStyle? trailingStyle;

  /// A line under it, in the plugin form's manner.
  final String? note;

  String get _shown => signed && value > 0 ? '+$value' : '$value';

  @override
  Widget build(BuildContext context) {
    // A step of zero, or one wider than the range, would leave `divisions` at
    // zero — which Slider asserts on, taking the whole form down with it.
    final division = step <= 0 ? 1 : step;
    final divisions = ((maximum - minimum) ~/ division).clamp(1, 1 << 20);
    final lowest = floor ?? minimum;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(label),
          subtitle: Slider(
            value: value.clamp(minimum, maximum).toDouble(),
            min: minimum.toDouble(),
            max: maximum.toDouble(),
            divisions: divisions,
            label: _shown,
            onChanged: (raw) {
              final snapped = (raw / division).round() * division;
              onChanged(snapped < lowest ? lowest : snapped);
            },
          ),
          trailing: Text(_shown, style: trailingStyle),
        ),
        if (note != null && note!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              note!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.7),
                  ),
            ),
          ),
      ],
    );
  }
}
