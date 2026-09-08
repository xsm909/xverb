import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/i18n.dart';
import 'content_swap.dart';
import 'zoom_canvas.dart';
import 'reading_colours.dart';
import '../picture_filter.dart';

/// A raster picture, whatever wrote it.
///
/// The looking at it — fit, 1:1, zoom, panning, the keyboard — is
/// [ZoomCanvas], shared with the drawing canvas. What is here is the decoding
/// and the one line that paints it.
class ImageView extends StatefulWidget {
  const ImageView({
    super.key,
    required this.bytes,
    this.hasKeyboard = true,
    this.detail,
  });

  /// The whole file, as the plugin sent it. Decoded here rather than by an
  /// `Image` widget because the canvas needs the picture's true size in pixels
  /// before it can say what 1:1 is.
  final Uint8List bytes;

  final bool hasKeyboard;

  /// Anything the reader could not do, to be said beside the caption.
  final String? detail;

  @override
  State<ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<ImageView> {
  ui.Image? _picture;
  String? _trouble;

  /// Held open for as long as there are frames to come: an animated GIF is a
  /// codec that hands over one frame at a time, and closing it after the first
  /// would turn every animation in the collection into a still.
  ui.Codec? _codec;
  Timer? _nextFrame;

  @override
  void initState() {
    super.initState();
    // **Said before anything else: there is nothing here yet.** The page keeps
    // the picture already on screen until this one answers — see
    // [ContentSwap], and [ContentPending] for why a view has to ask for that
    // rather than being given it. After the frame, because a notification
    // dispatched from inside a build reaches its listener mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _picture == null && _trouble == null) {
        const ContentPending().dispatch(context);
      }
    });
    _decode();
  }

  @override
  void didUpdateWidget(ImageView old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) {
      _forget();
      _decode();
    }
  }

  @override
  void dispose() {
    _forget();
    super.dispose();
  }

  void _forget() {
    _nextFrame?.cancel();
    _nextFrame = null;
    _codec?.dispose();
    _codec = null;
    _picture?.dispose();
    _picture = null;
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      if (!mounted) {
        codec.dispose();
        return;
      }
      _codec = codec;
      await _frame();
    } on Object catch (e) {
      // Whatever the plugin sent, this machine's engine could not read it. Say
      // so rather than drawing an empty window — the same rule the 3D viewer
      // learnt about a picture it could not find.
      if (mounted) {
        setState(() => _trouble = '$e');
        // A message is something to draw, so the page may go ahead and show
        // it: a file that cannot be read must not hold the one before it on
        // screen for as long as [ContentSwap.patience].
        const ContentPainted().dispatch(context);
      }
    }
  }

  /// The next frame of the picture, and the one after it if there is one.
  ///
  /// A still is a codec of one frame and this runs once. An animated GIF or
  /// WebP is the same call in a loop — the codec composites each frame onto the
  /// last, so nothing here has to know what a disposal method is.
  Future<void> _frame() async {
    final codec = _codec;
    if (codec == null) return;
    final frame = await codec.getNextFrame();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    final old = _picture;
    final first = old == null;
    setState(() => _picture = frame.image);
    // The first frame is the one the page has been holding the old picture
    // for; the ones after it are an animation running in a view already on
    // screen, and nobody is waiting on those.
    if (first) const ContentPainted().dispatch(context);
    // Not before the frame that still holds it has been painted: an image
    // disposed while the layer tree references it is a crash on the raster
    // thread, and it is not one this widget would ever see itself.
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    if (codec.frameCount > 1) {
      _nextFrame = Timer(frame.duration, _frame);
    }
  }

  @override
  Widget build(BuildContext context) {
    final trouble = _trouble;
    if (trouble != null) return _Trouble(message: trouble);
    final picture = _picture;
    if (picture == null) {
      // Nothing at all rather than a spinner: decoding is milliseconds, and a
      // wheel that flashes once per file is the flicker rule the other way up.
      return const SizedBox.expand();
    }

    final size = Size(picture.width.toDouble(), picture.height.toDouble());
    return ZoomCanvas(
      content: size,
      hasKeyboard: widget.hasKeyboard,
      detail: widget.detail,
      caption: (zoom) => '${picture.width} × ${picture.height}'
          ' · ${zoomPercent(zoom)}%',
      paint: (canvas, at, scale) => canvas.drawImageRect(
        picture,
        Offset.zero & size,
        at,
        Paint()
          // **Magnified, a pixel is a square.** Smoothing a picture that is
          // being looked at closely destroys the one thing somebody magnifies
          // it to see; shrunk, the same choice would alias it to pieces, so it
          // is the direction that decides and not a preference.
          ..filterQuality =
              scale >= 1 ? FilterQuality.none : pictureSmoothing,
      ),
    );
  }
}

class _Trouble extends StatelessWidget {
  const _Trouble({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined, size: 32),
              const SizedBox(height: 10),
              Text(
                tr('This picture could not be read on this machine.'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  color: readingColours(context).muted,
                ),
              ),
            ],
          ),
        ),
      );
}
