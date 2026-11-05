import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../media/media_item.dart';
import '../mpv/mpv.dart';
import '../services/player_sync_offsets.dart';
import '../services/scoped_player_prefs.dart';
import 'study_ffmpeg.dart';

class StudySyncResult {
  /// The subtitle delay applied, in seconds; null when nothing was changed.
  final double? offset;
  final String message;

  const StudySyncResult(this.offset, this.message);
}

/// Lines the primary (usually Japanese, e.g. from Jimaku) subtitle up with an
/// English track of the video itself, which is timed to this exact release.
///
/// Both tracks' line start times are read with ffmpeg and the constant shift
/// that makes the most lines start together becomes `sub-delay`. For an
/// embedded English track only a window around the playhead is read, so a
/// Plex stream isn't downloaded whole.
class StudySubtitleSync {
  StudySubtitleSync._();

  static const _window = 90.0;
  static const _maxShift = 60.0;
  static const _tolerance = 0.3;
  static const _textCodecs = {'subrip', 'srt', 'ass', 'ssa', 'webvtt', 'mov_text', 'text'};

  static Future<StudySyncResult> syncToEnglish(Player player, MediaItem? item) async {
    final ffmpeg = await StudyFfmpeg.find();
    if (ffmpeg == null) return const StudySyncResult(null, 'Needs ffmpeg');

    final tracks = await _subtitleTracks(player);
    final sid = await player.getProperty('sid');
    final primary = tracks.where((t) => t.id == sid).firstOrNull;
    if (primary == null) return const StudySyncResult(null, 'No subtitle selected');
    if (!primary.isText) return const StudySyncResult(null, 'Selected subtitle is an image track');

    final english = _pickEnglish(tracks.where((t) => t.id != sid && t.isText).toList());
    if (english == null) return const StudySyncResult(null, 'No English text subtitle in this video');

    final source = await player.getProperty('path');
    final headers = StudyFfmpeg.headerArgs(await player.getProperty('http-header-fields'));
    final position = double.tryParse(await player.getProperty('time-pos') ?? '') ?? 0;

    final reference = await _starts(ffmpeg, english, source, headers, position);
    final target = await _starts(ffmpeg, primary, source, headers, null);
    if (reference == null || reference.length < 3) {
      return const StudySyncResult(null, 'Could not read the English lines');
    }
    if (target == null || target.length < 3) return const StudySyncResult(null, 'Could not read the subtitle lines');

    final best = bestOffset(reference, target);
    if (best == null) return const StudySyncResult(null, 'No matching timing found');

    final ms = (best.offset * 1000).round().clamp(
      ScopedPlayerPrefs.minimumSyncOffsetMs,
      ScopedPlayerPrefs.maximumSyncOffsetMs,
    );
    await player.setProperty(PlayerSyncOffsets.subtitleProperty, (ms / 1000).toString());
    PlayerSyncOffsets.of(player).recordApplied(PlayerSyncOffsets.subtitleProperty, ms);
    // Remembered for this episode like a manual subtitle sync.
    if (item != null) await ScopedPlayerPrefs.write(ScopedPlayerPrefs.subtitleSyncOffset, item, ms);
    final sign = ms >= 0 ? '+' : '−';
    return StudySyncResult(
      ms / 1000,
      'Shifted $sign${(ms.abs() / 1000).toStringAsFixed(2)} s · ${best.matched}/${reference.length} lines match',
    );
  }

  static Future<List<_Track>> _subtitleTracks(Player player) async {
    final count = int.tryParse(await player.getProperty('track-list/count') ?? '') ?? 0;
    final out = <_Track>[];
    for (var i = 0; i < count; i++) {
      Future<String> p(String name) async => await player.getProperty('track-list/$i/$name') ?? '';
      if (await p('type') != 'sub') continue;
      out.add(
        _Track(
          id: await p('id'),
          lang: (await p('lang')).toLowerCase(),
          title: (await p('title')).toLowerCase(),
          codec: (await p('codec')).toLowerCase(),
          forced: await p('forced') == 'yes',
          externalFile: await p('external') == 'yes' ? await p('external-filename') : null,
          ffIndex: int.tryParse(await p('ff-index')),
        ),
      );
    }
    return out;
  }

  /// A full English track rather than signs & songs or forced lines.
  static _Track? _pickEnglish(List<_Track> candidates) {
    bool isEnglish(_Track t) => t.lang.startsWith('en') || t.title.contains('english');
    bool isPartial(_Track t) => t.forced || RegExp(r'sign|song|forced|karaoke').hasMatch(t.title);
    final english = candidates.where(isEnglish).toList();
    return english.where((t) => !isPartial(t)).firstOrNull ?? english.firstOrNull;
  }

  /// Line start times in seconds. With [around] set, an embedded track is
  /// read only in a window centred there.
  static Future<List<double>?> _starts(
    String ffmpeg,
    _Track track,
    String? source,
    List<String> headers,
    double? around,
  ) async {
    final List<String> args;
    final external = track.externalFile;
    if (external != null && external.isNotEmpty) {
      args = [if (external.startsWith('http')) ...headers, '-i', external, '-map', '0:s:0'];
    } else if (source != null && track.ffIndex != null) {
      final from = around == null ? null : math.max(0.0, around - _window / 2);
      // The seek lands on a keyframe before [from], so keep the file's own
      // timestamps (-copyts) and stop at an absolute end (-to); a -t would
      // count from the keyframe, and on the input side it is ignored.
      args = [
        ...headers,
        if (from != null) ...['-ss', from.toStringAsFixed(3)],
        '-i',
        source,
        '-map',
        '0:${track.ffIndex}',
        '-copyts',
        if (from != null) ...['-to', (from + _window).toStringAsFixed(3)],
      ];
    } else {
      return null;
    }
    final srt = await StudyFfmpeg.output(ffmpeg, [...args, '-f', 'srt', 'pipe:1']);
    return srt == null ? null : parseSrtStarts(srt);
  }

  static final _timing = RegExp(r'(\d+):(\d\d):(\d\d)[,.](\d{3})\s*-->');

  /// Distinct line start times of an SRT document, sorted.
  @visibleForTesting
  static List<double> parseSrtStarts(String srt) {
    final starts = <int>{};
    for (final m in _timing.allMatches(srt)) {
      final ms = int.parse(m[1]!) * 3600000 + int.parse(m[2]!) * 60000 + int.parse(m[3]!) * 1000 + int.parse(m[4]!);
      starts.add((ms / 10).round()); // 10 ms buckets fold stacked ASS layers
    }
    return (starts.toList()..sort()).map((s) => s / 100).toList();
  }

  /// The shift `d` (seconds) for which the most [reference] starts have a
  /// [target] start at `reference − d`, refined to the median of those pairs.
  /// Null when fewer than 3 lines (or under a third of [reference]) agree.
  @visibleForTesting
  static ({double offset, int matched})? bestOffset(List<double> reference, List<double> target) {
    final sortedTarget = [...target]..sort();

    // Vote with every pair's difference in 0.1 s bins, then score the
    // strongest bins exactly.
    final votes = <int, int>{};
    for (final r in reference) {
      for (final t in sortedTarget) {
        final d = r - t;
        if (d.abs() <= _maxShift) votes.update((d * 10).round(), (v) => v + 1, ifAbsent: () => 1);
      }
    }
    final candidates = (votes.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(25);

    ({double offset, int matched, List<double> diffs})? best;
    for (final c in candidates) {
      final d = c.key / 10;
      final diffs = <double>[];
      for (final r in reference) {
        final t = _nearest(sortedTarget, r - d);
        if (t != null && (t + d - r).abs() <= _tolerance) diffs.add(r - t);
      }
      if (best == null ||
          diffs.length > best.matched ||
          (diffs.length == best.matched && d.abs() < best.offset.abs())) {
        best = (offset: d, matched: diffs.length, diffs: diffs);
      }
    }
    if (best == null || best.matched < math.max(3, reference.length / 3)) return null;
    final diffs = best.diffs..sort();
    return (offset: diffs[diffs.length ~/ 2], matched: best.matched);
  }

  static double? _nearest(List<double> sorted, double x) {
    if (sorted.isEmpty) return null;
    var lo = 0;
    var hi = sorted.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (sorted[mid] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final above = sorted[lo];
    final below = lo > 0 ? sorted[lo - 1] : above;
    return (x - below).abs() <= (above - x).abs() ? below : above;
  }
}

class _Track {
  final String id;
  final String lang;
  final String title;
  final String codec;
  final bool forced;
  final String? externalFile;
  final int? ffIndex;

  const _Track({
    required this.id,
    required this.lang,
    required this.title,
    required this.codec,
    required this.forced,
    required this.externalFile,
    required this.ffIndex,
  });

  bool get isText => StudySubtitleSync._textCodecs.contains(codec);
}
