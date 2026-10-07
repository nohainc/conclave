import 'package:flutter/material.dart';

import 'colors.dart';

/// Canonical brand asset identifiers and rendering helpers.
abstract final class ConclaveBrandAssets {
  static const markSvg = 'assets/branding/conclave_mark.svg';
  static const markDarkSvg = 'assets/branding/conclave_mark_dark.svg';
  static const markMonochromeSvg =
      'assets/branding/conclave_mark_monochrome.svg';
  static const markTwotoneSvg = 'assets/branding/conclave_mark_twotone.svg';
  static const wordmarkSvg = 'assets/branding/conclave_wordmark.svg';
  static const wordmarkDarkSvg = 'assets/branding/conclave_wordmark_dark.svg';
  static const logoMasterSvg = 'assets/branding/conclave_logo.svg';

  static const logoPng1024 = 'assets/branding/conclave_logo.png';
  static const logoPng512 = 'assets/branding/conclave_logo_512.png';
  static const logoPng192 = 'assets/branding/conclave_logo_192.png';
  static const logoPng128 = 'assets/branding/conclave_logo_128.png';
  static const logoPng64 = 'assets/branding/conclave_logo_64.png';
  static const logoPng32 = 'assets/branding/conclave_logo_32.png';

  /// Renders the official Conclave AX logo mark.
  static Widget logoMark({
    double size = 28,
    BorderRadius? borderRadius,
    BoxFit fit = BoxFit.contain,
  }) {
    final image = Image.asset(
      logoPng1024,
      width: size,
      height: size,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: ConclaveColors.primary,
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
        alignment: Alignment.center,
        child: Text(
          'C',
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
  }
}
