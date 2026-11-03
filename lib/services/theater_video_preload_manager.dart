import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/episode.dart';
import '../models/fq_video.dart';
import 'api_client.dart';
import 'crypto_native_channel.dart';

class TheaterVideoPreloadManager {
  TheaterVideoPreloadManager({
    required this.apiClient,
  });

  final ApiClient apiClient;

  final Map<String, String> _preloadedUrls = {};
  final Map<String, String> _sourceUrls = {};
  final Map<String, DateTime> _preloadedExpiries = {};
  final Set<int> _preloadingEpisodeIndexes = {};
  final Set<String> _prewarmedVideoIds = {};
  final Set<String> _headerPrewarmedVideoIds = {};
  Future<void> _prewarmQueue = Future<void>.value();

  void clear() {
    _preloadedUrls.clear();
    _sourceUrls.clear();
    _preloadedExpiries.clear();
    _preloadingEpisodeIndexes.clear();
    _prewarmedVideoIds.clear();
    _headerPrewarmedVideoIds.clear();
  }

  void trimCache({
    required List<Episode> episodes,
    required int currentIndex,
    int previousCount = 1,
    int nextCount = 3,
  }) {
    final first = (currentIndex - previousCount).clamp(0, episodes.length);
    final last = (currentIndex + nextCount + 1).clamp(0, episodes.length);
    final retainedIds = episodes
        .sublist(first, last)
        .map((episode) => episode.url.trim())
        .where((videoId) => videoId.isNotEmpty)
        .toSet();

    _preloadedUrls.removeWhere(
      (videoId, _) => !retainedIds.contains(videoId),
    );
    _preloadedExpiries.removeWhere(
      (videoId, _) => !retainedIds.contains(videoId),
    );
    _sourceUrls.removeWhere((videoId, _) => !retainedIds.contains(videoId));
    _prewarmedVideoIds.removeWhere(
      (videoId) => !retainedIds.contains(videoId),
    );
    _headerPrewarmedVideoIds.removeWhere(
      (videoId) => !retainedIds.contains(videoId),
    );
  }

  bool isNextEpisodeReady({
    required List<Episode> episodes,
    required int currentIndex,
  }) {
    final nextIndex = currentIndex + 1;
    if (nextIndex >= episodes.length) return true;
    final videoId = episodes[nextIndex].url.trim();
    return videoId.isNotEmpty && _cachedUrl(videoId) != null;
  }

  Future<String> resolvePlayUrl(
    String videoId, {
    required int episodeIndex,
    int maxRetries = 3,
  }) async {
    final cachedUrl = _cachedUrl(videoId);
    if (cachedUrl != null) {
      debugPrint('使用预加载缓存，秒开');
      return cachedUrl;
    }

    final resolved =
        await _resolveVideoWithRetry(videoId, maxRetries: maxRetries);
    _rememberResolved(videoId, resolved);
    debugPrint('播放地址就绪');
    return resolved.proxyUrl;
  }

  Future<void> preloadEpisode({
    required List<Episode> episodes,
    required int currentIndex,
    required int targetIndex,
    required bool Function() isStillCurrent,
    VoidCallback? onNextEpisodeReady,
  }) async {
    if (targetIndex < 0 || targetIndex >= episodes.length) return;
    if (_preloadingEpisodeIndexes.contains(targetIndex)) return;

    final videoId = episodes[targetIndex].url.trim();
    if (videoId.isEmpty || _cachedUrl(videoId) != null) return;

    _preloadingEpisodeIndexes.add(targetIndex);
    try {
      if (!isStillCurrent()) return;
      final resolved = await _resolveVideoWithRetry(videoId);
      if (!isStillCurrent()) return;

      _rememberResolved(videoId, resolved);
      // 串行预热，避免并发槽位满时直接丢掉预热任务。
      await _enqueuePrewarm(() async {
        if (!isStillCurrent() || _prewarmedVideoIds.contains(videoId)) return;
        final status = await CryptoNativeChannel.instance
            .prewarm(resolved.sourceUrl, resolved.key);
        if (status == 0) {
          _prewarmedVideoIds.add(videoId);
        } else {
          debugPrint('native prewarm 返回非零状态: $status (第${targetIndex + 1}集)');
        }
      });
      debugPrint('剧集数据预缓存完成: 第${targetIndex + 1}集');

      if (targetIndex == currentIndex + 1) {
        onNextEpisodeReady?.call();
      }
    } catch (error) {
      debugPrint('第${targetIndex + 1}集预缓存失败: $error');
    } finally {
      _preloadingEpisodeIndexes.remove(targetIndex);
    }
  }

  // 带重试的视频解析：首集播放与预加载共用，消除“首集有重试、预加载无重试”
  // 的不对称——慢网下预加载也能像首集一样重试兜底，不会一次超时就放弃。
  Future<void> preloadEpisodeHeaderOnly({
    required List<Episode> episodes,
    required int currentIndex,
    required int targetIndex,
    required bool Function() isStillCurrent,
  }) async {
    if (targetIndex < 0 || targetIndex >= episodes.length) return;
    if (_preloadingEpisodeIndexes.contains(targetIndex)) return;

    final videoId = episodes[targetIndex].url.trim();
    if (videoId.isEmpty || _cachedUrl(videoId) != null) return;

    _preloadingEpisodeIndexes.add(targetIndex);
    try {
      if (!isStillCurrent()) return;
      final resolved = await _resolveVideoWithRetry(videoId);
      if (!isStillCurrent()) return;

      _rememberResolved(videoId, resolved);
      await _enqueuePrewarm(() async {
        if (!isStillCurrent() ||
            _prewarmedVideoIds.contains(videoId) ||
            _headerPrewarmedVideoIds.contains(videoId)) {
          return;
        }
        final status = await CryptoNativeChannel.instance
            .prewarmHeaderOnly(resolved.sourceUrl, resolved.key);
        if (status == 0) {
          _headerPrewarmedVideoIds.add(videoId);
        } else {
          debugPrint(
            'native prewarmHeaderOnly 返回非零: $status (第${targetIndex + 1}集)',
          );
        }
      });
      debugPrint('剧集头部数据预缓存完成: 第${targetIndex + 1}集');
    } catch (error) {
      debugPrint('预加载头部失败 第${targetIndex + 1}集: $error');
    } finally {
      _preloadingEpisodeIndexes.remove(targetIndex);
    }
  }

  Future<void> seedMdat({
    required List<Episode> episodes,
    required int targetIndex,
  }) async {
    if (targetIndex < 0 || targetIndex >= episodes.length) return;
    final videoId = episodes[targetIndex].url.trim();
    if (videoId.isEmpty) return;

    final sourceUrl = _sourceUrls[videoId];
    if (sourceUrl == null) return;

    try {
      final status =
          await CryptoNativeChannel.instance.prewarmSeedMdat(sourceUrl);
      if (status != 0) {
        debugPrint(
            'native prewarmSeedMdat 返回非零: $status (第${targetIndex + 1}集)');
      } else {
        debugPrint('剧集mdat种子补充完成: 第${targetIndex + 1}集');
      }
    } catch (error) {
      debugPrint('seedMdat失败 第${targetIndex + 1}集: $error');
    }
  }

  Future<void> _enqueuePrewarm(Future<void> Function() task) {
    final queued = _prewarmQueue.then((_) => task());
    _prewarmQueue = queued.catchError((error) {
      debugPrint('native prewarm 任务失败: $error');
    });
    return queued;
  }

  String? _cachedUrl(String videoId) {
    final url = _preloadedUrls[videoId];
    if (url == null) return null;
    final expiresAt = _preloadedExpiries[videoId];
    if (expiresAt != null &&
        !DateTime.now()
            .isBefore(expiresAt.subtract(const Duration(seconds: 30)))) {
      _preloadedUrls.remove(videoId);
      _preloadedExpiries.remove(videoId);
      _sourceUrls.remove(videoId);
      _prewarmedVideoIds.remove(videoId);
      _headerPrewarmedVideoIds.remove(videoId);
      return null;
    }
    return url;
  }

  void _rememberResolved(String videoId, _ResolvedTheaterVideo resolved) {
    if (_sourceUrls[videoId] != resolved.sourceUrl) {
      _prewarmedVideoIds.remove(videoId);
      _headerPrewarmedVideoIds.remove(videoId);
    }
    _sourceUrls[videoId] = resolved.sourceUrl;
    if (!resolved.cacheable) {
      _preloadedUrls.remove(videoId);
      _preloadedExpiries.remove(videoId);
      _prewarmedVideoIds.remove(videoId);
      _headerPrewarmedVideoIds.remove(videoId);
      return;
    }
    _preloadedUrls[videoId] = resolved.proxyUrl;
    final expiresAt = resolved.expiresAt;
    if (expiresAt != null) {
      _preloadedExpiries[videoId] = expiresAt;
    } else {
      _preloadedExpiries.remove(videoId);
    }
  }

  Future<_ResolvedTheaterVideo> _resolveVideoWithRetry(
    String videoId, {
    int maxRetries = 3,
  }) async {
    int attempt = 0;
    while (attempt < maxRetries) {
      try {
        attempt++;
        return await _resolveVideo(videoId);
      } on TimeoutException catch (error) {
        debugPrint('解析视频超时 (尝试 $attempt/$maxRetries): $error');
        if (attempt >= maxRetries) rethrow;
        await Future<void>.delayed(const Duration(seconds: 1));
      } catch (error) {
        debugPrint('解析视频失败 (尝试 $attempt/$maxRetries): $error');
        if (attempt >= maxRetries) rethrow;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    throw Exception('解析视频失败：已重试$maxRetries次');
  }

  Future<_ResolvedTheaterVideo> _resolveVideo(String videoId) async {
    final videoItems = await apiClient
        .fetchFqVideoModel(videoId)
        .timeout(const Duration(seconds: 10));
    if (videoItems.isEmpty) {
      throw Exception('未获取到视频信息');
    }

    final selected = selectBestPlayableFqVideo(videoItems);
    debugPrint(
      '选择画质: ${selected.definition} ${selected.width}x${selected.height} codec=${selected.codec}',
    );

    final key = isValidFqDecryptKey(selected.decryptKey)
        ? selected.decryptKey
        : await apiClient
            .fetchDecryptKey(selected.spadeA)
            .timeout(const Duration(seconds: 5));
    if (!isValidFqDecryptKey(key)) {
      throw Exception('视频解密密钥格式无效');
    }
    final expiresAt = selected.expireTime == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            selected.expireTime! < 10000000000
                ? selected.expireTime! * 1000
                : selected.expireTime!,
          );
    if (expiresAt != null &&
        !expiresAt.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      throw Exception('视频地址已过期，请重新解析');
    }
    debugPrint('获取key成功: ${key.substring(0, 8)}...');

    // Decrypt in the player IO pipeline via the native crypto:// protocol
    // (no localhost proxy).
    final playUrl = CryptoNativeChannel.buildCryptoUrl(selected.url, key);

    return _ResolvedTheaterVideo(
      proxyUrl: playUrl,
      sourceUrl: selected.url,
      key: key,
      expiresAt: expiresAt,
      cacheable: selected.cacheable,
    );
  }
}

class _ResolvedTheaterVideo {
  const _ResolvedTheaterVideo({
    required this.proxyUrl,
    required this.sourceUrl,
    required this.key,
    required this.expiresAt,
    required this.cacheable,
  });

  final String proxyUrl;
  final String sourceUrl;
  final String key;
  final DateTime? expiresAt;
  final bool cacheable;
}
