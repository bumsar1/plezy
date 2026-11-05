import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/study/study_subtitle_sync.dart';

void main() {
  test('keeps spoken ASS lines and drops signs, songs and karaoke', () {
    const ass = '''
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,Hello, there
Dialogue: 0,0:00:02.00,0:00:04.00,Sign,,0,0,0,,STORE
Dialogue: 0,0:00:02.10,0:00:02.14,Default,,0,0,0,,{\\pos(100,200)}frame sign
Dialogue: 0,0:00:05.00,0:00:07.00,OP-Romaji,,0,0,0,,{\\k20}la la
Dialogue: 0,0:00:08.00,0:00:09.00,Default,,0,0,0,,{\\i1}Italic line{\\i0}
Dialogue: 0,0:00:10.00,0:00:11.00,Default,,0,0,0,,{\\an8}
Dialogue: 0,1:02:03.45,1:02:04.00,Main,,0,0,0,,Late
''';
    final lines = StudySubtitleSync.parseAssLines(ass);
    expect(lines.map((l) => l.start), [1.5, 8.0, 3723.45]);
  });

  test('finds the shift between differently timed and split tracks', () {
    final random = Random(3);
    final english = <SubtitleLine>[];
    var t = 300.0;
    while (t < 390) {
      final d = 1.0 + random.nextDouble() * 3;
      english.add(SubtitleLine(t, t + d));
      t += d + 0.2 + random.nextDouble() * 2.5;
    }
    // Japanese: 2.4 s early, own timing (±0.3 s edges), some lines split in two,
    // a few missing, plus lines all over the rest of the episode.
    final japanese = <SubtitleLine>[];
    for (final e in english) {
      if (random.nextDouble() < 0.1) continue;
      final s = e.start - 2.4 + (random.nextDouble() - 0.5) * 0.6;
      final end = e.end - 2.4 + (random.nextDouble() - 0.5) * 0.6;
      if (random.nextDouble() < 0.3) {
        final mid = (s + end) / 2;
        japanese
          ..add(SubtitleLine(s, mid - 0.05))
          ..add(SubtitleLine(mid, end));
      } else {
        japanese.add(SubtitleLine(s, end));
      }
    }
    for (var x = 10.0; x < 1400; x += 7.3) {
      if (x < 280 || x > 400) japanese.add(SubtitleLine(x, x + 2));
    }
    final best = StudySubtitleSync.bestOffset(english, japanese)!;
    expect(best.offset, closeTo(2.4, 0.15));
    expect(best.coverage, greaterThan(0.5));
  });

  test('gives up when nothing lines up', () {
    final english = [for (var i = 0; i < 12; i++) SubtitleLine(100.0 + i * 5, 101.0 + i * 5)];
    final japanese = [SubtitleLine(500, 501), SubtitleLine(700, 702)];
    expect(StudySubtitleSync.bestOffset(english, japanese), isNull);
  });
}
