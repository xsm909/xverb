#ifndef RUNNER_SHELL_MENU_H_
#define RUNNER_SHELL_MENU_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// Shows Explorer's own context menu for a file, over the `xverb/shell`
// channel.
//
// Not a reimplementation of it: the shell builds the menu, fills it with
// whatever the machine has installed — the archiver, the version control
// client, "Open with" — and runs whichever command the user picks. The app
// only says which file and where.
void RegisterShellMenuChannel(flutter::FlutterEngine* engine, HWND window);

#endif  // RUNNER_SHELL_MENU_H_
