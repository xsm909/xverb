import 'package:flutter/material.dart';

import '../colour_contrast.dart';
import 'motion.dart';
import 'palette_seeds.dart';

/// A weight on the 100–900 scale, as the [FontWeight] Flutter draws it with.
///
/// **No `fontVariations`, deliberately.** The first cut set a `wght` variation
/// alongside the weight, on the theory that a static family would read the
/// weight and a variable one the variation, so both would be served. It buys
/// nothing: the scale steps in hundreds, so every value it can produce is
/// already exactly one of [FontWeight]'s nine, and Flutter puts `fontWeight`
/// onto a variable family's `wght` axis by itself. A variation is worth setting
/// for a value *between* the steps, or for an axis that is not weight, and
/// there are neither here — so it was two ways of saying one thing, and the
/// quieter one is enough.
class FontWeightSpec {
  FontWeightSpec(this.value)
    : weight = FontWeight.values[((value ~/ 100) - 1).clamp(0, 8)];

  /// The weight asked for, on the 100–900 scale.
  final int value;

  /// The same, as one of the nine Flutter knows.
  final FontWeight weight;
}

/// [base] moved [steps] places along [FontWeight]'s nine, and no further.
///
/// This is how a weight the application wrote down itself — a dialog title at
/// w600, the menu strip at w500 — follows the interface weight setting. The
/// same argument as `AppearanceSettings.scaled` for sizes: the number at the
/// call site goes on saying what it always said (a title is a step above the
/// text under it) and moves with the setting as well.
///
/// Clamped at both ends rather than wrapped, so a shift that would run off the
/// scale flattens the difference instead of turning it over.
FontWeight shiftFontWeight(FontWeight base, int steps) =>
    FontWeight.values[(FontWeight.values.indexOf(base) + steps).clamp(0, 8)];

/// Backdrop drawn behind the window on desktop.
///
/// Anything other than [opaque] needs a transparent window, which is why the
/// panels also pick up [AppearanceSettings.panelOpacity] — with fully opaque
/// panels there would be nothing for the blur to show through.
enum WindowBackdrop {
  /// No effect; panels are drawn solid. The only option on mobile.
  opaque,

  /// Windows 10/11 acrylic, macOS vibrancy: blurred, tinted backdrop.
  acrylic,

  /// Windows 11 mica: the desktop wallpaper, heavily blurred.
  mica,

  /// Fully transparent window with no blur at all.
  transparent;

  String get label => switch (this) {
    WindowBackdrop.opaque => 'Opaque',
    WindowBackdrop.acrylic => 'Acrylic',
    WindowBackdrop.mica => 'Mica',
    WindowBackdrop.transparent => 'Transparent',
  };
}

/// Which key opens quick search.
///
/// There is **one** quick search. These are two ways of reaching it, not two
/// searches: the same box appears at the bottom left, with the same caret in
/// it and the same keys inside it, whichever one opened it.
enum QuickSearchOpener {
  /// Opens the box empty, and the name is typed into it.
  ///
  /// The first one built, and the default until 1.0.0.409.
  altS,

  /// Opens the box already holding the letter that was pressed, which is one
  /// keystroke to the first match.
  ctrlAltLetter,

  /// No opening key at all: a letter typed in a panel *is* the search, and the
  /// box comes up already holding it.
  ///
  /// The one thing it takes away is typing a command straight into the panel,
  /// and that is the trade this setting makes: the command line
  /// belongs to the console, Ctrl+Down puts the keyboard in there, and while
  /// it is in there the search is not listening.
  ///
  /// **The default since 1.0.0.409.** A settings file written before the
  /// setting existed has no key for it and therefore arrives here — which is
  /// the right answer, because this is the new default rather than a migration
  /// of an old choice, but it does mean an upgrade changes what a letter does
  /// in a panel.
  typing;

  String get label => switch (this) {
    QuickSearchOpener.altS => 'Alt+S',
    QuickSearchOpener.ctrlAltLetter => 'Ctrl+Alt+letter',
    QuickSearchOpener.typing => 'Typing',
  };
}

/// What 1.0.0.121 to .124 wrote, back when the two openers were two searches.
String? _legacyOpener(Map<String, dynamic> json) {
  return switch (json['quickSearchStyle']) {
    'box' => QuickSearchOpener.altS.name,
    'letter' => QuickSearchOpener.ctrlAltLetter.name,
    _ => null,
  };
}

/// The speeds offered for [AppearanceSettings.animationScale].
///
/// The setting itself is a number, not one of these: these are the four points
/// on it worth pressing a button for. A settings file edited by hand may hold
/// any value between 0 and 1 and the application will honour it — the control
/// simply shows nothing selected, which is the truth.
///
/// The numbers live in `motion.dart` with every other animation number.
enum AnimationSpeed {
  off(kAnimationOff),
  fast(kAnimationFast),
  normal(kAnimationNormal),
  slow(kAnimationSlow);

  const AnimationSpeed(this.scale);

  final double scale;

  String get label => switch (this) {
    AnimationSpeed.off => 'Off',
    AnimationSpeed.fast => 'Fast',
    AnimationSpeed.normal => 'Normal',
    AnimationSpeed.slow => 'Slow',
  };

  /// The preset a saved number is exactly, or null if it is between two of
  /// them. Deliberately exact: rounding 0.37 to Fast would show a button
  /// pressed that nobody pressed.
  static AnimationSpeed? matching(double scale) {
    for (final speed in AnimationSpeed.values) {
      if (speed.scale == scale) return speed;
    }
    return null;
  }
}

/// How a live row answers the pointer: by moving, or by growing.
///
/// One question with two good answers, so it is a setting rather than a
/// decision. Both say the same thing — *this row is under the pointer* — and
/// both are built out of the same lengths and curves in `motion.dart`; only the
/// property being animated differs. The distances and the multipliers live
/// there too, one pair each.
enum LiveListMotion {
  /// The icon and the name step aside. `kRowHoverLean`, `kRowCursorLean`.
  slide,

  /// The icon and the name grow where they are. `kRowHoverScale`,
  /// `kRowCursorScale`. Drawn rather than laid out, so nothing around the row
  /// moves and the columns stay where they are.
  scale;

  String get label => switch (this) {
    LiveListMotion.slide => 'Slide',
    LiveListMotion.scale => 'Scale',
  };
}

/// How a folder opening and a folder being left are shown.
///
/// **All four say the same thing about the fade and differ only in what the
/// direction is said with.** The listing being left goes out over the first
/// half, the rows are exchanged at the midpoint where there is nothing on
/// screen to see it, and the listing arrived in comes in over the second —
/// that is [kListingSwapDuration] and it does not change here. What changes is
/// the half of the movement that states *which way you went*: nothing, size,
/// distance, or both at once.
///
/// A move that is neither in nor out — a drive, a path typed into the bar, a
/// set of results — is a plain fade under all of them, because it is not deeper
/// or shallower than where you were and a movement has to state something true.
enum FolderSwapMotion {
  /// A cut: the folder is simply open, the way it was before 1.0.0.322. No
  /// copy of the listing is taken and no timeline runs — an animation of no
  /// length is not the same thing as no animation.
  none,

  /// The listing being left grows and passes the eye, the one arrived in comes
  /// forward from behind. `kListingSwapZoom`.
  depth,

  /// The listing travels sideways: in towards the middle of the window, out
  /// towards the edge the panel sits on. `kListingSwapSlide`.
  slide,

  /// Both at once — it comes forward *and* moves across.
  both;

  /// Whether the listing changes size under this one.
  bool get hasDepth =>
      this == FolderSwapMotion.depth || this == FolderSwapMotion.both;

  /// Whether the listing travels sideways under this one.
  bool get hasSlide =>
      this == FolderSwapMotion.slide || this == FolderSwapMotion.both;

  String get label => switch (this) {
    FolderSwapMotion.none => 'None',
    FolderSwapMotion.depth => 'Depth',
    FolderSwapMotion.slide => 'Slide',
    FolderSwapMotion.both => 'Both',
  };
}

/// How an internal window comes out of the row it was asked at.
///
/// **One question with two good answers, so it is a setting rather than a
/// decision** — the same shape as [LiveListMotion] and [FolderSwapMotion], and
/// for the same reason. Both say the same true thing, that *this row opened
/// into this window*; both run on one timeline at `kWindowArriveDuration` and
/// use the same curves. Only what says it differs.
///
/// There is no `none` here, unlike a folder opening. That one is the exception
/// offered to a panel of thousands of rows; a window is one thing arriving, and
/// "no animation" is what the speed setting's Off already means.
enum WindowArriveMotion {
  /// The row becomes the whole window at once: the cursor's rectangle grows
  /// and turns into the dialog, everything in it arriving together.
  ///
  /// It fades as it comes, and that is not decoration — a window squashed into
  /// the height of one row is a form with its buttons on top of its title, and
  /// what the fade buys is that nobody sees it until it has room to be itself.
  whole,

  /// The row becomes the window's **title bar**, and the form unfolds out from
  /// under it.
  ///
  /// No fade at all: the title strip is the cursor's own colour, so the first
  /// frame is a bar the size and colour of the cursor, exactly where the cursor
  /// is — indistinguishable from it. Fade that in and the movement begins by
  /// admitting there are two things.
  unfold;

  String get label => switch (this) {
    WindowArriveMotion.whole => 'Whole',
    WindowArriveMotion.unfold => 'Unfold',
  };
}

/// How dense the file rows are drawn.
enum PanelDensity { compact, normal, comfortable }

extension PanelDensityMetrics on PanelDensity {
  /// Extra vertical padding added to a row on top of the text height.
  double get verticalPadding => switch (this) {
    PanelDensity.compact => 1,
    PanelDensity.normal => 3,
    PanelDensity.comfortable => 7,
  };

  String get label => switch (this) {
    PanelDensity.compact => 'Compact',
    PanelDensity.normal => 'Normal',
    PanelDensity.comfortable => 'Comfortable',
  };
}

/// Every colour and metric the panels draw with.
///
/// The defaults are **Xverb Light**, the palette of the same name in
/// [ColourSchemeLibrary.builtIn] — a near-white page with near-black on it.
/// The classic orthodox-commander look, white text on a deep blue panel, is
/// still one press away as Commander Blue; it is no longer what an install
/// opens in. Everything here is editable from the Appearance settings page.
@immutable
class AppearanceSettings {
  const AppearanceSettings({
    this.panelBackground = const Color(0xFFF7F7F4),
    // **The inks are what Xverb Light derives**, to four points a channel of
    // the near-blacks that were written here by hand. That is not a look being
    // changed — nobody can see the difference between two near-blacks — it is
    // the defaults and the palette of the same name being made literally the
    // same thing, so that choosing Xverb Light after pressing something is a
    // way back rather than an approximate one.
    this.panelForeground = const Color(0xFF272721),
    this.readingBackground = const Color(0xFFF7F7F4),
    this.readingForeground = const Color(0xFF272721),
    // A light yellow ground with dark blue on it, and the one note in the
    // application that is *not* in the palette — a hint is
    // paper pinned to the window, and it is meant to be told apart from
    // everything it floats over at a glance.
    this.hintBackground = const Color(0xFFFDF3C7),
    this.hintForeground = const Color(0xFF0B2A5B),
    this.directoryColor = const Color(0xFF12447A),
    this.markedColor = const Color(0xFFB5460F),
    this.cursorColor = const Color(0xFFBBD4F5),
    this.accentColor = const Color(0xFF2F72D6),
    this.headerBackground = const Color(0xFFE7E7E2),
    this.headerForeground = const Color(0xFF252522),
    this.fontFamily = '',
    this.fileFontFamily = '',
    this.fontSize = defaultFontSize,
    this.extensionLetters = defaultExtensionLetters,
    this.sizeDigits = defaultSizeDigits,
    this.modifiedDigits = defaultModifiedDigits,
    this.density = PanelDensity.normal,
    // The defaults are what the listing has always drawn: plain files at
    // regular, directories a step up, emphasis a step above that. The
    // interface sits at regular too, which is Material's own body weight —
    // so at the default nothing outside the panels moves at all.
    this.fileWeight = 400,
    this.directoryWeight = 600,
    this.strongWeight = 700,
    this.uiWeight = defaultUiWeight,
    this.weightOffset = 0,
    this.panelBorderWidth = 1,
    // **Typing, since 1.0.0.409.** It is the opener with nothing to learn —
    // you type the name of the file you are looking for — and the trade it
    // makes is deliberate: the command line is the console's, and Ctrl+Down is
    // the way into it.
    this.quickSearchOpener = QuickSearchOpener.typing,
    this.showAboutAtStart = true,
    this.showHidden = false,
    this.nativeIcons = false,
    this.monochromeIcons = false,
    this.showGridLines = false,
    this.alternateRowShading = true,
    // Dark, not light: a white stripe over a near-white panel is nothing at
    // all — the same reasoning the palette itself carries.
    this.alternateRowColor = const Color(0x0A000000),
    this.darkChrome = false,
    this.backdrop = WindowBackdrop.opaque,
    this.panelOpacity = 0.82,
    // **The defaults are now what the palette derives, not what used to sit
    // behind a flag.** These three, and the four below them, were the colours
    // stored *beside* `menuFollowsPalette`, `consoleFollowsPalette` and
    // `windowFollowsPalette` — reachable only by turning one off, and never on
    // screen at the defaults. With the flags gone they would have read as
    // colours somebody had chosen, and the default look would have arrived with
    // a near-black console in it.
    //
    // So each is written out as what the flag actually produced: the header's
    // pair for a menu, the panel's for a console, the panel and the cursor for
    // a window. The shipped look does not move a pixel, and the defaults are
    // now a palette rather than a palette plus seven exceptions.
    this.menuBackground = const Color(0xFFE7E7E2),
    this.menuForeground = const Color(0xFF252522),
    this.menuBorderColor = const Color(0xFFFFFFFF),
    this.menuBorderWidth = 1,
    this.menuMonolith = true,
    this.menuOpacity = 0.6,
    this.menuBlur = 30,
    this.slidePanelOpacity = 0.78,
    this.invertCursorText = false,
    this.consoleBackground = const Color(0xFFF7F7F4),
    // The panel's ink at nine tenths, which is what following produced.
    this.consoleForeground = const Color(0xE6272721),
    this.windowBackground = const Color(0xFFF7F7F4),
    // The cursor's colour, because a window grows out of the row it was asked
    // at, and black on it because that is what reads on a pale blue.
    this.windowHeaderBackground = const Color(0xFFBBD4F5),
    this.windowHeaderForeground = const Color(0xFF000000),
    // The constant itself, not a copy of what it happens to say: it was written
    // out as 0.5 here, and the moment `motion.dart` was tuned the default and
    // the preset disagreed.
    this.animationScale = kAnimationNormal,
    this.animateLiveFileList = false,
    this.liveFileListMotion = LiveListMotion.slide,
    this.animateFileListCursor = false,
    this.folderChangeMotion = FolderSwapMotion.depth,
    this.windowArriveMotion = WindowArriveMotion.unfold,
  });

  /// Panel body colour — the blue background.
  final Color panelBackground;

  /// Default text colour for files.
  final Color panelForeground;

  /// The page a file is *read* on — everything Ctrl+Q opens, whatever shape
  /// the content turns out to be.
  ///
  /// **Its own colour rather than the panel's.** Reading and listing are two
  /// different jobs done at two different distances — a listing is glanced
  /// down, a page is read for minutes — and a palette that suits one need not
  /// suit the other. Until
  /// now the viewer painted itself in [panelBackground] and the markdown on it
  /// took Material's guess at an ink, so the page could not be set at all and
  /// the two halves of it did not even agree.
  ///
  /// It is *the* colour of the reading, not one of a dozen: the plaque behind
  /// a code block, the rule under a table heading, the wash behind an inline
  /// pill are all this pair mixed, never separate settings. Two knobs, and
  /// two knobs only — see [ReadingColours] for what is derived from them.
  ///
  /// The syntax colours are deliberately *not* derived: keywords, strings and
  /// numbers go on taking [directoryColor], [markedColor] and [accentColor]
  /// from the palette: three roles on two knobs is a loss of control, not a
  /// simplification.
  final Color readingBackground;

  /// What is *written* on that page. The body ink; everything quieter than the
  /// body is this colour with the alpha taken off it.
  final Color readingForeground;

  /// What a [Hint] is drawn on — the bubble that says what something is when
  /// the pointer rests on it.
  ///
  /// **Its own pair**, added with the reading's. It had neither half of one
  /// before that: the bubble was the panel's ink laid a tenth over the
  /// *header's* fill, and written in the panel's ink — a fill from one place
  /// and an ink from another, which is exactly how the menus came to have
  /// invisible rows in them before item 24.
  ///
  /// A hint is not chrome and not a page: it is the one thing on screen that
  /// belongs to no surface, floating over a panel one moment and a reading the
  /// next. That is the argument for it having colours rather than borrowing
  /// them — there is nothing for it to borrow *from* that is true in both
  /// places.
  ///
  /// **And the default is a note, not a shade of the palette** — light yellow
  /// with dark blue on it. So this is the one pair
  /// that does *not* inherit what was in force on the way in: a settings file
  /// written before 1.0.0.299 gets the yellow, because the yellow is the answer
  /// to what a hint should look like rather than a migration of what it did.
  ///
  /// The line round it is not a third setting. It is [hintForeground] at a
  /// fifth, the way every other edge in the application is the ink at a
  /// distance.
  final Color hintBackground;

  /// What a hint is written in.
  final Color hintForeground;

  /// Text colour for directories, traditionally brighter than files.
  final Color directoryColor;

  /// Text colour for entries the user has marked for an operation.
  final Color markedColor;

  /// Fill behind the row the keyboard cursor is on.
  final Color cursorColor;

  /// Highlight used for the focused panel's border and for controls.
  final Color accentColor;

  /// Column header and path bar background.
  final Color headerBackground;

  /// What is *written* on that background — the column headings, the path, the
  /// status line, the F-key row and the application's own title bar.
  ///
  /// One of two gaps closed together: the bar's background could be set and
  /// its writing could not, so a dark header under a light palette was a bar
  /// with invisible words on it. The pairing is the point — a background
  /// without an ink is half a colour.
  ///
  /// **No "follows the palette" switch**, unlike the dialog's and the console's:
  /// those have a *background* that may or may not be their own, and an ink that
  /// has to go with it. This ink is always the header's own, and its default is
  /// the panel's ink, so nothing moves until it is pressed
  /// ([[appearance-colours-are-pressed]]).
  final Color headerForeground;

  /// The family the application speaks in — menus, dialogs, settings, the title
  /// bar. Empty means the platform's default.
  ///
  /// Item 43 split the one family in two: the interface has a voice of its own
  /// and a listing has a job to do. This is the voice.
  final String fontFamily;

  /// The family a *name off a disk* is drawn in — the panels, the path bars and
  /// the console.
  ///
  /// Its own setting because the two are chosen for different reasons: a
  /// listing wants letters that can be told apart, `l` from `1` and `O` from
  /// `0`, and the interface wants to read well in a sentence.
  ///
  /// Empty means "whatever the interface is set to", which is what every
  /// settings file written before today says and exactly how the application
  /// drew before it — one family everywhere. See [fileFamily] and
  /// [consoleFamily] for what empty comes to in each place.
  final String fileFontFamily;

  /// What the interface is actually drawn in, or null for the platform's own.
  String? get uiFamily => fontFamily.isEmpty ? null : fontFamily;

  /// What a listing is drawn in: its own family, or the interface's when
  /// nothing has been chosen.
  String? get fileFamily => fileFontFamily.isEmpty ? uiFamily : fileFontFamily;

  /// What the console is drawn in.
  ///
  /// The one place where "nothing chosen" is not the interface's family:
  /// columns of output line up or they do not, so an unset console is fixed
  /// pitch, which is what it has always been.
  String get consoleFamily =>
      fileFontFamily.isEmpty ? 'monospace' : fileFontFamily;

  /// How wide the extension column is, **counted in letters rather than in
  /// pixels**.
  ///
  /// Which is the only unit that survives the font being changed: a column set
  /// to 52 pixels holds six letters at 13pt and three at 22pt, and the person
  /// who set it was thinking about letters both times. Three letters at the
  /// narrowest and ten at the widest: three is `mp3` and `zip`, and past ten
  /// there is nothing left to show that is not already a name.
  ///
  /// A letter here is an average one, measured from the file font in force —
  /// see `extensionColumnWidth` in the panel, which is where the measuring can
  /// be done.
  final int extensionLetters;

  static const int defaultExtensionLetters = 4;
  static const int minExtensionLetters = 3;
  static const int maxExtensionLetters = 10;

  /// The size column, counted in **digits** rather than letters.
  ///
  /// A different unit for a different column, and not pedantry: a digit is
  /// wider than an average letter in every font that has tabular figures, and
  /// these two columns hold nothing but figures. Counted in letters they would
  /// both come out short by a character or two — which is exactly the kind of
  /// almost-right that reads as a bug in the drawing.
  ///
  /// `123.4 MB` is eight, so the narrowest useful column is about five and the
  /// default has a little slack: the column is right-aligned and the slack is
  /// where the eye finds the edge of the number.
  final int sizeDigits;

  static const int defaultSizeDigits = 10;
  static const int minSizeDigits = 5;
  static const int maxSizeDigits = 14;

  /// The modified column, in digits as well.
  ///
  /// `2026-08-19 18:23` is sixteen characters and the default is sixteen. Below
  /// that the date is cut from the right, which is a thing somebody may well
  /// want — the time matters less than the day on most listings — so the floor
  /// is set where the date alone still fits rather than where the whole of it
  /// does.
  final int modifiedDigits;

  static const int defaultModifiedDigits = 16;
  static const int minModifiedDigits = 10;
  static const int maxModifiedDigits = 22;

  final double fontSize;

  /// What [fontSize] is when nobody has touched it.
  ///
  /// Named rather than repeated, because it is the pivot every other size turns
  /// around: at this value [scaled] and [fontScale] change nothing, so the
  /// application at its default size is the application as it was drawn.
  static const double defaultFontSize = 13;

  /// [fontSize] as a multiplier, for text whose size is not ours to set.
  ///
  /// Material's own text — menus, dialogs, list tiles, buttons — carries sizes
  /// from its text theme, and the way to move all of them at once is a factor.
  /// See `app.dart`, which applies this to the theme.
  double get fontScale => fontSize / defaultFontSize;

  /// A size drawn at the default, scaled to the size in force.
  ///
  /// The application's chrome is full of numbers that were chosen against a
  /// 13pt listing — a menu row at 13, a shortcut hint at 10, a window title at
  /// 12.5. They were right, and they were also frozen: the font size setting
  /// moved the panels and left everything around them where it was, so at 20pt
  /// the listing grew and the menus it opened did not. Written as
  /// `theme.scaled(10)` the number keeps saying what it always said — a hint is
  /// three points under a row — and follows the setting as well.
  double scaled(double base) => base * fontScale;

  final PanelDensity density;

  /// What plain file rows are drawn at, on the 100–900 scale fonts use.
  ///
  /// The one weight of the three that is a weight. The other two are distances
  /// from it, so this is the number that moves the listing as a whole.
  final int fileWeight;

  /// What directory rows are drawn at, and never lighter than [fileWeight].
  ///
  /// A weight, plainly — not a distance from the one below it. That was tried
  /// and it made the setting unreadable: a slider that says `+200` and a number
  /// beside it that says `600` is arithmetic where a weight was wanted. The
  /// rule it was protecting is kept by **where the slider starts**: with files
  /// at 200 the directory slider runs 200 to 900, so a folder lighter than the
  /// files around it is not somewhere you can drag to.
  ///
  /// [resolvedDirectoryWeight] holds the same floor for anything that did not
  /// come from the slider — a settings file edited by hand, or a file weight
  /// raised past a directory weight already stored.
  final int directoryWeight;

  /// What the application says loudly: column headers, and the row the reserve
  /// is being held for.
  ///
  /// Free, unlike [directoryWeight] — it has no floor and answers to nothing
  /// below it. The pair that has to hold its order is files and directories,
  /// because they sit in the same listing and are told apart by weight;
  /// emphasis is somewhere else on the screen and is nobody's comparison.
  final int strongWeight;

  /// What the application says in its own voice: menus, dialogs, settings
  /// forms, buttons, the title bar — everything that is not a file listing.
  ///
  /// The fourth weight, and the only one that is not about the panels. The
  /// other three are read together, because files and directories sit in one
  /// listing and are told apart by weight; this one is read against nothing,
  /// so it has no floor and no ceiling but the scale.
  ///
  /// **A pivot, not a flat weight.** It reaches the interface as a *shift* of
  /// [defaultUiWeight] applied to Material's own weights — see [uiWeightShift]
  /// — so ordinary text is drawn at exactly the number on the slider while a
  /// label that Material draws a step heavier stays a step heavier. Setting one
  /// weight on everything would have flattened that hierarchy, which is the
  /// same mistake the font size setting avoided by being a factor rather than a
  /// size.
  final int uiWeight;

  /// What [uiWeight] is when nobody has touched it, and the weight Material
  /// draws ordinary body text at.
  ///
  /// The pivot the shift turns around: at this value [uiWeightShift] is zero
  /// and the interface is Material's, untouched.
  static const int defaultUiWeight = 400;

  /// Added to all four at once, which is the one knob for "denser everywhere".
  ///
  /// An offset rather than four more numbers, because it keeps the differences
  /// between them intact by construction — the reason to reach for it is a
  /// new screen or a new family, and neither of those is a reason to re-decide
  /// how far apart files and folders should sit.
  final int weightOffset;

  /// The scale the three sit on, and the step they move in.
  ///
  /// A hundred is what a font family actually offers. `FontWeight` has nine
  /// values and nothing between them, and a static family carries the two or
  /// three faces it was drawn with — ask for 500 from a family that ships
  /// Regular and Bold and you get Regular, the same pixels. A finer slider
  /// would move without the screen changing, which is the way a setting comes to
  /// look broken.
  ///
  /// A *variable* family has no such steps, and [FontWeightSpec] carries a
  /// `wght` variation as well so those move exactly where they are put.
  static const int weightMinimum = 100;
  static const int weightMaximum = 900;
  static const int weightStep = 100;

  /// How far [weightOffset] may push, either way.
  static const int weightOffsetLimit = 300;

  /// Reads a stored weight, or the default when it is not one of the steps.
  ///
  /// Not clamped — snapped and rejected. A file edited by hand, or written by a
  /// build with a different scale, must not be able to put 450 on a family that
  /// would then draw it as something nobody picked.
  static int _weight(Object? stored, int fallback) =>
      stored is int &&
          stored >= weightMinimum &&
          stored <= weightMaximum &&
          stored % weightStep == 0
      ? stored
      : fallback;

  static int _offset(Object? stored, int fallback) =>
      stored is int &&
          stored.abs() <= weightOffsetLimit &&
          stored % weightStep == 0
      ? stored
      : fallback;

  int _onScale(int value) => value.clamp(weightMinimum, weightMaximum);

  /// [directoryWeight], held at or above [fileWeight].
  ///
  /// The slider cannot go below it, so in normal use this changes nothing. It
  /// is here for the two cases the slider does not cover: a settings file that
  /// was edited by hand, and a file weight raised past a directory weight that
  /// was stored when it was lower. A folder lighter than the files around it is
  /// the one arrangement the pair exists to rule out, and it should not depend
  /// on which order the two sliders were touched in.
  int get resolvedDirectoryWeight =>
      directoryWeight < fileWeight ? fileWeight : directoryWeight;

  /// The three as drawn: the directory floor applied, then each shifted by
  /// [weightOffset] and kept on the scale. Clamping is monotonic, so the
  /// ceiling can bring files and directories level but never turn them over.
  FontWeightSpec get fileFontWeight =>
      FontWeightSpec(_onScale(fileWeight + weightOffset));
  FontWeightSpec get directoryFontWeight =>
      FontWeightSpec(_onScale(resolvedDirectoryWeight + weightOffset));
  FontWeightSpec get strongFontWeight =>
      FontWeightSpec(_onScale(strongWeight + weightOffset));
  FontWeightSpec get uiFontWeight =>
      FontWeightSpec(_onScale(uiWeight + weightOffset));

  /// [uiFontWeight] as a number of steps from [defaultUiWeight].
  ///
  /// What actually reaches the interface. Material's text theme carries a
  /// weight per style — body at 400, labels and titles at 500 — and those are
  /// a hierarchy, not a set of numbers to overwrite. Shifting them all by the
  /// same number of steps keeps the hierarchy and still puts plain body text
  /// at the weight on the slider, because body text is where the pivot was
  /// taken from. See `scaledTypography` in `ui/text_scale.dart`, which is
  /// where it is applied, and `text_scale_test`, which measures it.
  int get uiWeightShift => (uiFontWeight.value - defaultUiWeight) ~/ weightStep;

  /// A weight the application wrote down itself, moved by [uiWeightShift].
  ///
  /// The counterpart of [scaled] for weights. Material's own text follows the
  /// setting through the typography without anything opting in, but a style
  /// that names its weight in our code — the menu strip, a dialog title, a
  /// section heading in the settings — wins that merge and would otherwise sit
  /// still while everything around it moved.
  FontWeight uiWeightFor(FontWeight base) =>
      shiftFontWeight(base, uiWeightShift);

  /// How thick a panel's frame is, in logical pixels. A whole number of them.
  ///
  /// A setting because the right answer depends on the screen. One logical pixel
  /// is one device pixel at 100% and two on a Retina panel, so the frame that
  /// reads correctly on a desk monitor can come out hairline on a laptop.
  ///
  /// **Whole numbers only, and that is not a formality.** At 1.5 the frame lands
  /// on half-pixel boundaries and two holes come out of it: `Container` reserves
  /// exactly the border's width, so the listing began half a pixel in and the
  /// cursor row's leftmost pixel was half fill over dark panel — a gap between
  /// the cursor and the frame it should be touching. Around a rounded corner it
  /// is worse, because a 1.5 stroke spread along an arc of radius
  /// [panelCornerRadius] never covers a whole pixel, so the arc came out at less
  /// than half strength and the frame visibly broke at all four corners.
  /// [panelBorderWidths] is the list offered, and every entry on it is an
  /// integer for that reason.
  final int panelBorderWidth;

  /// The widths a panel frame may be. Kept beside the setting so the control and
  /// the clamp cannot drift apart.
  static const List<int> panelBorderWidths = [1, 2, 3];

  /// Which key opens quick search.
  final QuickSearchOpener quickSearchOpener;

  /// Whether the About card comes up when the application starts.
  ///
  /// **On, because that is what it is for.** It is Blender's splash: the way
  /// back into where you were working, offered at the one moment somebody has
  /// not yet decided where they are going. A card that has to be asked for is a
  /// card nobody asks for.
  ///
  /// And off, because Blender has that switch too and for the same reason: it
  /// is shown every single time, and every single time is a lot.
  final bool showAboutAtStart;

  /// Whether dotfiles are listed.
  final bool showHidden;

  /// Draw the desktop's own icons for files and folders instead of the built-in
  /// set.
  ///
  /// Off by default, and the built-in set stays: it is one shape per kind of
  /// thing, it costs nothing, and it is the same on every machine — which is
  /// worth keeping for anyone who prefers a listing that does not change
  /// character with what happens to be installed.
  final bool nativeIcons;

  /// Draw those native icons in the panel's own colours rather than their own.
  ///
  /// Only meaningful with [nativeIcons] on. The shape comes from the desktop and
  /// the colour from the palette, so a folder stays the folder colour and a marked
  /// row stays the marked colour — a listing that reads as one thing rather than
  /// as a row of stickers.
  final bool monochromeIcons;

  /// Vertical separators between columns.
  final bool showGridLines;

  /// Subtle striping to make long listings easier to scan.
  final bool alternateRowShading;

  /// What that striping is painted with.
  ///
  /// Laid over the panel, so it wants to be mostly transparent. The default is
  /// white at three per cent, which lifts a dark panel; on a light palette it
  /// does nothing at all, which is why this is a setting and not a constant.
  final Color alternateRowColor;

  /// Dark window chrome around the panels.
  final bool darkChrome;

  /// Desktop backdrop effect. Ignored on mobile.
  final WindowBackdrop backdrop;

  /// Applied to panel and header fills when [backdrop] is not opaque.
  final double panelOpacity;

  /// What a menu is *written* in.
  ///
  /// Asked for on 2026-08-15: the context menu needs a colour setting, ground
  /// and text. The fill had a setting and the ink did not, so a menu
  /// painted dark under a light palette was a menu with invisible rows in it —
  /// the same gap item 24 closed for the header, and the same answer: a
  /// background without an ink is half a colour.
  final Color menuForeground;

  /// The line round a menu — and, when the menu belongs to a title on the menu
  /// strip, round the pair of them together.
  ///
  /// Its own colour rather than the accent's, added along with the joined
  /// outline. White by default, which is what the join was drawn against.
  final Color menuBorderColor;

  /// How thick that line is, in logical pixels. One, two or three: past three it
  /// stops being an outline and becomes a frame the menu sits inside.
  final int menuBorderWidth;

  /// Whether a menu and the title it was opened from are drawn as one shape.
  ///
  /// A switch between the old way and the new, so the monolith can be turned
  /// off. Off, the menu is a panel of
  /// its own with its own outline all the way round, and the title stays the
  /// selector it was — which is how it was drawn until 1.0.0.240.
  ///
  /// It does not touch where the menu *opens*: under the title either way,
  /// which was a separate fix and not part of this.
  final bool menuMonolith;

  /// Menu fill.
  final Color menuBackground;

  /// How solid menus are. This is what decides whether the blur behind them is
  /// visible at all: at full opacity there is nothing to see through.
  final double menuOpacity;

  /// Blur radius behind menus, in logical pixels. Zero turns it off.
  final double menuBlur;

  /// How solid a panel that slides over the reading is — the node properties,
  /// and the document structure after them.
  ///
  /// **Its own number rather than the menu's.** A menu
  /// is glanced at and dismissed; a panel is *read from* while the thing
  /// underneath stays visible, and the two want different amounts of the
  /// window showing through. It still takes the menu's blur: one blurred
  /// surface in the application, set in one place.
  final double slidePanelOpacity;

  /// When true the row under the cursor is written in whatever contrasts with
  /// [cursorColor] instead of in its own colour.
  ///
  /// Off by default, because the colour a name is written in is information —
  /// a directory, a marked file — and inverting throws it away. On is for the
  /// palette where it costs nothing and buys everything: a black cursor under
  /// black text leaves the row under the cursor unreadable, which is the one
  /// row you are looking at.
  final bool invertCursorText;

  /// What the cursor row is written in when [invertCursorText] is on: black or
  /// white, whichever can actually be read on the cursor.
  ///
  /// **The same measurement [inkFor] makes, and for the same reason.** This
  /// used to be its own `luminance > 0.5` threshold, which is not the question
  /// and gets a band of strong mid colours wrong: on the shipped `#F97316`
  /// cursor it chose white, at 2.8:1, where black on that orange is 7.4:1. One
  /// implementation now, so the cursor row and a window's title strip cannot
  /// answer the same colour two different ways.
  Color get cursorForeground => inkFor(cursorColor);

  /// The console's fill.
  final Color consoleBackground;

  /// What a line of it is written in when nothing else has claimed the line —
  /// *default* text: a prompt, a failure and a remark keep their own colours,
  /// and this is what everything else is.
  final Color consoleForeground;

  /// Body fill of an internal window.
  final Color windowBackground;

  /// Title-strip fill of an internal window, likewise.
  final Color windowHeaderBackground;

  /// What an internal window writes its title in.
  ///
  /// Its own, for the same reason its background is its own: a form given a
  /// colour of its own so it has an edge against the panels had nothing to
  /// write its title in but the file-row colour.
  final Color windowHeaderForeground;

  /// The palette these colours are: three seeds, and the keys somebody pressed.
  ///
  /// **Worked out rather than stored, and it costs nothing to do so** — which
  /// is the reason no field, no migration and no settings key came with any of
  /// this. [PaletteRecipe.of] reads the seeds off the three colours that *are*
  /// the seeds and records every derived key that then disagrees, so a recipe
  /// resolved and read back is the recipe that went in. A settings file written
  /// before palettes existed therefore has one the moment it is asked, and a
  /// stale stored recipe — the failure a field here would have invited — cannot
  /// exist.
  PaletteRecipe get recipe => PaletteRecipe.of(this);

  /// The same appearance with one of the three seeds moved.
  ///
  /// Everything worked out from the seeds is repainted; every colour somebody
  /// pressed stays exactly where it was put. A seed change that threw the
  /// pressed colours away would quietly undo an afternoon's work.
  AppearanceSettings withSeeds(PaletteSeeds seeds) =>
      recipe.withSeeds(seeds).applyTo(this);

  /// [key] chosen by hand — what pressing a thing in the preview does.
  ///
  /// This is the whole of what the three `*FollowsPalette` flags used to do,
  /// and it works for every colour rather than for three surfaces out of eight.
  ///
  /// **The three seed colours move the seed instead of becoming overrides.**
  /// Pressing the panel *is* choosing the paper; recording it as a deviation
  /// from a paper it no longer resembles would leave the palette describing a
  /// look nobody is in, and would break the one property [recipe] rests on —
  /// that the seeds can always be read back off the colours.
  AppearanceSettings pressing(String key, Color colour) => switch (key) {
    'panelBackground' => withSeeds(recipe.seeds.copyWith(paper: colour)),
    'headerBackground' => withSeeds(recipe.seeds.copyWith(chrome: colour)),
    'accentColor' => withSeeds(recipe.seeds.copyWith(accent: colour)),
    _ => recipe.overriding(key, colour.toARGB32()).applyTo(this),
  };

  /// [key] handed back to the palette — the way out of an override, and the
  /// reason no colour needs a switch beside it.
  AppearanceSettings releasing(String key) =>
      recipe.releasing(key).applyTo(this);

  /// Whether [key] is a colour somebody chose rather than one worked out.
  ///
  /// What a "reset to the palette" affordance asks before offering itself.
  bool isPressed(String key) => recipe.overrides.containsKey(key);

  /// Height of a chrome strip that carries text at [fontSize] - 1: the column
  /// header, the status line, the breadcrumb steps, the location pill.
  ///
  /// These were a flat 22, which the font-size slider overran — its top
  /// setting is 22, so the text ended up taller than the strip holding it and
  /// Flutter drew its overflow stripes across the panel. The 22 survives as a
  /// floor so nothing moves at the usual sizes.
  double get chromeRowHeight {
    final height = (fontSize - 1) * 1.6;
    return height < 22 ? 22 : height;
  }

  /// The one hairline the chrome is divided by.
  ///
  /// A plain horizontal hairline, one pixel: under the main menu, under the
  /// tabs in the one-panel layout, and over the console. A line instead of a
  /// gap — the two-pixel border the panel used to keep round its strips went
  /// with it, so the path bar and the count at the bottom now run the width of
  /// the panel.
  ///
  /// One colour for all of them, in the header's own ink, because three
  /// hairlines at three alphas is three lines that do not look like the same
  /// idea.
  ///
  /// **A third, not a tenth.** At 0.15 the line came out at #5A6784 on the
  /// default palette and the path bar under it at #5B6986 — the same colour to
  /// within a value, so between the panels and the main menu there was no line
  /// to see at all. A rule has to read against **both** of the things it
  /// divides, and the two things here are usually two shades of the same
  /// chrome.
  Color get chromeRule => headerForeground.withValues(alpha: 0.3);

  /// Corner radius of the selection — the ring that marks the active panel.
  ///
  /// **The panels themselves are square.** They sit edge to edge and a rounded
  /// panel has to negotiate with the one beside it: two curves turning away
  /// from each other leave a notch at the join, first with the window's
  /// backdrop showing through it and then, once that was closed, with the fill.
  /// A square panel has no join to negotiate. The selection is a separate thing
  /// drawn over the top and can be as round as it likes, because it is never
  /// beside anything — there is one of it and it moves.
  ///
  /// A constant rather than a setting: it is the shape of the app, not a
  /// preference. Kept here so the panels and the preview of them cannot round
  /// differently, which they did — 5 against 4 is invisible side by side and
  /// wrong all the same.
  static const double panelCornerRadius = 8;

  /// How fast everything in the application moves, as a multiplier on the
  /// lengths in `motion.dart`. 0 to 1.
  ///
  /// One number for the whole application, and one place that multiplies by it
  /// — [animated]. Before this there were eight durations invented one at a
  /// time (90, 120, 140, 160, 180, 320…), which is not a set of decisions but a
  /// set of accidents; a scale that can be turned as a whole cannot drift.
  ///
  /// **0 means off, not instant.** Nothing is animated at 0: [animated] hands
  /// back [Duration.zero] and every controller jumps straight to its end state.
  /// Someone who has turned motion off is not asking for a one-millisecond
  /// animation, and the code path they get should be the one with no animation
  /// in it.
  ///
  /// The system's own "reduce motion" flag is deliberately not read. This is
  /// the application's setting, and one owner is better than two.
  final double animationScale;

  /// Whether the listing answers the pointer: a live list rather than a
  /// printed one.
  ///
  /// **Not about rows arriving, and not about scrolling.** Nothing here
  /// animates a listing being read, replaced or scrolled — a panel is thousands
  /// of rows, and animating their arrival is how a file manager gets slow and
  /// how a cursor comes to sit somewhere other than where it says it is. What
  /// this turns on is a row leaning aside — its icon and its name together —
  /// under the mouse and under the keyboard cursor: `kRowHoverLean` and
  /// `kRowCursorLean` in `motion.dart`, taken quickly and given back slowly, so
  /// a pointer swept down the listing leaves a wake.
  ///
  /// It was called `animateFileList` and meant rows fading as the contents
  /// changed, which was never built. The old key is not read: it answered a
  /// different question, and a yes to that one is not a yes to this.
  ///
  /// Off by default, and the switch is dead while [animationScale] is 0 —
  /// motion off means nothing moves, and this is motion.
  final bool animateLiveFileList;

  /// Which of the two answers a live row gives: stepping aside, or growing.
  ///
  /// Only consulted where [animateLiveFileList] is on. It changes what is
  /// animated and nothing else — the lengths, the curves and the wake are the
  /// same either way, because they are what the effect *is*.
  final LiveListMotion liveFileListMotion;

  /// Whether the cursor row animates on its way between rows.
  ///
  /// Separate from [animateLiveFileList] because it answers a different
  /// question: that one is about a listing answering the pointer, this one is
  /// about the mark that says which row the keyboard is on getting there.
  final bool animateFileListCursor;

  /// How opening a folder and leaving one are shown — see [FolderSwapMotion].
  ///
  /// **On by default, unlike the two above, because it is not the same kind of
  /// thing.** Those two put a ticker on every row of a listing that may hold
  /// thousands, and are offered as exceptions to "a listing does not animate".
  /// This is one fade over the panel however many rows are in it, and it is
  /// what rule number two asks for: a listing replaced in a single frame reads
  /// as a fault rather than as a different folder.
  ///
  /// [FolderSwapMotion.none] is a cut — the new folder is simply there, which
  /// is how it was before 1.0.0.322. Dead while [animationScale] is 0, like
  /// every other switch here: motion off means nothing moves.
  final FolderSwapMotion folderChangeMotion;

  /// How an internal window comes out of the row it was asked at, and goes
  /// back into it — see [WindowArriveMotion]. Dead at [animationScale] 0, like
  /// everything else.
  final WindowArriveMotion windowArriveMotion;

  /// Whether the exchange is drawn at all, for the places that only ask that
  /// much. Which of the two it is drawn with is the setting itself.
  bool get animateFolderChange => folderChangeMotion != FolderSwapMotion.none;

  /// One of the millisecond constants in `motion.dart`, scaled to the speed in
  /// force — the one place the multiplication happens.
  ///
  /// Every animated thing asks for its length through here, so that turning the
  /// setting turns all of them, and so that a site cannot quietly opt out by
  /// forgetting to multiply.
  Duration animated(int fullMs) => animationScale <= 0
      ? Duration.zero
      : Duration(microseconds: (fullMs * 1000 * animationScale).round());

  /// Whether anything moves at all. For the places that need to skip the
  /// machinery rather than run it with a zero length.
  bool get animates => animationScale > 0;

  /// The same for the taller path bar.
  double get pathBarHeight {
    final height = (fontSize - 1) * 2.1;
    return height < 30 ? 30 : height;
  }

  /// A menu's fill and the ink its rows are written in.
  ///
  /// **There is nothing to resolve here any more.** These four pairs used to be
  /// computed through a `*FollowsPalette` flag — take the header's pair, or the
  /// panel's, or the colour stored beside the flag. The palette works them out
  /// instead ([PaletteSeeds.derive]), and a colour somebody pressed is an
  /// override, so by the time a value reaches a field it is already the answer.
  /// The getters stay because the whole application calls them by these names,
  /// and because `effectiveMenuBackground` says *what a menu is painted in*
  /// rather more clearly than `menuBackground` does.
  Color get effectiveMenuBackground => menuBackground;

  Color get effectiveMenuForeground => menuForeground;

  Color get effectiveConsoleBackground => consoleBackground;

  Color get effectiveConsoleForeground => consoleForeground;

  Color get effectiveWindowBackground => windowBackground;

  /// Title-strip fill of an internal window — **the cursor's own colour**,
  /// because that is where the window comes from.
  ///
  /// A dialog grows out of the row the cursor is on, and it starts as a bar of
  /// exactly that row's size: in the cursor's colour the first frame of the
  /// movement is indistinguishable from the cursor itself, so what the eye sees
  /// is the row lifting off rather than something new appearing over it. The
  /// palette derives it from the accent, and the accent *is* the cursor.
  Color get effectiveWindowHeaderBackground => windowHeaderBackground;

  Color get effectiveWindowHeaderForeground => windowHeaderForeground;

  /// Panel fill as actually painted, accounting for the backdrop.
  Color get effectivePanelBackground => _translucent(panelBackground);

  /// Header and status-bar fill as actually painted.
  Color get effectiveHeaderBackground => _translucent(headerBackground);

  /// The reading page as actually painted. It takes the backdrop the same way
  /// a panel does: a page covers the route below rather than floating over it,
  /// so what shows through a translucent one is the window's own backdrop.
  Color get effectiveReadingBackground => _translucent(readingBackground);

  /// A hint's fill as actually painted. It has taken the backdrop since it was
  /// drawn on the header's fill, and goes on doing so now that the fill is its
  /// own — a bubble that turned solid the day it got a setting would be a
  /// change nobody asked for.
  Color get effectiveHintBackground => _translucent(hintBackground);

  Color _translucent(Color color) => backdrop == WindowBackdrop.opaque
      ? color
      : color.withValues(alpha: panelOpacity.clamp(0.0, 1.0));

  AppearanceSettings copyWith({
    Color? panelBackground,
    Color? panelForeground,
    Color? readingBackground,
    Color? readingForeground,
    Color? hintBackground,
    Color? hintForeground,
    Color? directoryColor,
    Color? markedColor,
    Color? cursorColor,
    Color? accentColor,
    Color? headerBackground,
    Color? headerForeground,
    String? fontFamily,
    String? fileFontFamily,
    double? fontSize,
    int? extensionLetters,
    int? sizeDigits,
    int? modifiedDigits,
    PanelDensity? density,
    int? fileWeight,
    int? directoryWeight,
    int? strongWeight,
    int? uiWeight,
    int? weightOffset,
    int? panelBorderWidth,
    QuickSearchOpener? quickSearchOpener,
    bool? showAboutAtStart,
    bool? showHidden,
    bool? nativeIcons,
    bool? monochromeIcons,
    bool? showGridLines,
    bool? alternateRowShading,
    Color? alternateRowColor,
    bool? darkChrome,
    WindowBackdrop? backdrop,
    double? panelOpacity,
    Color? menuBackground,
    Color? menuForeground,
    Color? menuBorderColor,
    int? menuBorderWidth,
    bool? menuMonolith,
    double? menuOpacity,
    double? slidePanelOpacity,
    double? menuBlur,
    bool? invertCursorText,
    Color? consoleBackground,
    Color? consoleForeground,
    Color? windowBackground,
    Color? windowHeaderBackground,
    Color? windowHeaderForeground,
    double? animationScale,
    bool? animateLiveFileList,
    LiveListMotion? liveFileListMotion,
    bool? animateFileListCursor,
    FolderSwapMotion? folderChangeMotion,
    WindowArriveMotion? windowArriveMotion,
  }) {
    return AppearanceSettings(
      panelBackground: panelBackground ?? this.panelBackground,
      panelForeground: panelForeground ?? this.panelForeground,
      readingBackground: readingBackground ?? this.readingBackground,
      readingForeground: readingForeground ?? this.readingForeground,
      hintBackground: hintBackground ?? this.hintBackground,
      hintForeground: hintForeground ?? this.hintForeground,
      directoryColor: directoryColor ?? this.directoryColor,
      markedColor: markedColor ?? this.markedColor,
      cursorColor: cursorColor ?? this.cursorColor,
      accentColor: accentColor ?? this.accentColor,
      headerBackground: headerBackground ?? this.headerBackground,
      headerForeground: headerForeground ?? this.headerForeground,
      fontFamily: fontFamily ?? this.fontFamily,
      fileFontFamily: fileFontFamily ?? this.fileFontFamily,
      fontSize: fontSize ?? this.fontSize,
      extensionLetters: extensionLetters ?? this.extensionLetters,
      sizeDigits: sizeDigits ?? this.sizeDigits,
      modifiedDigits: modifiedDigits ?? this.modifiedDigits,
      density: density ?? this.density,
      fileWeight: fileWeight ?? this.fileWeight,
      directoryWeight: directoryWeight ?? this.directoryWeight,
      strongWeight: strongWeight ?? this.strongWeight,
      uiWeight: uiWeight ?? this.uiWeight,
      weightOffset: weightOffset ?? this.weightOffset,
      panelBorderWidth: panelBorderWidth ?? this.panelBorderWidth,
      quickSearchOpener: quickSearchOpener ?? this.quickSearchOpener,
      showAboutAtStart: showAboutAtStart ?? this.showAboutAtStart,
      showHidden: showHidden ?? this.showHidden,
      nativeIcons: nativeIcons ?? this.nativeIcons,
      monochromeIcons: monochromeIcons ?? this.monochromeIcons,
      showGridLines: showGridLines ?? this.showGridLines,
      alternateRowShading: alternateRowShading ?? this.alternateRowShading,
      alternateRowColor: alternateRowColor ?? this.alternateRowColor,
      darkChrome: darkChrome ?? this.darkChrome,
      backdrop: backdrop ?? this.backdrop,
      panelOpacity: panelOpacity ?? this.panelOpacity,
      menuBackground: menuBackground ?? this.menuBackground,
      menuForeground: menuForeground ?? this.menuForeground,
      menuBorderColor: menuBorderColor ?? this.menuBorderColor,
      menuBorderWidth: menuBorderWidth ?? this.menuBorderWidth,
      menuMonolith: menuMonolith ?? this.menuMonolith,
      menuOpacity: menuOpacity ?? this.menuOpacity,
      slidePanelOpacity: slidePanelOpacity ?? this.slidePanelOpacity,
      menuBlur: menuBlur ?? this.menuBlur,
      invertCursorText: invertCursorText ?? this.invertCursorText,
      consoleBackground: consoleBackground ?? this.consoleBackground,
      consoleForeground: consoleForeground ?? this.consoleForeground,
      windowBackground: windowBackground ?? this.windowBackground,
      windowHeaderBackground:
          windowHeaderBackground ?? this.windowHeaderBackground,
      windowHeaderForeground:
          windowHeaderForeground ?? this.windowHeaderForeground,
      animationScale: animationScale ?? this.animationScale,
      animateLiveFileList: animateLiveFileList ?? this.animateLiveFileList,
      liveFileListMotion: liveFileListMotion ?? this.liveFileListMotion,
      animateFileListCursor:
          animateFileListCursor ?? this.animateFileListCursor,
      folderChangeMotion: folderChangeMotion ?? this.folderChangeMotion,
      windowArriveMotion: windowArriveMotion ?? this.windowArriveMotion,
    );
  }

  Map<String, dynamic> toJson() => {
    // **The marker that says the three `*FollowsPalette` flags are not coming.**
    //
    // Their absence used to mean "take the default", which was *on* for all
    // three, and that reading is still the right one for every file written
    // before 1.0.0.407 — it is what was on the screen. But a file written after
    // it has no flags either, and the same absence cannot mean two things: read
    // as a legacy file, a modern one would have its console repainted the
    // panel's colour every time it was loaded. So the new model says so out
    // loud, once, and [AppearanceSettings.fromJson] collapses the flags only
    // where this is missing.
    'paletteModel': 'seeds',
    'panelBackground': panelBackground.toARGB32(),
    'panelForeground': panelForeground.toARGB32(),
    'readingBackground': readingBackground.toARGB32(),
    'readingForeground': readingForeground.toARGB32(),
    'hintBackground': hintBackground.toARGB32(),
    'hintForeground': hintForeground.toARGB32(),
    'directoryColor': directoryColor.toARGB32(),
    'markedColor': markedColor.toARGB32(),
    'cursorColor': cursorColor.toARGB32(),
    'accentColor': accentColor.toARGB32(),
    'headerBackground': headerBackground.toARGB32(),
    'headerForeground': headerForeground.toARGB32(),
    'fontFamily': fontFamily,
    'fileFontFamily': fileFontFamily,
    'fontSize': fontSize,
    'extensionLetters': extensionLetters,
    'sizeDigits': sizeDigits,
    'modifiedDigits': modifiedDigits,
    'density': density.name,
    'fileWeight': fileWeight,
    'directoryWeight': directoryWeight,
    'strongWeight': strongWeight,
    'uiWeight': uiWeight,
    'weightOffset': weightOffset,
    'panelBorderWidth': panelBorderWidth,
    'quickSearchOpener': quickSearchOpener.name,
    'showAboutAtStart': showAboutAtStart,
    'showHidden': showHidden,
    'nativeIcons': nativeIcons,
    'monochromeIcons': monochromeIcons,
    'showGridLines': showGridLines,
    'alternateRowShading': alternateRowShading,
    'alternateRowColor': alternateRowColor.toARGB32(),
    'darkChrome': darkChrome,
    'backdrop': backdrop.name,
    'panelOpacity': panelOpacity,
    'menuBackground': menuBackground.toARGB32(),
    'menuForeground': menuForeground.toARGB32(),
    'menuBorderColor': menuBorderColor.toARGB32(),
    'menuBorderWidth': menuBorderWidth,
    'menuMonolith': menuMonolith,
    'menuOpacity': menuOpacity,
    'slidePanelOpacity': slidePanelOpacity,
    'menuBlur': menuBlur,
    'invertCursorText': invertCursorText,
    'consoleBackground': consoleBackground.toARGB32(),
    'consoleForeground': consoleForeground.toARGB32(),
    'windowBackground': windowBackground.toARGB32(),
    'windowHeaderBackground': windowHeaderBackground.toARGB32(),
    'windowHeaderForeground': windowHeaderForeground.toARGB32(),
    'animationScale': animationScale,
    'animateLiveFileList': animateLiveFileList,
    'liveFileListMotion': liveFileListMotion.name,
    'animateFileListCursor': animateFileListCursor,
    'folderChangeMotion': folderChangeMotion.name,
    'windowArriveMotion': windowArriveMotion.name,
  };

  factory AppearanceSettings.fromJson(Map<String, dynamic> json) {
    const defaults = AppearanceSettings();
    Color color(String key, Color fallback) {
      final value = json[key];
      if (value is num) return Color(value.toInt());
      // **`#AARRGGBB` as well as a number.** A palette file is meant to be
      // read and edited by hand, and it is read back through here now that a
      // saved palette is a whole appearance rather than a list of colours.
      if (value is String) {
        var text = value.trim().replaceAll('#', '');
        if (text.length == 6) text = 'FF$text';
        final parsed = text.length == 8 ? int.tryParse(text, radix: 16) : null;
        if (parsed != null) return Color(parsed);
      }
      return fallback;
    }

    // **The three `*FollowsPalette` flags, collapsed on the way in.** They are
    // gone from the model — a colour is now either derived from the palette or
    // pressed, and a flag is a third way of saying the first — but every
    // settings file and every palette written before 1.0.0.407 has them, and
    // each one decided what actually reached the screen. So each is read once,
    // here, and turned into the colour it stood for. A file with no flag in it
    // gets the default the flag had, which is *on* for all three: that is what
    // was in force, and inheriting what was in force is the same rule the
    // reading pair was migrated by.
    final panelBackground = color('panelBackground', defaults.panelBackground);
    final headerBackground = color(
      'headerBackground',
      defaults.headerBackground,
    );
    final headerForeground = color(
      'headerForeground',
      defaults.headerForeground,
    );
    final panelForeground = color('panelForeground', defaults.panelForeground);
    final cursorColor = color('cursorColor', defaults.cursorColor);

    // Only a file from before the flags went is read as having them.
    final legacy = json['paletteModel'] != 'seeds';
    final menuFollows = legacy && (json['menuFollowsPalette'] as bool? ?? true);
    final consoleFollows =
        legacy && (json['consoleFollowsPalette'] as bool? ?? true);
    final windowFollows =
        legacy && (json['windowFollowsPalette'] as bool? ?? true);

    return AppearanceSettings(
      panelBackground: panelBackground,
      panelForeground: panelForeground,
      // Falling back to the *panel's* colours rather than to the defaults,
      // which is what keeps every settings file written before 1.0.0.298
      // looking exactly as it did: the page took the panel's fill and the
      // panel's ink until it had a pair of its own, so inheriting them is
      // not a guess — it is the value that was in force.
      readingBackground: color(
        'readingBackground',
        color('panelBackground', defaults.panelBackground),
      ),
      readingForeground: color(
        'readingForeground',
        color('panelForeground', defaults.panelForeground),
      ),
      // The defaults, not what was in force: the hint's pair is a note pinned
      // to the window rather than a shade of the palette, so an old settings
      // file gets the yellow rather than the near-invisible bubble it had.
      hintBackground: color('hintBackground', defaults.hintBackground),
      hintForeground: color('hintForeground', defaults.hintForeground),
      directoryColor: color('directoryColor', defaults.directoryColor),
      markedColor: color('markedColor', defaults.markedColor),
      cursorColor: cursorColor,
      accentColor: color('accentColor', defaults.accentColor),
      headerBackground: headerBackground,
      headerForeground: headerForeground,
      fontFamily: json['fontFamily'] as String? ?? defaults.fontFamily,
      fileFontFamily:
          json['fileFontFamily'] as String? ?? defaults.fileFontFamily,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? defaults.fontSize,
      // Clamped on the way in as well as on the way out: a settings file from
      // a build that knew a different range must not draw a column nobody can
      // reach the edge of.
      extensionLetters:
          ((json['extensionLetters'] as num?)?.toInt() ??
                  defaults.extensionLetters)
              .clamp(minExtensionLetters, maxExtensionLetters),
      sizeDigits: ((json['sizeDigits'] as num?)?.toInt() ?? defaults.sizeDigits)
          .clamp(minSizeDigits, maxSizeDigits),
      modifiedDigits:
          ((json['modifiedDigits'] as num?)?.toInt() ??
                  defaults.modifiedDigits)
              .clamp(minModifiedDigits, maxModifiedDigits),
      density: PanelDensity.values.firstWhere(
        (d) => d.name == json['density'],
        orElse: () => defaults.density,
      ),
      // Read through the scale rather than trusted, for the same reason the
      // frame width is: a number off the scale would draw at a face nobody
      // chose, and a fraction would draw at whatever rounding decided.
      fileWeight: _weight(json['fileWeight'], defaults.fileWeight),
      directoryWeight: _weight(
        json['directoryWeight'],
        defaults.directoryWeight,
      ),
      strongWeight: _weight(json['strongWeight'], defaults.strongWeight),
      uiWeight: _weight(json['uiWeight'], defaults.uiWeight),
      weightOffset: _offset(json['weightOffset'], defaults.weightOffset),
      // Read through the list rather than trusted: a settings file that has
      // been edited by hand, or written by a build that offered a width this
      // one does not, must not be able to put a fraction back on the frame.
      panelBorderWidth: panelBorderWidths.contains(json['panelBorderWidth'])
          ? json['panelBorderWidth'] as int
          : defaults.panelBorderWidth,
      // `quickSearchStyle` is what 1.0.0.121 to .124 wrote, back when the two
      // were separate searches rather than two ways into one.
      quickSearchOpener: QuickSearchOpener.values.firstWhere(
        (o) => o.name == (json['quickSearchOpener'] ?? _legacyOpener(json)),
        orElse: () => defaults.quickSearchOpener,
      ),
      showAboutAtStart:
          json['showAboutAtStart'] as bool? ?? defaults.showAboutAtStart,
      showHidden: json['showHidden'] as bool? ?? defaults.showHidden,
      nativeIcons: json['nativeIcons'] as bool? ?? defaults.nativeIcons,
      monochromeIcons:
          json['monochromeIcons'] as bool? ?? defaults.monochromeIcons,
      showGridLines: json['showGridLines'] as bool? ?? defaults.showGridLines,
      alternateRowShading:
          json['alternateRowShading'] as bool? ?? defaults.alternateRowShading,
      alternateRowColor: color('alternateRowColor', defaults.alternateRowColor),
      darkChrome: json['darkChrome'] as bool? ?? defaults.darkChrome,
      backdrop: WindowBackdrop.values.firstWhere(
        (b) => b.name == json['backdrop'],
        orElse: () => defaults.backdrop,
      ),
      panelOpacity:
          (json['panelOpacity'] as num?)?.toDouble() ?? defaults.panelOpacity,
      menuBackground: menuFollows
          ? headerBackground
          : color('menuBackground', defaults.menuBackground),
      menuForeground: menuFollows
          ? headerForeground
          : color('menuForeground', defaults.menuForeground),
      menuBorderColor: color('menuBorderColor', defaults.menuBorderColor),
      menuMonolith: json['menuMonolith'] as bool? ?? defaults.menuMonolith,
      // One, two or three; anything else is a file edited by hand.
      menuBorderWidth: switch (json['menuBorderWidth']) {
        final int width when width >= 1 && width <= 3 => width,
        _ => defaults.menuBorderWidth,
      },
      menuOpacity:
          (json['menuOpacity'] as num?)?.toDouble() ?? defaults.menuOpacity,
      slidePanelOpacity: (json['slidePanelOpacity'] as num?)?.toDouble() ??
          defaults.slidePanelOpacity,
      menuBlur: (json['menuBlur'] as num?)?.toDouble() ?? defaults.menuBlur,
      invertCursorText:
          json['invertCursorText'] as bool? ?? defaults.invertCursorText,
      consoleBackground: consoleFollows
          ? panelBackground
          : color('consoleBackground', defaults.consoleBackground),
      // The tenth the ink was quietened by when it followed, kept: the lines
      // that do have a colour — the prompt, a failure, a remark — are the ones
      // meant to stand out.
      consoleForeground: consoleFollows
          ? panelForeground.withValues(alpha: 0.9)
          : color('consoleForeground', defaults.consoleForeground),
      windowBackground: windowFollows
          ? panelBackground
          : color('windowBackground', defaults.windowBackground),
      windowHeaderBackground: windowFollows
          ? cursorColor
          : color('windowHeaderBackground', defaults.windowHeaderBackground),
      windowHeaderForeground: windowFollows
          ? inkFor(cursorColor)
          : color('windowHeaderForeground', defaults.windowHeaderForeground),
      // Clamped rather than trusted. A hand-edited 3 would put every animation
      // in the application at three times the length nobody asked for, and a
      // negative one would reach `animated` as neither off nor a duration.
      //
      // Tested for rather than cast, too: a cast throws on the word someone
      // typed where a number goes, and that takes down the whole appearance —
      // every colour and every metric — over one line of a text file.
      animationScale: switch (json['animationScale']) {
        final num saved => saved.toDouble().clamp(0.0, 1.0),
        _ => defaults.animationScale,
      },
      animateLiveFileList:
          json['animateLiveFileList'] as bool? ?? defaults.animateLiveFileList,
      liveFileListMotion: LiveListMotion.values.firstWhere(
        (m) => m.name == json['liveFileListMotion'],
        orElse: () => defaults.liveFileListMotion,
      ),
      animateFileListCursor:
          json['animateFileListCursor'] as bool? ??
          defaults.animateFileListCursor,
      folderChangeMotion: FolderSwapMotion.values.firstWhere(
        (m) => m.name == json['folderChangeMotion'],
        // What 1.0.0.324 to .333 wrote, when the exchange had one shape and the
        // setting was only whether it ran. A file from then says depth or
        // nothing, which is exactly what it meant.
        orElse: () => switch (json['animateFolderChange']) {
          false => FolderSwapMotion.none,
          true => FolderSwapMotion.depth,
          _ => defaults.folderChangeMotion,
        },
      ),
      windowArriveMotion: WindowArriveMotion.values.firstWhere(
        (m) => m.name == json['windowArriveMotion'],
        // A file from 1.0.0.378, which had the one shape and no setting.
        orElse: () => defaults.windowArriveMotion,
      ),
    );
  }
}
