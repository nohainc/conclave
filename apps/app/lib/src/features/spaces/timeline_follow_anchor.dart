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
  bool _pending = false;
  bool _protected = false;

  GlobalKey? keyFor(Object message) => _keys[message];

  void retainMessages(Iterable<Object> messages) {
    final retained = messages.toSet();
    if (_message != null && !retained.contains(_message)) reset();
    _keys.removeWhere((message, _) => !retained.contains(message));
  }

  void observe(Object message, ScrollController controller) {
    if (_message == message || (_message != null && (_pending || _protected))) {
      return;
    }
    _message = message;
    _key = _keys.putIfAbsent(message, GlobalKey.new);
    _pending = true;
    _fallbackOffset =
        controller.hasClients && controller.position.hasContentDimensions
            ? controller.position.maxScrollExtent +
                controller.position.viewportDimension
            : _lastContentEnd;
  }

  void reset({bool clearKeys = false}) {
    if (clearKeys) {
      _keys.clear();
      _lastContentEnd = null;
    }
    _message = null;
    _key = null;
    _fallbackOffset = null;
    _pending = false;
    _protected = false;
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
      controller.jumpTo((_fallbackOffset ?? position.maxScrollExtent)
          .clamp(position.minScrollExtent, position.maxScrollExtent));
      return true;
    }
    final viewport = RenderAbstractViewport.of(render);
    final start = viewport.getOffsetToReveal(render, 0).offset;
    _pending = false;
    _protected = position.maxScrollExtent > start + 1;
    // Short messages can remain fully visible above the composer. Long
    // messages stop at their opening line instead of their final line.
    controller.jumpTo(
        start.clamp(position.minScrollExtent, position.maxScrollExtent));
    return false;
  }
}
