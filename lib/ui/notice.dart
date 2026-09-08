import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../core/i18n/i18n.dart';
import 'motion.dart';
import 'widgets/hint.dart';

/// A short remark along the bottom of the window — no association for this
/// file, no viewer for that one, an operation that partly failed.
///
/// Its own overlay entry rather than a `SnackBar`, because the one thing a
/// remark has to do is go away, and a `SnackBar` would not.
/// `ScaffoldMessenger` creates the dismissal timer inside its own `build`, and
/// only if the entrance animation happens to have completed by then; miss that
/// and the bar sits there for the rest of the session. This owns the timer, so
/// there is nothing to miss.
///
/// It goes into the **root** overlay, so a remark is visible over the settings
/// or a viewer as well as over the panels, and it **replaces** whatever is
/// already showing instead of queueing behind it: these are remarks about what
/// just happened, and pressing Enter on four unassociated files should say so
/// once rather than four times over the next twenty seconds.
/// How long a remark stays up once it has arrived.
///
/// **Provisional, and deliberately so.** These were 3 and 6 seconds and were
/// reported as too long; halved is a correction, not a decision. What a remark
/// *is* — where it may appear, what raises it, how long it lives and which of
/// those are settings — is item 45 on the backlog and is a conversation, not a
/// number. When that lands, this is the one place it changes.
///
/// Not run through `animated()` like the lengths in `motion.dart`: the speed
/// setting decides how things *move*, and at Off it would leave a remark on
/// screen for no time at all, which is not what "no animation" means.
const Duration kNoticeLife = Duration(milliseconds: 1800);

/// The same for the ones that are reporting a failure worth reading twice.
const Duration kNoticeLongLife = Duration(milliseconds: 3600);

/// How much of the bottom of the window is not the panels: the console when it
/// is open, the command line, the function keys.
///
/// A remark floats **above** that, never over it. It used to be nailed to the
/// bottom of the window and knew nothing about the console, so `cd` to a folder
/// that is not there put the answer on top of the very pane the answer was
/// about. Quick search floats over its own panel and not over the thing it
/// belongs to ([[quick-search-one-box]] in the notes); this is the same rule.
///
/// Published rather than worked out here. The heights are a fixed 26 for the
/// command line, a scaled 30 or 52 for the function keys depending on how wide
/// the window is, and whatever the console has been dragged to — three numbers
/// that live in three widgets, and a copy of them here is a copy that drifts.
final ValueNotifier<double> noticeBottomInset = ValueNotifier(0);

/// Measures [child] and publishes its height as [noticeBottomInset].
///
/// Wrapped around the strip at the bottom of the commander screen. Measured
/// rather than declared for the reason above, and after the frame rather than
/// during it, because a height is not known until the thing has been laid out.
class NoticeBottomInset extends StatefulWidget {
  const NoticeBottomInset({super.key, required this.child});

  final Widget child;

  @override
  State<NoticeBottomInset> createState() => _NoticeBottomInsetState();
}

class _NoticeBottomInsetState extends State<NoticeBottomInset> {
  final GlobalKey _key = GlobalKey();

  @override
  void dispose() {
    // The panels are gone, so nothing is in the way any more. Left set, a
    // remark raised from somewhere else would float on a ledge that is not
    // there.
    noticeBottomInset.value = 0;
    super.dispose();
  }

  void _measure(Duration _) {
    if (!mounted) return;
    final height = (_key.currentContext?.findRenderObject() as RenderBox?)
        ?.size
        .height;
    if (height != null && height != noticeBottomInset.value) {
      noticeBottomInset.value = height;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Every build, because the console changing height is a rebuild of this
    // subtree and not a remount of it.
    WidgetsBinding.instance.addPostFrameCallback(_measure);
    return KeyedSubtree(key: _key, child: widget.child);
  }
}

void showNotice(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  bool long = false,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _Notice.replace(
    overlay,
    message: message,
    actionLabel: actionLabel,
    onAction: onAction,
    duration: long ? kNoticeLongLife : kNoticeLife,
  );
}

/// Sends the current remark away early, if there is one. It fades out.
void hideNotice() => _Notice.dismiss();

/// The one remark on screen, the timer that ends it, and the way out.
class _Notice {
  static OverlayEntry? _entry;
  static Timer? _timer;

  /// Set to true to ask the bar on screen to leave. The bar takes its own
  /// entry away once it has finished fading, which is why this is a signal
  /// rather than a removal: only the bar knows when it has gone.
  static ValueNotifier<bool>? _leaving;

  static void replace(
    OverlayState overlay, {
    required String message,
    required String? actionLabel,
    required VoidCallback? onAction,
    required Duration duration,
  }) {
    // At once, not faded: two remarks in the same place at the same time is
    // one unreadable remark, and a replacement is a correction.
    _removeNow();

    final leaving = ValueNotifier(false);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _NoticeBar(
        message: message,
        actionLabel: actionLabel,
        leaving: leaving,
        onGone: () {
          if (identical(_entry, entry)) _removeNow();
        },
        onAction: onAction == null
            ? null
            : () {
                _removeNow();
                onAction();
              },
      ),
    );
    _entry = entry;
    _leaving = leaving;
    overlay.insert(entry);

    _timer = Timer(duration, dismiss);
  }

  static void dismiss() {
    _timer?.cancel();
    _timer = null;
    _leaving?.value = true;
  }

  static void _removeNow() {
    _timer?.cancel();
    _timer = null;
    // The entry first: removing it unmounts the bar, which is what takes the
    // bar's listener off the notifier before it is thrown away.
    _entry?.remove();
    _entry = null;
    _leaving?.dispose();
    _leaving = null;
  }
}

class _NoticeBar extends StatefulWidget {
  const _NoticeBar({
    required this.message,
    required this.actionLabel,
    required this.onAction,
    required this.leaving,
    required this.onGone,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Turns true when the remark's time is up. See [_Notice._leaving].
  final ValueListenable<bool> leaving;

  /// Called once it has faded, so the entry can be taken out of the overlay.
  final VoidCallback onGone;

  @override
  State<_NoticeBar> createState() => _NoticeBarState();
}

class _NoticeBarState extends State<_NoticeBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: kNoticeAnimationDuration),
  );

  bool _started = false;

  @override
  void initState() {
    super.initState();
    widget.leaving.addListener(_leave);
  }

  /// Started here rather than at construction, because the length comes from
  /// the settings and those need a context. Once: a remark arrives, it does not
  /// re-arrive when something above it rebuilds.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _in.duration = motionOf(context, kNoticeAnimationDuration);
    // The way out is the way in, reversed. It was not there at all before:
    // the remark was removed from the overlay outright, so it arrived by
    // fading and left by vanishing.
    _in.reverseDuration = _in.duration;
    _in.forward();
  }

  void _leave() {
    if (!widget.leaving.value || !mounted) return;
    // With motion off the length is zero and this is still correct: the
    // controller reverses in no time and the entry goes on the next tick.
    _in.reverse().whenCompleteOrCancel(() {
      if (mounted) widget.onGone();
    });
  }

  @override
  void dispose() {
    widget.leaving.removeListener(_leave);
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ValueListenableBuilder<double>(
      valueListenable: noticeBottomInset,
      builder: (context, inset, child) => Positioned(
        left: 16,
        right: 16,
        // Clear of the console, the command line and the function keys — a
        // remark about the console that lands on the console is an answer
        // covering the question.
        bottom: 16 + inset,
        child: child!,
      ),
      // Only the bar itself takes the pointer. A remark must never stand
      // between the user and the panel underneath it.
      child: IgnorePointer(
        ignoring: false,
        child: Align(
          alignment: Alignment.bottomLeft,
          child: FadeTransition(
            opacity: _in,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0, 0.4),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(parent: _in, curve: kArrivingCurve),
                  ),
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(6),
                color: scheme.inverseSurface,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      14,
                      10,
                      widget.actionLabel == null ? 14 : 6,
                      10,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            widget.message,
                            style: TextStyle(color: scheme.onInverseSurface),
                          ),
                        ),
                        if (widget.actionLabel != null) ...[
                          const SizedBox(width: 12),
                          TextButton(
                            onPressed: widget.onAction,
                            child: Text(widget.actionLabel!),
                          ),
                        ],
                        // Somewhere to put it out of the way early, for the
                        // six-second ones that are covering something.
                        Hint(
                          message: tr('Dismiss'),
                          child: IconButton(
                            iconSize: 16,
                            visualDensity: VisualDensity.compact,
                            color: scheme.onInverseSurface,
                            icon: const Icon(Icons.close),
                            onPressed: hideNotice,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
