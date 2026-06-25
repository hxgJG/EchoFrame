class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.description,
    required this.mediaIds,
    required this.updatedAt,
  });

  factory Playlist.fromJson(Map<String, Object?> json) {
    return Playlist(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未命名播放列表',
      description: json['description']?.toString() ?? '',
      mediaIds: _asStringList(json['mediaIds']),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        _asInt(json['updatedAtMs']),
      ),
    );
  }

  final String id;
  final String name;
  final String description;
  final List<String> mediaIds;
  final DateTime updatedAt;

  Playlist copyWith({
    String? id,
    String? name,
    String? description,
    List<String>? mediaIds,
    DateTime? updatedAt,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      mediaIds: mediaIds ?? this.mediaIds,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'description': description,
      'mediaIds': mediaIds,
      'updatedAtMs': updatedAt.millisecondsSinceEpoch,
    };
  }
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<String> _asStringList(Object? value) {
  if (value is! List<Object?>) {
    return const <String>[];
  }
  return value.map((item) => item.toString()).toList(growable: false);
}
