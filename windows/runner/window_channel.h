#ifndef RUNNER_WINDOW_CHANNEL_H_
#define RUNNER_WINDOW_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// The application's own window, answered over `xverb/window` — the same
// channel the macOS runner answers in `MainFlutterWindow.swift`.
//
// **Why not window_manager.** A plugin reaches its window through the view it
// was registered with, and once the engine draws into several windows a call
// made through a plugin acts on the first one, or on none: the title bar of a
// detached window minimised the commander. So the window is done here, where
// every HWND of the application is in hand, and Dart names the one it means
// by the address the windowing API gave it (no address: the first window).

// Takes the platform's bar off [main], gives it the application's starting
// size in the middle of its screen, and leaves it hidden: it is shown when
// Dart says it has painted (`show`), or after a few seconds regardless.
void PlaceMainWindow(HWND main);

// Opens the channel. [main] is the window the application started in.
void RegisterWindowChannel(flutter::FlutterEngine* engine, HWND main);

// Closes it, before the engine goes.
void UnregisterWindowChannel();

// The first window's messages that are this channel's to answer: the frame,
// the hand on its edges, the smallest size, the way out. True when answered,
// with the answer in [result]. Called before Flutter's own handler, so that
// nothing a plugin does to the frame comes between.
bool HandleMainWindowMessage(HWND hwnd, UINT message, WPARAM wparam,
                             LPARAM lparam, LRESULT* result);

#endif  // RUNNER_WINDOW_CHANNEL_H_
