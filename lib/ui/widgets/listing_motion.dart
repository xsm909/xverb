import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/settings/appearance_settings.dart';
import '../motion.dart';

/// The two things that move in a listing, wherever the listing came from.
///
/// **A panel's rows and a plugin's table are one piece of furniture.** They are
/// drawn in the same window by the same application, and a cursor that slides
/// on one side of it and cuts on the other reads as two programs sharing a
/// window rather than as one program. So both are here, both answer the same
/// two settings, and neither has a copy of its own.

/// The cursor's slide from one row to the next, and where it has got to.
///
/// Held by whoever draws the rows, because the mark is one thing moving
/// *between* them: the row it is arriving at and the row it is leaving are two
/// halves of one movement, and neither can own it. Everything that answers the
/// cursor — the mark's position, a row's lean, the text inverting — runs off
/// this one animation. They were three timings once, and holding an arrow key
/// showed it: the key repeats faster than the mark travels, so the row it was
/// going to had finished leaning while the mark was still on its way.
class CursorSlide {
  CursorSlide(TickerProvider vsync)
      : _slide = AnimationController(
          vsync: vsync,
          duration: const Duration(milliseconds: kCursorAnimationDuration),
          value: 1,
        ) {
    // Made once rather than per build: a `CurvedAnimation` holds a listener on
    // its parent, and a listing rebuilds on every keystroke.
    arriving = CurvedAnimation(parent: _slide, curve: kBothCurve);
    leaving = ReverseAnimation(arriving);
  }

  final AnimationController _slide;

  /// Seen from the row being arrived at: 0 as the mark sets off, 1 when it is
  /// there.
  late final Animation<double> arriving;

  /// The same, seen from the row being left: 1 while the mark is still on it.
  late final Animation<double> leaving;

  /// Where the mark set off from, in viewport pixels rather than in rows.
  ///
  /// Rows would be the obvious unit and they are the wrong one. End on a long
  /// listing moves the cursor five thousand rows and scrolls the view to the
  /// bottom in the same breath; interpolated in rows the mark would set off
  /// upwards out of the viewport and fly back in from nowhere. What actually
  /// happened on screen is that the mark went from where it was to where it now
  /// is, a few centimetres at most.
  double _fromY = 0;

  /// The row the mark is leaving, for as long as its text is still inverting
  /// back. -1 when there is none.
  int _fromIndex = -1;

  int _lastIndex = -1;
  Object? _lastListing;

  void dispose() => _slide.dispose();

  /// How far [index] is into being the cursor, 0..1 — and it is the *mark's*
  /// own progress, not a length of its own. Null where the cursor does not
  /// animate at all: the mark is a cut then, and a row easing into place behind
  /// it would describe a movement that did not happen.
  Animation<double>? progressFor(int index, {required bool isCursor, required bool sliding}) {
    if (!sliding) return null;
    if (isCursor) return arriving;
    return index == _fromIndex ? leaving : null;
  }

  /// Starts a slide if the cursor has moved somewhere a slide would be true of.
  ///
  /// [listing] is whatever identifies the list being shown — a location, a
  /// content object. A new one still slides: coming out of a deep folder with
  /// the mark at the foot of the window and finding it at the top with nothing
  /// in between is a cut, and a cut is what the eye loses. What the mark states
  /// by moving is *where the keyboard now is*, and that is true whatever the
  /// rows underneath did.
  void follow(
    int index,
    Object? listing,
    double rowHeight,
    double scrollOffset, {
    required bool sliding,
    required Duration length,
  }) {
    final was = _lastIndex;
    final sameListing = listing == _lastListing;

    // Tracked even with the setting off, so that turning it on does not owe
    // the first move a slide from nowhere.
    _lastIndex = index;
    _lastListing = listing;
    if (index == was) return;

    _slide.duration = length;
    if (sliding && was >= 0) {
      // Where the mark is at this instant, which is not necessarily where the
      // row it was on has got to: a second keystroke can arrive mid-slide, and
      // then it sets off from where the eye last saw it rather than snapping
      // ahead to the row it had not reached yet.
      _fromY = was * rowHeight - scrollOffset;
      // The row being left keeps its inverted text only if it is still the
      // same row. In a new listing that index belongs to some other file, and
      // fading a stranger's text back from the cursor colour is a claim about
      // a file that was never on the cursor.
      _fromIndex = sameListing ? was : -1;
      _slide.forward(from: 0);
    } else {
      _fromIndex = -1;
      if (_slide.value != 1) _slide.value = 1;
    }
  }

  /// Where the mark is drawn, in viewport pixels, on its way to [index].
  double markY(int index, double rowHeight, double scrollOffset) {
    final target = index * rowHeight - scrollOffset;
    return _fromY + (target - _fromY) * arriving.value;
  }
}

/// Marks the sliding cursor apart from a row's own fill, which is the same
/// rectangle in the same colour and does not move.
const Key kListCursorKey = ValueKey('list-cursor');

/// The one cursor mark in a listing, drawn under the rows and slid between
/// them.
///
/// One of it rather than a fill on each row, for the same reason there is one
/// panel ring rather than a border on each panel: a thing that moves has to be
/// one thing. Rows take turns being the cursor; a mark that slides cannot be
/// owned by either the row it is leaving or the row it is going to.
class CursorMark extends StatelessWidget {
  const CursorMark({
    super.key,
    required this.slide,
    required this.index,
    required this.rowHeight,
    required this.scroll,
    required this.colour,
  });

  final CursorSlide slide;
  final int index;
  final double rowHeight;
  final ScrollController scroll;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // The scroll position as well as the slide: the mark is placed in
      // viewport pixels, so a listing scrolling under a cursor that is not
      // moving still moves the mark.
      animation: Listenable.merge([slide.arriving, scroll]),
      // Built once and carried through. It is a rectangle of one colour; only
      // where it is changes.
      //
      // Keyed because a row's own fill is a rectangle of the same colour, and
      // the difference between the two — one of them slides — is the whole
      // point of this widget and invisible to anything looking for a colour.
      child: ColoredBox(key: kListCursorKey, color: colour),
      builder: (context, child) => Positioned(
        left: 0,
        right: 0,
        top: slide.markY(
          index,
          rowHeight,
          scroll.hasClients ? scroll.position.pixels : 0,
        ),
        height: rowHeight,
        child: child!,
      ),
    );
  }
}


/// A row that answers the pointer, for as long as the setting says so.
///
/// It answers under the mouse and further under the keyboard cursor, which
/// outranks it, and it takes the answer faster than it gives it back. That
/// asymmetry is the whole of the effect: a pointer swept down a listing leaves
/// a wake of rows on their way back, where equal lengths would give one row
/// answering under the pointer and nothing else.
///
/// **Two answers, and only one of them is this row's own business.** The mouse
/// is: it arrives and leaves on this row alone, off a controller here, fast one
/// way and slow the other. The keyboard is not: the cursor is one thing moving
/// between rows, and the row it is arriving at and the row it is leaving are
/// two halves of one movement. That half comes in already measured, as
/// [cursorMoving] — the same animation the mark itself slides on.
///
/// It was a length of its own here first, and the mismatch was the point of
/// changing it: holding an arrow key repeats faster than the mark travels, so
/// the row ahead had finished answering while the mark was still crossing to
/// it, and rows behind were still giving their answer back from two moves ago.
/// The mark, the lean and the inverted text now say the same thing at the same
/// rate, because there is one thing being said.
///
/// *What* is animated is [AppearanceSettings.liveFileListMotion] — a distance
/// in pixels or a multiplier on the row's size — and the two answers are
/// combined by taking the louder, so a row under the mouse *and* the cursor is
/// the cursor's.
///
/// Built only when the setting is on. Nothing here is left running behind a
/// zero: with the setting off the row is not wrapped at all, which is what
/// makes "off" mean off rather than "the same machinery, at no distance".
class LivelyRow extends StatefulWidget {
  const LivelyRow({
    super.key,
    required this.theme,
    required this.isCursor,
    required this.cursorMoving,
    required this.builder,
  });

  final AppearanceSettings theme;
  final bool isCursor;

  /// How far this row is into being the cursor, or null when the cursor is
  /// not moving. See [CursorSlide].
  final Animation<double>? cursorMoving;

  /// The row itself, drawn at the lean and the scale it has reached. One of the
  /// two is always at rest — 0 for a lean, 1 for a scale.
  final Widget Function(double lean, double scale) builder;

  @override
  State<LivelyRow> createState() => _LivelyRowState();
}

class _LivelyRowState extends State<LivelyRow> with SingleTickerProviderStateMixin {
  /// The mouse's answer, and the only thing this row animates itself: 0 away
  /// from the pointer, 1 under it.
  late final AnimationController _hover = AnimationController(vsync: this);

  /// Arriving on the way in, leaving on the way back — the curves as well as
  /// the lengths, so the wake looks like a wake at both ends.
  late final CurvedAnimation _hovering = CurvedAnimation(
    parent: _hover,
    curve: kArrivingCurve,
    reverseCurve: kLeavingCurve,
  );

  bool _over = false;

  @override
  void dispose() {
    _hovering.dispose();
    _hover.dispose();
    super.dispose();
  }

  /// How far this row is into being the cursor.
  ///
  /// 0 or 1 outright where the mark does not animate: the cursor is a cut then,
  /// and a row easing into place behind a cut describes a movement that did not
  /// happen.
  double get _cursor =>
      widget.cursorMoving?.value ?? (widget.isCursor ? 1 : 0);

  /// The louder of the two answers, each at its own size.
  double _amount(double byMouse, byKeyboard) =>
      math.max(_hovering.value * byMouse, _cursor * byKeyboard);

  void _hoverTo(bool over) {
    if (_over == over) return;
    _over = over;
    // Read on the gesture rather than kept: the speed setting can change while
    // a listing is on screen, and a controller built once keeps the length it
    // was born with.
    _hover.duration = widget.theme.animated(kRowLeanInDuration);
    _hover.reverseDuration = widget.theme.animated(kRowLeanOutDuration);
    // From wherever it has got to. A pointer crossing back over a row it has
    // just left must not start the lean again from nothing.
    if (over) {
      _hover.forward();
    } else {
      _hover.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    // How far the answer carries on this machine. One number, applied to the
    // distance and never to the length: the speed setting stays the only thing
    // that decides how long any of this takes.
    final reach = liveRowReach(Theme.of(context).platform);

    return MouseRegion(
      onEnter: (_) => _hoverTo(true),
      onExit: (_) => _hoverTo(false),
      child: AnimatedBuilder(
        animation: Listenable.merge([_hover, widget.cursorMoving]),
        builder: (context, _) => switch (widget.theme.liveFileListMotion) {
          LiveListMotion.slide => widget.builder(
              _amount(kRowHoverLean, kRowCursorLean) * reach,
              1,
            ),
          // The multipliers are given as what they add, so that no answer and
          // an answer of nothing are the same number — and so that the reach
          // multiplies the answer rather than the row's own size.
          LiveListMotion.scale => widget.builder(
              0,
              1 + _amount(kRowHoverScale - 1, kRowCursorScale - 1) * reach,
            ),
        },
      ),
    );
  }
}

