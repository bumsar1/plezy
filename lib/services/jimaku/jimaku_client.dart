import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One Jimaku directory: a show or movie backed by an AniList or TMDB id.
class JimakuEntry {
  final int id;
  final String name;
  final String? japaneseName;
  final String? englishName;
  final int? anilistId;
  final String? tmdbId;
  final bool isMovie;

  const JimakuEntry({
    required this.id,
    required this.name,
    this.japaneseName,
    this.englishName,
    this.anilistId,
    this.tmdbId,
    this.isMovie = false,
  });

  factory JimakuEntry.fromJson(Map<String, dynamic> json) {
    final flags = json['flags'];
    return JimakuEntry(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      japaneseName: json['japanese_name'] as String?,
      englishName: json['english_name'] as String?,
      anilistId: json['anilist_id'] as int?,
      tmdbId: json['tmdb_id'] as String?,
      isMovie: flags is Map && flags['movie'] == true,
    );
  }
}

/// One downloadable file inside a [JimakuEntry]: a subtitle or an archive.
class JimakuFile {
  final String name;
  final String url;
  final int size;
  final DateTime? lastModified;

  const JimakuFile({required this.name, required this.url, required this.size, this.lastModified});

  factory JimakuFile.fromJson(Map<String, dynamic> json) => JimakuFile(
    name: json['name'] as String,
    url: json['url'] as String,
    size: (json['size'] as num?)?.toInt() ?? 0,
    lastModified: DateTime.tryParse(json['last_modified'] as String? ?? ''),
  );

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }
}

class JimakuException implements Exception {
  final int? statusCode;
  final String message;

  const JimakuException(this.message, {this.statusCode});

  bool get isUnauthorized => statusCode == 401 || statusCode == 403;
  bool get isRateLimited => statusCode == 429;

  @override
  String toString() => message;
}

/// Minimal client for the Jimaku REST API (https://jimaku.cc/api/docs).
class JimakuClient {
  static const String _host = 'jimaku.cc';
  static const String _userAgent = 'Plezy-Jimaku (https://github.com/bumsar1/plezy)';

  final String apiKey;
  final http.Client _http;

  JimakuClient(this.apiKey, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  Map<String, String> get _headers => {'Authorization': apiKey, 'User-Agent': _userAgent};

  Future<List<JimakuEntry>> searchEntries({int? anilistId, String? tmdbId, String? query, bool? anime}) async {
    final params = <String, String>{
      if (anilistId != null) 'anilist_id': '$anilistId',
      if (tmdbId != null) 'tmdb_id': tmdbId,
      if (query != null && query.isNotEmpty) 'query': query,
      if (anime != null) 'anime': '$anime',
    };
    final json = await _getJson('/api/entries/search', params);
    return [for (final e in json as List) JimakuEntry.fromJson(e as Map<String, dynamic>)];
  }

  Future<List<JimakuFile>> listFiles(int entryId, {int? episode}) async {
    final json = await _getJson('/api/entries/$entryId/files', {if (episode != null) 'episode': '$episode'});
    return [for (final f in json as List) JimakuFile.fromJson(f as Map<String, dynamic>)];
  }

  Future<Uint8List> download(JimakuFile file) async {
    final uri = Uri.parse(file.url);
    // Only Jimaku itself gets the API key.
    final headers = uri.host == _host ? _headers : {'User-Agent': _userAgent};
    final response = await _http.get(uri, headers: headers);
    _check(response);
    return response.bodyBytes;
  }

  Future<Object?> _getJson(String path, Map<String, String> params) async {
    final uri = Uri.https(_host, path, params.isEmpty ? null : params);
    final response = await _http.get(uri, headers: _headers);
    _check(response);
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  void _check(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    String message = 'HTTP ${response.statusCode}';
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is Map && body['error'] is String) message = body['error'] as String;
    } catch (_) {}
    throw JimakuException(message, statusCode: response.statusCode);
  }

  void close() => _http.close();
}
