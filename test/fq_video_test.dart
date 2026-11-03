import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shortplay/config/api_config.dart';
import 'package:shortplay/models/fq_video.dart';
import 'package:shortplay/services/api_client.dart';

void main() {
  test('parses nested video metadata with numeric strings and direct key', () {
    final item = FqVideoItem.fromJson({
      'main_url': 'https://cdn.example/video.mp4',
      'video_meta': {
        'definition': '1080p',
        'vwidth': '1920',
        'vheight': '1080',
        'bitrate': '2400000',
        'codec_type': 'h264',
      },
      'encrypt_info': {'spade_a': 'encrypted-key', 'kid': 'kid'},
      'decrypt_key': '0123456789abcdef0123456789abcdef',
      'expire_time': '1790000000',
      'cacheable': '0',
    });

    expect(item.url, 'https://cdn.example/video.mp4');
    expect(item.width, 1920);
    expect(item.height, 1080);
    expect(item.bitrate, 2400000);
    expect(item.spadeA, 'encrypted-key');
    expect(item.decryptKey, '0123456789abcdef0123456789abcdef');
    expect(item.expireTime, 1790000000);
    expect(item.cacheable, isFalse);
  });

  test('decodes an unpadded URL-safe base64 video URL', () {
    const url = 'https://cdn.example/video.mp4?token=short';
    final encoded = base64Url.encode(utf8.encode(url)).replaceAll('=', '');

    final item = FqVideoItem.fromJson({
      'main_url': encoded,
      'definition': '720p',
      'vwidth': 1280.0,
      'vheight': '720',
      'spade_a': 'encrypted-key',
    });

    expect(item.url, url);
    expect(item.width, 1280);
    expect(item.height, 720);
  });

  test('parses server stream maps and numeric-string response codes', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.uri.path, ApiConfig.algorithmVideo);
          expect(options.data, {'video_id': 'episode-id'});
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'code': '0',
                'data': {
                  'streams': [
                    {
                      'url': 'https://cdn.example/video.mp4',
                      'definition': '1080p',
                      'width': '1920',
                      'height': '1080',
                      'bitrate': '2400000',
                      'decrypt_key': '0123456789abcdef0123456789abcdef',
                      'codec_type': 'h264',
                    },
                  ],
                },
              },
            ),
          );
        },
      ),
    );

    final videos = await ApiClient(dio: dio).fetchFqVideoModel('episode-id');

    expect(videos, hasLength(1));
    expect(videos.single.url, 'https://cdn.example/video.mp4');
    expect(videos.single.width, 1920);
    expect(
      selectBestPlayableFqVideo(videos).decryptKey,
      '0123456789abcdef0123456789abcdef',
    );
  });
}
