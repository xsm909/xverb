#include "backdrop.h"

#include <dwmapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <map>
#include <memory>

namespace {

// **A window not in front is see-through, by as much as the settings say** —
// its content, its glass and its edge together, since this is the platform's
// layered-window alpha and that covers everything in a window. Fading the
// interface alone left the acrylic behind it untouched, which read as the
// backdrop getting thinner rather than as the window stepping back.
//
// **This is one of the fade's two layers, and the shallower one.** The
// interface steps back further still, in the widget tree, because fading glass
// and interface by one figure lets the desktop through sharp and reads as the
// background fading harder than the content. What arrives here is the window's
// figure alone; the pair and the arithmetic are Dart's, in
// `kWindowShareOfTheFade`. The `content` figure the call also carries cannot be
// applied on this platform — there is one alpha for a whole window and nothing
// to aim at the drawing by itself — so Flutter carries that half here, while on
// macOS the runner fades the Flutter view and the window separately.
//
// At full strength the window stops being layered at all: a layered window
// loses its acrylic, and the window in front should keep it.
double g_inactive_opacity = 1.0;
double g_fade_ms = 240;
constexpr UINT_PTR kFadeTimer = 0x78466164;  // 'xFad'

struct Fade {
  double from = 1;
  double to = 1;
  double now = 1;
  ULONGLONG start = 0;
};
// **One fade per window.** A detached view's window steps back and forward
// on its own, and the setting reaches every window that is behind.
struct WindowFade {
  Fade fade;
  bool active = true;
};
std::map<HWND, WindowFade> g_fades;

void SetAlpha(HWND hwnd, double alpha) {
  LONG_PTR ex = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  if (alpha >= 0.999) {
    if (ex & WS_EX_LAYERED) {
      ::SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
    }
    return;
  }
  if (!(ex & WS_EX_LAYERED)) {
    ::SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
  }
  ::SetLayeredWindowAttributes(hwnd, 0, static_cast<BYTE>(alpha * 255 + 0.5),
                               LWA_ALPHA);
}

void CALLBACK FadeStep(HWND hwnd, UINT, UINT_PTR, DWORD) {
  auto it = g_fades.find(hwnd);
  if (it == g_fades.end() || !::IsWindow(hwnd)) {
    ::KillTimer(hwnd, kFadeTimer);
    return;
  }
  Fade& fade = it->second.fade;
  const double elapsed = static_cast<double>(::GetTickCount64() - fade.start);
  const double t = g_fade_ms <= 0 ? 1.0 : std::min(1.0, elapsed / g_fade_ms);
  const double eased = 1 - (1 - t) * (1 - t) * (1 - t);  // ease out
  fade.now = fade.from + (fade.to - fade.from) * eased;
  SetAlpha(hwnd, fade.now);
  if (t >= 1) ::KillTimer(hwnd, kFadeTimer);
}

void FadeTo(HWND hwnd, double to) {
  Fade& fade = g_fades[hwnd].fade;
  if (fade.to == to && fade.now == to) return;
  fade.from = fade.now;
  fade.to = to;
  fade.start = ::GetTickCount64();
  if (g_fade_ms <= 0) {
    FadeStep(hwnd, 0, kFadeTimer, 0);
    return;
  }
  ::SetTimer(hwnd, kFadeTimer, 15, FadeStep);
}

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

// DWMWA_SYSTEMBACKDROP_TYPE and its DWMSBT_NONE.
constexpr DWORD kSystemBackdropType = 38;
constexpr int kSystemBackdropNone = 1;

// ACCENT_ACRYLICBLURBEHIND.
constexpr int kAccentAcrylicBlurBehind = 4;

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

void RegisterBackdropChannel(flutter::FlutterEngine* engine,
                             HWND main_window) {
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [main_window](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        if (call.method_name() == "inactiveOpacity") {
          // How see-through the window is while not in front, and how long
          // the fade takes; a window already behind goes to it at once.
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          auto number = [arguments](const char* key, double fallback) {
            if (!arguments) return fallback;
            auto it = arguments->find(flutter::EncodableValue(key));
            if (it == arguments->end()) return fallback;
            if (const auto* v = std::get_if<double>(&it->second)) return *v;
            if (const auto* v = std::get_if<int32_t>(&it->second)) {
              return static_cast<double>(*v);
            }
            if (const auto* v = std::get_if<int64_t>(&it->second)) {
              return static_cast<double>(*v);
            }
            return fallback;
          };
          g_inactive_opacity = std::clamp(number("value", 1.0), 0.1, 1.0);
          g_fade_ms = std::max(0.0, number("ms", 220));
          for (auto& [window, fade] : g_fades) {
            if (!fade.active && ::IsWindow(window)) {
              FadeTo(window, g_inactive_opacity);
            }
          }
          result->Success();
          return;
        }
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

        // **Which window wears it**: the first, or a detached view's, by the
        // address the windowing API handed Dart.
        HWND window = main_window;
        {
          auto it = arguments->find(flutter::EncodableValue("handle"));
          if (it != arguments->end()) {
            int64_t address = 0;
            if (const auto* v = std::get_if<int64_t>(&it->second)) address = *v;
            if (const auto* v = std::get_if<int32_t>(&it->second)) address = *v;
            window = reinterpret_cast<HWND>(address);
          }
          if (!::IsWindow(window)) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
        }

        const int state = integer("state", 0);
        const int argb = integer("color", 0);
        const bool dark = boolean("dark", true);

        BOOL dark_mode = dark ? TRUE : FALSE;
        ::DwmSetWindowAttribute(window, kUseImmersiveDarkMode, &dark_mode,
                                sizeof(dark_mode));

        // **Not DWM's system backdrop**: it will not paint on a window whose
        // frame we removed, and left set it only gets in the accent's way.
        int no_system_backdrop = kSystemBackdropNone;
        ::DwmSetWindowAttribute(window, kSystemBackdropType,
                                &no_system_backdrop,
                                sizeof(no_system_backdrop));

        // Flag 2 makes DWM honour the gradient colour as a tint. **Not for
        // acrylic**: there the tint is laid down as an opaque layer of light,
        // whatever its alpha, and the window came out the tint's colour all
        // over with nothing of the desktop's brightness in it — a dark slab.
        // With flag 0 and no colour the acrylic is Windows' own, and the
        // panels drawn above it are what tint it. This is how xConsole does
        // it, and the two are meant to look alike side by side.
        const bool is_acrylic = state == kAccentAcrylicBlurBehind;
        ACCENT_POLICY accent = {};
        accent.state = state;
        accent.flags = is_acrylic ? 0 : 2;
        accent.gradient_color =
            is_acrylic
                ? 0
                : (static_cast<DWORD>((argb >> 24) & 0xFF) << 24) |  // A
                      (static_cast<DWORD>((argb) & 0xFF) << 16) |    // B
                      (static_cast<DWORD>((argb >> 8) & 0xFF) << 8) |  // G
                      (static_cast<DWORD>((argb >> 16) & 0xFF));       // R
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

void FadeWindowForActivation(HWND window, bool active) {
  g_fades[window].active = active;
  FadeTo(window, active ? 1.0 : g_inactive_opacity);
}

void ForgetWindowFade(HWND window) {
  ::KillTimer(window, kFadeTimer);
  g_fades.erase(window);
}
