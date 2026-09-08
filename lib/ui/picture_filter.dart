import 'dart:io';

import 'package:flutter/painting.dart';

/// How a picture is sampled when it is drawn smaller than it is.
///
/// [FilterQuality.medium] is the answer wherever it can be trusted. It
/// mipmaps, which is what keeps a 383-pixel icon drawn at 34 from shimmering
/// into whichever pixels the sampler happened to land on — and asking for it
/// is asking the graphics driver to build the mipmap chain.
///
/// Linux is where that bet does not always pay. On `nouveau` — what an NVIDIA
/// card runs on until the proprietary driver is installed — Impeller's
/// mipmapped sampling comes back as a dark silhouette of the picture, or as
/// nothing at all. Only pictures: text goes through the font path and stays
/// perfect, so the application looks entirely right apart from every image in
/// it, which is a confusing thing to be handed as a bug report. Measured on
/// that machine, with one picture in the same widget this application draws
/// its plugin icons with:
///
/// | quality | result |
/// | --- | --- |
/// | `medium` — Flutter's default | a dark silhouette |
/// | `high` | a dark silhouette |
/// | `low` | correct |
/// | `none` | correct |
///
/// So Linux draws with [FilterQuality.low]: one bilinear tap, and no mipmap
/// chain for anybody to get wrong. It is softer than `medium` on a picture
/// shrunk a long way, and that is the whole of the cost. Windows and macOS
/// are left exactly as they were — this is a driver being worked around, not
/// a change of mind about how pictures should look.
final FilterQuality pictureSmoothing =
    Platform.isLinux ? FilterQuality.low : FilterQuality.medium;
