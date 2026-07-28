import 'package:flutter_test/flutter_test.dart';
import 'package:lumio/platform/media_library/media_file_operation.dart';

void main() {
  test('source file changes always require an explicit confirmation', () {
    final request = MediaFileOperationRequest.rename(
      mediaId: 'android-audio-42',
      displayName: 'renamed.mp3',
    );

    expect(request.requiresConfirmation, isTrue);
    expect(request.isValid, isTrue);
  });

  test('rename rejects path traversal and keeps a plain display name', () {
    expect(
      MediaFileOperationRequest.rename(
        mediaId: 'android-audio-42',
        displayName: '../escaped.mp3',
      ).isValid,
      isFalse,
    );
    expect(
      MediaFileOperationRequest.rename(
        mediaId: 'android-audio-42',
        displayName: 'renamed.mp3',
      ).isValid,
      isTrue,
    );
  });

  test('move accepts only safe MediaStore relative paths', () {
    expect(
      MediaFileOperationRequest.move(
        mediaIds: const <String>['android-video-7'],
        relativePath: 'Movies/Lumio',
      ).normalizedRelativePath,
      'Movies/Lumio/',
    );
    expect(
      MediaFileOperationRequest.move(
        mediaIds: const <String>['android-video-7'],
        relativePath: '../../private',
      ).isValid,
      isFalse,
    );
  });

  test('parses a cancelled system authorization without affected media', () {
    final result = MediaFileOperationResult.fromJson(
      const <String, Object?>{
        'status': 'cancelled',
        'message': '用户取消了系统授权',
        'affectedMediaIds': <String>[],
      },
    );

    expect(result.status, MediaFileOperationStatus.cancelled);
    expect(result.affectedMediaIds, isEmpty);
    expect(result.didChangeFiles, isFalse);
  });

  test('MP3 tag writes require one media id and non-empty metadata', () {
    final request = MediaFileOperationRequest.writeTags(
      mediaId: 'external-audio-1',
      title: '新标题',
      artist: '新艺术家',
      album: '新专辑',
    );

    expect(request.isValid, isTrue);
    expect(request.toJson()['type'], 'writeTags');
    expect(request.toJson()['title'], '新标题');
  });
}
