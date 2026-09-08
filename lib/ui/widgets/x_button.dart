import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings/settings_store.dart';
import '../motion.dart';
import '../text_scale.dart';
import 'hint.dart';
import '../picture_filter.dart';

/// The shape an [XButton] takes.
enum XButtonShape {
  /// Fully rounded ends. The house style, used wherever a control needs to
  /// read as a button.
  pill,

  /// A circle, for a single icon that should feel like a knob.
  circle,

  /// No outline and no fill until hovered, for icons packed into a dense bar
  /// where borders would be noise.
  bare,
}

/// How much of a nudge the button gives the eye.
enum XButtonTone {
  /// Foreground colour, background only on hover.
  neutral,

  /// Accent colour throughout; for the one action a bar is really about.
  accent,

  /// Filled with the accent; for a primary action.
  filled,
}

/// The project's button.
///
/// One widget covers the pill, the outlined circle and the bare icon, because
/// they are the same control at different weights — keeping them together is
/// what stops the toolbars drifting apart visually.
///
/// It draws from [SettingsStore] rather than the Material theme so it matches
/// the panels, which are themed independently of the app chrome.
class XButton extends StatefulWidget {
  const XButton({
    super.key,
    this.icon,
    this.image,
    this.label,
    this.onPressed,
    this.tooltip,
    this.shape = XButtonShape.pill,
    this.tone = XButtonTone.neutral,
    this.outlined = false,
    this.selected = false,
    this.height = 24,
    this.iconSize = 16,
    this.ink,
  }) : assert(icon != null || label != null, 'a button needs something to show');

  /// Icon-only, label-only, or both — in which case the icon leads.
  final IconData? icon;

  /// A picture to draw instead of [icon] — a plugin's own mark. Drawn as it
  /// is, unrecoloured: a brand that follows the palette is not a brand.
  final String? image;
  final String? label;

  final VoidCallback? onPressed;
  final String? tooltip;

  final XButtonShape shape;
  final XButtonTone tone;

  /// Draws a border. Implied for [XButtonShape.circle] unless turned off.
  final bool outlined;

  /// Held-down look, for toggles that are currently on.
  final bool selected;

  /// The ink to draw in, where the panel's is the wrong answer.
  ///
  /// A button on the **title bar** is one such place: it stands on the header's
  /// fill, not on a panel, so it takes the header's ink. Left null it draws
  /// from the palette as before — which is right everywhere a button sits on a
  /// panel, and was wrong on the bar: a plugin's icon came out in the listing's
  /// dark ink on a slate bar, and only the one plugin shipping a picture of its
  /// own could be made out (reported 2026-08-15).
  final Color? ink;

  final double height;
  final double iconSize;

  @override
  State<XButton> createState() => _XButtonState();
}

class _XButtonState extends State<XButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<SettingsStore>().appearance;
    final enabled = widget.onPressed != null;

    final base = switch (widget.tone) {
      XButtonTone.neutral => widget.ink ?? theme.panelForeground,
      XButtonTone.accent => theme.accentColor,
      XButtonTone.filled => theme.panelBackground,
    };
    final foreground = enabled ? base : base.withValues(alpha: 0.38);

    Color background;
    if (widget.tone == XButtonTone.filled) {
      background = theme.accentColor.withValues(
        alpha: !enabled
            ? 0.35
            : _pressed
                ? 1.0
                : _hovered
                    ? 0.92
                    : 0.8,
      );
    } else if (widget.selected) {
      background = theme.accentColor.withValues(alpha: _hovered ? 0.30 : 0.22);
    } else if (_pressed) {
      background = (widget.ink ?? theme.panelForeground).withValues(alpha: 0.20);
    } else if (_hovered && enabled) {
      background = (widget.ink ?? theme.panelForeground).withValues(alpha: 0.12);
    } else {
      background = Colors.transparent;
    }

    final showBorder = widget.outlined || widget.shape == XButtonShape.circle;
    final radius = switch (widget.shape) {
      XButtonShape.circle => widget.height / 2,
      // A pill is a stadium: the radius is simply half the height.
      XButtonShape.pill => widget.height / 2,
      XButtonShape.bare => 5.0,
    };

    // A circle must stay circular whatever the label would have wanted.
    final isCircular = widget.shape == XButtonShape.circle;
    final horizontal = isCircular
        ? 0.0
        : widget.label == null
            ? widget.height * 0.28
            : widget.height * 0.42;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.image != null)
          Image.file(
            File(widget.image!),
            width: widget.iconSize,
            height: widget.iconSize,
            filterQuality: pictureSmoothing,
            // A picture that has gone — an uninstalled plugin still in a menu
            // — falls back to the shape rather than to a broken box.
            errorBuilder: (context, _, _) => Icon(
              widget.icon ?? Icons.extension_outlined,
              size: widget.iconSize,
              color: foreground,
            ),
          )
        else if (widget.icon != null)
          Icon(widget.icon, size: widget.iconSize, color: foreground),
        if ((widget.icon != null || widget.image != null) &&
            widget.label != null)
          SizedBox(width: widget.height * 0.22),
        if (widget.label != null)
          Text(
            widget.label!,
            style: TextStyle(
              color: foreground,
              fontSize: widget.height * 0.5,
              // Constant weight: swapping to a bolder face on hover or
              // selection re-measures the text and makes it twitch. Constant
              // per state, that is — the interface weight setting still moves
              // it, it just does not move because the pointer arrived.
              fontWeight: context.uiWeight(FontWeight.w500),
              height: 1.1,
            ),
          ),
      ],
    );

    final button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: enabled
            ? () {
                setState(() => _pressed = false);
                widget.onPressed!();
              }
            : null,
        child: AnimatedContainer(
          // Feedback under the pointer: it must not outlive the gesture.
          duration: theme.animated(kButtonAnimationDuration),
          curve: kArrivingCurve,
          height: widget.height,
          width: isCircular ? widget.height : null,
          padding: EdgeInsets.symmetric(horizontal: horizontal),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(radius),
            border: showBorder
                ? Border.all(
                    color: widget.selected
                        ? theme.accentColor
                        : foreground.withValues(alpha: _hovered ? 0.55 : 0.3),
                  )
                : null,
          ),
          child: content,
        ),
      ),
    );

    if (widget.tooltip == null) return button;
    return Hint(
      message: widget.tooltip!,
      wait: const Duration(milliseconds: 450),
      child: button,
    );
  }
}
