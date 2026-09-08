#ifndef RUNNER_BACKDROP_H_
#define RUNNER_BACKDROP_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Applies the window's composition attribute — the legacy blur-behind and
// acrylic accents — over the `xverb/backdrop` channel.
//
// This exists because `flutter_acrylic` writes ACCENT_DISABLED to the window
// before every effect it sets. DWM composes a frame from that intermediate
// state, so each re-apply blanks the window for a moment: dragging the window
// raises a focus event, the focus handler re-asserts the backdrop, and the
// window visibly flashes. One write, no intermediate state, no flash.
void RegisterBackdropChannel(flutter::FlutterEngine* engine, HWND window);

#endif  // RUNNER_BACKDROP_H_
