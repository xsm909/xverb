#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

#include "alt_beep.h"
#include "audio.h"
#include "backdrop.h"
#include "file_transfer.h"
#include "shell_menu.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // The backdrop goes on this window, not on Flutter's child view.
  RegisterBackdropChannel(flutter_controller_->engine(), GetHandle());
  // Explorer's own context menu, for the press-and-hold on the right button.
  RegisterShellMenuChannel(flutter_controller_->engine(), GetHandle());
  // The machine's own player, for the sound viewer.
  RegisterAudioChannel(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Files dragged in and out. On Flutter's own window rather than this one:
  // OLE looks for a drop target on the window under the pointer, and that is
  // the child filling the client area.
  RegisterTransferChannel(flutter_controller_->engine(),
                          flutter_controller_->view()->GetNativeWindow());
  // The keyboard belongs to the view, so a menu key is answered there.
  AnswerMenuChar(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_ && flutter_controller_->view()) {
    // Before the engine goes: OLE holds a reference to the drop target, and
    // the drop target answers by sending messages down a channel.
    UnregisterTransferChannel(flutter_controller_->view()->GetNativeWindow());
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    // The same answer as on the view, for the moments when the view has not
    // got the focus — the window is being dragged, or a native menu is up.
    // **WM_SYSCHAR is not claimed here either**: see alt_beep.h.
    case WM_MENUCHAR:
      return MAKELRESULT(0, MNC_CLOSE);
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
