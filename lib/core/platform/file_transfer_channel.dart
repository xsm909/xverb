import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Copying or moving — the one question every transfer answers, whether it was
/// asked with two keys, a dragged selection or a modifier held over a panel.
enum TransferIntent { copy, move }

/// Which modifiers the desktop saw while the drag was over us.
///
/// Read from the platform rather than from Flutter's own keyboard state: during
/// a native drag the pointer belongs to the drag loop and the window is not
/// getting key events, so `HardwareKeyboard` sits frozen on whatever was held
/// when the drag began.
class DragKeys {
  const DragKeys({
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  factory DragKeys.fromMap(Map<Object?, Object?> map) => DragKeys(
    control: map['control'] as bool? ?? false,
    shift: map['shift'] as bool? ?? false,
    alt: map['alt'] as bool? ?? false,
    meta: map['meta'] as bool? ?? false,
  );

  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;
}

/// What the desktop's clipboard is holding, when what it is holding is files.
class ClipboardFiles {
  const ClipboardFiles({
    required this.paths,
    required this.intent,
    required this.changeCount,
  });

  final List<String> paths;

  /// Windows writes the intent onto the clipboard beside the paths, in the
  /// `Preferred DropEffect` format Explorer invented for exactly this. macOS
  /// has no such thing — a cut there is remembered by whoever did the cutting —
  /// so from a foreign application this is always a copy.
  final TransferIntent intent;

  /// The desktop's own clipboard serial. It moves whenever anything is put on
  /// the clipboard by anyone, which is what lets [FileClipboard] tell its own
  /// cut from a copy somebody else made a second later.
  final int changeCount;
}

/// What Dart answers the platform while a drag hangs over the window.
class DragAnswer {
  const DragAnswer(this.intent);

  const DragAnswer.refused() : intent = null;

  /// Null when nothing here will take it, which is the cursor the user sees.
  final TransferIntent? intent;

  String get wireName => switch (intent) {
    TransferIntent.copy => 'copy',
    TransferIntent.move => 'move',
    null => 'none',
  };
}

/// Everything the platform can tell us about a drag that is over the window.
class DragEvent {
  const DragEvent({
    required this.position,
    required this.paths,
    required this.keys,
    required this.allowsMove,
  });

  factory DragEvent.fromMap(Map<Object?, Object?> map) => DragEvent(
    position: Offset(
      (map['x'] as num?)?.toDouble() ?? 0,
      (map['y'] as num?)?.toDouble() ?? 0,
    ),
    paths: (map['paths'] as List<Object?>? ?? const [])
        .whereType<String>()
        .toList(growable: false),
    keys: DragKeys.fromMap((map['keys'] as Map<Object?, Object?>?) ?? const {}),
    allowsMove: map['allowsMove'] as bool? ?? true,
  );

  /// Logical pixels, in the same space `RenderBox.localToGlobal` speaks — the
  /// native half divides by the window's scale factor so nothing above this
  /// has to know what a physical pixel is.
  final Offset position;

  /// The files being dragged, as the desktop names them.
  final List<String> paths;

  final DragKeys keys;

  /// Whether the source will let this be a move at all. A drag out of a
  /// read-only place — a disc, a search result window — offers copy and
  /// nothing else, and honouring that is the difference between a refusal the
  /// user sees now and one they read after the files have gone.
  final bool allowsMove;
}

/// The runner's own drag-and-drop and file-clipboard channel.
///
/// **The desktop does the dragging; this only asks it to.** No package, no
/// Rust toolchain in the build: `IDropTarget` and `SHDoDragDrop` on Windows,
/// `NSDraggingDestination` and `beginDraggingSession` on macOS, reached through
/// the same kind of method channel the audio and shell halves already use.
///
/// One rule runs through all of it and is worth stating once: **a move is
/// performed by us, never by the other application.** When Explorer or Finder
/// hands us files with a move in mind, the answer sent back is always *copy*,
/// and the deletion of the originals is done here after the copy has arrived —
/// because a target that says "move" hands the source permission to delete
/// files we have not finished reading. What that costs is nothing; what it buys
/// is that a failed transfer cannot take the only copy with it.
class FileTransferChannel {
  FileTransferChannel._();

  static final FileTransferChannel instance = FileTransferChannel._();

  static const MethodChannel _channel = MethodChannel('xverb/transfer');

  /// The platforms whose runner carries the native half. Elsewhere the keys
  /// still copy and paste *inside* the application — the clipboard is ours,
  /// the desktop simply never hears about it.
  ///
  /// Saying so is only half of it: the ping below is what actually decides,
  /// because a platform can be on this list and still be a build whose runner
  /// does not answer.
  static bool get isAvailable =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Whether the other end has ever answered. Null until it has been asked.
  ///
  /// **A channel nobody is listening on does not fail; it says nothing.** A
  /// build whose runner was not given this half — a harness, an older binary,
  /// a platform still to be written — leaves every call waiting for a reply
  /// that is not coming, and the key the user pressed simply never happens. So
  /// the first question is asked with a stopwatch on it, and a platform that
  /// misses it is not asked again.
  bool? _alive;

  static const Duration _patience = Duration(milliseconds: 400);

  Future<bool> get _reachable async {
    if (!isAvailable) return false;
    final known = _alive;
    if (known != null) return known;
    try {
      await _channel.invokeMethod<void>('ping').timeout(_patience);
      return _alive = true;
    } on Object {
      return _alive = false;
    }
  }

  /// Called for every drag that crosses the window. Set by the drag session,
  /// which is the only thing that should be listening.
  void listen({
    required Future<DragAnswer> Function(DragEvent event) onOver,
    required void Function() onLeave,
    required void Function(DragEvent event, TransferIntent intent) onDrop,
  }) {
    if (!isAvailable) return;
    _channel.setMethodCallHandler((call) async {
      final arguments = (call.arguments as Map<Object?, Object?>?) ?? const {};
      switch (call.method) {
        case 'dragOver':
          final answer = await onOver(DragEvent.fromMap(arguments));
          return answer.wireName;
        case 'dragLeave':
          onLeave();
          return null;
        case 'drop':
          final event = DragEvent.fromMap(arguments);
          final intent = arguments['intent'] == 'move'
              ? TransferIntent.move
              : TransferIntent.copy;
          onDrop(event, intent);
          // Always copy back down the wire, whatever we are about to do with
          // them. See the note on this class.
          return 'copy';
        default:
          return null;
      }
    });
  }

  /// Puts [paths] on the desktop's clipboard and returns the serial that came
  /// of it, or 0 where there is no native half to put them on.
  Future<int> writeClipboard(
    List<String> paths, {
    required TransferIntent intent,
  }) async {
    if (paths.isEmpty || !await _reachable) return 0;
    try {
      final serial = await _channel.invokeMethod<int>('clipboardWrite', {
        'paths': paths,
        'move': intent == TransferIntent.move,
      });
      return serial ?? 0;
    } on Object {
      return 0;
    }
  }

  /// The files on the desktop's clipboard, or null when it holds none.
  Future<ClipboardFiles?> readClipboard() async {
    if (!await _reachable) return null;
    try {
      final answer = await _channel.invokeMethod<Map<Object?, Object?>>(
        'clipboardRead',
      );
      if (answer == null) return null;
      final paths = (answer['paths'] as List<Object?>? ?? const [])
          .whereType<String>()
          .toList(growable: false);
      if (paths.isEmpty) return null;
      return ClipboardFiles(
        paths: paths,
        intent: answer['move'] == true
            ? TransferIntent.move
            : TransferIntent.copy,
        changeCount: (answer['changeCount'] as num?)?.toInt() ?? 0,
      );
    } on Object {
      return null;
    }
  }

  /// The clipboard's serial on its own, without reading what is on it.
  Future<int> clipboardSerial() async {
    if (!await _reachable) return 0;
    try {
      return await _channel.invokeMethod<int>('clipboardSerial') ?? 0;
    } on Object {
      return 0;
    }
  }

  /// Hands [paths] to the desktop's own drag loop and waits for it to end.
  ///
  /// Returns what the drop actually did, or null when nothing took them. The
  /// call does not come back until the user lets go: on both platforms this is
  /// a modal loop that pumps the window's messages, so the application goes on
  /// drawing while it runs, but nothing else on this channel will be answered.
  Future<TransferIntent?> startDrag(
    List<String> paths, {
    required bool allowMove,
  }) async {
    // No stopwatch on this one, and it is the only one without: the call comes
    // back when the user lets go of the mouse, which may be a minute from now.
    // What it leans on instead is the ping above — a platform that has never
    // answered anything is not handed a drag to run.
    if (paths.isEmpty || !await _reachable) return null;
    try {
      final answer = await _channel.invokeMethod<String>('startDrag', {
        'paths': paths,
        'allowMove': allowMove,
      });
      return switch (answer) {
        'move' => TransferIntent.move,
        'copy' => TransferIntent.copy,
        _ => null,
      };
    } on Object {
      return null;
    }
  }
}
