import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/jimaku/jimaku_client.dart';
import 'package:plezy/services/jimaku/jimaku_service.dart';

void main() {
  group('JimakuService.matchesEpisode', () {
    test('matches common episode spellings', () {
      expect(JimakuService.matchesEpisode('[SubsPlease] Frieren - 05 (1080p).ja.srt', 5), isTrue);
      expect(JimakuService.matchesEpisode('Frieren.S01E05.WEB.ass', 5), isTrue);
      expect(JimakuService.matchesEpisode('葬送のフリーレン 第5話.srt', 5), isTrue);
      expect(JimakuService.matchesEpisode('Frieren_05.ass', 5), isTrue);
      expect(JimakuService.matchesEpisode('Frieren [05v2].ass', 5), isTrue);
    });

    test('ignores numbers that are not the episode', () {
      expect(JimakuService.matchesEpisode('[SubsPlease] Frieren - 15 (1080p).srt', 5), isFalse);
      expect(JimakuService.matchesEpisode('Frieren - 06 [x265 1080p].ass', 5), isFalse);
      expect(JimakuService.matchesEpisode('Frieren.S01E50.ass', 5), isFalse);
    });
  });

  test('JimakuEntry parses the API shape', () {
    final entry = JimakuEntry.fromJson({
      'id': 42,
      'name': 'Sousou no Frieren',
      'japanese_name': '葬送のフリーレン',
      'anilist_id': 154587,
      'flags': {'anime': true, 'movie': false},
      'last_modified': '2024-01-01T00:00:00Z',
    });
    expect(entry.id, 42);
    expect(entry.anilistId, 154587);
    expect(entry.isMovie, isFalse);
  });

  test('JimakuFile reports usable extensions', () {
    JimakuFile file(String name) => JimakuFile(name: name, url: 'https://jimaku.cc/x', size: 1);
    expect(JimakuService.isUsable(file('a.ASS')), isTrue);
    expect(JimakuService.isUsable(file('pack.zip')), isTrue);
    expect(JimakuService.isUsable(file('pack.rar')), isFalse);
  });
}
