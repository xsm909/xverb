import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../i18n/i18n.dart';
import 'appearance_settings.dart';
import 'palette_seeds.dart';

/// A named appearance, saved to a file so it can be passed around.
///
/// **It used to be a list of ten colours**, which is not what saving the
/// current palette has to mean: everything is saved, and it has to stay that
/// way as settings go on being added.
/// A palette that carries the panel's colours and forgets the font, the
/// density, the opacity and the console's own pair is a palette that half
/// arrives.
///
/// So a scheme is **whatever appearance keys it carries** — not a fixed list —
/// and two things follow from that one decision:
///
/// - **Saving carries everything by construction.** [ColourScheme.of] takes
///   `settings.toJson()` whole, so a setting added tomorrow is in every
///   palette saved after it without a line being written here. A snapshot
///   written field by field would silently miss the next one, and nobody would
///   notice until a palette was passed around.
/// - **Applying changes only what the scheme names.** The built-in palettes
///   name colours and nothing else, so choosing one still leaves the font size
///   and the window's own colours exactly where they were — which is the rule
///   this class was written with and which is worth keeping. A palette saved
///   from the *whole* appearance names everything, and so restores everything.
@immutable
class ColourScheme {
  const ColourScheme({
    required this.name,
    required this.settings,
    this.author,
    this.recipe,
  });

  /// A palette written as **what it is made of** rather than as what it came
  /// out as: three seeds, and whatever was pressed afterwards.
  ///
  /// This is the form every palette shipped with the application now takes, and
  /// the form *Save palette* writes. The reason is the one that made the seeds
  /// worth having at all: a palette saved as twenty resolved colours can never
  /// know about the surface added tomorrow, and a palette saved as a recipe
  /// grows a colour for it the moment [PaletteSeeds.derive] does.
  factory ColourScheme.palette({
    required String name,
    required PaletteSeeds seeds,
    Map<String, dynamic> overrides = const {},
    String? author,
  }) {
    final recipe = PaletteRecipe(seeds: seeds, overrides: overrides);
    return ColourScheme(
      name: name,
      author: author,
      recipe: recipe,
      // Kept in step for anything that reads the flat keys — the swatches, a
      // hand-editor, an older build. The recipe is what actually applies.
      settings: {
        ...recipe.seeds.derive(),
        ...recipe.overrides,
      },
    );
  }

  /// The appearance this palette was saved from, whole.
  factory ColourScheme.of(
    AppearanceSettings settings, {
    required String name,
    String? author,
  }) => ColourScheme(name: name, author: author, settings: settings.toJson());

  /// A palette that names colours and leaves everything else alone — the shape
  /// the ones shipped with the application have.
  factory ColourScheme.colours({
    required String name,
    required Color panelBackground,
    required Color panelForeground,
    required Color directoryColor,
    required Color markedColor,
    required Color cursorColor,
    required Color accentColor,
    required Color headerBackground,
    required Color headerForeground,
    required Color alternateRowColor,
    required bool darkChrome,
    String? author,
  }) => ColourScheme(
    name: name,
    author: author,
    settings: {
      'panelBackground': panelBackground.toARGB32(),
      'panelForeground': panelForeground.toARGB32(),
      // The reading page takes the panel's pair rather than being an argument
      // of its own. A shipped palette is a *look*, and a look that repainted
      // the listing and left the page it opens in the last look would be half
      // a palette — the same complaint that made a scheme carry everything.
      // Anyone wanting the page a different colour presses it, and their own
      // saved palette carries what they pressed.
      'readingBackground': panelBackground.toARGB32(),
      'readingForeground': panelForeground.toARGB32(),
      'directoryColor': directoryColor.toARGB32(),
      'markedColor': markedColor.toARGB32(),
      'cursorColor': cursorColor.toARGB32(),
      'accentColor': accentColor.toARGB32(),
      'headerBackground': headerBackground.toARGB32(),
      'headerForeground': headerForeground.toARGB32(),
      'alternateRowColor': alternateRowColor.toARGB32(),
      'darkChrome': darkChrome,
    },
  );

  final String name;

  /// Free text, shown under the name. Whoever made the scheme.
  final String? author;

  /// The appearance keys this palette carries, in the same shape
  /// [AppearanceSettings.toJson] writes them. Anything absent is a thing the
  /// palette says nothing about.
  final Map<String, dynamic> settings;

  /// The three seeds this palette is grown from, when it was written as a
  /// recipe. Null for a palette that is a list of colours — a file saved before
  /// seeds existed, or a whole appearance saved as one.
  final PaletteRecipe? recipe;

  /// Whether this is a palette or a whole settings file.
  ///
  /// **The file says which it is now**, rather than the reader guessing from
  /// how many keys are in it. Two commands write these — *Save palette* and
  /// *Save all settings* — and a file that does not say which it is is a file
  /// that gets applied the wrong way round: a palette treated as settings
  /// carries a font nobody asked for, and settings treated as a palette lose
  /// one somebody chose.
  bool get isWholeAppearance => recipe == null && settings.length > 24;

  /// The three colours to draw for this palette in a list.
  ///
  /// A palette written as a recipe has them; one written as a list of colours
  /// has them read back off it, which is exact — see [PaletteSeeds.of].
  PaletteSeeds get swatch => recipe?.seeds ?? PaletteSeeds.of(preview);

  /// What one of these looks like on its own, for the swatches in the list:
  /// the defaults with whatever it carries laid over them.
  AppearanceSettings get preview => applyTo(const AppearanceSettings());

  /// The current settings with this palette laid over them.
  ///
  /// A recipe is applied as a recipe — seeds worked out, then the pressed
  /// colours — so choosing it leaves the settings holding a palette rather than
  /// a set of colours that happen to agree with one.
  AppearanceSettings applyTo(AppearanceSettings current) =>
      recipe?.applyTo(current) ??
      AppearanceSettings.fromJson({...current.toJson(), ...settings});

  /// Colours are written as `#AARRGGBB`, because a scheme is meant to be read
  /// and edited by hand before it is passed on.
  ///
  /// Which keys those are is read off their names rather than kept in a list:
  /// a list is the thing that goes stale, and getting this wrong costs a
  /// number written in decimal, which reads back exactly the same.
  Map<String, dynamic> toJson() => {
    'name': name,
    if (author != null && author!.isNotEmpty) 'author': author,
    // **The file says what it is.** A reader that had to count keys to tell a
    // palette from a settings file would get it wrong on the day somebody saved
    // a palette with a lot of pressed colours in it.
    'kind': recipe != null || !isWholeAppearance ? 'palette' : 'settings',
    if (recipe != null) ...recipe!.toJson(),
    if (recipe == null)
      for (final entry in settings.entries)
        entry.key: _looksLikeAColour(entry.key) && entry.value is int
            ? _hex(Color(entry.value as int))
            : entry.value,
  };

  /// Anything missing falls back to the defaults rather than failing, so a
  /// half-written scheme still loads and shows what it does have — and an old
  /// one, which carried ten colours and nothing else, goes on meaning exactly
  /// what it always meant.
  factory ColourScheme.fromJson(
    Map<String, dynamic> json, {
    String? fallbackName,
  }) {
    final name = (json['name'] as String?)?.trim().isNotEmpty == true
        ? (json['name'] as String).trim()
        : (fallbackName ?? tr('Untitled'));
    final author = (json['author'] as String?)?.trim();

    // A recipe if it has seeds. Which is not the same test as `kind`, on
    // purpose: `kind` is what the file *says*, and this is what it *holds* —
    // a hand-written file with three seeds in it and no kind is a palette, and
    // reading it as one is more useful than telling its author off.
    if (json['seeds'] is Map<String, dynamic>) {
      final recipe = PaletteRecipe.fromJson(json);
      return ColourScheme.palette(
        name: name,
        author: author,
        seeds: recipe.seeds,
        overrides: recipe.overrides,
      );
    }

    return ColourScheme(
      name: name,
      author: author,
      settings: {
        for (final entry in json.entries)
          if (entry.key != 'name' &&
              entry.key != 'author' &&
              entry.key != 'kind')
            entry.key: entry.value,
      },
    );
  }

  static bool _looksLikeAColour(String key) =>
      key.endsWith('Color') ||
      key.endsWith('Colour') ||
      key.endsWith('Background') ||
      key.endsWith('Foreground');

  static String _hex(Color colour) =>
      '#${colour.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  /// Accepts `#RRGGBB`, `#AARRGGBB`, either without the hash, or a plain
  /// integer — the form the settings file itself uses.
  ///
  /// One implementation, in `palette_seeds.dart`, kept reachable under the name
  /// it has been called by since palettes were only ten colours.
  static Color? parseColour(Object? value) => parseHexColour(value);
}

/// The schemes on offer: the ones that ship with the app, and whatever the user
/// has dropped into their own folder.
///
/// A scheme is a file so that it can be passed around. Somebody works one out,
/// posts the file, and everyone else drops it in the folder and restarts the
/// list — no export format to agree on, because the file *is* the format.
class ColourSchemeLibrary {
  const ColourSchemeLibrary._();

  /// The palettes that ship with the application: **seven light, seven dark**,
  /// one of them the classic Norton Commander.
  ///
  /// Every one of them is **three colours**. That is the whole point of the
  /// exercise and it is worth stating as a constraint rather than as a
  /// coincidence: a preset that needed a fourth would be a preset saying the
  /// derivation is not good enough, and the place to fix that is the
  /// derivation. The one exception is deliberate and is explained where it
  /// stands.
  ///
  /// **Xverb Light was XCmd Light, then X2D Light**, and it follows the
  /// product name because it *is* the product name — a palette called after an
  /// older spelling of the application is a palette that dates it. Nothing
  /// breaks: which palette is on is matched on the recipe, never on a stored
  /// name.
  ///
  /// Light first, and *Xverb Light* first of all, because it is what the
  /// application opens in: the defaults in `AppearanceSettings` are these three
  /// seeds, so that row is the way back after anything has been pressed.
  ///
  /// Not `const`: a recipe holds a map, and a map is not a constant expression.
  /// Built once, at first use.
  static final List<ColourScheme> builtIn = [
    // ---- light -----------------------------------------------------------
    ColourScheme.palette(
      name: 'Xverb Light',
      seeds: const PaletteSeeds(
        paper: Color(0xFFF7F7F4),
        chrome: Color(0xFFE7E7E2),
        accent: Color(0xFF2F72D6),
      ),
      // The two colours the shipped look has always had that three seeds do not
      // compute: a pale cursor rather than the accent itself, and the deep blue
      // directories that came with it. They are what this palette *is*, and
      // overrides are how a palette says so.
      overrides: {
        'cursorColor': 0xFFBBD4F5,
        'directoryColor': 0xFF12447A,
        'markedColor': 0xFFB5460F,
        'windowHeaderBackground': 0xFFBBD4F5,
        'windowHeaderForeground': 0xFF000000,
      },
    ),
    ColourScheme.palette(
      name: 'Parchment',
      seeds: const PaletteSeeds(
        paper: Color(0xFFFBF7EF),
        chrome: Color(0xFFEFE7D8),
        accent: Color(0xFFB45309),
      ),
    ),
    ColourScheme.palette(
      name: 'Solar',
      seeds: const PaletteSeeds(
        paper: Color(0xFFFDF6E3),
        chrome: Color(0xFFEEE8D5),
        accent: Color(0xFF268BD2),
      ),
    ),
    ColourScheme.palette(
      name: 'Nordic',
      seeds: const PaletteSeeds(
        paper: Color(0xFFECEFF4),
        chrome: Color(0xFFD8DEE9),
        accent: Color(0xFF5E81AC),
      ),
    ),
    ColourScheme.palette(
      name: 'Mint',
      seeds: const PaletteSeeds(
        paper: Color(0xFFF2FAF6),
        chrome: Color(0xFFDDEFE6),
        accent: Color(0xFF0F766E),
      ),
    ),
    ColourScheme.palette(
      name: 'Rose',
      seeds: const PaletteSeeds(
        paper: Color(0xFFFDF4F5),
        chrome: Color(0xFFF3E2E5),
        accent: Color(0xFFBE123C),
      ),
    ),
    // **Light paper under dark chrome**, a shape three seeds make reachable
    // and a two-colour scheme cannot express at all. It is not a dark theme and
    // it is not a light one.
    ColourScheme.palette(
      name: 'Ink and Paper',
      seeds: const PaletteSeeds(
        paper: Color(0xFFF7F7F4),
        chrome: Color(0xFF0B2A5B),
        accent: Color(0xFFF97316),
      ),
    ),

    // ---- dark ------------------------------------------------------------
    // **The one preset with a reason to override.** Norton Commander is not a
    // look somebody is choosing, it is a look somebody remembers, and the CGA
    // palette it was drawn in cannot be derived from anything: cyan text on
    // blue, white directories, yellow on the marked ones. Deriving *near* it
    // and calling that Norton would be worse than not shipping it.
    ColourScheme.palette(
      name: 'Norton Commander',
      seeds: const PaletteSeeds(
        paper: Color(0xFF0000A8),
        chrome: Color(0xFF000078),
        accent: Color(0xFF54FCFC),
      ),
      overrides: {
        'panelForeground': 0xFF54FCFC,
        'readingForeground': 0xFF54FCFC,
        'directoryColor': 0xFFFCFCFC,
        'markedColor': 0xFFFCFC54,
        'cursorColor': 0xFF00A8A8,
      },
    ),
    ColourScheme.palette(
      name: 'Commander Blue',
      seeds: const PaletteSeeds(
        paper: Color(0xFF0B2A5B),
        chrome: Color(0xFF081F42),
        accent: Color(0xFF4C9AFF),
      ),
    ),
    ColourScheme.palette(
      name: 'Midnight',
      seeds: const PaletteSeeds(
        paper: Color(0xFF11141B),
        chrome: Color(0xFF0A0C11),
        accent: Color(0xFF6C8EFF),
      ),
    ),
    ColourScheme.palette(
      name: 'Ember',
      seeds: const PaletteSeeds(
        paper: Color(0xFF040B17),
        chrome: Color(0xFF040810),
        accent: Color(0xFFF97316),
      ),
    ),
    ColourScheme.palette(
      name: 'Forest',
      seeds: const PaletteSeeds(
        paper: Color(0xFF0F1A14),
        chrome: Color(0xFF0A120D),
        accent: Color(0xFF4ADE80),
      ),
    ),
    ColourScheme.palette(
      name: 'Plum',
      seeds: const PaletteSeeds(
        paper: Color(0xFF17101F),
        chrome: Color(0xFF100B16),
        accent: Color(0xFFC084FC),
      ),
    ),
    ColourScheme.palette(
      name: 'Lagoon',
      seeds: const PaletteSeeds(
        paper: Color(0xFF0C1A1A),
        chrome: Color(0xFF081313),
        accent: Color(0xFF2DD4BF),
      ),
    ),
  ];

  /// Where the user's own schemes live. Created on first use.
  static Future<Directory> folder() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'schemes'));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  /// Every `.json` in the folder, sorted by name. A file that will not parse is
  /// skipped rather than taking the list down with it.
  static Future<List<ColourScheme>> user() async {
    try {
      final directory = await folder();
      final files = await directory
          .list()
          .where((entity) => entity is File && p.extension(entity.path) == '.json')
          .cast<File>()
          .toList();

      final schemes = <ColourScheme>[];
      for (final file in files) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is! Map<String, dynamic>) continue;
          schemes.add(ColourScheme.fromJson(
            decoded,
            fallbackName: p.basenameWithoutExtension(file.path),
          ));
        } on Object {
          // One unreadable file must not hide the rest.
        }
      }
      schemes.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return schemes;
    } on Object {
      return const [];
    }
  }

  /// Writes [scheme] into the folder and hands back the file.
  static Future<File> save(ColourScheme scheme) async {
    final directory = await folder();
    final file = File(p.join(directory.path, '${_fileName(scheme.name)}.json'));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(scheme.toJson()),
    );
    return file;
  }

  /// A name a file system will accept, without being clever about it.
  static String _fileName(String name) {
    final cleaned = name
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), '-');
    return cleaned.isEmpty ? 'scheme' : cleaned.toLowerCase();
  }
}
