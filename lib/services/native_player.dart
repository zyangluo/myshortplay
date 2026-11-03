import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

class NativePlayer {
  static const _channel = MethodChannel('shortplay/native_player');
  static const _events = EventChannel('shortplay/native_player/events');

  static StreamSubscription? _globalEventSub;
  static final Map<int, NativePlayer> _instances = {};
  static final Set<NativePlayer> _creating = {};
  static final Map<int, Map<String, Map<Object?, Object?>>> _earlyEvents = {};
  static const _creationTimeout = Duration(seconds: 15);

  static void _ensureGlobalListener() {
    if (_globalEventSub != null) return;
    _globalEventSub = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final playerId = event['playerId'] as int?;
        if (playerId == null) return;
        final player = _instances[playerId];
        if (player != null) {
          player._handleEvent(event);
        } else if (_creating.isNotEmpty &&
            (_earlyEvents.containsKey(playerId) || _earlyEvents.length < 8)) {
          final type = event['type'];
          if (type is String) {
            (_earlyEvents[playerId] ??= {})[type] = Map<Object?, Object?>.of(
              event,
            );
          }
        }
      },
      onError: (Object error) {
        for (final player in _instances.values.toList()) {
          player._handleEvent({
            'type': 'error',
            'value': '播放器事件通道异常：$error',
          });
        }
      },
    );
  }

  @visibleForTesting
  static Future<void> resetEventListenerForTesting() async {
    assert(_instances.isEmpty && _creating.isEmpty);
    await _globalEventSub?.cancel();
    _globalEventSub = null;
    _earlyEvents.clear();
  }

  int? _playerId;
  int? _textureId;
  bool _disposed = false;

  int? get textureId => _textureId;
  bool get isCreated => _textureId != null;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _completed = false;
  bool _buffering = false;
  bool _firstFrameRendered = false;
  String? _errorMessage;
  int _videoWidth = 0;
  int _videoHeight = 0;

  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get completed => _completed;
  bool get buffering => _buffering;
  bool get firstFrameRendered => _firstFrameRendered;
  String? get errorMessage => _errorMessage;
  int get videoWidth => _videoWidth;
  int get videoHeight => _videoHeight;

  final _positionCtrl = StreamController<Duration>.broadcast();
  final _durationCtrl = StreamController<Duration>.broadcast();
  final _playingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _firstFrameCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();

  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration> get durationStream => _durationCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;
  Stream<bool> get completedStream => _completedCtrl.stream;
  Stream<bool> get bufferingStream => _bufferingCtrl.stream;
  Stream<bool> get firstFrameStream => _firstFrameCtrl.stream;
  Stream<String> get errorStream => _errorCtrl.stream;

  // ─── 生命周期 ──────────────────────────────────────────────────────────

  final _createdCompleter = Completer<int>();

  Future<int> create(String cdnUrl, String keyHex) async {
    if (_disposed) throw StateError('播放器已关闭');
    final created = _createdCompleter.future;
    unawaited(
      created.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    _creating.add(this);
    try {
      _ensureGlobalListener();
      final result = await _channel.invokeMapMethod<String, dynamic>('create', {
        'cdnUrl': cdnUrl,
        'keyHex': keyHex,
      });
      final playerId = result?['playerId'];
      if (playerId is! int) {
        throw StateError('播放器未返回有效标识');
      }
      _playerId = playerId;
      _instances[playerId] = this;
      final events = _earlyEvents.remove(playerId);
      if (events != null) {
        for (final event in events.values) {
          _handleEvent(event);
        }
      }
      _textureId = await created.timeout(_creationTimeout);
      return _textureId!;
    } catch (_) {
      await dispose();
      rethrow;
    } finally {
      _creating.remove(this);
      if (_creating.isEmpty) _earlyEvents.clear();
    }
  }

  Future<void> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_errorMessage != null) throw StateError(_errorMessage!);
    if (_disposed) throw StateError('播放器已关闭');
    if (_firstFrameRendered) return;

    final completer = Completer<void>();
    final frameSubscription = firstFrameStream.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    final errorSubscription = errorStream.listen((message) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(message));
      }
    });
    try {
      await completer.future.timeout(timeout);
    } finally {
      await frameSubscription.cancel();
      await errorSubscription.cancel();
    }
  }

  Future<void> play() async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('play', {'id': _playerId});
  }

  Future<void> pause() async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('pause', {'id': _playerId});
  }

  Future<void> seek(Duration position) async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('seek', {
      'id': _playerId,
      'positionMs': position.inMilliseconds,
    });
  }

  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('setVolume', {
      'id': _playerId,
      'volume': volume,
    });
  }

  Future<void> setRate(double rate) async {
    if (_disposed) return;
    await _channel.invokeMethod<void>('setRate', {
      'id': _playerId,
      'rate': rate,
    });
  }

  static Future<void> setKeepScreenOn(bool on) async {
    await _channel.invokeMethod<void>('setKeepScreenOn', {'on': on});
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_playerId != null) _instances.remove(_playerId);
    try {
      await _channel.invokeMethod('dispose', {'id': _playerId});
    } catch (_) {}
    _positionCtrl.close();
    _durationCtrl.close();
    _playingCtrl.close();
    _completedCtrl.close();
    _bufferingCtrl.close();
    _firstFrameCtrl.close();
    _errorCtrl.close();
  }

  // ─── 事件处理 ──────────────────────────────────────────────────────────

  void _handleEvent(dynamic event) {
    if (event is! Map) return;
    if (_disposed) return;
    final type = event['type'] as String?;
    switch (type) {
      case 'created':
        final textureId = event['value'] as int;
        if (!_createdCompleter.isCompleted) {
          _createdCompleter.complete(textureId);
        }
      case 'error':
        final message = event['value']?.toString() ?? '播放器发生未知错误';
        _errorMessage = message;
        _errorCtrl.add(message);
        if (!_createdCompleter.isCompleted) {
          _createdCompleter.completeError(Exception(message));
        }
      case 'position':
        if (_disposed) return;
        final ms = event['value'] as int;
        _position = Duration(milliseconds: ms);
        _positionCtrl.add(_position);
      case 'duration':
        if (_disposed) return;
        final ms = event['value'] as int;
        _duration = Duration(milliseconds: ms);
        _durationCtrl.add(_duration);
      case 'playing':
        if (_disposed) return;
        _playing = event['value'] as bool;
        _playingCtrl.add(_playing);
      case 'completed':
        if (_disposed) return;
        _completed = event['value'] as bool;
        _completedCtrl.add(_completed);
      case 'buffering':
        if (_disposed) return;
        _buffering = event['value'] as bool;
        _bufferingCtrl.add(_buffering);
      case 'firstFrame':
        if (_disposed) return;
        _firstFrameRendered = true;
        _firstFrameCtrl.add(true);
      case 'videoSize':
        if (_disposed) return;
        _videoWidth = event['width'] as int;
        _videoHeight = event['height'] as int;
    }
  }
}
