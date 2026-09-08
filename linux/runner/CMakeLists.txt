cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "audio.cc"
  "file_transfer.cc"
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# The sound channel plays through GStreamer, which is the desktop's own player
# on this platform — but a machine without its development packages must still
# build the application. Found, the channel plays; not found, it is still
# registered and answers that this build cannot play, which is a sentence the
# viewer already knows how to say.
pkg_check_modules(GSTREAMER IMPORTED_TARGET
  gstreamer-1.0 gstreamer-app-1.0 gstreamer-pbutils-1.0)
if(GSTREAMER_FOUND)
  target_compile_definitions(${BINARY_NAME} PRIVATE "XVERB_HAS_GSTREAMER")
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GSTREAMER)
else()
  message(STATUS "GStreamer development files not found; sound will not play.")
endif()

# Under KWin a window can ask for what is behind it to be blurred — the one way
# to have a real acrylic backdrop on Linux, because no client can do it itself.
# It is an X11 property, so it needs Xlib; GNOME's compositor ignores it, and a
# build without the X11 development files simply never asks.
pkg_check_modules(X11 IMPORTED_TARGET x11)
if(X11_FOUND)
  target_compile_definitions(${BINARY_NAME} PRIVATE "XVERB_HAS_X11")
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::X11)
else()
  message(STATUS "X11 development files not found; KWin will not be asked to blur.")
endif()

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
