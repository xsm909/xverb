#include "window_channel.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <algorithm>
#include <memory>
#include <optional>
#include <set>

#include "alt_beep.h"
#include "backdrop.h"

namespace {

// What the application draws at first, and the floor under how small it may
// be made: the sizes window_manager was given, in the units the interface is
// laid out in.
constexpr int kStartWidth = 1280;
constexpr int kStartHeight = 800;
constexpr int kMinWidth = 640;
constexpr int kMinHeight = 420;

// **A window that never gets shown is far worse than a missing effect**, so
// it goes up regardless if Dart never says it has painted.
constexpr UINT_PTR kRevealTimer = 0x78526576;  // 'xRev'
constexpr UINT kRevealAfterMs = 4000;

constexpr UINT_PTR kAdoptedSubclass = 0x78416470;  // 'xAdp'
constexpr UINT_PTR kViewEdgeSubclass = 0x78456467;  // 'xEdg'

HWND g_main = nullptr;
bool g_shown = false;
bool g_told_maximized = false;

// The windows the windowing API made and this side has given the
// application's look. Kept so the keyboard's news can say which window of
// ours it went to — and that it went to none of them.
std::set<HWND> g_adopted;

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

double ScaleOf(HWND hwnd) { return ::GetDpiForWindow(hwnd) / 96.0; }

// How thick the frame Windows would draw is: the strip at the sides and the
// bottom kept for the hand to resize by, and what a maximised window hangs
// off the screen by.
int FrameThickness(HWND hwnd) {
  const UINT dpi = ::GetDpiForWindow(hwnd);
  return ::GetSystemMetricsForDpi(SM_CXFRAME, dpi) +
         ::GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

// **No bar of the platform's.** The client area is the whole window but for a
// strip at the sides and the bottom, which Windows draws nothing in and keeps
// for the hand to resize by. A maximised window hangs off the screen by its
// frame, so it is drawn inside it.
void FitClientArea(HWND hwnd, NCCALCSIZE_PARAMS* params) {
  RECT& r = params->rgrc[0];
  const int frame = FrameThickness(hwnd);
  if (::IsZoomed(hwnd)) {
    r.left += frame;
    r.top += frame;
    r.right -= frame;
    r.bottom -= frame;
  } else {
    r.left += frame;
    r.right -= frame;
    r.bottom -= frame;
    // **A pixel at the top is left to the platform**, on every Windows. DWM
    // draws the window's one-pixel border along its outer edge, over whatever
    // is there: at the sides and the bottom that is the sizing frame, but a
    // client area starting at the very top put the border over the top of the
    // line the application draws round itself, and only that side vanished.
    // Measured against the build that still had window_manager: border at
    // row 0, the line at row 1. (Windows 10 also draws a white line along a
    // top edge of zero.)
    r.top += 1;
  }
}

// **The top edge is held by the hand like the other three.** The client area
// runs right up to the top, where the application draws its own bar, so
// Windows kept no strip to resize by there. The top band, a frame thick, is
// the window's own edge again. Not on a maximised window, which has no edge
// to pull. [screen] is in screen coordinates.
LRESULT TopEdgeHit(HWND top, POINT screen) {
  if (::IsZoomed(top)) return HTNOWHERE;
  RECT outer;
  ::GetWindowRect(top, &outer);
  const int frame = FrameThickness(top);
  if (screen.y < outer.top || screen.y >= outer.top + frame) return HTNOWHERE;
  if (screen.x < outer.left + 2 * frame) return HTTOPLEFT;
  if (screen.x >= outer.right - 2 * frame) return HTTOPRIGHT;
  return HTTOP;
}

// **The view lets the top band through.** Flutter's view is a child covering
// the whole client area, so a press lands on it rather than on the window
// whose edge it is; answering HTTRANSPARENT hands the hit test to the window
// underneath, which says [TopEdgeHit].
LRESULT CALLBACK ViewEdgeProc(HWND hwnd, UINT message, WPARAM wparam,
                              LPARAM lparam, UINT_PTR, DWORD_PTR) {
  if (message == WM_NCHITTEST) {
    const POINT screen = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    if (TopEdgeHit(::GetAncestor(hwnd, GA_ROOT), screen) != HTNOWHERE) {
      return HTTRANSPARENT;
    }
  }
  if (message == WM_NCDESTROY) {
    ::RemoveWindowSubclass(hwnd, ViewEdgeProc, kViewEdgeSubclass);
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}

void LetTopEdgeThrough(HWND top) {
  for (HWND view = ::GetWindow(top, GW_CHILD); view;
       view = ::GetWindow(view, GW_HWNDNEXT)) {
    ::SetWindowSubclass(view, ViewEdgeProc, kViewEdgeSubclass, 0);
  }
}

// **No buttons and no bar of the platform's**, on any window of ours: without
// the system menu DWM draws no caption buttons over the application's own.
//
// **The frame is not extended into the client area**, as window_manager
// never did. A row of it at the top (xConsole's `{0, 0, 1, 0}`) is a row DWM
// composes over the drawing, and the top of the line the application draws
// round its window vanished under it while the other three sides stayed.
// The sizing frame alone keeps the shadow.
void StripFrame(HWND hwnd) {
  ::SetWindowLongPtrW(hwnd, GWL_STYLE,
                      ::GetWindowLongPtrW(hwnd, GWL_STYLE) & ~WS_SYSMENU);
  MARGINS margins = {0, 0, 0, 0};
  ::DwmExtendFrameIntoClientArea(hwnd, &margins);
}

void Tell(const char* method,
          std::unique_ptr<flutter::EncodableValue> args = nullptr) {
  if (g_channel) g_channel->InvokeMethod(method, std::move(args));
}

bool IsOurs(HWND hwnd) {
  return hwnd && (hwnd == g_main || g_adopted.count(hwnd) > 0);
}

// **Says which window has the keyboard, by the address Dart knows it by.**
// Flutter keeps one focus for the whole application, not one per window, so
// Dart has to be told where the keyboard went and moves the focus there
// (`ProgramWindows.theKeyboardIsIn`). Nought is the first window; no address
// means none of ours has it.
void TellKeyboard(HWND to) {
  flutter::EncodableMap args;
  if (to == g_main) {
    args[flutter::EncodableValue("handle")] = flutter::EncodableValue(0);
  } else if (IsOurs(to)) {
    args[flutter::EncodableValue("handle")] =
        flutter::EncodableValue(reinterpret_cast<int64_t>(to));
  }
  Tell("keyboard", std::make_unique<flutter::EncodableValue>(args));
}

// A window of ours has gained or lost the keyboard. Losing it to another of
// ours says nothing: that one's own activation is the news, and a "none"
// between the two would fade every window for a frame.
void Activated(HWND hwnd, WPARAM wparam, LPARAM lparam) {
  const bool active = LOWORD(wparam) != WA_INACTIVE;
  FadeWindowForActivation(hwnd, active);
  if (active) {
    TellKeyboard(hwnd);
  } else if (!IsOurs(reinterpret_cast<HWND>(lparam))) {
    TellKeyboard(nullptr);
  }
}

// **A window the windowing API made is given the first window's frame.** Its
// messages are the API's, not this runner's, so the ones that decide the
// frame and the keyboard's news are taken in front of it.
LRESULT CALLBACK AdoptedProc(HWND hwnd, UINT message, WPARAM wparam,
                             LPARAM lparam, UINT_PTR, DWORD_PTR) {
  switch (message) {
    case WM_NCCALCSIZE:
      if (wparam) {
        FitClientArea(hwnd, reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam));
        return 0;
      }
      break;
    case WM_NCHITTEST: {
      const POINT screen = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      const LRESULT edge = TopEdgeHit(hwnd, screen);
      if (edge != HTNOWHERE) return edge;
      break;
    }
    case WM_NCACTIVATE:
      // The rest of the chain hears about it with nothing redrawn: there is
      // no caption left to paint, and painting one flashes it.
      ::DefSubclassProc(hwnd, message, wparam, -1);
      return 1;
    case WM_ACTIVATE:
      Activated(hwnd, wparam, lparam);
      break;
    case WM_ERASEBKGND:
      return 1;
    case WM_GETMINMAXINFO: {
      ::DefSubclassProc(hwnd, message, wparam, lparam);
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      const double scale = ScaleOf(hwnd);
      const int frame = FrameThickness(hwnd);
      info->ptMinTrackSize.x = static_cast<LONG>(kMinWidth / 2 * scale) + 2 * frame;
      info->ptMinTrackSize.y = static_cast<LONG>(kMinHeight / 2 * scale) + frame;
      return 0;
    }
    case WM_NCDESTROY:
      g_adopted.erase(hwnd);
      ForgetWindowFade(hwnd);
      ::RemoveWindowSubclass(hwnd, AdoptedProc, kAdoptedSubclass);
      break;
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}

void Reveal(HWND hwnd) {
  ::KillTimer(hwnd, kRevealTimer);
  if (!g_shown) {
    g_shown = true;
    ::ShowWindow(hwnd, SW_SHOWNORMAL);
  }
  ::SetForegroundWindow(hwnd);
}

std::optional<int64_t> IntArg(const flutter::EncodableMap& args,
                              const char* name) {
  auto it = args.find(flutter::EncodableValue(name));
  if (it == args.end()) return std::nullopt;
  if (auto v = std::get_if<int32_t>(&it->second)) return *v;
  if (auto v = std::get_if<int64_t>(&it->second)) return *v;
  return std::nullopt;
}

double DoubleArg(const flutter::EncodableMap& args, const char* name,
                 double otherwise) {
  auto it = args.find(flutter::EncodableValue(name));
  if (it == args.end()) return otherwise;
  if (auto v = std::get_if<double>(&it->second)) return *v;
  if (auto v = std::get_if<int32_t>(&it->second)) return *v;
  if (auto v = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*v);
  }
  return otherwise;
}

bool BoolArg(const flutter::EncodableMap& args, const char* name,
             bool otherwise) {
  auto it = args.find(flutter::EncodableValue(name));
  if (it == args.end()) return otherwise;
  if (auto v = std::get_if<bool>(&it->second)) return *v;
  return otherwise;
}

void HandleCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  flutter::EncodableMap args;
  if (auto map = std::get_if<flutter::EncodableMap>(call.arguments())) {
    args = *map;
  }

  // **Which window is being spoken about**: the first, or one the windowing
  // API made, by the address it handed Dart. A window that has gone in the
  // meantime is answered with nothing done to anything.
  HWND hwnd = g_main;
  if (auto address = IntArg(args, "handle")) {
    hwnd = reinterpret_cast<HWND>(*address);
    if (!::IsWindow(hwnd)) {
      result->Success();
      return;
    }
  }

  const std::string& method = call.method_name();
  if (method == "show") {
    Reveal(hwnd);
    result->Success();
  } else if (method == "raise") {
    // One view is one thing wherever it is: asked for again while a window
    // already holds it, that window comes forward.
    if (::IsIconic(hwnd)) ::ShowWindow(hwnd, SW_RESTORE);
    ::SetForegroundWindow(hwnd);
    result->Success();
  } else if (method == "handle") {
    result->Success(flutter::EncodableValue(reinterpret_cast<int64_t>(hwnd)));
  } else if (method == "adopt") {
    if (hwnd != g_main && !g_adopted.count(hwnd)) {
      g_adopted.insert(hwnd);
      StripFrame(hwnd);
      ::SetWindowSubclass(hwnd, AdoptedProc, kAdoptedSubclass, 0);
      LetTopEdgeThrough(hwnd);
      for (HWND view = ::GetWindow(hwnd, GW_CHILD); view;
           view = ::GetWindow(view, GW_HWNDNEXT)) {
        AnswerMenuChar(view);
      }
      // The frame is recomputed for the new client area to take.
      ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                         SWP_FRAMECHANGED);
      // It came up in front, before it was ours to report on.
      if (::GetForegroundWindow() == hwnd) TellKeyboard(hwnd);
    }
    result->Success();
  } else if (method == "setClientSize") {
    // The size of what the application draws, in its own units. The top left
    // stays where it is, unless [center] asks for the middle of the screen.
    const double scale = ScaleOf(hwnd);
    RECT outer, client;
    ::GetWindowRect(hwnd, &outer);
    ::GetClientRect(hwnd, &client);
    const int extra_w = (outer.right - outer.left) - client.right;
    const int extra_h = (outer.bottom - outer.top) - client.bottom;
    const int w =
        static_cast<int>(DoubleArg(args, "width", 0) * scale + 0.5) + extra_w;
    const int h =
        static_cast<int>(DoubleArg(args, "height", 0) * scale + 0.5) + extra_h;
    if (w > extra_w && h > extra_h) {
      UINT flags = SWP_NOZORDER | SWP_NOACTIVATE;
      int x = 0, y = 0;
      if (BoolArg(args, "center", false)) {
        MONITORINFO monitor = {sizeof(monitor)};
        ::GetMonitorInfoW(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                          &monitor);
        const RECT& work = monitor.rcWork;
        x = work.left + ((work.right - work.left) - w) / 2;
        y = work.top + ((work.bottom - work.top) - h) / 2;
      } else {
        flags |= SWP_NOMOVE;
      }
      ::SetWindowPos(hwnd, nullptr, x, y, w, h, flags);
    }
    result->Success();
  } else if (method == "minimize") {
    ::ShowWindow(hwnd, SW_MINIMIZE);
    result->Success();
  } else if (method == "toggleMaximize") {
    ::ShowWindow(hwnd, ::IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
    result->Success();
  } else if (method == "isMaximized") {
    result->Success(flutter::EncodableValue(::IsZoomed(hwnd) != 0));
  } else if (method == "requestClose") {
    // Through the platform, as Alt+F4 does: the first window answers it by
    // telling Dart (`closing`), so there is one way out and it is the tested
    // one.
    ::PostMessageW(hwnd, WM_CLOSE, 0, 0);
    result->Success();
  } else if (method == "destroy") {
    result->Success();
    if (hwnd == g_main) {
      // Ends the message loop; `main.cpp` hides the window at once and tears
      // the engine down behind an empty screen. Destroying the window from
      // inside a call the engine is still answering is not safe.
      ::PostQuitMessage(0);
    } else {
      ::DestroyWindow(hwnd);
    }
  } else if (method == "startDrag") {
    // The platform's own move loop, from the press that is still held. The
    // view has the mouse captured, so it lets go first; answered before the
    // loop, which does not return until the hand lets go.
    result->Success();
    ::ReleaseCapture();
    ::SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
  } else {
    // The backdrop is `xverb/backdrop`'s on this machine.
    result->NotImplemented();
  }
}

}  // namespace

void PlaceMainWindow(HWND main) {
  g_main = main;
  StripFrame(main);
  const double scale = ScaleOf(main);
  MONITORINFO monitor = {sizeof(monitor)};
  ::GetMonitorInfoW(::MonitorFromWindow(main, MONITOR_DEFAULTTOPRIMARY),
                    &monitor);
  const RECT& work = monitor.rcWork;
  const int frame = FrameThickness(main);
  int width = static_cast<int>(kStartWidth * scale) + 2 * frame;
  int height = static_cast<int>(kStartHeight * scale) + frame;
  width = (std::min)(width, static_cast<int>(work.right - work.left));
  height = (std::min)(height, static_cast<int>(work.bottom - work.top));
  const int x = work.left + ((work.right - work.left) - width) / 2;
  const int y = work.top + ((work.bottom - work.top) - height) / 2;
  ::SetWindowPos(main, nullptr, x, y, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  ::SetTimer(main, kRevealTimer, kRevealAfterMs, nullptr);
}

void RegisterWindowChannel(flutter::FlutterEngine* engine, HWND main) {
  g_main = main;
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "xverb/window",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const auto& call, auto result) { HandleCall(call, std::move(result)); });
  LetTopEdgeThrough(main);
}

void UnregisterWindowChannel() { g_channel = nullptr; }

bool HandleMainWindowMessage(HWND hwnd, UINT message, WPARAM wparam,
                             LPARAM lparam, LRESULT* result) {
  switch (message) {
    case WM_NCCALCSIZE:
      if (!wparam) return false;
      FitClientArea(hwnd, reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam));
      *result = 0;
      return true;
    case WM_NCHITTEST: {
      const POINT screen = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      const LRESULT edge = TopEdgeHit(hwnd, screen);
      if (edge == HTNOWHERE) return false;
      *result = edge;
      return true;
    }
    case WM_NCACTIVATE:
      // Nothing of the caption is left to repaint; letting Windows do it
      // flashes one. The news goes out on WM_ACTIVATE, which still arrives.
      *result = ::DefWindowProcW(hwnd, message, wparam, -1);
      return true;
    case WM_ACTIVATE:
      Tell(LOWORD(wparam) != WA_INACTIVE ? "focus" : "blur");
      Activated(hwnd, wparam, lparam);
      // Not answered: the base class still hands the focus to Flutter's view.
      return false;
    case WM_GETMINMAXINFO: {
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      const double scale = ScaleOf(hwnd);
      const int frame = FrameThickness(hwnd);
      info->ptMinTrackSize.x = static_cast<LONG>(kMinWidth * scale) + 2 * frame;
      info->ptMinTrackSize.y = static_cast<LONG>(kMinHeight * scale) + frame;
      *result = 0;
      return true;
    }
    case WM_TIMER:
      if (wparam != kRevealTimer) return false;
      Reveal(hwnd);
      *result = 0;
      return true;
    case WM_SIZE: {
      if (wparam == SIZE_MINIMIZED) return false;
      const bool maximized = wparam == SIZE_MAXIMIZED;
      if (maximized != g_told_maximized) {
        g_told_maximized = maximized;
        Tell("shape", std::make_unique<flutter::EncodableValue>(
                          flutter::EncodableMap{
                              {flutter::EncodableValue("maximized"),
                               flutter::EncodableValue(maximized)}}));
      }
      return false;
    }
    case WM_CLOSE:
      // **The window asks rather than acts.** Dart writes down what it owes
      // — the folder history above all — and answers with `destroy`. With no
      // one to ask yet, it closes as any window would.
      if (!g_channel) return false;
      Tell("closing");
      *result = 0;
      return true;
  }
  return false;
}
