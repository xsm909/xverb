#include "backdrop.h"

#include <dwmapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace {

// None of this is in the SDK headers. `SetWindowCompositionAttribute` has been
// undocumented since Windows 8 and is still the only way to make a Flutter
// window translucent: DWM's own system backdrops refuse to paint on a window
// whose frame we removed in order to draw our own title bar.
enum WINDOWCOMPOSITIONATTRIB {
  WCA_ACCENT_POLICY = 19,
};

struct WINDOWCOMPOSITIONATTRIBDATA {
  WINDOWCOMPOSITIONATTRIB attribute;
  PVOID data;
  SIZE_T size;
};

struct ACCENT_POLICY {
  int state;
  int flags;
  // 0xAABBGGRR, not the ARGB Dart hands us.
  DWORD gradient_color;
  int animation_id;
};

using SetWindowCompositionAttributeProc =
    BOOL(WINAPI*)(HWND, WINDOWCOMPOSITIONATTRIBDATA*);

// DwmSetWindowAttribute's dark-mode flag, which decides the colour of the
// window's shadow and border.
constexpr DWORD kUseImmersiveDarkMode = 20;

constexpr char kChannelName[] = "xverb/backdrop";
constexpr char kSetAccent[] = "setAccent";

SetWindowCompositionAttributeProc ResolveSetWindowCompositionAttribute() {
  HMODULE user32 = ::GetModuleHandleW(L"user32.dll");
  if (!user32) {
    return nullptr;
  }
  return reinterpret_cast<SetWindowCompositionAttributeProc>(
      ::GetProcAddress(user32, "SetWindowCompositionAttribute"));
}

// Keeps the channel alive for the process; the engine outlives it.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;

}  // namespace

void RegisterBackdropChannel(flutter::FlutterEngine* engine, HWND window) {
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [window](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) {
        if (call.method_name() != kSetAccent) {
          result->NotImplemented();
          return;
        }

        static SetWindowCompositionAttributeProc set_attribute =
            ResolveSetWindowCompositionAttribute();
        if (!set_attribute) {
          // Dart falls back to `flutter_acrylic` when this fails, so an old
          // or locked-down Windows still gets whatever backdrop it can.
          result->Error("unavailable", "SetWindowCompositionAttribute missing");
          return;
        }

        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (!arguments) {
          result->Error("bad-args", "expected a map");
          return;
        }

        auto integer = [arguments](const char* key, int fallback) {
          auto it = arguments->find(flutter::EncodableValue(key));
          if (it == arguments->end()) {
            return fallback;
          }
          if (const auto* value = std::get_if<int32_t>(&it->second)) {
            return static_cast<int>(*value);
          }
          if (const auto* value = std::get_if<int64_t>(&it->second)) {
            return static_cast<int>(*value);
          }
          return fallback;
        };
        auto boolean = [arguments](const char* key, bool fallback) {
          auto it = arguments->find(flutter::EncodableValue(key));
          if (it == arguments->end()) {
            return fallback;
          }
          const auto* value = std::get_if<bool>(&it->second);
          return value ? *value : fallback;
        };

        const int state = integer("state", 0);
        const int argb = integer("color", 0);
        const bool dark = boolean("dark", true);

        BOOL dark_mode = dark ? TRUE : FALSE;
        ::DwmSetWindowAttribute(window, kUseImmersiveDarkMode, &dark_mode,
                                sizeof(dark_mode));

        // Flag 2 is what every implementation of this passes; it is the one
        // that makes DWM honour the gradient colour as a tint.
        ACCENT_POLICY accent = {};
        accent.state = state;
        accent.flags = 2;
        accent.gradient_color =
            (static_cast<DWORD>((argb >> 24) & 0xFF) << 24) |  // A
            (static_cast<DWORD>((argb) & 0xFF) << 16) |        // B
            (static_cast<DWORD>((argb >> 8) & 0xFF) << 8) |    // G
            (static_cast<DWORD>((argb >> 16) & 0xFF));         // R
        accent.animation_id = 0;

        WINDOWCOMPOSITIONATTRIBDATA data = {};
        data.attribute = WCA_ACCENT_POLICY;
        data.data = &accent;
        data.size = sizeof(accent);

        // The single write the whole file exists for.
        const BOOL ok = set_attribute(window, &data);
        result->Success(flutter::EncodableValue(ok != FALSE));
      });
}
