import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../plugins/viewer.dart';

/// What the machine said when it was asked whether it can draw a model.
class Mesh3dAcceleration {
  const Mesh3dAcceleration({
    required this.available,
    this.renderer = '',
    this.reason = '',
  });

  static const Mesh3dAcceleration none = Mesh3dAcceleration(available: false);

  /// Whether there is a graphics path at all.
  final bool available;

  /// What it is drawing with, for the one line a person may want to read:
  /// "OpenGL 4.6 · NVIDIA GeForce RTX 3070".
  final String renderer;

  /// Why not, when not: "OpenGL 1.1 (GDI Generic)", "OpenGL 3.3 refused".
  final String reason;
}

/// The graphics card's half of the model viewer.
///
/// **This file is the contract, and it is deliberately not about OpenGL.** One
/// implementation exists — `windows/runner/mesh3d.cpp`, which uses OpenGL 3.3
/// because that is what Windows has — and the others will not: Linux hands
/// Flutter a GL texture directly through `FlTextureGL`, and macOS will be
/// Metal, because OpenGL there has been deprecated since 2018. What every
/// implementation shares is the six methods below and nothing else. Adding a
/// platform is: write the native half, add the platform to [isSupported], and
/// change nothing in `lib/ui`.
///
/// **An addition to the painter, never a replacement.** Every method here can
/// say no, and every no means the same thing: the model is drawn by
/// `_MeshPainter` in `lib/ui/plugins/mesh3d_view.dart`, which is what happens
/// on a platform with no native half, on a machine with no graphics worth
/// having, and on any model this side will not take whole. Nothing anywhere
/// treats that as a failure, and nothing tells the user.
///
/// ## What a native half has to do
///
/// - `probe` → `{available, renderer, reason}`. Asked once. `renderer` is a
///   line fit to show a person — "OpenGL 4.6 · NVIDIA GeForce RTX 3060" — and
///   `reason` says why not when not. **Refuse a software renderer.** The
///   painter already rasterises on the GPU through Flutter's own canvas, so
///   falling back to a software GL is a step down, not a step sideways.
/// - `create` → a texture id, **64 bits**. Windows hands out numbers like
///   1 863 525 693 296; anything that narrows one to an `int` finds no model
///   and fails silently.
/// - `upload` → the geometry, once. False means this model is not this side's
///   to draw, and half a model is worse than the painter drawing all of it.
/// - `clips` → every baked frame of every clip, once.
/// - `frame` → draw and mark the texture ready. One call, one picture.
/// - `dispose` → give the surface back.
///
/// ## What it has to get right
///
/// - **The framing is not free to differ.** The camera is a turntable whose
///   distance is `radius · √(1 + focal²) · margin / zoom` with `focal` 2.414
///   and `margin` 1.06 — `MeshCamera.distanceFor`, and the reason both paths
///   frame a model identically instead of jumping when acceleration turns on.
/// - **Lighting is three directions and an ambient**, the numbers in
///   `_MeshPainter`, two-sided by turning a normal that points away back
///   towards the eye rather than by dropping a sign.
/// - **Bone matrices are row-vector** as the plugin bakes them, which is what a
///   column-major `mat4` multiplied on the left already reads. No transposing.
/// - **Sizes are physical pixels** and so is the pan; Dart multiplies by the
///   device ratio before calling.
/// - **The picture is premultiplied and cleared to nothing**, so the theme's
///   own surface stays behind the model.
/// - Whether the picture has to be turned over depends on the platform: a
///   framebuffer's origin is its bottom left corner and the engine wants the
///   top row first.
///
/// The division of labour with Dart does not change: geometry crosses once,
/// clips cross once, and a frame costs a camera and two numbers. The clock, the
/// clips, the camera and the keyboard stay where they were.
class Mesh3dChannel {
  const Mesh3dChannel._();

  static const MethodChannel _channel = MethodChannel('xverb/mesh3d');

  /// Which platforms carry a native half at all.
  ///
  /// **The one line to change when another is written.** Asked before anything
  /// else so that no channel call is made where nothing is listening — a
  /// missing channel would answer, eventually, with an exception per model
  /// opened.
  static bool get isSupported => Platform.isWindows;

  /// What this machine can do, asked once and remembered: a driver does not
  /// arrive while the application is running.
  static Future<Mesh3dAcceleration> probe() async {
    if (!isSupported) return Mesh3dAcceleration.none;
    final remembered = _probed;
    if (remembered != null) return remembered;
    try {
      final answer = await _channel.invokeMapMethod<String, Object?>('probe');
      _probed = Mesh3dAcceleration(
        available: answer?['available'] == true,
        renderer: answer?['renderer']?.toString() ?? '',
        reason: answer?['reason']?.toString() ?? '',
      );
    } on Object {
      // A missing channel is a fallback, not a crash.
      _probed = Mesh3dAcceleration.none;
    }
    return _probed!;
  }

  static Mesh3dAcceleration? _probed;

  /// Makes a surface and returns the texture it will be shown through, or null.
  static Future<int?> create() async {
    if (!isSupported) return null;
    try {
      final id = await _channel.invokeMethod<Object?>('create');
      return id is int ? id : null;
    } on Object {
      return null;
    }
  }

  /// Hands over the geometry, once. False means this model is not this side's
  /// to draw — too many bones for one uniform block, or nothing in it.
  ///
  /// [images] are the pictures already decoded for the Dart painter, so no file
  /// is read twice and no decoder is written on the native side.
  ///
  /// [colours] is one `0xAARRGGBB` per mesh, or null where the file said no
  /// colour and the theme's is to stand in. They are passed in rather than read
  /// off the meshes because what a material colour *looks* like here is a rule
  /// the painter already owns — dark ones are lifted until a shape can be read
  /// from them — and a rule with two implementations is a rule with two
  /// answers.
  static Future<bool> upload(
    int view,
    List<MeshGeometry> meshes,
    List<ui.Image?> images,
    List<int?> colours,
  ) async {
    if (!isSupported) return false;
    try {
      final pictures = <Map<String, Object?>>[];
      for (final image in images) {
        final bytes = image == null
            ? null
            : await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        pictures.add({
          'width': image?.width ?? 0,
          'height': image?.height ?? 0,
          'pixels': bytes?.buffer.asUint8List(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ) ??
              Uint8List(0),
        });
      }

      final ok = await _channel.invokeMethod<bool>('upload', {
        'view': view,
        'images': pictures,
        'meshes': [
          for (final (index, mesh) in meshes.indexed)
            {
              'positions': _bytes(mesh.positions),
              'normals': _bytes(mesh.normals),
              'indices': _bytes(mesh.indices),
              if (mesh.uvs != null) 'uvs': _bytes(mesh.uvs!),
              if (mesh.bones != null) 'bones': _bytes(mesh.bones!),
              if (mesh.boneParents != null)
                'boneParents': _bytes(mesh.boneParents!),
              if (mesh.isSkinned) ...{
                'joints': mesh.joints,
                'jointIndices': _bytes(mesh.jointIndices!),
                'jointWeights': _bytes(mesh.jointWeights!),
              },
              'image': mesh.image,
              if (index < colours.length && colours[index] != null)
                'color': colours[index],
            },
        ],
      });
      return ok ?? false;
    } on Object {
      return false;
    }
  }

  /// Hands over every baked frame of every clip, once. [clips] must be in the
  /// order the view plays them in, because a frame names a clip by index.
  static Future<bool> clips(int view, List<MeshClip> clips) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('clips', {
        'view': view,
        'clips': [
          for (final clip in clips)
            {
              'frames': clip.frames,
              'tracks': [for (final track in clip.tracks) _bytes(track)],
            },
        ],
      });
      return ok ?? false;
    } on Object {
      return false;
    }
  }

  /// Draws one frame and marks it ready. False means nothing was drawn, and
  /// the caller should show what it showed before — or fall back for good.
  static Future<bool> frame(
    int view, {
    required int width,
    required int height,
    required double yaw,
    required double pitch,
    required double zoom,
    required double panX,
    required double panY,
    required int look,
    required bool skeleton,
    required bool reflections,
    required int clip,
    required int frame,
    required int fallback,
  }) async {
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('frame', {
        'view': view,
        'width': width,
        'height': height,
        'yaw': yaw,
        'pitch': pitch,
        'zoom': zoom,
        'panX': panX,
        'panY': panY,
        'look': look,
        'skeleton': skeleton,
        'reflections': reflections,
        'clip': clip,
        'frame': frame,
        // Per frame rather than per upload, because it is the theme's and the
        // theme can change under an open model.
        'fallback': fallback,
      });
      return ok ?? false;
    } on Object {
      return false;
    }
  }

  /// Gives back the surface, the geometry and the pictures.
  static Future<void> dispose(int view) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<bool>('dispose', {'view': view});
    } on Object {
      // Nothing to do about it, and nothing to tell anybody.
    }
  }

  /// Every array crosses as bytes.
  ///
  /// Dart's standard codec has no `Uint32List` and no `Uint16List` — and
  /// indices are the first while bone slots are the second. Rather than two
  /// encodings and a conversion on the far side, there is one: the bytes as
  /// they already sit in memory, which for a typed list is no copy at all.
  static Uint8List _bytes(TypedData list) =>
      list.buffer.asUint8List(list.offsetInBytes, list.lengthInBytes);
}
