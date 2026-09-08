#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Xverb", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // **The picture goes first, and it is the whole of the bug this fixes.**
  // Closing this application ends with `windowManager.destroy()`, and on
  // Windows that call is one line — `PostQuitMessage` — which ends the loop
  // above and does nothing whatever to the window. So the window stayed: on
  // screen, unpainted and answering nothing, because the loop that would
  // answer it was over, for the several seconds the engine takes to shut down
  // and the Python interpreters behind the plugins take to notice their pipes
  // have closed. Every one of those seconds read as the application hanging,
  // and on macOS none of them are visible because closing the window there
  // *is* closing the window.
  //
  // Hiding it is one call and it is instant. What follows is spent behind an
  // empty screen, which is where a teardown belongs.
  if (HWND handle = window.GetHandle()) {
    ::ShowWindow(handle, SW_HIDE);
  }

  // **And the teardown happens here, not after `CoUninitialize`.** `window` is
  // a local, so its destructor — which is what shuts the engine down — used to
  // run after the line below, on a thread whose apartment had already been
  // taken away from it. The drop target and the shell menu are COM objects the
  // engine releases on its way out, and they have to be released while COM is
  // still there to release them into.
  window.Destroy();

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
