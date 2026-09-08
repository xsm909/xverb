#include "file_transfer.h"

#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <shobjidl.h>

#include <memory>
#include <string>
#include <vector>

namespace {

constexpr char kChannelName[] = "xverb/transfer";

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;

// Flutter's own window. Points arriving from OLE are in screen coordinates and
// are turned into this window's, which is what Flutter draws in.
HWND g_view = nullptr;

// What Dart last said it would do with the drag now over the window, as a
// DROPEFFECT. See the note in the header: the answer is a message round trip
// and OLE wants one now, so the last one stands until the next arrives.
DWORD g_effect = DROPEFFECT_NONE;

// Set while a drag started here is running, so a drag arriving back at our own
// window is known to be ours. What that changes is one thing: our own drag may
// be told the truth about a move, because both ends of it are ours.
bool g_dragging_ours = false;

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

std::string Narrow(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                         static_cast<int>(wide.size()), nullptr,
                                         0, nullptr, nullptr);
  std::string utf8(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        utf8.data(), size, nullptr, nullptr);
  return utf8;
}

// The clipboard format Explorer invented to say whether a copy or a cut is on
// the clipboard. Registered once and answered to by every file manager on the
// machine, which is why a cut here is a move over there.
UINT PreferredDropEffectFormat() {
  static const UINT format =
      ::RegisterClipboardFormatW(CFSTR_PREFERREDDROPEFFECT);
  return format;
}

// The paths inside a CF_HDROP, wherever it came from — the clipboard or a
// drag. Empty when the object is not carrying files.
std::vector<std::string> PathsFromDrop(HDROP drop) {
  std::vector<std::string> paths;
  if (drop == nullptr) return paths;
  const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count; ++i) {
    const UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
    if (length == 0) continue;
    // One more than the characters, for the null the shell writes.
    std::vector<wchar_t> buffer(length + 1, L'\0');
    ::DragQueryFileW(drop, i, buffer.data(), length + 1);
    paths.push_back(Narrow(std::wstring(buffer.data())));
  }
  return paths;
}

std::vector<std::string> PathsFromDataObject(IDataObject* data) {
  std::vector<std::string> paths;
  if (data == nullptr) return paths;
  FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1,
                      TYMED_HGLOBAL};
  STGMEDIUM medium = {};
  if (FAILED(data->GetData(&format, &medium))) return paths;
  HDROP drop = static_cast<HDROP>(::GlobalLock(medium.hGlobal));
  paths = PathsFromDrop(drop);
  ::GlobalUnlock(medium.hGlobal);
  ::ReleaseStgMedium(&medium);
  return paths;
}

// A double-null-terminated list of paths behind a DROPFILES header: the shape
// both the clipboard and a drag carry files in.
HGLOBAL BuildDropFiles(const std::vector<std::wstring>& paths) {
  size_t characters = 1;  // the extra null that ends the list
  for (const auto& path : paths) characters += path.size() + 1;

  const size_t bytes = sizeof(DROPFILES) + characters * sizeof(wchar_t);
  HGLOBAL memory = ::GlobalAlloc(GHND, bytes);
  if (memory == nullptr) return nullptr;

  auto* header = static_cast<DROPFILES*>(::GlobalLock(memory));
  header->pFiles = sizeof(DROPFILES);
  header->fWide = TRUE;
  auto* text = reinterpret_cast<wchar_t*>(
      reinterpret_cast<BYTE*>(header) + sizeof(DROPFILES));
  for (const auto& path : paths) {
    ::memcpy(text, path.c_str(), (path.size() + 1) * sizeof(wchar_t));
    text += path.size() + 1;
  }
  *text = L'\0';
  ::GlobalUnlock(memory);
  return memory;
}

flutter::EncodableMap KeysNow(DWORD key_state) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("control"),
       flutter::EncodableValue((key_state & MK_CONTROL) != 0)},
      {flutter::EncodableValue("shift"),
       flutter::EncodableValue((key_state & MK_SHIFT) != 0)},
      {flutter::EncodableValue("alt"),
       flutter::EncodableValue(::GetKeyState(VK_MENU) < 0)},
      {flutter::EncodableValue("meta"),
       flutter::EncodableValue(::GetKeyState(VK_LWIN) < 0)},
  };
}

// A value out of a map, or null when the key is not there. Every argument
// arriving from Dart goes through this: `at` on a map throws, and a channel is
// a place where a message can always be a message we were not expecting.
const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

std::vector<std::wstring> PathsIn(const flutter::EncodableMap& map) {
  std::vector<std::wstring> paths;
  const auto* list = std::get_if<flutter::EncodableList>(Find(map, "paths"));
  if (list == nullptr) return paths;
  for (const auto& value : *list) {
    const auto* path = std::get_if<std::string>(&value);
    if (path != nullptr) paths.push_back(Widen(*path));
  }
  return paths;
}

// Where the pointer is, in the logical pixels Flutter draws in.
flutter::EncodableMap Describe(const std::vector<std::string>& paths,
                               POINTL point, DWORD key_state,
                               DWORD allowed) {
  POINT where = {point.x, point.y};
  ::ScreenToClient(g_view, &where);
  const UINT dpi = ::GetDpiForWindow(g_view);
  const double scale = dpi == 0 ? 1.0 : static_cast<double>(dpi) / 96.0;

  flutter::EncodableList list;
  for (const auto& path : paths) {
    list.push_back(flutter::EncodableValue(path));
  }

  return flutter::EncodableMap{
      {flutter::EncodableValue("x"),
       flutter::EncodableValue(static_cast<double>(where.x) / scale)},
      {flutter::EncodableValue("y"),
       flutter::EncodableValue(static_cast<double>(where.y) / scale)},
      {flutter::EncodableValue("paths"), flutter::EncodableValue(list)},
      {flutter::EncodableValue("allowsMove"),
       flutter::EncodableValue((allowed & DROPEFFECT_MOVE) != 0)},
      {flutter::EncodableValue("keys"),
       flutter::EncodableValue(KeysNow(key_state))},
  };
}

DWORD EffectNamed(const flutter::EncodableValue* answer) {
  const auto* name = std::get_if<std::string>(answer);
  if (name == nullptr) return DROPEFFECT_NONE;
  if (*name == "copy") return DROPEFFECT_COPY;
  if (*name == "move") return DROPEFFECT_MOVE;
  return DROPEFFECT_NONE;
}

// What is actually reported back to OLE.
//
// **A drag from another application is always answered "copy"**, whatever is
// about to happen to the files. Answering "move" is permission for the source
// to delete them the moment this returns, and the copying has not started yet:
// the transfer runs in Dart, asynchronously, and the deletion of the originals
// is done here after it has arrived. Our own drags are the exception, because
// both ends of those are ours.
DWORD Reported(DWORD effect) {
  if (effect == DROPEFFECT_NONE) return DROPEFFECT_NONE;
  return g_dragging_ours ? effect : DROPEFFECT_COPY;
}

void Ask(const char* method, flutter::EncodableMap arguments,
         bool remember_answer) {
  if (channel == nullptr) return;
  auto result = std::make_unique<
      flutter::MethodResultFunctions<flutter::EncodableValue>>(
      [remember_answer](const flutter::EncodableValue* answer) {
        if (remember_answer) g_effect = EffectNamed(answer);
      },
      [remember_answer](const std::string&, const std::string&,
                        const flutter::EncodableValue*) {
        if (remember_answer) g_effect = DROPEFFECT_NONE;
      },
      [remember_answer]() {
        if (remember_answer) g_effect = DROPEFFECT_NONE;
      });
  channel->InvokeMethod(
      method,
      std::make_unique<flutter::EncodableValue>(std::move(arguments)),
      std::move(result));
}

// Files being dragged over the window.
//
// Everything it knows it is told by OLE and passes on; the deciding is done in
// Dart, which is the only half that knows what is under the pointer.
class DropTarget : public IDropTarget {
 public:
  DropTarget() = default;

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
    if (riid == IID_IUnknown || riid == IID_IDropTarget) {
      *object = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }

  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG left = --references_;
    if (left == 0) delete this;
    return left;
  }

  // IDropTarget
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD key_state,
                                      POINTL point, DWORD* effect) override {
    paths_ = PathsFromDataObject(data);
    allowed_ = *effect;
    if (paths_.empty()) {
      g_effect = DROPEFFECT_NONE;
      *effect = DROPEFFECT_NONE;
      return S_OK;
    }
    Ask("dragOver", Describe(paths_, point, key_state, allowed_), true);
    *effect = Reported(g_effect);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragOver(DWORD key_state, POINTL point,
                                     DWORD* effect) override {
    if (paths_.empty()) {
      *effect = DROPEFFECT_NONE;
      return S_OK;
    }
    Ask("dragOver", Describe(paths_, point, key_state, allowed_), true);
    *effect = Reported(g_effect);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragLeave() override {
    paths_.clear();
    g_effect = DROPEFFECT_NONE;
    if (channel != nullptr) {
      channel->InvokeMethod("dragLeave", nullptr);
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD key_state,
                                 POINTL point, DWORD* effect) override {
    // Asked of the object being dropped rather than of what DragEnter saw: a
    // drag can change what it is carrying on the way across the screen.
    std::vector<std::string> paths = PathsFromDataObject(data);
    if (paths.empty() || g_effect == DROPEFFECT_NONE) {
      *effect = DROPEFFECT_NONE;
      paths_.clear();
      return S_OK;
    }

    flutter::EncodableMap arguments =
        Describe(paths, point, key_state, allowed_);
    arguments[flutter::EncodableValue("intent")] = flutter::EncodableValue(
        g_effect == DROPEFFECT_MOVE ? "move" : "copy");
    Ask("drop", std::move(arguments), false);

    *effect = Reported(g_effect);
    g_effect = DROPEFFECT_NONE;
    paths_.clear();
    return S_OK;
  }

 private:
  ULONG references_ = 1;
  std::vector<std::string> paths_;
  DWORD allowed_ = DROPEFFECT_COPY;
};

DropTarget* g_target = nullptr;

// --- The clipboard ---------------------------------------------------------

int WriteClipboard(const std::vector<std::wstring>& paths, bool move) {
  HGLOBAL files = BuildDropFiles(paths);
  if (files == nullptr) return 0;

  HGLOBAL effect = ::GlobalAlloc(GHND, sizeof(DWORD));
  if (effect != nullptr) {
    auto* value = static_cast<DWORD*>(::GlobalLock(effect));
    *value = move ? DROPEFFECT_MOVE : DROPEFFECT_COPY;
    ::GlobalUnlock(effect);
  }

  if (!::OpenClipboard(g_view)) {
    ::GlobalFree(files);
    if (effect != nullptr) ::GlobalFree(effect);
    return 0;
  }
  ::EmptyClipboard();
  ::SetClipboardData(CF_HDROP, files);
  if (effect != nullptr) {
    ::SetClipboardData(PreferredDropEffectFormat(), effect);
  }
  ::CloseClipboard();
  return static_cast<int>(::GetClipboardSequenceNumber());
}

flutter::EncodableValue ReadClipboard() {
  if (!::IsClipboardFormatAvailable(CF_HDROP)) {
    return flutter::EncodableValue();
  }
  if (!::OpenClipboard(g_view)) return flutter::EncodableValue();

  std::vector<std::string> paths =
      PathsFromDrop(static_cast<HDROP>(::GetClipboardData(CF_HDROP)));

  bool move = false;
  HANDLE effect = ::GetClipboardData(PreferredDropEffectFormat());
  if (effect != nullptr) {
    auto* value = static_cast<DWORD*>(::GlobalLock(effect));
    if (value != nullptr) {
      move = (*value & DROPEFFECT_MOVE) != 0;
      ::GlobalUnlock(effect);
    }
  }
  ::CloseClipboard();

  if (paths.empty()) return flutter::EncodableValue();

  flutter::EncodableList list;
  for (const auto& path : paths) {
    list.push_back(flutter::EncodableValue(path));
  }
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("paths"), flutter::EncodableValue(list)},
      {flutter::EncodableValue("move"), flutter::EncodableValue(move)},
      {flutter::EncodableValue("changeCount"),
       flutter::EncodableValue(
           static_cast<int>(::GetClipboardSequenceNumber()))},
  });
}

// --- Dragging out ----------------------------------------------------------

// The shell's own data object for a set of paths.
//
// Built out of the items themselves rather than assembled by hand, and that is
// what makes a drag out of this application look like a drag out of Explorer:
// the object carries everything the shell puts in one — the ghost under the
// cursor with the file icons in it, the count, the formats an application on
// the other side may ask for instead of a path.
IDataObject* DataObjectFor(const std::vector<std::wstring>& paths) {
  std::vector<PIDLIST_ABSOLUTE> ids;
  for (const auto& path : paths) {
    PIDLIST_ABSOLUTE id = nullptr;
    if (SUCCEEDED(::SHParseDisplayName(path.c_str(), nullptr, &id, 0,
                                       nullptr))) {
      ids.push_back(id);
    }
  }
  if (ids.empty()) return nullptr;

  std::vector<PCIDLIST_ABSOLUTE> read_only(ids.begin(), ids.end());
  IDataObject* object = nullptr;
  IShellItemArray* items = nullptr;
  if (SUCCEEDED(::SHCreateShellItemArrayFromIDLists(
          static_cast<UINT>(read_only.size()), read_only.data(), &items))) {
    items->BindToHandler(nullptr, BHID_DataObject, IID_IDataObject,
                         reinterpret_cast<void**>(&object));
    items->Release();
  }
  for (auto* id : ids) ::CoTaskMemFree(id);
  return object;
}

void StartDrag(const flutter::EncodableMap& arguments,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) {
  std::vector<std::wstring> paths = PathsIn(arguments);
  if (paths.empty()) return result->Success();

  const auto* allow_move = std::get_if<bool>(Find(arguments, "allowMove"));
  DWORD allowed = DROPEFFECT_COPY;
  if (allow_move == nullptr || *allow_move) allowed |= DROPEFFECT_MOVE;

  IDataObject* object = DataObjectFor(paths);
  if (object == nullptr) return result->Success();

  DWORD did = DROPEFFECT_NONE;
  g_dragging_ours = true;
  // Whoever takes the files may need to ask something — Explorer's "there is
  // already a file with the same name" above all — and a window it puts up
  // while we hold the foreground opens *behind* ours, where it looks as though
  // the drag did nothing. This is Windows' own way of handing that right over:
  // not forcing anybody's window to the front, but ceasing to be the reason
  // theirs cannot come. The Mac needed the same thing said a different way.
  ::AllowSetForegroundWindow(ASFW_ANY);
  // The shell's drag loop rather than DoDragDrop directly: this is the call
  // that draws the ghost, and a drag with no ghost is a drag nobody believes
  // has started. It pumps the window's messages while it runs, so the
  // application goes on drawing and our own drop target goes on answering.
  ::SHDoDragDrop(g_view, object, nullptr, allowed, &did);
  g_dragging_ours = false;
  object->Release();

  if (did == DROPEFFECT_MOVE) {
    result->Success(flutter::EncodableValue("move"));
  } else if (did == DROPEFFECT_NONE) {
    result->Success();
  } else {
    result->Success(flutter::EncodableValue("copy"));
  }
}

}  // namespace

void RegisterTransferChannel(flutter::FlutterEngine* engine, HWND view) {
  g_view = view;
  // RegisterDragDrop needs OLE, not merely COM. The runner has already put the
  // thread into an apartment, so this is the rest of the initialisation and
  // returns S_FALSE for the part that was already done.
  ::OleInitialize(nullptr);

  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  g_target = new DropTarget();
  ::RegisterDragDrop(view, g_target);

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());

        if (call.method_name() == "ping") {
          result->Success();
        } else if (call.method_name() == "clipboardSerial") {
          result->Success(flutter::EncodableValue(
              static_cast<int>(::GetClipboardSequenceNumber())));
        } else if (call.method_name() == "clipboardRead") {
          result->Success(ReadClipboard());
        } else if (call.method_name() == "clipboardWrite") {
          if (arguments == nullptr) {
            return result->Success(flutter::EncodableValue(0));
          }
          const std::vector<std::wstring> paths = PathsIn(*arguments);
          const auto* move = std::get_if<bool>(Find(*arguments, "move"));
          result->Success(flutter::EncodableValue(
              WriteClipboard(paths, move != nullptr && *move)));
        } else if (call.method_name() == "startDrag") {
          if (arguments == nullptr) return result->Success();
          StartDrag(*arguments, std::move(result));
        } else {
          result->NotImplemented();
        }
      });
}

void UnregisterTransferChannel(HWND view) {
  ::RevokeDragDrop(view);
  if (g_target != nullptr) {
    g_target->Release();
    g_target = nullptr;
  }
  channel = nullptr;
  g_view = nullptr;
}
