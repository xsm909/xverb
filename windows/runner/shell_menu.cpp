#include "shell_menu.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <shlwapi.h>

#include <memory>
#include <string>

#pragma comment(lib, "shlwapi.lib")

namespace {

constexpr char kChannelName[] = "xverb/shell";
constexpr char kShowMenu[] = "showContextMenu";

// Command ids handed to the shell. Anything below this is ours, and there is
// nothing of ours, so the range simply has to avoid zero: zero is what
// TrackPopupMenu returns when the user picks nothing.
constexpr UINT kFirstCommand = 1;
constexpr UINT kLastCommand = 0x7FFF;

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;

// The shell's own menu can ask to handle window messages while it is up —
// owner drawing, and the submenus of "Send to" and "New" are built on demand.
// It says so by handing back an IContextMenu2 or 3, which then has to see
// those messages, so the window procedure is borrowed for as long as the menu
// is open.
IContextMenu2* g_context_menu2 = nullptr;
IContextMenu3* g_context_menu3 = nullptr;
WNDPROC g_previous_proc = nullptr;

LRESULT CALLBACK MenuWindowProc(HWND window, UINT message, WPARAM wparam,
                                LPARAM lparam) {
  switch (message) {
    case WM_MENUCHAR:
    case WM_MEASUREITEM:
    case WM_DRAWITEM:
    case WM_INITMENUPOPUP:
      if (g_context_menu3) {
        LRESULT result = 0;
        if (SUCCEEDED(g_context_menu3->HandleMenuMsg2(message, wparam, lparam,
                                                      &result))) {
          return result;
        }
      } else if (g_context_menu2) {
        if (SUCCEEDED(g_context_menu2->HandleMenuMsg(message, wparam, lparam))) {
          return 0;
        }
      }
      break;
    default:
      break;
  }
  return ::CallWindowProc(g_previous_proc, window, message, wparam, lparam);
}

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr,
                                         0);
  std::wstring wide(size, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        wide.data(), size);
  return wide;
}

// Builds and runs the menu. Returns an error string, or an empty one when it
// worked — including when the user dismissed it without choosing anything,
// which is a perfectly ordinary outcome and not a failure.
//
// x and y arrive as physical pixels inside the client area, because that is
// what Flutter can say without guessing; turning them into screen coordinates
// is this side's job, which knows where the window is.
std::string ShowFor(HWND window, const std::wstring& path, int x, int y) {
  POINT where = {x, y};
  ::ClientToScreen(window, &where);

  PIDLIST_ABSOLUTE pidl = nullptr;
  if (FAILED(::SHParseDisplayName(path.c_str(), nullptr, &pidl, 0, nullptr)) ||
      pidl == nullptr) {
    return "the shell does not recognise that path";
  }

  IShellFolder* parent = nullptr;
  PCUITEMID_CHILD child = nullptr;
  HRESULT hr = ::SHBindToParent(pidl, IID_IShellFolder,
                                reinterpret_cast<void**>(&parent), &child);
  if (FAILED(hr) || parent == nullptr) {
    ::CoTaskMemFree(pidl);
    return "no shell folder for that path";
  }

  IContextMenu* menu = nullptr;
  hr = parent->GetUIObjectOf(window, 1, &child, IID_IContextMenu, nullptr,
                             reinterpret_cast<void**>(&menu));
  if (FAILED(hr) || menu == nullptr) {
    parent->Release();
    ::CoTaskMemFree(pidl);
    return "no context menu for that item";
  }

  std::string error;
  HMENU popup = ::CreatePopupMenu();
  if (popup == nullptr) {
    error = "could not create the menu";
  } else {
    hr = menu->QueryContextMenu(popup, 0, kFirstCommand, kLastCommand,
                                CMF_NORMAL | CMF_EXPLORE);
    if (FAILED(hr)) {
      error = "the shell declined to fill the menu";
    } else {
      menu->QueryInterface(IID_IContextMenu2,
                           reinterpret_cast<void**>(&g_context_menu2));
      menu->QueryInterface(IID_IContextMenu3,
                           reinterpret_cast<void**>(&g_context_menu3));
      g_previous_proc = reinterpret_cast<WNDPROC>(::SetWindowLongPtr(
          window, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(MenuWindowProc)));

      // The app window has to be in front, or the menu is dismissed the
      // moment it appears.
      ::SetForegroundWindow(window);
      const int chosen = ::TrackPopupMenuEx(
          popup, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_RIGHTBUTTON, where.x,
          where.y, window, nullptr);

      ::SetWindowLongPtr(window, GWLP_WNDPROC,
                         reinterpret_cast<LONG_PTR>(g_previous_proc));
      g_previous_proc = nullptr;
      if (g_context_menu2) { g_context_menu2->Release(); g_context_menu2 = nullptr; }
      if (g_context_menu3) { g_context_menu3->Release(); g_context_menu3 = nullptr; }

      if (chosen > 0) {
        // Whatever the command starts — a terminal, a properties sheet — is a
        // new process, and Windows only lets a process take the foreground if
        // the one that started it hands over the right. Without this it opens
        // behind the window the menu was asked for from, which reads as the
        // command having done nothing.
        ::AllowSetForegroundWindow(ASFW_ANY);

        CMINVOKECOMMANDINFOEX invoke = {};
        invoke.cbSize = sizeof(invoke);
        invoke.fMask = CMIC_MASK_UNICODE;
        invoke.hwnd = window;
        invoke.lpVerb = MAKEINTRESOURCEA(chosen - kFirstCommand);
        invoke.lpVerbW = MAKEINTRESOURCEW(chosen - kFirstCommand);
        invoke.nShow = SW_SHOWNORMAL;
        if (FAILED(menu->InvokeCommand(
                reinterpret_cast<CMINVOKECOMMANDINFO*>(&invoke)))) {
          error = "the command failed";
        }
      }
    }
    ::DestroyMenu(popup);
  }

  menu->Release();
  parent->Release();
  ::CoTaskMemFree(pidl);
  return error;
}

}  // namespace

void RegisterShellMenuChannel(flutter::FlutterEngine* engine, HWND window) {
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [window](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) {
        if (call.method_name() != kShowMenu) {
          result->NotImplemented();
          return;
        }

        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (!arguments) {
          result->Error("bad-args", "expected a map");
          return;
        }

        auto text = [arguments](const char* key) -> std::string {
          auto it = arguments->find(flutter::EncodableValue(key));
          if (it == arguments->end()) return std::string();
          const auto* value = std::get_if<std::string>(&it->second);
          return value ? *value : std::string();
        };
        auto number = [arguments](const char* key) -> int {
          auto it = arguments->find(flutter::EncodableValue(key));
          if (it == arguments->end()) return 0;
          if (const auto* v = std::get_if<int32_t>(&it->second)) return *v;
          if (const auto* v = std::get_if<int64_t>(&it->second)) {
            return static_cast<int>(*v);
          }
          if (const auto* v = std::get_if<double>(&it->second)) {
            return static_cast<int>(*v);
          }
          return 0;
        };

        const std::wstring path = Widen(text("path"));
        if (path.empty()) {
          result->Error("bad-args", "no path");
          return;
        }

        const std::string error =
            ShowFor(window, path, number("x"), number("y"));
        if (error.empty()) {
          result->Success();
        } else {
          result->Error("shell-menu", error);
        }
      });
}
