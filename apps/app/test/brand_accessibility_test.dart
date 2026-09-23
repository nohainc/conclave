import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/brand.dart';

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
  test('light and dark text tokens meet normal-text contrast targets', () {
    expect(_contrastRatio(ConclaveBrand.lightInk, ConclaveBrand.lightSurface),
        greaterThanOrEqualTo(4.5));
    expect(
        _contrastRatio(ConclaveBrand.lightInkMuted, ConclaveBrand.lightSurface),
        greaterThanOrEqualTo(4.5));
    expect(_contrastRatio(ConclaveBrand.darkInk, ConclaveBrand.darkSurface),
        greaterThanOrEqualTo(4.5));
    expect(
        _contrastRatio(ConclaveBrand.darkInkMuted, ConclaveBrand.darkSurface),
        greaterThanOrEqualTo(4.5));
  });

  test('primary action colors meet contrast targets', () {
    expect(_contrastRatio(Colors.white, ConclaveBrand.accent),
        greaterThanOrEqualTo(4.5));
    expect(_contrastRatio(Colors.white, ConclaveBrand.accentDark),
        greaterThanOrEqualTo(4.5));
  });
}
