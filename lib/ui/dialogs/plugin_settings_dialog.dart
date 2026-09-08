import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../../core/plugins/plugin_registry.dart';
import '../../state/window_stack.dart';
import '../text_scale.dart';
import '../widgets/choice_button.dart';
import '../windows/window_dialogs.dart';
import 'plugin_form.dart';

/// A plugin's own settings, rendered from what the plugin declared.
///
/// The plugin ships a list of fields in its manifest and the host does the
/// rest: draws them, stores the answers, and hands them over at startup and
/// whenever they change. No plugin writes a settings screen, so no two look
/// different, and nothing can hide its options somewhere nobody looks.
Future<void> showPluginSettings(
  BuildContext context, {
  required PluginManifest manifest,
  required PluginRegistry registry,
}) {
  return showDeskWindow<void>(
    context,
    id: 'plugin-settings:${manifest.id}',
    title: tr('{name}: settings', {'name': manifest.displayName}),
    icon: Icons.tune,
    preferredSize: const Size(560, 520),
    minSize: const Size(420, 300),
    builder: (window) => _SettingsForm(
      manifest: manifest,
      registry: registry,
      window: window,
    ),
  );
}

class _SettingsForm extends StatefulWidget {
  const _SettingsForm({
    required this.manifest,
    required this.registry,
    required this.window,
  });

  final PluginManifest manifest;
  final PluginRegistry registry;
  final DeskWindow window;

  @override
  State<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<_SettingsForm> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, bool> _flags = {};
  final Map<String, String?> _choices = {};

  /// Integer settings that declared a range, and so are drawn as sliders.
  final Map<String, int> _numbers = {};

  /// Where each of the plugin's commands is offered, by command id.
  final Map<String, CommandSurface> _surfaces = {};

  /// Which surfaces each of the plugin's views is offered on, by view id. A
  /// set rather than one answer: a view can be in several places at once, and
  /// the same disk map is worth having both full screen and in a panel.
  final Map<String, Set<PluginSurface>> _viewSurfaces = {};

  /// The settings this plugin declared, in the user's language.
  List<PluginField> get _fields => [
    for (final field in widget.manifest.settings)
      field.saidBy(widget.manifest.id),
  ];

  List<PluginCommandSpec> get _commands => widget.manifest.commands;

  List<ViewSpec> get _views => widget.manifest.views;

  @override
  void initState() {
    super.initState();
    for (final command in _commands) {
      _surfaces[command.id] =
          widget.registry.declaredSurfaceFor(widget.manifest.id, command);
    }
    for (final view in _views) {
      _viewSurfaces[view.id] = widget.registry
          .declaredSurfacesForView(widget.manifest.id, view)
          .toSet();
    }
    // From the manifest in hand rather than from the registry's view of it:
    // the form belongs to *this* plugin's declaration, and asking the registry
    // would show nothing for one it has not started.
    _fill({
      ...widget.manifest.settingDefaults,
      ...widget.registry.storedSettings(widget.manifest.id),
    });
  }

  /// Puts [values] into the inputs, creating them on the first pass and
  /// reusing them afterwards — "restore defaults" rewrites a live form.
  void _fill(Map<String, Object?> values) {
    for (final field in _fields) {
      final value = values[field.key];
      switch (field.type) {
        case PluginFieldType.boolean:
          _flags[field.key] = value == true || value == 'true';
        case PluginFieldType.choice:
          _choices[field.key] = value?.toString();
        case PluginFieldType.password:
          break;
        case PluginFieldType.integer when field.hasRange:
          _numbers[field.key] =
              value is int ? value : int.tryParse('${value ?? ''}') ?? 0;
        case PluginFieldType.text:
        case PluginFieldType.integer:
        case PluginFieldType.remotePath:
          final text = value?.toString() ?? '';
          final existing = _text[field.key];
          if (existing == null) {
            _text[field.key] = TextEditingController(text: text);
          } else {
            existing.text = text;
          }
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _isHidden(PluginField field) {
    final key = field.hiddenWhen;
    return key != null && (_flags[key] ?? false);
  }

  /// Only what differs from the plugin's declared default is kept.
  ///
  /// Storing every field would freeze today's defaults into everybody's
  /// settings, so a plugin that later picks a better one would never reach
  /// anyone who had opened this window once.
  Map<String, Object?> _collect() {
    final defaults = widget.manifest.settingDefaults;
    final values = <String, Object?>{};

    for (final command in _commands) {
      final chosen = _surfaces[command.id];
      final byDefault = CommandSurface.parse(
        null,
        wantsTitleBar: command.inTitleBar,
      );
      if (chosen == null || chosen == byDefault) continue;
      values['${PluginRegistry.surfaceKeyPrefix}${command.id}'] = chosen.name;
    }

    for (final view in _views) {
      final chosen = _viewSurfaces[view.id] ?? view.surfaces.toSet();
      // Everything the view declared is the default, so leave nothing behind
      // when that is what is ticked — a later version adding a surface then
      // reaches a user who never touched this.
      if (setEquals(chosen, view.surfaces.toSet())) continue;
      values['${PluginRegistry.viewSurfaceKeyPrefix}${view.id}'] =
          PluginRegistry.formatViewSurfaces(
        view.surfaces.where(chosen.contains),
      );
    }

    for (final field in _fields) {
      final Object? value = switch (field.type) {
        PluginFieldType.boolean => _flags[field.key] ?? false,
        PluginFieldType.choice => _choices[field.key],
        PluginFieldType.integer => field.hasRange
            ? _numbers[field.key]
            : int.tryParse(_text[field.key]?.text.trim() ?? ''),
        PluginFieldType.password => null,
        PluginFieldType.text ||
        PluginFieldType.remotePath =>
          _text[field.key]?.text.trim(),
      };

      if (value == null) continue;
      if (value is String && value.isEmpty) continue;
      if (value == defaults[field.key]) continue;
      values[field.key] = value;
    }
    return values;
  }

  Future<void> _submit() async {
    await widget.registry.setSettings(widget.manifest.id, _collect());
    widget.window.close();
  }

  @override
  Widget build(BuildContext context) {
    return WindowForm(
      onSubmit: _submit,
      actions: [
        TextButton(
          onPressed: () =>
              setState(() => _fill(widget.manifest.settingDefaults)),
          child: Text(tr('Restore defaults')),
        ),
        TextButton(
          onPressed: widget.window.close,
          child: Text(tr('Cancel')),
        ),
        FilledButton(onPressed: _submit, child: Text(tr('OK'))),
      ],
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final field in _fields)
              if (!_isHidden(field)) _buildField(field),
            if (_commands.isNotEmpty) ...[
              const SizedBox(height: 14),
              _SectionLabel(
                _commands.length == 1
                    ? tr('Where this command appears')
                    : tr('Where these commands appear'),
              ),
              for (final command in _commands)
                LabelledField(
                  label: command.title,
                  note: command.description,
                  child: ChoiceButton<CommandSurface>(
                    value: _surfaces[command.id] ?? CommandSurface.menu,
                    searchHint: tr('Search places'),
                    options: [
                      for (final surface in CommandSurface.values)
                        ChoiceOption(surface, surface.label),
                    ],
                    onChanged: (value) =>
                        setState(() => _surfaces[command.id] = value),
                  ),
                ),
            ],
            if (_views.isNotEmpty) ...[
              const SizedBox(height: 14),
              _SectionLabel(
                _views.length == 1
                    ? tr('Where this view appears')
                    : tr('Where these views appear'),
              ),
              // Only the surfaces the view says it can be drawn on. A viewer
              // cannot be talked into the Tools menu, and offering the choice
              // would be offering something that cannot work.
              for (final view in _views)
                LabelledField(
                  label: view.title,
                  note: view.description,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final surface in view.surfaces)
                        FilterChip(
                          label: Text(surface.label),
                          selected:
                              _viewSurfaces[view.id]?.contains(surface) ??
                                  false,
                          onSelected: (on) => setState(() {
                            final chosen =
                                _viewSurfaces[view.id] ??= <PluginSurface>{};
                            on ? chosen.add(surface) : chosen.remove(surface);
                          }),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildField(PluginField field) {
    // Settings live in ordinary preferences, which are not a place for a
    // secret. Said out loud rather than silently skipped: a plugin author who
    // declared one needs to know why it is not being collected.
    if (field.type == PluginFieldType.password) {
      return LabelledField(
        label: field.label,
        note: tr('Passwords are not kept in settings. Declare a connection instead, where the password goes to the key store.'),
        child: const TextField(enabled: false),
      );
    }

    return PluginFieldInput(
      field: field,
      controller: _text[field.key],
      flag: _flags[field.key] ?? false,
      choice: _choices[field.key],
      number: _numbers[field.key],
      onChanged: (value) => setState(() {
        if (value is bool) {
          _flags[field.key] = value;
        } else if (value is int) {
          _numbers[field.key] = value;
        } else {
          _choices[field.key] = value?.toString();
        }
      }),
    );
  }
}

/// A heading inside the form, for the part the host adds rather than the
/// plugin: where the plugin's commands are offered.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 0.8,
                fontWeight: context.uiWeight(FontWeight.w700),
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );
}
