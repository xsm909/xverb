import 'dart:io';

import 'package:path/path.dart' as p;

import '../i18n/i18n.dart';
import '../vfs/shell_open.dart';
import 'shell_kind.dart';

/// Runs a script the way a commander does: in a terminal window of its own, in
/// the folder the script lives in.
///
/// Both halves of that matter and neither was true before. Handing a `.bat` to
/// the desktop ran it in a console that closed the instant it finished, so
/// whatever it printed — including why it failed — was gone before it could be
/// read. And it ran in *the application's* working directory, so a script
/// written to sit beside the files it works on found none of them.
///
/// The terminal is left open on purpose. A script run from a file manager is
/// being run to be watched; a window that vanishes is the thing people work
/// around by putting `pause` at the end of every batch file they write.
/// What to start, or why nothing can be.
class ScriptInvocation {
  const ScriptInvocation({this.file, this.parameters, this.refusal});

  /// The program to run — a shell, not the script itself.
  final String? file;

  /// Its whole argument string, quoted for the shell.
  final String? parameters;

  /// A sentence for the user when there is nothing on this machine that could
  /// run the script. Non-null exactly when [file] is null.
  final String? refusal;
}

class ScriptLaunch {
  const ScriptLaunch._();

  /// Extensions treated as a script to be run rather than a file to be opened.
  ///
  /// Deliberately short. Everything here is a program in text form that the
  /// user of a file manager expects to *run* on Enter; a `.py` or a `.rb` is
  /// left to whatever the desktop has associated with it, because on most
  /// machines that is an editor and changing that would be a surprise.
  static const Set<String> extensions = {
    'bat',
    'cmd',
    'ps1',
    'sh',
    'bash',
    'zsh',
    'command',
  };

  static bool isScript(String nativePath) =>
      extensions.contains(_extensionOf(nativePath));

  /// Programs that wait for a person: a bare invocation of one has nothing to
  /// read and nothing to print, so captured in a pane it simply hangs.
  ///
  /// Typing `cmd` was doing exactly that. A shell with no terminal is a shell
  /// with no prompt, no echo and nowhere to type — the pane sat empty until the
  /// command was cancelled.
  static const Set<String> _shells = {
    'cmd', 'cmd.exe',
    'powershell', 'powershell.exe', 'pwsh', 'pwsh.exe',
    'bash', 'sh', 'zsh', 'fish', 'ash', 'dash',
    'wsl', 'wsl.exe',
  };

  /// Read-eval-print loops, which are shells in every way that matters here.
  static const Set<String> _repls = {
    'python', 'python3', 'py', 'node', 'deno', 'irb', 'lua', 'ghci', 'iex',
    'psql', 'mysql', 'sqlite3', 'redis-cli', 'mongosh', 'dart',
  };

  /// These take the whole terminal over whatever they are given, so the number
  /// of arguments says nothing about them.
  static const Set<String> _fullScreen = {
    'ssh', 'sftp', 'telnet', 'ftp', 'nc',
    'vim', 'vi', 'nvim', 'nano', 'pico', 'emacs', 'joe',
    'less', 'more', 'most', 'top', 'htop', 'btop', 'watch', 'man',
    'mc', 'ranger', 'tmux', 'screen',
    'diskpart', 'nslookup', 'netsh', 'edit',
  };

  /// Flags that mean "stay and talk to me" whatever else was asked for.
  static const Set<String> _interactiveFlags = {'-i', '-noexit', '--interactive'};

  /// Whether [command] has to be given a terminal of its own rather than being
  /// run into the console pane.
  ///
  /// A shell or a REPL only when it is asked for **bare**: `python` waits for
  /// input, `python build.py` prints and exits, and the second belongs in the
  /// pane where its output can be read and copied. The full-screen programs
  /// count whatever their arguments are.
  ///
  /// A list is a guess, and guesses need a way round them, so the Console menu
  /// opens a terminal outright — that is the answer for anything this does not
  /// know about.
  static bool needsTerminal(String command) {
    final words = command.trim().split(RegExp(r'\s+'));
    if (words.isEmpty || words.first.isEmpty) return false;

    final name = _nameOf(words.first);
    final bare = words.length == 1;

    if (_fullScreen.contains(name)) return true;
    if ((_shells.contains(name) || _repls.contains(name)) && bare) return true;

    return words
        .skip(1)
        .any((word) => _interactiveFlags.contains(word.toLowerCase()));
  }

  /// The program a word names, without the path or the quotes around it.
  static String _nameOf(String word) =>
      word.replaceAll('"', '').split(RegExp(r'[\\/]')).last.toLowerCase();

  /// True when the whole command is nothing but the name of a shell.
  ///
  /// Such a command asks to *be* a shell, so it has to replace the one the
  /// terminal starts with rather than run underneath it. Left as it was, the
  /// user ends up two deep and the first `exit` appears to do nothing.
  ///
  /// The REPLs are deliberately not on this list. Leaving `python` on top of a
  /// shell is what a person expects: quitting it should give them their prompt
  /// back, not close the window.
  static bool _isBareShell(String command) {
    final words = command.trim().split(RegExp(r'\s+'));
    return words.length == 1 && _shells.contains(_nameOf(words.first));
  }

  /// Runs a typed command line in a terminal of its own, in [directory].
  ///
  /// Returns a message on failure, or null when a terminal was started.
  static Future<String?> runCommand(
    String command, {
    required String directory,
  }) async {
    try {
      if (Platform.isWindows) return _windowsCommand(command, directory);
      if (Platform.isMacOS) return await _macOSCommand(command, directory);
      if (Platform.isLinux) {
        return await _linuxRun(linuxCommandLine(command), directory);
      }
      return tr('Opening a terminal is not supported here.');
    } on Object catch (e) {
      return '$e';
    }
  }

  static String? _windowsCommand(String command, String directory) {
    // A shell asked for by name is started as itself. Wrapping it in another
    // shell would work and would leave the user two deep, with the first `exit`
    // appearing to do nothing.
    if (_isBareShell(command)) {
      return ShellOpen.execute(file: command.trim(), directory: directory);
    }

    // Everything else goes through cmd, which resolves what was typed exactly as
    // typed — PATH, built-ins like `dir`, redirection and quotes — and whose
    // window stays afterwards, so a program that exits at once still leaves its
    // output on screen.
    return ShellOpen.execute(
      file: 'cmd.exe',
      parameters: '/k $command',
      directory: directory,
    );
  }

  static String _extensionOf(String nativePath) {
    final extension = p.extension(nativePath);
    return extension.isEmpty ? '' : extension.substring(1).toLowerCase();
  }

  /// Starts [nativePath] in its own terminal. Returns a message on failure, or
  /// null when a terminal was started.
  ///
  /// Only the Windows path is measured — a test host has no terminal to open and
  /// no way to look at one, so what macOS and Linux do here has been written
  /// from their documented behaviour and not observed.
  static Future<String?> run(String nativePath) async {
    final directory = p.dirname(nativePath);
    final kind = _extensionOf(nativePath);

    try {
      if (Platform.isWindows) return _windows(nativePath, directory, kind);
      if (Platform.isMacOS) return await _macOS(nativePath, directory);
      if (Platform.isLinux) return await _linux(nativePath, directory);
      return tr('Running scripts is not supported here.');
    } on Object catch (e) {
      return '$e';
    }
  }

  /// Every argument goes through the shell as one string, so a path with a
  /// space in it has to carry its own quotes.
  static String _quoted(String path) => '"$path"';

  static String? _windows(String script, String directory, String kind) {
    final invocation = windowsInvocation(script, kind);
    if (invocation.refusal != null) return invocation.refusal;

    return ShellOpen.execute(
      file: invocation.file!,
      parameters: invocation.parameters,
      directory: directory,
    );
  }

  /// What Windows will be asked to start, worked out without starting it.
  ///
  /// Separate from [run] so that it can be checked without a terminal window
  /// appearing: a test that opened one would leave it on the desk of whoever ran
  /// the suite, every run.
  static ScriptInvocation windowsInvocation(String script, String kind) {
    switch (kind) {
      case 'bat':
      case 'cmd':
        // /k rather than /c: the window stays, with a prompt already in the
        // script's own folder, which is usually where the next command belongs.
        return ScriptInvocation(
          file: 'cmd.exe',
          parameters: '/k ${_quoted(script)}',
        );

      case 'ps1':
        final powershell = ShellResolver.executableFor(ShellKind.powershell);
        if (powershell == null) {
          return ScriptInvocation(refusal: tr('PowerShell is not installed.'));
        }
        // Bypass for this one process only, and nothing is written to the
        // machine's policy: a script the user just asked to run is a script the
        // user meant to run, and the alternative is a refusal they cannot act
        // on from here.
        return ScriptInvocation(
          file: powershell,
          parameters:
              '-NoExit -ExecutionPolicy Bypass -File ${_quoted(script)}',
        );

      default:
        // A shell script on Windows needs a shell that understands it. Git for
        // Windows ships one and is on most developers' machines; without it
        // there is nothing to run this in, and saying so is more use than
        // handing the file to Notepad.
        final bash = ShellResolver.executableFor(ShellKind.gitBash);
        if (bash == null) {
          return const ScriptInvocation(
            refusal: 'A shell script needs Git Bash, which is not installed.',
          );
        }
        return ScriptInvocation(
          file: bash,
          parameters: '-c "${_shellQuoted(script)}; exec bash"',
        );
    }
  }

  /// A path inside a double-quoted shell string, safe for spaces.
  static String _shellQuoted(String path) => "'${path.replaceAll("'", r"'\''")}'";

  /// Terminal.app, told to run a script file. A path is one word however many
  /// spaces are in it, so it goes in quoted.
  static Future<String?> _macOS(String script, String directory) =>
      _macOSRun('cd ${_shellQuoted(directory)} && ${_shellQuoted(script)}');

  /// The line Terminal.app is asked to run for a **typed** command, worked out
  /// without opening a window.
  ///
  /// There is no way to hand a working directory to `do script`, so the line
  /// carries its own `cd`. The command itself is passed through as typed —
  /// quoting it the way a script path is quoted would turn `ls -la` into the
  /// name of a program nobody has.
  ///
  /// A bare shell does not come through here at all; see
  /// [macOSLauncherScript] for why it cannot.
  ///
  /// Public for the same reason [windowsInvocation] is: a test that opened a
  /// terminal per case would leave a row of them on the desk of whoever ran the
  /// suite, and from Windows this branch can be read but never run.
  static String macOSCommandLine(String command, String directory) =>
      'cd ${_shellQuoted(directory)} && $command';

  /// The little script a bare shell is started through, and the reason it has
  /// to exist.
  ///
  /// `do script` cannot start a shell. It opens a window, runs the *login*
  /// shell in it, and only then types the line it was given — so asking for
  /// bash while zsh is the login shell opened a zsh window and put bash in it.
  /// `exec` fixed the nesting, and 1.0.0.119 shipped it: only one shell is left
  /// afterwards. What it could not fix is the window having already opened as
  /// the wrong shell, which is the part that is visible, and is what "first zsh
  /// starts, then bash" describes. Windows has never had this because
  /// `ShellExecute` starts the program itself and nothing before it.
  ///
  /// `open -a Terminal <file>` was tried as the nearest thing macOS has to
  /// that, on the belief that the file becomes the window's own process. It
  /// takes a path rather than a command line, which is the whole reason for
  /// writing a script instead of passing one — the `cd` and the shell have to
  /// travel inside the file.
  ///
  /// **It does not, and this was measured** (item 34, which asked for a check
  /// rather than a change). A probe script run this way reported its
  /// ancestry as `Terminal → login → -zsh → the script`: Terminal starts the
  /// **login shell** whatever it is asked to open, and runs the file as a child
  /// of it. So the window is still zsh first and the shell that was asked for
  /// second — the symptom exactly — and `exit` drops back into zsh rather than
  /// closing the window.
  ///
  /// `exec` stays, and does what it can: this script is replaced by the shell
  /// rather than running under it, so there are two shells in the chain and not
  /// three. Making the window *be* the asked-for shell needs something else
  /// again — a Terminal settings profile, or the user's own Terminal
  /// preference — and that is a decision, not a fix.
  static String macOSLauncherScript(String command, String directory) =>
      '#!/bin/sh\n'
      'cd ${_shellQuoted(directory)} || exit 1\n'
      'exec ${command.trim()}\n';

  /// Runs a typed command line on macOS: a bare shell gets a window of its own,
  /// everything else is typed into one.
  static Future<String?> _macOSCommand(String command, String directory) async {
    if (!_isBareShell(command)) {
      return _macOSRun(macOSCommandLine(command, directory));
    }

    // Named by the clock rather than a fixed name, so two windows opened
    // together cannot overwrite each other's script mid-launch.
    final file = File(
      p.join(
        Directory.systemTemp.path,
        'xverb-shell-${DateTime.now().microsecondsSinceEpoch}.sh',
      ),
    );
    await file.writeAsString(macOSLauncherScript(command, directory));
    await Process.run('chmod', ['700', file.path]);

    final result = await Process.run('open', ['-a', 'Terminal', file.path]);
    if (result.exitCode != 0) {
      // Nothing is going to read it now, so it does not get to stay.
      await file.delete().catchError((_) => file);
      return tr('Terminal would not start it: {error}',
          {'error': '${result.stderr}'.trim()});
    }

    // Not deleted on the way out: `open` returns before Terminal has read the
    // file, and removing it here is a race with the window that is opening.
    // It is a few dozen bytes in the system's own temporary directory.
    return null;
  }

  static Future<String?> _macOSRun(String command) async {
    final applescript =
        'tell application "Terminal"\n'
        '  activate\n'
        '  do script "${_appleScriptQuoted(command)}"\n'
        'end tell';

    final result = await Process.run('osascript', ['-e', applescript]);
    return result.exitCode == 0
        ? null
        : tr('Terminal would not start it: {error}',
            {'error': '${result.stderr}'.trim()});
  }

  /// Backslashes first, then quotes: the other order escapes the escapes.
  static String _appleScriptQuoted(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  /// The terminals worth trying, and how each takes a command.
  ///
  /// The working directory is not passed as a flag — every one of these spells
  /// it differently — but through the child process, which they all inherit.
  static const List<(String, List<String>)> _linuxTerminals = [
    ('x-terminal-emulator', ['-e']),
    ('gnome-terminal', ['--']),
    ('konsole', ['-e']),
    ('xfce4-terminal', ['-x']),
    ('alacritty', ['-e']),
    ('kitty', <String>[]),
    ('xterm', ['-e']),
  ];

  static String _loginShell() =>
      File('/bin/bash').existsSync() ? '/bin/bash' : '/bin/sh';

  static Future<String?> _linux(String script, String directory) =>
      _linuxRun('${_shellQuoted(script)}; exec ${_loginShell()}', directory);

  /// The line a Linux terminal is asked to run for a **typed** command.
  ///
  /// The emulator closes its window the moment the command it was given ends,
  /// so an ordinary command hands over to a login shell afterwards and the
  /// output stays readable. A bare shell needs no such tail: it *is* the shell
  /// that stays, and `exec` puts it in place of the one that started it rather
  /// than underneath it.
  static String linuxCommandLine(String command) => _isBareShell(command)
      ? 'exec ${command.trim()}'
      : '$command; exec ${_loginShell()}';

  /// The first terminal emulator that is actually installed, told to run a
  /// shell command and stay.
  static Future<String?> _linuxRun(String command, String directory) async {
    final shell = _loginShell();

    for (final (terminal, prefix) in _linuxTerminals) {
      if (_which(terminal) == null) continue;
      await Process.start(
        terminal,
        [...prefix, shell, '-c', command],
        workingDirectory: directory,
        mode: ProcessStartMode.detached,
      );
      return null;
    }
    return 'No terminal emulator was found to run this in.';
  }

  static String? _which(String name) {
    final pathValue = Platform.environment['PATH'];
    if (pathValue == null) return null;
    for (final directory in pathValue.split(':')) {
      if (directory.isEmpty) continue;
      final candidate = File(p.join(directory, name));
      if (candidate.existsSync()) return candidate.path;
    }
    return null;
  }
}
