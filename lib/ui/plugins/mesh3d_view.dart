import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/viewer.dart';
import '../widgets/context_menu.dart';
import '../widgets/hint.dart';
import '../widgets/viewport_chrome.dart';

/// How a model is drawn, and what is drawn over it.
///
/// Not a renderer setting but a way of looking: shaded is what a model is,
/// wireframe is where its triangles are, and unlit is its picture with the
/// light taken off — which is the only way to see a texture as it was painted
/// rather than as it happens to be lit.
enum MeshLook {
  shaded,
  wire,
  unlit;

  String get label => switch (this) {
        MeshLook.shaded => 'Shaded',
        MeshLook.wire => 'Wireframe',
        MeshLook.unlit => 'Unlit',
      };

  IconData get icon => switch (this) {
        MeshLook.shaded => Icons.view_in_ar_outlined,
        MeshLook.wire => Icons.grid_3x3,
        MeshLook.unlit => Icons.wb_sunny_outlined,
      };

  /// The letter that picks it, in the menu and on its own.
  String get accelerator => switch (this) {
        MeshLook.shaded => 's',
        MeshLook.wire => 'w',
        MeshLook.unlit => 'u',
      };
}

/// Triangles a plugin sent, drawn.
///
/// No 3D engine and no dependency: `Canvas.drawVertices` takes a flat array of
/// screen positions and a colour each, so the camera, the lighting and the
/// order to draw in are all arithmetic done here. That is enough for a preview
/// of the size these files are — twenty thousand triangles — and it works
/// identically on every platform the app runs on, which no plugin-based
/// renderer would.
///
/// What it does not have is a depth buffer. Triangles are sorted back to front
/// and drawn in that order, which is right for everything except geometry that
/// interpenetrates itself. That is the price of the trade, and it is visible
/// on some models; a preview is still what this is.
class Mesh3dView extends StatefulWidget {
  const Mesh3dView({
    super.key,
    required this.content,
    this.hasKeyboard = true,
  });

  final ViewerContent content;

  /// Whether this is the reading the keys belong to. A split page has two.
  final bool hasKeyboard;

  @override
  State<Mesh3dView> createState() => _Mesh3dViewState();
}

class _Mesh3dViewState extends State<Mesh3dView>
    with SingleTickerProviderStateMixin {
  late _Scene _scene = _Scene.of(widget.content.meshes);

  /// Made here rather than at the first play. A model with no animation in it
  /// never plays, and a ticker made lazily is then made by `dispose` itself —
  /// which asks the tree for something at the one moment the tree will not
  /// answer.
  late final Ticker _ticker;

  /// Where in the clip we are, in frames, kept fractional so the slider and
  /// the clock agree at any speed.
  double _frame = 0;
  int _clip = 0;
  bool _playing = false;
  Duration _lastTick = Duration.zero;

  /// Skinned positions and normals, rebuilt when the frame changes and reused
  /// when only the camera moves — turning a model must not re-skin it.
  List<Float32List>? _posed;
  List<Float32List>? _posedNormals;

  /// Where the bones are this frame. Posed by the same arithmetic as a vertex
  /// with one bone pulling on it at full weight, which is what a bone is.
  List<Float32List>? _posedBones;
  int _posedFrame = -1;
  int _posedClip = -1;

  /// Where the camera is, as angles about the model rather than a position:
  /// what a preview needs is to be turned, not to be flown through.
  double _yaw = 0.6;
  double _pitch = 0.35;
  double _zoom = 1;
  Offset _pan = Offset.zero;

  double _lastScale = 1;
  Offset _lastFocus = Offset.zero;
  int _pointers = 0;

  /// What the clip menu opens from when it is opened from the transport.
  final GlobalKey _clipAnchor = GlobalKey();

  /// How it is being looked at, and whether the skeleton is drawn over it.
  MeshLook _look = MeshLook.shaded;
  bool _skeleton = false;

  /// **Taken, not asked for.** A viewer is not a route, so it opens inside the
  /// scope the panel F3 was pressed in and that panel keeps the keyboard;
  /// `autofocus` lands nowhere. The node canvas learnt this the hard way and
  /// answered no keys at all until something had been clicked.
  final FocusNode _keys = FocusNode(debugLabel: 'model');

  /// The pictures, decoded once. A model draws in its material colours until
  /// they arrive, which is a frame or two and is what it drew before textures
  /// existed at all — better than an empty window while a PNG is unpacked.
  List<ui.Image?> _images = const [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _decode();
    _takeKeyboard();
    if (_clips.isNotEmpty) _play();
  }

  void _takeKeyboard() {
    if (!widget.hasKeyboard) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.hasKeyboard && !_keys.hasFocus) {
        _keys.requestFocus();
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    for (final look in MeshLook.values) {
      if (event.character?.toLowerCase() == look.accelerator) {
        setState(() => _look = look);
        return KeyEventResult.handled;
      }
    }
    if (event.character?.toLowerCase() == 'b') {
      if (!_hasSkeleton) return KeyEventResult.ignored;
      setState(() => _skeleton = !_skeleton);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space && _clips.isNotEmpty) {
      _playing ? _pause() : _play();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Whether anything here has a skeleton to draw.
  bool get _hasSkeleton =>
      widget.content.meshes.any((mesh) => mesh.boneCount > 0);

  @override
  void didUpdateWidget(Mesh3dView old) {
    super.didUpdateWidget(old);
    if (!identical(old.content, widget.content)) {
      _scene = _Scene.of(widget.content.meshes);
      _frame = 0;
      _clip = 0;
      _posedFrame = -1;
      _decode();
      _reset();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _keys.dispose();
    _forget();
    super.dispose();
  }

  void _forget() {
    for (final image in _images) {
      image?.dispose();
    }
    _images = const [];
  }

  Future<void> _decode() async {
    _forget();
    final source = widget.content.images;
    if (source.isEmpty) return;
    final decoded = List<ui.Image?>.filled(source.length, null);
    for (var i = 0; i < source.length; i++) {
      try {
        final codec = await ui.instantiateImageCodec(source[i]);
        decoded[i] = (await codec.getNextFrame()).image;
        codec.dispose();
      } catch (_) {
        // A picture that will not decode is a picture the model does without.
        decoded[i] = null;
      }
    }
    if (!mounted) {
      for (final image in decoded) {
        image?.dispose();
      }
      return;
    }
    setState(() => _images = decoded);
  }

  List<MeshClip> get _clips =>
      [for (final clip in widget.content.clips) if (!clip.isEmpty) clip];

  MeshClip? get _current =>
      _clips.isEmpty ? null : _clips[_clip.clamp(0, _clips.length - 1)];

  void _play() {
    if (_clips.isEmpty) return;
    setState(() => _playing = true);
    _lastTick = Duration.zero;
    _ticker.start();
  }

  void _pause() {
    _ticker.stop();
    setState(() => _playing = false);
  }

  void _onTick(Duration elapsed) {
    final clip = _current;
    if (clip == null) return;
    final delta = _lastTick == Duration.zero
        ? Duration.zero
        : elapsed - _lastTick;
    _lastTick = elapsed;
    if (delta == Duration.zero) return;

    setState(() {
      _frame += delta.inMicroseconds / 1e6 * clip.fps;
      // Round and round: a preview of a walk cycle wants to keep walking.
      if (clip.frames > 1) _frame %= clip.frames;
    });
  }

  /// Applies the pose to the vertices, once per frame rather than per repaint.
  void _pose() {
    final clip = _current;
    final frame = _frame.floor();
    if (clip == null) {
      _posed = null;
      _posedNormals = null;
      _posedBones = null;
      return;
    }
    if (_posedFrame == frame && _posedClip == _clip && _posed != null) return;

    final positions = <Float32List>[];
    final normals = <Float32List>[];
    final bones = <Float32List>[];
    for (var m = 0; m < widget.content.meshes.length; m++) {
      final mesh = widget.content.meshes[m];
      final track = m < clip.tracks.length ? clip.tracks[m] : Float32List(0);
      bones.add(_poseBones(mesh, track, frame, clip.frames));
      if (!mesh.isSkinned || track.isEmpty) {
        positions.add(mesh.positions);
        normals.add(mesh.normals);
        continue;
      }
      final skinned = _skin(mesh, track, frame, clip.frames);
      positions.add(skinned.$1);
      normals.add(skinned.$2);
    }
    _posed = positions;
    _posedNormals = normals;
    _posedBones = bones;
    _posedFrame = frame;
    _posedClip = _clip;
  }

  /// A bone put where this frame has it: its resting place moved by its own
  /// matrix, which is one vertex with one bone pulling on it.
  Float32List _poseBones(
    MeshGeometry mesh,
    Float32List track,
    int frame,
    int frames,
  ) {
    final rest = mesh.bones;
    if (rest == null || rest.isEmpty) return Float32List(0);
    if (track.isEmpty) return rest;
    final joints = mesh.joints;
    final base = frame.clamp(0, frames - 1) * joints * 16;
    final out = Float32List(rest.length);
    for (var b = 0; b * 3 + 2 < rest.length; b++) {
      final x = rest[b * 3], y = rest[b * 3 + 1], z = rest[b * 3 + 2];
      final m = base + b * 16;
      if (b >= joints || m + 15 >= track.length) {
        out[b * 3] = x;
        out[b * 3 + 1] = y;
        out[b * 3 + 2] = z;
        continue;
      }
      out[b * 3] =
          track[m] * x + track[m + 4] * y + track[m + 8] * z + track[m + 12];
      out[b * 3 + 1] =
          track[m + 1] * x + track[m + 5] * y + track[m + 9] * z + track[m + 13];
      out[b * 3 + 2] =
          track[m + 2] * x + track[m + 6] * y + track[m + 10] * z + track[m + 14];
    }
    return out;
  }

  /// Linear blend skinning: every vertex is put where its bones agree it goes.
  (Float32List, Float32List) _skin(
    MeshGeometry mesh,
    Float32List track,
    int frame,
    int frames,
  ) {
    final count = mesh.vertexCount;
    final out = Float32List(count * 3);
    final outNormals = Float32List(count * 3);
    final joints = mesh.joints;
    final base = (frame.clamp(0, frames - 1)) * joints * 16;
    final indices = mesh.jointIndices!;
    final weights = mesh.jointWeights!;

    for (var v = 0; v < count; v++) {
      final x = mesh.positions[v * 3];
      final y = mesh.positions[v * 3 + 1];
      final z = mesh.positions[v * 3 + 2];
      final nx = mesh.normals[v * 3];
      final ny = mesh.normals[v * 3 + 1];
      final nz = mesh.normals[v * 3 + 2];

      var px = 0.0, py = 0.0, pz = 0.0;
      var mx = 0.0, my = 0.0, mz = 0.0;
      var total = 0.0;

      for (var slot = 0; slot < 4; slot++) {
        final weight = weights[v * 4 + slot];
        if (weight <= 0) continue;
        final joint = indices[v * 4 + slot];
        if (joint >= joints) continue;
        final m = base + joint * 16;
        if (m + 15 >= track.length) continue;

        // Row-vector convention, as the plugin bakes them.
        px += weight * (track[m] * x + track[m + 4] * y + track[m + 8] * z + track[m + 12]);
        py += weight * (track[m + 1] * x + track[m + 5] * y + track[m + 9] * z + track[m + 13]);
        pz += weight * (track[m + 2] * x + track[m + 6] * y + track[m + 10] * z + track[m + 14]);

        mx += weight * (track[m] * nx + track[m + 4] * ny + track[m + 8] * nz);
        my += weight * (track[m + 1] * nx + track[m + 5] * ny + track[m + 9] * nz);
        mz += weight * (track[m + 2] * nx + track[m + 6] * ny + track[m + 10] * nz);
        total += weight;
      }

      // A vertex nothing pulls on stays where it was rather than collapsing
      // to the origin, which is what an unweighted vertex looks like.
      if (total <= 1e-6) {
        out[v * 3] = x;
        out[v * 3 + 1] = y;
        out[v * 3 + 2] = z;
        outNormals[v * 3] = nx;
        outNormals[v * 3 + 1] = ny;
        outNormals[v * 3 + 2] = nz;
        continue;
      }

      out[v * 3] = px;
      out[v * 3 + 1] = py;
      out[v * 3 + 2] = pz;
      final length = math.sqrt(mx * mx + my * my + mz * mz);
      if (length > 1e-9) {
        outNormals[v * 3] = mx / length;
        outNormals[v * 3 + 1] = my / length;
        outNormals[v * 3 + 2] = mz / length;
      } else {
        outNormals[v * 3 + 1] = 1;
      }
    }
    return (out, outNormals);
  }

  void _reset() => setState(() {
        _yaw = 0.6;
        _pitch = 0.35;
        _zoom = 1;
        _pan = Offset.zero;
      });

  void _pick(int index) => setState(() {
        _clip = index;
        _frame = 0;
      });

  /// Everything this view can be told, as the application's own menu.
  ///
  /// One menu rather than a bar of buttons: it is searchable and walkable from
  /// the keyboard for nothing, and every letter it offers is a letter that
  /// works outside it too.
  Future<void> _menu({Offset? at}) async {
    final clips = _clips;
    final box = _clipAnchor.currentContext?.findRenderObject() as RenderBox?;
    await showAppContextMenu(
      context: context,
      globalPosition: at,
      anchorRect: at != null || box == null || !box.hasSize
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
      searchHint: tr('Search'),
      nodes: [
        for (final look in MeshLook.values)
          MenuItem(
            tr(look.label),
            icon: look.icon,
            accelerator: look.accelerator,
            checked: look == _look,
            onSelected: () => setState(() => _look = look),
          ),
        if (_hasSkeleton)
          MenuItem(
            tr('Bones over the model'),
            icon: Icons.polyline_outlined,
            accelerator: 'b',
            checked: _skeleton,
            onSelected: () => setState(() => _skeleton = !_skeleton),
          ),
        if (clips.length > 1) const MenuSeparator(),
        if (clips.length > 1)
          for (var i = 0; i < clips.length; i++)
            MenuItem(
              clips[i].name.isEmpty ? tr('Unnamed clip') : clips[i].name,
              icon: Icons.movie_outlined,
              checked: i == _clip,
              onSelected: () => _pick(i),
            ),
      ],
    );
  }

  void _orbit(Offset delta) => setState(() {
        _yaw += delta.dx * 0.01;
        // Straight up and straight down are where the maths degenerates and
        // where nobody wants to be anyway.
        _pitch = (_pitch + delta.dy * 0.01).clamp(-1.45, 1.45);
      });

  void _zoomBy(double factor) =>
      setState(() => _zoom = (_zoom * factor).clamp(0.05, 40.0));

  @override
  Widget build(BuildContext context) {
    if (_scene.isEmpty) {
      return Center(child: Text(tr('Nothing to show.')));
    }
    final theme = Theme.of(context);
    _pose();
    final clip = _current;

    return Focus(
      focusNode: _keys,
      onKeyEvent: _onKey,
      child: Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          _zoomBy(event.scrollDelta.dy > 0 ? 1 / 1.12 : 1.12);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _reset,
        // The whole menu, where the hand already is.
        onSecondaryTapUp: (details) => _menu(at: details.globalPosition),
        onScaleStart: (details) {
          _lastScale = 1;
          _lastFocus = details.localFocalPoint;
          _pointers = details.pointerCount;
        },
        onScaleUpdate: (details) {
          if (details.scale != 1) {
            _zoomBy(details.scale / _lastScale);
            _lastScale = details.scale;
          }
          final moved = details.localFocalPoint - _lastFocus;
          _lastFocus = details.localFocalPoint;
          // One finger turns the model; two move it, which is what every
          // other three-dimensional thing on a trackpad does.
          if (_pointers > 1 || details.pointerCount > 1) {
            setState(() => _pan += moved);
          } else if (details.scale == 1) {
            _orbit(moved);
          }
        },
        child: CustomPaint(
          painter: _MeshPainter(
            scene: _scene,
            images: _images,
            look: _look,
            skeleton: _skeleton,
            posed: _posed,
            posedNormals: _posedNormals,
            posedBones: _posedBones,
            yaw: _yaw,
            pitch: _pitch,
            zoom: _zoom,
            pan: _pan,
            background: theme.colorScheme.surface,
            fallback: theme.colorScheme.primary,
          ),
          child: Column(
            children: [
              // Over the model, top right: what it is being looked at with,
              // and one press to change it. The menu and the letters do the
              // same thing — this is the one you can see.
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: _toggles(theme),
                ),
              ),
              const Spacer(),
              if (clip != null) _transport(theme, clip),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Row(
                  children: [
                    // Flexible, because a clip's name is whatever the tool
                    // that wrote the file felt like: a real one arrived
                    // called `pexels-media-4260697-1677171430630_001_001` and
                    // pushed this row off the end of the window.
                    Flexible(
                      child: Text(
                        '${tr('{triangles} △ · {meshes} mesh(es)', {
                          'triangles': _scene.triangles,
                          'meshes': _scene.meshes.length,
                        })}'
                        '${clip == null ? '' : ' · ${clip.name}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                    // What was left out, said where what was shown is said.
                    // A model too big to read whole is drawn as far as it
                    // goes, and a model whose pictures are not beside it draws
                    // in flat colour; a preview that mentions neither is
                    // telling the reader they have seen the thing.
                    if (widget.content.detail?.isNotEmpty == true) ...[
                      const SizedBox(width: 8),
                      Icon(
                        widget.content.truncated
                            ? Icons.content_cut
                            : Icons.broken_image_outlined,
                        size: 12,
                        color: theme.colorScheme.error.withValues(alpha: 0.8),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          tr(widget.content.detail!),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.error
                                .withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
  /// The ways of looking, as a row of switches standing on the model.
  ///
  /// Three of them are one choice and the fourth is a thing on its own, so the
  /// bones sit apart behind a divider: a row of four identical buttons would
  /// say they were four of a kind.
  Widget _toggles(ThemeData theme) {
    return ViewportChrome(
      children: [
        for (final look in MeshLook.values)
          ViewportSwitch(
            icon: look.icon,
            message: '${tr(look.label)}  ${look.accelerator.toUpperCase()}',
            on: _look == look,
            onPressed: () => setState(() => _look = look),
          ),
        if (_hasSkeleton) ...[
          const ViewportRule(),
          ViewportSwitch(
            icon: Icons.polyline_outlined,
            message: '${tr('Bones over the model')}  B',
            on: _skeleton,
            onPressed: () => setState(() => _skeleton = !_skeleton),
          ),
        ],
      ],
    );
  }

  /// Play, pause and where in the clip we are — nothing else. A preview is
  /// watched, not edited.
  Widget _transport(ThemeData theme, MeshClip clip) {
    final colour = theme.colorScheme.onSurface.withValues(alpha: 0.75);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 12, 0),
      child: Row(
        children: [
          Hint(
            message: _playing ? tr('Pause') : tr('Play'),
            child: IconButton(
              iconSize: 20,
              color: colour,
              icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
              onPressed: () => _playing ? _pause() : _play(),
            ),
          ),
          if (_clips.length > 1)
            Hint(
              message: tr('Which animation'),
              child: TextButton.icon(
                key: _clipAnchor,
                onPressed: () => _menu(),
                icon: const Icon(Icons.movie_outlined, size: 16),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    clip.name.isEmpty ? tr('Unnamed clip') : clip.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: colour,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          Expanded(
            child: Slider(
              value: _frame.clamp(0, (clip.frames - 1).toDouble()),
              max: (clip.frames - 1).toDouble(),
              onChanged: (value) {
                if (_playing) _pause();
                setState(() => _frame = value);
              },
            ),
          ),
          Text(
            '${(_frame / clip.fps).toStringAsFixed(2)} / '
            '${clip.seconds.toStringAsFixed(2)} s',
            style: TextStyle(fontSize: 11, color: colour),
          ),
        ],
      ),
    );
  }
}

/// Where the eye is, and what that does to a point.
///
/// A turntable: the model stays where it is and the eye goes round it, which is
/// what a preview wants — a thing is turned over in the hands, not flown
/// through.
///
/// The world it is handed is right-handed and Y-up, whatever the file said, and
/// the screen has to keep it that way: x across to the right, y up, and **the
/// eye on the +Z side** looking back at the origin. Put the eye on the other
/// side and every image is its own mirror image, which is the kind of mistake
/// that never looks like one — a cube still looks like a cube. It shows only in
/// the two places it cannot hide: the model turns the wrong way under the
/// mouse, and a solid shape reads as hollow, because turning left while being
/// lit as though turning right is exactly what a hollow shape does.
class MeshCamera {
  MeshCamera({
    required double yaw,
    required double pitch,
    required this.distance,
  })  : _cosYaw = math.cos(yaw),
        _sinYaw = math.sin(yaw),
        _cosPitch = math.cos(pitch),
        _sinPitch = math.sin(pitch);

  /// How far the eye stands off what it is looking at.
  final double distance;

  /// Where the eye has to stand to have all of a model in front of it, in the
  /// direction [look] and [face] are written for.
  ///
  /// The sphere of radius r fits inside a cone of half-angle θ only from
  /// `r / sin θ` away, so the framing and the field of view are one number and
  /// are kept as one. The eye itself is `unit(yaw, pitch)` scaled by this.
  static double distanceFor(double radius, double zoom) =>
      radius * math.sqrt(1 + _focal * _focal) * _margin / zoom;

  /// The direction the eye lies in from what it is looking at.
  static List<double> unit(double yaw, double pitch) => [
        -math.sin(yaw) * math.cos(pitch),
        math.sin(pitch),
        math.cos(yaw) * math.cos(pitch),
      ];

  /// Field of view, as the half-angle's tangent. 45° all told.
  static const double _focal = 2.414; // 1 / tan(22.5°)

  /// How far off the model the eye stands, in radii, so that the whole of it
  /// is inside the frame — see [distanceFor]. It used to be 2.1, which frames
  /// a sphere of 0.80 r and cuts the fifth of the model that sticks out past
  /// it. Nothing showed it for as long as the only models were people: tall,
  /// thin, and nowhere near filling the sphere their height sets. A cube fills
  /// it in every direction at once, and came out with its near corner off the
  /// bottom of the window.
  static const double _margin = 1.06;

  final double _cosYaw;
  final double _sinYaw;
  final double _cosPitch;
  final double _sinPitch;

  /// What [look] or [face] was last given, as the screen sees it: across it to
  /// the right, up it, and away from the eye. Fields rather than a returned
  /// record, because this runs three times per triangle per frame.
  double across = 0;
  double up = 0;
  double away = 0;

  /// A point, given relative to whatever the camera is turning about.
  void look(double dx, double dy, double dz) {
    final towards = _cosYaw * dz - _sinYaw * dx;
    across = _cosYaw * dx + _sinYaw * dz;
    up = _cosPitch * dy - _sinPitch * towards;
    away = distance - (_cosPitch * towards + _sinPitch * dy);
  }

  /// A direction — a normal. It has no place, so no distance from the eye
  /// either: [away] comes back as how much of it points straight at the eye,
  /// negative when it does.
  void face(double nx, double ny, double nz) {
    final towards = _cosYaw * nz - _sinYaw * nx;
    across = _cosYaw * nx + _sinYaw * nz;
    up = _cosPitch * ny - _sinPitch * towards;
    away = -(_cosPitch * towards + _sinPitch * ny);
  }
}

/// The meshes plus what the camera needs to know about them.
class _Scene {
  _Scene({
    required this.meshes,
    required this.centre,
    required this.radius,
    required this.triangles,
    this.solid = const [],
  });

  factory _Scene.of(List<MeshGeometry> meshes) {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
    var triangles = 0;

    for (final mesh in meshes) {
      triangles += mesh.triangleCount;
      final p = mesh.positions;
      for (var i = 0; i + 2 < p.length; i += 3) {
        if (p[i] < minX) minX = p[i];
        if (p[i] > maxX) maxX = p[i];
        if (p[i + 1] < minY) minY = p[i + 1];
        if (p[i + 1] > maxY) maxY = p[i + 1];
        if (p[i + 2] < minZ) minZ = p[i + 2];
        if (p[i + 2] > maxZ) maxZ = p[i + 2];
      }
    }

    if (triangles == 0 || minX > maxX) {
      return _Scene(
        meshes: const [],
        centre: const [0.0, 0.0, 0.0],
        radius: 1,
        triangles: 0,
      );
    }

    final centre = [(minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2];
    final radius = math.max(
      1e-6,
      0.5 *
          math.sqrt(
            math.pow(maxX - minX, 2) +
                math.pow(maxY - minY, 2) +
                math.pow(maxZ - minZ, 2),
          ),
    );
    return _Scene(
      meshes: meshes,
      centre: centre,
      radius: radius,
      triangles: triangles,
      solid: [for (final mesh in meshes) _solidity(mesh)],
    );
  }

  /// Whether a mesh shuts, and if so which way round it is wound: 1 when its
  /// triangles run anticlockwise seen from outside, −1 when they run the other
  /// way, and 0 when the mesh has no outside to speak of.
  ///
  /// Both halves are measured off the file rather than assumed of it, and
  /// neither asks anything of the normals it shipped.
  ///
  /// **Does it shut.** Add up every triangle's normal scaled by its own area
  /// and a closed surface cancels itself out exactly — each direction it faces
  /// one way it also faces the other. An open one does not: the sum comes back
  /// as the area of the hole it has, so three sides of a box read 58% of their
  /// own area and a shut box reads nothing. That is the real question, it takes
  /// one pass, and unlike counting shared edges it is unbothered by the fact
  /// that every corner of every file here is split per face — a cube ships as
  /// 24 vertices, and no two of its faces share an index.
  ///
  /// **Which way round.** The volume it encloses, as the tetrahedra its
  /// triangles make with a point inside, signed by the winding. Being closed,
  /// the answer does not depend on which point. A surface that shuts but
  /// encloses nothing — a sheet with a copy of itself wound backwards, which
  /// is how a file ships a leaf that must be seen from both sides — comes out
  /// at zero here, and is left alone: there is no far side of it to drop.
  static int _solidity(MeshGeometry mesh) {
    final p = mesh.positions;
    final indices = mesh.indices;
    if (indices.length < 3 || p.length < 9) return 0;

    var cx = 0.0, cy = 0.0, cz = 0.0;
    final count = p.length ~/ 3;
    for (var v = 0; v < count; v++) {
      cx += p[v * 3];
      cy += p[v * 3 + 1];
      cz += p[v * 3 + 2];
    }
    cx /= count;
    cy /= count;
    cz /= count;

    var volume = 0.0;
    var area = 0.0;
    var openX = 0.0, openY = 0.0, openZ = 0.0;
    for (var t = 0; t + 2 < indices.length; t += 3) {
      final a = indices[t] * 3, b = indices[t + 1] * 3, c = indices[t + 2] * 3;
      if (a + 2 >= p.length || b + 2 >= p.length || c + 2 >= p.length) continue;
      final ax = p[a] - cx, ay = p[a + 1] - cy, az = p[a + 2] - cz;
      final bx = p[b] - cx, by = p[b + 1] - cy, bz = p[b + 2] - cz;
      final dx = p[c] - cx, dy = p[c + 1] - cy, dz = p[c + 2] - cz;

      // (b − a) × (c − a): twice the triangle's area, pointing the way the
      // winding says it faces.
      final ex = bx - ax, ey = by - ay, ez = bz - az;
      final fx = dx - ax, fy = dy - ay, fz = dz - az;
      final gx = ey * fz - ez * fy;
      final gy = ez * fx - ex * fz;
      final gz = ex * fy - ey * fx;
      openX += gx;
      openY += gy;
      openZ += gz;
      area += math.sqrt(gx * gx + gy * gy + gz * gz) / 2;

      // And a · (b × c) / 6: the tetrahedron from the centre to the triangle.
      volume += (ax * (by * dz - bz * dy) +
              ay * (bz * dx - bx * dz) +
              az * (bx * dy - by * dx)) /
          6;
    }

    if (area <= 0) return 0;
    final open = math.sqrt(openX * openX + openY * openY + openZ * openZ) / 2;
    if (open > area * 0.001) return 0;
    if (volume.abs() < math.pow(area, 1.5) * 0.005) return 0;
    return volume > 0 ? 1 : -1;
  }

  final List<MeshGeometry> meshes;
  final List<double> centre;
  final double radius;
  final int triangles;

  /// Per mesh, what [_solidity] found.
  final List<int> solid;

  bool get isEmpty => triangles == 0;
}

/// One frame's worth of arithmetic.
class _MeshPainter extends CustomPainter {
  _MeshPainter({
    required this.scene,
    required this.images,
    required this.look,
    required this.skeleton,
    required this.posed,
    required this.posedNormals,
    required this.posedBones,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.pan,
    required this.background,
    required this.fallback,
  });

  final _Scene scene;

  /// The decoded pictures, in the order the meshes index them by. Entries may
  /// be null — one that has not arrived yet, and one that never will.
  final List<ui.Image?> images;

  /// How it is being looked at, and whether the skeleton goes over it.
  final MeshLook look;
  final bool skeleton;

  /// Where the vertices are this frame, or null when nothing is animating.
  final List<Float32List>? posed;
  final List<Float32List>? posedNormals;
  final List<Float32List>? posedBones;

  final double yaw;
  final double pitch;
  final double zoom;
  final Offset pan;
  final Color background;
  final Color fallback;

  /// Field of view, as the half-angle's tangent. 45° all told, and the same
  /// number the camera frames a model with — see [MeshCamera.distanceFor].
  static const double _focal = MeshCamera._focal;

  /// The key light, and it stands **in the world**, above and to one side —
  /// not in the camera's frame with everything else here.
  ///
  /// That is the whole of what it means for a model to have a top and an
  /// underside. A light carried by the camera has no such thing: stoop to look
  /// up at a model and the light stoops with you, so the underside comes up as
  /// brightly lit as the top ever was, and what anyone reasonably says about
  /// that is that the normals are inside out. Leave the light where it is and
  /// going underneath something puts you in its shadow, which is what going
  /// underneath something does.
  ///
  /// The direction was solved for, not chosen: a cube at the angle this view
  /// opens at shows three faces, and they were asked to come out 0.90, 0.67 and
  /// 0.46 apart enough to read as three planes of one solid.
  static const double _keyX = -0.568;
  static const double _keyY = 0.770;
  static const double _keyZ = 0.290;
  static const double _keyWeight = 0.66;

  /// The bounce, also standing in the world, under the model and opposite the
  /// key — what a floor would throw back. Weak, because it is a bounce.
  ///
  /// It is here because the key alone was the same fault stood on its head:
  /// with nothing but a light from above, going underneath a model put every
  /// face in view in shadow at once, and a shape with no light on it at all
  /// reads as broken exactly the way an evenly lit one does. The underside now
  /// comes out around 0.31 against its neighbouring sides at 0.48 and 0.53 —
  /// plainly the darker face, and still a face.
  static const double _bounceX = 0.501;
  static const double _bounceY = -0.751;
  static const double _bounceZ = -0.431;
  static const double _bounceWeight = 0.20;

  /// The fill, and this one *does* ride with the camera: across the screen, up
  /// it, and towards the eye. Its job is the opposite of the key's — to make
  /// sure that whatever you have turned towards you can be made out at all,
  /// even from the shadow side. Hence weak, and hence off to one side rather
  /// than sitting on the eye, which would flatten every face it touched.
  static const double _fillAcross = 0.87;
  static const double _fillUp = 0.49;
  static const double _fillToEye = 0.06;
  static const double _fillWeight = 0.16;

  /// What a face none of them reaches still gets. The key and the bounce point
  /// almost exactly opposite ways, so no face can take both: the brightest any
  /// face gets is 0.98, nothing is ever clipped, and the darkest anywhere —
  /// measured over every direction a face can point and every angle it can be
  /// seen from — is this.
  static const double _ambient = 0.16;

  @override
  void paint(Canvas canvas, Size size) {
    if (scene.isEmpty || size.isEmpty) return;

    // Nothing here draws outside the view it was given. A canvas is not bounded
    // by the widget that owns it, and a model that overflows its frame was
    // painting over whatever the page had put beside it.
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final camera = MeshCamera(
      yaw: yaw,
      pitch: pitch,
      distance: MeshCamera.distanceFor(scene.radius, zoom),
    );
    final scale = math.min(size.width, size.height) / 2 * _focal;
    final originX = size.width / 2 + pan.dx;
    final originY = size.height / 2 + pan.dy;

    // Every triangle in the file lands in one array, sorted once: two meshes
    // drawn separately would each be sorted only against themselves, and the
    // near one would be painted under the far one wherever they overlap.
    final total = scene.triangles;
    final positions = Float32List(total * 6);
    final colours = Int32List(total * 3);
    final texture = Float32List(total * 6);
    final depths = Float32List(total);
    final order = Int32List(total);
    /// Which picture each triangle is read out of, −1 for the ones that are
    /// only a colour. It is what the drawing is broken into runs by.
    final painted = Int32List(total);
    var kept = 0;

    for (var index = 0; index < scene.meshes.length; index++) {
      final mesh = scene.meshes[index];
      final picture = mesh.isPainted && mesh.image < images.length
          ? images[mesh.image]
          : null;
      // A picture *is* the colour: what the material also said about it is a
      // fallback for the file that has no picture, and multiplying the two
      // would only darken a photograph by whatever grey the exporter wrote.
      final base = picture != null
          ? const Color(0xFFFFFFFF)
          : _visible(mesh.color != null ? Color(mesh.color!) : fallback);
      final red = base.r, green = base.g, blue = base.b;
      final uvs = mesh.uvs;
      final width = picture?.width.toDouble() ?? 0;
      final height = picture?.height.toDouble() ?? 0;
      final posedList = posed;
      final p = posedList != null && index < posedList.length
          ? posedList[index]
          : mesh.positions;
      final posedNormalList = posedNormals;
      final n = posedNormalList != null && index < posedNormalList.length
          ? posedNormalList[index]
          : mesh.normals;
      final indices = mesh.indices;
      final solid = index < scene.solid.length ? scene.solid[index] : 0;

      for (var t = 0; t + 2 < indices.length; t += 3) {
        var sumZ = 0.0;
        var visible = true;
        final slot = kept * 6;

        for (var corner = 0; corner < 3; corner++) {
          final v = indices[t + corner] * 3;
          if (v + 2 >= p.length) {
            visible = false;
            break;
          }

          camera.look(
            p[v] - scene.centre[0],
            p[v + 1] - scene.centre[1],
            p[v + 2] - scene.centre[2],
          );

          // Behind the eye, or on it: no projection exists, so the triangle
          // goes. Clipping properly is a lot of code for a preview.
          final depth = camera.away;
          if (depth <= scene.radius * 0.02) {
            visible = false;
            break;
          }

          positions[slot + corner * 2] = originX + camera.across * scale / depth;
          positions[slot + corner * 2 + 1] = originY - camera.up * scale / depth;
          sumZ += depth;

          // Where in the picture this corner reads from, in its own pixels:
          // that is the space an `ImageShader` samples in.
          if (picture != null && uvs != null && v ~/ 3 * 2 + 1 < uvs.length) {
            texture[slot + corner * 2] = uvs[v ~/ 3 * 2] * width;
            texture[slot + corner * 2 + 1] = uvs[v ~/ 3 * 2 + 1] * height;
          }

          // Two lights and an ambient, and the lighting is two-sided — but by
          // turning a normal that points away back towards the eye, **not** by
          // taking the size of the dot product and dropping its sign.
          //
          // Dropping it is what a preview reads as broken normals, and rightly:
          // a normal and its exact opposite then light the same, so the
          // underside of a model is as bright as its top and no surface can
          // ever say which way it faces. A surface you can see is a surface
          // facing you, so a normal that points away is one the file wrote
          // backwards — which is the thing two-sidedness is for, and all it is
          // for.
          camera.face(n[v], n[v + 1], n[v + 2]);
          final facing = camera.away <= 0 ? 1.0 : -1.0;

          // The two standing lights are asked of the normal as the file gave
          // it, in the world; the fill of the same normal as the screen sees
          // it. Turning it round is a factor either way, a dot product being
          // linear.
          final key =
              (n[v] * _keyX + n[v + 1] * _keyY + n[v + 2] * _keyZ) * facing;
          final bounce =
              (n[v] * _bounceX + n[v + 1] * _bounceY + n[v + 2] * _bounceZ) *
                  facing;
          final fill = (camera.across * _fillAcross +
                  camera.up * _fillUp -
                  camera.away * _fillToEye) *
              facing;
          // Unlit is the picture as it was painted, which is the only way to
          // tell a dark texture from a badly lit one.
          final lambert = look == MeshLook.unlit
              ? 1.0
              : (key > 0 ? key * _keyWeight : 0.0) +
                  (bounce > 0 ? bounce * _bounceWeight : 0.0) +
                  (fill > 0 ? fill * _fillWeight : 0.0) +
                  _ambient;

          colours[kept * 3 + corner] = _shade(red, green, blue, lambert);
        }

        if (!visible) continue;

        // The far side of a solid, dropped.
        //
        // Sorting alone cannot do this, and that is not a matter of tuning.
        // A triangle is ordered by one number — where its middle is — while
        // what it hides is a question asked separately at every pixel it
        // covers. On a closed shape the two disagree wherever a face that
        // faces away has its middle nearer than the far corner of a face that
        // faces you: the underside of a box, seen level with it, is a sliver
        // whose middle is nearer than half of the side wall in front of it, so
        // it is painted last and lies across the wall as a wedge of nowhere.
        // Which is what shows on screen, and it is not a wrong number
        // anywhere.
        //
        // The far side cannot hide anything from an eye outside the shape, so
        // once [_Scene._solidity] has established that there *is* an outside,
        // the far side can go. Which way a triangle faces is read off the
        // picture rather than off the normals the file supplied: the corners
        // of a triangle turned towards you come out one way round on screen
        // and the other way round when it is turned away, whatever the file
        // believes its normals to be. Perspective is already in that, being
        // measured after the projection.
        if (solid != 0) {
          final ax = positions[slot], ay = positions[slot + 1];
          final turn = (positions[slot + 2] - ax) * (positions[slot + 5] - ay) -
              (positions[slot + 4] - ax) * (positions[slot + 3] - ay);
          // Screen y runs down, which turns every triangle round once more.
          if (turn * solid >= 0) continue;
        }

        depths[kept] = sumZ;
        order[kept] = kept;
        painted[kept] = picture != null ? mesh.image : -1;
        kept++;
      }
    }

    if (kept == 0) {
      canvas.restore();
      return;
    }

    // Far to near. Without a depth buffer this ordering *is* the depth test.
    final sorted = order.buffer.asInt32List(0, kept).toList(growable: false)
      ..sort((a, b) => depths[b].compareTo(depths[a]));

    if (look == MeshLook.wire) {
      // Every triangle's three edges, from the same projected corners the
      // shaded look draws — so a wireframe can never disagree with the model
      // it is a wireframe of. Lines want no depth order: a wireframe is
      // see-through, which is what it is for.
      final lines = Float32List(kept * 12);
      for (var i = 0; i < kept; i++) {
        final from = i * 6;
        final to = i * 12;
        for (var edge = 0; edge < 3; edge++) {
          final a = (edge * 2) % 6;
          final b = ((edge + 1) * 2) % 6;
          lines[to + edge * 4] = positions[from + a];
          lines[to + edge * 4 + 1] = positions[from + a + 1];
          lines[to + edge * 4 + 2] = positions[from + b];
          lines[to + edge * 4 + 3] = positions[from + b + 1];
        }
      }
      canvas.drawRawPoints(
        ui.PointMode.lines,
        lines,
        Paint()
          ..color = fallback.withValues(alpha: 0.7)
          ..strokeWidth = 1,
      );
      _drawBones(canvas, camera, scale, originX, originY);
      canvas.restore();
      return;
    }

    // One call can carry one picture, so a model of several has to be drawn in
    // more than one — and the order they go in is not negotiable. Rather than
    // a call per picture, which would put every triangle of one behind every
    // triangle of another, the sorted order is walked and cut wherever the
    // picture changes. The depth order survives whole; what varies is only how
    // many calls it takes, and for the usual model — one picture, or none —
    // that is still one.
    var start = 0;
    while (start < kept) {
      final image = painted[sorted[start]];
      var end = start + 1;
      while (end < kept && painted[sorted[end]] == image) {
        end++;
      }
      final count = end - start;

      final drawPositions = Float32List(count * 6);
      final drawColours = Int32List(count * 3);
      final drawTexture = image < 0 ? null : Float32List(count * 6);
      for (var i = 0; i < count; i++) {
        final from = sorted[start + i] * 6;
        final to = i * 6;
        for (var part = 0; part < 6; part++) {
          drawPositions[to + part] = positions[from + part];
          drawTexture?[to + part] = texture[from + part];
        }
        final fromColour = sorted[start + i] * 3;
        drawColours[i * 3] = colours[fromColour];
        drawColours[i * 3 + 1] = colours[fromColour + 1];
        drawColours[i * 3 + 2] = colours[fromColour + 2];
      }

      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        drawPositions,
        textureCoordinates: drawTexture,
        colors: drawColours,
      );
      if (image < 0) {
        canvas.drawVertices(vertices, BlendMode.srcOver, Paint());
      } else {
        // `modulate` multiplies the picture by the colour each corner was
        // given, and that colour is the light: the model is lit exactly as it
        // was before, with the picture standing where the flat colour stood.
        final shader = ui.ImageShader(
          images[image]!,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.identity().storage,
          filterQuality: FilterQuality.medium,
        );
        canvas.drawVertices(
          vertices,
          BlendMode.modulate,
          Paint()..shader = shader,
        );
        shader.dispose();
      }
      vertices.dispose();
      start = end;
    }
    _drawBones(canvas, camera, scale, originX, originY);
    canvas.restore();
  }

  /// The skeleton, over the model.
  ///
  /// A bone is a line to the bone it hangs from and a dot where it sits, and
  /// that is the whole of it: what anyone wants from this is whether the rig
  /// is where the limbs are, and whether it is the rig that is bending them.
  /// Drawn over everything and with no depth test of its own — a skeleton half
  /// hidden inside its own model is no use for either question.
  void _drawBones(Canvas canvas, MeshCamera camera, double scale,
      double originX, double originY) {
    if (!skeleton) return;
    final posedList = posedBones;
    final line = Paint()
      ..color = const Color(0xFF00E5FF)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final joint = Paint()..color = const Color(0xFFFFC400);

    for (var index = 0; index < scene.meshes.length; index++) {
      final mesh = scene.meshes[index];
      final parents = mesh.boneParents;
      if (parents == null || parents.isEmpty) continue;
      final rest = posedList != null && index < posedList.length &&
              posedList[index].isNotEmpty
          ? posedList[index]
          : mesh.bones;
      if (rest == null || rest.isEmpty) continue;

      Offset? screen(int bone) {
        final at = bone * 3;
        if (at + 2 >= rest.length) return null;
        camera.look(rest[at] - scene.centre[0], rest[at + 1] - scene.centre[1],
            rest[at + 2] - scene.centre[2]);
        final depth = camera.away;
        if (depth <= scene.radius * 0.02) return null;
        return Offset(originX + camera.across * scale / depth,
            originY - camera.up * scale / depth);
      }

      for (var bone = 0; bone < parents.length; bone++) {
        final here = screen(bone);
        if (here == null) continue;
        final parent = parents[bone];
        if (parent >= 0 && parent < parents.length) {
          final there = screen(parent);
          if (there != null) canvas.drawLine(there, here, line);
        }
        canvas.drawCircle(here, 2.2, joint);
      }
    }
  }

  /// A material colour, brought up to something a shape can be read from.
  ///
  /// Preview, not render: a diffuse colour of near-black is a perfectly good
  /// answer to "what colour is this" and a useless answer to "what shape is
  /// this". Dark materials are lifted; anything already legible is left alone.
  static Color _visible(Color colour) {
    final hsl = HSLColor.fromColor(colour);
    if (hsl.lightness >= 0.45) return colour;
    return hsl
        .withLightness(0.58)
        .withSaturation(math.min(hsl.saturation, 0.35))
        .toColor();
  }

  static int _shade(double r, double g, double b, double lambert) {
    final light = lambert.clamp(0.0, 1.0);
    final red = (r * light * 255).clamp(0, 255).toInt();
    final green = (g * light * 255).clamp(0, 255).toInt();
    final blue = (b * light * 255).clamp(0, 255).toInt();
    return 0xFF000000 | (red << 16) | (green << 8) | blue;
  }

  @override
  bool shouldRepaint(_MeshPainter old) =>
      old.scene != scene ||
      old.look != look ||
      old.skeleton != skeleton ||
      !identical(old.images, images) ||
      !identical(old.posedBones, posedBones) ||
      !identical(old.posed, posed) ||
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom ||
      old.pan != pan ||
      old.fallback != fallback;
}
