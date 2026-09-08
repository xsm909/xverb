import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/settings/settings_store.dart';
import 'core/settings/window_service.dart';
import 'core/update/update_swap.dart';
import 'core/update/updater_handoff.dart';
import 'core/update/updater_runner.dart';
import 'state/app_state.dart';
import 'ui/about/about_splash.dart';
import 'ui/update/updater_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // On a phone the app takes the whole screen. It draws its own title bar,
  // and the system's status bar was landing on top of it.
  if (Platform.isAndroid || Platform.isIOS) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  final settings = await SettingsStore.load();

  // One start in the life of an installation is not a start at all: this copy
  // was made in a temporary folder to replace the one that made it. It shows
  // its own small window and never gets as far as a commander — no plugins, no
  // panels, and nothing of the user's written. See [UpdaterHandoff].
  final handoff = await UpdaterHandoff.forRunningCopy();
  if (handoff != null) {
    await runUpdater(handoff: handoff, appearance: settings.appearance);
    return;
  }

  // The window is set up before anything is drawn, so the frameless title bar
  // and the backdrop are already in place for the first frame.
  await WindowService.initialize(settings.appearance);

  // Settings and the initial panel listings are ready before the first frame,
  // so the app never flashes an empty commander. Plugins load afterwards.
  final state = await AppState.create(settings: settings);

  // **The About card is Blender's splash, and a splash is shown at start-up.**
  // Said here rather than in the screen that shows it, because that screen is
  // built again whenever a page above it closes — and a card on the way back
  // from Settings would be a card nobody asked for. This is the one place that
  // knows the process has just begun. See `wantAboutAtStartup`.
  if (settings.appearance.showAboutAtStart) wantAboutAtStartup();

  runApp(XverbApp(state: state));

  // After the first frame, and not before: the marker is how a copy that
  // installed this one learns that it got as far as a window. Clearing it
  // earlier would report a success that has not happened yet, and the whole
  // point of the marker is that "the process is still alive" is not good
  // enough.
  WidgetsBinding.instance.addPostFrameCallback((_) => _reportStarted());
}

/// Says "I drew something", and clears away what an old update left behind.
///
/// Wrapped whole: an ordinary start must not fail because of tidying, and on a
/// machine where the application is installed somewhere unwritable there is
/// nothing here worth an error.
Future<void> _reportStarted() async {
  if (Platform.isAndroid || Platform.isIOS) return;
  try {
    final root = bundleRootOf(Platform.resolvedExecutable);
    await StartMarker(File('${root.parent.path}'
            '${Platform.pathSeparator}$kUpdatePendingMarker'))
        .clear();
    await sweepUpdaterLeftovers();
  } on Object {
    // Nothing here is worth failing a start for.
  }
}
