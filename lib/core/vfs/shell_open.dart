import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import '../i18n/i18n.dart';
import 'package:path/path.dart' as p;

/// Hands a file to whatever the desktop has associated with it.
///
/// This is what Enter does, and it is deliberately different from F3: Enter
/// leaves the app, F3 stays inside it and asks a viewer plugin.
class ShellOpen {
  const ShellOpen._();

  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Opens [nativePath] with the default handler. Returns an error message on
  /// failure, or null when the shell took it.
  static Future<String?> open(String nativePath) async {
    if (!isSupported) return tr('Opening files is not supported here.');

    try {
      if (Platform.isWindows) return _windows(nativePath);

      final command = Platform.isMacOS ? 'open' : 'xdg-open';
      final result = await Process.run(command, [nativePath]);
      return result.exitCode == 0
          ? null
          : tr('No application is associated with this file.');
    } on Object catch (e) {
      return '$e';
    }
  }

  /// Opens [nativePath], and when nothing on the machine claims the type, asks
  /// the desktop *which* application to use.
  ///
  /// This is what Enter means: the action the desktop would take, and the
  /// desktop's own question when it has no answer. Falling back to a viewer of
  /// our own would be the application deciding it knows better — F3 is there for
  /// whoever wants that.
  ///
  /// Windows has the question built in as the `openas` verb: the same "How do you
  /// want to open this file?" that Explorer shows. macOS asks by itself, so
  /// nothing more is needed there. Linux has no chooser every desktop agrees on,
  /// so there the answer is still a message.
  static Future<String?> openAs(String nativePath) async {
    if (!isSupported) return tr('Opening files is not supported here.');

    try {
      if (Platform.isWindows) {
        // Asked before anything is started, rather than opening and retrying on
        // the refusal: a retry would have to open the file to find out, and for a
        // type that *is* claimed that means opening it twice.
        return hasAssociation(nativePath)
            ? _windows(nativePath)
            : _windows(nativePath, verb: 'openas');
      }
      return await open(nativePath);
    } on Object catch (e) {
      return '$e';
    }
  }

  /// Whether anything on this machine is registered to open [nativePath].
  ///
  /// `AssocQueryStringW` answers from the registry and starts nothing, which is
  /// what makes it usable both here and in a test. Off Windows there is no such
  /// question to ask, so this says yes and lets the attempt speak for itself.
  static bool hasAssociation(String nativePath) {
    if (!Platform.isWindows) return true;

    final extension = p.extension(nativePath);
    // No extension at all: the shell has nothing to look up, and `openas` is the
    // honest answer.
    if (extension.isEmpty) return false;

    try {
      final shlwapi = DynamicLibrary.open('shlwapi.dll');
      final query = shlwapi.lookupFunction<
          Int32 Function(Uint32, Uint32, Pointer<Utf16>, Pointer<Utf16>,
              Pointer<Utf16>, Pointer<Uint32>),
          int Function(int, int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
              Pointer<Uint32>)>('AssocQueryStringW');

      final association = extension.toNativeUtf16();
      final length = calloc<Uint32>()..value = 1024;
      final out = calloc<Uint16>(1024).cast<Utf16>();
      try {
        // ASSOCSTR_EXECUTABLE (2): which program would run. S_OK means one
        // would.
        //
        // ASSOCF_INIT_IGNOREUNKNOWN (0x400) is the whole point of the call.
        // Without it Windows answers for *everything*, because an unclaimed type
        // falls back to the Open-With shim — measured: a made-up extension came
        // back associated. With it, only a real association counts, which is the
        // question actually being asked.
        return query(0x400, 2, association, nullptr, out, length) == 0;
      } finally {
        calloc.free(association);
        calloc.free(length);
        calloc.free(out);
      }
    } on Object {
      // If the question cannot be asked, do not turn that into a refusal to open
      // the file.
      return true;
    }
  }

  /// Opens [nativePath] for editing rather than for viewing — F4.
  ///
  /// Not the same as [open]: Enter hands a `.log` to whatever claims that
  /// extension, which may be a log viewer, and F4 has to reach something that
  /// can change it. Every desktop has a way to say "edit this":
  ///
  /// | | |
  /// | --- | --- |
  /// | Windows | the shell's `edit` verb, falling back to Notepad |
  /// | macOS | `open -t`, the default text editor |
  /// | Linux | `$VISUAL`, `$EDITOR`, then `xdg-open` |
  ///
  /// The core ships no editor of its own and is not going to: editing is not
  /// file management, and every machine already has one.
  static Future<String?> edit(String nativePath) async {
    if (!isSupported) return tr('Editing files is not supported here.');

    try {
      if (Platform.isWindows) {
        // Plenty of types have no `edit` verb registered; Notepad opens
        // anything, which is what Total Commander's default does too.
        return _windows(nativePath, verb: 'edit') == null
            ? null
            : await _run('notepad', [nativePath]);
      }
      if (Platform.isMacOS) return await _run('open', ['-t', nativePath]);

      final editor = Platform.environment['VISUAL'] ??
          Platform.environment['EDITOR'];
      if (editor != null && editor.trim().isNotEmpty) {
        return await _run(editor.trim(), [nativePath]);
      }
      return await _run('xdg-open', [nativePath]);
    } on Object catch (e) {
      return '$e';
    }
  }

  /// Starts [file] with [parameters], from [directory], through the shell.
  ///
  /// The directory is the reason this exists: `ShellExecuteW` takes one, and a
  /// program started without it inherits *this* application's working directory.
  /// For a script that is the difference between running where it lives and
  /// running somewhere it has never heard of.
  ///
  /// Windows only. Returns a message on failure, or null when the shell took it.
  static String? execute({
    required String file,
    String? parameters,
    String? directory,
  }) {
    if (!Platform.isWindows) {
      return tr('Starting a program this way is only supported on Windows.');
    }
    return _windows(file, parameters: parameters, directory: directory);
  }


  static Future<String?> _run(String command, List<String> arguments) async {
    final result = await Process.run(command, arguments);
    return result.exitCode == 0
        ? null
        : tr('Could not open an editor for this file.');
  }

  /// `ShellExecuteW` rather than `cmd /c start`, which would flash a console
  /// window on every open.
  /// `SE_ERR_NOASSOC`: nothing on this machine claims the file type.
  static const int _noAssociation = 31;

  static String? _windows(
    String nativePath, {
    String verb = 'open',
    String? parameters,
    String? directory,
  }) =>
      _messageFor(_execute(
        nativePath,
        verb: verb,
        parameters: parameters,
        directory: directory,
      ));

  /// The shell's own answer: above 32 it accepted the request, and at or below
  /// that it is one of the legacy WinExec error values.
  static String? _messageFor(int code) {
    if (code > 32) return null;
    return switch (code) {
      2 => tr('File not found.'),
      3 => tr('Path not found.'),
      5 => tr('Access denied.'),
      _noAssociation => tr('No application is associated with this file type.'),
      _ => tr('The shell refused to open it (code {code}).', {'code': code}),
    };
  }

  static int _execute(
    String nativePath, {
    String verb = 'open',
    String? parameters,
    String? directory,
  }) {
    final shell32 = DynamicLibrary.open('shell32.dll');
    final shellExecute = shell32.lookupFunction<
        IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
            Pointer<Utf16>, Int32),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
            Pointer<Utf16>, int)>('ShellExecuteW');

    final operation = verb.toNativeUtf16();
    final file = nativePath.toNativeUtf16();
    final arguments = parameters?.toNativeUtf16() ?? nullptr;
    final workingDirectory = directory?.toNativeUtf16() ?? nullptr;
    try {
      // SW_SHOWNORMAL. The raw code is returned so that the caller can tell
      // "nothing claims this type" from the failures worth reporting.
      return shellExecute(0, operation, file, arguments, workingDirectory, 1);
    } finally {
      calloc.free(operation);
      calloc.free(file);
      if (arguments != nullptr) calloc.free(arguments);
      if (workingDirectory != nullptr) calloc.free(workingDirectory);
    }
  }
}
