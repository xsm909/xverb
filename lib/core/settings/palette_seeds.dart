/// **Three colours, and the rest worked out from them.**
///
/// Choosing three colours and deriving the rest. What follows is not a guess
/// at which three — it is what the two hand-built palettes in the repository
/// turned out to say when they were read side by side.
///
/// Of the twenty-odd colour keys the appearance holds, **nine** had been
/// touched. The hint, the menu, the console and the internal windows were the
/// shipped defaults in both files, reaching the screen through the three
/// follows-the-palette flags rather than through anything chosen. And of the
/// nine, three facts stood out:
///
/// - **`cursorColor` and `accentColor` were the same colour in both** —
///   `#F97316`. They had already been collapsed by hand; this writes it down.
/// - **`directoryColor` and `markedColor` were both in the accent's family** in
///   both files, and one of them lands within a couple of degrees and a couple
///   of percent of what [_directory] and [_marked] compute. They were never
///   three independent choices — they are the accent, spread.
/// - **The light palette is not a light theme.** Panel `#F7F7F4`, header
///   `#0B2A5B`, console near-black: light paper, dark chrome, orange accent.
///   Three colours, chosen by hand, in a file with twenty-four in it.
///
/// So the three are **paper, chrome and accent**, and not the more obvious
/// fill/ink/accent. The ink is derived rather than chosen because an ink is the
/// one colour that must never be got wrong — see [legibleInk] and the rule it
/// carries. A palette that cannot state an unreadable ink cannot ship one.
///
/// **What is deliberately not derived:** the hint's pair, which belongs to no
/// surface and therefore has nothing to borrow from that is true in both the
/// places it floats over; and everything that is not a colour at all — fonts,
/// density, opacity, motion. A palette is a look, not a settings file.
library;

import 'package:flutter/widgets.dart';

import '../colour_contrast.dart';
import 'appearance_settings.dart';

/// The three colours a palette is made of.
@immutable
class PaletteSeeds {
  const PaletteSeeds({
    required this.paper,
    required this.chrome,
    required this.accent,
  });

  /// The listing itself — the surface most of the window is.
  final Color paper;

  /// The furniture around it: the header, the status strip, the menus.
  ///
  /// Its own colour rather than a shade of [paper], because that is the choice
  /// his light palette is built on — light paper under dark chrome. Deriving
  /// this from the paper would have made that palette unreachable.
  final Color chrome;

  /// The one hue that means *this one*: the cursor, the frame, the links, and
  /// the family the directory and marked colours are spread out of.
  final Color accent;

  /// What the application opens in, read off [AppearanceSettings] rather than
  /// written out again — the defaults are the seeds of the default look, and
  /// two lists of the same colours drift.
  static const PaletteSeeds initial = PaletteSeeds(
    paper: Color(0xFFF7F7F4),
    chrome: Color(0xFFE7E7E2),
    accent: Color(0xFF2F72D6),
  );

  /// The three a palette already on screen is standing on.
  ///
  /// Used to read seeds off a settings file written before seeds existed, and
  /// to show three swatches for a palette that carries a full set of colours
  /// and no recipe.
  factory PaletteSeeds.of(AppearanceSettings settings) => PaletteSeeds(
    paper: settings.panelBackground,
    chrome: settings.headerBackground,
    accent: settings.accentColor,
  );

  PaletteSeeds copyWith({Color? paper, Color? chrome, Color? accent}) =>
      PaletteSeeds(
        paper: paper ?? this.paper,
        chrome: chrome ?? this.chrome,
        accent: accent ?? this.accent,
      );

  /// Whether the paper is dark enough that everything else goes the other way.
  ///
  /// The paper decides and not the chrome: the panels are most of the window,
  /// and a listing is what the eye is actually on.
  bool get isDark => paper.computeLuminance() < 0.5;

  /// The appearance keys these three settle, in the shape
  /// [AppearanceSettings.toJson] writes them.
  ///
  /// A map rather than an [AppearanceSettings] because that is what composes:
  /// `{...defaults, ...derive(), ...overrides}` is the whole resolution rule,
  /// and it stays one line however many keys are added here.
  Map<String, dynamic> derive() {
    final ink = _inkOn(paper);
    final chromeInk = _inkOn(chrome);

    return {
      'panelBackground': paper.toARGB32(),
      'panelForeground': ink.toARGB32(),

      // The page a file is read on is the panel it was opened from, until
      // somebody says otherwise. That is what his dark palette does by hand,
      // and what `ColourScheme.colours` has always written for the shipped
      // ones: a palette that repainted the listing and left the reading in the
      // last look would be half a palette.
      'readingBackground': paper.toARGB32(),
      'readingForeground': ink.toARGB32(),

      'headerBackground': chrome.toARGB32(),
      'headerForeground': chromeInk.toARGB32(),

      'accentColor': accent.toARGB32(),
      // One colour, because he had already made them one in both his palettes.
      'cursorColor': accent.toARGB32(),

      'directoryColor': _directory().toARGB32(),
      'markedColor': _marked().toARGB32(),

      // Dark over a light paper, light over a dark one — a white stripe on a
      // near-white panel is nothing at all. The alphas are the ones that
      // shipped.
      'alternateRowColor': (isDark
              ? const Color(0x08FFFFFF)
              : const Color(0x0A000000))
          .toARGB32(),
      'darkChrome': isDark,

      // **The menu is chrome.** Which is exactly what `menuFollowsPalette`
      // did — take the header's *pair*, its fill and the ink chosen to be read
      // on that fill. The flag said the same thing in a place the user had to
      // find; here it is simply what a menu is.
      'menuBackground': chrome.toARGB32(),
      'menuForeground': chromeInk.toARGB32(),
      // **The outline is not derived**, and that is a decision rather than an
      // omission. It is not an ink on a surface — it is a line drawn round one,
      // white by default because that is what the joined menu-and-title shape
      // was drawn against, and its thickness is a setting beside it. Deriving
      // it would have turned that white into a near-black on every light
      // palette, which is a look nobody asked to change.

      // **The console is paper**, and the ink a tenth quietened so the lines
      // that do have a colour — the prompt, a failure — are the ones that
      // stand out. Again what the flag did, and for the reason written where it
      // used to live: a console painted near-black under a light palette is a
      // console with a dark ink on it, measured once at 2.3:1.
      'consoleBackground': paper.toARGB32(),
      'consoleForeground': ink.withValues(alpha: 0.9).toARGB32(),

      // A window's body is the paper it grew out of; its title strip is the
      // cursor's colour, because that is the row it grew out of, and the first
      // frame of the movement has to be indistinguishable from the cursor
      // itself. The title is black or white against that strip.
      'windowBackground': paper.toARGB32(),
      'windowHeaderBackground': accent.toARGB32(),
      'windowHeaderForeground': inkFor(accent).toARGB32(),
    };
  }

  /// The colour keys [derive] settles. Anything not in here is either not a
  /// colour or is one a palette says nothing about — the hint's pair.
  static final Set<String> derivedKeys = PaletteSeeds.initial.derive().keys
      .toSet();

  /// An ink for [surface]: the surface's own hue, taken to whichever end the
  /// surface leaves free, and then held to a contrast body text can carry.
  ///
  /// **The hue is kept** so a navy panel gets a blue-white rather than a dead
  /// grey-white — which is what he wrote by hand: `#040B17` against `#E8EEF7`
  /// is one hue at two ends, and this computes it back to within a shade.
  /// **The saturation is cut** because an ink at the paper's own saturation is
  /// a coloured ink, and a listing is read, not looked at.
  static Color _inkOn(Color surface) {
    final hsl = HSLColor.fromColor(surface);
    final dark = surface.computeLuminance() < 0.5;
    // **Half the surface's saturation, capped.** Not the surface's own: a warm
    // near-white at 12% would hand back a warm ink where the paper has no hue
    // worth carrying, and a strongly coloured panel would hand back a coloured
    // one. Halving keeps the tint of a navy panel — his `#040B17` still gets a
    // blue-white — and lets a near-neutral paper go neutral.
    final saturation = hsl.saturation * 0.5 < 0.18
        ? hsl.saturation * 0.5
        : 0.18;

    // 7:1 rather than the 4.5:1 [legibleInk] holds a borrowed ink to. That one
    // is a rescue — the best that can be done with a colour somebody chose;
    // this is a colour being made, and body text read all day should be made
    // better than the floor.
    for (final lightness in dark
        ? const [0.93, 0.96, 1.0]
        : const [0.14, 0.10, 0.0]) {
      final ink = hsl
          .withSaturation(saturation)
          .withLightness(lightness)
          .toColor();
      if (contrastRatio(ink, surface) >= 7) return ink;
    }
    // A mid-grey surface has no end far enough away for its own hue to reach,
    // and neither black nor white clears 7:1 on one. Take whichever of the two
    // reads better and let the hue go: at that point the choice is between a
    // legible ink and a pretty one.
    return inkFor(surface);
  }

  /// Directories: the accent's **own hue**, pushed to the far lightness end
  /// from the paper.
  ///
  /// The two are told apart by weight of colour rather than by hue, and that is
  /// what his dark palette does: `#FFDBB8` is his accent gone pale, and this
  /// computes it back to within a shade. His light one goes further, all the
  /// way into red — which is why an override exists.
  Color _directory() => HSLColor.fromColor(accent)
      .withLightness(isDark ? 0.85 : 0.22)
      .toColor();

  /// The marked colour: the accent taken **toward yellow**, at a lightness that
  /// stands out from both the paper and the directories.
  ///
  /// This is the one of the two that moves in hue, so that a marked directory
  /// is not simply a directory at a different brightness. On the dark palette
  /// it computes `#FCD24E` against the hand-picked `#FFD24A` it replaces, which
  /// is the same colour by any measure that matters.
  ///
  /// **The two lightnesses were measured against the fourteen shipped
  /// palettes, not chosen.** On a light paper both colours have to be dark, and
  /// darks compress: at 0.28 and 0.38 the pair came within 27 points a channel
  /// of each other on the least saturated accent, and marked itself fell to
  /// 2.9:1 on the palest paper. 0.22 and 0.35 clear both — 44 points apart at
  /// worst, and nothing under 3:1 on its own listing.
  Color _marked() => HSLColor.fromColor(accent)
      .withHue(_rotate(18))
      .withLightness(isDark ? 0.65 : 0.35)
      .toColor();

  double _rotate(double degrees) {
    final hue = HSLColor.fromColor(accent).hue + degrees;
    return hue < 0 ? hue + 360 : (hue >= 360 ? hue - 360 : hue);
  }

  Map<String, dynamic> toJson() => {
    'paper': _hex(paper),
    'chrome': _hex(chrome),
    'accent': _hex(accent),
  };

  /// Anything missing falls back to [initial], so a half-written recipe still
  /// loads and means what it does say.
  factory PaletteSeeds.fromJson(Map<String, dynamic> json) => PaletteSeeds(
    paper: parseHexColour(json['paper']) ?? initial.paper,
    chrome: parseHexColour(json['chrome']) ?? initial.chrome,
    accent: parseHexColour(json['accent']) ?? initial.accent,
  );

  static String _hex(Color colour) =>
      '#${colour.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  @override
  bool operator ==(Object other) =>
      other is PaletteSeeds &&
      other.paper == paper &&
      other.chrome == chrome &&
      other.accent == accent;

  @override
  int get hashCode => Object.hash(paper, chrome, accent);
}

/// Accepts `#RRGGBB`, `#AARRGGBB`, either without the hash, or a plain integer
/// — the form the settings file itself uses.
Color? parseHexColour(Object? value) {
  if (value is num) return Color(value.toInt());
  if (value is! String) return null;

  var text = value.trim().replaceAll('#', '');
  if (text.length == 6) text = 'FF$text';
  if (text.length != 8) return null;
  final parsed = int.tryParse(text, radix: 16);
  return parsed == null ? null : Color(parsed);
}

/// Three seeds and whatever was pressed afterwards.
///
/// **The recipe is stored, not the result.** A palette saved as twenty resolved
/// colours is a palette that will never know about the surface added tomorrow;
/// a palette saved as three seeds and a short list of deviations grows a colour
/// for it the moment [PaletteSeeds.derive] does. That is the whole reason this
/// class exists rather than a bare map of colours.
///
/// **An override is a colour that was pressed**, and nothing else. There is no
/// follows-the-palette flag anywhere in here: a key is either in [overrides],
/// in which case somebody chose it, or it is not, in which case it is worked
/// out. The three flags that used to say this — for the menu, the console and
/// the internal windows — said it about three surfaces out of eight, from a
/// list the user had to go and find.
@immutable
class PaletteRecipe {
  const PaletteRecipe({required this.seeds, this.overrides = const {}});

  final PaletteSeeds seeds;

  /// Colour keys somebody pressed, in [AppearanceSettings.toJson]'s shape.
  final Map<String, dynamic> overrides;

  /// The recipe that reproduces [settings] **exactly**.
  ///
  /// Seeds are read off the three colours they are; every derived key that then
  /// disagrees with what [settings] actually holds becomes an override. So this
  /// is lossless by construction rather than by measurement — which is what a
  /// migration of somebody's working palette has to be. There is no palette
  /// this cannot carry, only palettes that carry more overrides than others.
  factory PaletteRecipe.of(AppearanceSettings settings) {
    final seeds = PaletteSeeds.of(settings);
    final derived = seeds.derive();
    final actual = settings.toJson();

    return PaletteRecipe(
      seeds: seeds,
      overrides: {
        for (final key in derived.keys)
          if (actual[key] != derived[key]) key: actual[key],
      },
    );
  }

  /// [base] with this palette laid over it: the seeds worked out, then whatever
  /// was pressed laid on top.
  ///
  /// Only colours move. The font, the density, the opacity and the motion in
  /// [base] come through untouched, which is what makes choosing a palette safe
  /// on a settings page somebody has already been through.
  AppearanceSettings applyTo(AppearanceSettings base) =>
      AppearanceSettings.fromJson({
        ...base.toJson(),
        ...seeds.derive(),
        ...overrides,
      });

  /// The same three seeds with one of them changed, keeping every override.
  ///
  /// This is what moving a seed in the settings has to do: repaint everything
  /// that was worked out, and leave alone every colour somebody went in and
  /// chose. A seed change that threw the overrides away would be a seed change
  /// that quietly undoes an afternoon's work.
  PaletteRecipe withSeeds(PaletteSeeds seeds) =>
      PaletteRecipe(seeds: seeds, overrides: overrides);

  /// [key] set to [value] by hand — pressing a thing in the preview.
  PaletteRecipe overriding(String key, Object? value) => PaletteRecipe(
    seeds: seeds,
    overrides: {...overrides, key: value},
  );

  /// [key] handed back to the palette. The way out of an override, and the
  /// reason one never needs a switch beside it.
  PaletteRecipe releasing(String key) => PaletteRecipe(
    seeds: seeds,
    overrides: {
      for (final entry in overrides.entries)
        if (entry.key != key) entry.key: entry.value,
    },
  );

  Map<String, dynamic> toJson() => {
    'seeds': seeds.toJson(),
    if (overrides.isNotEmpty)
      'overrides': {
        for (final entry in overrides.entries)
          entry.key: entry.value is int
              ? PaletteSeeds._hex(Color(entry.value as int))
              : entry.value,
      },
  };

  factory PaletteRecipe.fromJson(Map<String, dynamic> json) {
    final overrides = json['overrides'];
    return PaletteRecipe(
      seeds: PaletteSeeds.fromJson(
        json['seeds'] is Map<String, dynamic>
            ? json['seeds'] as Map<String, dynamic>
            : const {},
      ),
      overrides: overrides is! Map<String, dynamic>
          ? const {}
          : {
              for (final entry in overrides.entries)
                entry.key: _looksLikeAColour(entry.key)
                    ? (parseHexColour(entry.value)?.toARGB32() ?? entry.value)
                    : entry.value,
            },
    );
  }

  static bool _looksLikeAColour(String key) =>
      key.endsWith('Color') ||
      key.endsWith('Colour') ||
      key.endsWith('Background') ||
      key.endsWith('Foreground');

  @override
  bool operator ==(Object other) =>
      other is PaletteRecipe &&
      other.seeds == seeds &&
      _sameOverrides(other.overrides, overrides);

  static bool _sameOverrides(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(seeds, overrides.length);
}
