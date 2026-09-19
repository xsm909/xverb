import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/colour_contrast.dart';
import '../../core/i18n/i18n.dart';
import '../../core/links.dart';
import '../../core/plugins/first_run_setup.dart';
import '../../core/plugins/plugin_registry.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../core/vfs/shell_open.dart';
import '../../core/vfs/vfs_path.dart';
import '../../core/version.dart';
import '../../state/app_state.dart';
import '../branding/app_mark.dart';
import '../motion.dart';
import '../widgets/blurred_backdrop.dart';
import '../widgets/hint.dart';
import '../widgets/context_menu.dart' show MenuAppearance, menuAppearanceFrom;

/// The About form, built the way Blender's splash is.
///
/// **What was taken from Blender and what was left.** Taken: a picture across
/// the top with the version written on it, two columns under it, a row of ways
/// out at the bottom, and a card that goes when you press anywhere else — the
/// whole thing reads as a card laid on the desk rather than as a window with a
/// job to do. Left: the *New File* column. This application does not make
/// anything, and half a splash offering to create a document nobody asked for
/// is half a splash for another program.
///
/// **So the left column is the history**, which is the half of Blender's splash
/// people actually press. The same list the drive menu offers under *History*:
/// the folders somebody has actually worked in, pinned ones first. It was the
/// plain chronological list for a day and that is gone, because everywhere
/// the panels have been includes everywhere they merely passed through, and a
/// splash offering those is a splash offering a walk rather than a place to
/// carry on from.
const Size kAboutSplashSize = Size(620, 250);

/// The corner the whole card is cut to, and the picture with it.
const double kAboutSplashRadius = 12;

/// How far through its arrival the card is whole, and its shadow begins.
///
/// **One after the other, never together.** The card is translucent, and a
/// shadow fading in under a card that is itself still half there showed
/// through it as a grey smear — dirt on the desk rather than something laid on
/// it. So the card comes first, the shadow once it is solid, and going is the
/// same in reverse.
const double kAboutCardShown = 0.6;

/// Whether the card is still owed to this run of the application.
///
/// **Set by `main`, and by nothing else.** Blender shows its splash when it
/// starts, and so does this — but "starts" has to mean the process starting
/// rather than the commander screen being built, because that screen is built
/// again whenever a page above it closes and a splash on the way back from
/// Settings would be a splash nobody asked for. It is also what keeps the card
/// out of the several dozen tests that pump the screen: a test is not a
/// start-up, and a test does not call `main`.
///
/// One shot. [takeStartupSplash] hands it over and clears it.
bool _startupSplash = false;

/// Says that this is a start-up, so the card is owed. Called from `main`.
void wantAboutAtStartup() => _startupSplash = true;

/// Whether to show the card now, answered once.
bool takeStartupSplash() {
  final owed = _startupSplash;
  _startupSplash = false;
  return owed;
}

/// Puts the About card up. Returns when it has gone.
Future<void> showAboutSplash(BuildContext context) {
  final appearance = context.read<SettingsStore>().appearance;
  final state = context.read<AppState?>();
  return Navigator.of(context, rootNavigator: true).push(
    AboutCardRoute(
      appearance: appearance,
      builder: (context) => _AboutCard(appearance: appearance, state: state),
    ),
  );
}

/// A card laid over the application: this one, and a plugin's.
///
/// A route rather than a dialog, for the two things a dialog would not give:
/// a barrier that takes the press without dimming the application to grey, and
/// a card that can be dismissed by that press without a button to press.
class AboutCardRoute extends PopupRoute<void> {
  AboutCardRoute({
    required this.appearance,
    required this.builder,
    this.grows = true,
  });

  final AppearanceSettings appearance;
  final WidgetBuilder builder;

  /// Whether it comes up out of a slightly smaller card as it fades in, or
  /// only fades. The application's card grows; a plugin's only fades — it is
  /// asked for from a page, often, and a card that is merely there and then
  /// not is the quieter answer to a question about a version.
  final bool grows;

  /// **Nothing behind it is dimmed**, which is the one place that is right.
  ///
  /// Every other modal in the application darkens what it is over, and should:
  /// it is holding a question, and the darkening says *this first*. This one
  /// holds no question. It is a card laid on the desk with a photograph on it,
  /// and dimming the application behind it would say the commander had been
  /// suspended when it has not.
  ///
  /// Null rather than transparent, because there is nothing to paint. The
  /// barrier itself stays: it is what takes the press that puts the card away.
  @override
  Color? get barrierColor => null;

  /// **Pressing the application closes it**, which is what Blender does.
  /// A splash has nothing to confirm and nothing to lose, so the way out is
  /// everywhere except the card itself.
  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => tr('Close');

  @override
  Duration get transitionDuration =>
      appearance.animated(kWindowArriveDuration);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // It comes up rather than out of a corner: a card laid on the desk, the
    // same arrival an internal window uses at its plainest.
    //
    // **The card first, and its shadow after it** — see [kAboutCardShown].
    // Going, the same animation runs backwards, so the shadow leaves first
    // and the card after it without saying so twice.
    final eased = CurvedAnimation(
      parent: animation,
      curve: const Interval(0, kAboutCardShown, curve: kArrivingCurve),
    );
    if (!grows) return FadeTransition(opacity: eased, child: child);
    return FadeTransition(
      opacity: eased,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(eased),
        child: child,
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.appearance, required this.state});

  final AppearanceSettings appearance;
  final AppState? state;

  @override
  Widget build(BuildContext context) => AboutCardFrame(
    appearance: appearance,
    builder: (menu) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Banner(appearance: appearance),
        _Body(appearance: appearance, menu: menu, state: state),
      ],
    ),
  );
}

/// The card itself, whatever is on it: its width, its corners, its shadow, the
/// blur behind it, and Escape.
///
/// Shared so that the application's card and a plugin's are one shape — a
/// plugin's is the same question asked about something smaller.
class AboutCardFrame extends StatelessWidget {
  const AboutCardFrame({
    super.key,
    required this.appearance,
    required this.builder,
  });

  final AppearanceSettings appearance;

  /// What is on the card, given the colours it is drawn in.
  final Widget Function(MenuAppearance menu) builder;

  @override
  Widget build(BuildContext context) {
    // The menu's colours, because this is the same kind of thing: something
    // laid over the application for a moment rather than part of it. It brings
    // the blur with it, which is the application's own look.
    final menu = menuAppearanceFrom(appearance);

    return Center(
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) => Navigator.of(context).maybePop(),
            ),
          },
          child: Focus(
            autofocus: true,
            child: SizedBox(
              width: kAboutSplashSize.width,
              child: Material(
                type: MaterialType.transparency,
                child: _Shadow(
                  animation: ModalRoute.of(context)?.animation,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(kAboutSplashRadius),
                    child: blurredBackdrop(
                      sigma: menu.blur,
                      passes: menu.blurPasses,
                      child: Container(
                        color: menu.background.withValues(alpha: menu.opacity),
                        child: builder(menu),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The card's shadow, which arrives after the card and leaves before it.
///
/// Its own widget so that only the shadow is rebuilt as it fades; the card
/// under it is built once. Without a route to follow — a test drawing the
/// frame on its own — it is simply there.
class _Shadow extends StatelessWidget {
  const _Shadow({required this.animation, required this.child});

  final Animation<double>? animation;
  final Widget child;

  static const _interval = Interval(kAboutCardShown, 1, curve: kArrivingCurve);

  @override
  Widget build(BuildContext context) {
    final running = animation;
    if (running == null) return _drawn(1, child);
    return AnimatedBuilder(
      animation: running,
      builder: (context, card) =>
          _drawn(_interval.transform(running.value), card!),
      child: child,
    );
  }

  Widget _drawn(double strength, Widget card) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(kAboutSplashRadius),
      boxShadow: [
        if (strength > 0)
          BoxShadow(
            color: const Color(0x59000000).withValues(alpha: 0.35 * strength),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
      ],
    ),
    child: card,
  );
}

/// The picture, with the version written over its quiet corner.
class _Banner extends StatelessWidget {
  const _Banner({required this.appearance});

  final AppearanceSettings appearance;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: kAboutSplashSize.width,
    height: kAboutSplashSize.height,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/about/splash.png',
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          // **The form works without the picture**, which is what lets it be
          // built before the picture exists. A gradient in the palette's own
          // colours, with the wordmark on it: not a hole, and not a broken
          // image either.
          errorBuilder: (context, _, _) =>
              AboutBannerFallback(appearance: appearance),
        ),
        // **The mark, top left.** It is the same painter the dock icon is
        // rendered from, so the mark on the card and the mark on the dock
        // cannot drift
        // apart — and drawn rather than placed as a picture, so it is crisp at
        // whatever size the interface is set to.
        //
        // White, with a shadow under it, for the reason the version has one: it
        // has to read on a photograph this code has never seen.
        Positioned(
          left: 14,
          top: 12,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: Color(0x99000000), blurRadius: 10),
              ],
            ),
            child: AppMark(
              colour: Colors.white,
              // Twice what it was. A mark this size is the card saying whose
              // it is; at half of it, it was a badge on a photograph.
              size: appearance.scaled(68),
            ),
          ),
        ),
        // **Top right, and thin.** It is a fact about the copy somebody is
        // running rather than a thing to read, and a light face at the top of
        // a picture says
        // that — where the same number in a heavier one at the bottom read as a
        // caption for the photograph.
        //
        // White with a shadow under it, because it has to be legible on a
        // picture this code has never seen.
        Positioned(
          right: 14,
          top: 10,
          child: Text(
            kAppVersion,
            style: TextStyle(
              color: Colors.white,
              fontSize: appearance.scaled(12),
              fontWeight: FontWeight.w200,
              letterSpacing: 0.6,
              shadows: const [
                Shadow(color: Color(0xCC000000), blurRadius: 6),
              ],
            ),
          ),
        ),
        // **A line under the picture**, along the bottom, and a caption
        // rather than a credit: whoever took it, or where it was taken, or
        // nothing at all.
        //
        // Read from a file beside the picture rather than written here, so
        // changing the photograph is changing two files in `assets/about` and
        // no code at all.
        const Positioned(left: 14, bottom: 9, child: _PhotoCaption()),
      ],
    ),
  );
}

/// What is drawn when there is no picture to draw.
///
/// **Public so it can be tested**, which is the only way it can be: once
/// `assets/about/splash.png` exists the error builder never runs, and a test
/// that went through the form would be asserting about a branch that is no
/// longer taken. The branch still has to work — a picture can be missing from a
/// build, and a hole where the top of the card should be is worse than a plain
/// one.
class AboutBannerFallback extends StatelessWidget {
  const AboutBannerFallback({super.key, required this.appearance});

  final AppearanceSettings appearance;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          appearance.headerBackground,
          appearance.accentColor.withValues(alpha: 0.55),
        ],
      ),
    ),
    // **One colour, all of it.** The title bar splits the
    // wordmark, accent letter and then the rest, because up there it is a small
    // mark among controls and the accent is what picks it out. Sixty points
    // across a photograph it is a name, and a name written in two colours reads
    // as two things.
    child: Center(
      child: Text(
        kAppTitle,
        style: TextStyle(
          fontSize: appearance.scaled(64),
          fontWeight: FontWeight.w200,
          letterSpacing: 6,
          color: Colors.white,
        ),
      ),
    ),
  );
}

/// The line under the picture, from `assets/about/caption.txt`.
///
/// **A caption rather than a credit**, because it is not always a name.
/// Whoever took it, or where it was taken. Whatever is in the file is drawn.
///
/// A file rather than a constant, so the picture and its line travel together:
/// replacing one is replacing the other, in the same folder, with nothing to
/// find in the source. **Empty or absent means nothing is drawn** — and that is
/// the ordinary case, not a failure: a photograph of one's own with nowhere
/// worth naming needs no line at all.
class _PhotoCaption extends StatefulWidget {
  const _PhotoCaption();

  @override
  State<_PhotoCaption> createState() => _PhotoCaptionState();
}

class _PhotoCaptionState extends State<_PhotoCaption> {
  /// Read once for the life of the process, and kept.
  ///
  /// **A value rather than a future**, so the second time the card is opened
  /// the line is simply there: an asset read is asynchronous however cheap it
  /// is, and a caption that fades in one frame late every time is a caption
  /// that flickers. It also makes the widget behave the same on its first
  /// showing and its tenth, which is what a test can hold.
  static String? _known;
  static bool _looked = false;

  String? _line;

  @override
  void initState() {
    super.initState();
    if (_looked) {
      _line = _known;
    } else {
      unawaited(_read());
    }
  }

  Future<void> _read() async {
    String? text;
    try {
      text = (await rootBundle.loadString('assets/about/caption.txt')).trim();
    } on Object {
      // No file, which is an ordinary state and not a failure.
      text = null;
    }
    _known = (text?.isEmpty ?? true) ? null : text;
    _looked = true;
    if (mounted) setState(() => _line = _known);
  }

  @override
  Widget build(BuildContext context) {
    final line = _line;
    if (line == null) return const SizedBox.shrink();
    return Text(
      line,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Color(0xCCFFFFFF),
        fontSize: 10.5,
        fontWeight: FontWeight.w300,
        letterSpacing: 0.4,
        shadows: [Shadow(color: Color(0xCC000000), blurRadius: 6)],
      ),
    );
  }
}

/// The two columns and the row of ways out.
class _Body extends StatelessWidget {
  const _Body({
    required this.appearance,
    required this.menu,
    required this.state,
  });

  final AppearanceSettings appearance;
  final MenuAppearance menu;
  final AppState? state;

  @override
  Widget build(BuildContext context) {
    // **The history, not the plain chronological list.** The card was
    // offering everywhere the panels had been, walked-through folders and all;
    // the history is the folders somebody has actually worked in, with the
    // pinned ones at the top. One list in the application, and this is it.
    final folders = state?.history.favourites ?? const <VfsPath>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AboutColumn(
                    title: tr('History'),
                    appearance: appearance,
                    menu: menu,
                    children: [
                      if (folders.isEmpty)
                        AboutQuiet(
                          text: tr('Nowhere yet'),
                          appearance: appearance,
                          menu: menu,
                        )
                      else
                        for (final where in folders.take(8))
                          AboutRow(
                            label: where.label,
                            hint: where.display,
                            icon: Icons.folder_outlined,
                            appearance: appearance,
                            menu: menu,
                            onPressed: () {
                              final app = state;
                              if (app == null) return;
                              Navigator.of(context).maybePop();
                              unawaited(app.active.navigateTo(where));
                            },
                          ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 210,
                  child: AboutColumn(
                    title: tr('Xverb'),
                    appearance: appearance,
                    menu: menu,
                    children: [
                      // The front door, and first because that is what it is:
                      // the rows under it are places somebody goes for one
                      // particular thing.
                      AboutRow(
                        label: tr('Website'),
                        icon: Icons.language_outlined,
                        appearance: appearance,
                        menu: menu,
                        onPressed: () => _open(context, kWebsiteUrl),
                      ),
                      AboutRow(
                        label: tr("What's new"),
                        icon: Icons.auto_awesome_outlined,
                        appearance: appearance,
                        menu: menu,
                        onPressed: () => _open(context, kReleasesUrl),
                      ),
                      AboutRow(
                        label: tr('Source and licence'),
                        icon: Icons.code_outlined,
                        appearance: appearance,
                        menu: menu,
                        onPressed: () => _open(context, kProjectUrl),
                      ),
                      AboutRow(
                        label: tr('Report a problem'),
                        icon: Icons.bug_report_outlined,
                        appearance: appearance,
                        menu: menu,
                        onPressed: () => _open(context, kIssuesUrl),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // The first run's offer, where there is no Python yet. Nothing at all
          // where there is, so the card is what it has always been.
          if (state != null)
            _FirstRunOffer(
              plugins: state!.plugins,
              appearance: appearance,
              menu: menu,
            ),
          const SizedBox(height: 10),
          Divider(height: 1, color: menu.foreground.withValues(alpha: 0.14)),
          const SizedBox(height: 8),
          // What the card is, in one line: the name, the version, what the
          // release is called, and the licence — which is the one fact a free
          // program owes anybody looking at its About form.
          //
          // The release name and the caption on the photograph are the same
          // word, and that is the point of it: the picture is a glacier he
          // photographed in Iceland, and this release is called after it.
          Text(
            '$kAppTitle $kAppVersion  “$kReleaseName”'
            '  ·  ${tr('Free software under the GNU GPL v3 or later')}',
            style: TextStyle(
              fontSize: appearance.scaled(10.5),
              color: menu.foreground.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context, String url) async {
    Navigator.of(context).maybePop();
    await ShellOpen.open(url);
  }
}

/// Python and the everyday plugins, offered under the two columns while there
/// is no Python — see [FirstRunSetup]. Its own words are the confirmation: a
/// second dialog raised over a card that is itself laid over the application
/// would open behind it.
///
/// It opens and closes its place rather than appearing in it, and the strip
/// says, in the same place, how the work is going and how it ended.
class _FirstRunOffer extends StatelessWidget {
  const _FirstRunOffer({
    required this.plugins,
    required this.appearance,
    required this.menu,
  });

  final PluginRegistry plugins;
  final AppearanceSettings appearance;
  final MenuAppearance menu;

  @override
  Widget build(BuildContext context) {
    final setup = FirstRunSetup.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([plugins, setup]),
      builder: (context, _) => AnimatedSize(
        duration: motionOf(context, kSettingsFoldDuration),
        curve: kBothCurve,
        alignment: Alignment.topCenter,
        child: setup.shownWith(plugins)
            ? _strip(setup)
            : const SizedBox(width: double.infinity),
      ),
    );
  }

  Widget _strip(FirstRunSetup setup) {
    final ink = menu.foreground;
    final accent = appearance.accentColor;
    final progress = setup.progress;
    final failure = setup.failure;
    final installed = setup.installed;
    final message = progress != null
        ? progress.message
        : failure ??
            (installed != null
                ? tr('Python and {count} plugin(s) are installed.',
                    {'count': installed})
                : tr(
                    'Plugins need Python, and it is not here yet. Install it '
                    'with the everyday plugins: archives, PDF, pictures, '
                    'vector graphics and the disk map. Nothing is installed '
                    'system-wide.',
                  ));
    final offering = progress == null && installed == null;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.extension_outlined, size: 18, color: accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      fontSize: appearance.scaled(12),
                      color: ink,
                    ),
                  ),
                ),
                if (offering) ...[
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: setup.notNow,
                    style: TextButton.styleFrom(
                      foregroundColor: ink.withValues(alpha: 0.8),
                    ),
                    child: Text(tr('Not now')),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: () => unawaited(setup.install(plugins)),
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: inkFor(accent),
                    ),
                    child: Text(failure != null ? tr('Try again') : tr('Install')),
                  ),
                ],
              ],
            ),
            if (progress != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress.fraction,
                  minHeight: 3,
                  color: accent,
                  backgroundColor: accent.withValues(alpha: 0.18),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AboutColumn extends StatelessWidget {
  const AboutColumn({
    super.key,
    required this.title,
    required this.children,
    required this.appearance,
    required this.menu,
  });

  final String title;
  final List<Widget> children;
  final AppearanceSettings appearance;
  final MenuAppearance menu;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            letterSpacing: 1.1,
            fontSize: appearance.scaled(10),
            fontWeight: FontWeight.w600,
            color: menu.muted,
          ),
        ),
      ),
      ...children,
    ],
  );
}

/// One pressable line, shaped like a menu row because that is what it is.
class AboutRow extends StatefulWidget {
  const AboutRow({
    super.key,
    required this.label,
    required this.icon,
    required this.appearance,
    required this.menu,
    required this.onPressed,
    this.hint,
  });

  final String label;

  /// The whole path, shown when the pointer rests on the row.
  ///
  /// **Because a name is not an answer.** Two folders called `src` are two
  /// different places, and a list of names alone asks somebody to guess which
  /// one they are about to open.
  final String? hint;
  final IconData icon;
  final AppearanceSettings appearance;
  final MenuAppearance menu;
  final VoidCallback onPressed;

  @override
  State<AboutRow> createState() => _AboutRowState();
}

/// **There was an accent variant, and it is worth knowing why.**
///
/// One row on this card used to be drawn in the accent, in semibold, and with a
/// stronger hover — the one that asked the reader for money. A row that *asks*
/// should not look like the four that *offer*, and that difference was the
/// whole of it. It went with the donate link on 2026-09-07 (see
/// `lib/core/links.dart`), and returning it is three ternaries: the ink, the
/// hover alpha, and the weight.
class _AboutRowState extends State<AboutRow> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final menu = widget.menu;
    final ink = menu.foreground;

    return Hint(
      message: widget.hint ?? '',
      child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: motionOf(context, kHintDuration),
          curve: kArrivingCurve,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: _over ? menu.accent.withValues(alpha: 0.2) : null,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 15, color: ink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: widget.appearance.scaled(12.5),
                    color: ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// A column with nothing in it, saying so.
class AboutQuiet extends StatelessWidget {
  const AboutQuiet({
    super.key,
    required this.text,
    required this.appearance,
    required this.menu,
  });

  final String text;
  final AppearanceSettings appearance;
  final MenuAppearance menu;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: appearance.scaled(12),
        color: menu.foreground.withValues(alpha: 0.45),
      ),
    ),
  );
}
