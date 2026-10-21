import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../media/media_item.dart';
import '../../mpv/mpv.dart';
import '../../utils/app_logger.dart';
import '../settings_service.dart';
import 'jimaku_client.dart';
import 'jimaku_service.dart';

/// Remembers which Jimaku subtitle was picked for an item and loads it again
/// the next time that item plays. The file is kept in the app support folder,
/// so replays work offline; if it was removed, it is downloaded again from the
/// remembered Jimaku URL.
class JimakuMemory {
  JimakuMemory._();

  /// Credential-adjacent runtime state, so kept out of settings export/reset.
  static const _pref = NullableStringPref('jimaku_remembered_subtitles');

  /// Track title prefix that marks a subtitle as loaded from Jimaku.
  static const titlePrefix = 'Jimaku: ';

  static const _maxItems = 1000;

  static final Set<String> _restoring = {};

  static String trackTitle(String fileName) => '$titlePrefix$fileName';

  static bool isJimakuTrack(SubtitleTrack track) => track.title?.startsWith(titlePrefix) ?? false;

  static String? _keyFor(MediaItem item) {
    final serverId = item.serverId;
    if (serverId == null || serverId.isEmpty || item.id.isEmpty) return null;
    return '$serverId:${item.id}';
  }

  static Map<String, dynamic> _readAll() {
    final raw = SettingsService.instanceOrNull?.read(_pref);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeAll(Map<String, dynamic> all) async {
    final settings = await SettingsService.getInstance();
    await settings.write(_pref, all.isEmpty ? null : jsonEncode(all));
  }

  static Future<Directory> _dirFor(String key) async {
    final base = await getApplicationSupportDirectory();
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return Directory('${base.path}${Platform.pathSeparator}jimaku_subtitles${Platform.pathSeparator}$safe');
  }

  /// Stores [subtitle] (picked from Jimaku [source]) as [item]'s subtitle and
  /// returns the path of the kept copy, which is what the player should load.
  static Future<String> remember(MediaItem item, JimakuFile source, File subtitle) async {
    final key = _keyFor(item);
    if (key == null) return subtitle.path;

    final name = subtitle.uri.pathSegments.last;
    final dir = await _dirFor(key);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final kept = await subtitle.copy('${dir.path}${Platform.pathSeparator}$name');

    final all = _readAll();
    all[key] = {
      'path': kept.path,
      'name': name,
      'sourceName': source.name,
      'sourceUrl': source.url,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
    };
    while (all.length > _maxItems) {
      final oldest = all.entries.reduce(
        (a, b) => '${(a.value as Map)['savedAt']}'.compareTo('${(b.value as Map)['savedAt']}') <= 0 ? a : b,
      );
      all.remove(oldest.key);
      unawaited(_deleteDir(oldest.key));
    }
    await _writeAll(all);
    return kept.path;
  }

  static Future<void> forget(MediaItem item) async {
    final key = _keyFor(item);
    if (key == null) return;
    final all = _readAll();
    if (all.remove(key) == null) return;
    await _writeAll(all);
    await _deleteDir(key);
  }

  static Future<void> _deleteDir(String key) async {
    try {
      final dir = await _dirFor(key);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// A subtitle the user picked by hand replaces the remembered Jimaku file,
  /// unless it is a Jimaku track itself. Picking Off forgets it too.
  static Future<void> onUserPickedSubtitle(MediaItem item, SubtitleTrack track) async {
    if (isJimakuTrack(track)) return;
    await forget(item);
  }

  /// Loads and selects [item]'s remembered Jimaku subtitle, if it has one.
  /// Safe to call after every track-selection pass: an already-loaded track
  /// is only re-selected, never added twice.
  static Future<void> restore(Player player, MediaItem item, {required bool Function() isActive}) async {
    if (player.playerType != 'mpv') return;
    final key = _keyFor(item);
    if (key == null || _restoring.contains(key)) return;
    final entry = _readAll()[key];
    if (entry is! Map) return;

    _restoring.add(key);
    try {
      final name = entry['name'] as String;
      final title = trackTitle(name);

      for (final track in player.state.tracks.subtitle) {
        if (track.title == title) {
          if (player.state.track.subtitle?.id != track.id && isActive()) await player.selectSubtitleTrack(track);
          return;
        }
      }

      var path = entry['path'] as String;
      if (!await File(path).exists()) {
        final redownloaded = await _redownload(item, entry);
        if (redownloaded == null) return;
        path = redownloaded;
      }
      if (!isActive()) return;
      await player.command(['sub-add', path, 'select', title, 'ja']);
      appLogger.i('Jimaku: restored remembered subtitle $name');
    } catch (e) {
      appLogger.w('Jimaku: could not restore remembered subtitle', error: e);
    } finally {
      _restoring.remove(key);
    }
  }

  static Future<String?> _redownload(MediaItem item, Map entry) async {
    final apiKey = JimakuService.readApiKey();
    final url = entry['sourceUrl'] as String?;
    final sourceName = entry['sourceName'] as String?;
    if (apiKey == null || url == null || sourceName == null) return null;

    final jimaku = JimakuClient(apiKey);
    try {
      final source = JimakuFile(name: sourceName, url: url, size: 0);
      final files = await JimakuService.fetchSubtitleFiles(jimaku, source);
      if (files.isEmpty) return null;
      final wanted = entry['name'] as String;
      final picked = files.firstWhere((f) => f.uri.pathSegments.last == wanted, orElse: () => files.first);
      return await remember(item, source, picked);
    } finally {
      jimaku.close();
    }
  }
}
