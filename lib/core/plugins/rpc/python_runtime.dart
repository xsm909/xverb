import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../i18n/i18n.dart';
import 'python_installer.dart';

/// Locates a Python interpreter and stages the bundled `xverb` SDK so
/// plugins can `import xverb` without any installation step.
class PythonRuntime {
  PythonRuntime._(this.executable, this.sdkPath, this.version);

  /// Absolute path or command name of the interpreter to spawn.
  final String executable;

  /// Directory added to `PYTHONPATH`, containing the `xverb` package.
  final String sdkPath;

  /// Reported interpreter version, e.g. `3.12.4`.
  final String version;

  /// Spawning a child process is only possible on desktop. On iOS and Android
  /// there is no interpreter to launch, so the plugin system stays dormant and
  /// the app runs with the built-in local provider only.
  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Files of the Python SDK, copied out of the app bundle on first run.
  static const List<String> _sdkAssets = [
    'xverb/__init__.py',
    'xverb/rpc.py',
    'xverb/plugin.py',
    'xverb/fs.py',
  ];

  static PythonRuntime? _cached;
  static String? _lastError;

  /// Why [detect] returned null, for display in the plugin manager.
  static String? get lastError => _lastError;

  /// Resolves the runtime once per session. Returns null when no usable
  /// interpreter is present, which is a normal state, not a crash.
  static Future<PythonRuntime?> detect() async {
    if (_cached != null) return _cached;
    if (!isSupported) {
      _lastError = tr('Python plugins are not available on {platform}.',
          {'platform': Platform.operatingSystem});
      return null;
    }

    _rejected = null;
    final executable = await _findInterpreter();
    if (executable == null) {
      final floor = '${PythonInstaller.targetMajor}.'
          '${PythonInstaller.targetMinor}';
      _lastError = [
        ?_rejected,
        PythonInstaller.isSupported
            ? tr(
                'Plugins run on {version}, which this app '
                'installs for itself. Install it to enable Python plugins.',
                {'version': PythonInstaller.pinnedLabel},
              )
            : tr(
                'No pinned Python build is published for this machine. Set '
                'XVERB_PYTHON to a Python {version} or newer interpreter.',
                {'version': floor},
              ),
      ].join(' ');
      return null;
    }

    final version = await _versionOf(executable) ?? 'unknown';
    final sdkPath = await _stageSdk();
    _lastError = null;
    return _cached = PythonRuntime._(executable, sdkPath, version);
  }

  /// Environment for a plugin process: the SDK on `PYTHONPATH`, unbuffered
  /// output so RPC replies are not held back, and no `.pyc` clutter.
  Map<String, String> environmentFor(String pluginDirectory) {
    final existing = Platform.environment['PYTHONPATH'];
    final entries = [sdkPath, pluginDirectory, ?existing];
    return {
      'PYTHONPATH': entries.join(Platform.isWindows ? ';' : ':'),
      'PYTHONUNBUFFERED': '1',
      'PYTHONDONTWRITEBYTECODE': '1',
      'PYTHONIOENCODING': 'utf-8',
    };
  }

  /// An interpreter chosen by the user in settings, tried before anything else.
  static String? preferredPath;

  /// Forgets the detected runtime so the next [detect] looks again. Called
  /// after installing or choosing an interpreter.
  static void reset() {
    _cached = null;
    _lastError = null;
    _rejected = null;
  }

  /// Whether [version] is new enough to run plugins, which are written against
  /// one language version — see "Target Python version" in `docs/plugins.md`.
  static bool meetsFloor(String version) {
    final match = RegExp(r'^(\d+)\.(\d+)').firstMatch(version);
    if (match == null) return false;
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    if (major != PythonInstaller.targetMajor) {
      return major > PythonInstaller.targetMajor;
    }
    return minor >= PythonInstaller.targetMinor;
  }

  /// The interpreter to spawn.
  ///
  /// The managed build wins, and a Python found on PATH is not consulted at
  /// all. That is the rule, not an accident: when the machine's own `python3`
  /// was preferred, the same plugin ran on 3.9 on a stock Mac, 3.12 on Windows
  /// and 3.14 under Homebrew, and no plugin author can test against that.
  /// `XVERB_PYTHON` and the settings override stay as escape hatches, and
  /// they are held to the same floor so a too-old choice fails here rather
  /// than on syntax the interpreter cannot parse.
  static Future<String?> _findInterpreter() async {
    for (final explicit in [
      Platform.environment['XVERB_PYTHON'],
      preferredPath,
    ]) {
      if (explicit == null || explicit.isEmpty) continue;
      final version = await _versionOf(explicit);
      if (version == null) continue;
      if (!meetsFloor(version)) {
        _rejected = '$explicit is Python $version; '
            '${PythonInstaller.targetMajor}.${PythonInstaller.targetMinor} '
            'or newer is required.';
        continue;
      }
      return explicit;
    }

    final managed = await PythonInstaller.installed();
    if (managed != null) {
      final version = await _versionOf(managed);
      if (version != null && meetsFloor(version)) return managed;
    }

    return null;
  }

  /// Why an explicitly chosen interpreter was turned down, if one was.
  static String? _rejected;

  /// Runs `<executable> --version` and returns the version, or null if the
  /// command is missing or is not a Python at all.
  static Future<String?> _versionOf(String executable) async {
    try {
      final result = await Process.run(executable, ['--version']);
      if (result.exitCode != 0) return null;
      final output = '${result.stdout}${result.stderr}'.trim();
      final match = RegExp(r'Python (\d+)\.(\d+)\.?(\d*)').firstMatch(output);
      if (match == null) return null;
      return match.group(0)!.replaceFirst('Python ', '');
    } on ProcessException {
      return null;
    }
  }

  /// Copies the SDK from the app bundle into the support directory. Files are
  /// rewritten every launch so an app update always ships a matching SDK.
  static Future<String> _stageSdk() async {
    final support = await getApplicationSupportDirectory();
    final target = Directory(p.join(support.path, 'python-sdk'));
    await target.create(recursive: true);

    for (final asset in _sdkAssets) {
      final contents = await rootBundle.loadString('assets/python/$asset');
      final file = File(p.join(target.path, asset.replaceAll('/', p.separator)));
      await file.parent.create(recursive: true);
      await file.writeAsString(contents);
    }
    return target.path;
  }
}
