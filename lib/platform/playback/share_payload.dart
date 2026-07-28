import '../../core/models/media_item.dart';

Map<String, Object?> mediaSharePayload(MediaItem item) {
  return <String, Object?>{
    'mediaId': item.id,
    'kind': item.kind.name,
    'title': item.title,
    'path': item.path,
  };
}
