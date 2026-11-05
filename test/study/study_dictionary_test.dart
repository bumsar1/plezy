import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/study/study_dictionary.dart';

/// Runs against a locally built dictionary:
/// STUDY_DICTIONARY=/path/to/study_dictionary.sqlite flutter test test/study
void main() {
  final path = Platform.environment['STUDY_DICTIONARY'];

  group('StudyDictionary', skip: path == null ? 'STUDY_DICTIONARY not set' : null, () {
    late StudyDictionary dict;
    setUpAll(() async => dict = await StudyDictionary.openFile(File(path!)));

    Future<StudyEntry> first(String text) async => (await dict.lookup(text)).entries.first;

    test('plain word', () async {
      final e = await first('食べる');
      expect(e.written, '食べる');
      expect(e.reading, 'たべる');
      expect(e.senses.first.glosses, contains('to eat'));
    });

    test('conjugated verb resolves to dictionary form', () async {
      final e = await first('食べなかった。');
      expect(e.written, '食べる');
      expect(e.matchLength, 6);
      expect(e.process, isNotEmpty);
    });

    test('longest match from inside a sentence', () async {
      final e = await first('行きたくないんだよ');
      expect(e.written, '行く');
    });

    test('kana word', () async {
      final e = await first('ありがとう');
      expect(e.matchLength, 5);
    });

    test('kanji fallback', () async {
      final l = await dict.lookup('猫が');
      expect(l.kanji?.character, '猫');
      expect(l.entries.first.written, '猫');
    });
  });
}
