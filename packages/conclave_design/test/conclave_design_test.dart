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

    test('Typography tokens and scale are valid and deterministic', () {
      expect(ConclaveTypography.fontFamily, 'Inter');
      expect(ConclaveTypography.fontFamilyMono, 'JetBrains Mono');
      expect(ConclaveTypography.display.fontSize, 26);
      expect(ConclaveTypography.displayLarge.fontSize, 26);
      expect(ConclaveTypography.pageTitle.fontSize, 22);
      expect(ConclaveTypography.titleLarge.fontSize, 22);
      expect(ConclaveTypography.sectionTitle.fontSize, 17);
      expect(ConclaveTypography.titleMedium.fontSize, 17);
      expect(ConclaveTypography.cardTitle.fontSize, 15);
      expect(ConclaveTypography.titleSmall.fontSize, 15);
      expect(ConclaveTypography.bodyLarge.fontSize, 14);
      expect(ConclaveTypography.body.fontSize, 13.5);
      expect(ConclaveTypography.bodyMedium.fontSize, 13.5);
      expect(ConclaveTypography.bodySmall.fontSize, 12.5);
      expect(ConclaveTypography.caption.fontSize, 11.5);
      expect(ConclaveTypography.button.fontSize, 13);
      expect(ConclaveTypography.mono.fontSize, 12);
      expect(ConclaveTypography.codeSmall.fontSize, 12);
      expect(ConclaveTypography.codeBlock.fontSize, 13);
      expect(ConclaveTypography.monoSmall.fontSize, 11);

      // Verify no typography scale item is below 11px
      expect(ConclaveTypography.caption.fontSize!, greaterThanOrEqualTo(11.0));
      expect(ConclaveTypography.monoSmall.fontSize!, greaterThanOrEqualTo(11.0));
    });

    test('ThemeData TextTheme includes all core typographic levels', () {
      final theme = ConclaveBrand.darkTheme();
      expect(theme.textTheme.displayLarge?.fontSize, 26);
      expect(theme.textTheme.headlineMedium?.fontSize, 24);
      expect(theme.textTheme.titleLarge?.fontSize, 20);
      expect(theme.textTheme.titleMedium?.fontSize, 16);
      expect(theme.textTheme.titleSmall?.fontSize, 14);
      expect(theme.textTheme.bodyLarge?.fontSize, 14);
      expect(theme.textTheme.bodyMedium?.fontSize, 13.5);
      expect(theme.textTheme.bodySmall?.fontSize, 12);
      expect(theme.textTheme.labelLarge?.fontSize, 13);
      expect(theme.textTheme.labelSmall?.fontSize, 11.5);
      expect(theme.textTheme.labelSmall?.fontSize!, greaterThanOrEqualTo(11.0));
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
