import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/study/study_subtitle_sync.dart';

void main() {
  test('parses SRT start times and folds stacked lines', () {
    const srt =
        '1\n00:00:01,000 --> 00:00:02,000\nA\n\n2\n00:00:01,004 --> 00:00:02,000\nB\n\n3\n01:02:03,450 --> 01:02:04,000\nC\n';
    expect(StudySubtitleSync.parseSrtStarts(srt), [1.0, 3723.45]);
  });

  test('finds a constant shift despite extra and missing lines', () {
    final english = [for (var i = 0; i < 30; i++) 100 + i * 3.7 + (i % 4) * 0.9];
    // Japanese: 2.35 s early, with signs on top and a few lines missing.
    final japanese = [
      for (final (i, e) in english.indexed)
        if (i % 7 != 3) e - 2.35 + (i.isEven ? 0.05 : -0.04),
      for (var i = 0; i < 15; i++) 20 + i * 11.3,
    ];
    final best = StudySubtitleSync.bestOffset(english, japanese)!;
    expect(best.offset, closeTo(2.35, 0.06));
    expect(best.matched, greaterThanOrEqualTo(24));
  });

  test('gives up when nothing lines up', () {
    expect(StudySubtitleSync.bestOffset([1, 50, 90, 140], [7.3, 33.1, 61.9, 99.4]), isNull);
  });
}
