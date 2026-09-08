import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

import '../core/platform/file_transfer_channel.dart';
import '../core/vfs/vfs_path.dart';

/// What is being dragged, whoever started it.
class DragPayload {
  const DragPayload({
    required this.sources,
    required this.fromHere,
    required this.allowsMove,
  });

  final List<VfsPath> sources;

  /// Started in this window. It changes two things: a move is ours to perform
  /// rather than the other application's, and the panel it came from knows to
  /// refuse a drop back into itself.
  final bool fromHere;

  /// Whether a move is on offer at all — false for a drag out of somewhere
  /// that cannot give its files up.
  final bool allowsMove;

  bool get isEmpty => sources.isEmpty;
}

/// What a zone says it would do with the drag hanging over it.
class DropProposal {
  const DropProposal({required this.target, required this.intent, this.row});

  /// The folder that would receive the files.
  final VfsPath target;

  final TransferIntent intent;

  /// The row being pointed at, for the panel to light up. Null when the drop
  /// would land in the folder the panel is already showing.
  final int? row;
}

/// Somewhere on the screen that takes dropped files.
abstract class DropZone {
  /// Where it is now, in global logical pixels; null while it is off screen.
  Rect? get dropBounds;

  /// What this zone would do with [payload] dropped at [globalPosition], or
  /// null when it will not take it.
  DropProposal? proposeDrop(
    Offset globalPosition,
    DragPayload payload,
    DragKeys keys,
  );

  /// Carries it out. The zone owns the dialogs this puts up.
  Future<void> performDrop(DropProposal proposal, DragPayload payload);

  /// The drag has left, one way or another: gone to another zone, dropped, or
  /// abandoned. Anything the zone started while it hovered — a scroll that
  /// walks the listing at the edge — stops here.
  void dropHoverEnded();
}

/// The one thing listening to the desktop's drags, and the one thing that knows
/// which of our zones a pointer is over.
///
/// **The desktop's drag loop is the only drag loop.** Files dragged from one
/// panel to the other do not take a private path: they go out to the platform
/// as a real drag and come straight back in through the same events Explorer's
/// and Finder's drags arrive on. So there is one set of rules to write, one
/// highlight to draw, and dropping on our own window is not a special case of
/// anything.
class DragSession extends ChangeNotifier {
  DragSession({FileTransferChannel? channel})
    : _channel = channel ?? FileTransferChannel.instance;

  final FileTransferChannel _channel;

  final List<DropZone> _zones = [];

  DragPayload? _payload;
  DropZone? _hovered;
  DropProposal? _proposal;

  /// Where the pointer was when the platform last told us, and what was held
  /// down with it. Kept so a zone that scrolls itself under a still pointer can
  /// ask again — see [refreshHover] — and so the chip that says what the drop
  /// would do has somewhere to sit.
  Offset? _pointer;
  DragKeys _keys = const DragKeys();

  /// What is over the window now, or null when nothing is.
  DragPayload? get payload => _payload;

  /// What would happen if it were let go now, or null when nothing would.
  DropProposal? get proposal => _proposal;

  /// True for the zone the pointer is over, so a panel can outline itself.
  bool isHovered(DropZone zone) => identical(_hovered, zone);

  /// Where the drag is, in global logical pixels, or null when none is over
  /// the window.
  Offset? get pointer => _pointer;

  /// Asks the hovered zone again, without the pointer having moved.
  ///
  /// A listing that scrolls itself while a drag rests near its edge is moving
  /// the rows *under* a still pointer: the row being pointed at changes, and
  /// nothing else in this file would ever hear about it.
  void refreshHover() {
    final zone = _hovered;
    final payload = _payload;
    final at = _pointer;
    if (zone == null || payload == null || at == null) return;
    final proposal = zone.proposeDrop(at, payload, _keys);
    if (proposal?.target != _proposal?.target ||
        proposal?.intent != _proposal?.intent ||
        proposal?.row != _proposal?.row) {
      _proposal = proposal;
      notifyListeners();
    }
  }

  /// Starts listening to the platform. Called once, from the screen that owns
  /// the panels.
  void start() {
    _channel.listen(onOver: _onOver, onLeave: _onLeave, onDrop: _onDrop);
  }

  void register(DropZone zone) => _zones.add(zone);

  void unregister(DropZone zone) {
    _zones.remove(zone);
    if (identical(_hovered, zone)) {
      _hovered = null;
      _proposal = null;
    }
  }

  /// Where our own drags come from: the panel hands over what is being dragged
  /// and this puts it in the desktop's hands.
  ///
  /// Returns when the user lets go, with what actually happened — which the
  /// panel needs in order to re-read the folder, and for nothing else: a move
  /// out of the window is carried out by whoever took the files.
  Future<TransferIntent?> dragOut({
    required List<VfsPath> sources,
    required List<String> nativePaths,
    required bool allowMove,
  }) async {
    if (nativePaths.isEmpty) return null;
    _payload = DragPayload(
      sources: sources,
      fromHere: true,
      allowsMove: allowMove,
    );
    notifyListeners();

    final TransferIntent? did;
    try {
      did = await _channel.startDrag(nativePaths, allowMove: allowMove);
    } finally {
      _clearHover();
      _payload = null;
      notifyListeners();
    }

    return did;
  }

  Future<DragAnswer> _onOver(DragEvent event) async {
    final payload = _payload ??= DragPayload(
      sources: event.paths.map(VfsPath.local).toList(growable: false),
      fromHere: false,
      allowsMove: event.allowsMove,
    );

    _pointer = event.position;
    _keys = event.keys;

    final zone = _zoneAt(event.position);
    if (!identical(zone, _hovered)) {
      _hovered?.dropHoverEnded();
      _hovered = zone;
    }

    final proposal = zone?.proposeDrop(event.position, payload, event.keys);
    if (proposal?.target != _proposal?.target ||
        proposal?.intent != _proposal?.intent ||
        proposal?.row != _proposal?.row) {
      _proposal = proposal;
      notifyListeners();
    }
    return DragAnswer(proposal?.intent);
  }

  void _onLeave() {
    _clearHover();
    // A drag of our own is still running even while the pointer is outside the
    // window; one from elsewhere is over as far as we are concerned.
    if (_payload?.fromHere != true) _payload = null;
    notifyListeners();
  }

  void _onDrop(DragEvent event, TransferIntent intent) {
    final payload = _payload;
    final zone = _hovered;
    final proposal = _proposal;
    _clearHover();
    if (payload != null && zone != null && proposal != null) {
      // Not awaited: the platform is inside its own drop call and must be let
      // go of before a dialog can open over the window it is holding.
      zone.performDrop(proposal, payload);
    }
    if (payload?.fromHere != true) _payload = null;
    notifyListeners();
  }

  void _clearHover() {
    _hovered?.dropHoverEnded();
    _hovered = null;
    _proposal = null;
    _pointer = null;
  }

  /// The topmost zone under the pointer. Registration order is enough of a
  /// stacking order here: a panel is either under the pointer or it is not, and
  /// the two never overlap.
  DropZone? _zoneAt(Offset position) {
    for (final zone in _zones.reversed) {
      final bounds = zone.dropBounds;
      if (bounds != null && bounds.contains(position)) return zone;
    }
    return null;
  }

}

/// Copy or move — the question a drop asks, answered the way the desktop the
/// application is running on answers it.
///
/// **Each machine's own convention, not one of ours.** A hand that has dragged
/// files on this desktop for twenty years already knows what happens when it
/// holds a key down, and a file manager that invents a third rule is a file
/// manager that has to be watched. Windows: the same volume moves, another
/// volume copies, Ctrl forces a copy and Shift forces a move. macOS: the same
/// volume moves, another volume copies, Option forces a copy and Command
/// forces a move.
///
/// Null means this drop cannot happen at all, which is the cursor the user is
/// already looking at.
TransferIntent? dropIntentFor({
  required List<VfsPath> sources,
  required VfsPath target,
  required DragKeys keys,
  required bool allowsMove,
  required bool targetWritable,
}) {
  if (sources.isEmpty || !targetWritable) return null;

  // A folder cannot be dropped into itself, at any price.
  final workable =
      sources.where((path) => !path.contains(target)).toList(growable: false);
  if (workable.isEmpty) return null;

  final forcedCopy = Platform.isMacOS ? keys.alt : keys.control;
  final forcedMove = Platform.isMacOS ? keys.meta : keys.shift;

  final TransferIntent intent;
  if (!allowsMove || (forcedCopy && !forcedMove)) {
    intent = TransferIntent.copy;
  } else if (forcedMove && !forcedCopy) {
    intent = TransferIntent.move;
  } else {
    final together = workable.every((path) => _sameVolume(path, target));
    intent = together ? TransferIntent.move : TransferIntent.copy;
  }

  // Dropped back where it came from. As a move that is nothing at all — the
  // commonest slip of the hand there is, and it must not become an operation.
  // As a copy it is how a duplicate is made, and both desktops keep it: hold
  // the copy key over the folder a file is already in and you get a second
  // one, named around the collision.
  if (intent == TransferIntent.move &&
      workable.every((path) => path.parent == target)) {
    return null;
  }
  return intent;
}

/// Whether two locations sit on the same volume, which is what decides a
/// dragged file's fate when no key is held.
///
/// Two different file systems are never the same volume however their paths
/// read: a folder on a server and a folder on the disk have nothing in common
/// but the shape of the string.
bool _sameVolume(VfsPath a, VfsPath b) {
  if (a.scheme != b.scheme) return false;
  if (a.scheme != VfsPath.localScheme) {
    // Within one provider, the host is the volume: two paths on the same
    // server move, two servers copy.
    return a.uri.authority == b.uri.authority;
  }
  if (Platform.isWindows) {
    return a.root == b.root;
  }
  // On macOS everything is under `/`, and everything that is *not* the boot
  // volume is under `/Volumes/<name>`. Two paths are together when they are
  // both on the boot volume or both under the same mounted one.
  String volume(VfsPath path) {
    final segments = path.segments;
    if (segments.length >= 2 && segments.first == 'Volumes') {
      return '/Volumes/${segments[1]}';
    }
    return '/';
  }

  return volume(a) == volume(b);
}
