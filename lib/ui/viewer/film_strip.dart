import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/plugins/plugin_manifest.dart';
import '../../core/plugins/viewer.dart';
import '../../core/settings/appearance_settings.dart';
import '../../core/settings/settings_store.dart';
import '../../core/vfs/file_entry.dart';
import '../motion.dart';
import 'thumbnails.dart';

/// The files in [listing] that a viewer declaring [spec] can open, in the
/// order the listing had them.
///
/// **`handles` rather than `claims`, and the difference is the whole rule.** A
/// viewer that claims extensions gives back its own kind, so the picture canvas
/// walks pictures and a text file among them is not in the way; a viewer
/// declared as a fallback handles everything, so a hex dump walks the whole
/// folder — which is exactly what a hex dump is for.
///
/// **Except what another viewer names as its own.** [others] is every viewer
/// there is, and a file one of them names is not the fallback's business: a
/// `.png` in a folder of source was offered in the text viewer's strip and
/// opened as a wall of bytes. Handing it over to the picture viewer instead
/// was the first answer and it was worse — the strip then became a strip of
/// pictures, and stepping from the strip into one of them left no way back to
/// the documents. So the strip walks what
/// the viewer reading it is *for*, and what nobody names stays with the
/// fallback, which is what a fallback is.
///
/// Directories and the way back up are never neighbours: they are not files
/// anything opens, and a strip with a folder in it would offer somewhere the
/// arrow cannot go.
///
/// **And what another viewer of the same kind names is a neighbour too.** That
/// was the limit this used to end on: a folder of `.jpg` beside `.heic` was two
/// strips, because the machine's own decoder reads one and a Python reader the
/// other, and a strip that stopped at the first `.heic` told the reader the
/// folder ended there. The answer was in the contract rather than in this
/// file — [ViewerSpec.produces], a word for what a viewer gives back — and with
/// it the rule reads as it always should have: **a strip walks the kind of
/// thing being looked at, not the plugin that happens to open it.**
///
/// A viewer that says nothing about what it produces is its own kind and keeps
/// exactly the strip it had.
List<FileEntry> neighboursFor(
  List<FileEntry> listing,
  ViewerSpec spec, {
  List<ViewerSpec> others = const [],
}) => [
  for (final entry in listing)
    if (!entry.isDirectory &&
        !entry.isParentLink &&
        (spec.handles(entry.extension, name: entry.name) ||
            _sameKindClaims(spec, others, entry)) &&
        !others.any((other) => givesWayTo(spec, other, entry)))
      entry,
];

/// Whether a viewer of the same kind names this file — see
/// [ViewerSpec.produces].
bool _sameKindClaims(
  ViewerSpec spec,
  List<ViewerSpec> others,
  FileEntry entry,
) => others.any(
  (other) =>
      opensTheSameKind(spec, other) &&
      other.claims(entry.extension, name: entry.name),
);

/// How far from square a thumbnail may be before it is cropped to get there.
///
/// **The square is the whole of the row of houses, and getting it wrong is
/// invisible.** The first cut allowed a landscape half again as wide as it was
/// tall before it had to lose any height — and an ordinary photograph is 4:3
/// or 3:2, which fits inside that, so every one of them came out at full
/// height and the strip was as flat as it had been. Only a picture wider than
/// 3:2 differed. The test missed it because the picture in it was exactly 2:1.
///
/// Beyond this a picture would be a sliver nobody can see anything in, and
/// cropping is the right answer.
const double kFurthestFromSquare = 3.0;

/// The shape one cell takes: its picture fitted inside a square of [room], or
/// the whole square while nothing is known about the picture yet.
///
/// Takes the picture's *size* rather than the picture: this is measuring, and
/// nothing that measures should be holding a `ui.Image` — see
/// [ThumbnailCache.take].
///
/// **A cell is the picture's own shape, standing on the floor of the strip.**
/// Two requirements, and they are one rule. First, that a portrait be seen to
/// be a portrait and a landscape a landscape without anybody having to look
/// twice. Then, that the difference be carried by the *height*, with
/// everything aligned along the bottom. So the picture is fitted inside a
/// square and
/// stood on the floor of it: a portrait fills the height and is narrow, a
/// landscape fills the width and is short, and along a strip they stand at
/// different heights on one line.
///
/// **It lives out here because two people need the same answer.** The cell is
/// drawn at it and the strip lays the row out with it — a row placed by one
/// rule and drawn by another is wrong by exactly the difference.
Size cellShape(Size? picture, double room) {
  if (picture == null || picture.height == 0) return Size(room, room);
  final proportion = (picture.width / picture.height)
      .clamp(1 / kFurthestFromSquare, kFurthestFromSquare);
  return proportion > 1
      ? Size(room, room / proportion)
      : Size(room * proportion, room);
}

/// How the strip lays the folder out once it is folded.
///
/// **Two, because the two things it can be are worth different prices.** The
/// ribbon is the honest one — nothing ever jumps — and it costs the reading
/// order: every other line runs back the way it came, which takes a moment to
/// follow. Lines all read the same way is what
/// anybody expects of a wall of pictures, and it costs a picture leaving one
/// end of a line to reappear at the other end of the line above.
///
/// Neither is wrong, so it is a setting.
enum StripFold {
  /// The folder gathered into **ranks**: as many pictures one above another as
  /// the setting allows, the next few in the rank beside them, and the whole
  /// thing walked left to right the way the row it came from was.
  ranks,

  /// Folded like a ribbon: the folder runs along a line and carries on along
  /// the line below, turning round at each fold, so every other line runs back
  /// the way it came and nothing ever crosses the strip.
  ribbon;

  /// The name as the settings hold it, answering with the default for anything
  /// it does not know — including nothing at all.
  static StripFold named(String? name) => StripFold.values.firstWhere(
    (fold) => fold.name == name,
    orElse: () => StripFold.ranks,
  );

  /// What the settings page calls it.
  String get label => switch (this) {
    StripFold.ranks => 'In ranks',
    StripFold.ribbon => 'Folded',
  };
}

/// The row of neighbours along the bottom of a full-screen viewer.
///
/// **It exists so that a key press is not a hidden mode.** Left and Right could
/// have walked the folder with nothing on screen to show it, and then the same
/// arrow would mean "move the picture" or "open the next file" depending on a
/// state nobody can see. With the strip up, the highlight is the answer: the
/// arrows obviously move *that*, because it is the thing that moves.
///
/// **It is thumbnails and nothing else.** No band, no fill, no rule along the
/// top: it stands *on* the picture, which runs the whole height of the window
/// and passes underneath it. Thumbnails and a shadow, never a panel of its
/// own: a bar would take height away from the thing being looked at in order
/// to say nothing. What
/// holds a thumbnail apart from whatever is behind it is a shadow, the way a
/// photograph on a table is held apart from the table.
///
/// **Under the pointer it folds into a grid** of up to [rows] rows and unfolds
/// again when the pointer leaves. Nothing is exchanged for
/// anything: the same cells travel to new places, because a list that is
/// swapped for a different list has said that these are different pictures.
/// The grid is built from the floor up, so a folder that only makes two rows
/// makes them at the bottom and leaves the picture above it alone.
///
/// **A cell that has no thumbnail says the file's name**, and that is not a
/// placeholder — it is what a strip of text files, or of pictures in a format
/// the machine's decoder will not read, honestly looks like. Only that cell
/// has a surface, because a word needs something to be written on. See
/// [ThumbnailCache] for which formats those are and why it is the machine's
/// answer rather than ours.
class FilmStrip extends StatefulWidget {
  const FilmStrip({
    super.key,
    required this.entries,
    required this.current,
    required this.thumbnails,
    required this.theme,
    required this.onPick,
    this.active = true,
    this.rows = SettingsStore.defaultStripRows,
    this.fold = StripFold.ranks,
  });

  /// The neighbours, in the order the panel had them.
  final List<FileEntry> entries;

  /// Which of them is being looked at.
  final int current;

  final ThumbnailCache thumbnails;

  /// The settings' own colours, handed down rather than read here.
  ///
  /// The strip stands *inside* the reading surface but is not part of the
  /// reading: it is chrome, and it takes the header's fill and the header's
  /// ink like the size line under it. Asking [appearanceOf] from in here would
  /// hand back the page's colours, which is the opposite of what it wants.
  final AppearanceSettings theme;

  final void Function(int index) onPick;

  /// Whether it is on screen. A strip that has been put away is still in the
  /// tree so that it can slide back, and must not go on reading a folder of
  /// photographs while nobody is looking at it.
  final bool active;

  /// How many rows the pointer unfolds it into. The setting's own number,
  /// handed down: see [SettingsStore.filmStripRows], which is also where the
  /// two ends of it are written down.
  final int rows;

  /// Which of the two arrangements it folds into, from the settings.
  final StripFold fold;

  /// How tall one row is, given the interface size.
  ///
  /// Tied to the font rather than fixed, like every other row in the
  /// application: somebody who set the interface large did so to see it.
  static double heightFor(AppearanceSettings theme) =>
      (theme.fontSize * 5.6).clamp(76.0, 148.0);

  @override
  State<FilmStrip> createState() => _FilmStripState();
}

/// Where one cell goes, measured from the strip's own floor.
///
/// **Up from the floor rather than down from the top**, because the strip is
/// pinned to the bottom of the window and *changes height* — it grows upward
/// as it folds. Anything measured from the top would be measured from an edge
/// that is itself moving, and the bottom row would drift while it was supposed
/// to be standing still.
@immutable
class _Spot {
  const _Spot(this.left, this.bottom, this.width, this.height);

  final double left;
  final double bottom;
  final double width;
  final double height;

  bool within(double from, double to, double floor, double ceiling) =>
      left < to &&
      left + width > from &&
      bottom < ceiling &&
      bottom + height > floor;
}

/// Both arrangements of the same cells, worked out from the pictures that have
/// arrived so far.
///
/// **One object rather than two functions**, because the two arrangements
/// share every number they are built from — the cells' own shapes, the room
/// there is, the gap between them — and a grid built from a different reading
/// of those than the row was is a grid the cells cannot travel to.
@immutable
class _Plan {
  const _Plan({
    required this.row,
    required this.grid,
    required this.rowWidth,
    required this.rowBox,
    required this.gridBox,
    required this.viewport,
    required this.pitch,
    required this.lineLength,
    required this.thread,
    required this.columns,
    required this.lines,
    required this.maxAcross,
    required this.ribbon,
  });

  /// Where each cell stands in one row, and in the grid.
  ///
  /// **The row's places are the folder's own and the grid's are the strip's.**
  /// A cell's place along the row does not depend on how far the row has been
  /// scrolled; its place in the grid does, because moving the thread puts
  /// every cell on a different line. So one of these two has the scrolling in
  /// it already and the other has it subtracted where it is read.
  final List<_Spot> row;
  final List<_Spot> grid;

  /// How wide the row is, edge padding included.
  final double rowWidth;

  /// How tall the strip is in each arrangement.
  final double rowBox;
  final double gridBox;

  final double viewport;

  /// One slot of the grid: a cell's square and the gap after it.
  final double pitch;

  /// How much of the thread one line holds, and how long the whole thread is.
  final double lineLength;
  final double thread;

  final int columns;

  /// How many lines the grid came out as. One means the folder is already all
  /// on screen and there is nothing for the fold to do.
  final int lines;

  /// Which line the file being looked at is put on when the strip folds: the
  /// **first**, so that the whole of the fold is what comes next. The middle
  /// was the first answer — what came before above, what comes next below —
  /// and it is the wrong one: from the file you are on, the useful half of a
  /// folder is the half you have not seen. What came before is still there,
  /// off the near end of the first line, one push away.
  int get openingLine => 0;

  /// Whether this is the folded ribbon or the wall of lines — which decides
  /// what listing it means, and therefore what [maxAcross] counts.
  final bool ribbon;

  /// How far it can be listed: along the ribbon in pictures, or down the wall
  /// in rows.
  final double maxAcross;

  double get maxAlong => math.max(0.0, rowWidth - viewport);

  /// One step of listing: a whole line either way — a line's worth of ribbon,
  /// or one row of the wall.
  double get listStep => ribbon ? lineLength : pitch;
}

class _FilmStripState extends State<FilmStrip> with TickerProviderStateMixin {
  /// 0 is one row, 1 is the grid. Everything the fold changes — where a cell
  /// stands, how tall the strip is, which of the two scroll offsets is in use
  /// — is read off this one number.
  late final AnimationController _fold = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: kFilmStripFoldDuration),
  );
  late final Animation<double> _unfolded = CurvedAnimation(
    parent: _fold,
    curve: kBothCurve,
  );

  /// The strip's own scrolling, one number per arrangement.
  ///
  /// **Two rather than one, and neither is a `ScrollController`.** Both run
  /// sideways, but a row and a grid of the same folder are different lengths —
  /// the grid is as many times shorter as it has rows — so one number could
  /// not mean the same place in both. Holding them ourselves also means the
  /// cells can be *placed* rather than laid out, which is what lets a cell fly
  /// from its place in the row to its place in the grid.
  double _along = 0;
  double _across = 0;

  /// Where the cells are going. It flips the moment the pointer arrives or
  /// leaves; [_fold] is how far along they are.
  bool _grid = false;

  /// The last arrangement worked out, for the pointer and the arrows to read.
  /// They run between frames, when there is no layout to ask.
  _Plan? _plan;

  /// Frames, for as long as any cell is still growing into its own shape.
  ///
  /// **A clock rather than an animation**, because the thing being animated is
  /// not one movement but forty little ones that begin at forty different
  /// moments. See [_blend].
  late final Ticker _clock = createTicker((_) {
    if (!mounted) return;
    // **The file being looked at holds the middle while the rest settles.**
    // Pictures land in handfuls and every one of them changes the shape of its
    // cell and the place of every cell after it, so a strip left alone walks
    // out from under the very file it was opened on. Held to the middle each
    // frame of the settling, the pictures arrange themselves *around* it.
    if (_wandered) {
      setState(() {});
      return;
    }
    final plan = _plan;
    if (_travel.isAnimating && plan != null) {
      // **A walk in progress is not interrupted, it is re-aimed.** The strip
      // travelling to the file just walked to, and the pictures still landing
      // under it, are two claims on the same number — and the first cut let
      // the second win every frame, which stopped the travel dead and put the
      // new file in the middle in one jump. He saw it as the strip sometimes
      // scrolling and sometimes shifting: it scrolled once the folder had
      // finished arriving, and jumped while it was still coming in.
      final wants = _wantedOf(plan);
      _alongTo = wants.along;
      _acrossTo = wants.across;
      setState(() {});
      return;
    }
    _place(now: true, both: true);
  });

  /// When each picture landed, by the file it belongs to. What it is *for* is
  /// in [_blend]; what it costs is one entry per file, dropped when the strip
  /// is.
  final Map<String, Duration> _landed = {};

  /// Whether anything has been drawn yet. Everything the cache already holds
  /// on the very first frame has *not* just arrived — it was there before the
  /// strip was — and opening a folder for the second time should not be forty
  /// pictures growing out of forty squares.
  bool _drawn = false;

  /// Which cell the pointer is on, if any. **Kept up here so it can be drawn
  /// last**: a cell that grows under the pointer would otherwise be overlapped
  /// by the one after it, which is the one thing a picture picked up off a
  /// table never is.
  int? _lit;

  /// Whether the reader has pushed the strip somewhere of their own.
  ///
  /// The middle belongs to the current file until somebody goes looking for
  /// another one, and then it belongs to them: a strip that dragged itself
  /// back every time a thumbnail arrived would be unusable for the one thing a
  /// grid is for, which is looking away from where you are.
  bool _wandered = false;

  /// The row travelling to the file that has just been walked to.
  late final AnimationController _travel = AnimationController(vsync: this)
    ..addListener(_onTravel);
  double _alongFrom = 0;
  double _alongTo = 0;
  double _acrossFrom = 0;
  double _acrossTo = 0;

  static const double _padding = 8;
  static const double _gap = 8;

  /// The room a cell needs beyond its own edges to be picked up in.
  ///
  /// **Measured from the two numbers that decide it**, rather than guessed at:
  /// a cell under the pointer is drawn [kThumbnailHoverScale] bigger and
  /// leaning by up to [kThumbnailHoverTilt], and a rectangle turned through an
  /// angle reaches further than its own half-diagonal in both directions. Eight
  /// pixels of edge padding was less than that, so the picture being reached
  /// for was the one the strip's own edge clipped.
  static double _liftFor(double side) {
    final grown = side * kThumbnailHoverScale;
    final leaning = kThumbnailHoverTilt * math.pi / 180;
    final reach = (grown * math.cos(leaning) + grown * math.sin(leaning)) / 2;
    return math.max(0.0, reach - side / 2);
  }

  int get _rows => widget.rows.clamp(
    SettingsStore.fewestStripRows,
    SettingsStore.mostStripRows,
  );

  @override
  void initState() {
    super.initState();
    // After the first layout, not during it: there is no viewport to measure
    // against until the strip has been given its width.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _place(now: true, both: true, centre: true);
    });
  }

  @override
  void didUpdateWidget(FilmStrip old) {
    super.didUpdateWidget(old);
    // A strip that has been put away must not be found as a grid when it
    // slides back: the pointer is not over it any more and will never say so,
    // because a strip nobody can point at gets no leaving event.
    if (!widget.active && _grid) {
      _grid = false;
      _fold.reverse();
    }
    if (old.current == widget.current) return;
    // A new file is a new middle, and whatever the reader had gone looking at
    // is answered: they walked to this one.
    _wandered = false;
    // **At once, not at the end of the frame.** Where the cells stand is
    // arithmetic now and has nothing to do with which of them is current, so
    // there is nothing to wait for — and waiting cost the movement itself: a
    // picture landing in the same frame reached the middle first, so by the
    // time the walk was set going there was nowhere left to walk to.
    _place();
  }

  @override
  void dispose() {
    _fold.dispose();
    _travel.dispose();
    _clock.dispose();
    super.dispose();
  }

  void _onTravel() {
    final t = kBothCurve.transform(_travel.value);
    setState(() {
      _along = ui.lerpDouble(_alongFrom, _alongTo, t)!;
      _across = ui.lerpDouble(_acrossFrom, _acrossTo, t)!;
    });
  }

  /// Brings the current cell into view, in the middle where there is a
  /// neighbour on either side of it to walk to.
  ///
  /// **Only the offset that is on screen**, unless [both] says otherwise. The
  /// other arrangement is not being drawn, so its offset can be moved to
  /// wherever it will be needed with nobody able to see it move — which is
  /// exactly what the fold does with it, and why folding needs no second
  /// animation to keep the current file in sight.
  /// Where the strip wants to stand: near enough that the file being looked at
  /// is on screen, and — when [centre] — with it in the middle.
  ///
  /// **Following, not chasing.** Walking the folder used to drag the whole
  /// strip a cell sideways at every step so that the current file stayed in
  /// the middle: the highlight stood still and the pictures moved, which is
  /// the wrong way round for something you are walking *along*. Now the
  /// highlight moves along the row and the row only gives way when the
  /// highlight would run off the end of it.
  ///
  /// The middle is still what an *arrangement* answers with: opening the strip
  /// and folding it are not steps along the folder but a new thing to look at,
  /// and there is no reason for the file it is about to show to be at the edge
  /// of it.
  ({double along, double across}) _wantedOf(_Plan plan, {bool centre = false}) {
    final index = widget.current.clamp(0, plan.row.length - 1);

    // **The row follows, it does not lead.** Walking the folder used to drag
    // the whole strip a cell sideways at every step so that the current file
    // stayed in the middle: the highlight stood still and the pictures moved,
    // which is the wrong way round for something you are walking *along*. The
    // highlight moves along the row, and the row gives way only when the
    // highlight would run off the end of it. The middle is still what an
    // *arrangement* answers with: opening the strip is not a step along the
    // folder.
    final spot = plan.row[index];
    final room = plan.rowBox;
    final double along;
    if (centre) {
      along = (spot.left + spot.width / 2 - plan.viewport / 2).clamp(
        0.0,
        plan.maxAlong,
      );
    } else {
      final showRight = spot.left + spot.width + room - plan.viewport;
      final showLeft = spot.left - room;
      final lowest = math.min(showRight, showLeft);
      final highest = math.max(showRight, showLeft);
      along = _along.clamp(lowest, highest).clamp(0.0, plan.maxAlong);
    }

    // **Opening the grid shows the file at the top; walking in it moves
    // nothing.** What came before is above the first line and what comes next
    // is the whole of the fold below it, and after that the grid is a thing
    // you walk about in rather than one that follows the highlight. So a step
    // leaves it exactly where it is, and the
    // highlight walks the lines until it would leave them altogether; only
    // then does the grid move, and by a **whole line**, which is how a wrapped
    // page follows a cursor.
    final line = plan.lineLength;
    final double across;
    if (plan.ribbon) {
      // Along the ribbon: the middle of the first line when it opens, and
      // afterwards a whole line at a time, only when the file walked to would
      // otherwise leave the lines altogether.
      if (centre) {
        across = (index * plan.pitch - (line - plan.pitch) / 2).clamp(
          0.0,
          plan.maxAcross,
        );
      } else {
        final at = index * plan.pitch - _across;
        final window = plan.lines * line;
        final adrift = at < 0
            ? (at / line).floor()
            : (at + plan.pitch > window
                  ? ((at + plan.pitch - window) / line).ceil()
                  : 0);
        across = (_across + adrift * line).clamp(0.0, plan.maxAcross);
      }
    } else {
      // Along the ranks: the rank it stands in, brought to the middle when the
      // grid opens and left alone afterwards — the ranks give way only when
      // the file walked to would stand off the end of the strip, which is the
      // rule the row keeps.
      final at = (index ~/ plan.lines) * plan.pitch;
      if (centre) {
        across = (at + plan.pitch / 2 - plan.viewport / 2).clamp(
          0.0,
          plan.maxAcross,
        );
      } else {
        final room = plan.rowBox;
        final showRight = at + plan.pitch + room - plan.viewport;
        final showLeft = at - room;
        final lowest = math.min(showRight, showLeft);
        final highest = math.max(showRight, showLeft);
        across = _across.clamp(lowest, highest).clamp(0.0, plan.maxAcross);
      }
    }

    // **Snapped to whole slots.** A cell whose place falls in a fold hangs
    // between two lines, which is what a ribbon does while it is being pulled
    // — and not what an arrangement should settle into. The wheel is left
    // free; this is only where the strip puts *itself*.
    final settled = plan.pitch <= 0
        ? across
        : (across / plan.pitch).round() * plan.pitch;
    return (along: along, across: settled.clamp(0.0, plan.maxAcross));
  }

  /// A rebuild, unless one is already under way.
  ///
  /// [_place] is called from three different moments — a pointer, a frame of
  /// the clock, and `didUpdateWidget`, which is itself a build. Asking for a
  /// rebuild from inside that last one is an error and, worse, an unnecessary
  /// one: the build it would ask for is the build it is already in.
  void _ping() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      return;
    }
    setState(() {});
  }

  void _place({bool now = false, bool both = false, bool centre = false}) {
    final plan = _plan;
    if (plan == null || plan.row.isEmpty) return;
    final wants = _wantedOf(plan, centre: centre);
    final along = both || !_grid ? wants.along : _along;
    final across = both || _grid ? wants.across : _across;
    if (_wandered && !centre && _grid) {
      // Gone looking somewhere else in the grid: the middle is theirs until
      // they walk to another file, which is what clears it.
      return;
    }

    final duration = motionOf(context, kFilmStripDuration);
    if (now || duration == Duration.zero) {
      _travel.stop();
      _along = along;
      _across = across;
      _ping();
      return;
    }
    // Already where it wants to be — which, now that walking only *follows*,
    // is most steps along a folder. Starting an animation that has nowhere to
    // go would stop the one that has.
    if (along == _along && across == _across) return;
    _alongFrom = _along;
    _alongTo = along;
    _acrossFrom = _across;
    _acrossTo = across;
    _travel
      ..duration = duration
      ..forward(from: 0);
  }

  /// The pointer arriving over the strip, or leaving it.
  void _pointer({required bool over}) {
    if (!mounted || _grid == over) return;
    // Nothing to gain, so nothing happens: a folder already showing all of
    // itself in one row folds into that same one row, and a strip that
    // rearranged itself to say nothing would only be in the way.
    if (over && (!widget.active || (_plan?.lines ?? 1) <= 1)) return;
    setState(() => _grid = over);
    _wandered = false;
    // The offset of the arrangement being *entered*, set at once. The one
    // being left is what is on screen this frame and must not jump.
    _place(now: true, centre: true);
    if (over) {
      _fold.forward();
    } else {
      _fold.reverse();
    }
  }

  /// A push through the folder, however it was made.
  ///
  /// **One number, and it is the folder it moves through, not an axis.** The
  /// strip runs sideways when it is a row and downward when it is a grid, and
  /// the same two fingers have to mean "further on" in both — so the stronger
  /// of the two directions is taken and applied to whichever way the strip is
  /// laid out. A wheel over a row of pictures that only answered a sideways
  /// push, or a grid that only answered a downward one, would be a control
  /// that moves for some hands and not others.
  ///
  /// [scroll] is in the wheel's own terms: positive is on toward the end of
  /// the folder, which is what a scroll event carries and the opposite of what
  /// a hand on a trackpad reports.
  void _push(Offset scroll) {
    final plan = _plan;
    if (plan == null) return;
    final push = scroll.dy.abs() >= scroll.dx.abs() ? scroll.dy : scroll.dx;
    if (push == 0) return;
    _wandered = true;

    // **Both arrangements are walked the same way, sideways**, because both
    // of them run that way: the ribbon along its thread and the ranks along
    // their ranks, and a listing reads left to right.
    _travel.stop();
    setState(() {
      if (_grid) {
        _across = (_across + push).clamp(0.0, plan.maxAcross);
      } else {
        _along = (_along + push).clamp(0.0, plan.maxAlong);
      }
    });
  }

  /// Both arrangements, from the pictures that have arrived.
  ///
  /// Answered from the cache rather than from the cells, because the cells
  /// that are off screen do not exist to be asked. A picture nobody has
  /// decoded yet counts as a square, which is the widest a cell can be: the
  /// row therefore only ever *narrows* as the pictures arrive, and never jumps
  /// outward under the pointer.
  _Plan _makePlan(List<Size> shapes, double viewport, double side) {
    final count = shapes.length;
    final lift = _liftFor(side);
    final edge = _padding + lift;
    final band = side + edge * 2;
    final pitch = side + _gap;

    // The row. **A short row stands in the middle of the window, not against
    // the left edge**: three photographs pushed into the corner read as a list
    // that has been scrolled, and the eye goes looking for the rest of it.
    var wide = edge * 2 + _gap * math.max(0, count - 1);
    for (final shape in shapes) {
      wide += shape.width;
    }
    final row = <_Spot>[];
    var x = edge + math.max(0.0, (viewport - wide) / 2);
    for (final shape in shapes) {
      row.add(_Spot(x, edge, shape.width, shape.height));
      x += shape.width + _gap;
    }

    // The grid. **Uniform slots, and the picture keeps its own shape inside
    // one.** Nothing is resized by the fold: a cell is the same size in both
    // arrangements and only its place changes, which is what makes the fold
    // read as a rearrangement rather than as a redraw.
    //
    // **Two arrangements, and they differ in what a line *is*.** See
    // [StripFold]: a wall of lines, which is a folder wrapped like text and
    // turned over a row at a time; or a ribbon, which is the strip itself
    // folded, pulled along and never jumping.
    //
    // **As few lines as will show the whole folder, and never more than the
    // setting.** A folder that fits in two lines is drawn in two, at the
    // bottom, and one that already fits
    // in a single line has nothing to gain from folding at all, which is why
    // [lines] can come back as one and the pointer then leaves the strip
    // alone.
    final columns = math.max(
      1,
      ((viewport - edge * 2 + _gap) / pitch).floor(),
    );
    final along = columns * pitch;
    final thread = count * pitch;
    final ribbon = widget.fold == StripFold.ribbon;

    // How many rows it comes to. **The fewest that will show the whole folder,
    // and never more than the setting** — a folder that fits in two rows is
    // drawn in two at the bottom, and one that already fits in a single row
    // has nothing to gain from folding
    // at all, which is why this can come back as one and the pointer then
    // leaves the strip alone.
    var lines = _rows;
    for (var tried = 1; tried <= _rows; tried++) {
      final fits = ribbon
          ? thread <= tried * along
          : (count / tried).ceil() * pitch - _gap + edge * 2 <= viewport;
      if (fits) {
        lines = tried;
        break;
      }
    }

    // How far it has been listed, and how far it *can* be: along the ribbon in
    // pictures, or along the ranks in ranks.
    final ranks = count == 0 ? 1 : (count / lines).ceil();
    final most = ribbon
        ? math.max(0.0, thread - lines * along)
        : math.max(0.0, ranks * pitch - _gap + edge * 2 - viewport);
    final across = _across.clamp(0.0, most);

    final grid = <_Spot>[];
    for (var index = 0; index < count; index++) {
      final double left;
      final double bottom;
      if (ribbon) {
        final at = index * pitch - across;
        // Whole lines, and the floor is the last of them: the strip is pinned
        // to the bottom of the window and grows upward, so the line the folder
        // carries on to is the one nearer the floor.
        final line = (at / along).floor();
        final into = at - line * along;
        // **The fold is part of the ribbon, not a cut in it.** A line holds
        // its cells across [travel]; the slot's worth of thread after that is
        // the fold itself, and a cell in it does not move along at all — it
        // slides *down* to the line below, at the very place it reached. So a
        // picture crosses the strip, rounds the fold, and comes back the other
        // way, and the only two places anything appears or disappears are the
        // open ends, where it goes out under the edge.
        final travel = along - pitch;
        final reached = math.min(into, travel);
        final turning = math.max(0.0, into - travel) / pitch;
        left = edge + (line.isOdd ? travel - reached : reached);
        bottom = edge + (lines - 1 - line - turning) * pitch;
      } else {
        // **Ranks, and the folder still runs left to right.** Three files
        // stand one above another — the earlier above, the later below, as it
        // has been from the start — the next three stand in the rank beside
        // them, and listing walks the ranks sideways exactly as
        // the row was walked. Nothing wraps, so nothing can appear at one edge
        // having left the other: a picture leaves under the side it reached.
        left = edge + (index ~/ lines) * pitch - across;
        bottom = edge + (lines - 1 - index % lines) * pitch;
      }
      grid.add(
        _Spot(
          left + (side - shapes[index].width) / 2,
          bottom,
          shapes[index].width,
          shapes[index].height,
        ),
      );
    }

    return _Plan(
      row: row,
      grid: grid,
      rowWidth: wide,
      rowBox: band,
      gridBox: lines * pitch - _gap + edge * 2,
      viewport: viewport,
      pitch: pitch,
      lineLength: along,
      thread: thread,
      columns: columns,
      lines: lines,
      maxAcross: most,
      ribbon: ribbon,
    );
  }

  /// A picture has arrived, so the cells are a different shape than they were.
  ///
  /// **Every arrival, not only the ones while the row already fits.** A row of
  /// squares that overflows can still fit once it turns out to be a row of
  /// narrow portraits, and a strip that only re-measured while it was already
  /// centred would never find that out. It costs one rebuild per picture, and
  /// [ThumbnailCache] never has more than a handful in flight.
  void _remeasure() {
    if (!mounted) return;
    _wakes++;
    if (!_clock.isTicking) _clock.start();
    setState(() {});
  }

  /// How many pictures have landed. Only ever compared with itself — see the
  /// end of [_blend].
  int _wakes = 0;

  /// The shape to lay each cell out at: its picture's own, or the square it
  /// was before its picture landed, or somewhere between the two while it is
  /// growing from one into the other.
  ///
  /// **Each cell on its own little clock, started when its own picture
  /// arrived.** A picture arriving changes the shape of its cell, and every
  /// cell after it moves — that used to come free, because the row was a list
  /// and the cell animated its own width while the list laid itself out again
  /// each frame. Placing the cells ourselves means placing them mid-growth as
  /// well.
  ///
  /// **One animation for all of them was the first cut, and it twitched.**
  /// Pictures land four at a time, over and over, and every landing restarted
  /// the one animation — so every cell still on its way was re-aimed from
  /// wherever it had got to and set off again from the fast end of the curve.
  /// Forty small kicks, which is exactly what he saw on opening a folder and
  /// never after it. A cell that starts once and is never re-aimed cannot
  /// kick, and the row is the sum of them, which is smooth because they are.
  List<Size> _blend(double side, Duration now, Duration over) {
    final square = Size(side, side);
    final shapes = <Size>[];
    var moving = false;
    for (final entry in widget.entries) {
      final picture = widget.thumbnails.sizeOf(entry);
      if (picture == null) {
        shapes.add(square);
        continue;
      }
      final landed = _landed.putIfAbsent(
        ThumbnailCache.keyOf(entry),
        // Already there before the strip was: settled, not arriving.
        () => _drawn ? now : now - over,
      );
      final grown = over.inMicroseconds <= 0
          ? 1.0
          : ((now - landed).inMicroseconds / over.inMicroseconds).clamp(
              0.0,
              1.0,
            );
      if (grown < 1) moving = true;
      shapes.add(
        grown >= 1
            ? cellShape(picture, side)
            : Size.lerp(
                square,
                cellShape(picture, side),
                kArrivingCurve.transform(grown),
              )!,
      );
    }
    _drawn = true;
    // Nothing left growing: stop asking for frames, after this one rather
    // than in the middle of it. **Unless another picture landed meanwhile** —
    // the wake is counted, and a clock stopped on a stale count would leave
    // that picture's cell frozen half way into its shape.
    if (!moving && _clock.isTicking) {
      final wakes = _wakes;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _clock.isTicking && wakes == _wakes) _clock.stop();
      });
    }
    return shapes;
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final band = FilmStrip.heightFor(theme);
    // The cells are cut from the row's own height less its padding; the room
    // to pick one up in is added *outside* that, so that reaching for a
    // picture never makes the pictures smaller.
    final side = band - _padding * 2;
    _fold.duration = motionOf(context, kFilmStripFoldDuration);

    return LayoutBuilder(
      builder: (context, constraints) {
        final shapes = _blend(
          side,
          SchedulerBinding.instance.currentFrameTimeStamp,
          motionOf(context, kFilmStripDuration),
        );
        final plan = _plan = _makePlan(shapes, constraints.maxWidth, side);
        // The pictures arriving can leave an offset past the end of what is
        // left to scroll. Corrected where it is read rather than announced:
        // nothing on screen depends on the stale number.
        _along = _along.clamp(0.0, plan.maxAlong);
        _across = _across.clamp(0.0, plan.maxAcross);

        return MouseRegion(
          onEnter: (_) => _pointer(over: true),
          onExit: (_) => _pointer(over: false),
          child: Listener(
            // **The whole strip, not only the cells in it.** A wheel is turned
            // at a place, and half of that place is the gaps between the
            // pictures; deferring to the children would leave the strip
            // scrolling from some points and not others. It also keeps the
            // wheel from reaching the picture underneath, which would
            // otherwise magnify while the pointer was on the strip.
            behavior: HitTestBehavior.opaque,
            onPointerSignal: (signal) {
              if (signal is PointerScrollEvent) _push(signal.scrollDelta);
            },
            // **The other road the same gesture arrives by, and on this
            // machine it is the usual one.** macOS reports a trackpad's two
            // fingers as pan and pinch events wherever anything is listening
            // for them, and only falls back to scroll events where nothing
            // is — so a strip that listened for scrolls alone answered the
            // wheel and sat still under the trackpad. A hand pushes the
            // *pictures*, which is the wheel's direction reversed.
            onPointerPanZoomUpdate: (event) => _push(-event.panDelta),
            child: AnimatedBuilder(
              animation: _unfolded,
              builder: (context, _) => _arrangement(plan, theme),
            ),
          ),
        );
      },
    );
  }

  Widget _arrangement(_Plan plan, AppearanceSettings theme) {
    // **One arithmetic, one clock.** Where a cell is, and how far the strip
    // has been scrolled, are read off the same number: the cell's place in the
    // row *as it is scrolled to*, travelling to its place in the grid *as that
    // is scrolled to*. Two clocks was the first cut of this — the cells moved
    // by one animation and the strip slid under them by another — and at the
    // half way point of a folder of two hundred the two disagreed by the
    // height of the window, so the whole strip emptied for the length of the
    // fold and then reappeared arranged. Both ends were right, which is what
    // made every measurement of it pass.
    final t = _unfolded.value;
    final height = ui.lerpDouble(plan.rowBox, plan.gridBox, t)!;

    return SizedBox(
      width: plan.viewport,
      height: height,
      // A cell scrolled past the edge is gone, not drawn over the picture: the
      // strip is only as tall and as wide as it says it is.
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          // **One place clips, and it is the [ClipRect] above.** A `Stack`
          // clips to its own bounds as well, and a cell just off the edge —
          // which this builds on purpose, so that nothing arrives late into a
          // place the eye is already on — is exactly what such a clip eats.
          // The two bounds happen to coincide today; leaving both to clip
          // would mean two answers to keep agreeing.
          clipBehavior: Clip.none,
          children: [
            for (final index in _inPaintingOrder(_onScreen(plan, t, height)))
              Positioned(
                key: ValueKey(index),
                left: _leftOf(plan, index, t),
                bottom: _bottomOf(plan, index, t),
                width: plan.row[index].width,
                height: plan.row[index].height,
                // **What the fold has no room for goes out as it goes up.**
                // A ribbon folded into three layers is longer than the three
                // layers: the rest of it folds away behind them. Left at full
                // strength, those cells sail up through the top edge on their
                // way out and the last of them anybody sees is a row of bottom
                // edges and shadows leaning in over it — which he counted as a
                // fourth line, and which is also the blinking at the edges,
                // since they cross back in as the strip unfolds.
                child: Opacity(
                  opacity: _folded(plan, index) ? 1 : 1 - t,
                  child: _Cell(
                    entry: widget.entries[index],
                    thumbnails: widget.thumbnails,
                    theme: theme,
                    current: index == widget.current,
                    active: widget.active,
                    onPick: () => widget.onPick(index),
                    onSettled: _remeasure,
                    onLit: (lit) {
                      if (mounted && (lit || _lit == index)) {
                        setState(() => _lit = lit ? index : null);
                      }
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Where a cell is on screen: its place in the row, its place in the grid,
  /// and [t] of the way between them. A cell is the same size in both, so only
  /// the two corners travel.
  /// How far along the fold this cell is.
  ///
  /// **Nought for the ones the fold has no room for, however far along the
  /// rest are.** A ribbon folded into three layers is longer than the three
  /// layers, and what is beyond them has nowhere to go — so it stays where it
  /// was and fades out instead of setting off for a place off the top of the
  /// strip. Sent on its way it crossed the top edge a tenth of the way into
  /// the fold and spent the rest of it leaning its shadow in over the
  /// edge, where it stayed visible for the whole of the animation, and
  /// the same cells crossing back in on the way out were the blinking at the
  /// edges.
  double _foldOf(_Plan plan, int index, double t) =>
      _folded(plan, index) ? t : 0;

  /// Where a cell is on screen: its place along the row *as the row is
  /// scrolled*, its place in the grid — which is already where the thread has
  /// been pulled to — and [t] of the way between them.
  double _leftOf(_Plan plan, int index, double t) => ui.lerpDouble(
    plan.row[index].left - _along,
    plan.grid[index].left,
    _foldOf(plan, index, t),
  )!;

  double _bottomOf(_Plan plan, int index, double t) => ui.lerpDouble(
    plan.row[index].bottom,
    plan.grid[index].bottom,
    _foldOf(plan, index, t),
  )!;

  /// Whether this cell has a place in the folded ribbon at all.
  ///
  /// The ribbon is longer than the layers it is folded into, and what is
  /// beyond them folds away out of sight: those cells are on their way off the
  /// strip for the whole of the fold, and are drawn fading rather than sailing
  /// out through the edge.
  bool _folded(_Plan plan, int index) {
    // Ranks hold every picture there is — what is not on screen is simply off
    // the side of it, which is where it belongs and how it leaves. Only the
    // ribbon has more folder than it has lines.
    if (!plan.ribbon || plan.lineLength <= 0) return true;
    final line = ((index * plan.pitch - _across) / plan.lineLength).floor();
    return line >= 0 && line < plan.lines;
  }

  /// The same cells, with the one under the pointer last — which in a stack is
  /// on top, and is what lets it grow over its neighbours rather than under
  /// them.
  Iterable<int> _inPaintingOrder(Iterable<int> indices) {
    final lit = _lit;
    if (lit == null) return indices;
    return [
      for (final index in indices)
        if (index != lit) index,
      if (indices.contains(lit)) lit,
    ];
  }

  /// Which cells are worth building: the ones on screen, and a margin of those
  /// about to be.
  ///
  /// **Asked of where a cell actually is**, which is the whole gain of placing
  /// them by arithmetic: mid-fold a cell is neither in its row place nor in
  /// its grid one, and a strip that guessed by taking both would build the
  /// ones flying past and miss the ones flying through.
  ///
  /// **And it has to be an answer, not a list of every file.** Building all of
  /// them would ask [ThumbnailCache] for a folder's worth of pictures at once,
  /// and the cache keeps a few hundred: the ones it dropped would be disposed
  /// under the cells still holding them.
  Iterable<int> _onScreen(_Plan plan, double t, double height) sync* {
    // **Sideways there is a margin, upward there is none.** A cell just off the
    // left or right edge is about to be on it, and one that arrives late is a
    // hole in the row. Above and below there is nothing to arrive: a line of
    // the grid is whole, and the strip is pinned to the floor — so a cell
    // built up there could never be seen, *and its shadow could*. He counted
    // four lines in a strip set to three, and the fourth one was only ever its
    // shadow leaning in over the top edge.
    final margin = plan.rowBox;
    for (var index = 0; index < plan.row.length; index++) {
      final left = _leftOf(plan, index, t);
      final bottom = _bottomOf(plan, index, t);
      if (left < plan.viewport + margin &&
          left + plan.row[index].width > -margin &&
          bottom < height &&
          bottom + plan.row[index].height > 0) {
        yield index;
      }
    }
  }
}

/// One file in the strip: its picture if there is one, its name if there is
/// not, and a frame round it when it is the one being looked at.
///
/// It is given no size of its own — the strip places it, in both arrangements
/// and on the way between them.
class _Cell extends StatefulWidget {
  const _Cell({
    required this.entry,
    required this.thumbnails,
    required this.theme,
    required this.current,
    required this.active,
    required this.onPick,
    this.onSettled,
    this.onLit,
  });

  final FileEntry entry;
  final ThumbnailCache thumbnails;
  final AppearanceSettings theme;
  final bool current;
  final bool active;
  final VoidCallback onPick;

  /// Told when the picture has arrived and the cell knows its own shape, so
  /// that the strip can lay both arrangements out again.
  final VoidCallback? onSettled;

  /// Told when the pointer arrives on this cell and when it leaves, so that
  /// the strip can draw it over its neighbours while it is bigger than them.
  final ValueChanged<bool>? onLit;

  @override
  State<_Cell> createState() => _CellState();
}

class _CellState extends State<_Cell> {
  ui.Image? _image;

  /// Whether the pointer is on this one.
  bool _lit = false;

  /// The lean it takes, in turns — drawn afresh every time the pointer
  /// arrives, and kept while it goes back so that it leaves the way it came.
  /// See [kThumbnailHoverTilt].
  double _tilt = 0;
  static final math.Random _dice = math.Random();

  /// Whether the machine has been asked and has answered — either with a
  /// picture or with a refusal.
  ///
  /// **Three states, not two, and that is the whole of it.** Waiting is not
  /// the same as having nothing: a cell that writes the file's name while the
  /// picture is on its way shows a word and then replaces it, so walking into
  /// a folder is a row of names flickering into photographs. The name belongs
  /// to the third state only — asked, and there will never be a picture.
  bool _answered = false;

  /// Whether a request for this file is already out. The strip rebuilds every
  /// cell whenever a picture lands — that is how the arrangement finds its new
  /// shape — and without this, every rebuild would hang another listener on
  /// the same pending decode.
  bool _asked = false;

  /// Rounded, and by enough to be seen at the size a thumbnail is drawn.
  static const double _corner = 6;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  /// **The picture is the cell's own copy, so the cell closes it.** See
  /// [ThumbnailCache.take]: what the cache hands out stays alive until the
  /// last handle to it is disposed, and a cell that dropped its handle without
  /// disposing it would hold the pixels for as long as the application ran.
  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_Cell old) {
    super.didUpdateWidget(old);
    if (ThumbnailCache.keyOf(old.entry) != ThumbnailCache.keyOf(widget.entry)) {
      _image?.dispose();
      _image = null;
      _answered = false;
      _asked = false;
    }
    if (_image == null) _ask();
  }

  void _ask() {
    if (!widget.active || _asked) return;
    final ready = widget.thumbnails.take(widget.entry);
    if (ready != null) {
      _image = ready;
      _answered = true;
      return;
    }
    if (widget.thumbnails.refused(widget.entry)) {
      _answered = true;
      return;
    }
    // Asked for what the strip has built rather than for the whole folder:
    // the strip builds a little beyond its own edges and nothing further, so
    // what is asked for is already bounded by what is nearly visible.
    _asked = true;
    widget.thumbnails.of(widget.entry).then((image) {
      // Gone while it was being decoded: the copy it was handed is still
      // owed a close.
      if (!mounted) {
        image?.dispose();
        return;
      }
      // Told either way. A refusal is an answer, and it is the one that puts
      // the file's name in the cell.
      setState(() {
        _image = image;
        _answered = true;
      });
      widget.onSettled?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final ink = theme.headerForeground;
    final image = _image;

    // **Bigger and leaning, under the pointer.** A strip is a table of
    // photographs and this is the one being reached for — picked up a little
    // and turned, the way anybody picks a photograph up. It leans in the same
    // lengths and curves a listing row does, because it is the same
    // acknowledgement said by a different kind of thing.
    return MouseRegion(
      onEnter: (_) {
        setState(() {
          _lit = true;
          _tilt = (_dice.nextDouble() * 2 - 1) * kThumbnailHoverTilt / 360;
        });
        widget.onLit?.call(true);
      },
      onExit: (_) {
        setState(() => _lit = false);
        widget.onLit?.call(false);
      },
      child: AnimatedScale(
        scale: _lit ? kThumbnailHoverScale : 1,
        duration: motionOf(
          context,
          _lit ? kRowLeanInDuration : kRowLeanOutDuration,
        ),
        curve: _lit ? kArrivingCurve : kLeavingCurve,
        child: AnimatedRotation(
          turns: _lit ? _tilt : 0,
          duration: motionOf(
            context,
            _lit ? kRowLeanInDuration : kRowLeanOutDuration,
          ),
          curve: _lit ? kArrivingCurve : kLeavingCurve,
          child: GestureDetector(
            onTap: widget.onPick,
            child: AnimatedContainer(
        duration: motionOf(context, kFilmStripDuration),
        curve: kArrivingCurve,
        decoration: BoxDecoration(
          // **An empty frame holds the place until the picture comes.** Not a
          // filled one: a folder opening was once a row of dark tiles before
          // it was a row of photographs, and a dark tile reads as a wrong
          // picture rather than as an absent one; for a while after that a
          // waiting cell painted nothing at all, which is how a strip walked
          // sideways came to look like photographs blinking into existence at
          // its edges. A cell that has not loaded yet is a frame with a
          // shadow: the frame is there from the first frame, the picture
          // arrives inside it, and nothing appears out of nothing.
          //
          // A *surface* only where the file has no picture and never will: a
          // word needs something to be written on. A photograph does not —
          // what holds it apart from the picture behind it is the shadow.
          color: _answered && image == null
              ? theme.effectiveHeaderBackground.withValues(alpha: 0.86)
              : null,
          borderRadius: BorderRadius.circular(_corner),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF000000).withValues(alpha: 0.45),
              blurRadius: widget.current ? 10 : 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        // **It goes in front of the picture, not behind it.** A `Container`
        // paints its decoration under the child and then clips the child to
        // the *outer* rounded rectangle, so a picture drawn to fill the cell
        // covers the border's arc — the straight sides survive, because a
        // border insets the child by its width, and the corners do not.
        // Measured rather than reasoned about: white along the top edge, and
        // no white anywhere on the corner arc. A foreground decoration is
        // painted over the child, so the frame closes.
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_corner),
          // Framed, always. A photograph cut straight out of the strip has no
          // edge of its own, and over another photograph there is nothing to
          // say where one stops. The frame is the accent where the file is the
          // one being looked at and a quiet white elsewhere — quiet rather
          // than the palette's ink, because what is behind it is somebody's
          // photograph and not a surface this application chose.
          border: Border.all(
            color: widget.current
                ? theme.accentColor
                : const Color(0xFFFFFFFF).withValues(alpha: 0.55),
            width: widget.current ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        padding: image == null ? const EdgeInsets.all(3) : EdgeInsets.zero,
        child: image == null
            // Nothing at all until the machine has answered. What goes here
            // while a picture is on its way is an empty place for it, not a
            // word that will be taken away again.
            ? !_answered
                  ? const SizedBox.shrink()
                  : Center(
                      child: Text(
                        widget.entry.name,
                        maxLines: 3,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ink.withValues(alpha: 0.75),
                          fontSize: theme.fontSize - 3,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    )
            : RawImage(
                image: image,
                // The cell is already the picture's own shape, so cover and
                // contain agree and nothing is cropped — except a picture
                // further from square than [kFurthestFromSquare], and there
                // cropping is the right answer: shown whole it would be a
                // letterbox with two holes, and a hole needs a fill, which is
                // the band he did not want.
                fit: BoxFit.cover,
                // The picture is already the size it is drawn at, near enough,
                // and a thumbnail is looked at rather than examined — so this
                // is the one place in the application that *does* smooth.
                filterQuality: FilterQuality.low,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
