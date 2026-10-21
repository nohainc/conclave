part of '../spaces_pages.dart';

/// Shared virtualized history surface for Chat and Work timelines.
///
/// Headers, pagination controls and errors stay as sliver adapters while
/// variable-height entries are built by a keyed sliver list. The composer is
/// owned by the parent and therefore remains outside this scroll surface.
class AxTimelineContainer extends StatefulWidget {
  const AxTimelineContainer({
    super.key,
    required this.scrollKey,
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    this.headerSlivers = const <Widget>[],
    this.empty,
    this.separatorBuilder,
    this.findChildIndexCallback,
    this.itemId,
  });

  final Key scrollKey;
  final ScrollController controller;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final List<Widget> headerSlivers;
  final Widget? empty;
  final IndexedWidgetBuilder? separatorBuilder;
  final ChildIndexGetter? findChildIndexCallback;

  /// Stable identity of the item at an index. With it the timeline is
  /// anchored at the latest item present when it first had content: those
  /// items grow upward from the bottom edge, so opening a long history lays
  /// out only the rows that fit on screen and builds older rows as the reader
  /// scrolls up. Later items grow downward below that anchor, so neither new
  /// items nor older pages move what the reader is looking at.
  final Object? Function(int index)? itemId;

  @override
  State<AxTimelineContainer> createState() => _AxTimelineContainerState();
}

class _AxTimelineContainerState extends State<AxTimelineContainer> {
  static const _centerKey = ValueKey('timeline-center');

  Object? _anchorId;
  int _anchorCount = 0;

  /// Number of items laid out above the anchor, kept across rebuilds.
  int _resolveAnchorCount() {
    final itemId = widget.itemId;
    final count = widget.itemCount;
    if (itemId == null) return 0;
    if (_anchorId == null) {
      if (count == 0) return 0;
      _anchorId = itemId(count - 1);
      return _anchorCount = count;
    }
    // Newer items usually follow the anchor, so search from the end.
    for (var index = count - 1; index >= 0; index--) {
      if (itemId(index) == _anchorId) return _anchorCount = index + 1;
    }
    return _anchorCount = _anchorCount.clamp(0, count);
  }

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    final itemCount = widget.itemCount;
    final hasSeparators = widget.separatorBuilder != null && itemCount > 1;
    final childCount = hasSeparators ? itemCount * 2 - 1 : itemCount;
    Widget child(BuildContext context, int flat) {
      if (hasSeparators && flat.isOdd) {
        return widget.separatorBuilder!(context, flat ~/ 2);
      }
      return widget.itemBuilder(context, hasSeparators ? flat ~/ 2 : flat);
    }

    int? flatIndexFor(Key key) {
      final itemIndex = widget.findChildIndexCallback!(key);
      if (itemIndex == null) return null;
      return hasSeparators ? itemIndex * 2 : itemIndex;
    }

    final anchored = _resolveAnchorCount();
    if (itemCount == 0 || anchored == 0) {
      return CustomScrollView(
        key: widget.scrollKey,
        controller: widget.controller,
        slivers: [
          ...widget.headerSlivers,
          if (itemCount == 0 && widget.empty != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: widget.empty,
            )
          else if (itemCount > 0)
            SliverList(
              delegate: SliverChildBuilderDelegate(
                child,
                childCount: childCount,
                findChildIndexCallback:
                    widget.findChildIndexCallback == null ? null : flatIndexFor,
              ),
            ),
        ],
      );
    }

    // Items up to the anchor are built from the bottom edge upward; the
    // separator after the anchor starts the downward list.
    final split = hasSeparators ? anchored * 2 - 1 : anchored;
    return CustomScrollView(
      key: widget.scrollKey,
      controller: widget.controller,
      center: _centerKey,
      anchor: 1,
      slivers: [
        ...widget.headerSlivers,
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => child(context, split - 1 - index),
            childCount: split,
            findChildIndexCallback: widget.findChildIndexCallback == null
                ? null
                : (key) {
                    final flat = flatIndexFor(key);
                    return flat == null || flat >= split
                        ? null
                        : split - 1 - flat;
                  },
          ),
        ),
        SliverList(
          key: _centerKey,
          delegate: SliverChildBuilderDelegate(
            (context, index) => child(context, split + index),
            childCount: childCount - split,
            findChildIndexCallback: widget.findChildIndexCallback == null
                ? null
                : (key) {
                    final flat = flatIndexFor(key);
                    return flat == null || flat < split ? null : flat - split;
                  },
          ),
        ),
      ],
    );
  }
}
