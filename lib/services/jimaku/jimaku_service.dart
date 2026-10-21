import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../base_shared_preferences_service.dart';
import '../settings_service.dart';
import '../trackers/tracker_id_resolver.dart';
import 'jimaku_client.dart';

/// Glue between a playing [MediaItem] and Jimaku: the API key setting, the
/// item → entry lookup, and turning a downloaded file into subtitle files on
/// disk that mpv can `sub-add`.
class JimakuService {
  JimakuService._();

  /// Kept out of [SettingsService]'s reset/export groups on purpose: it is a
  /// credential, like the tracker tokens.
  static const apiKey = NullableStringPref('jimaku_api_key');

  static const subtitleExtensions = {'ass', 'ssa', 'srt', 'vtt', 'sub'};
  static const supportedArchiveExtensions = {'zip'};
  static const unsupportedArchiveExtensions = {'rar', '7z'};

  static String? readApiKey() {
    final key = SettingsService.instanceOrNull?.read(apiKey)?.trim();
    return key == null || key.isEmpty ? null : key;
  }

  static bool get isConfigured => readApiKey() != null;

  static bool isUsable(JimakuFile file) =>
      subtitleExtensions.contains(file.extension) || supportedArchiveExtensions.contains(file.extension);

  /// Finds the Jimaku entries for [item]: AniList id first (via Plezy's Fribb
  /// mapping), then TMDB id, then a fuzzy title search. [episode] is the
  /// number to filter files by — AniList-relative when the anime mapping
  /// produced one, the server's own episode index otherwise.
  static Future<JimakuLookup> lookup(JimakuClient jimaku, MediaServerClient server, MediaItem item) async {
    final isEpisode = item.kind == MediaKind.episode;
    final title = (isEpisode ? item.grandparentTitle : item.title) ?? item.title ?? '';

    TrackerIds? ids;
    try {
      final resolver = TrackerIdResolver(server);
      ids = isEpisode
          ? await resolver.resolveShowForEpisode(item, includeAnimeProgress: false)
          : await resolver.resolveForMovie(item.id);
    } catch (_) {
      // No ids just means falling through to the title search.
    }

    final episode = isEpisode ? (ids?.animeEpisodeNumber ?? item.index) : null;
    final anilistId = ids?.anime?.anilist;
    final tmdb = ids?.external.tmdb;

    if (anilistId != null) {
      final entries = await jimaku.searchEntries(anilistId: anilistId);
      if (entries.isNotEmpty) return JimakuLookup(entries: entries, episode: episode, query: title);
    }
    if (tmdb != null) {
      final entries = await jimaku.searchEntries(tmdbId: '${isEpisode ? 'tv' : 'movie'}:$tmdb');
      if (entries.isNotEmpty) return JimakuLookup(entries: entries, episode: episode, query: title);
    }
    final entries = title.isEmpty ? const <JimakuEntry>[] : await jimaku.searchEntries(query: title);
    return JimakuLookup(entries: entries, episode: episode, query: title);
  }

  /// Downloads [file] and writes every subtitle it holds to a temp folder.
  /// Archives are unpacked; when [episode] is set and an archive holds several
  /// subtitles, the ones whose name matches that episode come first.
  static Future<List<File>> fetchSubtitleFiles(JimakuClient jimaku, JimakuFile file, {int? episode}) async {
    final bytes = await jimaku.download(file);
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}plezy_jimaku');
    await dir.create(recursive: true);

    final named = <({String name, Uint8List bytes})>[];
    if (supportedArchiveExtensions.contains(file.extension)) {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        final name = entry.name.split(RegExp(r'[\\/]')).last;
        if (!subtitleExtensions.contains(_extensionOf(name))) continue;
        named.add((name: name, bytes: entry.content));
      }
    } else {
      named.add((name: file.name, bytes: bytes));
    }

    if (episode != null && named.length > 1) {
      final matching = named.where((n) => matchesEpisode(n.name, episode)).toList();
      if (matching.isNotEmpty) {
        named
          ..removeWhere(matching.contains)
          ..insertAll(0, matching);
      }
    }

    final written = <File>[];
    for (final n in named) {
      final out = File('${dir.path}${Platform.pathSeparator}${_safeName(n.name)}');
      await out.writeAsBytes(n.bytes, flush: true);
      written.add(out);
    }
    return written;
  }

  /// Loose filename check for "episode N": `E05`, `第5話`, ` - 05`, `[05]`, `_05.`
  /// and similar, without matching the 5 inside `1080p` or `x265`.
  static bool matchesEpisode(String name, int episode) {
    final n = '0*$episode';
    final patterns = [
      RegExp('(?:^|[^a-z])(?:e|ep|episode)\\s*$n(?![0-9])', caseSensitive: false),
      RegExp('第\\s*$n\\s*[話话集]'),
      RegExp('(?:^|[\\s_\\-\\[\\(])$n(?:v\\d)?(?=[\\s_\\-\\]\\)\\.])', caseSensitive: false),
    ];
    return patterns.any((p) => p.hasMatch(name));
  }

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static String _safeName(String name) => name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
}

class JimakuLookup {
  final List<JimakuEntry> entries;
  final int? episode;
  final String query;

  const JimakuLookup({required this.entries, required this.episode, required this.query});
}
