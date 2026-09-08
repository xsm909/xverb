import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../vfs/vfs_path.dart';

/// Where the panels have been, and how long you stayed.
///
/// A list of the ten folders most worth going back to, ranked by the time
/// spent in them rather than by the number of times they were entered.
///
/// **Counting entries measures the walk, not the work.** Getting to one folder
/// four levels down enters four folders, and three of them were passed through
/// without being looked at — yet they scored exactly what the destination did.
/// Time tells them apart: a folder walked through is worth the second it took,
/// and a folder worked in is worth the afternoon.
///
/// **And a folder has to be stood in for a minute to be in the list at all** —
/// [minimumStay]. Ranking by time already put the passages at the bottom; this
/// keeps them off it, which is the difference between a list of ten and a list
/// of ten with three passages in it.
///
/// **One list, of ten.** It was two for a day — the folders you spend your time
/// in, and a chronological *where was I just now* underneath — and the second
/// one is gone. Once the top is ranked by time rather than by arrivals it
/// already holds everywhere worth going back to, and a second list of the same
/// folders in a different order is a second list to read.
///
/// The chronological order is still **kept**, because it settles a tie and it
/// is not worth writing anything else to settle one. It is simply not offered.
///
/// **Both panels count, not just the one with the cursor in it.** A folder held
/// open in one panel while the work darts in and out of the other is a folder
/// being used, and counting only the active one took its clock away at every
/// crossing — which is most of what copying from one panel to the other is. A
/// folder open in *both* is counted once: the same minute cannot be spent
/// twice.
///
/// **In memory while the application runs, written once on the way out.**
/// Walking a tree is thousands of navigations, and a counter that touched the
/// disk on each one would put a write between every folder and the next. The
/// cost is that a crash loses the session — but it does mean [save] has to
/// actually be called on every way out.
class FolderHistory extends ChangeNotifier {
  FolderHistory._(this._file, this._spent, this._recent, this._pinned);

  /// The behaviour without a disk behind it.
  ///
  /// For tests, and for the moment before [load] has finished — an application
  /// that had no history until a file had been read would have a window with a
  /// null in it for the first frame.
  FolderHistory.inMemory({
    Map<String, int> spent = const {},
    List<String> recent = const [],
    List<String> pinned = const [],
  })  : _file = null,
        _spent = {...spent},
        _recent = [...recent],
        _pinned = [...pinned];

  final File? _file;

  /// How long has been spent in each folder, in milliseconds. Keyed by
  /// [VfsPath.toString], which round-trips through [VfsPath.parse] exactly.
  final Map<String, int> _spent;

  /// Most recent first, and **not shown anywhere**. Two jobs: it settles a tie
  /// in [favourites], and it says which folders to keep when the table is
  /// trimmed. The About card offered it for a day and he took that out — one
  /// list in the application, and it is [favourites].
  final List<String> _recent;

  /// Folders somebody has pinned, in the order they are to be shown.
  ///
  /// **A list built out of what you did needs a way to say what you meant.**
  /// Time is a good guess and a guess is all it is; a pin is somebody saying
  /// outright.
  ///
  /// They come first and they do not leave. Their **order is theirs** — the
  /// order they were pinned in — rather than by time, because a pinned row that
  /// moved would be a pinned row you have to look for.
  final List<String> _pinned;

  /// A folder on screen right now, and what it has put by.
  ///
  /// One entry per *distinct* folder rather than one per panel, so a folder
  /// open in both panels is one clock — the same minute cannot be spent twice.
  final Map<String, _Stay> _showing = {};

  /// Folders that were forgotten while a panel was still standing in them.
  ///
  /// **A row taken out must not walk back in.** Forgetting stops that folder's
  /// clock, and without this the next panel notification — a cursor moving a
  /// row — would start a fresh one and the folder would be back a minute later,
  /// which is not what the cross said it would do. A folder is let go the
  /// moment it leaves the screen: coming back to it is a new visit, and a new
  /// visit is allowed to count.
  final Set<String> _forgotten = {};

  /// Whether the application is the one being used.
  ///
  /// **Time behind another window is not time spent in a folder.** Without
  /// this, leaving the application open on a Friday afternoon would hand
  /// whatever folder was on screen the whole weekend, and the top of the list
  /// would be decided by where somebody stopped rather than by where they work.
  /// It is the platform's own signal rather than an idle timer of our own
  /// invention — a timer would need a length, and any length is a guess.
  ///
  /// **And it fails open, because the signal is not to be trusted.** Measured
  /// on macOS 2026-09-06 with the application logging every lifecycle event it
  /// was given: one run reported nothing at all, and the next reported
  /// `inactive` when the window lost focus and **never reported `resumed`**. On
  /// that evidence a gate that only opens on a resume is a gate that shuts once
  /// and stays shut — the history stopped counting the first time the window
  /// lost focus, which is the fault this was found through.
  ///
  /// So [enters] opens it as well: **somebody navigating is somebody who is
  /// there**, and that is a fact rather than a report about one. The window
  /// signals are still listened to, and are what stops the weekend; this is
  /// what stops a lost signal stopping everything.
  bool _inFront = true;

  /// Nothing has changed since it was last written.
  bool _dirty = false;

  /// How many of each are offered.
  static const int shown = 10;

  /// How many folders are remembered at all.
  ///
  /// **A cap rather than a decay.** Time that never fades makes the top ten a
  /// monument to last year, and the honest answers to that — halving everything
  /// monthly, weighting by recency — are policies he has not asked for and
  /// would notice. A cap keeps the file from growing without inventing one:
  /// past this, the folders with the least time go first, and a folder somebody
  /// passed through once is exactly the one nobody wants in the list.
  static const int remembered = 200;

  /// The most recent list is shorter, because "where was I" has a horizon.
  static const int recentKept = 40;

  /// How long a folder has to be stood in before it is in the history at all.
  ///
  /// Ranking by time already put a folder walked
  /// through at the bottom of the list; this keeps it off the list altogether,
  /// which is the difference between a short list of ten and a short list of
  /// ten with three passages in it.
  ///
  /// **It is a door, not a tax.** The minute is what a folder has to do *once*
  /// to get into the history. After that every
  /// spell in it counts, however short: somebody who works in a folder in
  /// thirty-second bursts is working in it.
  static const Duration minimumStay = Duration(minutes: 1);

  /// What the clock is asked for. Injectable so a test can say what time it is
  /// rather than sleeping.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  static Future<File> _where() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'folder-history.json'));
  }

  /// Reads what was written last time. A file that will not parse is a file
  /// that starts again rather than one that takes the application down.
  ///
  /// **A file written before 1.0.0.420 holds visit counts**, under `visits`,
  /// and they are not read. A count of five and five milliseconds are not the
  /// same measurement and there is no honest way to turn one into the other —
  /// the times start again, and the chronological list, which means the same
  /// thing under both, carries over.
  static Future<FolderHistory> load() async {
    try {
      final file = await _where();
      if (!await file.exists()) return FolderHistory._(file, {}, [], []);

      // **A file that will not read must not take the writing with it.**
      // Measured on his machine 2026-09-06: `folder-history.json` was **nought
      // bytes**, written by a save that a `pkill` cut in half — and from then
      // on every run threw in here, landed in the outer catch, and came back
      // with no file to write to. The history had been dead for two hours and
      // looked like a bug in the counting.
      Map<String, dynamic>? decoded;
      try {
        final read = jsonDecode(await file.readAsString());
        if (read is Map<String, dynamic>) decoded = read;
      } on Object {
        // Empty, half-written, or edited into nonsense. Start again — but start
        // again *with the file*, so tonight's history has somewhere to go.
      }
      if (decoded == null) return FolderHistory._(file, {}, [], []);
      final spent = <String, int>{};
      final ms = decoded['spentMs'];
      if (ms is Map<String, dynamic>) {
        for (final entry in ms.entries) {
          final value = entry.value;
          if (value is int && value > 0) spent[entry.key] = value;
        }
      }
      final recent = <String>[
        for (final entry in (decoded['recent'] as List? ?? const []))
          if (entry is String) entry,
      ];
      final pinned = <String>[
        for (final entry in (decoded['pinned'] as List? ?? const []))
          if (entry is String) entry,
      ];
      return FolderHistory._(file, spent, recent, pinned);
    } on Object {
      // No support directory at all — a test, or a machine that will not give
      // us one. Nothing to read and nowhere to write.
      return FolderHistory._(null, {}, [], []);
    }
  }

  /// The panels are showing these folders, and nothing else.
  ///
  /// Anything null is a panel with nowhere to count — a search result listing
  /// is a question somebody asked rather than a place to go back to, and a row
  /// that cannot be opened is a row that lies.
  ///
  /// Safe to call on every change a panel has, which is what the application
  /// does: the folders that were already showing keep their clocks untouched.
  void showing(Iterable<VfsPath?> places) {
    final keys = <String>{
      for (final place in places)
        if (place != null) place.toString(),
    };

    // **Evidence beats a report.** Nobody works a window they are not looking
    // at, so this is proof the application is in front — and proof is worth
    // more than a lifecycle event that may never arrive. See [_inFront].
    if (keys.isNotEmpty) _inFront = true;

    var changed = false;

    // Gone from the screen: what it earned is banked, and what it did not is
    // dropped. A stay is one visit to one folder.
    for (final key in _showing.keys.toList()) {
      if (keys.contains(key)) continue;
      _settle(key, leaving: true);
      _showing.remove(key);
    }
    // Leaving one that was forgotten is what lets it be counted again.
    _forgotten.removeWhere((key) => !keys.contains(key));

    for (final key in keys) {
      if (_forgotten.contains(key)) continue;
      final stay = _showing[key];
      if (stay != null) {
        // Already counting, or paused by a signal that was never taken back.
        stay.since ??= _inFront ? now() : null;
        continue;
      }
      _showing[key] = _Stay(since: _inFront ? now() : null);
      _recent
        ..remove(key)
        ..insert(0, key);
      if (_recent.length > recentKept) {
        _recent.removeRange(recentKept, _recent.length);
      }
      _dirty = true;
      changed = true;
    }

    if (changed) notifyListeners();
  }

  /// Whether the application is the one in front. See [_inFront].
  void inFront(bool yes) {
    if (yes == _inFront) return;
    _inFront = yes;
    if (yes) {
      for (final stay in _showing.values) {
        stay.since ??= now();
      }
    } else {
      _pause();
    }
  }

  /// Stops every clock where it stands, keeping what it has.
  ///
  /// **The folders are still open.** Going behind another window is not leaving
  /// them, so nothing is dropped and nothing is ended — the time so far goes
  /// into the stay's own pile and the clock starts again on the way back.
  void _pause() {
    for (final key in _showing.keys.toList()) {
      _settle(key, leaving: false);
    }
  }

  /// Folds what the clock has run up into the stay, and banks the stay if it
  /// has earned its place.
  ///
  /// [leaving] says whether the folder is going off the screen, in which case
  /// what it has not earned is lost — half a minute here and half a minute
  /// there is not a minute anywhere.
  void _settle(String key, {required bool leaving}) {
    final stay = _showing[key];
    if (stay == null) return;

    final since = stay.since;
    stay.since = null;
    if (since != null) {
      final ms = now().difference(since).inMilliseconds;
      // A clock that went backwards — the machine woke up, or somebody changed
      // the time. Nothing to bank, and nothing worth reporting either.
      if (ms > 0) stay.pending += ms;
    }

    if (_counts(key, stay.pending)) {
      _spent[key] = (_spent[key] ?? 0) + stay.pending;
      stay.pending = 0;
      _forget();
      _dirty = true;
    } else if (leaving) {
      stay.pending = 0;
    }
  }

  /// Whether a stay of [ms] in [key] goes into the history.
  ///
  /// Long enough on its own, or a folder that is already in there — see
  /// [minimumStay] for why those are the two.
  bool _counts(String key, int ms) =>
      ms >= minimumStay.inMilliseconds || _spent.containsKey(key);

  /// Drops the folders with the least time once there are more than  /// Drops the folders with the least time once there are more than
  /// [remembered] of them.
  ///
  /// Whatever is in the recent list is kept whatever its time. It is not on
  /// screen any more, but it is what a tie is settled by, and a folder somebody
  /// walked out of a minute ago is the likeliest one to be walked back into.
  void _forget() {
    if (_spent.length <= remembered) return;
    final keep = _recent.toSet();
    final byTime = _spent.keys.toList()
      ..sort((a, b) => (_spent[b] ?? 0).compareTo(_spent[a] ?? 0));
    for (final key in byTime.skip(remembered)) {
      if (!keep.contains(key)) _spent.remove(key);
    }
  }

  /// Whether [path] has been pinned.
  bool isPinned(VfsPath path) => _pinned.contains(path.toString());

  /// Pins [path], or takes the pin out of it.
  ///
  /// **Pinning is also remembering.** A folder can be pinned before it has
  /// earned a minute — that is half of what pinning is for — so it goes into
  /// the recent list too, or the list would hold a pin pointing at nothing.
  ///
  /// Written out straight away, for the reason [clear] is: somebody who pins a
  /// folder and then loses power has not pinned it.
  Future<void> pin(VfsPath path, {required bool pinned}) async {
    final key = path.toString();
    if (pinned == _pinned.contains(key)) return;

    if (pinned) {
      if (_pinned.length >= shown) return;
      _pinned.add(key);
      if (!_recent.contains(key)) _recent.insert(0, key);
    } else {
      _pinned.remove(key);
    }
    _dirty = true;
    notifyListeners();
    await save();
  }

  /// Moves a pinned folder [by] places up or down among the pinned ones.
  ///
  /// **Only the pinned ones have an order to change.** The rest are ranked by
  /// time, and a hand-placed row among them would be a row that jumps the next
  /// time somebody works somewhere.
  ///
  /// Clamped rather than refused: a row dragged past the end lands at the end,
  /// which is what dragging past the end means everywhere else.
  Future<void> movePin(VfsPath path, {required int by}) async {
    final key = path.toString();
    final from = _pinned.indexOf(key);
    if (from < 0 || by == 0) return;

    final to = (from + by).clamp(0, _pinned.length - 1);
    if (to == from) return;

    _pinned
      ..removeAt(from)
      ..insert(to, key);
    _dirty = true;
    notifyListeners();
    await save();
  }

  /// Whether another folder can be pinned at all.
  ///
  /// **Ten is the whole list**, so ten pins is a list with nothing else in it —
  /// which is allowed and is the point: somebody who has named ten folders has
  /// said what the list is for. Past that the pin is simply not offered, rather
  /// than offered and refused.
  bool get canPin => _pinned.length < shown;

  /// The folders you spend your time in, most first.
  ///
  /// The clock still running is counted, so a folder does not have to be left
  /// before the time in it appears — somebody who opens this menu after an hour
  /// in one folder should see that hour.
  ///
  /// Ties go to whichever was seen more recently, so two folders with the same
  /// total are not in whatever order a hash table happened to hold them — a
  /// list that reshuffles itself between openings is a list you cannot learn.
  ///
  /// **The pinned ones first, in their own order**, and then as many of the
  /// rest as there is room for. Ten in all: pin ten and there is no room left
  /// for a folder that merely earned its place, which is the plainest reading
  /// of a list of ten.
  List<VfsPath> get favourites {
    final totals = _totals();
    // [pin] refuses a folder that is already pinned, so this holds each once.
    final earned = totals.keys.where((key) => !_pinned.contains(key)).toList()
      ..sort((a, b) {
        final byTime = (totals[b] ?? 0).compareTo(totals[a] ?? 0);
        if (byTime != 0) return byTime;
        return _recency(a).compareTo(_recency(b));
      });
    return _paths([..._pinned, ...earned].take(shown));
  }


  /// How long has been spent in [path], the clock still running included.
  Duration timeIn(VfsPath path) =>
      Duration(milliseconds: _totals()[path.toString()] ?? 0);

  bool get isEmpty => _spent.isEmpty && _recent.isEmpty && _pinned.isEmpty;

  /// What is banked, plus whatever the clocks are holding.
  ///
  /// A folder appears in the list at the moment it earns its place, which is
  /// the same moment it would have earned it by being left — and what the stay
  /// has already put by counts towards that. See [_Stay].
  Map<String, int> _totals() {
    if (_showing.isEmpty) return _spent;

    final totals = {..._spent};
    for (final entry in _showing.entries) {
      final stay = entry.value;
      final since = stay.since;
      final running =
          since == null ? 0 : now().difference(since).inMilliseconds;
      final held = stay.pending + (running > 0 ? running : 0);
      if (held <= 0 || !_counts(entry.key, held)) continue;
      totals[entry.key] = (totals[entry.key] ?? 0) + held;
    }
    return totals;
  }

  /// Forgets one folder.
  ///
  /// A list built out of what somebody did is a list that will
  /// sooner or later hold something they would rather it did not, and the only
  /// answers to that are a way to take one row out or a way to throw the lot
  /// away. Both, now.
  ///
  /// Written out straight away, for the reason [clear] is: somebody who takes a
  /// folder out of a list and then loses power has not taken it out.
  Future<void> forget(VfsPath path) async {
    final key = path.toString();
    final had = _spent.remove(key) != null;
    final listed = _recent.remove(key);
    // Forgetting a folder unpins it: a pin on a row that is not there is a pin
    // that would put the row back.
    final wasPinned = _pinned.remove(key);
    if (!had && !listed && !wasPinned) return;

    // The clock cannot be left running on a folder that is no longer counted:
    // it would put it straight back the moment anything else happened. And it
    // is not started again either while the panel stands there — see
    // [_forgotten].
    if (_showing.remove(key) != null) _forgotten.add(key);

    _dirty = true;
    notifyListeners();
    await save();
  }

  /// Forgets everything.
  ///
  /// **The times as well as the list**, because that is the whole of clearing:
  /// a cleared history that still ranked by where you used to work would not be
  /// cleared. Written out straight away rather than waiting for the way
  /// out — somebody who clears a history and then loses power has not cleared
  /// it.
  Future<void> clear() async {
    _spent.clear();
    _recent.clear();
    // The pins go with it. A cleared history that came back with five rows in
    // it is not a cleared history.
    _pinned.clear();
    // But what is on screen starts counting again from now: clearing is
    // forgetting the past, not refusing to look at the present.
    _forgotten.clear();
    // The clocks start again where they are: clearing is forgetting the past,
    // not leaving the folders standing open.
    for (final stay in _showing.values) {
      stay.pending = 0;
      stay.since = _inFront ? now() : null;
    }
    _dirty = true;
    notifyListeners();
    await save();
  }

  /// Writes it down, if there is anything to write.
  ///
  /// **The running clock is banked first.** This is called on the way out, and
  /// the folder somebody has been in all afternoon is the one whose time would
  /// otherwise be the only one lost.
  ///
  /// Failure is swallowed on purpose: this runs while the application is
  /// closing, and a folder history is not worth holding up a shutdown or
  /// showing somebody an error about.
  Future<void> save() async {
    // Everything the clocks are holding is banked first — the folder somebody
    // has been in all afternoon is the one whose time would otherwise be the
    // only one lost.
    _pause();
    // And they go on running from now, so saving twice does not count the same
    // minute twice and does not stop counting either.
    if (_inFront) {
      for (final stay in _showing.values) {
        stay.since = now();
      }
    }

    if (!_dirty) return;
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      // **Written beside it and moved into place**, because `writeAsString`
      // empties the file before it fills it — and something that dies in
      // between leaves nought bytes, which is what happened here. A rename is
      // one step on every system this runs on: the file is either the old one
      // or the new one and never a half of either.
      final draft = File('${file.path}.writing');
      await draft.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'spentMs': _spent,
          'recent': _recent,
          'pinned': _pinned,
        }),
        flush: true,
      );
      await draft.rename(file.path);
      _dirty = false;
    } on Object {
      // Nothing to be done about it at this point in the life of the process.
    }
  }

  /// Position in the recent list, or one past the end for a folder not in it.
  int _recency(String key) {
    final at = _recent.indexOf(key);
    return at < 0 ? _recent.length : at;
  }

  /// Keys back into paths, skipping any that will no longer parse — a file
  /// edited by hand, or a scheme belonging to a plugin since removed.
  List<VfsPath> _paths(Iterable<String> keys) {
    final paths = <VfsPath>[];
    for (final key in keys) {
      try {
        paths.add(VfsPath.parse(key));
      } on Object {
        continue;
      }
    }
    return paths;
  }
}

/// A folder that is on screen, and what its visit has put by.
///
/// [since] is null while the clock is stopped — the application is behind
/// another window, or the time has just been folded in. [pending] is what this
/// visit has run up without yet reaching [FolderHistory.minimumStay]: kept
/// rather than lost, because the minute belongs to the stay and not to one
/// uninterrupted stretch of it.
class _Stay {
  _Stay({this.since});

  DateTime? since;
  int pending = 0;
}
