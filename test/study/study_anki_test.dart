import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/study/study_anki.dart';

void main() {
  group('StudyAnki.furigana', () {
    test('kana tail stays outside the brackets', () => expect(StudyAnki.furigana('食べる', 'たべる'), '食[た]べる'));
    test('kana head is split off with a space', () => expect(StudyAnki.furigana('お茶', 'おちゃ'), 'お 茶[ちゃ]'));
    test('all kanji', () => expect(StudyAnki.furigana('日本語', 'にほんご'), '日本語[にほんご]'));
    test('kana-only word', () => expect(StudyAnki.furigana('ありがとう', ''), 'ありがとう'));
  });
}
