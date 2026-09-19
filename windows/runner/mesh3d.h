#ifndef RUNNER_MESH3D_H_
#define RUNNER_MESH3D_H_

#include <flutter/flutter_engine.h>

// Draws a model on the graphics card, over the `xverb/mesh3d` channel.
//
// **The Windows half of a contract, not the contract.** What the channel is —
// its six methods, what each argument means, and everything a picture has to
// get right to agree with the renderer Dart already has — is written in
// `lib/core/platform/mesh3d_channel.dart`, and is deliberately free of OpenGL.
// Linux hands Flutter a GL texture directly and macOS will be Metal; this file
// uses OpenGL 3.3 because that is what Windows has, and because the engine
// takes a pixel buffer here rather than a texture name.
//
// **An addition, never a replacement.** `lib/ui/plugins/mesh3d_view.dart` keeps
// its own renderer and keeps using it: on every other platform, on a machine
// whose OpenGL is not worth having, and at any point where anything here says
// no. What this offers is the one thing that renderer cannot — geometry that
// stays on the card between frames.
//
// That is the whole of the speed argument. The processor path is not slow
// because it rasterises in software (it does not: Flutter's canvas puts the
// triangles through the GPU); it is slow because every frame rebuilds every
// vertex on the processor — skinning, projection, lighting, a back-to-front
// sort, and some thirteen megabytes of fresh arrays for a model of a hundred
// thousand triangles. Here the vertices are uploaded once and posed by the
// vertex shader, so a frame costs one buffer of bone matrices — a few
// kilobytes — and one draw call. The depth buffer comes free with that, and
// with it the sort and the dropped far side of a solid both stop being needed.
//
// The division of labour with Dart is unchanged: the plugin bakes, and now the
// host draws twice over. Dart still owns the clock, the clips, the camera and
// every key; this side is asked for a picture and answers with one.
void RegisterMesh3dChannel(flutter::FlutterEngine* engine);

#endif  // RUNNER_MESH3D_H_
