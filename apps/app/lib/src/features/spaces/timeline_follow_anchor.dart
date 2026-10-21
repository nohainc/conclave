import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Follows incoming content only as far as the first new message's start.
/// The anchor survives subsequent updates until the reader scrolls themselves.
class AxTimelineFollowAnchor {
  final _keys = <Object, GlobalKey>{};
  double? _lastContentEnd;
  Object? _message;
  GlobalKey? _key;
  double? _fallbackOffset;
  double? _fallbackFraction;
  bool _once = false;
  GlobalKey? _nextKey;

  /// Whether an anchor is currently owned (and not yet released).
  bool get active => _message != null;

  /// Every row owns a stable key from its first build, so anchoring a row
  /// later never re-parents (and rebuilds) an already-rendered message.
  GlobalKey keyFor(Object message) => _keys.putIfAbsent(message, GlobalKey.new);

  void retainMessages(Iterable<Object> messages) {
    final retained = messages.toSet();
    if (_message != null && !retained.contains(_message)) reset();
    _keys.removeWhere((message, _) => !retained.contains(message));
  }

  void observe(Object message, ScrollController controller) {
    // The first unread message owns the anchor until the reader scrolls or it
    // disappears. A short first message fits above the composer and is never
    // "protected", so later arrivals must not steal the anchor and push it
    // out of view.
    if (_message != null) return;
    _message = message;
    _key = _keys.putIfAbsent(message, GlobalKey.new);
    _fallbackOffset =
        controller.hasClients && controller.position.hasContentDimensions
            ? controller.position.maxScrollExtent +
                controller.position.viewportDimension
            : _lastContentEnd;
  }

  /// Anchors the already-read message before the first new one so it is shown
  /// at the top of the viewport. [next] is the first new message; when the
  /// previous message is so tall that [next] would start far below the
  /// viewport, the view starts at [next] instead so it stays visible.
  /// [fraction] estimates the row's position so a virtualized, unmounted row
  /// can be approached before it is measured. With [once] the anchor releases
  /// after the reveal so later arrivals can anchor again.
  void anchorAt(Object message,
      {Object? next, required double fraction, bool once = true}) {
    reset();
    _message = message;
    _key = _keys.putIfAbsent(message, GlobalKey.new);
    _nextKey = next == null ? null : _keys.putIfAbsent(next, GlobalKey.new);
    _fallbackFraction = fraction.clamp(0.0, 1.0);
    _once = once;
  }

  void reset({bool clearKeys = false}) {
    if (clearKeys) {
      _keys.clear();
      _lastContentEnd = null;
    }
    _message = null;
    _key = null;
    _fallbackOffset = null;
    _fallbackFraction = null;
    _once = false;
    _nextKey = null;
  }

  /// Returns true if another layout is needed to mount a virtualized anchor.
  bool reveal(ScrollController controller) {
    final position = controller.position;
    _lastContentEnd = position.maxScrollExtent + position.viewportDimension;
    if (_key == null) {
      controller.jumpTo(position.maxScrollExtent);
      return false;
    }
    // Virtualized children can remain mounted while inactive in the sliver's
    // keep-alive cache. Inspect attachment without findRenderObject(), which
    // requires an active element and asserts before we can check attachment.
    final context = _key!.currentContext;
    final render = context is Element ? context.renderObject : null;
    if (render == null || !render.attached) {
      final estimate = _fallbackFraction != null
          ? position.minScrollExtent +
              _fallbackFraction! *
                  (position.maxScrollExtent - position.minScrollExtent)
          : _fallbackOffset ?? position.maxScrollExtent;
      controller.jumpTo(
          estimate.clamp(position.minScrollExtent, position.maxScrollExtent));
      return true;
    }
    final viewport = RenderAbstractViewport.of(render);
    var start = viewport.getOffsetToReveal(render, 0).offset;
    final nextContext = _nextKey?.currentContext;
    final nextRender = nextContext is Element ? nextContext.renderObject : null;
    if (nextRender != null && nextRender.attached) {
      final nextStart = viewport.getOffsetToReveal(nextRender, 0).offset;
      if (nextStart - start > position.viewportDimension * 0.7) {
        start = nextStart;
      }
    }
    // Short messages can remain fully visible above the composer. Long
    // messages stop at their opening line instead of their final line.
    controller.jumpTo(
        start.clamp(position.minScrollExtent, position.maxScrollExtent));
    if (_once) reset();
    return false;
  }
}
