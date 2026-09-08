import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../widgets/choice_button.dart';
import '../widgets/stepped_slider.dart';

/// A label, an input and its small print — the shape every field a plugin
/// declares is drawn in, wherever the form happens to be.
class LabelledField extends StatelessWidget {
  const LabelledField({
    super.key,
    required this.label,
    required this.child,
    this.note,
  });

  final String label;
  final Widget child;
  final String? note;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            child,
            if (note != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  note!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      );
}

/// Draws one field a plugin declared.
///
/// Every form built from a plugin's declaration goes through here — the
/// connection dialog and a plugin's own settings both — so a field means the
/// same thing and looks the same wherever it was declared. Passwords are the
/// exception the caller keeps: what happens to one depends on where it is
/// going, and that is not this widget's business.
class PluginFieldInput extends StatelessWidget {
  const PluginFieldInput({
    super.key,
    required this.field,
    required this.onChanged,
    this.controller,
    this.flag = false,
    this.choice,
    this.number,
    this.suffix,
    this.inputKey,
  });

  final PluginField field;

  /// Holds the text of a text, number or path field. Switches and choices have
  /// no free text and ignore it.
  final TextEditingController? controller;

  /// Current value of a [PluginFieldType.boolean] field.
  final bool flag;

  /// Current value of a [PluginFieldType.choice] field.
  final String? choice;

  /// Current value of an integer field that declared a range, and so is drawn
  /// as a slider rather than as something typed.
  final int? number;

  /// The new value: a `bool` for a switch, a `String` for a choice. Text
  /// fields report through their controller and never call this.
  final ValueChanged<Object?> onChanged;

  /// Anything the caller wants inside the input, e.g. a browse button.
  final Widget? suffix;

  /// Key on the input itself, for a caller that has to anchor a menu to it.
  final Key? inputKey;

  @override
  Widget build(BuildContext context) {
    if (field.type == PluginFieldType.boolean) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(field.label),
          subtitle: field.note == null ? null : Text(field.note!),
          value: flag,
          onChanged: (value) => onChanged(value ?? false),
        ),
      );
    }

    if (field.type == PluginFieldType.choice) {
      return _ChoiceInput(field: field, value: choice, onChanged: onChanged);
    }

    // A number with both ends declared is a number that can be *shown*, so it
    // is — on the same slider the appearance settings use. A box also cannot
    // take a minus sign here, so a signed setting was unreachable in one.
    if (field.hasRange) {
      final lowest = field.minimum!;
      final highest = field.maximum!;
      return SteppedSlider(
        label: field.label,
        note: field.note,
        value: (number ?? _defaultNumber(field) ?? lowest).clamp(lowest, highest),
        minimum: lowest,
        maximum: highest,
        step: field.step ?? 1,
        // A range that crosses zero is a shift rather than a quantity, and a
        // shift reads better with its sign on it.
        signed: lowest < 0,
        onChanged: onChanged,
      );
    }

    final isNumber = field.type == PluginFieldType.integer;
    return LabelledField(
      label: field.label,
      note: field.note,
      child: TextField(
        key: inputKey,
        controller: controller,
        keyboardType: isNumber ? TextInputType.number : TextInputType.text,
        inputFormatters:
            isNumber ? [FilteringTextInputFormatter.digitsOnly] : null,
        decoration: InputDecoration(hintText: field.hint, suffixIcon: suffix),
      ),
    );
  }
}

/// A choice a plugin declared, drawn as the app's own menu button.
///
/// A value the plugin no longer offers reads as nothing chosen rather than as
/// a label the button cannot show.
class _ChoiceInput extends StatelessWidget {
  const _ChoiceInput({
    required this.field,
    required this.value,
    required this.onChanged,
  });

  final PluginField field;
  final String? value;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) => LabelledField(
        label: field.label,
        note: field.note,
        child: ChoiceButton<String>(
          value: value ?? '',
          placeholder: field.hint ?? '',
          searchHint: tr('Search {what}',
              {'what': field.label.toLowerCase()}),
          options: [
            for (final option in field.options)
              ChoiceOption(option.value, option.label),
          ],
          onChanged: onChanged,
        ),
      );
}

/// What a ranged field starts at when nothing has been chosen yet.
int? _defaultNumber(PluginField field) {
  final value = field.defaultValue;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('${value ?? ''}');
}
