import '../../core/models/media_item.dart';

Map<String, Object?> media3QueuePayload({
  required MediaItem current,
  required List<MediaItem> queue,
  required Duration position,
}) {
  final items = <MediaItem>[];
  final seenIds = <String>{};
  for (final item in queue) {
    if (item.id.isNotEmpty && seenIds.add(item.id)) {
      items.add(item);
    }
  }
  var currentIndex = items.indexWhere((item) => item.id == current.id);
  if (currentIndex < 0) {
    items.insert(0, current);
    currentIndex = 0;
  }
  return <String, Object?>{
    'currentIndex': currentIndex,
    'positionMs': position.inMilliseconds,
    'items': items
        .map(
          (item) => <String, Object?>{
            'mediaId': item.id,
            'kind': item.kind.name,
            'title': item.title,
            'artist': item.artist,
            'album': item.album,
            'path': item.path,
            'durationMs': item.duration.inMilliseconds,
          },
        )
        .toList(growable: false),
  };
}
