import 'package:flutter/material.dart';

import 'colors.dart';

/// Canonical brand asset identifiers and rendering helpers.
abstract final class SyntilaBrandAssets {
  static const markSvg = 'assets/branding/syntila_mark.svg';
  static const markDarkSvg = 'assets/branding/syntila_mark_dark.svg';
  static const markMonochromeSvg =
      'assets/branding/syntila_mark_monochrome.svg';
  static const markTwotoneSvg = 'assets/branding/syntila_mark_twotone.svg';
  static const wordmarkSvg = 'assets/branding/syntila_wordmark.svg';
  static const wordmarkDarkSvg = 'assets/branding/syntila_wordmark_dark.svg';
  static const logoMasterSvg = 'assets/branding/syntila_logo.svg';
  static const logoDarkMasterSvg = 'assets/branding/syntila_logo_dark.svg';

  static const logoPng1024 = 'assets/branding/syntila_logo.png';
  static const logoPng512 = 'assets/branding/syntila_logo_512.png';
  static const logoPng192 = 'assets/branding/syntila_logo_192.png';
  static const logoPng128 = 'assets/branding/syntila_logo_128.png';
  static const logoPng64 = 'assets/branding/syntila_logo_64.png';
  static const logoPng32 = 'assets/branding/syntila_logo_32.png';

  static const logoDarkPng1024 = 'assets/branding/syntila_logo_dark.png';
  static const logoDarkPng512 = 'assets/branding/syntila_logo_dark_512.png';
  static const logoDarkPng192 = 'assets/branding/syntila_logo_dark_192.png';
  static const logoDarkPng128 = 'assets/branding/syntila_logo_dark_128.png';
  static const logoDarkPng64 = 'assets/branding/syntila_logo_dark_64.png';
  static const logoDarkPng32 = 'assets/branding/syntila_logo_dark_32.png';

  /// Returns the theme-appropriate 1024px raster logo path.
  static String logoPng1024For(bool isDark) =>
      isDark ? logoDarkPng1024 : logoPng1024;

  /// Returns the theme-appropriate 32px raster logo path.
  static String logoPng32For(bool isDark) => isDark ? logoDarkPng32 : logoPng32;

  /// Renders the official Syntila logo mark, automatically selecting the
  /// light or dark theme variant from [Theme.of(context).brightness] unless
  /// [brightness] is explicitly provided.
  static Widget logoMark({
    double size = 28,
    BorderRadius? borderRadius,
    BoxFit fit = BoxFit.contain,
    Brightness? brightness,
  }) {
    return Builder(
      builder: (context) {
        final effectiveBrightness = brightness ?? Theme.of(context).brightness;
        final isDark = effectiveBrightness == Brightness.dark;
        final image = Image.asset(
          logoPng1024For(isDark),
          width: size,
          height: size,
          fit: fit,
          errorBuilder: (context, error, stackTrace) => Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              color: SyntilaColors.primary,
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
            alignment: Alignment.center,
            child: Text(
              'S',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: size * 0.54,
              ),
            ),
          ),
        );
        if (borderRadius != null) {
          return ClipRRect(borderRadius: borderRadius, child: image);
        }
        return image;
      },
    );
  }
}
