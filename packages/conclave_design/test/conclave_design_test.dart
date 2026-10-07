import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_design/conclave_design.dart';

double _contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  group('Surface Hierarchy & Theme Tokens', () {
    test('Light mode surface hierarchy is defined deterministically', () {
      expect(ConclaveColors.canvasLight, const Color(0xfff8f7f3));
      expect(ConclaveColors.surfaceLight, const Color(0xffffffff));
      expect(ConclaveColors.surfaceHoverLight, const Color(0xfff1efe8));
      expect(ConclaveColors.borderLight, const Color(0xffdfded8));
      expect(ConclaveColors.codeBackgroundLight, const Color(0xfff0eee8));
    });

    test('Dark mode surface hierarchy is defined deterministically', () {
      expect(ConclaveColors.canvasDark, const Color(0xff121217));
      expect(ConclaveColors.surfaceDark, const Color(0xff1a1a22));
      expect(ConclaveColors.surfaceHoverDark, const Color(0xff24242f));
      expect(ConclaveColors.borderDark, const Color(0xff2e2e3a));
      expect(ConclaveColors.codeBackgroundDark, const Color(0xff15151d));
    });

    test('Material 3 ColorScheme maps surface containers properly', () {
      final lightTheme = ConclaveBrand.lightTheme();
      expect(lightTheme.scaffoldBackgroundColor, ConclaveColors.canvasLight);
      expect(lightTheme.colorScheme.surface, ConclaveColors.surfaceLight);
      expect(lightTheme.colorScheme.surfaceContainerLowest, ConclaveColors.canvasLight);
      expect(lightTheme.colorScheme.surfaceContainer, ConclaveColors.surfaceLight);
      expect(lightTheme.colorScheme.surfaceContainerHigh, ConclaveColors.surfaceHoverLight);
      expect(lightTheme.colorScheme.surfaceContainerHighest, ConclaveColors.codeBackgroundLight);
      expect(lightTheme.colorScheme.outline, ConclaveColors.borderLight);

      final darkTheme = ConclaveBrand.darkTheme();
      expect(darkTheme.scaffoldBackgroundColor, ConclaveColors.canvasDark);
      expect(darkTheme.colorScheme.surface, ConclaveColors.surfaceDark);
      expect(darkTheme.colorScheme.surfaceContainerLowest, ConclaveColors.canvasDark);
      expect(darkTheme.colorScheme.surfaceContainer, ConclaveColors.surfaceDark);
      expect(darkTheme.colorScheme.surfaceContainerHigh, ConclaveColors.surfaceHoverDark);
      expect(darkTheme.colorScheme.surfaceContainerHighest, ConclaveColors.codeBackgroundDark);
      expect(darkTheme.colorScheme.outline, ConclaveColors.borderDark);
    });

    test('Typography tokens and scale are valid', () {
      expect(ConclaveTypography.fontFamily, 'Inter');
      expect(ConclaveTypography.fontFamilyMono, 'JetBrains Mono');
      expect(ConclaveTypography.display.fontSize, 26);
      expect(ConclaveTypography.pageTitle.fontSize, 22);
      expect(ConclaveTypography.sectionTitle.fontSize, 17);
      expect(ConclaveTypography.cardTitle.fontSize, 15);
      expect(ConclaveTypography.body.fontSize, 13.5);
      expect(ConclaveTypography.caption.fontSize, 11.5);
    });

    test('Contrast ratios meet WCAG AA standards', () {
      // Light mode
      expect(
          _contrastRatio(
              ConclaveColors.textPrimaryLight, ConclaveColors.surfaceLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              ConclaveColors.textSecondaryLight, ConclaveColors.surfaceLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              ConclaveColors.textPrimaryLight, ConclaveColors.canvasLight),
          greaterThanOrEqualTo(4.5));

      // Dark mode
      expect(
          _contrastRatio(
              ConclaveColors.textPrimaryDark, ConclaveColors.surfaceDark),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              ConclaveColors.textSecondaryDark, ConclaveColors.surfaceDark),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              ConclaveColors.textPrimaryDark, ConclaveColors.canvasDark),
          greaterThanOrEqualTo(4.5));

      // Dark mode foreground accent (#B8A9FE) on dark surfaces
      expect(
          _contrastRatio(
              ConclaveColors.primaryForegroundDark, ConclaveColors.surfaceDark),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              ConclaveColors.primaryForegroundDark, ConclaveColors.canvasDark),
          greaterThanOrEqualTo(4.5));
    });
  });
}
