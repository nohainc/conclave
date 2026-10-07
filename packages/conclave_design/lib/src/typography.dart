import 'package:flutter/material.dart';

/// Typography scale, font families, and text styles for Conclave AX.
abstract final class ConclaveTypography {
  static const fontFamily = 'Inter';
  static const fontFamilyFallback = [
    'Inter',
    '-apple-system',
    'BlinkMacSystemFont',
    'Segoe UI',
    'Roboto',
    'Helvetica Neue',
    'sans-serif',
  ];

  static const fontFamilyMono = 'JetBrains Mono';
  static const fontFamilyMonoFallback = [
    'JetBrains Mono',
    'SF Mono',
    'Menlo',
    'Monaco',
    'Consolas',
    'Liberation Mono',
    'monospace',
  ];

  /// Wordmark typography (Inter, 700, -0.02em tracking)
  static const wordmark = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.32,
    height: 1.2,
  );

  /// Display / Hero headline (26px, 700)
  static const display = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 26,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.02,
    height: 1.25,
  );

  /// Page title (22px, 700)
  static const pageTitle = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.015,
    height: 1.3,
  );

  /// Section heading (17px, 650/700)
  static const sectionTitle = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 17,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.01,
    height: 1.35,
  );

  /// Card title / group header (15px, 600)
  static const cardTitle = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  /// Body regular (13.5px, 400)
  static const body = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 13.5,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );

  /// Body medium weight (13.5px, 500)
  static const bodyMedium = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 13.5,
    fontWeight: FontWeight.w500,
    height: 1.45,
  );

  /// Secondary text (12.5px, 400)
  static const bodySmall = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 12.5,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  /// Desktop metadata / caption (11.5px, 500)
  static const caption = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  /// Button label (13px, 600)
  static const button = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.005,
    height: 1.3,
  );

  /// Monospace for technical content (code, digests, IDs, CLI) (12px, 400)
  static const mono = TextStyle(
    fontFamily: fontFamilyMono,
    fontFamilyFallback: fontFamilyMonoFallback,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );

  /// Monospace small metadata (11px, 400)
  static const monoSmall = TextStyle(
    fontFamily: fontFamilyMono,
    fontFamilyFallback: fontFamilyMonoFallback,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.35,
  );

  /// Monospace medium emphasis (12px, 500)
  static const monoMedium = TextStyle(
    fontFamily: fontFamilyMono,
    fontFamilyFallback: fontFamilyMonoFallback,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.45,
  );

  /// Primary markdown body, long-form discussion (14px, 400)
  static const bodyLarge = TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );

  /// Inline code chips, tokens, digests, arguments (12px, 500 Mono)
  static const codeSmall = TextStyle(
    fontFamily: fontFamilyMono,
    fontFamilyFallback: fontFamilyMonoFallback,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.35,
  );

  /// Code review blocks, execution logs, terminals (13px, 400 Mono)
  static const codeBlock = TextStyle(
    fontFamily: fontFamilyMono,
    fontFamilyFallback: fontFamilyMonoFallback,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.45,
  );

  // Spec alias mappings
  static const displayLarge = display;
  static const titleLarge = pageTitle;
  static const titleMedium = sectionTitle;
  static const titleSmall = cardTitle;
}
