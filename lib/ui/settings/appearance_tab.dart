import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/i18n/i18n.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/colour_scheme.dart';
import '../../core/settings/palette_seeds.dart';
import '../../core/settings/settings_store.dart';
import '../../core/settings/font_catalogue.dart';
import '../../core/settings/window_service.dart';
import '../../core/vfs/native_icons.dart';
import '../../core/vfs/shell_open.dart';
import '../../state/window_stack.dart';
import '../dialogs/common_dialogs.dart';
import '../motion.dart';
import '../notice.dart';
import '../text_scale.dart';
import '../widgets/choice_button.dart';
import '../widgets/context_menu.dart';
import '../widgets/hint.dart';
import '../viewer/film_strip.dart';
import '../widgets/stepped_slider.dart';
import '../windows/window_dialogs.dart';
import 'appearance_preview.dart';
import 'settings_group.dart';

/// Everything that controls how the panels look.
class AppearanceTab extends StatefulWidget {
  const AppearanceTab({super.key});

  @override
  State<AppearanceTab> createState() => _AppearanceTabState();
}

class _AppearanceTabState extends State<AppearanceTab> {
  /// Schemes found in the user's folder. Read once when the tab opens and
  /// again after one is saved, since the folder is only changed from here or
  /// from outside the app entirely.
  List<ColourScheme> _mine = const [];

  /// Which group is open, by title. **One at a time and none to begin with.**
  /// Null is the state the page opens in, and it
  /// is the state that makes the preview beside it the first thing read —
  /// which is what the preview was built to be.
  String? _open;

  /// What is being looked for. Empty means the groups are showing; anything
  /// else replaces them with the rows that answer, wherever they live.
  final TextEditingController _query = TextEditingController();

  /// The row the preview last sent us to, lit until it fades.
  PreviewTarget? _lit;

  /// One key per target, kept rather than made fresh: a `GlobalKey` built
  /// during build is a different key every frame, and `ensureVisible` needs the
  /// element that is already on screen.
  final Map<PreviewTarget, GlobalKey> _keys = {};

  GlobalKey _keyFor(PreviewTarget target) =>
      _keys.putIfAbsent(target, GlobalKey.new);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Opens the group [target] lives in, scrolls to its row and lights it.
  ///
  /// **This is what makes the preview the way in rather than a picture beside
  /// the list.** With everything folded shut the list says nothing until it is
  /// asked, and the thing that asks is the press on the very colour being
  /// changed — so the two halves of the page stop competing: the preview is
  /// where you point, the list is where you land.
  void _revealInList(PreviewTarget target) {
    final groups = _groups(context, context.read<SettingsStore>(),
        context.read<SettingsStore>().appearance);
    for (final group in groups) {
      final holds = group.rows.any(
        (row) => row is SettingsRow && row.target == target,
      );
      if (!holds) continue;
      setState(() {
        _open = group.title;
        _lit = target;
      });
      // After the group has opened, or there is nothing on screen to scroll to.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final key = _keys[target];
        final box = key?.currentContext;
        if (box != null) {
          unawaited(
            Scrollable.ensureVisible(
              box,
              alignment: 0.4,
              duration: motionOf(context, kSettingsFoldDuration),
              curve: kArrivingCurve,
            ),
          );
        }
      });
      return;
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_reloadSchemes());
  }

  Future<void> _reloadSchemes() async {
    final schemes = await ColourSchemeLibrary.user();
    if (mounted) setState(() => _mine = schemes);
  }


  /// Writes what is on screen into a file of its own.
  ///
  /// **Two commands, because they are two different things.**
  ///
  /// - A **palette** is three seeds and the colours that were pressed. It is
  ///   the thing worth passing around, it applies over whatever settings the
  ///   person opening it already has, and — because it is a recipe rather than
  ///   a list of colours — it grows a colour for the surface added next year.
  /// - **All settings** is the whole appearance: the font, the density, the
  ///   opacity, the motion. It is a backup and a move-to-the-other-machine,
  ///   not something to hand to somebody with their own font size.
  ///
  /// The difference used to be implicit — how many keys were in the file — and
  /// a reader had to guess. Both write a `kind` now, and both are read back by
  /// what they hold rather than by counting.
  Future<void> _save(SettingsStore settings, {required bool whole}) async {
    final name = await promptForText(
      context,
      title: whole ? tr('Save all settings') : tr('Save the palette'),
      hint: tr('What to call it'),
      confirmLabel: tr('Save'),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;

    final appearance = settings.appearance;
    final file = await ColourSchemeLibrary.save(
      whole
          ? ColourScheme.of(appearance, name: name.trim())
          : ColourScheme.palette(
              name: name.trim(),
              seeds: appearance.recipe.seeds,
              overrides: appearance.recipe.overrides,
            ),
    );
    await _reloadSchemes();
    if (mounted) {
      showNotice(
          context, tr('Saved to {file}', {'file': p.basename(file.path)}));
    }
  }

  /// Opens the folder the palettes live in, the machine's own way.
  ///
  /// **It used to open a window that told you where the folder was**, which is
  /// an answer to "where" when the question was "take me there". The
  /// plugins tab already had the right shape for this and this is now the same
  /// call. What that window also said — that a scheme is a plain JSON file you
  /// can drop in or copy out — moved onto the button, where it is read before
  /// pressing rather than after.
  Future<void> _showFolder() async {
    final directory = await ColourSchemeLibrary.folder();
    final failure = await ShellOpen.open(directory.path);
    if (failure != null && mounted) showNotice(context, failure, long: true);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final theme = settings.appearance;

    final advanced = settings.advancedAppearance;

    return Column(
      children: [
        // Two settings pages in one, and which one you get is remembered.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, label: Text(tr('Simple'))),
                  ButtonSegment(value: true, label: Text(tr('Advanced'))),
                ],
                selected: {advanced},
                onSelectionChanged: (selection) =>
                    settings.advancedAppearance = selection.first,
              ),
            ],
          ),
        ),
        Expanded(
          child: advanced
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    final preview = AppearancePreview(
                      theme: theme,
                      onPick: (target) =>
                          unawaited(_pickFromPreview(target, settings)),
                    );

                    // A phone has no room beside anything. The preview goes
                    // to the top of the list instead of alongside it, where
                    // it is the first thing seen and then scrolls away —
                    // rather than taking half of a narrow window for good.
                    //
                    // It is also the layout that says a finger is doing the
                    // pointing, which is the one thing the row height needs to
                    // know — see [SettingsRowMetrics].
                    if (constraints.maxWidth < _sideBySideFrom) {
                      return SettingsRowMetrics(
                        dense: false,
                        child: ListView(
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                              child: preview,
                            ),
                            ..._advanced(context, settings, theme),
                          ],
                        ),
                      );
                    }

                    // Controls down the left, the preview pinned down the
                    // right.
                    //
                    // Above the list it was in the way of the thing it
                    // describes: every colour row sat lower for it, and on a
                    // short window it took most of what was left. Beside the
                    // list it is always in view without costing the controls
                    // any height, and the eye is already going left to right
                    // from the row being changed to the panel it changes.
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: SettingsRowMetrics(
                            dense: true,
                            child: ListView(
                              padding: const EdgeInsets.only(bottom: 24),
                              children: _advanced(context, settings, theme),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: _previewWidth,
                          // Scrolls when the window is too short for it. The
                          // preview grew a page of reading on 2026-08-18 and
                          // is now taller than a small window, and a pinned
                          // column that cannot scroll answers that with an
                          // overflow stripe — which is the one thing a preview
                          // must never show.
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(8, 8, 16, 16),
                            child: preview,
                          ),
                        ),
                      ],
                    );
                  },
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: _simple(context, settings, theme),
                ),
        ),
      ],
    );
  }

  /// Wide enough for the preview's own columns without crowding the controls.
  static const double _previewWidth = 440;

  /// Narrower than this and the preview cannot sit beside the controls: what
  /// is left for them is a column of squeezed rows, which is worse than
  /// scrolling.
  static const double _sideBySideFrom = 820;

  /// Opens the picker for whatever was pressed in the preview.
  ///
  /// The preview is the map: a colour is easier to find by pointing at the
  /// thing it paints than by matching a name in a list of twelve.
  Future<void> _pickFromPreview(
    PreviewTarget target,
    SettingsStore settings,
  ) async {
    // The colour the picker opens on is read out of the settings by the same
    // key the press writes back to, so the two cannot come apart.
    final current = Color(
      settings.appearance.toJson()[_settingKeyFor(target)] as int,
    );

    // The list follows the press before the picker opens, so that closing the
    // picker leaves the page open at the row just changed — an answer to "and
    // where does this one live" that costs nothing to give.
    _revealInList(target);

    final picked = await _pickColor(context, current);
    if (picked == null) return;

    // **Every colour goes in the same way now: it is pressed.**
    //
    // This used to be twenty branches, six of which also had to turn off a
    // `*FollowsPalette` flag — because accepting a colour and then ignoring it
    // because a switch was still on is the failure that arrangement invited.
    // The flags are gone: a key is either derived from the palette's three
    // seeds or it is one somebody chose, and `pressing` is the choosing.
    // Pressing the panel, the header or the accent moves a *seed*, and
    // everything worked out from it moves too — which is what makes three
    // colours a palette rather than three more rows.
    settings.updateAppearance(
      (a) => a.pressing(_settingKeyFor(target), picked),
    );
  }

  /// Which appearance key a pickable in the preview stands for.
  ///
  /// One list rather than two: the colour a press reads out of the settings and
  /// the colour it writes back have to be the same one, and a `switch` on each
  /// side is two lists that drift.
  static String _settingKeyFor(PreviewTarget target) => switch (target) {
    PreviewTarget.panel => 'panelBackground',
    PreviewTarget.header => 'headerBackground',
    PreviewTarget.headerText => 'headerForeground',
    PreviewTarget.fileText => 'panelForeground',
    PreviewTarget.directoryText => 'directoryColor',
    PreviewTarget.marked => 'markedColor',
    PreviewTarget.cursor => 'cursorColor',
    PreviewTarget.accent => 'accentColor',
    PreviewTarget.window => 'windowBackground',
    PreviewTarget.windowHeader => 'windowHeaderBackground',
    PreviewTarget.windowHeaderText => 'windowHeaderForeground',
    PreviewTarget.console => 'consoleBackground',
    PreviewTarget.consoleText => 'consoleForeground',
    PreviewTarget.menu => 'menuBackground',
    PreviewTarget.menuText => 'menuForeground',
    PreviewTarget.reading => 'readingBackground',
    PreviewTarget.readingText => 'readingForeground',
    PreviewTarget.hint => 'hintBackground',
    PreviewTarget.hintText => 'hintForeground',
  };

  /// Three things: what colour it is, what the window is made of, what the
  /// text is set in. Everything else is a preference, and preferences live
  /// under Advanced.
  ///
  /// Kept short on words as well as on controls — a line of explanation under
  /// every row is what made the old page feel like a form to fill in.
  List<Widget> _simple(
    BuildContext context,
    SettingsStore settings,
    AppearanceSettings theme,
  ) {
    return [
      _SectionTitle(tr('Language')),
      _LanguageRow(settings: settings),
      _SectionTitle(tr('Colour')),
      // **One row, not a wall of chips.** There were four palettes and now
      // there are fourteen, and fourteen chips is a paragraph of names to read
      // before anything can be chosen. The list shows each one as its three
      // colours instead, applies as it is walked and puts back what was there
      // if it is left — so choosing a palette is looking at palettes.
      ListTile(
        title: Text(tr('Palette')),
        trailing: SizedBox(
          width: 200,
          child: _PaletteButton(settings: settings, mine: _mine),
        ),
      ),
      _SectionTitle(tr('Window')),
      ListTile(
        title: Text(tr('Backdrop')),
        trailing: ChoiceButton<WindowBackdrop>(
          value: theme.backdrop,
          width: 150,
          searchHint: tr('Search backdrops'),
          options: [
            for (final backdrop in WindowBackdrop.values)
              ChoiceOption(backdrop, tr(backdrop.label)),
          ],
          onChanged: (value) =>
              settings.updateAppearance((a) => a.copyWith(backdrop: value)),
        ),
      ),
      _SectionTitle(tr('Text')),
      ListTile(
        title: Text(tr('Interface font')),
        trailing: _FontFamilyPicker(
          current: theme.fontFamily,
          onChanged: (value) =>
              settings.updateAppearance((a) => a.copyWith(fontFamily: value)),
        ),
      ),
      ListTile(
        title: Text(tr('File font')),
        trailing: _FontFamilyPicker(
          current: theme.fileFontFamily,
          unsetLabel: tr('Same as the interface'),
          onChanged: (value) => settings.updateAppearance(
            (a) => a.copyWith(fileFontFamily: value),
          ),
        ),
      ),
      ListTile(
        title: Text(tr('Size')),
        subtitle: Slider(
          value: theme.fontSize,
          min: 9,
          max: 22,
          divisions: 13,
          label: theme.fontSize.toStringAsFixed(0),
          onChanged: (value) =>
              settings.updateAppearance((a) => a.copyWith(fontSize: value)),
        ),
        trailing: Text(theme.fontSize.toStringAsFixed(0)),
      ),
    ];
  }

  /// The advanced page: a box to search with, the language, the groups, and a
  /// way back to the defaults.
  ///
  /// **Everything shut, and one open at a time.** The rule is
  /// worth saying out loud because it decides the rest: a page that opens with
  /// nothing showing is a page whose first move is either to press a group or
  /// to type — so the two things that have to work are the *names* of the
  /// groups and the search, and both got the attention that would otherwise
  /// have gone into arranging thirty-seven rows nobody can see at once.
  List<Widget> _advanced(
    BuildContext context,
    SettingsStore settings,
    AppearanceSettings theme,
  ) {
    final groups = _groups(context, settings, theme);
    final query = _query.text.trim();

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: SettingsSearchBox(
          controller: _query,
          onChanged: (_) => setState(() {}),
        ),
      ),
      // Above the groups rather than inside one: it is a single row and it is
      // the first question, and a group that holds one row is a lid on nothing.
      if (query.isEmpty) _LanguageRow(settings: settings),
      if (query.isNotEmpty)
        ..._found(context, groups, query)
      else
        for (final group in groups)
          SettingsGroupTile(
            group: group,
            open: _open == group.title,
            // Opening one closes whatever was open, which is the whole of
            // "only one at a time" — and pressing the open one shuts it, so
            // the state with nothing showing is always one press away.
            onPressed: () => setState(
              () => _open = _open == group.title ? null : group.title,
            ),
          ),
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: OutlinedButton.icon(
          onPressed: settings.resetAppearance,
          icon: const Icon(Icons.restore),
          label: Text(tr('Reset to defaults')),
        ),
      ),
    ];
  }

  /// What answers [query], flattened out of the groups and labelled with the
  /// group each row came from.
  ///
  /// **Flat, not "the groups with the misses hidden".** A search that leaves the
  /// folding in place makes the reader open things to see what was found, which
  /// is the work the search was meant to save. The group's name travels with the
  /// row instead, so the answer also says where the row lives — and the next
  /// time it can be gone to directly.
  List<Widget> _found(
    BuildContext context,
    List<SettingsGroup> groups,
    String query,
  ) {
    final found = <Widget>[];
    for (final group in groups) {
      // A group whose *name* matches offers everything in it: somebody typing
      // "menu" means the menu, not the four rows with the word in them.
      final whole = group.matches(query);
      final rows = [
        for (final row in group.rows)
          if (whole || (row is SettingsRow && row.matches(query))) row,
      ];
      if (rows.isEmpty) continue;
      found
        ..add(FoundIn(group: group, query: query))
        // Each row is handed the query so it can pick out the run that made it
        // an answer — see [SettingsSearch] and [marked].
        ..addAll([
          for (final row in rows) SettingsSearch(query: query, child: row),
        ]);
    }

    if (found.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Text(
            tr('Nothing here answers to that'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ];
    }
    return found;
  }

  /// The nine groups, in the order they are offered.
  ///
  /// **Grouped by the *thing*, not by the property.** The list before this was
  /// one long and unreadable one, named on two axes at once: five
  /// headings after a surface (Reading, Hint, Menu, Slide panel, Window) and
  /// four after a property (Colours, Typography, Motion, Behaviour). So
  /// "Colours" silently meant *the panels' colours*, and the only way to learn
  /// that was to look for the menu's there and fail. Folding a list that lies
  /// about itself only hides the lie.
  ///
  /// One axis now: every surface owns its own colours **and** its own numbers —
  /// the menu's opacity and blur sit with the menu's pair, the slide panel is a
  /// window rather than a heading with one slider under it — and what genuinely
  /// crosses all of them (fonts, motion, behaviour) comes last.
  ///
  /// Language is not in here: it is one row and it is the first question, so it
  /// stands above the groups where it can be answered without opening anything.
  List<SettingsGroup> _groups(
    BuildContext context,
    SettingsStore settings,
    AppearanceSettings theme,
  ) {
    void set(AppearanceSettings Function(AppearanceSettings) change) =>
        settings.updateAppearance(change);

    return [
      SettingsGroup(
        title: 'Palettes',
        icon: Icons.palette_outlined,
        rows: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                Expanded(child: Text(tr('Palette'))),
                SizedBox(
                  width: 220,
                  child: _PaletteButton(settings: settings, mine: _mine),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Wrap(
              spacing: 8,
              children: [
                Hint(
                  message: tr(
                    'Three colours and whatever you have pressed. It applies over anything, and leaves the font, the density and the motion alone.',
                  ),
                  child: TextButton.icon(
                    onPressed: () => unawaited(_save(settings, whole: false)),
                    icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                    label: Text(tr('Save the palette')),
                  ),
                ),
                Hint(
                  message: tr(
                    'The whole appearance, including the font, the density, the opacity and the motion. A backup, or a way to carry this look to another machine.',
                  ),
                  child: TextButton.icon(
                    onPressed: () => unawaited(_save(settings, whole: true)),
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: Text(tr('Save all settings')),
                  ),
                ),
                Hint(
                  message: tr(
                    'Schemes are plain JSON files. Drop one in this folder and it appears in the list; copy one out to pass it on.',
                  ),
                  child: TextButton.icon(
                    onPressed: () => unawaited(_showFolder()),
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: Text(tr('Where they live')),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      SettingsGroup(
        title: 'Panels',
        icon: Icons.view_column_outlined,
        rows: [
          _colour(settings, 'Panel background', theme.panelBackground,
              (a, c) => a.copyWith(panelBackground: c),
              target: PreviewTarget.panel),
          _colour(settings, 'Header background', theme.headerBackground,
              (a, c) => a.copyWith(headerBackground: c),
              target: PreviewTarget.header),
          _colour(settings, 'Header text', theme.headerForeground,
              (a, c) => a.copyWith(headerForeground: c),
              target: PreviewTarget.headerText),
          _colour(settings, 'File text', theme.panelForeground,
              (a, c) => a.copyWith(panelForeground: c),
              target: PreviewTarget.fileText),
          _colour(settings, 'Directory text', theme.directoryColor,
              (a, c) => a.copyWith(directoryColor: c),
              target: PreviewTarget.directoryText),
          _colour(settings, 'Marked entries', theme.markedColor,
              (a, c) => a.copyWith(markedColor: c),
              target: PreviewTarget.marked),
          _colour(settings, 'Cursor row', theme.cursorColor,
              (a, c) => a.copyWith(cursorColor: c),
              target: PreviewTarget.cursor),
          _switch(
            'Invert the text under the cursor',
            note: 'Black on a light cursor, white on a dark one, whatever the row would otherwise be written in',
            value: theme.invertCursorText,
            onChanged: (v) => set((a) => a.copyWith(invertCursorText: v)),
          ),
          _colour(settings, 'Accent', theme.accentColor,
              (a, c) => a.copyWith(accentColor: c),
              target: PreviewTarget.accent),
          _switch(
            'Alternating row shading',
            value: theme.alternateRowShading,
            onChanged: (v) => set((a) => a.copyWith(alternateRowShading: v)),
          ),
          if (theme.alternateRowShading)
            _colour(settings, 'Alternating row', theme.alternateRowColor,
                (a, c) => a.copyWith(alternateRowColor: c),
                allowAlpha: true),
          // In letters, because that is the unit the column is set in and the
          // one that survives a change of font — see
          // [AppearanceSettings.extensionLetters]. The same setting is on the
          // edge of the column itself, where a hand reaches for it; this is
          // where the keyboard reaches it.
          _slider(
            'Extension column',
            value: theme.extensionLetters.toDouble(),
            min: AppearanceSettings.minExtensionLetters.toDouble(),
            max: AppearanceSettings.maxExtensionLetters.toDouble(),
            divisions: AppearanceSettings.maxExtensionLetters -
                AppearanceSettings.minExtensionLetters,
            said: tr('{count} letters', {'count': '${theme.extensionLetters}'}),
            onChanged: (v) => set((a) => a.copyWith(extensionLetters: v.round())),
          ),
          // Figures rather than letters for these two, because that is what
          // they hold — see [AppearanceSettings.sizeDigits].
          _slider(
            'Size column',
            value: theme.sizeDigits.toDouble(),
            min: AppearanceSettings.minSizeDigits.toDouble(),
            max: AppearanceSettings.maxSizeDigits.toDouble(),
            divisions:
                AppearanceSettings.maxSizeDigits -
                AppearanceSettings.minSizeDigits,
            said: tr('{count} digits', {'count': '${theme.sizeDigits}'}),
            onChanged: (v) => set((a) => a.copyWith(sizeDigits: v.round())),
          ),
          _slider(
            'Modified column',
            value: theme.modifiedDigits.toDouble(),
            min: AppearanceSettings.minModifiedDigits.toDouble(),
            max: AppearanceSettings.maxModifiedDigits.toDouble(),
            divisions:
                AppearanceSettings.maxModifiedDigits -
                AppearanceSettings.minModifiedDigits,
            said: tr('{count} digits', {'count': '${theme.modifiedDigits}'}),
            onChanged: (v) => set((a) => a.copyWith(modifiedDigits: v.round())),
          ),
          SettingsRow(
            label: 'Row density',
            trailing: SegmentedButton<PanelDensity>(
              segments: [
                for (final density in PanelDensity.values)
                  ButtonSegment(value: density, label: Text(tr(density.label))),
              ],
              selected: {theme.density},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  set((a) => a.copyWith(density: selection.first)),
            ),
          ),
          SettingsRow(
            label: 'Panel frame',
            note: 'One logical pixel is one device pixel at 100% and two on a Retina screen, so the same frame reads differently per machine',
            trailing: SegmentedButton<int>(
              segments: [
                for (final width in AppearanceSettings.panelBorderWidths)
                  ButtonSegment(value: width, label: Text('$width px')),
              ],
              selected: {theme.panelBorderWidth},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  set((a) => a.copyWith(panelBorderWidth: selection.first)),
            ),
          ),
        ],
      ),
      // Two rows and no third: everything else on a page — the plaque behind a
      // block of code, the rule under a heading, the wash inside a pill — is
      // worked out from these two, and the syntax colours go on coming from the
      // panels' own.
      SettingsGroup(
        title: 'Reading',
        icon: Icons.article_outlined,
        rows: [
          _colour(settings, 'Reading background', theme.readingBackground,
              (a, c) => a.copyWith(readingBackground: c),
              target: PreviewTarget.reading),
          _colour(settings, 'Reading text', theme.readingForeground,
              (a, c) => a.copyWith(readingForeground: c),
              target: PreviewTarget.readingText),
        ],
      ),
      // A note pinned to the window rather than a shade of the palette, which
      // is why it is its own pair and why the default is yellow.
      SettingsGroup(
        title: 'Hint',
        icon: Icons.sticky_note_2_outlined,
        rows: [
          _colour(settings, 'Hint background', theme.hintBackground,
              (a, c) => a.copyWith(hintBackground: c),
              target: PreviewTarget.hint),
          _colour(settings, 'Hint text', theme.hintForeground,
              (a, c) => a.copyWith(hintForeground: c),
              target: PreviewTarget.hintText),
        ],
      ),
      SettingsGroup(
        title: 'Menu',
        icon: Icons.menu_open_outlined,
        note: 'A menu can only blur what the app itself draws. Over a translucent window there is nothing behind it to blur, so the effect is strongest with an opaque backdrop.',
        rows: [
          // **No follow-the-palette switch, and no rows hidden behind one.**
          // A menu takes the chrome seed until somebody presses it, and then it
          // is a colour that was chosen — which is what these rows now show and
          // set. A switch here was a second way of saying the same thing, in a
          // place you had to go and find.
          ...[
            _colour(settings, 'Menu background', theme.menuBackground,
                (a, c) => a.copyWith(menuBackground: c),
                target: PreviewTarget.menu),
            _colour(settings, 'Menu text', theme.menuForeground,
                (a, c) => a.copyWith(menuForeground: c),
                target: PreviewTarget.menuText),
          ],
          _switch(
            'The menu and its title are one element',
            note: 'Off: a menu is a panel of its own, and the title stays lit',
            value: theme.menuMonolith,
            onChanged: (v) => set((a) => a.copyWith(menuMonolith: v)),
          ),
          // Neither of the outline's two questions is pressable in the preview:
          // a line one to three pixels wide is not something to aim at.
          _colour(settings, 'Menu outline', theme.menuBorderColor,
              (a, c) => a.copyWith(menuBorderColor: c)),
          SettingsRow(
            label: 'Menu outline width',
            trailing: ChoiceButton<int>(
              value: theme.menuBorderWidth,
              width: 110,
              searchHint: tr('Search widths'),
              options: const [
                ChoiceOption(1, '1 px'),
                ChoiceOption(2, '2 px'),
                ChoiceOption(3, '3 px'),
              ],
              onChanged: (value) =>
                  set((a) => a.copyWith(menuBorderWidth: value)),
            ),
          ),
          // Worth spelling out: this is what decides whether the blur is
          // visible at all, and a solid menu was read as a broken blur.
          _slider(
            'Menu opacity',
            value: theme.menuOpacity,
            min: 0.2,
            max: 1,
            divisions: 16,
            said: '${(theme.menuOpacity * 100).round()}%',
            onChanged: (v) => set((a) => a.copyWith(menuOpacity: v)),
          ),
          _slider(
            'Menu blur',
            value: theme.menuBlur,
            max: 60,
            divisions: 12,
            said: theme.menuBlur.toStringAsFixed(0),
            onChanged: (v) => set((a) => a.copyWith(menuBlur: v)),
          ),
        ],
      ),
      // The console had a pair and no rows: it could only be reached by pressing
      // the strip in the preview. That was survivable while the list was flat
      // and is not now the preview *opens* the row it points at — a target with
      // nowhere to go is the one case that arrangement cannot answer.
      SettingsGroup(
        title: 'Console',
        icon: Icons.terminal_outlined,
        rows: [
          ...[
            _colour(settings, 'Console background', theme.consoleBackground,
                (a, c) => a.copyWith(consoleBackground: c),
                target: PreviewTarget.console),
            _colour(settings, 'Console text', theme.consoleForeground,
                (a, c) => a.copyWith(consoleForeground: c),
                target: PreviewTarget.consoleText),
          ],
        ],
      ),
      SettingsGroup(
        title: 'Windows and dialogs',
        icon: Icons.web_asset_outlined,
        note: 'The slide panel is the one that comes over a reading — a node\'s properties, and the document structure. It takes the menu\'s blur.',
        rows: [
          SettingsRow(
            label: 'Backdrop',
            note: 'Acrylic and Mica need a translucent window; desktop only',
            trailing: ChoiceButton<WindowBackdrop>(
              value: theme.backdrop,
              width: 150,
              searchHint: tr('Search backdrops'),
              options: [
                for (final backdrop in WindowBackdrop.values)
                  ChoiceOption(backdrop, tr(backdrop.label)),
              ],
              onChanged: (value) => set((a) => a.copyWith(backdrop: value)),
            ),
          ),
          if (theme.backdrop != WindowBackdrop.opaque) ...[
            SettingsRow(
              label: 'Re-apply the backdrop',
              note: 'Windows sometimes drops the effect after the display or theme changes.',
              trailing: const Icon(Icons.refresh, size: 18),
              onTap: (_) => WindowService.reapplyBackdrop(theme),
            ),
            SettingsRow(
              label: 'If a backdrop shows no blur, try Mica',
              note: 'Acrylic and Mica are drawn by the system, not by the app, and which of them works depends on the Windows build and on transparency being enabled in Windows personalisation settings.',
              trailing: const Icon(Icons.info_outline, size: 18),
            ),
            _slider(
              'Panel opacity',
              value: theme.panelOpacity,
              min: 0.2,
              max: 1,
              divisions: 16,
              said: '${(theme.panelOpacity * 100).round()}%',
              onChanged: (v) => set((a) => a.copyWith(panelOpacity: v)),
            ),
          ],
          ...[
            _colour(settings, 'Dialog background', theme.windowBackground,
                (a, c) => a.copyWith(windowBackground: c),
                target: PreviewTarget.window),
            _colour(settings, 'Dialog title bar', theme.windowHeaderBackground,
                (a, c) => a.copyWith(windowHeaderBackground: c),
                target: PreviewTarget.windowHeader),
            // A form given a colour of its own had nothing to write its title
            // in but the file-row colour, which is the same gap the
            // application's own title bar had.
            _colour(settings, 'Dialog title text', theme.windowHeaderForeground,
                (a, c) => a.copyWith(windowHeaderForeground: c),
                target: PreviewTarget.windowHeaderText),
          ],
          // Its own number: a menu is glanced at, a panel is read from while
          // what is under it stays visible, and the two want different amounts
          // of the window showing through.
          _slider(
            'Slide panel opacity',
            value: theme.slidePanelOpacity,
            min: 0.2,
            max: 1,
            divisions: 16,
            said: '${(theme.slidePanelOpacity * 100).round()}%',
            onChanged: (v) => set((a) => a.copyWith(slidePanelOpacity: v)),
          ),
          _switch(
            'Dark window chrome',
            note: 'A colour scheme sets this to match itself',
            value: theme.darkChrome,
            onChanged: (v) => set((a) => a.copyWith(darkChrome: v)),
          ),
        ],
      ),
      SettingsGroup(
        title: 'Fonts',
        icon: Icons.text_fields_outlined,
        note: 'Interface weight is everything outside the panels — menus, dialogs and this page. It moves the whole interface together, so text Material draws a step heavier stays a step heavier. The directory slider starts where the file slider is, so a folder cannot be set lighter than the files it sits among. Emphasis is free. The offset moves all four at once. A family that ships only Regular and Bold draws the nearest face it has, so several steps can look identical — the preview beside this is drawn at the weights set here, and this page is drawn at the interface one, which is where to see whether this font answers to them.',
        rows: [
          _slider(
            'Font size',
            value: theme.fontSize,
            min: 9,
            max: 22,
            divisions: 13,
            said: theme.fontSize.toStringAsFixed(0),
            onChanged: (v) => set((a) => a.copyWith(fontSize: v)),
          ),
          // Two families, item 43: the interface has a voice of its own and a
          // listing has a job to do. A file font left unset is the interface's,
          // which is how the application drew when there was only one.
          SettingsRow(
            label: 'Interface font family',
            note: 'Menus, dialogs and the title bar',
            trailing: _FontFamilyPicker(
              current: theme.fontFamily,
              onChanged: (value) => set((a) => a.copyWith(fontFamily: value)),
            ),
          ),
          SettingsRow(
            label: 'File font family',
            note: 'The panels, the path bars and the console. Unset, the panels follow the interface and the console stays fixed pitch.',
            trailing: _FontFamilyPicker(
              current: theme.fileFontFamily,
              unsetLabel: tr('Same as the interface'),
              onChanged: (value) =>
                  set((a) => a.copyWith(fileFontFamily: value)),
            ),
          ),
          // The interface first, because it is the one weight here that is not
          // about the panels — menus, dialogs and this form itself. It answers
          // to no floor for the same reason emphasis does not: nothing sits
          // beside it to be told apart from.
          _WeightSlider(
            label: tr('Interface weight'),
            value: theme.uiWeight,
            resolved: theme.uiFontWeight,
            onChanged: (value) => set((a) => a.copyWith(uiWeight: value)),
          ),
          _WeightSlider(
            label: tr('File weight'),
            value: theme.fileWeight,
            resolved: theme.fileFontWeight,
            onChanged: (value) => set((a) => a.copyWith(fileWeight: value)),
          ),
          // Plain weights, each starting where the one below it is. With files
          // at 200 the directory slider runs 200 to 900, so a folder lighter
          // than the files around it is not somewhere the slider goes.
          _WeightSlider(
            label: tr('Directory weight'),
            value: theme.resolvedDirectoryWeight,
            resolved: theme.directoryFontWeight,
            floor: theme.fileWeight,
            onChanged: (value) =>
                set((a) => a.copyWith(directoryWeight: value)),
          ),
          _WeightSlider(
            label: tr('Emphasis weight'),
            // Free: emphasis is not in the listing and has nothing to be
            // compared with, so it answers to no floor.
            value: theme.strongWeight,
            resolved: theme.strongFontWeight,
            onChanged: (value) => set((a) => a.copyWith(strongWeight: value)),
          ),
          _WeightSlider(
            label: tr('Weight offset'),
            value: theme.weightOffset,
            resolved: null,
            minimum: -AppearanceSettings.weightOffsetLimit,
            maximum: AppearanceSettings.weightOffsetLimit,
            signed: true,
            onChanged: (value) => set((a) => a.copyWith(weightOffset: value)),
          ),
        ],
      ),
      SettingsGroup(
        title: 'Motion',
        icon: Icons.animation_outlined,
        rows: [
          SettingsRow(
            label: 'Animation speed',
            note: theme.animates
                // The abstract number said in something anyone can check
                // against the screen: this is the one everybody sees, all day.
                ? tr('The panel frame changes side in %s ms').replaceFirst(
                    '%s',
                    '${theme.animated(kPanelAnimationDuration).inMilliseconds}',
                  )
                : 'Nothing animates: every change is a cut',
            trailing: SegmentedButton<AnimationSpeed>(
              segments: [
                for (final speed in AnimationSpeed.values)
                  ButtonSegment(value: speed, label: Text(tr(speed.label))),
              ],
              // A settings file may hold any number between 0 and 1, and it is
              // honoured. When it is not one of these four, no button is
              // pressed — which is true, and truer than rounding it.
              selected: {?AnimationSpeed.matching(theme.animationScale)},
              emptySelectionAllowed: true,
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  set((a) => a.copyWith(animationScale: selection.first.scale)),
            ),
          ),
          // Rule number two, on the one change the whole panel makes: a folder
          // opened in a single frame is a listing that suddenly holds different
          // files, and that reads as a fault. Animated by default, and one fade
          // however many rows are in the panel — which is what separates it
          // from the two exceptions below. The three answers differ only in
          // what says which way you went: nothing, size, or distance.
          SettingsRow(
            label: 'How a folder opens',
            note: switch (theme.folderChangeMotion) {
              FolderSwapMotion.none =>
                'The folder you moved to is simply there, in one frame',
              FolderSwapMotion.depth =>
                'The listing fades out and the folder you moved to comes forward',
              FolderSwapMotion.slide =>
                'The listing travels in towards the middle of the window, and back out to its own edge',
              FolderSwapMotion.both => 'It comes forward and travels at once',
            },
            enabled: theme.animates,
            trailing: SegmentedButton<FolderSwapMotion>(
              segments: [
                for (final motion in FolderSwapMotion.values)
                  ButtonSegment(value: motion, label: Text(tr(motion.label))),
              ],
              selected: {theme.folderChangeMotion},
              showSelectedIcon: false,
              onSelectionChanged: theme.animates
                  ? (selection) => set(
                      (a) => a.copyWith(folderChangeMotion: selection.first),
                    )
                  : null,
            ),
          ),
          // A window is one thing arriving, so there is no "none" here: Off on
          // the speed above already means no animation, and a second way of
          // saying it would be a second place to look. The two answers say the
          // same true thing — this row opened into this window — and differ
          // only in what says it.
          SettingsRow(
            label: 'How a window opens',
            note: switch (theme.windowArriveMotion) {
              WindowArriveMotion.whole =>
                'The row the cursor is on becomes the whole window at once',
              WindowArriveMotion.unfold =>
                'The row becomes the title bar, and the form unfolds out from under it',
            },
            enabled: theme.animates,
            trailing: SegmentedButton<WindowArriveMotion>(
              segments: [
                for (final motion in WindowArriveMotion.values)
                  ButtonSegment(value: motion, label: Text(tr(motion.label))),
              ],
              selected: {theme.windowArriveMotion},
              showSelectedIcon: false,
              onSelectionChanged: theme.animates
                  ? (selection) => set(
                      (a) => a.copyWith(windowArriveMotion: selection.first),
                    )
                  : null,
            ),
          ),
          // The exception to "a listing does not animate", and offered as one.
          // Not rows arriving and not scrolling — neither of those is free on a
          // panel of thousands of rows. This is the listing answering the
          // pointer.
          _switch(
            'Live file list',
            note: 'A row leans aside under the mouse, and further under the cursor. Nothing about scrolling',
            value: theme.animateLiveFileList,
            onChanged: theme.animates
                ? (v) => set((a) => a.copyWith(animateLiveFileList: v))
                : null,
          ),
          // One question with two good answers, so it is asked rather than
          // decided. Dead unless the list is live: it says how a thing that is
          // not happening would happen.
          SettingsRow(
            label: 'How a row answers',
            note: theme.liveFileListMotion == LiveListMotion.slide
                ? 'The name and its icon step aside'
                : 'The name and its icon grow where they are',
            enabled: theme.animates && theme.animateLiveFileList,
            trailing: SegmentedButton<LiveListMotion>(
              segments: [
                for (final motion in LiveListMotion.values)
                  ButtonSegment(value: motion, label: Text(tr(motion.label))),
              ],
              selected: {theme.liveFileListMotion},
              showSelectedIcon: false,
              onSelectionChanged: theme.animates && theme.animateLiveFileList
                  ? (selection) =>
                      set((a) => a.copyWith(liveFileListMotion: selection.first))
                  : null,
            ),
          ),
          _switch(
            'Animate the list cursor',
            note: 'The mark that says which row the keyboard is on',
            value: theme.animateFileListCursor,
            onChanged: theme.animates
                ? (v) => set((a) => a.copyWith(animateFileListCursor: v))
                : null,
          ),
        ],
      ),
      SettingsGroup(
        title: 'Behaviour',
        icon: Icons.tune_outlined,
        rows: [
          // Blender has this switch for the same reason: the card is shown
          // every single time, and every single time is a lot.
          _switch(
            'Show the About card at start-up',
            note: 'The picture, the version, and the folders you were last in',
            value: theme.showAboutAtStart,
            onChanged: (v) => set((a) => a.copyWith(showAboutAtStart: v)),
          ),
          // One search, reached three ways. The same box appears whichever is
          // chosen; this only says what brings it up, and one of them is live
          // at a time — so that Ctrl+Alt keeps its other bindings when Alt+S is
          // chosen, and so that the command line keeps plain typing unless
          // Typing has been given to the search.
          SettingsRow(
            label: 'Quick search opens with',
            note: switch (theme.quickSearchOpener) {
              QuickSearchOpener.altS =>
                'The box comes up empty and the name is typed into it',
              QuickSearchOpener.ctrlAltLetter =>
                'The box comes up already holding the letter pressed',
              QuickSearchOpener.typing =>
                'A letter typed in a panel is the search; the command line is then reached with Ctrl+↓',
            },
            trailing: SegmentedButton<QuickSearchOpener>(
              segments: [
                for (final opener in QuickSearchOpener.values)
                  ButtonSegment(value: opener, label: Text(tr(opener.label))),
              ],
              selected: {theme.quickSearchOpener},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  set((a) => a.copyWith(quickSearchOpener: selection.first)),
            ),
          ),
          _switch(
            'Show hidden files',
            note: 'Ctrl+H toggles this from the panels',
            value: theme.showHidden,
            onChanged: (v) => set((a) => a.copyWith(showHidden: v)),
          ),
          // Off by default, and the built-in set stays: one shape per kind of
          // thing, the same on every machine. This is for whoever would rather
          // see what the rest of the desktop shows for a `.psd` or a `.blend`.
          _switch(
            'Native icons from the system',
            note: NativeIcons.isSupported
                ? 'The same icons the desktop shows for files and folders'
                : 'This desktop has no icons to offer',
            value: theme.nativeIcons && NativeIcons.isSupported,
            onChanged: NativeIcons.isSupported
                ? (v) => set((a) => a.copyWith(nativeIcons: v))
                : null,
          ),
          // Only once there are native icons to recolour. Shown greyed rather
          // than hidden, so it is discoverable before the switch above is
          // found.
          _switch(
            'Tint them to the palette',
            note: 'Shape from the desktop, colour from the panel: folders stay the folder colour',
            value: theme.monochromeIcons,
            onChanged: theme.nativeIcons && NativeIcons.isSupported
                ? (v) => set((a) => a.copyWith(monochromeIcons: v))
                : null,
          ),
          _switch(
            'Directories first',
            value: settings.directoriesFirst,
            onChanged: (v) => settings.directoriesFirst = v,
          ),
          // The strip along the bottom of a viewer folds into a grid while the
          // pointer is on it. This is how tall that grid may get — and it is a
          // number rather than a switch because the answer depends on the
          // window: three rows of a wide one is most of a hundred photographs
          // at once, and on a small screen the picture itself has gone.
          // The two ways the strip can lay a folder out once it is folded.
          // Neither is wrong: lines all reading the same way is what anybody
          // expects of a wall of pictures and costs a jump at the ends of
          // them; folded like a ribbon nothing ever jumps and every other line
          // runs back the way it came.
          SettingsRow(
            label: 'How the film strip folds',
            note: StripFold.named(settings.filmStripFold) == StripFold.ribbon
                ? 'The strip folded over on itself: it turns round at each'
                      ' fold, so nothing ever jumps across it'
                : 'Files stacked a few at a time, the ranks walked sideways',
            trailing: SegmentedButton<StripFold>(
              segments: [
                for (final fold in StripFold.values)
                  ButtonSegment(value: fold, label: Text(tr(fold.label))),
              ],
              selected: {StripFold.named(settings.filmStripFold)},
              showSelectedIcon: false,
              onSelectionChanged: (choice) =>
                  settings.setFilmStripFold(choice.first.name),
            ),
          ),
          // One row is how the folding is turned off: the strip stays the row
          // it is and the pointer leaves it alone.
          _slider(
            'Rows the film strip unfolds into',
            value: settings.filmStripRows.toDouble(),
            min: SettingsStore.fewestStripRows.toDouble(),
            max: SettingsStore.mostStripRows.toDouble(),
            divisions:
                SettingsStore.mostStripRows - SettingsStore.fewestStripRows,
            said: '${settings.filmStripRows}',
            onChanged: (v) => settings.setFilmStripRows(v.round()),
          ),
        ],
      ),
    ];
  }

  /// A colour, with the press in the preview that leads to it.
  /// A colour row in the list, for one of the pickables in the preview.
  ///
  /// **A row and a press are the same act**, so both go through
  /// [AppearanceSettings.pressing] wherever the row stands for a
  /// [PreviewTarget]. That matters for the three seed colours in particular:
  /// setting the panel with a plain `copyWith` would leave the ink where it
  /// was, and the palette would then record the old ink as a colour somebody
  /// chose — a paper moved and an ink frozen to it, from one row press.
  ///
  /// [change] is what the rows with no pickable still use — the alternating
  /// stripe and the menu's outline, which are not on the map.
  Widget _colour(
    SettingsStore settings,
    String label,
    Color colour,
    AppearanceSettings Function(AppearanceSettings, Color) change, {
    PreviewTarget? target,
    bool allowAlpha = false,
  }) => _colourRow(
    key: target == null ? null : _keyFor(target),
    label: label,
    color: colour,
    allowAlpha: allowAlpha,
    target: target,
    lit: target != null && target == _lit,
    onChanged: (c) => settings.updateAppearance(
      (a) => target == null ? change(a, c) : a.pressing(_settingKeyFor(target), c),
    ),
  );

  Widget _switch(
    String label, {
    String? note,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) => SettingsRow(
    label: label,
    note: note,
    enabled: onChanged != null,
    // Pressing anywhere on the row throws the switch, which is what a
    // `SwitchListTile` did and what a row of this height needs: the switch
    // itself is a small target beside a wide label.
    onTap: onChanged == null ? null : (_) => onChanged(!value),
    trailing: Switch(
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );

  /// A slider and the number it is at, on one line.
  ///
  /// It used to be a `ListTile` with the slider in the *subtitle* slot, which
  /// is what made these rows two lines tall for one control.
  Widget _slider(
    String label, {
    required double value,
    double min = 0,
    required double max,
    required int divisions,
    required String said,
    required ValueChanged<double> onChanged,
  }) => SettingsRow(
    label: label,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 180,
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: said,
            onChanged: onChanged,
          ),
        ),
        // **Wide enough for a translation, and never two lines.** 44 was
        // measured against the English label and nothing else, so a translated
        // one wrapped and lost its second line off the bottom of the row.
        // Fixed rather than shrink-wrapped, or the number moving from
        // 6 to 18 would shift the slider beside it while it is being dragged.
        SizedBox(
          width: 92,
          child: Text(
            said,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );
}

/// Picks the panel font from what the machine has, with each entry drawn in
/// its own face so the choice can be made by looking rather than by guessing.
///
/// A family the list does not know about — a font installed since, or one this
/// catalogue never heard of — can still be typed in through "Other…", and is
/// then shown as the current choice.
class _FontFamilyPicker extends StatelessWidget {
  const _FontFamilyPicker({
    required this.current,
    required this.onChanged,
    this.unsetLabel = 'System default',
  });

  /// Empty means [unsetLabel] — the system's own face for the interface, and
  /// "whatever the interface is" for the listing.
  final String current;

  /// What nothing-chosen is called here. The two families mean different
  /// things by it, and a row that called both "System default" would be
  /// telling one of them a lie.
  final String unsetLabel;

  final ValueChanged<String> onChanged;

  static const String _system = '';

  /// Not a family name, and cannot collide with one: the entry that asks for
  /// a name instead of being one.
  static const String _other = 'xverb:other';

  @override
  Widget build(BuildContext context) {
    final families = [
      ...FontCatalogue.available(),
      // Whatever is set now belongs in the list even if it is not a candidate,
      // otherwise the menu could not show its own value.
      if (current.isNotEmpty && !FontCatalogue.available().contains(current))
        current,
    ];

    return ChoiceButton<String>(
      value: current.isEmpty ? _system : current,
      width: 220,
      searchHint: tr('Search fonts'),
      options: [
        ChoiceOption(_system, tr(unsetLabel)),
        for (final family in families) ChoiceOption(family, family),
        ChoiceOption(_other, tr('Other…')),
      ],
      onChanged: (value) {
        if (value == _other) {
          unawaited(_askForFamily(context));
          return;
        }
        onChanged(value);
      },
    );
  }

  Future<void> _askForFamily(BuildContext context) async {
    final typed = await promptForText(
      context,
      title: tr('Font family'),
      initialValue: current,
      hint: tr('Exactly as the font is named on this machine'),
      confirmLabel: tr('Use it'),
    );
    final family = typed?.trim();
    if (family == null) return;
    onChanged(family);
  }
}

/// Picks the language the application is shown in.
///
/// Each language is named in itself — someone looking for their own scans the
/// list for the word they would write, not for the English for it — with the
/// English name beside it so the row is still readable in a language you do
/// not have. "System" follows the machine and says which language that turned
/// out to be, because "System" on its own tells you nothing.
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({required this.settings});

  final SettingsStore settings;

  String _labelFor(LanguageOption option) {
    if (option.code == LanguageOption.system.code) {
      return '${tr('System')} · ${LanguageOption.ofPlatform().endonym}';
    }
    // Compared *after* translating, not before. A language named in the
    // language now showing is named the same twice — its English name and its
    // endonym come out identical — and the second half is only worth drawing
    // when it says something the first does not.
    final named = tr(option.name);
    return option.endonym == named
        ? option.endonym
        : '${option.endonym} · $named';
  }

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      label: 'Show the application in',
      trailing: ChoiceButton<LanguageOption>(
        value: settings.language,
        width: 190,
        searchHint: tr('Search languages'),
        options: [
          for (final option in LanguageOption.choices)
            ChoiceOption(option, _labelFor(option)),
        ],
        onChanged: (value) => unawaited(settings.setLanguage(value)),
      ),
    );
  }
}

/// One weight on a slider, shown at the weight it sets.
///
/// The number on the right is drawn in its own weight, so the row answers "does
/// this font have that face" without leaving the line — which matters, because
/// a family that ships Regular and Bold and nothing else will draw four of these
/// steps identically and the slider will look broken to anyone who cannot see
/// why.
class _WeightSlider extends StatelessWidget {
  const _WeightSlider({
    required this.label,
    required this.value,
    required this.resolved,
    required this.onChanged,
    this.minimum = AppearanceSettings.weightMinimum,
    this.maximum = AppearanceSettings.weightMaximum,
    this.signed = false,
    this.floor,
  });

  final String label;

  /// The weight the slider is on, or the offset for the one that is an offset.
  final int value;

  /// What it comes to once [AppearanceSettings.weightOffset] is counted. Null
  /// for the offset itself, which is not a weight and has nothing to be drawn
  /// at.
  final FontWeightSpec? resolved;

  final ValueChanged<int> onChanged;
  final int minimum;
  final int maximum;

  /// Shows a leading `+` on anything above zero, for a number that is a shift
  /// rather than a weight.
  final bool signed;

  /// The lowest value that may be *chosen*. Below it the track is still there
  /// and still the same length — it simply cannot be dragged to.
  ///
  /// A floor rather than a smaller [minimum], and the difference is the whole
  /// point. Moving the minimum shortened the scale under the thumb, so the same
  /// weight sat in a different place depending on what the slider above it was
  /// set to; and at 900 it shortened it to nothing, where `divisions` came out
  /// zero and Slider asserts — dragging file weight to the top took the form
  /// down with it.
  final int? floor;

  @override
  Widget build(BuildContext context) => SteppedSlider(
        label: label,
        value: value,
        minimum: minimum,
        maximum: maximum,
        // A hundred, because that is the granularity a font family actually
        // has — `FontWeight` holds nine values with nothing between them, and
        // a finer slider would slide without the screen changing.
        step: AppearanceSettings.weightStep,
        signed: signed,
        floor: floor,
        // The number shows itself at the weight it is asking for.
        trailingStyle: TextStyle(fontWeight: resolved?.weight),
        onChanged: onChanged,
      );
}

/// One folding group of settings.
///
/// The rows are built whether or not the group is open, which is deliberate:
/// the search reads its labels off them, and a search that could only find what
/// was already showing would be no search at all.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1.1,
        fontWeight: context.uiWeight(FontWeight.w700),
      ),
    ),
  );
}

/// A colour, as a [SettingsRow]: the swatch and its code on the right, the picker
/// behind a press.
///
/// A function rather than a widget of its own, so there is exactly **one** kind
/// of row on this page. The search reads labels off `SettingsRow`s and the preview
/// lights them by target; a second row class would have to be taught both, and
/// the first one added afterwards would be the one nobody remembered to teach.
///
/// [allowAlpha] is whether the colour is meant to be seen through. Row striping
/// is: it is laid over the panel and is nearly all transparency.
Widget _colourRow({
  Key? key,
  required String label,
  required Color color,
  required ValueChanged<Color> onChanged,
  bool allowAlpha = false,
  PreviewTarget? target,
  bool lit = false,
}) => SettingsRow(
  key: key,
  label: label,
  target: target,
  lit: lit,
  // The colour first and its code beside it, on one line. A chip the size of a
  // button with the code underneath as a subtitle made every colour two rows
  // tall, and there are a dozen of them.
  trailing: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _Swatch(color: color),
      const SizedBox(width: 8),
      Text(
        allowAlpha ? _hexWithAlpha(color) : _hexOf(color),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    ],
  ),
  onTap: (context) async {
    final picked = await _pickColor(context, color, allowAlpha: allowAlpha);
    if (picked != null) onChanged(picked);
  },
);

String _hexOf(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

String _hexWithAlpha(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// A colour, as a dot. Draws a light and a dark half behind it, so a nearly
/// transparent one still reads as "pale over dark, pale over light" instead of
/// looking like an empty circle.
///
/// **Painted, not clipped**, and that is what mends it. This used to be two
/// half-width boxes with the colour over them, cut to a circle by
/// `Clip.antiAlias` — which cost it twice. The cut is masked in whole device
/// pixels, so the edge came out as a staircase and the dot read as a rounded
/// square at 18 logical pixels; and the outline, being part of the decoration,
/// was painted *before* the child and then half covered by it. Measured at 20×
/// on 2026-08-13, next to the same two faults around the preview panel's
/// corner — see `appearance_preview.dart`.
///
/// Filled paths are antialiased and they go on in the order they are written,
/// so both faults go away together: two arcs, the colour, the outline last.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, this.size = 18});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _SwatchFace(
          colour: color,
          edge: Theme.of(context).dividerColor,
        ),
      );
}

class _SwatchFace extends CustomPainter {
  const _SwatchFace({required this.colour, required this.edge});

  final Color colour;
  final Color edge;

  /// The two behind a translucent colour, so alpha reads as alpha instead of
  /// as whatever the form happens to be. Left dark, right light, which is what
  /// the two boxes were.
  static const _dark = Color(0xFF1B1F27);
  static const _light = Color(0xFFF2F4F7);

  @override
  void paint(Canvas canvas, Size size) {
    // Half the stroke in, so the outline lands inside the widget rather than
    // half outside it, where the row would take the outer half off again.
    final disc = (Offset.zero & size).deflate(0.5);

    canvas.drawArc(disc, math.pi / 2, math.pi, true, Paint()..color = _dark);
    canvas.drawArc(disc, -math.pi / 2, math.pi, true, Paint()..color = _light);
    canvas.drawOval(disc, Paint()..color = colour);
    canvas.drawOval(
      disc,
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_SwatchFace old) =>
      old.colour != colour || old.edge != edge;
}

/// A deliberately small colour picker: a palette plus a hex field. Enough to
/// theme the panels without pulling in a dependency.
Future<Color?> _pickColor(
  BuildContext context,
  Color current, {
  bool allowAlpha = false,
}) {
  const palette = <int>[
    0xFF000000,
    0xFF11141B,
    0xFF23262B,
    0xFF3B4048,
    0xFF6B7280,
    0xFFB6BDC7,
    0xFFE8EEF7,
    0xFFFFFFFF,
    0xFF0000A8,
    0xFF0B2A5B,
    0xFF12447A,
    0xFF2F72D6,
    0xFF4C9AFF,
    0xFF8FB8FF,
    0xFF006B5B,
    0xFF12A594,
    0xFF54FCFC,
    0xFF166534,
    0xFF22C55E,
    0xFF86EFAC,
    0xFF7C2D12,
    0xFFB5460F,
    0xFFF97316,
    0xFFFFB86C,
    0xFFFFD24A,
    0xFFFCFC54,
    0xFF7F1D1D,
    0xFFDC2626,
    0xFFFCA5A5,
    0xFF581C87,
    0xFF9333EA,
    0xFFD8B4FE,
  ];

  return showDeskWindow<Color>(
    context,
    id: 'colour-picker',
    title: tr('Pick a colour'),
    icon: Icons.palette_outlined,
    preferredSize: Size(430, allowAlpha ? 560 : 500),
    minSize: const Size(360, 420),
    builder: (window) => _ColorPicker(
      window: window,
      current: current,
      palette: palette,
      allowAlpha: allowAlpha,
    ),
  );
}

/// The picker's contents: the palette, or a colour mixed by hand.
class _ColorPicker extends StatefulWidget {
  const _ColorPicker({
    required this.window,
    required this.current,
    required this.palette,
    required this.allowAlpha,
  });

  final DeskWindow window;
  final Color current;
  final List<int> palette;
  final bool allowAlpha;

  @override
  State<_ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<_ColorPicker>
    with SingleTickerProviderStateMixin {
  late Color _colour = widget.current;
  late final TextEditingController _hex = TextEditingController(text: _text());

  /// The palette first: most colours in this app are one of the swatches, and
  /// the custom tab is for the one that is not.
  late final TabController _tabs = TabController(length: 2, vsync: this);

  String _text() => widget.allowAlpha
      ? _hexWithAlpha(_colour).substring(1)
      : _hexOf(_colour).substring(1);

  @override
  void dispose() {
    _hex.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _set(Color colour) {
    setState(() => _colour = colour);
    _hex.text = _text();
  }

  /// A swatch keeps the opacity already dialled in, so picking a hue does not
  /// silently turn a three per cent overlay into a solid block.
  void _pickSwatch(int value) {
    final picked = Color(value);
    if (!widget.allowAlpha) {
      widget.window.close(picked);
      return;
    }
    _set(picked.withValues(alpha: _colour.a));
  }

  @override
  Widget build(BuildContext context) {
    return WindowForm(
      onSubmit: () => widget.window.close(_parseHex(_hex.text)),
      actions: [
        TextButton(onPressed: widget.window.close, child: Text(tr('Cancel'))),
        FilledButton(
          onPressed: () => widget.window.close(_parseHex(_hex.text)),
          child: Text(tr('Apply')),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            controller: _tabs,
            tabs: [Tab(text: tr('Palette')), Tab(text: tr('Custom'))],
          ),
          SizedBox(
            // A fixed height, because a TabBarView has no size of its own and
            // the two tabs are not the same height anyway. Tall enough for the
            // mixing area, which is the taller of them.
            height: 236,
            child: TabBarView(
              controller: _tabs,
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final value in widget.palette)
                        InkWell(
                          onTap: () => _pickSwatch(value),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: Color(value),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Color(value) == _colour
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).dividerColor,
                                width: Color(value) == _colour ? 2 : 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _ColourMixer(
                    colour: _colour,
                    onChanged: (value) => _set(
                      widget.allowAlpha
                          ? value.withValues(alpha: _colour.a)
                          : value,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.allowAlpha) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text(tr('Opacity')),
                Expanded(
                  child: Slider(
                    value: _colour.a,
                    divisions: 100,
                    label: '${(_colour.a * 100).round()}%',
                    onChanged: (value) =>
                        _set(_colour.withValues(alpha: value)),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${(_colour.a * 100).round()}%',
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 8),
                _Swatch(color: _colour, size: 24),
              ],
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _hex,
            decoration: InputDecoration(
              labelText: tr('Hex'),
              prefixText: '#',
              hintText: widget.allowAlpha ? 'AARRGGBB' : 'RRGGBB',
            ),
            onSubmitted: (value) => widget.window.close(_parseHex(value)),
          ),
        ],
      ),
    );
  }
}

/// Accepts `RRGGBB` or `AARRGGBB`, with or without a leading `#`.
Color? _parseHex(String value) {
  var text = value.trim().replaceAll('#', '');
  if (text.length == 6) text = 'FF$text';
  if (text.length != 8) return null;
  final parsed = int.tryParse(text, radix: 16);
  return parsed == null ? null : Color(parsed);
}

/// Mixing a colour by hand: a saturation-and-brightness square over a strip of
/// hues, the shape every picker has used for thirty years.
///
/// Here rather than from a package: it is a hundred lines, and a file manager
/// that grows a dependency for a colour square will grow one for everything.
class _ColourMixer extends StatelessWidget {
  const _ColourMixer({required this.colour, required this.onChanged});

  final Color colour;
  final ValueChanged<Color> onChanged;

  static const double _stripHeight = 22;

  @override
  Widget build(BuildContext context) {
    final hsv = HSVColor.fromColor(Color.from(
      alpha: 1,
      red: colour.r,
      green: colour.g,
      blue: colour.b,
    ));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (d) => _pickShade(hsv, d.localPosition, constraints),
              onPanUpdate: (d) => _pickShade(hsv, d.localPosition, constraints),
              child: CustomPaint(
                painter: _ShadePainter(hue: hsv.hue, marker: hsv),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: _stripHeight,
          child: LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (d) => _pickHue(hsv, d.localPosition, constraints),
              onPanUpdate: (d) => _pickHue(hsv, d.localPosition, constraints),
              child: CustomPaint(
                painter: _HuePainter(hue: hsv.hue),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _pickShade(HSVColor hsv, Offset at, BoxConstraints box) {
    final saturation = (at.dx / box.maxWidth).clamp(0.0, 1.0);
    final value = 1 - (at.dy / box.maxHeight).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(saturation).withValue(value).toColor());
  }

  void _pickHue(HSVColor hsv, Offset at, BoxConstraints box) {
    final hue = (at.dx / box.maxWidth).clamp(0.0, 1.0) * 360;
    onChanged(hsv.withHue(hue).toColor());
  }
}

/// White to the hue across, black up from the bottom — the standard square.
class _ShadePainter extends CustomPainter {
  const _ShadePainter({required this.hue, required this.marker});

  final double hue;
  final HSVColor marker;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & size;
    final rounded = RRect.fromRectAndRadius(area, const Radius.circular(6));
    canvas.save();
    canvas.clipRRect(rounded);

    canvas.drawRect(
      area,
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white,
            HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
          ],
        ).createShader(area),
    );
    canvas.drawRect(
      area,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(area),
    );
    canvas.restore();

    canvas.drawRRect(
      rounded,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black26,
    );

    // Ringed in both colours, so it stays visible over every shade.
    final at = Offset(
      marker.saturation * size.width,
      (1 - marker.value) * size.height,
    );
    canvas.drawCircle(
      at,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    canvas.drawCircle(
      at,
      8.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.black45,
    );
  }

  @override
  bool shouldRepaint(_ShadePainter old) =>
      old.hue != hue || old.marker != marker;
}

class _HuePainter extends CustomPainter {
  const _HuePainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & size;
    final rounded = RRect.fromRectAndRadius(
      area,
      Radius.circular(size.height / 2),
    );

    canvas.drawRRect(
      rounded,
      Paint()
        ..shader = LinearGradient(
          colors: [
            for (var degrees = 0; degrees <= 360; degrees += 60)
              HSVColor.fromAHSV(1, degrees % 360, 1, 1).toColor(),
          ],
        ).createShader(area),
    );

    final x = (hue / 360) * size.width;
    canvas.drawCircle(
      Offset(x.clamp(3.0, size.width - 3), size.height / 2),
      size.height / 2 - 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_HuePainter old) => old.hue != hue;
}

/// The three colours a palette is made of, drawn as one small mark.
///
/// **This is what a palette is chosen by now.** A name tells you what somebody
/// called it; three swatches tell you what it will look like, and that is the
/// question.
///
/// Paper, chrome, accent — in that order, left to right, largest thing first.
class PaletteSwatch extends StatelessWidget {
  const PaletteSwatch({super.key, required this.seeds, this.size = 12});

  final PaletteSeeds seeds;

  /// Height of each square. The mark is three of them side by side.
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size * 3 + 4,
    height: size,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (index, colour)
            in [seeds.paper, seeds.chrome, seeds.accent].indexed)
          Container(
            width: size,
            height: size,
            // Between them, not after the last one — the width above is three
            // squares and two gaps, and a trailing gap overflows it by two.
            margin: EdgeInsets.only(right: index == 2 ? 0 : 2),
            decoration: BoxDecoration(
              color: colour,
              borderRadius: BorderRadius.circular(2),
              // An outline, or a white paper on a white row is nothing at all —
              // the same reasoning the alternating stripe is chosen by.
              border: Border.all(
                color: const Color(0x66808080),
                width: 0.5,
              ),
            ),
          ),
      ],
    ),
  );
}

/// Picks a palette out of the list, showing each one as its three colours.
///
/// **It applies as it is walked, and puts back what was there if you leave.**
/// Choosing a palette from a name and finding out afterwards is the thing this
/// replaces; the palette under the highlight is the palette on screen, so
/// walking the list with the arrow keys *is* looking at them. Escape closes
/// the menu without choosing, and what was in force comes back.
///
/// Rule number one applies: everything here is reachable from the keyboard,
/// and Escape goes back — see the menu this is built on.
class _PaletteButton extends StatefulWidget {
  const _PaletteButton({
    required this.settings,
    required this.mine,
  });

  final SettingsStore settings;

  /// The palettes out of the user's own folder, after the shipped ones.
  final List<ColourScheme> mine;

  @override
  State<_PaletteButton> createState() => _PaletteButtonState();
}

class _PaletteButtonState extends State<_PaletteButton> {
  /// **A field, not a local in `build`.** A `GlobalKey` made afresh each build
  /// tears its subtree down and puts a new one up every frame, which showed up
  /// as "looking up a deactivated widget's ancestor" the first time a test
  /// pressed anything on this page.
  final GlobalKey _anchor = GlobalKey();

  SettingsStore get settings => widget.settings;

  /// The palette on screen, if it is one of the ones on offer.
  ///
  /// Matched on the **seeds and what was pressed**, not on a stored name: a
  /// name would have to be kept in the settings and kept in step with the file
  /// it came from, and would go stale the moment somebody edited either.
  ColourScheme? _current(List<ColourScheme> all, AppearanceSettings theme) {
    final recipe = theme.recipe;
    for (final scheme in all) {
      if (scheme.recipe == recipe) return scheme;
    }
    return null;
  }

  Future<void> _open() async {
    final box =
        _anchor.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final all = [...ColourSchemeLibrary.builtIn, ...widget.mine];
    // What to put back if the menu is left without a choice.
    final before = settings.appearance;
    ColourScheme? chosen;

    MenuItem row(ColourScheme scheme) => MenuItem(
      tr(scheme.name),
      leading: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: PaletteSwatch(seeds: scheme.swatch),
      ),
      leadingWidth: 46,
      keywords: [if (scheme.swatch.isDark) 'dark' else 'light'],
      onSelected: () {
        chosen = scheme;
        settings.updateAppearance(scheme.applyTo);
      },
    );

    final light = all.where((s) => !s.swatch.isDark).toList();
    final dark = all.where((s) => s.swatch.isDark).toList();

    await showAppContextMenu(
      context: context,
      anchorRect: box.localToGlobal(Offset.zero) & box.size,
      searchHint: tr('Search palettes'),
      // Grouped by what they are rather than by where they came from: somebody
      // looking for a palette knows whether they want a light one long before
      // they care whether it shipped with the application.
      nodes: [
        MenuSeparator(tr('Light')),
        ...light.map(row),
        MenuSeparator(tr('Dark')),
        ...dark.map(row),
      ],
      onRowHighlighted: (item) {
        if (item == null) return;
        final scheme = all
            .where((s) => tr(s.name) == item.label)
            .firstOrNull;
        if (scheme != null) settings.updateAppearance(scheme.applyTo);
      },
    );

    // **Left without choosing: put back exactly what was there.** Not "the
    // palette it was" — the whole appearance, because the walk laid palettes
    // over it and a palette carries darkChrome, which the window's own chrome
    // reads.
    if (chosen == null) settings.updateAppearance((_) => before);
  }

  @override
  Widget build(BuildContext context) {
    final theme = settings.appearance;
    final all = [...ColourSchemeLibrary.builtIn, ...widget.mine];
    final current = _current(all, theme);

    return InkWell(
      key: _anchor,
      onTap: () => unawaited(_open()),
      borderRadius: BorderRadius.circular(6),
      child: InputDecorator(
        decoration: const InputDecoration(isDense: true),
        child: Row(
          children: [
            PaletteSwatch(seeds: theme.recipe.seeds),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                // **"Custom" is not a failure to find one**, it is the true
                // answer: these three colours and these pressed ones are not
                // any of the palettes on offer, and saying "Xverb Light" because
                // it is nearest would be a lie the next press acts on.
                current == null ? tr('Custom') : tr(current.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}
