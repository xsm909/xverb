import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/settings/settings_store.dart';
import '../../state/app_state.dart';
import '../page_transition.dart';
import '../widgets/escape_to_pop.dart';
import '../widgets/title_bar.dart';
import '../windows/window_layer.dart';
import 'settings_view.dart';

/// Settings as a page you go to and come back from, rather than a window that
/// floats over the panels.
///
/// A pushed page used to be the wrong shape for this, and the reason is worth
/// keeping: a `MaterialPageRoute` covers the whole client area *including* the
/// application's own title bar, and with the system one hidden that is the only
/// thing the window can be dragged by. Settings were unmovable while open, and
/// that is what sent them into an internal window in the first place.
///
/// The viewer had already solved it by the time this followed: a page draws its
/// own [TitleBar] along the top, and the bar is the same widget wherever it
/// appears, so the window drags, maximises and closes from in here exactly as
/// it does from the panels.
///
/// The other half of the old argument — that a floating window let you watch a
/// colour land on the panels behind it — is answered by the preview in the
/// appearance settings, which shows a cursor row, a marked row and a shaded one
/// at once. The panels rarely showed all three anyway.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// Opens the page. Kept here so callers do not each have to know the route.
  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MotionPageRoute<void>.of(context, builder: (_) => const SettingsPage()),
  );

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;

    return EscapeToPop(
      child: ColoredBox(
        // The panel's own fill, backdrop and all. A page covers the route
        // below rather than floating over it, so what shows through a
        // translucent one is the window's own backdrop, not the listing.
        color: theme.effectivePanelBackground,
        child: Column(
          children: [
            // The application's title bar stays put, so the window can be
            // dragged and closed without leaving the settings first — and it
            // carries this page's chrome, the way it does for a view or a
            // command. Back and the title used to stand in an `AppBar` of their
            // own underneath it, which is two bars for one window.
            TitleBar(
              leading: [
                TitleBarButton(
                  icon: Icons.arrow_back,
                  tooltip: tr('Back'),
                  onPressed: Navigator.of(context).pop,
                ),
              ],
              title: Text(
                tr('Settings'),
                overflow: TextOverflow.ellipsis,
                style: TitleBar.titleStyle(theme),
              ),
            ),
            Expanded(
              // The page carries its own window layer, so a colour picker or
              // a name prompt opened from in here floats over the settings
              // instead of behind them. Only the front-most page draws the
              // stack — see WindowLayer.
              child: WindowLayer(
                stack: context.read<AppState>().windows,
                child: const Scaffold(
                  backgroundColor: Colors.transparent,
                  body: SettingsView(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
