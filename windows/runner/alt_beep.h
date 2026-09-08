#ifndef RUNNER_ALT_BEEP_H_
#define RUNNER_ALT_BEEP_H_

#include <windows.h>

// Answers WM_MENUCHAR, so a native menu that cannot match a key closes instead
// of complaining about it.
//
// **This used to answer WM_SYSCHAR as well, and that took Alt+<letter> away
// from the whole application.** Measured on Windows 11 on 2026-08-17, with a
// probe printing every key event the framework was handed: with the branch in,
// Alt+F delivered `Alt Left` and nothing else — the letter never arrived, so no
// menu opened, while Alt+F1 (which has no character message) worked throughout.
// The reason is that Flutter holds a key down whose character message is still
// coming and dispatches the two together; answering WM_SYSCHAR here meant the
// second half never arrived and the first was never sent on.
//
// And the beep it was written for does not need it: with the branch gone, the
// endpoint meter reads 0.0000 on Alt+F, Alt+Z, Alt+Q and Alt+Y against 0.3457
// for a control `MessageBeep`. Flutter consumes the character message as part
// of the key, so `DefWindowProc` — the only thing that ever beeped — does not
// see it.
//
// Keyboard messages go to the window with the focus, which is Flutter's child
// view rather than the top-level window, so the view is where this has to be
// fitted. Call it once, with the handle from
// `FlutterViewController::view()->GetNativeWindow()`.
void AnswerMenuChar(HWND flutter_view);

#endif  // RUNNER_ALT_BEEP_H_
