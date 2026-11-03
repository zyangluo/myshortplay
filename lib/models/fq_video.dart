import 'dart:convert';

class FqVideoItem {
  FqVideoItem({
    required this.url,
    required this.definition,
    required this.width,
    required this.height,
    required this.bitrate,
    required this.spadeA,
    required this.kid,
    required this.codec,
    this.decryptKey = '',
    this.expireTime,
    this.cacheable = true,
    this.posterUrl = '',
  });

  final String url;
  final String definition;
  final int width;
  final int height;
  final int bitrate;
  final String spadeA;
  final String kid;
  final String codec;
  final String decryptKey;
  final int? expireTime;
  final bool cacheable;
  String posterUrl;

  factory FqVideoItem.fromJson(Map<String, dynamic> json) {
    final meta = _asStringMap(json['video_meta']);
    final enc = _asStringMap(json['encrypt_info']);
    final directKey = _firstString([
      json['decrypt_key'],
      json['key'],
      enc?['decrypt_key'],
      enc?['key'],
    ]);

    if (meta != null) {
      return FqVideoItem(
        url: _decodeUrl(json['main_url']),
        definition: meta['definition']?.toString() ?? '',
        width: _asInt(meta['vwidth']),
        height: _asInt(meta['vheight']),
        bitrate: _asInt(meta['bitrate']),
        spadeA: enc?['spade_a']?.toString() ?? '',
        kid: enc?['kid']?.toString() ?? '',
        codec: meta['codec_type']?.toString() ?? '',
        decryptKey: directKey,
        expireTime: _asNullableInt(
          json['expire_time'] ??
              json['expires_at'] ??
              enc?['expire_time'] ??
              meta['expire_time'],
        ),
        cacheable: _asBool(json['cacheable'] ?? meta['cacheable']),
      );
    }

    // Format B: flat fields, main_url is base64 (object format)
    return FqVideoItem(
      url: _decodeUrl(json['main_url'] ?? json['url']),
      definition: json['definition']?.toString() ?? '',
      width: _asInt(json['vwidth'] ?? json['width']),
      height: _asInt(json['vheight'] ?? json['height']),
      bitrate: _asInt(json['bitrate']),
      spadeA: json['spade_a']?.toString() ?? '',
      kid: json['kid']?.toString() ?? '',
      codec: json['codec_type']?.toString() ?? '',
      decryptKey: directKey,
      expireTime: _asNullableInt(json['expire_time'] ?? json['expires_at']),
      cacheable: _asBool(json['cacheable']),
    );
  }
}

bool isValidFqDecryptKey(String value) =>
    RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(value);

FqVideoItem selectBestPlayableFqVideo(List<FqVideoItem> items) {
  final playable = items.where((item) {
    final uri = Uri.tryParse(item.url);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        (isValidFqDecryptKey(item.decryptKey) || item.spadeA.isNotEmpty) &&
        !const {'bytevc2', 'bvc2'}.contains(item.codec.toLowerCase());
  }).toList();
  if (playable.isEmpty) {
    throw const FormatException('没有可播放的视频地址');
  }

  int qualityRank(FqVideoItem item) {
    final definition = item.definition.toLowerCase();
    if (definition.contains('1080')) return 3;
    if (definition.contains('720')) return 2;
    if (item.height >= 1080) return 3;
    if (item.height >= 720) return 2;
    return 1;
  }

  playable.sort((a, b) {
    final quality = qualityRank(b).compareTo(qualityRank(a));
    return quality != 0 ? quality : b.bitrate.compareTo(a.bitrate);
  });
  return playable.first;
}

Map<String, dynamic>? _asStringMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _asNullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final normalized = value?.toString().toLowerCase();
  return normalized != 'false' && normalized != '0';
}

String _firstString(List<Object?> values) {
  for (final value in values) {
    final candidate = value?.toString().trim() ?? '';
    if (candidate.isNotEmpty) return candidate;
  }
  return '';
}

String _decodeUrl(Object? rawValue) {
  final raw = rawValue?.toString().trim() ?? '';
  if (raw.isEmpty || raw.startsWith('http://') || raw.startsWith('https://')) {
    return raw;
  }

  final normalized = raw.replaceAll('-', '+').replaceAll('_', '/');
  final padded = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
  try {
    final decoded = utf8.decode(base64Decode(padded)).trim();
    final uri = Uri.tryParse(decoded);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty) {
      return decoded;
    }
  } on FormatException {
    // Keep the original value so the caller can report an invalid URL.
  }
  return raw;
}
