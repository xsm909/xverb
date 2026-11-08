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
//
// The same channel carries `inactiveOpacity`: how see-through a window is
// while another one has the focus. `setAccent` takes an optional `handle`, the
// address of a detached view's window; without one it is [main_window].
void RegisterBackdropChannel(flutter::FlutterEngine* engine, HWND main_window);

// Fades [window] to full strength or to the inactive opacity, now that it is
// or is not in front. Called on WM_ACTIVATE, for every window of ours.
void FadeWindowForActivation(HWND window, bool active);

// Lets go of a window's fade once the window is gone.
void ForgetWindowFade(HWND window);

#endif  // RUNNER_BACKDROP_H_
