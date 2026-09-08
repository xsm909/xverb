import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../core/shell/command_line.dart';
import '../../core/shell/shell_kind.dart';
import '../../core/vfs/vfs_path.dart';
import '../widgets/x_button.dart';
import '../windows/window_dialogs.dart';

/// The Total Commander style command line.
///
/// It is drawn rather than being a `TextField` while nobody is editing it, on
/// purpose: the panels own the keyboard, so arrows keep navigating the listing
/// while you type a command, exactly as they do in Total Commander. Keys arrive
/// from the commander's key handler and are applied to [CommandLine].
///
/// Pressing the line — or the console — hands it a real input instead, which is
/// the only way it can be used at all without a hardware keyboard: a drawn line
/// raises no soft keyboard, so on a phone the command line was decoration.
/// Escape, or a press anywhere else, gives the keyboard back to the panels.
/// The stretch of the bar that hands the line a real input when pressed.
///
/// Named so that a test can aim at the thing itself. Aiming beside the prompt
/// instead meant finding the prompt, and its sigil is `>` on Windows and `$`
/// everywhere else — so five tests written on a Mac failed here for a reason
/// that had nothing to do with the command line.
const Key commandLineFieldKey = Key('commandLine.field');

class CommandLineBar extends StatelessWidget {
  const CommandLineBar({
    super.key,
    required this.commandLine,
    required this.location,
    required this.focused,
    required this.onPickShell,
    required this.onToggleConsole,
    required this.editing,
    required this.input,
    required this.inputText,
    required this.onBeginEditing,
    required this.onSubmit,
    required this.onDismiss,
  });

  final CommandLine commandLine;
  final VfsPath? location;

  /// True once the user has typed something, which is when the caret shows.
  final bool focused;

  final VoidCallback onPickShell;
  final VoidCallback onToggleConsole;

  /// Whether the real input is up.
  ///
  /// A flag rather than [input]`.hasFocus`: the node is only in the tree while
  /// the field is, and asking an unattached node to take focus does nothing at
  /// all — which is exactly the chicken-and-egg that made the first version of
  /// this do nothing when pressed.
  final bool editing;

  /// Focus of the real input, held by the screen so the console can hand the
  /// line the keyboard too.
  final FocusNode input;
  final TextEditingController inputText;

  /// The line was pressed: fill the input from what is typed and focus it.
  final VoidCallback onBeginEditing;

  /// Enter in the input. The screen runs the command, as it does for Enter in
  /// a panel — one path, so a command behaves the same however it was entered.
  final VoidCallback onSubmit;

  /// Escape, or focus lost: the panels take the keyboard back.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    // The bar stands on the header's fill, so it is written in the header's
    // ink. It used to take the *panel's*, which on a light palette is a dark
    // ink on a dark strip: measured 2026-08-15 at 1.9:1 against the fill, which
    // is a path nobody can read.
    final foreground = theme.headerForeground;

    return Container(
      height: 26,
      color: theme.effectiveHeaderBackground,
      padding: const EdgeInsets.only(left: 6),
      // Exactly one flexible child, and it is tight: the command area.
      //
      // Two flexible children do not work here. A loose one shrink-wraps its
      // text but is still allocated a share of the free space, and the unused
      // remainder collects after the last child, pushing the toggle off the
      // right edge. Making the path tight instead fixed that but gave the path
      // a fixed slice of the bar, stranding the prompt in the middle. So the
      // path is capped by a plain constraint and shrink-wraps.
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
        children: [
          ExcludeFocus(
            child: XButton(
              icon: Icons.terminal,
              label: tr(commandLine.shell.label),
              tooltip: tr('Choose the shell'),
              shape: XButtonShape.pill,
              tone: XButtonTone.accent,
              // The shell's name is text like any other. XButton takes its own
              // text size from its height, so the height is what has to follow
              // the setting — left at 20 the pill kept saying "System default"
              // at ten points while the listing beside it grew.
              height: theme.scaled(20),
              iconSize: theme.scaled(13),
              onPressed: onPickShell,
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.4),
            child: Text(
              location?.display ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground.withValues(alpha: 0.65),
                fontSize: theme.fontSize - 1,
                fontFamily: theme.consoleFamily,
              ),
            ),
          ),
          Text(
            '${commandLine.shell.sigil} ',
            style: TextStyle(
              color: theme.accentColor,
              fontSize: theme.fontSize - 1,
              fontFamily: theme.consoleFamily,
              fontWeight: FontWeight.w700,
            ),
          ),
          Expanded(
            child: editing
                ? _CommandInput(
                    focus: input,
                    controller: inputText,
                    commandLine: commandLine,
                    onSubmit: onSubmit,
                    onDismiss: onDismiss,
                  )
                : GestureDetector(
                    key: commandLineFieldKey,
                    // Opaque, so the whole empty stretch of the line is the
                    // target. A caret you have to hit exactly is a caret
                    // nobody finds on a phone.
                    behavior: HitTestBehavior.opaque,
                    onTap: onBeginEditing,
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            commandLine.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: foreground,
                              fontSize: theme.fontSize - 1,
                              fontFamily: theme.consoleFamily,
                            ),
                          ),
                        ),
                        if (focused)
                          _Caret(
                            color: theme.accentColor,
                            height: theme.fontSize,
                          ),
                      ],
                    ),
                  ),
          ),
          if (commandLine.isRunning)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: theme.accentColor,
                ),
              ),
            ),
          // There is only ever one toggle, and it rides with the console
          // header: while the console is open the button lives up there, so
          // it stays next to the thing it collapses.
          if (!commandLine.consoleVisible) ...[
            const SizedBox(width: 6),
            ExcludeFocus(
              child: XButton(
                icon: Icons.keyboard_arrow_up,
                tooltip: tr('Show console  (Ctrl+O)'),
                shape: XButtonShape.circle,
                tone: XButtonTone.accent,
                height: 22,
                iconSize: 16,
                onPressed: onToggleConsole,
              ),
            ),
            const SizedBox(width: 4),
          ],
        ],
        ),
      ),
    );
  }
}

/// The real input, shown only while the line is being edited by pointer or
/// touch.
///
/// It is deliberately indistinguishable from the drawn line: same face, same
/// size, same colours, no border and no decoration of its own. The one thing
/// that changes when the line is pressed is that the caret becomes a real one,
/// which is the whole of what the press promised. A field that announced
/// itself with a box would be the application admitting it has two command
/// lines, and the bar is 26 logical pixels tall besides — a decorated field
/// has a minimum height of its own and would not fit in it.
class _CommandInput extends StatelessWidget {
  const _CommandInput({
    required this.focus,
    required this.controller,
    required this.commandLine,
    required this.onSubmit,
    required this.onDismiss,
  });

  final FocusNode focus;
  final TextEditingController controller;
  final CommandLine commandLine;
  final VoidCallback onSubmit;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;

    // Escape is not caught here. A TextField does not use it, so it travels up
    // to the commander's own handler either way — and that handler is reached
    // whether or not the field ended up with the focus, which a Focus wrapper
    // around this could not promise.
    return TextField(
      focusNode: focus,
      controller: controller,
      // Not enough on its own — the screen also asks for the focus after the
      // frame, because autofocus is ignored while anything else in the scope
      // holds it, and the commander's own key handler always does. Kept
      // because it is what raises the soft keyboard on a phone.
      autofocus: true,
      // A shell command is not prose. Autocorrect turning `ls` into `is` is
      // not a small annoyance here; it is a different command.
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.go,
      maxLines: 1,
      cursorColor: theme.accentColor,
      style: TextStyle(
        color: theme.headerForeground,
        fontSize: theme.fontSize - 1,
        fontFamily: theme.consoleFamily,
      ),
      decoration: const InputDecoration(
        isCollapsed: true,
        border: InputBorder.none,
      ),
      onChanged: commandLine.setText,
      onSubmitted: (_) => onSubmit(),
      onTapOutside: (_) => onDismiss(),
    );
  }
}

/// A hollow block caret: what you type lands here, but the keyboard is in the
/// panel.
///
/// **It used to blink, and that was the confusion.** The drawn line is what is
/// showing whenever the keyboard is *not* in the command line — and a blinking
/// caret is the one thing on a screen that means "type here". So the state
/// where you are in the panel advertised itself as the state where you are in
/// the line, while the state where you really are in the line showed the thin
/// caret of a text field. Two carets, and the loud one on the wrong state.
///
/// Hollow and still now, against the field's own solid blinking one. Filled and
/// blinking means the line has the keyboard; an outline means it is only
/// collecting what is typed at the panel, which is what Total Commander's
/// command line does.
class _Caret extends StatelessWidget {
  const _Caret({required this.color, required this.height});

  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: height,
      margin: const EdgeInsets.only(left: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.75)),
      ),
    );
  }
}

/// Captured output from the commands that have been run.
class ConsolePane extends StatefulWidget {
  const ConsolePane({
    super.key,
    required this.commandLine,
    this.fills = false,
    required this.onCollapse,
    required this.onResize,
    required this.onResizeEnd,
    required this.onBeginEditing,
  });

  final CommandLine commandLine;

  /// Whether it has the whole window — F11 — rather than the strip it was
  /// dragged to. The dragged height is left alone either way, so coming back
  /// out of full screen puts it where it was.
  final bool fills;

  final VoidCallback onCollapse;

  /// The console was pressed. A console is a place you type into everywhere
  /// else, so pressing it puts the caret in the line below rather than doing
  /// nothing at all.
  final VoidCallback onBeginEditing;

  /// Vertical drag on the top edge, in logical pixels.
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;

  @override
  State<ConsolePane> createState() => _ConsolePaneState();
}

class _ConsolePaneState extends State<ConsolePane> {
  final ScrollController _scroll = ScrollController();
  int _lastCount = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _stickToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final lines = widget.commandLine.output;

    if (lines.length != _lastCount) {
      _lastCount = lines.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _stickToBottom());
    }

    return Container(
      height: widget.fills ? null : widget.commandLine.consoleHeight,
      decoration: BoxDecoration(
        color: theme.backdrop == WindowBackdrop.opaque
            ? theme.effectiveConsoleBackground
            : theme.effectiveConsoleBackground
                .withValues(alpha: theme.panelOpacity),
      ),
      child: Column(
        children: [
          _ResizeHandle(
            color: theme.effectiveConsoleForeground,
            accent: theme.accentColor,
            onDrag: widget.onResize,
            onDragEnd: widget.onResizeEnd,
          ),
          Container(
            // Holds text, so it grows with the text rather than cropping it.
            height: theme.scaled(24),
            padding: const EdgeInsets.only(left: 8),
            color: theme.effectiveHeaderBackground,
            child: Row(
              children: [
                Text(
                  '${tr('CONSOLE')} · ${tr(widget.commandLine.shell.label)}',
                  style: TextStyle(
                    fontSize: theme.fontSize - 3,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700,
                    // Measured at 1.15:1 against its own strip before this —
                    // the words were there and could not be seen at all.
                    color: theme.headerForeground.withValues(alpha: 0.6),
                  ),
                ),
                const Spacer(),
                if (widget.commandLine.isRunning)
                  ExcludeFocus(
                    child: TextButton(
                      onPressed: widget.commandLine.cancel,
                      child: Text(
                        tr('Stop'),
                        style: TextStyle(fontSize: theme.scaled(11)),
                      ),
                    ),
                  ),
                ExcludeFocus(
                  child: XButton(
                    icon: Icons.delete_sweep_outlined,
                    tooltip: tr('Clear the console'),
                    shape: XButtonShape.bare,
                    height: 20,
                    iconSize: 14,
                    onPressed: widget.commandLine.clearConsole,
                  ),
                ),
                const SizedBox(width: 4),
                ExcludeFocus(
                  child: XButton(
                    icon: Icons.keyboard_arrow_down,
                    tooltip: tr('Collapse console  (Ctrl+O)'),
                    shape: XButtonShape.circle,
                    tone: XButtonTone.accent,
                    height: 20,
                    iconSize: 15,
                    onPressed: widget.onCollapse,
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          Expanded(
            // The tap is on the way down and the output is still selectable:
            // a drag selects text as before, and only a plain press reaches
            // here to hand the line the keyboard.
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: widget.onBeginEditing,
              child: lines.isEmpty
                ? Center(
                    child: Text(
                      tr('Type a command and press Enter.'),
                      style: TextStyle(
                        color: theme.effectiveConsoleForeground
                            .withValues(alpha: 0.4),
                        fontSize: theme.fontSize - 1,
                      ),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      itemCount: lines.length,
                      itemBuilder: (context, index) {
                        final line = lines[index];
                        return Text(
                          line.text,
                          style: TextStyle(
                            fontFamily: theme.consoleFamily,
                            fontSize: theme.fontSize - 1,
                            height: 1.35,
                            color: switch (line.kind) {
                              ConsoleLineKind.prompt => theme.accentColor,
                              ConsoleLineKind.error => const Color(0xFFFF8A80),
                              ConsoleLineKind.notice => theme.markedColor,
                              // *Default* text: what a line is drawn in when
                              // nothing else has claimed it, so a prompt, a
                              // failure and a remark keep theirs.
                              ConsoleLineKind.output =>
                                theme.effectiveConsoleForeground,
                            },
                          ),
                        );
                      },
                    ),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The console's top edge, dragged to change its height.
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({
    required this.color,
    required this.accent,
    required this.onDrag,
    required this.onDragEnd,
  });

  final Color color;
  final Color accent;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _dragging;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onVerticalDragStart: (_) => setState(() => _dragging = true),
        onVerticalDragUpdate: (details) => widget.onDrag(details.delta.dy),
        onVerticalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        // A 6px strip is easy to hit, and it shows nothing at rest: the strip
        // under the panels carries the one hairline the chrome is divided by,
        // and a second line a pixel from it is that line drawn twice. What is
        // left is the grip, and the accent while it is being pulled.
        child: Container(
          height: 6,
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Container(
            height: active ? 2 : 0,
            color: active ? widget.accent : Colors.transparent,
          ),
        ),
      ),
    );
  }
}

/// Lets the user pick which shell commands run in.
Future<ShellKind?> pickShell(BuildContext context, ShellKind current) {
  final available = ShellResolver.available();

  return showDeskWindow<ShellKind>(
    context,
    id: 'shell-picker',
    title: tr('Run commands in'),
    icon: Icons.terminal,
    preferredSize: const Size(460, 300),
    minSize: const Size(340, 220),
    builder: (window) => WindowForm(
      padding: const EdgeInsets.symmetric(vertical: 6),
      actions: [
        TextButton(onPressed: window.close, child: Text(tr('Cancel'))),
      ],
      child: ListView(
        children: [
          for (final kind in available)
            ListTile(
              dense: true,
              leading: Icon(
                kind == current ? Icons.radio_button_checked : Icons.terminal,
              ),
              title: Text(tr(kind.label)),
              subtitle: Text(
                ShellResolver.executableFor(kind) ?? tr('not found'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => window.close(kind),
            ),
        ],
      ),
    ),
  );
}
