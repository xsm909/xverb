import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/plugins/viewer.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/i18n/i18n.dart';
import '../widgets/hint.dart';
import '../widgets/context_menu.dart' show MenuItem, showAppContextMenu;
import 'plugin_table.dart' show appearanceOf;

/// Fields to fill in, and the buttons that do something with them.
///
/// **The one content a plugin is told something through.** Everything else in
/// the view contract goes one way — the plugin describes, the host draws, the
/// user presses a row — and that was enough until committing, which needs a
/// sentence somebody typed. `ask` is yes or no and a row is a row, so this is
/// the gap it fills.
///
/// The typing stays here. A round trip per keystroke would put a pipe and a
/// Python process between a key and the letter appearing, so nothing leaves
/// until a button is pressed, and then everything does: the press carries what
/// every field holds. What the host answers on its own is the small part that
/// cannot wait — a primary button greyed out while a field the plugin called
/// `required` is still empty.
class PluginForm extends StatefulWidget {
  const PluginForm({super.key, required this.content, this.onSubmit});

  final ViewerContent content;

  /// A button was pressed, with what every field held at that moment.
  final void Function(String buttonId, Map<String, Object?> values)? onSubmit;

  @override
  State<PluginForm> createState() => _PluginFormState();
}

class _PluginFormState extends State<PluginForm> {
  final Map<String, TextEditingController> _typed = {};
  final Map<String, FocusNode> _focus = {};
  final Map<String, bool> _ticked = {};

  /// What the plugin last said each field holds.
  ///
  /// The difference between this and the controller is the whole rule: a form
  /// redrawn because a file was staged must keep the sentence being written in
  /// it, and a form whose plugin *changed* a value — amend filling in the last
  /// message — must show the new one. So a declared value is adopted when the
  /// declaration itself changed, and ignored when it did not.
  final Map<String, String> _declared = {};

  @override
  void initState() {
    super.initState();
    _adopt(const ViewerContent(kind: ViewerContentKind.form));
  }

  @override
  void didUpdateWidget(PluginForm old) {
    super.didUpdateWidget(old);
    _adopt(old.content);
  }

  @override
  void dispose() {
    for (final controller in _typed.values) {
      controller.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Whether the keyboard is inside one of the fields.
  ///
  /// What Escape means depends on it: out of the field first, and only then
  /// out of the page. A page that closed while a message was being written
  /// would lose the message to the one key everybody presses to change their
  /// mind about a word — see the rule the whole application follows.
  bool get _writing => _focus.values.any((node) => node.hasFocus);

  void _adopt(ViewerContent old) {
    final live = <String>{};
    for (final field in widget.content.fields) {
      live.add(field.id);
      if (field.kind == ContentFieldKind.check) {
        _ticked.putIfAbsent(field.id, () => field.checked);
        continue;
      }
      final controller = _typed.putIfAbsent(
        field.id,
        () => TextEditingController(text: field.value),
      );
      _focus.putIfAbsent(field.id, FocusNode.new);
      if (_declared[field.id] != field.value) {
        if (controller.text != field.value) controller.text = field.value;
      }
      _declared[field.id] = field.value;
    }
    // A field the plugin stopped asking for takes its typing with it.
    for (final gone in _typed.keys.toList()) {
      if (!live.contains(gone)) _typed.remove(gone)!.dispose();
    }
    for (final gone in _focus.keys.toList()) {
      if (!live.contains(gone)) _focus.remove(gone)!.dispose();
    }
    _ticked.removeWhere((id, _) => !live.contains(id));
    _declared.removeWhere((id, _) => !live.contains(id));
  }

  Map<String, Object?> get _values => {
        for (final field in widget.content.fields)
          field.id: field.kind == ContentFieldKind.check
              ? (_ticked[field.id] ?? field.checked)
              : (_typed[field.id]?.text ?? field.value),
      };

  /// Whether everything the plugin said it cannot do without has been filled
  /// in. Asked here rather than of the plugin: a question answered over a pipe
  /// is a question answered a keystroke late.
  bool get _ready => widget.content.fields.every(
        (field) =>
            !field.required ||
            field.kind == ContentFieldKind.check ||
            (_typed[field.id]?.text.trim().isNotEmpty ?? false),
      );

  ContentButton? get _primary {
    final primary = [
      for (final button in widget.content.buttons)
        if (button.primary) button,
    ];
    return primary.length == 1 ? primary.single : null;
  }

  void _press(ContentButton button) =>
      widget.onSubmit?.call(button.id, _values);

  @override
  Widget build(BuildContext context) {
    final theme = appearanceOf(context);
    final fields = widget.content.fields;
    final ticks = [
      for (final field in fields)
        if (field.kind == ContentFieldKind.check) field,
    ];

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        // The one key a form of any size can be finished with, and the one
        // every application that takes a message uses for it. Enter alone
        // belongs to the message: a commit message has paragraphs.
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            const _SubmitIntent(),
        const SingleActivator(LogicalKeyboardKey.enter, meta: true):
            const _SubmitIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const _LeaveIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SubmitIntent: CallbackAction<_SubmitIntent>(
            onInvoke: (_) {
              final button = _primary;
              if (button != null && _ready) _press(button);
              return null;
            },
          ),
          // Enabled only while a field has the keyboard, so the key is used
          // here when it means "out of this field" and left alone — to reach
          // whatever is above — when it means "out of this page".
          _LeaveIntent: _LeaveFieldAction(
            writing: () => _writing,
            // **Back to whoever had the keyboard**, not merely out of the
            // field. Plain `unfocus()` hands it to the enclosing scope, which
            // is nobody: the panel's own handler sits above the field and
            // never sees another key, so Escape out of a message left the
            // application deaf until something was clicked.
            leave: () => FocusManager.instance.primaryFocus?.unfocus(
              disposition: UnfocusDisposition.previouslyFocusedChild,
            ),
          ),
        },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final field in fields)
                if (field.kind != ContentFieldKind.check)
                  // The tall one takes what is left, so a message box in a
                  // part fills it however the divider is dragged. A row of
                  // short fields above it stays the height it needs.
                  field.kind == ContentFieldKind.lines
                      ? Expanded(child: _field(theme, field))
                      : _field(theme, field),
              if (ticks.isNotEmpty || widget.content.buttons.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  // Wrapped, not a row. A form lives in a part of a split, a
                  // part is as wide as the divider leaves it, and two buttons
                  // with words on them do not fit a narrow one — which is a
                  // button nobody can reach, and a striped edge over the page
                  // saying so. They go onto a second line instead.
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tick in ticks) _tick(theme, tick),
                      for (final button in widget.content.buttons)
                        _button(button),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(AppearanceSettings theme, ContentField field) {
    final tall = field.kind == ContentFieldKind.lines;
    final ink = theme.panelForeground;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (field.label.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                field.label,
                style: TextStyle(
                  color: ink.withValues(alpha: 0.7),
                  fontSize: theme.fontSize - 1,
                  fontWeight: theme.uiFontWeight.weight,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          if (tall)
            Expanded(child: _box(theme, field, tall: true))
          else
            _box(theme, field, tall: false),
        ],
      ),
    );
  }

  Widget _box(AppearanceSettings theme, ContentField field, {required bool tall}) {
    final ink = theme.panelForeground;
    return TextField(
      controller: _typed[field.id],
      focusNode: _focus[field.id],
      expands: tall,
      maxLines: tall ? null : 1,
      minLines: null,
      textAlignVertical: TextAlignVertical.top,
      // What is typed decides whether the primary button can be pressed, and
      // that is the only thing typing changes here.
      onChanged: (_) => setState(() {}),
      style: TextStyle(
        color: ink,
        fontSize: theme.fontSize,
        decoration: TextDecoration.none,
      ),
      cursorColor: theme.accentColor,
      decoration: InputDecoration(
        isDense: true,
        hintText: field.hint,
        hintStyle: TextStyle(
          color: ink.withValues(alpha: 0.4),
          fontSize: theme.fontSize,
        ),
        filled: true,
        fillColor: ink.withValues(alpha: 0.06),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: ink.withValues(alpha: 0.2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: ink.withValues(alpha: 0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: theme.accentColor),
        ),
      ),
    );
  }

  Widget _tick(AppearanceSettings theme, ContentField field) {
    final on = _ticked[field.id] ?? field.checked;
    return InkWell(
        onTap: () => setState(() => _ticked[field.id] = !on),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: on,
                activeColor: theme.accentColor,
                onChanged: (value) =>
                    setState(() => _ticked[field.id] = value ?? false),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              field.label,
              style: TextStyle(
                color: theme.panelForeground,
                fontSize: theme.fontSize - 1,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
    );
  }

  Widget _button(ContentButton button) {
    // Only the primary one waits for the fields. A form's other buttons are
    // ways out of it — Discard, Cancel — and a way out that greys itself out
    // because nothing has been typed is a trap.
    final pressable = !button.primary || _ready;
    final press = pressable ? () => _press(button) : null;
    final label = Text(tr(button.label), maxLines: 1);

    // Material's own buttons are drawn for a dialog with room to spare. This
    // one stands in a part of a split beside two listings, so it is given the
    // room a word needs and no more — the same reason the panels' own chrome
    // is tighter than a settings page's.
    final tight = ButtonStyle(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: button.primary ? 14 : 10, vertical: 4),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
    );

    if (button.danger) {
      final colors = Theme.of(context).colorScheme;
      return FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: colors.error,
          foregroundColor: colors.onError,
        ).merge(tight),
        onPressed: press,
        child: label,
      );
    }

    final plain = button.primary
        ? FilledButton(style: tight, onPressed: press, child: label)
        : OutlinedButton(style: tight, onPressed: press, child: label);
    if (button.items.isEmpty) return plain;

    // The same button with more of it behind an arrow. The face of it does the
    // usual thing — one press, no menu, nothing to read — and what is rarer
    // stands one press further away instead of taking a button of its own.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        plain,
        _More(button: button, enabled: pressable, onPick: _pick),
      ],
    );
  }

  /// A row of a button's own menu was chosen: the same press, another name.
  void _pick(String id) => widget.onSubmit?.call(id, _values);
}

/// The arrow beside a button that carries more of its kind.
class _More extends StatelessWidget {
  const _More({
    required this.button,
    required this.enabled,
    required this.onPick,
  });

  final ContentButton button;
  final bool enabled;
  final ValueChanged<String> onPick;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    await showAppContextMenu(
      context: context,
      // Anchored to the arrow, so the menu appears where the finger already
      // is — the same rule the pills and the path bar follow.
      anchorRect: box.localToGlobal(Offset.zero) & box.size,
      searchHint: button.label,
      nodes: [
        for (final item in button.items)
          MenuItem(item.label, onSelected: () => onPick(item.id)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Hint(
                                          message: tr('More'),
                                          child: IconButton(
          icon: const Icon(Icons.expand_more, size: 16),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 26, height: 30),
          onPressed: enabled ? () => unawaited(_open(context)) : null,
        ),
                                        );
}

class _SubmitIntent extends Intent {
  const _SubmitIntent();
}

class _LeaveIntent extends Intent {
  const _LeaveIntent();
}

/// Escape, out of a field and no further.
///
/// Its own class rather than a callback because whether it is *enabled* is the
/// whole point: an action that is not enabled does not consume the key, and
/// the page above goes on answering Escape the way it always has.
class _LeaveFieldAction extends Action<_LeaveIntent> {
  _LeaveFieldAction({required this.writing, required this.leave});

  final bool Function() writing;
  final VoidCallback leave;

  @override
  bool isEnabled(_LeaveIntent intent, [BuildContext? context]) => writing();

  @override
  Object? invoke(_LeaveIntent intent) {
    leave();
    return null;
  }
}
