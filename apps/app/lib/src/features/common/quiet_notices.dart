import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Transient pop-up messages (info and error) are intentionally not shown.
/// Outcomes belong in the page itself. Call sites keep building their
/// [SnackBar] so one change here can bring pop-ups back.
extension QuietScaffoldMessenger on ScaffoldMessengerState {
  void showNotice(SnackBar snackBar) => quietNotice(snackBar.content);
}

void quietNotice(Object content) {
  if (!kDebugMode) return;
  debugPrint('Notice suppressed: ${content is Text ? content.data : content}');
}
