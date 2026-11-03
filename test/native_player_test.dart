import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/services/native_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('shortplay/native_player');
  const eventChannel = EventChannel('shortplay/native_player/events');

  test('buffers native events that arrive before create returns', () async {
    final streamReady = Completer<MockStreamHandlerEventSink>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (_, events) => streamReady.complete(events),
      ),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == 'create') {
        final events = await streamReady.future;
        events.success({'playerId': 7, 'type': 'created', 'value': 42});
        events.success({
          'playerId': 7,
          'type': 'firstFrame',
          'value': true,
        });
        await Future<void>.delayed(Duration.zero);
        return {'playerId': 7, 'textureId': -1};
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, null);
    });

    final player = NativePlayer();
    expect(await player.create('https://example.com/video.mp4', ''), 42);
    expect(player.firstFrameRendered, isTrue);
    final errorResult = expectLater(
      player.errorStream,
      emits('decoder failed'),
    );
    final events = await streamReady.future;
    events.success({
      'playerId': 7,
      'type': 'error',
      'value': 'decoder failed',
    });
    await errorResult;
    expect(player.errorMessage, 'decoder failed');
    await expectLater(player.waitForFirstFrame(), throwsStateError);
    await player.dispose();
    await NativePlayer.resetEventListenerForTesting();
  });
}
