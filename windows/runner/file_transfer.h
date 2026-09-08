#ifndef RUNNER_FILE_TRANSFER_H_
#define RUNNER_FILE_TRANSFER_H_

#include <flutter/flutter_engine.h>
#include <windows.h>

// The file clipboard and drag-and-drop, over the `xverb/transfer`
// channel.
//
// Not a reimplementation of either: the shell builds the data object, draws
// the ghost under the cursor and runs the drag loop; OLE decides which window
// a drop belongs to. What this adds is the one thing the shell cannot know —
// which folder inside the application the pointer is over, and therefore
// whether the drop is a copy, a move or nothing at all. That question is asked
// of Dart and answered from there.
//
// [view] is Flutter's own child window, not the top-level one: it fills the
// client area, so a point inside it is a point in the coordinates Flutter
// draws in, and it is the window OLE finds under the pointer.
void RegisterTransferChannel(flutter::FlutterEngine* engine, HWND view);

// Lets go of the drop target. Called before the window goes, because OLE holds
// a reference to it and to the window it was registered on.
void UnregisterTransferChannel(HWND view);

#endif  // RUNNER_FILE_TRANSFER_H_
