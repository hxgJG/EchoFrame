import 'dart:async';
import 'dart:io';

String diagnosticUrl(Uri uri) => Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();

Map<String, Object?> diagnosticError(Object error) => {
      'errorType': error.runtimeType.toString(),
      if (error is SocketException) 'osErrorCode': error.osError?.errorCode,
      if (error is TlsException) 'osErrorCode': error.osError?.errorCode,
      if (error is TimeoutException)
        'timeoutMs': error.duration?.inMilliseconds,
      if (error is FileSystemException) 'osErrorCode': error.osError?.errorCode,
    };

/// Opt-in, bounded observations. No signed query strings, credentials or bodies.
class UpdateDiagnostics {
  final Stopwatch _clock = Stopwatch()..start();
  final List<Map<String, Object?>> _events = [];
  int droppedEvents = 0;
  static const maximumEvents = 2400;

  void record(String type, Map<String, Object?> values) {
    if (_events.length >= maximumEvents) {
      droppedEvents++;
      return;
    }
    _events.add(
        {'elapsedMs': _clock.elapsedMilliseconds, 'type': type, ...values});
  }

  Map<String, Object?> snapshot() => {
        'elapsedMs': _clock.elapsedMilliseconds,
        'droppedEvents': droppedEvents,
        'events': List<Map<String, Object?>>.of(_events),
      };
}
