import '../core/models/media_item.dart';
import '../core/models/playlist.dart';

const Set<String> removedSeedMediaIds = <String>{
  'song-blue-hour',
  'song-neon-archive',
  'song-sunlit-bassline',
  'song-midnight-map',
  'song-quiet-rooms',
  'song-paper-moon',
  'video-lake-cut',
  'video-city-night',
  'video-course-one',
  'video-family-clip',
};

const Set<String> removedSeedPlaylistIds = <String>{
  'playlist-night-drive',
  'playlist-focus',
};

const List<MediaItem> seedAudioItems = <MediaItem>[];
const List<MediaItem> seedVideoItems = <MediaItem>[];
const List<Playlist> seedPlaylists = <Playlist>[];
