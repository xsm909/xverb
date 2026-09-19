import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/plugins/plugin_changes.dart';
import '../../core/plugins/plugin_manifest.dart';
import '../../core/plugins/plugin_registry.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../core/vfs/shell_open.dart';
import '../../state/app_state.dart';
import '../about/about_splash.dart';
import '../dialogs/plugin_settings_dialog.dart';
import '../widgets/context_menu.dart' show MenuAppearance;
import '../widgets/keyboard_scrollable.dart';
import 'plugin_icons.dart';

/// φ. The card is at most the window's height divided by it.
const double kGoldenRatio = 1.6180339887;

/// Whether [event] asks the page it reached for the plugin behind it.
///
/// F1, as it is in every program with a help key, and on every page a plugin
/// draws — so the hand learns one key rather than one per kind of page.
bool isPluginAboutKey(KeyEvent event) =>
    event is KeyDownEvent &&
    event.logicalKey == LogicalKeyboardKey.f1 &&
    !HardwareKeyboard.instance.isControlPressed &&
    !HardwareKeyboard.instance.isMetaPressed &&
    !HardwareKeyboard.instance.isAltPressed &&
    !HardwareKeyboard.instance.isShiftPressed;

/// Which plugin is drawing this, which version of it, and what changed lately.
///
/// **The application's own About card, about something smaller.** The same
/// frame, the same colours and blur, nothing dimmed behind it, and put away by
/// pressing anywhere else or by Escape. Where the application's card has its
/// photograph, a plugin's has the picture it names as `banner` in its
/// manifest — and where it names none, nothing: a card with no picture is a
/// plugin that did not bring one, not a hole waiting for it.
///
/// It only fades in and out. See [AboutCardRoute.grows].
///
/// **One card for every kind of page.** A viewer, a view and a command are
/// three things to the host and one thing to the person looking at them:
/// something a plugin put on the screen, and "what is this, and is it the new
/// one" is the same question on all three. The plugin manager opens it too.
Future<void> showPluginAbout(
  BuildContext context, {
  required PluginManifest manifest,
}) async {
  final changes = await readPluginChanges(
    manifest,
    code: activeLocalisation.code,
  );
  final banner = await readPluginBanner(manifest);
  if (!context.mounted) return;
  final appearance = context.read<SettingsStore>().appearance;
  final registry =
      context.read<AppState?>()?.plugins ?? context.read<PluginRegistry?>();
  await Navigator.of(context, rootNavigator: true).push(
    AboutCardRoute(
      appearance: appearance,
      grows: false,
      builder: (context) => AboutCardFrame(
        appearance: appearance,
        builder: (menu) => PluginAbout(
          manifest: manifest,
          changes: changes,
          banner: banner,
          appearance: appearance,
          menu: menu,
          registry: registry,
        ),
      ),
    ),
  );
}

/// The bytes of [manifest]'s banner, or null when it has none that can be
/// drawn.
///
/// Read and decoded **before** the card goes up, so a picture that is missing
/// or broken is known to be missing before anything is drawn — and the card
/// then has no picture, rather than a picture-shaped gap that an error builder
/// fills with nothing.
Future<Uint8List?> readPluginBanner(PluginManifest manifest) async {
  final name = manifest.bannerFile;
  if (name == null) return null;
  try {
    final Uint8List bytes;
    if (manifest.isBundled) {
      final data = await rootBundle.load('${manifest.directory}/$name');
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } else {
      final file = File('${manifest.directory}${Platform.pathSeparator}$name');
      if (!await file.exists()) return null;
      bytes = await file.readAsBytes();
    }
    final codec = await ui.instantiateImageCodec(bytes);
    codec.dispose();
    return bytes;
  } on Object {
    return null;
  }
}

/// What is on the card, apart from the card so a test can draw it on its own.
class PluginAbout extends StatelessWidget {
  const PluginAbout({
    super.key,
    required this.manifest,
    required this.changes,
    required this.appearance,
    required this.menu,
    this.banner,
    this.registry,
  });

  final PluginManifest manifest;
  final List<PluginChange> changes;
  final AppearanceSettings appearance;
  final MenuAppearance menu;

  /// The picture across the top, already read. Null draws none.
  final Uint8List? banner;

  /// For the Settings row. Without one there is no such row.
  final PluginRegistry? registry;

  @override
  Widget build(BuildContext context) {
    final ink = menu.foreground;
    final picture = banner;
    final description = manifest.displayDescription;
    final homepage = manifest.homepage;
    final plugins = registry;
    final hasSettings = plugins != null &&
        (manifest.settings.isNotEmpty ||
            manifest.commands.isNotEmpty ||
            manifest.views.isNotEmpty);
    final hasLinks = (homepage != null && homepage.isNotEmpty) || hasSettings;

    // A plugin's history can be longer than the window is tall, so the card
    // stops at the golden section of the window's height and the changes
    // scroll inside it. The picture gives way too, in a low window, rather than
    // pushing the rest of the card off its bottom edge.
    final tallest = MediaQuery.sizeOf(context).height / kGoldenRatio;
    final bannerHeight = kAboutSplashSize.height < tallest * 0.4
        ? kAboutSplashSize.height
        : tallest * 0.4;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: tallest),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (picture != null)
            SizedBox(
              width: kAboutSplashSize.width,
              height: bannerHeight,
              child: Image.memory(
                picture,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
            ),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Heading(manifest: manifest, appearance: appearance, ink: ink),
                  if (description != null && description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: appearance.scaled(12),
                        color: ink.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Flexible(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: AboutColumn(
                            title: tr('Recent changes'),
                            appearance: appearance,
                            menu: menu,
                            children: [
                              if (changes.isEmpty)
                                AboutQuiet(
                                  text: tr(
                                    'This plugin keeps no list of its changes.',
                                  ),
                                  appearance: appearance,
                                  menu: menu,
                                )
                              else
                                Flexible(
                                  child: KeyboardScrollable(
                                    hasKeyboard: true,
                                    builder: (controller) =>
                                        SingleChildScrollView(
                                      controller: controller,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          for (final change in changes)
                                            _Change(
                                              change: change,
                                              appearance: appearance,
                                              ink: ink,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (hasLinks) ...[
                          const SizedBox(width: 14),
                          SizedBox(
                            width: 210,
                            child: AboutColumn(
                              title: tr('Plugin'),
                              appearance: appearance,
                              menu: menu,
                              children: [
                                if (homepage != null && homepage.isNotEmpty)
                                  AboutRow(
                                    label: tr('Website'),
                                    hint: homepage,
                                    icon: Icons.language_outlined,
                                    appearance: appearance,
                                    menu: menu,
                                    onPressed: () {
                                      Navigator.of(context).maybePop();
                                      unawaited(ShellOpen.open(homepage));
                                    },
                                  ),
                                if (hasSettings)
                                  AboutRow(
                                    label: tr('Settings'),
                                    icon: Icons.tune,
                                    appearance: appearance,
                                    menu: menu,
                                    onPressed: () {
                                      Navigator.of(context).maybePop();
                                      unawaited(showPluginSettings(
                                        context,
                                        manifest: manifest,
                                        registry: plugins,
                                      ));
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Divider(height: 1, color: ink.withValues(alpha: 0.14)),
                  const SizedBox(height: 8),
                  // What the card is about, in one line, as the application's
                  // card ends: which plugin exactly, and whose.
                  Text(
                    [
                      manifest.id,
                      if (manifest.author?.isNotEmpty ?? false) manifest.author!,
                      if (manifest.isBundled) tr('Ships with the application'),
                    ].join('  ·  '),
                    style: TextStyle(
                      fontSize: appearance.scaled(10.5),
                      color: ink.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The plugin's mark, its name, and the version beside it in a light face —
/// the way the application's card writes its own number.
class _Heading extends StatelessWidget {
  const _Heading({
    required this.manifest,
    required this.appearance,
    required this.ink,
  });

  final PluginManifest manifest;
  final AppearanceSettings appearance;
  final Color ink;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconTheme(
        data: IconThemeData(color: ink),
        child: SizedBox.square(
          dimension: appearance.scaled(32),
          child: Center(
            child: pluginArtwork(manifest, size: appearance.scaled(32)),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: manifest.displayName,
                style: TextStyle(
                  fontSize: appearance.scaled(17),
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(
                text: '   ${manifest.version}',
                style: TextStyle(
                  fontSize: appearance.scaled(13),
                  fontWeight: FontWeight.w300,
                  color: ink.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          style: TextStyle(color: ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

/// One version: its number, and a line for each thing that changed in it.
///
/// The number and nothing else. The file keeps a date beside it, and the card
/// leaves it there: which version is the question, not when it was.
class _Change extends StatelessWidget {
  const _Change({
    required this.change,
    required this.appearance,
    required this.ink,
  });

  final PluginChange change;
  final AppearanceSettings appearance;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final text = TextStyle(fontSize: appearance.scaled(12), color: ink);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            change.version,
            style: text.copyWith(fontWeight: FontWeight.w600),
          ),
          for (final note in change.notes)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 2, top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: text.copyWith(color: ink.withValues(alpha: 0.6))),
                  Expanded(child: Text(note, style: text)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
