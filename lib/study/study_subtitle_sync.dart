import 'dart:async';
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
/// When the subtitle is a local .srt/.ass file (Jimaku's always are), the
/// whole file is retimed: it is split into parts at pauses in the speech
/// (where a different cut of the episode - a longer intro, an ad break -
/// moves everything after it), each part's shift is measured against a short
/// window of the English track, and the file is rewritten with those shifts
/// and reloaded, so it stays right on later plays. Otherwise one constant
/// shift near the playhead becomes `sub-delay`. Only windows of an embedded
/// English track are read, so a Plex stream isn't downloaded whole.
class StudySubtitleSync {
  StudySubtitleSync._();

  static const _window = 90.0;
  static const _partWindow = 50.0;
  static const _maxShift = 90.0;

  /// A pause in the speech at least this long can separate two parts.
  static const _partGap = 15.0;

  /// Parts with fewer lines are too short to measure and join a neighbour.
  static const _minPartLines = 6;

  /// Shifts this close count as the same.
  static const _sameShift = 0.3;
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

    final file = primary.externalFile;
    if (file != null && !file.startsWith('http') && RegExp(r'\.(srt|ass|ssa)$', caseSensitive: false).hasMatch(file)) {
      return _retimeFile(player, item, ffmpeg, primary, File(file), english, source, headers);
    }

    final from = math.max(0.0, position - _window / 2);
    final reference = await _lines(ffmpeg, english, source, headers, (from: from, to: from + _window), 'reference');
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

    final ms = await _setDelay(player, item, best.offset);
    return StudySyncResult(
      ms / 1000,
      'Shifted ${_signed(ms / 1000)} · ${best.matched}/${reference.length} lines match',
    );
  }

  /// Applies and remembers (for this episode, like a manual subtitle sync)
  /// a sub-delay of [seconds]; returns it in whole milliseconds.
  static Future<int> _setDelay(Player player, MediaItem? item, double seconds) async {
    final ms = (seconds * 1000).round().clamp(
      ScopedPlayerPrefs.minimumSyncOffsetMs,
      ScopedPlayerPrefs.maximumSyncOffsetMs,
    );
    await player.setProperty(PlayerSyncOffsets.subtitleProperty, (ms / 1000).toString());
    PlayerSyncOffsets.of(player).recordApplied(PlayerSyncOffsets.subtitleProperty, ms);
    if (item != null) await ScopedPlayerPrefs.write(ScopedPlayerPrefs.subtitleSyncOffset, item, ms);
    return ms;
  }

  static String _signed(double seconds) => '${seconds >= 0 ? '+' : '−'}${seconds.abs().toStringAsFixed(2)} s';

  static Future<StudySyncResult> _retimeFile(
    Player player,
    MediaItem? item,
    String ffmpeg,
    _Track primary,
    File file,
    _Track english,
    String? source,
    List<String> headers,
  ) async {
    final bytes = await file.readAsBytes();
    final hasBom = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
    final text = utf8.decode(hasBom ? bytes.sublist(3) : bytes, allowMalformed: true);
    final isAss = !file.path.toLowerCase().endsWith('.srt');
    final spoken = isAss ? parseAssLines(text) : parseSrtLines(text);
    final parts = splitParts(spoken);
    if (parts.isEmpty) return const StudySyncResult(null, 'Could not read the subtitle lines');

    // Each part's window in video time, placed with the delay already applied
    // (a part shifts by at most a minute or so from there).
    final delay = double.tryParse(await player.getProperty(PlayerSyncOffsets.subtitleProperty) ?? '') ?? 0;
    ({double from, double to}) windowFor(List<SubtitleLine> part) {
      final a = part.first.start + delay;
      final b = part.last.end + delay;
      // A short part gets room on both sides for a shift of up to ~30 s.
      if (b - a <= _partWindow) return (from: math.max(0.0, a - 30), to: b + 30);
      final mid = (a + b) / 2;
      return (from: math.max(0.0, mid - _partWindow / 2), to: mid + _partWindow / 2);
    }

    // Measure as few parts as possible: the first and the last, and between
    // two that disagree the middle one, halving until each shift change is
    // pinned to one pause. A constant shift costs two windows.
    final slots = _Slots(3);
    final measured = <int, Future<double?>>{};
    Future<double?> measure(int i) => measured[i] ??= slots.run(() async {
      final reference = await _lines(ffmpeg, english, source, headers, windowFor(parts[i]), 'reference_$i');
      if (reference == null || reference.length < 3) return null;
      return bestOffset(reference, parts[i])?.offset;
    });
    final offsets = List<double?>.filled(parts.length, null);
    Future<void> solve(int lo, int hi) async {
      final [a, b] = await Future.wait([measure(lo), measure(hi)]);
      offsets[lo] = a;
      offsets[hi] = b;
      if (hi - lo <= 1) return;
      if (a != null && b != null && (a - b).abs() <= _sameShift) {
        for (var i = lo + 1; i < hi; i++) {
          offsets[i] = (a + b) / 2;
        }
        return;
      }
      final mid = (lo + hi) ~/ 2;
      await Future.wait([solve(lo, mid), solve(mid, hi)]);
    }

    await solve(0, parts.length - 1);
    appLogger.i(
      'Study sync: ${parts.length} parts ${[for (final p in parts) p.length]}, '
      '${measured.length} measured, offsets $offsets',
    );
    if (offsets.every((o) => o == null)) return const StudySyncResult(null, 'No matching timing found');
    // A part that couldn't be measured takes its nearest measured neighbour's shift.
    final filled = [
      for (var i = 0; i < offsets.length; i++)
        offsets[i] ??
            [
              for (var k = 1; k < offsets.length; k++) ...[
                if (i - k >= 0) offsets[i - k],
                if (i + k < offsets.length) offsets[i + k],
              ],
            ].firstWhere((o) => o != null)!,
    ];

    // Parts meet halfway through the pause between them.
    final boundaries = [for (var i = 1; i < parts.length; i++) (parts[i - 1].last.end + parts[i].first.start) / 2];
    final retimed = retimeSubtitle(text, isAss: isAss, boundaries: boundaries, offsets: filled);

    // Jimaku files live in Plezy's own folders: rewrite them in place (the
    // remembered subtitle then stays synced), keeping the original once.
    // Anything else gets a synced copy alongside in the cache.
    final appDirs = [(await getApplicationSupportDirectory()).path, (await getTemporaryDirectory()).path];
    final ownFile = appDirs.any(file.path.startsWith);
    final out = ownFile
        ? file
        : File(
            '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}plezy_study${Platform.pathSeparator}'
            'synced_${file.uri.pathSegments.last}',
          );
    if (ownFile) {
      final backup = File('${file.path}.orig');
      if (!await backup.exists()) await file.copy(backup.path);
    }
    await out.parent.create(recursive: true);
    await out.writeAsBytes([
      if (hasBom) ...[0xEF, 0xBB, 0xBF],
      ...utf8.encode(retimed),
    ]);

    if (ownFile) {
      await player.command(['sub-reload', primary.id]);
    } else {
      await player.command(['sub-add', out.path, 'select', '${primary.title} (synced)', 'ja']);
    }
    await _setDelay(player, item, 0);

    // Neighbouring parts with the same shift read as one in the summary.
    final shifts = <double>[];
    for (final o in filled) {
      if (shifts.isEmpty || (shifts.last - o).abs() > _sameShift) shifts.add(o);
    }
    return StudySyncResult(
      0,
      shifts.length == 1
          ? 'Synced: ${_signed(shifts.single)} throughout'
          : 'Synced in ${shifts.length} parts: ${shifts.map(_signed).join(' → ')}',
    );
  }

  /// Splits spoken lines into parts at pauses of [_partGap] or more; parts
  /// with under [_minPartLines] lines join their neighbour.
  @visibleForTesting
  static List<List<SubtitleLine>> splitParts(List<SubtitleLine> lines) {
    final sorted = [...lines]..sort((a, b) => a.start.compareTo(b.start));
    final parts = <List<SubtitleLine>>[];
    for (final l in sorted) {
      if (parts.isEmpty || l.start - parts.last.map((x) => x.end).reduce(math.max) >= _partGap) {
        parts.add([l]);
      } else {
        parts.last.add(l);
      }
    }
    for (var i = 0; i < parts.length && parts.length > 1;) {
      if (parts[i].length >= _minPartLines) {
        i++;
        continue;
      }
      final small = parts.removeAt(i);
      if (i == 0) {
        parts[0].insertAll(0, small);
      } else {
        parts[i - 1].addAll(small);
        i = i - 1;
      }
    }
    return parts;
  }

  static final _srtTiming = RegExp(r'(\d+):(\d\d):(\d\d)[,.](\d{3})(\s*-->\s*)(\d+):(\d\d):(\d\d)[,.](\d{3})');

  /// Every line of an SRT document, sorted.
  @visibleForTesting
  static List<SubtitleLine> parseSrtLines(String srt) => [
    for (final m in _srtTiming.allMatches(srt))
      SubtitleLine(_hms(m[1]!, m[2]!, m[3]!, m[4]!), _hms(m[6]!, m[7]!, m[8]!, m[9]!)),
  ]..sort((a, b) => a.start.compareTo(b.start));

  static double _hms(String h, String m, String s, String frac) =>
      int.parse(h) * 3600 + int.parse(m) * 60 + int.parse(s) + double.parse('0.$frac');

  /// [text] (SRT, or ASS when [isAss]) with every line moved by the offset of
  /// the part its start falls in: before `boundaries[0]` → `offsets[0]`, and
  /// so on. Signs and songs move with the speech around them.
  @visibleForTesting
  static String retimeSubtitle(
    String text, {
    required bool isAss,
    required List<double> boundaries,
    required List<double> offsets,
  }) {
    double offsetAt(double start) => offsets[boundaries.where((b) => start >= b).length];
    if (!isAss) {
      return text.replaceAllMapped(_srtTiming, (m) {
        final start = _hms(m[1]!, m[2]!, m[3]!, m[4]!);
        final end = _hms(m[6]!, m[7]!, m[8]!, m[9]!);
        final d = offsetAt(start);
        return '${_srtTime(start + d)}${m[5]}${_srtTime(end + d)}';
      });
    }
    return text
        .split('\n')
        .map((line) {
          final match = RegExp(r'^(Dialogue|Comment):\s*').firstMatch(line);
          if (match == null) return line;
          final fields = line.substring(match.end).split(',');
          if (fields.length < 10) return line;
          final start = _parseAssTime(fields[1].trim());
          final end = _parseAssTime(fields[2].trim());
          if (start == null || end == null) return line;
          final d = offsetAt(start);
          fields[1] = _assTimeString(start + d);
          fields[2] = _assTimeString(end + d);
          return '${match[0]}${fields.join(',')}';
        })
        .join('\n');
  }

  static String _srtTime(double seconds) {
    final ms = (math.max(0.0, seconds) * 1000).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
  }

  static String _assTimeString(double seconds) {
    final cs = (math.max(0.0, seconds) * 100).round();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${cs ~/ 360000}:${two(cs ~/ 6000 % 60)}:${two(cs ~/ 100 % 60)}.${two(cs % 100)}';
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
  /// [window] set, an embedded track is read only in that stretch.
  /// The raw extract is kept in the temp folder as sync_[label].ass for
  /// diagnosing a sync that went wrong.
  static Future<List<SubtitleLine>?> _lines(
    String ffmpeg,
    _Track track,
    String? source,
    List<String> headers,
    ({double from, double to})? window,
    String label,
  ) async {
    final List<String> args;
    final external = track.externalFile;
    if (external != null && external.isNotEmpty) {
      args = [if (external.startsWith('http')) ...headers, '-i', external, '-map', '0:s:0'];
    } else if (source != null && track.ffIndex != null) {
      final from = window?.from;
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
        if (window != null) ...['-to', window.to.toStringAsFixed(3)],
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
  /// differently. Null when under 30 % of the speech is covered.
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

    // Measured against whichever side has less speech here: a window may hold
    // more English than the part being matched, or the other way round.
    final tgtTotal = tgt.fold(0.0, (sum, l) => sum + l.end - l.start);
    final coverage = peak / math.min(refTotal, tgtTotal);
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

/// Runs at most [limit] jobs at once (ffmpeg windows read in parallel).
class _Slots {
  final int limit;
  var _running = 0;
  final _waiting = <Completer<void>>[];

  _Slots(this.limit);

  Future<T> run<T>(Future<T> Function() job) async {
    if (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      return await job();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
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
