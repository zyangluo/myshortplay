import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/api_config.dart';
import '../models/drama.dart';
import '../models/fq_video.dart';
import 'sign_interceptor.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => 'ApiException(message: $message, code: $code)';
}

class ApiClient {
  ApiClient({Dio? dio, String? baseUrl})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? ApiConfig.noveBaseUrl,
                connectTimeout: ApiConfig.connectTimeout,
                receiveTimeout: ApiConfig.receiveTimeout,
                sendTimeout: ApiConfig.sendTimeout,
              ),
            ) {
    _dio.interceptors.add(SignInterceptor());
  }

  final Dio _dio;
  final Map<String, Drama> _dramaCache = {};
  final Map<String, Future<List<FqVideoItem>>> _videoModelRequests = {};

  /// 暴露已配置 SignInterceptor 的 Dio，供 ShareLinkResolver 等复用同一签名链路。
  Dio get dio => _dio;

  Future<Drama> fetchDramaDetail(String dramaId) async {
    if (_dramaCache.containsKey(dramaId)) return _dramaCache[dramaId]!;
    final candidates = <({String path, Map<String, dynamic> query})>[
      (path: '/api/detail', query: {'id': dramaId}),
      (path: '/api/detail', query: {'series_id': dramaId}),
      (path: '/api/drama_detail', query: {'id': dramaId}),
      (path: '/api/drama', query: {'id': dramaId}),
    ];

    Object? lastError;
    for (final candidate in candidates) {
      try {
        final response = await _request(() => _dio.get(
              candidate.path,
              queryParameters: candidate.query,
            ));
        final payload = _decode(response);
        final data = payload['data'];
        Drama? drama;
        if (data is Map<String, dynamic>) drama = Drama.fromJson(data);
        if (data is Map) drama = Drama.fromJson(data.cast<String, dynamic>());
        final nested = payload['drama'];
        if (nested is Map<String, dynamic>) drama = Drama.fromJson(nested);
        if (nested is Map)
          drama = Drama.fromJson(nested.cast<String, dynamic>());
        if (drama != null) {
          _dramaCache[dramaId] = drama;
          return drama;
        }
        throw ApiException('解析接口返回失败');
      } catch (error) {
        lastError = error;
      }
    }

    if (lastError is ApiException) throw lastError;
    throw ApiException('请求失败');
  }

  Future<({List<Drama> dramas, bool hasMore})> search(
    String keyword, {
    int offset = 0,
  }) async {
    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveSearch,
      {
        'key': keyword,
        'tab_type': '11',
        if (offset > 0) 'offset': offset.toString(),
      },
    );
    final response = await _request(() => _dio.getUri(uri));
    final decoded = _decode(response);
    final searchTabs = decoded['search_tabs'] as List? ?? [];
    final dramaTab = searchTabs.firstWhere(
      (tab) => tab is Map && (tab['tab_type'] == 19 || tab['tab_type'] == 11),
      orElse: () => null,
    );
    if (dramaTab == null) return (dramas: <Drama>[], hasMore: false);
    final hasMore = (dramaTab as Map)['has_more'] == true;
    final data = dramaTab['data'] as List? ?? [];
    final dramas = <Drama>[];
    for (final item in data) {
      if (item is! Map) continue;
      final videoData = (item['video_data'] as List?)?.firstOrNull;
      if (videoData is! Map) continue;
      dramas.add(
        Drama.fromTheaterSearchJson(videoData.cast<String, dynamic>()),
      );
    }
    return (dramas: dramas, hasMore: hasMore);
  }

  /// Resolve playable theater streams through the server and coalesce concurrent
  /// lookups for the same episode.
  Future<List<FqVideoItem>> fetchFqVideoModel(String videoId) {
    final normalizedId = videoId.trim();
    if (normalizedId.isEmpty) {
      return Future.error(ApiException('视频ID为空'));
    }
    final pending = _videoModelRequests[normalizedId];
    if (pending != null) return pending;

    final cancelToken = CancelToken();
    final request =
        _fetchTheaterVideoStreams(normalizedId, cancelToken).timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        cancelToken.cancel('视频解析超时');
        throw TimeoutException('视频解析超时');
      },
    );
    _videoModelRequests[normalizedId] = request;
    return request.whenComplete(() {
      if (identical(_videoModelRequests[normalizedId], request)) {
        _videoModelRequests.remove(normalizedId);
      }
    });
  }

  Future<List<FqVideoItem>> _fetchTheaterVideoStreams(
    String videoId,
    CancelToken cancelToken,
  ) async {
    final response = await _request(() => _dio.post(
          '${ApiConfig.noveBaseUrl}${ApiConfig.algorithmVideo}',
          data: {'video_id': videoId},
          cancelToken: cancelToken,
          options: Options(headers: {'Content-Type': 'application/json'}),
        ));
    final decoded = _asJsonMap(response.data);
    if (_asInt(decoded['code']) != 0) {
      throw ApiException(
        decoded['message']?.toString() ??
            decoded['msg']?.toString() ??
            '解析短剧视频失败',
      );
    }

    final data = _asJsonMap(decoded['data']);
    var streams = data['streams'] ?? data['video_list'];
    var posterUrl = data['poster_url']?.toString() ?? '';
    if (streams == null && data['video_model'] != null) {
      final rawModel = data['video_model'];
      final model = rawModel is Map
          ? rawModel.map((key, value) => MapEntry(key.toString(), value))
          : _asJsonMap(jsonDecode(rawModel.toString()));
      streams = model['video_list'];
      posterUrl = model['poster_url']?.toString() ?? posterUrl;
    }
    if (streams is String) {
      streams = jsonDecode(streams);
    }

    final entries = switch (streams) {
      List values => values.whereType<Map>().map(_asJsonMap).toList(),
      Map values => values.values.whereType<Map>().map(_asJsonMap).toList(),
      _ => <Map<String, dynamic>>[],
    };
    final items = entries
        .map(FqVideoItem.fromJson)
        .where(
          (video) =>
              video.url.isNotEmpty &&
              (isValidFqDecryptKey(video.decryptKey) ||
                  video.spadeA.isNotEmpty),
        )
        .toList();
    for (final item in items) {
      item.posterUrl = posterUrl;
    }
    if (items.isEmpty) {
      throw ApiException('解析结果中没有可播放的视频流');
    }
    return items;
  }

  /// 请求服务端解密spade_a获取AES key
  Future<String> fetchDecryptKey(String spadeA) async {
    final response = await _request(() => _dio.post(
          '${ApiConfig.noveBaseUrl}${ApiConfig.algorithmSpade}',
          data: {'spade_a': spadeA},
          options: Options(headers: {'Content-Type': 'application/json'}),
        ));
    final decoded = _asJsonMap(response.data);
    if (_asInt(decoded['code']) != 0) {
      throw ApiException('解密key失败');
    }
    final data = _asJsonMap(decoded['data']);
    final key = data['key']?.toString().trim() ?? '';
    if (!isValidFqDecryptKey(key)) {
      throw ApiException('无效的解密key');
    }
    return key;
  }

  /// 解析分享口令：把整段剪贴板文本交给分享解析接口，
  /// 服务端返回 {videoid, text, vid}。返回作品 ID、剧名和集视频 ID，失败抛 ApiException。
  Future<({String videoId, String? title, String? episodeId})> fetchShareInfo(
    String text,
  ) async {
    final response = await _request(() => _dio.post(
          ApiConfig.myNoveShare,
          data: {'text': text},
          options: Options(headers: {'Content-Type': 'application/json'}),
        ));
    final decoded = _asJsonMap(response.data);
    if (decoded['code'] != 0) {
      throw ApiException(
        decoded['message']?.toString() ?? '解析分享链接失败',
        code: decoded['code'] is int ? decoded['code'] as int : null,
      );
    }
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    final videoId = data['videoid']?.toString() ?? '';
    if (videoId.isEmpty) throw ApiException('未解析到视频ID');
    final title = data['text']?.toString();
    final episodeId = (data['vid'] ?? decoded['vid'])?.toString();
    return (
      videoId: videoId,
      title: title?.isNotEmpty == true ? title : null,
      episodeId: episodeId?.isNotEmpty == true ? episodeId : null,
    );
  }

  Future<TheaterEpisodesResult> fetchTheaterEpisodes(String seriesId) async {
    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveDirectory,
      {'book_id': seriesId},
    );
    final response = await _request(() => _dio.getUri(uri));
    final decoded = _decode(response);
    final data = _asJsonMap(decoded['data']);
    final lists = data['lists'] as List? ?? [];
    final chapters = lists.whereType<Map>().map((item) {
      final itemId = item['item_id']?.toString() ?? '';
      final title = item['title']?.toString() ?? '';
      final index = RegExp(r'\d+').firstMatch(title)?.group(0) ?? '0';
      return TheaterChapter(
        itemId: itemId,
        title: title,
        realChapterOrder: index,
      );
    }).toList(growable: false);
    return TheaterEpisodesResult(
      allItemIds: chapters.map((c) => c.itemId).toList(),
      chapters: chapters,
    );
  }

  Future<HomePageResult> fetchHomePage({int? offset, String? sessionId}) async {
    final params = <String, String>{};
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    if (sessionId != null && sessionId.isNotEmpty)
      params['session_id'] = sessionId;

    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveHome,
      params,
    );
    final response = await _request(() => _dio.getUri(uri));
    final decoded = _decode(response);
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    return HomePageResult.fromJson(data);
  }

  // rankType: 'hotplay' | 'recommend' | 'rising' | 'newplay'
  Future<RankListResult> fetchRankList({
    required String rankType,
    String type = 'all',
    String? cellGender,
    int? offset,
    String? sessionId,
  }) async {
    final params = <String, String>{'rank': rankType, 'type': type};
    if (cellGender != null) params['cell_gender'] = cellGender;
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    if (sessionId != null && sessionId.isNotEmpty)
      params['session_id'] = sessionId;

    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveRank,
      params,
    );
    final response = await _request(() => _dio.getUri(uri));
    final decoded = _decode(response);
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    return RankListResult.fromJson(data);
  }

  Future<NewPlayResult> fetchNewPlay({
    int? offset,
    String? sessionId,
    String? cellGender,
  }) async {
    final params = <String, String>{'rank': 'newplay'};
    if (cellGender != null) params['cell_gender'] = cellGender;
    if (offset != null && offset > 0) params['offset'] = offset.toString();
    if (sessionId != null && sessionId.isNotEmpty)
      params['session_id'] = sessionId;

    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.noveRank,
      params,
    );
    final response = await _request(() => _dio.getUri(uri));
    final decoded = _decode(response);
    final data = decoded['data'] as Map<String, dynamic>? ?? {};
    return NewPlayResult.fromJson(data);
  }

  /// 获取滚动公告列表。X-Dusa 由 SignInterceptor 对 api.weeou.com 自动签名。
  Future<List<String>> fetchNotice() async {
    final uri = Uri.http(
      Uri.parse(ApiConfig.noveBaseUrl).host,
      ApiConfig.notice,
    );
    final response = await _request(() => _dio.getUri(uri));
    final decoded = _decode(response);
    final data = decoded['data'] as List? ?? [];
    return data.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
  }

  Map<String, dynamic> _decode(Response response) {
    if (response.statusCode == null ||
        response.statusCode! < 200 ||
        response.statusCode! >= 300) {
      throw ApiException('请求失败 (${response.statusCode})');
    }
    try {
      final decoded = _asJsonMap(response.data);
      final code = decoded['code'] == null ? 0 : _asInt(decoded['code']);
      if (code != 0) {
        throw ApiException(decoded['msg']?.toString() ?? '接口异常', code: code);
      }
      return decoded;
    } catch (error) {
      if (error is ApiException) {
        rethrow;
      }
      throw ApiException('解析接口返回失败');
    }
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final body = error.response?.data;
      final serverMessage = body is Map ? body['message']?.toString() : null;
      throw ApiException(
        serverMessage?.isNotEmpty == true
            ? serverMessage!
            : '请求失败：${error.message ?? error.type.name}',
        code: status,
      );
    }
  }

  Map<String, dynamic> _asJsonMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) {
      return data.map((key, value) => MapEntry(key.toString(), value));
    }
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    }
    throw ApiException('解析接口返回失败');
  }

  int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? -1;
  }
}

class TheaterEpisodesResult {
  TheaterEpisodesResult({required this.allItemIds, required this.chapters});

  final List<String> allItemIds;
  final List<TheaterChapter> chapters;

  factory TheaterEpisodesResult.fromJson(Map<String, dynamic> json) {
    final allItemIds =
        (json['allItemIds'] as List?)?.map((e) => e.toString()).toList() ?? [];

    final chapterListWithVolume = json['chapterListWithVolume'] as List? ?? [];
    final chapters = <TheaterChapter>[];

    for (final volume in chapterListWithVolume) {
      if (volume is List) {
        for (final chapter in volume) {
          if (chapter is Map) {
            chapters.add(
              TheaterChapter.fromJson(chapter.cast<String, dynamic>()),
            );
          }
        }
      }
    }

    return TheaterEpisodesResult(allItemIds: allItemIds, chapters: chapters);
  }
}

class TheaterChapter {
  TheaterChapter({
    required this.itemId,
    required this.title,
    required this.realChapterOrder,
    this.needPay = 0,
    this.isChapterLock = false,
  });

  final String itemId;
  final String title;
  final String realChapterOrder;
  final int needPay;
  final bool isChapterLock;

  factory TheaterChapter.fromJson(Map<String, dynamic> json) {
    return TheaterChapter(
      itemId: json['itemId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      realChapterOrder: json['realChapterOrder']?.toString() ?? '',
      needPay: json['needPay'] is int ? json['needPay'] as int : 0,
      isChapterLock: json['isChapterLock'] == true,
    );
  }
}

// 首页数据结果
class HomePageResult {
  HomePageResult({
    required this.offset,
    required this.sessionId,
    required this.count,
    required this.hasMore,
    required this.nextOffset,
    required this.list,
  });

  final int offset;
  final String sessionId;
  final int count;
  final bool hasMore;
  final int nextOffset;
  final List<Drama> list;

  factory HomePageResult.fromJson(Map<String, dynamic> json) {
    final list = json['list'] as List? ?? [];
    final dramas = list
        .whereType<Map>()
        .map((item) => Drama.fromHomeJson(item.cast<String, dynamic>()))
        .toList();

    return HomePageResult(
      offset: json['offset'] is int ? json['offset'] as int : 0,
      sessionId: json['session_id']?.toString() ?? '',
      count: json['count'] is int ? json['count'] as int : 0,
      hasMore: json['has_more'] == true,
      nextOffset: json['next_offset'] is int ? json['next_offset'] as int : 0,
      list: dramas,
    );
  }
}

// 榜单数据结果
class RankListResult {
  RankListResult({
    required this.offset,
    required this.sessionId,
    required this.count,
    required this.hasMore,
    required this.nextOffset,
    required this.list,
  });

  final int offset;
  final String sessionId;
  final int count;
  final bool hasMore;
  final int nextOffset;
  final List<Drama> list;

  factory RankListResult.fromJson(Map<String, dynamic> json) {
    final list = json['list'] as List? ?? [];
    final dramas = list
        .whereType<Map>()
        .map((item) => Drama.fromHomeJson(item.cast<String, dynamic>()))
        .toList();

    return RankListResult(
      offset: json['offset'] is int ? json['offset'] as int : 0,
      sessionId: json['session_id']?.toString() ?? '',
      count: json['count'] is int ? json['count'] as int : 0,
      hasMore: json['has_more'] == true,
      nextOffset: json['next_offset'] is int ? json['next_offset'] as int : 0,
      list: dramas,
    );
  }
}

// 新剧数据结果
class NewPlayResult {
  NewPlayResult({
    required this.offset,
    required this.sessionId,
    required this.count,
    required this.hasMore,
    required this.nextOffset,
    required this.list,
  });

  final int offset;
  final String sessionId;
  final int count;
  final bool hasMore;
  final int nextOffset;
  final List<Drama> list;

  factory NewPlayResult.fromJson(Map<String, dynamic> json) {
    final list = json['list'] as List? ?? [];
    final dramas = list
        .whereType<Map>()
        .map((item) => Drama.fromHomeJson(item.cast<String, dynamic>()))
        .toList();

    return NewPlayResult(
      offset: json['offset'] is int ? json['offset'] as int : 0,
      sessionId: json['session_id']?.toString() ?? '',
      count: json['count'] is int ? json['count'] as int : 0,
      hasMore: json['has_more'] == true,
      nextOffset: json['next_offset'] is int ? json['next_offset'] as int : 0,
      list: dramas,
    );
  }
}
