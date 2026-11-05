import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/study/study_dictionary.dart';
import 'package:plezy/study/study_user_dictionaries.dart';

/// Imports a real Yomitan zip and looks words up through it:
/// STUDY_DICTIONARY=/path/study_dictionary.sqlite STUDY_YOMITAN_ZIP=/path/dict.zip \
///   flutter test test/study/study_user_dictionaries_test.dart
void main() {
  final dictPath = Platform.environment['STUDY_DICTIONARY'];
  final zipPath = Platform.environment['STUDY_YOMITAN_ZIP'];

  test(
    'imports a Yomitan dictionary and merges it into lookups',
    skip: dictPath == null || zipPath == null ? 'STUDY_DICTIONARY / STUDY_YOMITAN_ZIP not set' : null,
    timeout: const Timeout(Duration(minutes: 20)),
    () async {
      final dir = await Directory.systemTemp.createTemp('study_user_dicts');
      addTearDown(() => dir.delete(recursive: true));

      final watch = Stopwatch()..start();
      final title = await StudyUserDictionaries.import(zipPath!, into: dir, onProgress: stdout.writeln);
      stdout.writeln('imported "$title" in ${watch.elapsed}');
      final installed = await StudyUserDictionaries.list(from: dir);
      expect(installed.single.title, title);
      stdout.writeln('${installed.single.entries} entries, ${installed.single.file.lengthSync() ~/ 1048576} MB');

      await expectLater(StudyUserDictionaries.import(zipPath, into: dir), throwsA(isA<StudyImportException>()));

      final dict = await StudyDictionary.openFile(File(dictPath!), userDictionaries: installed);
      for (final word in ['食べなかった', '行きたくない', 'アーチビショップ']) {
        final entry = (await dict.lookup(word)).entries.first;
        final fromUser = entry.senses.where((s) => s.dictionary == title).toList();
        stdout.writeln(
          '$word → ${entry.written} [${entry.reading}]: ${entry.senses.length} senses, ${fromUser.length} from $title',
        );
        if (fromUser.isNotEmpty) stdout.writeln('  ${fromUser.first.glosses.first}');
        expect(fromUser, isNotEmpty, reason: word);
        expect(entry.senses.first.dictionary, isNull, reason: 'JMdict first for $word');
      }
    },
  );
}
