import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../core/version.dart';
import '../../core/vfs/fs_provider.dart';
import '../../core/vfs/fs_registry.dart';
import '../../core/vfs/vfs_path.dart';
import '../../state/app_state.dart';
import '../about/about_splash.dart' show AboutColumn, AboutQuiet, AboutRow;
import 'figures/file_flight.dart';
import 'figures/hairline_kernel.dart';
import '../motion.dart';
import '../page_transition.dart';
import '../widgets/context_menu.dart' show MenuAppearance, menuAppearanceFrom;
import '../widgets/escape_to_pop.dart';
import '../widgets/title_bar.dart';

/// **The window's front page**, opened by pressing the application's mark in
/// the title bar — the same place a terminal of this family keeps it.
///
/// It answers one question, *where do I want to be*, and it answers it with
/// the two lists that answer it: the volumes and places this machine offers,
/// and the folders this application has actually been worked in. They are the
/// two halves of the panel's own drive menu and history, side by side and with
/// room to read them.
///
/// **It is not the About card.** That one is a splash — a picture, a version
/// and the ways out to the project — and it stays exactly as it is. This is
/// somewhere you go to get somewhere else, so it is a page: Escape comes back,
/// and a row takes the active panel there and closes the page behind it.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MotionPageRoute<void>.of(context, builder: (_) => const DashboardPage()),
  );

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with SingleTickerProviderStateMixin {
  /// **It arrives, it is not simply there** — rule two. The mark comes up
  /// first and the two lists a little after it, which is the order somebody
  /// watching would say it happened in.
  late final AnimationController _arrive = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_arrive.isDismissed) return;
    if (motionOn(context)) {
      _arrive.duration = motionOf(context, 520);
      unawaited(_arrive.forward());
    } else {
      _arrive.value = 1;
    }
  }

  @override
  void dispose() {
    _arrive.dispose();
    super.dispose();
  }

  /// Rises into place over [from]..[to] of the arrival.
  Widget _rising(double from, double to, Widget child) {
    final curve = CurvedAnimation(
      parent: _arrive,
      curve: Interval(from, to, curve: kArrivingCurve),
    );
    return AnimatedBuilder(
      animation: curve,
      // Built once and carried through: only where it is and how strongly it
      // is drawn change.
      child: child,
      builder: (context, child) => Opacity(
        opacity: curve.value,
        child: Transform.translate(
          offset: Offset(0, (1 - curve.value) * 14),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final menu = menuAppearanceFrom(theme);
    final app = context.read<AppState>();
    // The volumes as the drive menu has them, and the folders as the history
    // has them: one list of each in the application, and these are they.
    final roots = context.watch<FileSystemRegistry>().knownRoots;
    final folders = app.history.favourites;

    return EscapeToPop(
      child: ColoredBox(
        // The page covers the route under it, so what shows through a
        // translucent one is the window's own backdrop — the same sheet the
        // panels stand on.
        color: theme.effectivePanelBackground,
        child: Column(
          children: [
            TitleBar(
              leading: [
                TitleBarButton(
                  icon: Icons.arrow_back,
                  tooltip: tr('Back'),
                  onPressed: Navigator.of(context).pop,
                ),
              ],
              title: Text(
                tr('Dashboard'),
                overflow: TextOverflow.ellipsis,
                style: TitleBar.titleStyle(theme),
              ),
            ),
            Expanded(
              // **A Material, transparent.** Text outside one is drawn in the
              // engine's fallback face with a double underline ruled under it
              // — which is exactly what this page looked like without it.
              // Transparent because the sheet is painted above, once.
              child: Material(
                type: MaterialType.transparency,
                child: SingleChildScrollView(
                child: Center(
                  child: ConstrainedBox(
                    // Two columns and no more: a page of lists that runs the
                    // width of a wide window is a page nobody reads across.
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _rising(0, 0.6, _figure(theme, app)),
                          const SizedBox(height: 26),
                          _rising(
                            0.25,
                            1,
                            IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _places(
                                      context,
                                      theme: theme,
                                      menu: menu,
                                      app: app,
                                      roots: roots,
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: _recent(
                                      context,
                                      theme: theme,
                                      menu: menu,
                                      app: app,
                                      folders: folders,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// **The figure**: a sheet leaving one folder and landing in another, drawn
  /// in lines and leaning towards the pointer.
  ///
  /// It is not a picture of nothing — it is this application's one act, and
  /// it is told what the window is actually doing: the two folders wear the
  /// panels' names, and the count is what is marked in the active one.
  ///
  /// The drawing lives in this repository rather than coming from the package
  /// it was made for: that one is private, and a public program cannot depend
  /// on a private repository. See the head of `figures/file_flight.dart`.
  Widget _figure(AppearanceSettings theme, AppState app) {
    final ink = theme.panelForeground;
    final paper = theme.panelBackground;
    Color toPaper(double t) => Color.lerp(ink, paper, t)!;

    return Column(
      children: [
        SizedBox(
          height: 210,
          child: HlFileFlight(
            files: app.active.markedCount > 0 ? app.active.markedCount : 6,
            from: app.left.location?.label ?? tr('Left'),
            to: app.right.location?.label ?? tr('Right'),
            palette: HairlinePalette(
              // The plates are filled and must be the colour they stand on,
              // which here is the page's own sheet.
              plate: paper,
              hi: ink,
              edge: toPaper(0.35),
              mid: toPaper(0.5),
              lo: toPaper(0.65),
              // A light stroke on a dark ground reads thinner than a dark one
              // on a light ground, so the dark palette carries more of it.
              stroke: theme.darkChrome ? 1.2 : 0.95,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$kAppTitle $kAppVersion',
          style: TextStyle(
            color: theme.panelForeground.withValues(alpha: 0.55),
            fontSize: theme.fontSize - 1,
          ),
        ),
      ],
    );
  }

  /// **Where this machine can take you**: the volumes and places the drive
  /// menu offers, in the order it offers them.
  Widget _places(
    BuildContext context, {
    required AppearanceSettings theme,
    required MenuAppearance menu,
    required AppState app,
    required List<VfsRoot> roots,
  }) => AboutColumn(
    title: tr('Places'),
    appearance: theme,
    menu: menu,
    children: [
      if (roots.isEmpty)
        AboutQuiet(text: tr('Nowhere yet'), appearance: theme, menu: menu)
      else
        for (final root in roots)
          AboutRow(
            label: root.label,
            hint: root.subtitle ?? root.path.display,
            icon: root.isVolume ? Icons.storage_outlined : Icons.folder_special_outlined,
            appearance: theme,
            menu: menu,
            onPressed: () {
              Navigator.of(context).maybePop();
              // A volume lands where it was last left, a place goes to the
              // place: the drive menu's rule, and this is the same list.
              unawaited(
                root.isVolume
                    ? app.active.openVolume(root.path)
                    : app.active.navigateTo(root.path),
              );
            },
          ),
    ],
  );

  /// **Where this application has been**: the history, which is the folders
  /// somebody has worked in, pinned ones first — not everywhere the panels
  /// have passed through.
  Widget _recent(
    BuildContext context, {
    required AppearanceSettings theme,
    required MenuAppearance menu,
    required AppState app,
    required List<VfsPath> folders,
  }) => AboutColumn(
    title: tr('Recent'),
    appearance: theme,
    menu: menu,
    children: [
      if (folders.isEmpty)
        AboutQuiet(text: tr('Nowhere yet'), appearance: theme, menu: menu)
      else
        for (final where in folders.take(10))
          AboutRow(
            label: where.label,
            hint: where.display,
            icon: Icons.folder_outlined,
            appearance: theme,
            menu: menu,
            onPressed: () {
              Navigator.of(context).maybePop();
              unawaited(app.active.navigateTo(where));
            },
          ),
    ],
  );
}
