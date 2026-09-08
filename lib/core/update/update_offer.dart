/// When to ask, and when to keep quiet.
///
/// An update is offered, never taken: the person can install it, be asked
/// again tomorrow, or stay on what they have. This is the whole of that
/// decision, kept pure and away from the widget, because "did we already ask
/// about this one" is exactly the kind of rule that goes wrong quietly.
library;

import 'release_check.dart';

/// What is remembered between one offer and the next.
class UpdatePrompt {
  const UpdatePrompt({
    this.staying,
    this.postponed,
    this.remindAfter,
    this.lastChecked,
  });

  /// A version the person said they would stay on. Only that one and anything
  /// older is silenced — saying "not this one" is not saying "never again".
  final String? staying;

  /// The version *remind me later* was said about, and nothing else is
  /// silenced by it.
  ///
  /// **Anything newer than this is a different question.** Postponing 448 in
  /// the morning used to keep 449 quiet for a day as well, and 449 may be the
  /// build carrying the fix that made it worth publishing — every archive is
  /// put in the release folder by hand, one at a time, so a version arriving
  /// after an answer was given is news that answer never covered. Null in a
  /// prompt written by an older version, where the reminder silenced
  /// everything; [worthOffering] keeps that meaning rather than guessing.
  final String? postponed;

  /// Nothing about [postponed] is offered before this. Set by *remind me
  /// later*.
  final DateTime? remindAfter;

  /// When the release folder was last read, so a start does not read it again.
  final DateTime? lastChecked;

  /// How often the application looks by itself.
  ///
  /// **It used to be once a day, at a start, and that was the wrong shape for
  /// how releases are published now.** A file manager is opened in the morning
  /// and left open until the machine sleeps, so a start was the one moment it
  /// looked — and a build put out at noon reached nobody until they happened to
  /// restart. Every archive in the release folder is published by hand, one at
  /// a time, which means a build reaching people at all is already the decision
  /// that it should reach them; waiting a day to mention it is this side
  /// deciding otherwise.
  ///
  /// Four hours, and not less, because a check is a request to somebody else's
  /// server and the thing being waited for is a person uploading a file — a
  /// minute's precision buys nothing and costs a request every minute.
  static const Duration checkEvery = Duration(hours: 4);

  /// How long *remind me tomorrow* lasts. A day, because that is what the
  /// button says. It silences [postponed] and nothing newer.
  static const Duration postponeFor = Duration(days: 1);

  UpdatePrompt copyWith({
    String? staying,
    String? postponed,
    DateTime? remindAfter,
    DateTime? lastChecked,
    bool clearStaying = false,
    bool clearRemindAfter = false,
  }) =>
      UpdatePrompt(
        staying: clearStaying ? null : (staying ?? this.staying),
        // The postponed version and the moment it is postponed until are one
        // answer, so they are cleared together and never separately.
        postponed: clearRemindAfter ? null : (postponed ?? this.postponed),
        remindAfter:
            clearRemindAfter ? null : (remindAfter ?? this.remindAfter),
        lastChecked: lastChecked ?? this.lastChecked,
      );

  /// Whether it is time to look at the release folder at all.
  bool dueForCheck(DateTime now) {
    final last = lastChecked;
    if (last == null) return true;
    // A clock moved backwards — by a timezone, by hand — must not silence the
    // check until it catches up again.
    if (now.isBefore(last)) return true;
    return now.difference(last) >= checkEvery;
  }

  /// Whether what was found is worth putting in front of somebody.
  bool worthOffering(ReleaseVersion found, DateTime now) {
    final stayingOn = staying == null ? null : ReleaseVersion.tryParse(staying!);
    if (stayingOn != null && !(found > stayingOn)) return false;

    final later = remindAfter;
    if (later == null || !now.isBefore(later)) return true;

    // Inside the quiet period. It covers the version that was postponed and
    // everything older, and nothing else — see [postponed]. A prompt written
    // before that field existed has no version to compare, and there the old
    // meaning stands: quiet until the reminder is due.
    final deferred =
        postponed == null ? null : ReleaseVersion.tryParse(postponed!);
    if (deferred == null) return false;
    return found > deferred;
  }

  /// What is remembered after each of the three answers.
  ///
  /// *Remind me tomorrow* is an answer about **one version**, so [on] is kept
  /// with the moment: whatever is published after it is a question that has not
  /// been asked yet.
  UpdatePrompt afterLater(DateTime now, ReleaseVersion on) => copyWith(
        postponed: '$on',
        remindAfter: now.add(postponeFor),
        clearStaying: true,
      );

  UpdatePrompt afterStaying(ReleaseVersion on) =>
      copyWith(staying: '$on', clearRemindAfter: true);

  /// An update that was taken clears both: the version installed is no longer
  /// one to be silent about, and there is nothing left to remind anyone of.
  UpdatePrompt afterInstalling() =>
      copyWith(clearStaying: true, clearRemindAfter: true);
}
