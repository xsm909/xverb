import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../i18n/i18n.dart';
import '../vfs/shell_open.dart';
import '../vfs/vfs_path.dart';
import 'script_launch.dart';
import 'shell_kind.dart';

/// One line of console output.
class ConsoleLine {
  const ConsoleLine(this.text, this.kind);

  final String text;
  final ConsoleLineKind kind;
}

enum ConsoleLineKind {
  /// The command as the user typed it, echoed with its prompt.
  prompt,
  output,
  error,
  notice,
}

/// The Total Commander style command line: type a command, press Enter, it runs
/// in the directory the active panel is showing.
///
/// `cd` is handled here rather than passed to the shell, because a child
/// process changing its own directory would do nothing useful — the panel is
/// what needs to move.
class CommandLine extends ChangeNotifier {
  CommandLine();

  /// Text currently typed. The widget renders this; there is no TextField, so
  /// the panels keep their key bindings while the line is being edited.
  String text = '';

  int _historyIndex = -1;
  final List<String> _history = [];
  final List<ConsoleLine> _output = [];

  Process? _running;
  ShellKind shell = ShellKind.system;

  /// How a folder is handed to the desktop's own file manager.
  ///
  /// Replaceable so that a test can watch it being called: the real one opens a
  /// window, and a suite that opened one per run would litter the desk of
  /// whoever ran it.
  Future<String?> Function(String nativePath) openInFileManager = ShellOpen.open;

  /// How a command that needs a terminal of its own is given one. Replaceable
  /// for the same reason.
  Future<String?> Function(String command, {required String directory})
      openInTerminal = ScriptLaunch.runCommand;

  /// Where the history goes so the next run can have it back.
  ///
  /// Written here rather than by the screen, which is what saves the console's
  /// height: the height changes when a person drags it, and the history changes
  /// when a command is submitted — which is a thing this class knows about and
  /// nothing above it has to be told.
  Future<void> Function(List<String> entries)? saveHistory;

  /// Whether the console output pane is showing.
  bool consoleVisible = false;

  /// Height of the output pane, dragged by its top edge.
  double consoleHeight = 190;

  /// Whether the console has the whole window rather than a strip of it.
  ///
  /// F11 puts the console to full screen and back.
  /// **The height it was dragged to is kept**, so coming back out of
  /// full screen puts it where it was rather than at whatever the default is —
  /// a key that resizes something by being pressed twice is a key nobody
  /// presses twice.
  bool consoleFullScreen = false;

  static const double minConsoleHeight = 70;
  static const double maxConsoleHeight = 900;

  /// Applies a drag on the top edge. Dragging upwards grows the pane, so the
  /// delta is subtracted. [available] keeps it from swallowing the panels.
  void resizeConsole(double delta, {required double available}) {
    final ceiling = available.clamp(minConsoleHeight, maxConsoleHeight);
    final next = (consoleHeight - delta).clamp(minConsoleHeight, ceiling);
    if (next == consoleHeight) return;
    consoleHeight = next.toDouble();
    notifyListeners();
  }

  /// Output is bounded; a runaway command must not grow the heap.
  static const int maxLines = 2000;

  /// How many commands are remembered, and how many are kept between runs.
  ///
  /// Twenty, because it is a list walked with one key at a time rather than
  /// searched: past twenty presses it is quicker to type the command again.
  static const int maxHistory = 20;

  List<ConsoleLine> get output => List.unmodifiable(_output);

  /// Oldest first, which is the order it is written down and read back in.
  List<String> get history => List.unmodifiable(_history);

  /// Restores what an earlier run left behind.
  void loadHistory(Iterable<String> entries) {
    _history
      ..clear()
      ..addAll(entries.where((e) => e.trim().isNotEmpty));
    _trimHistory();
    _historyIndex = -1;
  }

  void _trimHistory() {
    if (_history.length > maxHistory) {
      _history.removeRange(0, _history.length - maxHistory);
    }
  }

  bool get isRunning => _running != null;

  bool get isEmpty => text.isEmpty;

  void insert(String characters) {
    text += characters;
    notifyListeners();
  }

  /// Replaces the whole line.
  ///
  /// What a real input needs: while the command line is being edited by
  /// pointer or touch, the text arrives already assembled rather than a
  /// keystroke at a time — a soft keyboard's autocomplete, a paste, and
  /// selecting a range and typing over it are all whole-line changes.
  void setText(String value) {
    if (value == text) return;
    text = value;
    _historyIndex = -1;
    notifyListeners();
  }

  void backspace() {
    if (text.isEmpty) return;
    text = text.substring(0, text.length - 1);
    notifyListeners();
  }

  /// Deletes back to the start of the previous word — Ctrl+Backspace.
  void deleteWord() {
    final trimmed = text.trimRight();
    final cut = trimmed.lastIndexOf(RegExp(r'[\s\\/]'));
    text = cut < 0 ? '' : trimmed.substring(0, cut + 1);
    notifyListeners();
  }

  void clear() {
    if (text.isEmpty && _historyIndex < 0) return;
    text = '';
    _historyIndex = -1;
    notifyListeners();
  }

  void clearConsole() {
    _output.clear();
    notifyListeners();
  }

  void toggleConsole() {
    consoleVisible = !consoleVisible;
    // Put away while it was filling the window, it comes back as a strip: the
    // console being hidden and full screen at once is a state nothing on the
    // screen could show.
    if (!consoleVisible) consoleFullScreen = false;
    notifyListeners();
  }

  /// F11 — the console takes the window, or gives it back.
  ///
  /// Opens it if it was not showing, because a key that does nothing until you
  /// have first pressed another one is a key that looks broken.
  void toggleConsoleFullScreen() {
    if (!consoleVisible) {
      consoleVisible = true;
      consoleFullScreen = true;
    } else {
      consoleFullScreen = !consoleFullScreen;
    }
    notifyListeners();
  }

  /// Steps through history. [delta] of -1 is the older entry.
  void recall(int delta) {
    if (_history.isEmpty) return;
    _historyIndex = (_historyIndex + delta).clamp(-1, _history.length - 1);
    text = _historyIndex < 0
        ? ''
        : _history[_history.length - 1 - _historyIndex];
    notifyListeners();
  }

  void setShell(ShellKind kind) {
    if (kind == shell) return;
    shell = kind;
    _append(tr('Shell set to {shell}.', {'shell': tr(kind.label)}),
        ConsoleLineKind.notice);
  }

  /// Stops whatever is running.
  void cancel() {
    final process = _running;
    if (process == null) return;
    process.kill();
    _append(tr('Cancelled.'), ConsoleLineKind.notice);
  }

  /// Runs the typed line.
  ///
  /// Returns a directory to navigate to when the command was a `cd`, so the
  /// caller can move the panel; null otherwise.
  Future<VfsPath?> submit({required VfsPath? location}) async {
    final command = text.trim();
    if (command.isEmpty) return null;

    text = '';
    _historyIndex = -1;
    if (_history.isEmpty || _history.last != command) {
      _history.add(command);
      _trimHistory();
      unawaited(saveHistory?.call(history));
    }
    _append('${_promptFor(location)} $command', ConsoleLineKind.prompt);

    final builtin = _runBuiltin(command, location);
    if (builtin != null) return builtin.destination;

    await _runExternal(command, location);
    return null;
  }

  String _promptFor(VfsPath? location) =>
      '${location?.display ?? ''}${shell.sigil}';

  /// Handles the commands that only make sense inside the app.
  _BuiltinResult? _runBuiltin(String command, VfsPath? location) {
    final parts = command.split(RegExp(r'\s+'));
    final head = parts.first.toLowerCase();

    switch (head) {
      case 'cls':
      case 'clear':
        _output.clear();
        notifyListeners();
        return const _BuiltinResult(null);

      case 'cd':
      case 'chdir':
        return _BuiltinResult(_resolveCd(parts.skip(1).join(' '), location));

      // A bare dot: this folder, over there. `cd .` already means stay, cmd
      // rejects a lone dot outright, and in a POSIX shell it is `source` with
      // nothing to source — so it is free to mean the useful thing, which is the
      // desktop's own window on the folder the panel is showing.
      case '.':
        _openHere(location);
        return const _BuiltinResult(null);

      // And its opposite number, which people type for the same reason they
      // type `cd ..` and expect not to have to.
      case '..':
        return _BuiltinResult(location?.parent ?? location);

      // The whole way out, in one character: a separator on its own takes the
      // panel to the root. Both spellings, because the
      // hand that types one is the hand that types the other depending on which
      // machine it learned on, and `cd \` has always meant this here.
      case '/':
      case r'\':
        return _BuiltinResult(location?.root ?? location);

      default:
        // A bare `X:` is how you switch drive in cmd, and people type it.
        final drive = _windowsDrive(command);
        return drive == null ? null : _BuiltinResult(drive);
    }
  }

  /// `C:` on its own, as a path — null when the word is not a drive.
  ///
  /// One rule for both spellings of the same intention: typed bare, which is
  /// how cmd changes drive, and after `cd`, which means the same thing to
  /// anyone who types it. They used to disagree, and the disagreement was not
  /// harmless: `cd c:` fell through to the relative branch of [_resolveCd] and
  /// made a *child* called `c:` of the folder in hand. Windows has no such
  /// path, so opening it threw `Illegal character in path: c:` — and the panel
  /// then wrote that folder down as where the drive had been left, so choosing
  /// that drive from Alt+F1 replayed the same failure ever after, naming a
  /// letter the user had not pressed.
  static VfsPath? _windowsDrive(String word) {
    if (!Platform.isWindows) return null;
    if (!RegExp(r'^[A-Za-z]:$').hasMatch(word)) return null;
    return VfsPath.local('${word.toUpperCase()}\\');
  }

  /// Opens the panel's folder in Explorer, Finder, or whatever the Linux
  /// session uses — the same folder, in the desktop's own file manager.
  void _openHere(VfsPath? location) {
    if (location == null) {
      _append(tr('There is nowhere to open.'), ConsoleLineKind.error);
      return;
    }
    if (location.scheme != VfsPath.localScheme) {
      _append(
        tr(
          'Only a local folder can be handed to the file manager; '
          '{scheme}: is served by a plugin and has no path the desktop '
          'knows about.',
          {'scheme': location.scheme},
        ),
        ConsoleLineKind.error,
      );
      return;
    }

    final native = location.toNativePath();
    // Said quietly: this is an acknowledgement of something that happened
    // *outside* the application, and it should not take space inside it by
    // opening the console pane over the panels.
    _append(tr('Opened {path} in the file manager.', {'path': native}),
        ConsoleLineKind.notice, show: false);
    unawaited(
      openInFileManager(native).then((failure) {
        if (failure != null) _append(failure, ConsoleLineKind.error);
      }),
    );
  }

  /// Works out where `cd <argument>` should take the panel.
  VfsPath? _resolveCd(String argument, VfsPath? location) {
    final target = argument.trim().replaceAll('"', '');

    if (target.isEmpty || target == '~') {
      final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
      if (home == null) {
        _append(tr('No home directory is set.'), ConsoleLineKind.error);
        return null;
      }
      return VfsPath.local(home);
    }

    // `cd c:` is a change of drive, not a folder called `c:`. Answered before
    // anything is asked of the panel's location, because it does not need one.
    final drive = _windowsDrive(target);
    if (drive != null) return drive;

    if (location == null) return null;

    if (target == '..') return location.parent ?? location;
    if (target == '.') return location;
    if (target == r'\' || target == '/') return location.root;

    // A URL moves to another provider entirely; that is how you reach ftp://.
    if (target.contains('://')) return VfsPath.parse(target);

    final isAbsolute = Platform.isWindows
        ? RegExp(r'^([A-Za-z]:[\\/]|\\\\)').hasMatch(target)
        : target.startsWith('/');
    if (isAbsolute) return VfsPath.local(target);

    // Relative: walk the segments so `../../foo` works.
    var result = location;
    for (final segment in target.split(RegExp(r'[\\/]'))) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        result = result.parent ?? result;
      } else {
        result = result.child(segment);
      }
    }
    return result;
  }

  Future<void> _runExternal(String command, VfsPath? location) async {
    if (_running != null) {
      _append('A command is already running.', ConsoleLineKind.error);
      return;
    }

    // A shell has nowhere to run unless the panel is on a real directory.
    String? workingDirectory;
    if (location != null && location.scheme == VfsPath.localScheme) {
      workingDirectory = location.toNativePath();
    } else if (location != null) {
      _append(
        'Commands need a local directory; ${location.scheme}: is served by a '
        'plugin. Switch the panel to a local path first.',
        ConsoleLineKind.error,
      );
      return;
    }

    // A shell, a REPL, or anything else that waits for a person cannot live in
    // a pane: with no terminal there is no prompt, no echo and nowhere to type.
    // Typing `cmd` used to sit there doing nothing until it was cancelled.
    if (ScriptLaunch.needsTerminal(command)) {
      if (workingDirectory == null) {
        _append(
          'A terminal needs a local directory to open in.',
          ConsoleLineKind.error,
        );
        return;
      }
      _append(
        '$command needs a terminal of its own; opened one here.',
        ConsoleLineKind.notice,
        show: false,
      );
      final refused = await openInTerminal(command, directory: workingDirectory);
      if (refused != null) _append(refused, ConsoleLineKind.error);
      return;
    }

    final invocation = ShellResolver.invocation(shell, command);
    if (invocation == null) {
      _append('${shell.label} is not installed.', ConsoleLineKind.error);
      return;
    }

    try {
      final process = await Process.start(
        invocation.executable,
        invocation.arguments,
        workingDirectory: workingDirectory,
        runInShell: false,
      );
      _running = process;
      notifyListeners();

      // stdout and stderr are interleaved as they arrive, so the ordering the
      // user sees matches what the command actually did.
      final streams = <Future<void>>[
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach((line) => _append(line, ConsoleLineKind.output)),
        process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach((line) => _append(line, ConsoleLineKind.error)),
      ];

      final code = await process.exitCode;
      await Future.wait(streams);

      if (code != 0) {
        _append('Exited with code $code.', ConsoleLineKind.notice);
      }
    } on ProcessException catch (e) {
      _append('${e.message} (${e.executable})', ConsoleLineKind.error);
    } on Object catch (e) {
      _append('$e', ConsoleLineKind.error);
    } finally {
      _running = null;
      notifyListeners();
    }
  }

  /// [show] is for the rare line that is not worth taking space from the panels
  /// — an acknowledgement of something that happened outside the application,
  /// where the result is already on screen in another window.
  void _append(String line, ConsoleLineKind kind, {bool show = true}) {
    _output.add(ConsoleLine(line, kind));
    if (_output.length > maxLines) {
      _output.removeRange(0, _output.length - maxLines);
    }
    // Any output is worth showing; a command that printed something the user
    // cannot see is worse than no command line at all.
    if (show && kind != ConsoleLineKind.prompt) consoleVisible = true;
    notifyListeners();
  }
}

class _BuiltinResult {
  const _BuiltinResult(this.destination);

  /// Where the panel should go, or null when the builtin did its work in place.
  final VfsPath? destination;
}
