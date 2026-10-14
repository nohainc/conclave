part of '../spaces_pages.dart';

/// Shared virtualized history surface for Chat and Work timelines.
///
/// Headers, pagination controls and errors stay as sliver adapters while
/// variable-height entries are built by a keyed sliver list. The composer is
/// owned by the parent and therefore remains outside this scroll surface.
class AxTimelineContainer extends StatelessWidget {
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
  });

  final Key scrollKey;
  final ScrollController controller;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final List<Widget> headerSlivers;
  final Widget? empty;
  final IndexedWidgetBuilder? separatorBuilder;
  final ChildIndexGetter? findChildIndexCallback;

  @override
  Widget build(BuildContext context) {
    final hasSeparators = separatorBuilder != null && itemCount > 1;
    final childCount = hasSeparators ? itemCount * 2 - 1 : itemCount;
    return CustomScrollView(
      key: scrollKey,
      controller: controller,
      slivers: [
        ...headerSlivers,
        if (itemCount == 0 && empty != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: empty,
          )
        else if (itemCount > 0)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (hasSeparators && index.isOdd) {
                  return separatorBuilder!(context, index ~/ 2);
                }
                return itemBuilder(context, hasSeparators ? index ~/ 2 : index);
              },
              childCount: childCount,
              findChildIndexCallback: findChildIndexCallback == null
                  ? null
                  : (key) {
                      final itemIndex = findChildIndexCallback!(key);
                      if (itemIndex == null) return null;
                      return hasSeparators ? itemIndex * 2 : itemIndex;
                    },
            ),
          ),
      ],
    );
  }
}
