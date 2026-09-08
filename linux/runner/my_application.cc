#include "my_application.h"

#include "audio.h"
#include "file_transfer.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#if defined(GDK_WINDOWING_X11) && defined(XVERB_HAS_X11)
#include <X11/Xatom.h>

#include <cmath>
#include <vector>
#endif

#include "flutter/generated_plugin_registrant.h"

#if defined(GDK_WINDOWING_X11) && defined(XVERB_HAS_X11)

// The radius the interface rounds its own corners with — `_CutCorners` in
// app.dart. Kept in step by hand, because the two live on opposite sides of
// the engine and neither can ask the other.
static const int kCornerRadius = 12;

// Asks the compositor to blur what is behind the window.
//
// `_KDE_NET_WM_BLUR_BEHIND_REGION` is KWin's, and it is the only way an
// application on Linux gets a real acrylic backdrop: what is behind a window is
// the compositor's to see, and GNOME publishes no interface for asking at all.
// Setting it under GNOME is harmless — the property is simply never read.
//
// The region is given rather than left empty, which would blur the whole
// window: the interface rounds its own corners and leaves them transparent, and
// a blur behind them would show as four blurred squares where nothing should
// be. So the region is the rounded rectangle, a row of pixels at a time down
// each curve.
//
// Blur behind an *opaque* window is invisible, so this needs no telling when
// the backdrop changes: with `opaque` there is nothing to see through.
static void ask_for_blur(GtkWidget* widget) {
  GdkWindow* gdk_window = gtk_widget_get_window(widget);
  if (gdk_window == nullptr || !GDK_IS_X11_WINDOW(gdk_window)) return;

  Display* display = GDK_WINDOW_XDISPLAY(gdk_window);
  Window xid = GDK_WINDOW_XID(gdk_window);

  // The surface is bigger than the window: GTK keeps a margin round it for the
  // shadow, and says how wide it is in `_GTK_FRAME_EXTENTS`.
  long left = 0, right = 0, top = 0, bottom = 0;
  Atom extents = XInternAtom(display, "_GTK_FRAME_EXTENTS", True);
  if (extents != None) {
    Atom type;
    int format;
    unsigned long count = 0, remaining = 0;
    unsigned char* data = nullptr;
    if (XGetWindowProperty(display, xid, extents, 0, 4, False, XA_CARDINAL,
                           &type, &format, &count, &remaining, &data) == Success &&
        data != nullptr) {
      if (count >= 4) {
        long* values = reinterpret_cast<long*>(data);
        left = values[0];
        right = values[1];
        top = values[2];
        bottom = values[3];
      }
      XFree(data);
    }
  }

  const long x = left;
  const long y = top;
  const long w = gdk_window_get_width(gdk_window) - left - right;
  const long h = gdk_window_get_height(gdk_window) - top - bottom;
  if (w <= 0 || h <= 0) return;

  long radius = kCornerRadius;
  if (radius * 2 > w) radius = w / 2;
  if (radius * 2 > h) radius = h / 2;

  std::vector<long> region = {x, y + radius, w, h - 2 * radius};
  for (long i = 0; i < radius; i++) {
    const double from_centre = radius - i - 0.5;
    const long inset = static_cast<long>(
        radius - std::sqrt(radius * radius - from_centre * from_centre) + 0.5);
    region.insert(region.end(), {x + inset, y + i, w - 2 * inset, 1});
    region.insert(region.end(),
                  {x + inset, y + h - i - 1, w - 2 * inset, 1});
  }

  Atom blur = XInternAtom(display, "_KDE_NET_WM_BLUR_BEHIND_REGION", False);
  XChangeProperty(display, xid, blur, XA_CARDINAL, 32, PropModeReplace,
                  reinterpret_cast<const unsigned char*>(region.data()),
                  static_cast<int>(region.size()));
}

// The region is in pixels, so it is wrong the moment the window is resized.
static void blur_region_follows_size(GtkWidget* widget, GdkRectangle*, gpointer) {
  ask_for_blur(widget);
}
#endif

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    // The name shown, not the name built — see kAppTitle in
    // lib/core/version.dart. Dart sets the title again once it is up; this
    // is what the window is called before that.
    gtk_header_bar_set_title(header_bar, "Xverb");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Xverb");
  }

  gtk_window_set_default_size(window, 1280, 720);

  // GTK's own decoration is told to paint nothing.
  //
  // A GTK window under client-side decorations draws a `decoration` node
  // beneath the application: a background, a border and a rounded corner of
  // its own. Normally none of it shows, because the application covers it —
  // but the interface rounds its corners itself (see `_CutCorners` in
  // app.dart), and through that cut GTK's background came back as a pale
  // hook around each corner, with GTK's radius rather than ours. Two corners
  // at two radii, which is what it looked like.
  //
  // The margin is deliberately left alone: it is the invisible border the
  // window is resized by, and it costs nothing once it draws nothing.
  g_autoptr(GtkCssProvider) decoration = gtk_css_provider_new();
  gtk_css_provider_load_from_data(
      decoration,
      "decoration { background-color: transparent; box-shadow: none;"
      " border: none; border-radius: 0; }",
      -1, nullptr);
  gtk_style_context_add_provider_for_screen(
      gdk_screen_get_default(), GTK_STYLE_PROVIDER(decoration),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Transparent, not the template's opaque black.
  //
  // This is the view's own background, and it is what everything Flutter draws
  // with any transparency at all ends up composited against. Left black, the
  // application cannot be see-through: the translucent backdrops came out as
  // their colour mixed with black rather than with the desktop, and the
  // rounded corners the interface clips for itself came out as black corners —
  // which look right only on a dark wallpaper, and square on a pale one.
  //
  // The window is already able to carry it: `flutter_acrylic` asks the screen
  // for an RGBA visual when it registers, and the compositor blends the rest
  // of the surface correctly — it was only ever this one colour in the way.
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  // The machine's own player, for the sound viewer.
  register_audio_channel(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)));
  // Files dragged in and out, and the desktop's own clipboard.
  register_transfer_channel(view);

  gtk_widget_grab_focus(GTK_WIDGET(view));

#if defined(GDK_WINDOWING_X11) && defined(XVERB_HAS_X11)
  ask_for_blur(GTK_WIDGET(window));
  g_signal_connect(window, "size-allocate",
                   G_CALLBACK(blur_region_follows_size), nullptr);
#endif
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
