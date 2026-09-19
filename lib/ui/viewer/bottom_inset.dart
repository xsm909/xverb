import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// How much of the bottom of a reading something is hanging over — the strip
/// of neighbours, while it is up.
///
/// **Not the media query's padding.** A list reads that padding by itself and
/// would make room for the strip in every reading; a page of text or a
/// picture is meant to run on underneath it, and only what has a line of its
/// own along the bottom — a sheet's status line — needs to stand clear. So
/// it asks here, and nothing else does.
class ViewerBottomInset extends InheritedWidget {
  const ViewerBottomInset({
    super.key,
    required this.inset,
    required super.child,
  });

  final double inset;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ViewerBottomInset>()?.inset ??
      0;

  @override
  bool updateShouldNotify(ViewerBottomInset old) => old.inset != inset;
}

/// Tells [onSize] how big its child was laid out, whenever that changes.
class MeasuredSize extends SingleChildRenderObjectWidget {
  const MeasuredSize({super.key, required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasuredSize(onSize);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMeasuredSize).onSize = onSize;
  }
}

class _RenderMeasuredSize extends RenderProxyBox {
  _RenderMeasuredSize(this.onSize);

  ValueChanged<Size> onSize;
  Size? _told;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _told) return;
    _told = size;
    // After the frame: a size told during layout would rebuild whatever is
    // listening in the middle of laying it out.
    final said = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(said));
  }
}
