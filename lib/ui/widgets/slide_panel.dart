import 'package:flutter/material.dart';

import '../../core/i18n/i18n.dart';
import '../motion.dart';
import '../plugins/plugin_table.dart' show appearanceOf, legibleOn;
import 'blurred_backdrop.dart';
import 'context_menu.dart' show kMenuCornerRadius;
import 'x_button.dart';

/// A panel that slides out over the content from one side of it.
///
/// **The content is never re-laid-out.** That is the whole point, and it is why
/// this is a [Stack] rather than a split: a reading that reflows when a panel
/// opens loses the reader their place, and the panel is opened precisely so
/// they can keep it. The child is laid out at the full size of the area either
/// way; the panel is drawn on top of it.
///
/// Its surface is translucent and blurred, like the context menu and for the
/// same reason: blurring stops the text underneath being readable *as text*, so
/// there is nothing left to distract, and the panel still reads as part of the
/// window rather than a patch stuck onto it. **How solid it is, is its own
/// setting** — a menu is glanced at and dismissed, a panel is read from while
/// what is under it stays visible. The blur and the roundness are the menu's:
/// one blurred surface in the application, set in one place.
///
/// Deliberately not a dock manager. Four sides and several panels is a
/// framework, and a framework built before its second consumer is one the first
/// real task then has to be bent to fit.

/// Which edge of the content the panel comes from.
enum PanelSide { left, right }

/// The share of the content's width a panel takes when nothing has been
/// dragged. A quarter leaves the reading readable, which is the test.
const double kSlidePanelFraction = 0.25;

/// The most of it a drag can take. Past a half the panel is the page.
const double kSlidePanelMaxFraction = 0.5;

/// The least, in logical pixels, whatever the share works out to.
///
/// A narrow window makes a quarter of it useless, so the panel takes this and
/// covers more of the reading instead. While it is open, the panel is what is
/// being read.
const double kSlidePanelMinWidth = 220;

/// The gap above and below, so the panel does not touch the edges of the area.
const double kSlidePanelInset = 8;

/// How wide the edge that can be dragged is.
const double kSlidePanelGripWidth = 8;

class SlidePanel extends StatefulWidget {
  const SlidePanel({
    super.key,
    required this.open,
    required this.panel,
    required this.child,
    this.side = PanelSide.right,
    this.fraction = kSlidePanelFraction,
    this.onFractionChanged,
    this.pinned = false,
    this.onPinnedChanged,
    this.onClose,
    this.onContentPressed,
  });

  /// Whether the panel is out. Changing it animates.
  final bool open;

  /// What is drawn on the panel. Built only while the panel is on screen.
  final WidgetBuilder panel;

  /// The content the panel is drawn over.
  final Widget child;

  final PanelSide side;

  /// The share of the width the panel takes, 0..1.
  ///
  /// A share rather than a pixel width, so resizing the window keeps the
  /// proportion the user chose — which is what they chose, rather than a number
  /// of pixels that happened to be right at one window size.
  final double fraction;

  /// Whether the panel stays when the content is pressed.
  ///
  /// **The pin does not give any space back** — it decides when the panel goes
  /// away. Unpinned, it is a look at something: the next press in the content
  /// puts it back. Pinned, it stays while the content is worked in, which is
  /// the difference between "I glanced at that node" and "I am reading this
  /// panel as I go".
  final bool pinned;

  /// Null leaves the pin off the panel altogether, for a consumer that has no
  /// use for one.
  final ValueChanged<bool>? onPinnedChanged;

  /// Asked for by the close button, and by a press in the content while the
  /// panel is not pinned. One callback for both, because they are one thing:
  /// the panel should go away now.
  final VoidCallback? onClose;

  /// A press landed in the content while the panel was not pinned, at [at] in
  /// the content's own coordinates.
  ///
  /// **Answer true to keep the panel out.** The press was on another thing of
  /// the same kind as the one on show, and the panel is about to show that one
  /// instead — it moves house rather than closing.
  ///
  /// With the pin not set, moving to a node of the same kind refreshes the
  /// tab rather than closing it — otherwise a double click on one node opens
  /// it, and on another it first closes and reopens.
  /// The panel cannot answer this itself — it has no idea what a node is — so
  /// it asks, and only a press nobody claimed puts it away.
  final bool Function(Offset at)? onContentPressed;

  /// Called when a drag of the edge has settled, with the new share.
  ///
  /// At the end and not during: the caller stores this, and a store written to
  /// on every pointer move is a store written to sixty times a second. The
  /// panel follows the drag from its own state meanwhile.
  final ValueChanged<double>? onFractionChanged;

  @override
  State<SlidePanel> createState() => _SlidePanelState();
}

class _SlidePanelState extends State<SlidePanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    value: widget.open ? 1 : 0,
  );

  /// The share while a drag is in progress; null when there is no drag.
  double? _dragging;

  @override
  void didUpdateWidget(SlidePanel old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) {
      _slide.duration = motionOf(context, kSlidePanelDuration);
      if (widget.open) {
        _slide.forward();
      } else {
        _slide.reverse();
      }
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = constraints.maxWidth;
        final width = _widthWithin(area);

        return Stack(
          // **Expanded, not loose.** Every child here is positioned, and a
          // loose [Stack] with nothing but positioned children takes the
          // smallest size its constraints allow — which is nothing at all.
          // The body of a [Scaffold] is laid out loosely, so the reading
          // under this panel simply vanished, with no error to say why — a
          // page that drew its title and its status line and nothing in
          // between. Found by measuring the panel's own size, 2026-08-16.
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Listener(
                // **A press in the content puts an unpinned panel away.** Not
                // a tap: by the time a tap has been recognised the press has
                // already done something to the content, and the panel would
                // leave a beat late. Presses inside the panel never arrive
                // here — it is above this in the stack and takes its own.
                onPointerDown: (event) {
                  if (_slide.value == 0) return;
                  // Whoever owns the content gets first refusal: a press on
                  // another node of the same kind moves the panel rather than
                  // shutting it. Only a press nobody claimed puts it away.
                  //
                  // **Told to the owner even when pinned.** It used to return
                  // before asking, and the owner then never heard that the
                  // content had been pressed at all — which is how a pinned
                  // panel kept the keyboard after the reading had been gone
                  // back to. What pinning stops is the *closing*, and nothing
                  // else; see item 93.
                  final box = context.findRenderObject() as RenderBox?;
                  final at = box == null
                      ? event.localPosition
                      : box.globalToLocal(event.position);
                  final claimed = widget.onContentPressed?.call(at) ?? false;
                  if (claimed || widget.pinned) return;
                  widget.onClose?.call();
                },
                child: widget.child,
              ),
            ),
            AnimatedBuilder(
              animation: _slide,
              builder: (context, _) {
                // Closed and still: not on screen, and not built. A panel
                // nobody has opened costs nothing, including its content.
                if (_slide.value == 0) return const SizedBox.shrink();
                return _panel(context, width);
              },
            ),
          ],
        );
      },
    );
  }

  Widget _panel(BuildContext context, double width) {
    final theme = appearanceOf(context);
    final right = widget.side == PanelSide.right;
    final t = _slide.value;
    final curve = widget.open ? kArrivingCurve : kLeavingCurve;
    final eased = curve.transform(t);

    // Corners face the content: a panel on the right rounds its left edge, and
    // the edge it came from stays square against the window.
    final radius = Radius.circular(kMenuCornerRadius);
    final shape = BorderRadius.only(
      topLeft: right ? radius : Radius.zero,
      bottomLeft: right ? radius : Radius.zero,
      topRight: right ? Radius.zero : radius,
      bottomRight: right ? Radius.zero : radius,
    );

    // The surface it slides *over*, which inside a reading is the page rather
    // than the listing — [appearanceOf] has already made that substitution.
    // These open on a reading: the document's structure, a node's properties.
    // A translucent panel in the listing's colour laid over a page in another
    // was two palettes in one window.
    final fill = theme.panelBackground
        .withValues(alpha: theme.slidePanelOpacity.clamp(0.0, 1.0));
    final ink = legibleOn(fill, theme);

    return Positioned(
      top: kSlidePanelInset,
      bottom: kSlidePanelInset,
      left: right ? null : 0,
      right: right ? 0 : null,
      width: width,
      child: FractionalTranslation(
        // It travels its own width, so it comes from off the edge and returns
        // there. No scale: the movement states where it lives, nothing else.
        translation: Offset(right ? 1 - eased : eased - 1, 0),
        child: CustomPaint(
          // The hairline is drawn rather than given to the decoration, and
          // **only along the edge that faces the content**. The edge
          // against the window has nothing to be told apart from, and a line
          // there draws a box round a panel that is not a box. A `Border` of
          // its own could not do it: a border with one side missing may not
          // carry a radius, and the radius is the whole shape here.
          foregroundPainter: _PanelEdge(
            colour: ink.withValues(alpha: 0.22 * eased),
            radius: kMenuCornerRadius,
            right: right,
          ),
          child: ClipRRect(
          // The blur has to be clipped to the panel's own shape, or it shows
          // outside the corners — clip and paint are not the same thing.
          borderRadius: shape,
          child: blurredBackdrop(
            // The fade is done by the surface's own alpha and by the blur
            // growing with it, and **never** by wrapping this in an [Opacity]:
            // that saves a layer, and a [BackdropFilter] in a saved layer has
            // nothing behind it to blur. The panel would arrive unblurred and
            // nobody would know why.
            sigma: theme.menuBlur * eased,
            passes: blurPassesFor(theme, sigma: theme.menuBlur),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill.withValues(alpha: fill.a * eased),
                borderRadius: shape,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: ink),
                  child: Opacity(
                    opacity: eased,
                    // Opaque to the pointer over the whole of it: a press on an
                    // empty part of the panel must not fall through to the
                    // content, which would put the panel away — the very panel
                    // that was pressed.
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (widget.onPinnedChanged != null ||
                                    widget.onClose != null)
                                  _controls(right, ink),
                                Expanded(child: widget.panel(context)),
                              ],
                            ),
                          ),
                          _grip(right),
                        ],
                      ),
                    ),
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

  /// The pin and the way out, along the top of the panel.
  ///
  /// The panel draws them rather than each consumer drawing its own, for the
  /// reason the panel exists at all: two panels whose furniture is in different
  /// places and behaves differently are two panels, however alike they look.
  Widget _controls(bool right, Color ink) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
    child: Row(
      // Against the outer edge, away from the content the panel came over.
      mainAxisAlignment:
          right ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        if (widget.onPinnedChanged != null)
          XButton(
            icon: widget.pinned
                ? Icons.push_pin
                : Icons.push_pin_outlined,
            shape: XButtonShape.bare,
            selected: widget.pinned,
            ink: ink,
            tooltip: widget.pinned ? tr('Let it go') : tr('Keep it out'),
            onPressed: () => widget.onPinnedChanged!(!widget.pinned),
          ),
        if (widget.onClose != null)
          XButton(
            icon: Icons.close,
            shape: XButtonShape.bare,
            ink: ink,
            tooltip: tr('Close'),
            onPressed: widget.onClose,
          ),
      ],
    ),
  );

  /// The edge that can be dragged — the one facing the content.
  Widget _grip(bool right) {
    return Positioned(
      top: 0,
      bottom: 0,
      left: right ? 0 : null,
      right: right ? null : 0,
      width: kSlidePanelGripWidth,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (details) {
            final area = context.size?.width;
            if (area == null || area <= 0) return;
            // Dragging the left edge of a right-hand panel to the left widens
            // it, hence the sign.
            final by = right ? -details.delta.dx : details.delta.dx;
            setState(() {
              final from = _dragging ?? widget.fraction;
              _dragging = (from + by / area).clamp(0.0, kSlidePanelMaxFraction);
            });
          },
          onHorizontalDragEnd: (_) => _settle(),
          onHorizontalDragCancel: _settle,
        ),
      ),
    );
  }

  void _settle() {
    final settled = _dragging;
    setState(() => _dragging = null);
    if (settled != null && settled != widget.fraction) {
      widget.onFractionChanged?.call(settled);
    }
  }

  /// The panel's width in [area], honouring the minimum and the maximum.
  ///
  /// A quarter by default, dragged to no more than a half, and never below the
  /// minimum in pixels — **and the half wins over the minimum**, which is what
  /// letting the panel into the side panels needed. In a narrow place the old
  /// rule gave the minimum and covered nearly all of the reading; now the
  /// reading keeps half of whatever it has.
  double _widthWithin(double area) {
    final share = (_dragging ?? widget.fraction)
        .clamp(0.0, kSlidePanelMaxFraction);
    final ceiling = area * kSlidePanelMaxFraction;
    final wanted = area * share;
    if (wanted >= kSlidePanelMinWidth) return wanted;
    return kSlidePanelMinWidth > ceiling ? ceiling : kSlidePanelMinWidth;
  }
}

/// The hairline round a panel, along everything but the edge it came from.
///
/// A blurred panel over a blurred window has no edge of its own where what is
/// under it happens to be plain, so the contour facing the content is drawn.
/// The other side is against the window and needs nothing: there is no content
/// there to be told apart from.
class _PanelEdge extends CustomPainter {
  const _PanelEdge({
    required this.colour,
    required this.radius,
    required this.right,
  });

  final Color colour;
  final double radius;
  final bool right;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colour;

    // Half a pixel in, so a one-pixel stroke lands *inside* the panel rather
    // than straddling its edge and coming out half as strong.
    const inset = 0.5;
    final r = radius;
    final w = size.width;
    final h = size.height;
    final path = Path();

    if (right) {
      path
        ..moveTo(w, inset)
        ..lineTo(r, inset)
        ..arcToPoint(
          Offset(inset, r),
          radius: Radius.circular(r),
          clockwise: false,
        )
        ..lineTo(inset, h - r)
        ..arcToPoint(
          Offset(r, h - inset),
          radius: Radius.circular(r),
          clockwise: false,
        )
        ..lineTo(w, h - inset);
    } else {
      path
        ..moveTo(0, inset)
        ..lineTo(w - r, inset)
        ..arcToPoint(
          Offset(w - inset, r),
          radius: Radius.circular(r),
        )
        ..lineTo(w - inset, h - r)
        ..arcToPoint(
          Offset(w - r, h - inset),
          radius: Radius.circular(r),
        )
        ..lineTo(0, h - inset);
    }
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_PanelEdge old) =>
      old.colour != colour || old.radius != radius || old.right != right;
}
