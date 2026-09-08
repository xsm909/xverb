import 'dart:ui' show Color, ColorFilter;

/// Colours an icon the way a shader would: desaturate, then multiply by the
/// wanted colour. `rgb → luminance(rgb) × colour`, and the alpha is left alone.
///
/// The first attempt used `srcIn`, which replaces every pixel the icon drew with
/// one flat colour. That is a paint fill, not a tint: a folder came out as a
/// silhouette with none of its own shading, and the listing lost exactly the
/// detail that makes an icon recognisable.
///
/// Luminance rather than an average, with the usual weights — green carries most
/// of what the eye reads as brightness, blue almost none — so a blue-and-white
/// icon keeps the difference between its blue and its white instead of both
/// landing on the same grey.
class IconTint {
  const IconTint._();

  /// Rec. 709 luminance, which is what "desaturate" means for anything shown on
  /// a screen.
  static const double _red = 0.2126;
  static const double _green = 0.7152;
  static const double _blue = 0.0722;

  /// The 4×5 matrix, row-major, as `ColorFilter.matrix` takes it.
  ///
  /// Each output channel is the input's luminance scaled by that channel of
  /// [colour], so a mid-grey pixel comes out at half the colour and a white one
  /// at the colour itself. Alpha is carried through, multiplied by the colour's
  /// own — which is what fades an icon along with its row when a quick search
  /// ghosts it.
  static List<double> matrixFor(Color colour) => <double>[
        colour.r * _red, colour.r * _green, colour.r * _blue, 0, 0,
        colour.g * _red, colour.g * _green, colour.g * _blue, 0, 0,
        colour.b * _red, colour.b * _green, colour.b * _blue, 0, 0,
        0, 0, 0, colour.a, 0,
      ];

  static ColorFilter of(Color colour) => ColorFilter.matrix(matrixFor(colour));

  /// What [matrixFor] does to one pixel, for anything that needs to check.
  ///
  /// Returns the four channels in the 0..1 the matrix works in.
  static (double, double, double, double) applyTo(
    List<double> matrix,
    double r,
    double g,
    double b,
    double a,
  ) =>
      (
        matrix[0] * r + matrix[1] * g + matrix[2] * b + matrix[3] * a + matrix[4],
        matrix[5] * r + matrix[6] * g + matrix[7] * b + matrix[8] * a + matrix[9],
        matrix[10] * r + matrix[11] * g + matrix[12] * b + matrix[13] * a + matrix[14],
        matrix[15] * r + matrix[16] * g + matrix[17] * b + matrix[18] * a + matrix[19],
      );
}
