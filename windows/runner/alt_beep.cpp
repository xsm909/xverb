#include "alt_beep.h"

namespace {

// The view's own window procedure, put back in the chain for everything this
// does not claim. One view, so one slot: the runner never makes a second.
WNDPROC g_view_proc = nullptr;

LRESULT CALLBACK MenuCharProc(HWND window, UINT message, WPARAM wparam,
                              LPARAM lparam) {
  // Reached when a native menu really is up — the shell's own context menu is
  // the one that happens here — and the key matches nothing in it. Closing
  // without a beep is the whole of what this procedure is for.
  //
  // WM_SYSCHAR is deliberately **not** claimed: see alt_beep.h for what that
  // cost and how it was measured.
  if (message == WM_MENUCHAR) {
    return MAKELRESULT(0, MNC_CLOSE);
  }

  // Never nullptr in practice — this procedure is only ever in the chain
  // because the old one came back from the swap — but a crash in a window
  // procedure takes the application with it, so it is checked.
  if (g_view_proc == nullptr) {
    return DefWindowProc(window, message, wparam, lparam);
  }
  return CallWindowProc(g_view_proc, window, message, wparam, lparam);
}

}  // namespace

void AnswerMenuChar(HWND flutter_view) {
  if (flutter_view == nullptr || g_view_proc != nullptr) {
    return;
  }
  g_view_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      flutter_view, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(MenuCharProc)));
}
