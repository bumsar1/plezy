import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../media/media_item.dart';
import '../mpv/mpv.dart';
import '../services/player_sync_offsets.dart';
import '../services/scoped_player_prefs.dart';
import '../utils/app_logger.dart';
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

    final reference = await _lines(ffmpeg, english, source, headers, position, 'reference');
    final target = await _lines(ffmpeg, primary, source, headers, null, 'target');
    if (reference == null || reference.length < 3) {
      return const StudySyncResult(null, 'Could not read the English lines');
    }
    if (target == null || target.length < 3) return const StudySyncResult(null, 'Could not read the subtitle lines');

    final best = bestOffset(reference, target);
    appLogger.i(
      'Study sync: ${reference.length} English lines near ${position.toStringAsFixed(1)} s, '
      '${target.length} subtitle lines; best ${best?.offset} s covering ${best?.coverage}',
    );
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

  /// Spoken lines of [track] (signs, songs and karaoke left out). With
  /// [around] set, an embedded track is read only in a window centred there.
  /// The raw extract is kept in the temp folder as sync_[label].ass for
  /// diagnosing a sync that went wrong.
  static Future<List<SubtitleLine>?> _lines(
    String ffmpeg,
    _Track track,
    String? source,
    List<String> headers,
    double? around,
    String label,
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
    // ASS keeps the style names and override tags that tell signs from speech.
    final ass = await StudyFfmpeg.output(ffmpeg, [...args, '-c:s', 'ass', '-f', 'ass', 'pipe:1']);
    if (ass == null) return null;
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}plezy_study');
      await dir.create(recursive: true);
      await File('${dir.path}${Platform.pathSeparator}sync_$label.ass').writeAsString(ass);
    } catch (_) {
      // Diagnostics only.
    }
    return parseAssLines(ass);
  }

  static final _assTime = RegExp(r'^(\d+):(\d\d):(\d\d)[.,](\d+)$');
  static final _signTags = RegExp(r'\\(pos|move|org|clip|iclip)\(|\\p[1-9]|\\k[fo]?\d', caseSensitive: false);
  static final _signStyles = RegExp(
    r'sign|song|kara|title|note|insert|typeset|lyric|romaji|^op|^ed|^ts|[ _-](op|ed)$',
    caseSensitive: false,
  );

  /// Spoken lines of an ASS document: Dialogue events whose style and
  /// override tags don't mark them as signs, songs or karaoke.
  @visibleForTesting
  static List<SubtitleLine> parseAssLines(String ass) {
    final lines = <SubtitleLine>[];
    for (final raw in LineSplitter.split(ass)) {
      if (!raw.startsWith('Dialogue:')) continue;
      final fields = raw.substring(9).split(',');
      if (fields.length < 10) continue;
      final start = _parseAssTime(fields[1].trim());
      final end = _parseAssTime(fields[2].trim());
      final style = fields[3].trim();
      final effect = fields[8].trim();
      final text = fields.sublist(9).join(',');
      if (start == null || end == null || end <= start) continue;
      if (effect.isNotEmpty || _signStyles.hasMatch(style) || _signTags.hasMatch(text)) continue;
      if (text.replaceAll(RegExp(r'\{[^}]*\}'), '').replaceAll(r'\N', '').trim().isEmpty) continue;
      lines.add(SubtitleLine(start, end));
    }
    return lines..sort((a, b) => a.start.compareTo(b.start));
  }

  static double? _parseAssTime(String s) {
    final m = _assTime.firstMatch(s);
    if (m == null) return null;
    final frac = double.parse('0.${m[4]}');
    return int.parse(m[1]!) * 3600 + int.parse(m[2]!) * 60 + int.parse(m[3]!) + frac;
  }

  /// The shift `d` (seconds) that makes [target] lines, moved by `d`, overlap
  /// [reference] lines the most. Overlap rather than start times because two
  /// subtitle tracks are timed by different people and split lines
  /// differently. Null when under 30 % of the reference speech is covered.
  @visibleForTesting
  static ({double offset, int matched, double coverage})? bestOffset(
    List<SubtitleLine> reference,
    List<SubtitleLine> target,
  ) {
    final ref = _union(reference);
    final refTotal = ref.fold(0.0, (sum, l) => sum + l.end - l.start);
    if (refTotal <= 0) return null;
    final from = ref.first.start - _maxShift;
    final to = ref.last.end + _maxShift;
    final tgt = _union([
      for (final l in target)
        if (l.end > from && l.start < to) l,
    ]);
    if (tgt.isEmpty) return null;

    double overlapAt(double d) {
      var total = 0.0;
      var j = 0;
      for (final r in ref) {
        while (j < tgt.length && tgt[j].end + d <= r.start) {
          j++;
        }
        for (var k = j; k < tgt.length && tgt[k].start + d < r.end; k++) {
          total += math.min(r.end, tgt[k].end + d) - math.max(r.start, tgt[k].start + d);
        }
      }
      return total;
    }

    // Coarse sweep, then a fine one around the peak; the middle of the fine
    // plateau is the answer (overlap is flat while edges don't line up).
    var best = 0.0;
    var bestScore = -1.0;
    for (var d = -_maxShift; d <= _maxShift; d += 0.1) {
      final score = overlapAt(d);
      if (score > bestScore) {
        bestScore = score;
        best = d;
      }
    }
    final fine = <({double d, double score})>[
      for (var d = best - 0.3; d <= best + 0.3; d += 0.01) (d: d, score: overlapAt(d)),
    ];
    final peak = fine.map((f) => f.score).reduce(math.max);
    final plateau = fine.where((f) => f.score >= peak * 0.995).map((f) => f.d).toList();
    final offset = (plateau.first + plateau.last) / 2;

    final coverage = peak / refTotal;
    final matched = reference
        .where((r) => target.any((t) => t.start + offset < r.end && t.end + offset > r.start))
        .length;
    if (coverage < 0.3 || matched < 3) return null;
    return (offset: offset, matched: matched, coverage: coverage);
  }

  static List<SubtitleLine> _union(List<SubtitleLine> lines) {
    final sorted = [...lines]..sort((a, b) => a.start.compareTo(b.start));
    final out = <SubtitleLine>[];
    for (final l in sorted) {
      if (out.isNotEmpty && l.start <= out.last.end) {
        if (l.end > out.last.end) out[out.length - 1] = SubtitleLine(out.last.start, l.end);
      } else {
        out.add(l);
      }
    }
    return out;
  }
}

class SubtitleLine {
  final double start;
  final double end;

  const SubtitleLine(this.start, this.end);
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
