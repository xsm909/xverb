#include "file_transfer.h"

#include <gio/gio.h>

#include <string>
#include <vector>

namespace {

constexpr char kChannelName[] = "xverb/transfer";

// The two things files travel as on this desktop. The first is the standard
// one every application understands; the second is how the file managers say
// whether a copy or a cut was made, and is what makes a cut here a move in
// Nautilus.
constexpr char kUriList[] = "text/uri-list";
constexpr char kGnomeCopied[] = "x-special/gnome-copied-files";

FlMethodChannel* g_channel = nullptr;
GtkWidget* g_view = nullptr;

// What Dart last said it would do with the drag now over the window. GTK wants
// an answer inside the motion handler and Dart is a message away, so the last
// answer stands until the next arrives — one frame behind a pointer, which is
// invisible, where waiting would not be.
GdkDragAction g_action = static_cast<GdkDragAction>(0);

// The files being dragged over the window. GTK only hands them over when they
// are asked for, so they are asked for once when the drag arrives and kept for
// as long as it is here.
std::vector<std::string> g_incoming;
bool g_asked_for_incoming = false;

// Set while a drag started here is running. Our own drag may be told the truth
// about a move, because both ends of it are ours; a drag from another
// application is always answered "copy" — see the note in the Windows runner,
// which is the same rule for the same reason.
bool g_dragging_ours = false;

// What is on our clipboard, and the serial that says whether it is still ours.
std::vector<std::string> g_clipboard;
bool g_clipboard_cut = false;
int64_t g_serial = 1;
GObject* g_owner = nullptr;

// The pending answer to a `startDrag` call, completed when GTK says the drag
// has ended.
FlMethodCall* g_drag_call = nullptr;
std::vector<std::string> g_outgoing;

std::string percent_encoded(const std::string& path) {
  g_autofree gchar* uri = g_filename_to_uri(path.c_str(), nullptr, nullptr);
  return uri == nullptr ? std::string() : std::string(uri);
}

std::string path_of_uri(const std::string& uri) {
  g_autofree gchar* path = g_filename_from_uri(uri.c_str(), nullptr, nullptr);
  return path == nullptr ? std::string() : std::string(path);
}

std::vector<std::string> paths_from_uri_list(const gchar* text) {
  std::vector<std::string> paths;
  if (text == nullptr) return paths;
  g_auto(GStrv) lines = g_strsplit(text, "\n", -1);
  for (gchar** line = lines; *line != nullptr; ++line) {
    g_strstrip(*line);
    if (**line == '\0' || **line == '#') continue;
    std::string path = path_of_uri(*line);
    if (!path.empty()) paths.push_back(path);
  }
  return paths;
}

FlValue* paths_value(const std::vector<std::string>& paths) {
  FlValue* list = fl_value_new_list();
  for (const auto& path : paths) {
    fl_value_append_take(list, fl_value_new_string(path.c_str()));
  }
  return list;
}

// Which modifiers are held, asked of the pointer rather than of an event:
// during a drag the keyboard is not sending us anything.
FlValue* keys_now(GdkDragContext* context) {
  GdkModifierType mask = static_cast<GdkModifierType>(0);
  GdkDevice* device = gdk_drag_context_get_device(context);
  GdkWindow* window =
      g_view == nullptr ? nullptr : gtk_widget_get_window(g_view);
  if (device != nullptr && window != nullptr) {
    gdk_window_get_device_position(window, device, nullptr, nullptr, &mask);
  }
  FlValue* keys = fl_value_new_map();
  fl_value_set_string_take(keys, "control",
                           fl_value_new_bool((mask & GDK_CONTROL_MASK) != 0));
  fl_value_set_string_take(keys, "shift",
                           fl_value_new_bool((mask & GDK_SHIFT_MASK) != 0));
  fl_value_set_string_take(keys, "alt",
                           fl_value_new_bool((mask & GDK_MOD1_MASK) != 0));
  fl_value_set_string_take(keys, "meta",
                           fl_value_new_bool((mask & GDK_SUPER_MASK) != 0));
  return keys;
}

FlValue* describe(GdkDragContext* context, gint x, gint y) {
  FlValue* map = fl_value_new_map();
  // GTK counts in the same logical units Flutter draws in — the scale factor
  // is applied below both of them — so the point goes across as it arrived.
  fl_value_set_string_take(map, "x", fl_value_new_float(x));
  fl_value_set_string_take(map, "y", fl_value_new_float(y));
  fl_value_set_string_take(map, "paths", paths_value(g_incoming));
  fl_value_set_string_take(
      map, "allowsMove",
      fl_value_new_bool(
          (gdk_drag_context_get_actions(context) & GDK_ACTION_MOVE) != 0));
  fl_value_set_string_take(map, "keys", keys_now(context));
  return map;
}

GdkDragAction action_named(FlValue* answer) {
  if (answer == nullptr || fl_value_get_type(answer) != FL_VALUE_TYPE_STRING) {
    return static_cast<GdkDragAction>(0);
  }
  const std::string name(fl_value_get_string(answer));
  if (name == "copy") return GDK_ACTION_COPY;
  if (name == "move") return GDK_ACTION_MOVE;
  return static_cast<GdkDragAction>(0);
}

// A drag from another application is answered "copy" whatever is about to
// happen to the files: on this desktop a move hands the source the deletion,
// and the copying has not started yet.
GdkDragAction reported() {
  if (g_action == 0) return static_cast<GdkDragAction>(0);
  return g_dragging_ours ? g_action : GDK_ACTION_COPY;
}

void remember_answer(GObject* object, GAsyncResult* result, gpointer) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(object), result, &error);
  if (response == nullptr || !FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
    g_action = static_cast<GdkDragAction>(0);
    return;
  }
  g_action = action_named(
      fl_method_success_response_get_result(FL_METHOD_SUCCESS_RESPONSE(response)));
}

void ask(const char* method, FlValue* arguments, bool remember) {
  if (g_channel == nullptr) {
    fl_value_unref(arguments);
    return;
  }
  fl_method_channel_invoke_method(g_channel, method, arguments, nullptr,
                                  remember ? remember_answer : nullptr,
                                  nullptr);
  fl_value_unref(arguments);
}

// --- A drag arriving -------------------------------------------------------

gboolean on_motion(GtkWidget* widget, GdkDragContext* context, gint x, gint y,
                   guint time, gpointer) {
  if (!g_asked_for_incoming) {
    g_asked_for_incoming = true;
    GdkAtom target = gtk_drag_dest_find_target(widget, context, nullptr);
    if (target != GDK_NONE) gtk_drag_get_data(widget, context, target, time);
  }
  if (!g_incoming.empty()) {
    ask("dragOver", describe(context, x, y), true);
  }
  gdk_drag_status(context, reported(), time);
  return TRUE;
}

void on_leave(GtkWidget*, GdkDragContext*, guint, gpointer) {
  g_incoming.clear();
  g_asked_for_incoming = false;
  g_action = static_cast<GdkDragAction>(0);
  if (g_channel != nullptr) {
    fl_method_channel_invoke_method(g_channel, "dragLeave", nullptr, nullptr,
                                    nullptr, nullptr);
  }
}

// Whether the data now being received is the drop itself rather than the look
// ahead taken when the drag arrived.
bool g_dropping = false;
gint g_drop_x = 0;
gint g_drop_y = 0;

gboolean on_drop(GtkWidget* widget, GdkDragContext* context, gint x, gint y,
                 guint time, gpointer) {
  GdkAtom target = gtk_drag_dest_find_target(widget, context, nullptr);
  if (target == GDK_NONE || g_action == 0) {
    gtk_drag_finish(context, FALSE, FALSE, time);
    return FALSE;
  }
  g_dropping = true;
  g_drop_x = x;
  g_drop_y = y;
  gtk_drag_get_data(widget, context, target, time);
  return TRUE;
}

void on_data_received(GtkWidget*, GdkDragContext* context, gint, gint,
                      GtkSelectionData* data, guint, guint time, gpointer) {
  g_autofree gchar* text =
      reinterpret_cast<gchar*>(gtk_selection_data_get_text(data));
  if (text != nullptr) {
    g_incoming = paths_from_uri_list(text);
  } else {
    const guchar* raw = gtk_selection_data_get_data(data);
    if (raw != nullptr) {
      g_incoming = paths_from_uri_list(reinterpret_cast<const gchar*>(raw));
    }
  }

  if (!g_dropping) return;
  g_dropping = false;

  if (g_incoming.empty()) {
    gtk_drag_finish(context, FALSE, FALSE, time);
    return;
  }

  FlValue* arguments = describe(context, g_drop_x, g_drop_y);
  fl_value_set_string_take(
      arguments, "intent",
      fl_value_new_string(g_action == GDK_ACTION_MOVE ? "move" : "copy"));
  ask("drop", arguments, false);

  // Never `delete`, whatever the drop was: the originals are taken away here
  // once the copy has arrived, not by whoever handed them over.
  gtk_drag_finish(context, TRUE, FALSE, time);
  g_incoming.clear();
  g_asked_for_incoming = false;
  g_action = static_cast<GdkDragAction>(0);
}

// --- A drag leaving --------------------------------------------------------

void on_drag_data_get(GtkWidget*, GdkDragContext*, GtkSelectionData* data,
                      guint, guint, gpointer) {
  std::string uris;
  for (const auto& path : g_outgoing) {
    const std::string uri = percent_encoded(path);
    if (uri.empty()) continue;
    uris += uri;
    uris += "\r\n";
  }
  gtk_selection_data_set(data, gtk_selection_data_get_target(data), 8,
                         reinterpret_cast<const guchar*>(uris.c_str()),
                         static_cast<gint>(uris.size()));
}

void finish_drag(const char* answer) {
  if (g_drag_call == nullptr) return;
  g_autoptr(FlMethodCall) call = g_drag_call;
  g_drag_call = nullptr;
  g_dragging_ours = false;
  g_autoptr(FlValue) value =
      answer == nullptr ? nullptr : fl_value_new_string(answer);
  g_autoptr(GError) error = nullptr;
  fl_method_call_respond_success(call, value, &error);
}

void on_drag_end(GtkWidget*, GdkDragContext* context, gpointer) {
  const GdkDragAction did = gdk_drag_context_get_selected_action(context);
  finish_drag(did & GDK_ACTION_MOVE ? "move"
                                    : (did & GDK_ACTION_COPY ? "copy" : nullptr));
}

gboolean on_drag_failed(GtkWidget*, GdkDragContext*, GtkDragResult, gpointer) {
  finish_drag(nullptr);
  return FALSE;
}

// --- The clipboard ---------------------------------------------------------

GtkClipboard* clipboard() {
  return gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
}

void on_clipboard_get(GtkClipboard*, GtkSelectionData* data, guint info,
                      gpointer) {
  std::string payload;
  if (info == 1) {
    // The file managers' own format: the word first, then the files.
    payload = g_clipboard_cut ? "cut\n" : "copy\n";
    for (size_t i = 0; i < g_clipboard.size(); ++i) {
      if (i > 0) payload += "\n";
      payload += percent_encoded(g_clipboard[i]);
    }
  } else {
    for (const auto& path : g_clipboard) {
      payload += percent_encoded(path);
      payload += "\r\n";
    }
  }
  gtk_selection_data_set(data, gtk_selection_data_get_target(data), 8,
                         reinterpret_cast<const guchar*>(payload.c_str()),
                         static_cast<gint>(payload.size()));
}

void on_clipboard_clear(GtkClipboard*, gpointer) {
  g_clipboard.clear();
}

int64_t write_clipboard(const std::vector<std::string>& paths, bool cut) {
  g_clipboard = paths;
  g_clipboard_cut = cut;

  GtkTargetEntry targets[2] = {
      {const_cast<gchar*>(kUriList), 0, 0},
      {const_cast<gchar*>(kGnomeCopied), 0, 1},
  };
  gtk_clipboard_set_with_owner(clipboard(), targets, 2, on_clipboard_get,
                               on_clipboard_clear, g_owner);
  return ++g_serial;
}

// Whether what is on the clipboard now is what we last put there.
//
// This desktop has no clipboard serial of its own — the number every
// application on Windows and macOS can read has no counterpart here — so the
// question is asked the only way it can be: are we still the owner? If we are,
// the serial handed out is the one we wrote with; if we are not, it is a
// number that cannot match, which is exactly what "somebody else's" means to
// the half that reads it.
int64_t serial_now() {
  return gtk_clipboard_get_owner(clipboard()) == g_owner ? g_serial
                                                         : g_serial + 1;
}

FlValue* read_clipboard() {
  GdkAtom gnome = gdk_atom_intern_static_string(kGnomeCopied);
  bool cut = false;
  std::vector<std::string> paths;

  // Freed by hand rather than with g_autoptr: the cleanup for this type is
  // not declared in every GTK 3 the application still builds against.
  GtkSelectionData* special =
      gtk_clipboard_wait_for_contents(clipboard(), gnome);
  if (special != nullptr) {
    const guchar* raw = gtk_selection_data_get_data(special);
    const gint length = gtk_selection_data_get_length(special);
    if (raw != nullptr && length > 0) {
      const std::string text(reinterpret_cast<const gchar*>(raw),
                             static_cast<size_t>(length));
      const size_t line = text.find('\n');
      if (line != std::string::npos) {
        cut = text.compare(0, line, "cut") == 0;
        paths = paths_from_uri_list(text.substr(line + 1).c_str());
      }
    }
    gtk_selection_data_free(special);
  }

  if (paths.empty()) {
    g_auto(GStrv) uris = gtk_clipboard_wait_for_uris(clipboard());
    if (uris != nullptr) {
      for (gchar** uri = uris; *uri != nullptr; ++uri) {
        std::string path = path_of_uri(*uri);
        if (!path.empty()) paths.push_back(path);
      }
    }
  }

  if (paths.empty()) return fl_value_new_null();

  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "paths", paths_value(paths));
  fl_value_set_string_take(map, "move", fl_value_new_bool(cut));
  fl_value_set_string_take(map, "changeCount", fl_value_new_int(serial_now()));
  return map;
}

// --- The channel -----------------------------------------------------------

std::vector<std::string> paths_in(FlValue* args) {
  std::vector<std::string> paths;
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return paths;
  }
  FlValue* list = fl_value_lookup_string(args, "paths");
  if (list == nullptr || fl_value_get_type(list) != FL_VALUE_TYPE_LIST) {
    return paths;
  }
  for (size_t i = 0; i < fl_value_get_length(list); ++i) {
    FlValue* item = fl_value_get_list_value(list, i);
    if (fl_value_get_type(item) == FL_VALUE_TYPE_STRING) {
      paths.push_back(fl_value_get_string(item));
    }
  }
  return paths;
}

bool flag_in(FlValue* args, const char* name, bool fallback) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return fallback;
  }
  FlValue* value = fl_value_lookup_string(args, name);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
    return fallback;
  }
  return fl_value_get_bool(value);
}

void start_drag(FlMethodCall* call, FlValue* args) {
  g_outgoing = paths_in(args);
  g_autoptr(GError) error = nullptr;
  if (g_outgoing.empty() || g_view == nullptr) {
    fl_method_call_respond_success(call, nullptr, &error);
    return;
  }

  const bool allow_move = flag_in(args, "allowMove", true);
  GtkTargetList* targets = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add(targets, gdk_atom_intern_static_string(kUriList), 0, 0);

  GdkEvent* event = gtk_get_current_event();
  GdkDragAction actions = allow_move
                              ? static_cast<GdkDragAction>(GDK_ACTION_COPY |
                                                           GDK_ACTION_MOVE)
                              : GDK_ACTION_COPY;

  g_drag_call = FL_METHOD_CALL(g_object_ref(call));
  g_dragging_ours = true;
  GdkDragContext* context =
      gtk_drag_begin_with_coordinates(g_view, targets, actions, 1, event, -1, -1);
  gtk_target_list_unref(targets);
  if (event != nullptr) gdk_event_free(event);

  if (context == nullptr) {
    finish_drag(nullptr);
    return;
  }
  // The file's own icon under the pointer, as a drag out of the desktop's own
  // file manager has.
  g_autoptr(GFile) file = g_file_new_for_path(g_outgoing.front().c_str());
  g_autoptr(GFileInfo) info =
      g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_ICON,
                        G_FILE_QUERY_INFO_NONE, nullptr, nullptr);
  GIcon* icon = info == nullptr ? nullptr : g_file_info_get_icon(info);
  if (icon != nullptr) {
    gtk_drag_set_icon_gicon(context, icon, 0, 0);
  }
}

void on_method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(GError) error = nullptr;

  if (g_strcmp0(method, "ping") == 0) {
    fl_method_call_respond_success(call, nullptr, &error);
  } else if (g_strcmp0(method, "clipboardSerial") == 0) {
    g_autoptr(FlValue) value = fl_value_new_int(serial_now());
    fl_method_call_respond_success(call, value, &error);
  } else if (g_strcmp0(method, "clipboardRead") == 0) {
    g_autoptr(FlValue) value = read_clipboard();
    fl_method_call_respond_success(call, value, &error);
  } else if (g_strcmp0(method, "clipboardWrite") == 0) {
    const int64_t serial =
        write_clipboard(paths_in(args), flag_in(args, "move", false));
    g_autoptr(FlValue) value = fl_value_new_int(serial);
    fl_method_call_respond_success(call, value, &error);
  } else if (g_strcmp0(method, "startDrag") == 0) {
    start_drag(call, args);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, &error);
  }
}

}  // namespace

void register_transfer_channel(FlView* view) {
  g_view = GTK_WIDGET(view);
  g_owner = G_OBJECT(view);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), kChannelName,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, on_method_call, nullptr,
                                            nullptr);

  // No default handling at all: every step of a drop is answered here, because
  // every step of it depends on what is under the pointer.
  GtkTargetEntry target = {const_cast<gchar*>(kUriList), 0, 0};
  gtk_drag_dest_set(g_view, static_cast<GtkDestDefaults>(0), &target, 1,
                    static_cast<GdkDragAction>(GDK_ACTION_COPY |
                                               GDK_ACTION_MOVE));

  g_signal_connect(g_view, "drag-motion", G_CALLBACK(on_motion), nullptr);
  g_signal_connect(g_view, "drag-leave", G_CALLBACK(on_leave), nullptr);
  g_signal_connect(g_view, "drag-drop", G_CALLBACK(on_drop), nullptr);
  g_signal_connect(g_view, "drag-data-received", G_CALLBACK(on_data_received),
                   nullptr);
  g_signal_connect(g_view, "drag-data-get", G_CALLBACK(on_drag_data_get),
                   nullptr);
  g_signal_connect(g_view, "drag-end", G_CALLBACK(on_drag_end), nullptr);
  g_signal_connect(g_view, "drag-failed", G_CALLBACK(on_drag_failed), nullptr);
}
