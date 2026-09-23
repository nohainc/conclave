import 'package:flutter/material.dart';

/// Shared Conclave AX visual constants for the productivity application.
abstract final class ConclaveBrand {
  static const accent = Color(0xff5e4bd8);
  static const accentDark = Color(0xff4937bd);
  static const accentWash = Color(0xffdedcf4);
  static const ink = Color(0xff20202a);
  static const paper = Color(0xfff8f7f3);
  static const surface = Color(0xffffffff);
  static const line = Color(0xffdfded8);
  static const navigation = Color(0xff20202a);

  static const brandMark = BoxDecoration(
    color: accent,
    borderRadius: BorderRadius.all(Radius.circular(10)),
  );
}
