import '../../core/models/media_item.dart';

List<MediaItem> visibleMediaItems(
  Iterable<MediaItem> items,
  Set<String> hiddenMediaIds,
) {
  return items
      .where((item) => !hiddenMediaIds.contains(item.id))
      .toList(growable: false);
}
