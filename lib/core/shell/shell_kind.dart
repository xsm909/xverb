import 'dart:io';

/// A shell the command line can run commands through.
enum ShellKind {
  /// Whatever the platform considers default: cmd, or `$SHELL`.
  system,
  cmd,
  powershell,
  gitBash,
  bash;

  String get label => switch (this) {
        ShellKind.system => 'System default',
        ShellKind.cmd => 'Command Prompt',
        ShellKind.powershell => 'PowerShell',
        ShellKind.gitBash => 'Git Bash',
        ShellKind.bash => 'Bash',
      };

  /// Shown as the prompt marker, so the active shell is never in doubt.
  String get sigil => switch (this) {
        ShellKind.cmd => '>',
        ShellKind.powershell => 'PS>',
        ShellKind.gitBash || ShellKind.bash => r'$',
        ShellKind.system => Platform.isWindows ? '>' : r'$',
      };
}

/// A resolved shell: the executable plus the arguments that make it run one
/// command and exit.
class ShellCommand {
  const ShellCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// Finds the shells actually installed and builds invocations for them.
class ShellResolver {
  const ShellResolver._();

  static final Map<ShellKind, String?> _cache = {};

  /// Shells present on this machine, in the order they should be offered.
  static List<ShellKind> available() {
    final kinds = <ShellKind>[ShellKind.system];
    for (final kind in ShellKind.values) {
      if (kind == ShellKind.system) continue;
      if (executableFor(kind) != null) kinds.add(kind);
    }
    return kinds;
  }

  /// Absolute path or command name for [kind], or null when it is not here.
  static String? executableFor(ShellKind kind) =>
      _cache.putIfAbsent(kind, () => _resolve(kind));

  static String? _resolve(ShellKind kind) {
    switch (kind) {
      case ShellKind.system:
        if (Platform.isWindows) return _which('cmd.exe');
        return Platform.environment['SHELL'] ?? '/bin/sh';

      case ShellKind.cmd:
        return Platform.isWindows ? _which('cmd.exe') : null;

      case ShellKind.powershell:
        // pwsh is PowerShell 7 and cross-platform; powershell.exe is 5.1.
        return _which('pwsh.exe') ??
            _which('pwsh') ??
            (Platform.isWindows ? _which('powershell.exe') : null);

      case ShellKind.gitBash:
        if (!Platform.isWindows) return null;
        for (final candidate in _gitBashCandidates()) {
          if (File(candidate).existsSync()) return candidate;
        }
        return null;

      case ShellKind.bash:
        if (Platform.isWindows) return null;
        for (final candidate in ['/bin/bash', '/usr/bin/bash']) {
          if (File(candidate).existsSync()) return candidate;
        }
        return null;
    }
  }

  /// Git for Windows ships bash beside git; the install location varies, and
  /// deriving it from `git.exe` covers the non-standard ones.
  static List<String> _gitBashCandidates() {
    final candidates = <String>[
      r'C:\Program Files\Git\bin\bash.exe',
      r'C:\Program Files (x86)\Git\bin\bash.exe',
    ];

    final git = _which('git.exe');
    if (git != null) {
      // `...\Git\cmd\git.exe` or `...\Git\mingw64\bin\git.exe`.
      final marker = RegExp(r'^(.*[\\/]Git)[\\/]', caseSensitive: false)
          .firstMatch(git);
      if (marker != null) {
        candidates.insert(0, '${marker.group(1)}\\bin\\bash.exe');
      }
    }

    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null) {
      candidates.add('$localAppData\\Programs\\Git\\bin\\bash.exe');
    }
    return candidates;
  }

  /// Looks a program up on PATH without running anything.
  static String? _which(String name) {
    final pathValue = Platform.environment['PATH'];
    if (pathValue == null) return null;

    final separator = Platform.isWindows ? ';' : ':';
    for (final directory in pathValue.split(separator)) {
      if (directory.isEmpty) continue;
      final candidate = File(
        '${directory.replaceAll(RegExp(r'[\\/]$'), '')}'
        '${Platform.isWindows ? '\\' : '/'}$name',
      );
      if (candidate.existsSync()) return candidate.path;
    }
    return null;
  }

  /// Builds the invocation that runs [command] and exits.
  static ShellCommand? invocation(ShellKind kind, String command) {
    final executable = executableFor(kind);
    if (executable == null) return null;

    final effective = kind == ShellKind.system
        ? (Platform.isWindows ? ShellKind.cmd : ShellKind.bash)
        : kind;

    return switch (effective) {
      ShellKind.cmd || ShellKind.system => ShellCommand(
          executable,
          ['/d', '/c', command],
        ),
      ShellKind.powershell => ShellCommand(
          executable,
          ['-NoProfile', '-NonInteractive', '-Command', command],
        ),
      // -l would load the profile and slow every command down; -c is enough.
      ShellKind.gitBash || ShellKind.bash => ShellCommand(
          executable,
          ['-c', command],
        ),
    };
  }
}
