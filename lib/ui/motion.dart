import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../core/settings/appearance_settings.dart';
// Imported as well as re-exported: an export puts the names in every caller's
// scope, not in this file's, and `liveRowReach` below reads one of them.
import '../core/settings/motion.dart';
import '../core/settings/settings_store.dart';

export '../core/settings/motion.dart';

/// Reaching the motion constants from a widget.
///
/// The numbers themselves are in `lib/core/settings/motion.dart`, which holds
/// every animation number in the application and nothing else — one constant
/// per animated thing, so tuning how the application moves is a file of numbers
/// with nothing to read around them. It is re-exported from here, so a widget
/// needs one import either way.

/// [fullMs] — one of those constants — scaled to the speed the user has set.
///
/// Falls back to the default speed when there is no [SettingsStore] above the
/// context. That is not defensive habit: a menu or a remark can be raised from
/// a harness that provides no store, and neither is worth a crash on the way to
/// deciding how long a fade should be.
///
/// [listen] registers a dependency, so the widget rebuilds when the speed
/// changes. Off by default — most callers read the length inside a build they
/// are already doing for another reason.
Duration motionOf(BuildContext context, int fullMs, {bool listen = false}) {
  return _appearanceOf(context, listen: listen).animated(fullMs);
}

/// Whether anything animates at all, for the places that skip the machinery
/// rather than run it at zero length.
bool motionOn(BuildContext context, {bool listen = false}) =>
    _appearanceOf(context, listen: listen).animates;

/// One thing giving way to another in the same place, on a single timeline.
///
/// [t] runs 0 to 1 across the whole exchange and this is how strongly to draw
/// whatever is in the place: 1 at both ends, 0 at the midpoint — where the
/// change itself is made, with nothing on screen to see it made. Eased on each
/// half, so it leaves and arrives softly rather than with a corner in it.
///
/// One function because it is one idea, and two copies of it would be two
/// exchanges that no longer look alike: the panel ring changing sides and the
/// listing changing folders are both this.
double fadeThrough(double t) =>
    kBothCurve.transform(t < 0.5 ? 1 - t * 2 : t * 2 - 1);

/// How far a live row travels, as a multiplier on the distances in
/// `motion.dart` — [kRowHoverLean] and the three beside it.
///
/// One everywhere but macOS, where the same movement reads as a smaller one.
/// See [kLiveRowReachOnMac] for why it is the platform and not the pixel ratio
/// that decides.
///
/// Takes the platform rather than a context so that a test can ask for either
/// one without a widget tree, and so that this file needs no Material import
/// for a single lookup. Callers pass `Theme.of(context).platform`, which is
/// what makes it settable in a test.
double liveRowReach(TargetPlatform platform) =>
    platform == TargetPlatform.macOS ? kLiveRowReachOnMac : 1;

AppearanceSettings _appearanceOf(BuildContext context, {required bool listen}) {
  try {
    return listen
        ? context.watch<SettingsStore>().appearance
        : context.read<SettingsStore>().appearance;
  } on ProviderNotFoundException {
    return const AppearanceSettings();
  }
}
