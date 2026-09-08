import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../i18n/i18n.dart';
import '../plugin_manifest.dart';
import 'json_rpc.dart';
import 'python_runtime.dart';

/// What a plugin reports back from `initialize`.
class PluginHandshake {
  const PluginHandshake({
    required this.apiVersion,
    required this.schemes,
    required this.commands,
    required this.viewers,
    this.views = const [],
    this.describers = const [],
  });

  factory PluginHandshake.fromJson(Map<String, dynamic> json) =>
      PluginHandshake(
        apiVersion: (json['apiVersion'] as num?)?.toInt() ?? 0,
        schemes: [
          for (final scheme in (json['schemes'] as List?) ?? const [])
            if (SchemeSpec.parse(scheme).scheme.isNotEmpty)
              SchemeSpec.parse(scheme),
        ],
        commands: (json['commands'] as List?)
                ?.map((e) => PluginCommandSpec.fromJson(
                    Map<String, dynamic>.from(e as Map)))
                .toList() ??
            const [],
        viewers: (json['viewers'] as List?)
                ?.map((e) =>
                    ViewerSpec.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            const [],
        views: (json['views'] as List?)
                ?.map(
                    (e) => ViewSpec.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            const [],
        describers: (json['describers'] as List?)
                ?.map((e) => DescriberSpec.fromJson(
                    Map<String, dynamic>.from(e as Map)))
                .toList() ??
            const [],
      );

  final int apiVersion;

  /// What the running plugin actually serves, and what each of them can do.
  /// Reported as bare names by a plugin written before schemes had anything to
  /// say about themselves — see [SchemeSpec].
  final List<SchemeSpec> schemes;
  final List<PluginCommandSpec> commands;
  final List<ViewerSpec> viewers;

  /// Views the plugin registered at runtime. Where each one appears still comes
  /// from the manifest — see the registry.
  final List<ViewSpec> views;

  /// Describers the plugin registered at runtime.
  final List<DescriberSpec> describers;
}

/// A message a plugin sent to the host log.
class PluginLogRecord {
  const PluginLogRecord(this.pluginId, this.level, this.message);

  final String pluginId;

  /// One of `debug`, `info`, `warning`, `error`.
  final String level;
  final String message;

  @override
  String toString() => '[$pluginId] $level: $message';
}

/// Runs one Python plugin in its own process and talks JSON-RPC over stdio.
///
/// Out-of-process is deliberate: a plugin that crashes, hangs or leaks takes
/// nothing with it, and no CPython has to be linked into the Flutter binary.
class PythonPluginHost {
  PythonPluginHost({
    required this.manifest,
    required this.runtime,
    this.onLog,
    this.onRead,
    this.onList,
    this.onStat,
    this.onViewUpdate,
  });

  final PluginManifest manifest;
  final PythonRuntime runtime;
  final void Function(PluginLogRecord record)? onLog;

  /// Reads a byte range from any registered file system on the plugin's behalf.
  /// This is how a viewer plugin can open a file that lives on a *different*
  /// plugin's transport without knowing anything about it.
  final Future<Map<String, Object?>> Function(
    String url,
    int offset,
    int length,
  )? onRead;

  /// Lists a directory through the host, on any transport. Reading was never
  /// enough for a view that has to walk a tree rather than open one file.
  final Future<Map<String, Object?>> Function(String url)? onList;

  /// One entry, or null when nothing is there.
  final Future<Map<String, Object?>?> Function(String url)? onStat;

  /// A view redrew itself between calls. The host routes it to whoever is
  /// holding that session, and drops it if nobody is.
  final void Function(String viewId, String session, Map<String, dynamic> body)?
      onViewUpdate;

  Process? _process;
  JsonRpcChannel? _channel;
  final _exited = Completer<int>();

  /// How long a plugin has to answer before the call is abandoned. Generous,
  /// because a network provider may legitimately be slow.
  static const Duration callTimeout = Duration(seconds: 60);

  bool get isRunning => _process != null && !_exited.isCompleted;

  JsonRpcChannel get channel {
    final channel = _channel;
    if (channel == null) {
      throw StateError('Plugin "${manifest.id}" is not running');
    }
    return channel;
  }

  /// Exit code of the plugin process once it stops.
  Future<int> get exitCode => _exited.future;

  /// Spawns the interpreter and performs the `initialize` handshake.
  ///
  /// [settings] is what the plugin declared merged with what the user changed;
  /// it arrives in the handshake so a plugin is configured before it registers
  /// anything, rather than starting one way and being corrected afterwards.
  Future<PluginHandshake> start({
    Map<String, Object?> settings = const {},
  }) async {
    if (_process != null) {
      throw StateError('Plugin "${manifest.id}" is already running');
    }

    final process = await Process.start(
      runtime.executable,
      ['-u', manifest.entryPath],
      workingDirectory: manifest.directory,
      environment: runtime.environmentFor(manifest.directory),
      runInShell: false,
    );
    _process = process;

    unawaited(process.exitCode.then((code) {
      if (!_exited.isCompleted) _exited.complete(code);
      _channel?.close();
    }));

    // stderr is the plugin's free-form log; stdout is reserved for RPC.
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      onLog?.call(PluginLogRecord(manifest.id, 'stderr', line));
    });

    _channel = JsonRpcChannel(
      incoming: process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
      send: (line) => process.stdin.writeln(line),
      onError: (error) =>
          onLog?.call(PluginLogRecord(manifest.id, 'error', '$error')),
    );

    _registerHostMethods(_channel!);

    final result = await _channel!.call(
      'initialize',
      params: {
        'apiVersion': kPluginApiVersion,
        'pluginId': manifest.id,
        'pluginDirectory': manifest.directory,
        'platform': PluginManifest.currentPlatformName(),
        // What language to speak in. Sent at the handshake because a plugin
        // decides what it contributes here — a command's title is registered
        // now — and because it reads its own catalogue, which the host cannot
        // do for a sentence it has never seen.
        'language': activeLocalisation.code,
        'settings': settings,
      },
      timeout: const Duration(seconds: 20),
    );

    return PluginHandshake.fromJson(
      result is Map ? Map<String, dynamic>.from(result) : const {},
    );
  }

  /// Asks the plugin to shut down, then kills it if it does not comply.
  ///
  /// **[patience] is how long each half of that is given.** Three seconds is
  /// right when one plugin is being disabled or replaced and the application
  /// goes on running: a plugin that is writing something out should be allowed
  /// to finish. It is wrong on the way out of the application, where the same
  /// three seconds are three seconds of somebody waiting for a window to go —
  /// so [PluginRegistry.shutdown] asks for much less there, and kills what has
  /// not gone by then.
  Future<void> stop({Duration patience = const Duration(seconds: 3)}) async {
    final process = _process;
    if (process == null) return;

    try {
      await _channel?.call('shutdown', timeout: patience);
    } on Object {
      // A plugin that cannot answer shutdown is exactly the case kill covers.
    }

    await _channel?.close();
    process.kill();
    await _exited.future.timeout(
      patience,
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    _process = null;
    _channel = null;
  }

  /// Methods the plugin may call back into.
  ///
  /// Everything here goes through the same file system registry the panels
  /// use, so a plugin asking the host for a directory gets one from whatever
  /// transport owns the URL — including another plugin's. Nothing here reaches
  /// into the application itself: there is no method that moves a panel or
  /// deletes a file, and that is on purpose. Those are *asked* for, as actions
  /// the host carries out where it can see what it is doing.
  void _registerHostMethods(JsonRpcChannel channel) {
    channel.on('host.log', (params) async {
      onLog?.call(PluginLogRecord(
        manifest.id,
        params['level'] as String? ?? 'info',
        params['message']?.toString() ?? '',
      ));
      return null;
    });

    channel.on('host.apiVersion', (_) async => kPluginApiVersion);

    channel.on('host.read', (params) async {
      final reader = onRead;
      if (reader == null) {
        throw StateError('This host does not provide file access');
      }
      return reader(
        params['url'] as String,
        (params['offset'] as num?)?.toInt() ?? 0,
        (params['length'] as num?)?.toInt() ?? 65536,
      );
    });

    channel.on('host.list', (params) async {
      final lister = onList;
      if (lister == null) {
        throw StateError('This host does not provide file access');
      }
      return lister(params['url'] as String);
    });

    channel.on('host.stat', (params) async {
      final stat = onStat;
      if (stat == null) {
        throw StateError('This host does not provide file access');
      }
      return stat(params['url'] as String);
    });

    channel.on('host.viewUpdate', (params) async {
      onViewUpdate?.call(
        params['viewId'] as String? ?? '',
        params['session'] as String? ?? '',
        Map<String, dynamic>.from(params),
      );
      return null;
    });
  }
}
