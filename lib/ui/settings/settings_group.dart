import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import '../motion.dart';
import '../plugins/plugin_table.dart' show appearanceOf;
import '../text_scale.dart';
import '../widgets/hint.dart';

/// How a settings page is built: folding groups, one open at a time, a box to
/// search them with, and a row that is a line of text rather than a target for
/// a finger.
///
/// **Shared because there are two pages, not because there might be.** The
/// Appearance tab got this shape and the Plugins tab was given the same one
/// within the hour, and two accordions written twice are two accordions that
/// drift: one animates and the other cuts, one closes on a second press and the
/// other does not. The pages differ in what goes *in* the groups, which is
/// where they should differ.

class SettingsGroup {
  const SettingsGroup({
    required this.title,
    required this.rows,
    this.icon,
    this.note,
  });

  /// English, translated where it is drawn — the same arrangement as [SettingsRow],
  /// and for the same reason: the search has to match either language.
  final String title;

  final List<Widget> rows;
  final IconData? icon;

  /// A paragraph at the foot of the group, for what a row cannot say in a line
  /// — why a blur needs an opaque window, what the five weights do to each
  /// other. These used to sit loose in the list between sections, which is part
  /// of why it read as one long page.
  final String? note;

  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return title.toLowerCase().contains(needle) ||
        tr(title).toLowerCase().contains(needle);
  }
}

/// A group, drawn as a header that folds what is under it.
///
/// **It grows and shrinks rather than appearing and vanishing** — rule number
/// two, and the one place it matters most here: two groups are moving at once
/// when one hands over to another, and a cut would read as the page jumping.
class SettingsGroupTile extends StatelessWidget {
  const SettingsGroupTile({
    super.key,
    required this.group,
    required this.open,
    required this.onPressed,
    this.count,
  });

  final SettingsGroup group;
  final bool open;
  final VoidCallback onPressed;

  /// How many things are inside, when that is worth saying before it is opened
  /// — a shelf of plugins is a different question from a group of settings,
  /// where the number would only be a count of switches.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tab reaches it and Enter or Space opens it. A header that only
        // answers the mouse is a group the keyboard cannot get into, and a
        // control the keyboard cannot reach does not exist.
        //
        // **The keys are bound here rather than left to the `InkWell`.**
        // Measured on 2026-08-18 with a focus probe: Tab does land on the
        // header — the ink well is focusable and takes the highlight — and
        // Enter did nothing at all. An ink well answers `ActivateIntent`, and
        // what reaches it from a bare Enter depends on the platform's own
        // shortcut map; binding both keys is one line and does not depend on
        // which platform this is running on.
        FocusableActionDetector(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                onPressed();
                return null;
              },
            ),
          },
          child: InkWell(
            // The detector above is the focusable one; two focus stops for one
            // header would mean Tab landing on the same row twice.
            canRequestFocus: false,
            onTap: onPressed,
            child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: SizedBox(
              height: 36,
              child: Row(
                children: [
                  if (group.icon != null) ...[
                    Icon(group.icon, size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      tr(group.title),
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: context.uiWeight(FontWeight.w600),
                      ),
                    ),
                  ),
                  if (count != null) ...[
                    Text(
                      '$count',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  // Turns rather than swapping: the same mark, moved, says
                  // "this opened" — two different marks would only say "this
                  // is different now".
                  AnimatedRotation(
                    turns: open ? 0.25 : 0,
                    duration: motionOf(context, kSettingsFoldDuration),
                    curve: kBothCurve,
                    child: Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            ),
          ),
        ),
        // Built only while it is open, and given its height by AnimatedSize —
        // an AnimatedCrossFade would keep the closed half laid out, and there
        // are nine of these.
        ClipRect(
          child: AnimatedSize(
            duration: motionOf(context, kSettingsFoldDuration),
            curve: kBothCurve,
            alignment: Alignment.topCenter,
            child: open
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ...group.rows,
                      if (group.note != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                          child: Text(
                            tr(group.note!),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      const SizedBox(height: 6),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ),
        Divider(height: 1, color: scheme.outlineVariant),
      ],
    );
  }
}

/// The caption over a run of search results, saying which group they are from.
class FoundIn extends StatelessWidget {
  const FoundIn({super.key, required this.group, this.query = ''});

  final SettingsGroup group;

  /// What was searched for, so a group offered **whole** — because its own name
  /// matched — says so here. Otherwise a group that answers "font" with a row
  /// about weights looks like a mistake, when it is the deliberate rule that
  /// somebody typing the name of a group means the group.
  final String query;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Row(
      children: [
        if (group.icon != null) ...[
          Icon(
            group.icon,
            size: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
        ],
        Builder(
          builder: (context) {
            final style = Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              fontWeight: context.uiWeight(FontWeight.w700),
            );
            final accent = appearanceOf(context).accentColor;
            final shown = tr(group.title).toUpperCase();
            final asked = query.trim().toUpperCase();

            // The group's name is what matched, and the rows under it are the
            // whole group rather than a set of answers — so the name is where
            // the mark goes. **In English too**, and that is not a detail: the
            // name is matched in either language, so on a translated interface
            // an English word can take a whole group with not a letter of it on
            // the screen. Then the English is put beside it, marked, and
            // the row that arrives with no highlight of its own is explained
            // by the header above it.
            if (!shown.contains(asked) && _holds(group.title, query)) {
              return Row(
                children: [
                  Text(shown, style: style),
                  const SizedBox(width: 6),
                  Text.rich(
                    marked(
                      group.title.toUpperCase(),
                      asked,
                      style?.copyWith(fontStyle: FontStyle.italic),
              accent,
            ),
                  ),
                ],
              );
            }
            return Text.rich(marked(shown, asked, style,
              accent,
            ));
          },
        ),
      ],
    ),
  );
}

/// The box the page is searched with.
///
/// **Escape empties it and gives the groups back**, which is the same sentence
/// Escape says everywhere else in this application: one step back, not out of
/// the page.
class SettingsSearchBox extends StatelessWidget {
  const SettingsSearchBox({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = 'Search the settings',
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// English, translated here — what the box is searching through.
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): _ClearSearchIntent(),
      },
      child: Actions(
        actions: {
          _ClearSearchIntent: CallbackAction<_ClearSearchIntent>(
            onInvoke: (_) {
              controller.clear();
              onChanged('');
              return null;
            },
          ),
        },
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 34),
            hintText: tr(hint),
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            suffixIcon: controller.text.isEmpty
                ? null
                // The application's own hint, never Material's tooltip — see
                // `hints_are_ours_test`, which is what caught this.
                : Hint(
                    message: tr('Clear'),
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () {
                        controller.clear();
                        onChanged('');
                      },
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _ClearSearchIntent extends Intent {
  const _ClearSearchIntent();
}

/// How tall a row in this page is, which is a question about the pointer and
/// not about the window.
///
/// The controls here used to be large, and it was inherited from the mobile
/// layout. Every one of them was a
/// Material `ListTile` or `SwitchListTile`, and those are sized for a finger:
/// measured on this page, a colour row came out at 48 logical pixels and a
/// switch with a line of explanation under it at **80**, so eleven rows of
/// thirty-seven filled a 936-pixel window.
///
/// A finger still needs the room, though, and the narrow layout of this page is
/// the phone one. So the size is carried down from where that is already known
/// rather than measured again per row — and it is the *layout* that knows,
/// because that is what the window width was already used to decide.
class SettingsRowMetrics extends InheritedWidget {
  const SettingsRowMetrics({
    super.key,
    required this.dense,
    required super.child,
  });

  /// Mouse: a row is a line of text with something on the end of it. Touch: it
  /// is a thing to hit.
  final bool dense;

  double get height => dense ? 30 : 48;

  /// With a line of explanation under the label. Still well under the 80 the
  /// switches used to take.
  double get tallHeight => dense ? 44 : 62;

  static SettingsRowMetrics of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsRowMetrics>() ??
      const SettingsRowMetrics(dense: true, child: SizedBox());

  @override
  bool updateShouldNotify(SettingsRowMetrics old) => old.dense != dense;
}

/// One setting: what it is on the left, what it is set to on the right.
///
/// **The label is the search key as well as the caption**, which is why the
/// search reads it straight off these widgets rather than off a second list
/// kept beside them. A list that has to be kept in step is a list that goes
/// stale the first time a setting is added.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    this.note,
    this.trailing,
    this.onTap,
    this.target,
    this.lit = false,
    this.enabled = true,
  });

  /// **The English, not the translation** — [tr] is applied here rather than at
  /// the call site, and that is what lets [matches] search both. A row handed
  /// an already-translated caption has lost the key, and then searching a
  /// Russian interface for "opacity" finds nothing.
  final String label;

  /// The line under it, in English for the same reason. Kept to one line and
  /// cut with an ellipsis: the whole of it is in the hint, and a paragraph in a
  /// settings row is what made these eighty pixels tall.
  final String? note;

  final Widget? trailing;

  /// Handed the row's own context, so a row can open a picker without a
  /// `Builder` wrapped round every call site that needs one.
  final ValueChanged<BuildContext>? onTap;

  /// What this row *is*, for whoever needs to find it again — the Appearance
  /// page puts a  here so a press in the preview can open the
  /// group the colour lives in and point at the row. Untyped on purpose: the
  /// row does not care what the page means by it, only whether two of them are
  /// the same.
  final Object? target;

  /// Lit because the preview just sent us here.
  final bool lit;

  /// A setting that has nothing to act on yet — how a row answers while the
  /// live list is off. Dimmed rather than hidden, so it can be found before the
  /// switch that gives it something to do.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final metrics = SettingsRowMetrics.of(context);
    final scheme = Theme.of(context).colorScheme;
    final accent = appearanceOf(context).accentColor;
    final has = note != null && note!.isNotEmpty;
    final ink = enabled ? null : scheme.onSurface.withValues(alpha: 0.38);

    // What was typed into the search box, if anything, so the row can show
    // *why* it is one of the answers. See [SettingsSearch].
    final query = SettingsSearch.of(context);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: ink);

    // A row can be an answer for a reason that is nowhere on the screen: the
    // query matched the English the key is written in while the interface is in
    // another language. Then there is nothing to pick out, and the honest thing
    // is to say what did match rather than leave the row looking arbitrary.
    final onlyInEnglish = query.isNotEmpty &&
        !_holds(tr(label), query) &&
        !(has && _holds(tr(note!), query)) &&
        (_holds(label, query) || (has && _holds(note!, query)));

    // A row is one line tall or two, and the height has to know which before
    // the words are laid out. It used to be "has a note"; now the English
    // shown in a note's place counts as well, and a row with neither used to
    // overflow by six pixels the moment it was an answer in English only.
    final twoLines = has || onlyInEnglish;

    final lines = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          marked(tr(label), query, TextStyle(color: ink),
              accent,
            ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // **The English in place of the note, not under it.** A row is two
        // lines tall and no more — a third overflowed it by six pixels — and
        // between the two the one worth showing is the one that answers "why
        // is this row here", which the note does not.
        if (onlyInEnglish)
          Text.rich(
            marked(
              _holds(label, query) ? label : note!,
              query,
              small?.copyWith(fontStyle: FontStyle.italic),
              accent,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        else if (has)
          Text.rich(
            marked(tr(note!), query, small,
              accent,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );

    // **The hint belongs to the words, and is measured where they are.**
    //
    // Its message is the row's own label and its own note, and both are drawn
    // right there — so on a row that fits, the bubble covered the row above it
    // to repeat what was already legible. It earns its place only where the row
    // had to cut something off.
    //
    // Measured *here*, inside whatever box the text actually got, because that
    // is the only place the width is known: a row that lays its control out
    // beside the words gives them a few hundred pixels less than the row is
    // wide. Measuring against the row instead — the first attempt — answered
    // "it fits" for every side-by-side row on the page, which is most of them,
    // and the note went on being cut with nothing offering to finish it.
    //
    // It also wraps the words alone rather than the whole strip, so the bubble
    // is anchored to the text it is about, and resting on the control at the
    // other end of the row raises nothing.
    final words = LayoutBuilder(
      builder: (context, box) => Hint(
        message: _cutOff(context, box.maxWidth)
            ? (has ? '${tr(label)} — ${tr(note!)}' : tr(label))
            : '',
        child: lines,
      ),
    );

    // **Side by side while there is room, stacked when there is not.** A
    // segmented button of three, or a slider and its number, does not shrink
    // below its own width — so on a narrow column the row that used to fit
    // simply ran off the end. Which layout is right is a question about the
    // width *this row* was given, not about the window: the list is a column
    // beside a 440-pixel preview, so it can be narrow on a wide screen.
    Widget row = LayoutBuilder(
      builder: (context, box) {
        if (trailing == null) {
          return SizedBox(
            height: twoLines ? metrics.tallHeight : metrics.height,
            child: words,
          );
        }
        // Touch always stacks: a control under its label is what a phone
        // does, and it is the layout where the widest of these — a segmented
        // button of three words — has nowhere to go sideways.
        if (metrics.dense && box.maxWidth >= _sideBySideRow) {
          return SizedBox(
            height: twoLines ? metrics.tallHeight : metrics.height,
            child: Row(
              children: [
                Expanded(child: words),
                const SizedBox(width: 12),
                trailing!,
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              words,
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerLeft, child: trailing!),
            ],
          ),
        );
      },
    );

    if (lit) {
      // Fades rather than switching off: a light going out in one frame reads
      // as a fault. It is drawn behind the row, so nothing about the row moves.
      row = TweenAnimationBuilder<double>(
        key: ValueKey(target),
        tween: Tween(begin: 1, end: 0),
        duration: motionOf(context, kSettingsFlashDuration),
        curve: kLeavingCurve,
        builder: (context, t, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.20 * t),
            borderRadius: BorderRadius.circular(4),
          ),
          child: child,
        ),
        child: row,
      );
    }

    return InkWell(
      onTap: onTap == null ? null : () => onTap!(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: row,
      ),
    );
  }

  /// Whether either line of this row would be cut at [room] wide.
  ///
  /// Asked of a `TextPainter` rather than of the `Text` that is drawn, because
  /// a widget cannot be asked afterwards whether it had to use its ellipsis —
  /// and the answer is needed *before* the row is built, to decide whether it
  /// has a hint at all.
  bool _cutOff(BuildContext context, double room) {
    if (room <= 0) return false;
    final base = DefaultTextStyle.of(context).style;
    final small = Theme.of(context).textTheme.bodySmall;
    final scale = MediaQuery.textScalerOf(context);

    bool cut(String text, TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        maxLines: 1,
        textScaler: scale,
        textDirection: Directionality.of(context),
      )..layout(maxWidth: room);
      return painter.didExceedMaxLines;
    }

    return cut(tr(label), null) ||
        (note != null && note!.isNotEmpty && cut(tr(note!), small));
  }

  /// Under this much room for the row itself, the control goes under the label
  /// instead of beside it. Wide enough for a label worth reading next to a
  /// segmented button of three.
  static const double _sideBySideRow = 380;

  /// Whether this row answers [query] — in the language on screen or in the
  /// English the key is written in.
  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    for (final text in [
      label,
      note ?? '',
      tr(label),
      if (note != null) tr(note!),
    ]) {
      if (text.toLowerCase().contains(needle)) return true;
    }
    return false;
  }
}


/// Whether [text] holds [query], the way the search asks it.
bool _holds(String text, String query) =>
    text.toLowerCase().contains(query.trim().toLowerCase());

/// [text] with every run of [query] in it picked out.
///
/// **Because a list of answers has to say why each one is an answer.** The
/// search looks in four places — a row's label and its note, each in the
/// language on screen and in the English the key is written in — and a group
/// whose *name* matches offers everything inside it. Three good reasons, and
/// until now not one of them was visible: a row could turn up with the word
/// nowhere on it and look like a mistake.
/// [accent] is the application's own, not Material's: a `ColorScheme` is seeded
/// from the accent and knows nothing about what a surface is painted in, and
/// this mark is drawn on a listing, a plugin row and a settings page alike.
TextSpan marked(
  String text,
  String query,
  TextStyle? base,
  Color accent,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return TextSpan(text: text, style: base);

  final haystack = text.toLowerCase();
  final runs = <TextSpan>[];
  var at = 0;
  while (true) {
    final hit = haystack.indexOf(needle, at);
    if (hit < 0) break;
    if (hit > at) runs.add(TextSpan(text: text.substring(at, hit)));
    runs.add(
      TextSpan(
        text: text.substring(hit, hit + needle.length),
        // The accent behind it rather than a colour of its own: what is marked
        // here is what was asked for, and that is what the accent means
        // everywhere else in the application.
        style: TextStyle(
          backgroundColor: accent.withValues(alpha: 0.28),
        ),
      ),
    );
    at = hit + needle.length;
  }
  if (runs.isEmpty) return TextSpan(text: text, style: base);
  if (at < text.length) runs.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: base, children: runs);
}

/// What is in the search box, handed down to the rows so each can show why it
/// is one of the answers.
///
/// An inherited widget rather than an argument, because the rows are written
/// out by hand at the call sites — a `SettingsRow` per setting, in a list — and
/// threading a query through every one of them would be a change to every line
/// of the settings page for the sake of one.
class SettingsSearch extends InheritedWidget {
  const SettingsSearch({
    super.key,
    required this.query,
    required super.child,
  });

  final String query;

  /// Empty when nothing is being searched for, which is also the answer
  /// wherever the settings are shown without a search box at all.
  static String of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SettingsSearch>()
          ?.query
          .trim() ??
      '';

  @override
  bool updateShouldNotify(SettingsSearch old) => old.query != query;
}
