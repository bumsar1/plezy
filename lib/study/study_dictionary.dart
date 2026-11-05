import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';
import 'deconjugator.dart';

/// One dictionary sense: English glosses plus JMdict part-of-speech codes.
class StudySense {
  final List<String> glosses;
  final List<String> pos;

  const StudySense(this.glosses, this.pos);
}

class StudyEntry {
  final String written;
  final String reading;
  final List<StudySense> senses;
  final int freq;

  /// Conjugation steps that led from the hovered text to [written], e.g.
  /// `["past", "negative"]`.
  final List<String> process;

  /// How many characters of the hovered text this entry covers.
  final int matchLength;

  const StudyEntry({
    required this.written,
    required this.reading,
    required this.senses,
    required this.freq,
    required this.process,
    required this.matchLength,
  });
}

class StudyKanji {
  final String character;
  final List<String> meanings;
  final List<String> readings;

  const StudyKanji(this.character, this.meanings, this.readings);
}

class StudyLookup {
  final List<StudyEntry> entries;
  final StudyKanji? kanji;

  const StudyLookup(this.entries, this.kanji);

  bool get isEmpty => entries.isEmpty && kanji == null;

  /// Characters the best match covers, for highlighting the hovered word.
  int get matchLength => entries.isEmpty ? (kanji == null ? 0 : 1) : entries.first.matchLength;
}

/// The Japanese→English dictionary behind study mode: meikipop's JMdict data
/// converted to SQLite (scripts/study/build_study_dictionary.py), downloaded
/// on first use, and the same longest-prefix + deconjugation lookup meikipop
/// does.
class StudyDictionary {
  StudyDictionary._(this._db, this._deconjugator);

  static const downloadUrl =
      'https://github.com/bumsar1/plezy/releases/download/study-dictionary/study_dictionary.sqlite.gz';
  static const _fileName = 'study_dictionary_v1.sqlite';
  static const _maxLookupLength = 16;
  static const _maxEntries = 6;
  static const _defaultFreq = 999999;

  static Future<StudyDictionary>? _opening;

  final _DictionaryDatabase _db;
  final Deconjugator _deconjugator;
  final Map<String, StudyLookup> _cache = {};

  /// Opens the dictionary, downloading it first if needed. [onProgress]
  /// receives 0–1 while downloading. Concurrent callers share one open.
  static Future<StudyDictionary> open({void Function(double progress)? onProgress}) {
    return _opening ??= _open(onProgress).catchError((Object e) {
      _opening = null;
      throw e;
    });
  }

  static Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}$_fileName');

  static Future<bool> isDownloaded() async => (await _file()).exists();

  static Future<StudyDictionary> _open(void Function(double)? onProgress) async {
    final file = await _file();
    if (!await file.exists()) await _download(file, onProgress);
    return openFile(file);
  }

  /// Opens an already downloaded dictionary file.
  @visibleForTesting
  static Future<StudyDictionary> openFile(File file) async {
    final db = _DictionaryDatabase(NativeDatabase.createInBackground(file));
    final row = await db.customSelect("SELECT value FROM meta WHERE key = 'deconjugator_rules'").getSingle();
    final rules = jsonDecode(row.read<String>('value')) as List<dynamic>;
    return StudyDictionary._(db, Deconjugator(rules));
  }

  static Future<void> _download(File target, void Function(double)? onProgress) async {
    appLogger.i('Study mode: downloading dictionary');
    final client = http.Client();
    final partial = File('${target.path}.part');
    try {
      final response = await client.send(http.Request('GET', Uri.parse(downloadUrl)));
      if (response.statusCode != 200) {
        throw HttpException('Dictionary download failed (HTTP ${response.statusCode})');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      final counted = response.stream.map((chunk) {
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
        return chunk;
      });
      await partial.parent.create(recursive: true);
      await counted.transform(gzip.decoder).pipe(partial.openWrite());
      await partial.rename(target.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    } finally {
      client.close();
    }
  }

  static final _kanji = RegExp(r'[一-龯]');
  static const _separators = {
    '、', '。', '「', '」', '｛', '｝', '（', '）', '【', '】', '『', '』', '〈', '〉', '《', '》', //
    '：', '・', '／', '…', '︙', '‥', '︰', '＋', '＝', '－', '÷', '？', '！', '．', '～', '―', //
    '!', '?', ' ', '　', '\n',
  };

  /// Looks up the word starting at the beginning of [text].
  Future<StudyLookup> lookup(String text) async {
    var t = text.trim();
    if (t.length > _maxLookupLength) t = t.substring(0, _maxLookupLength);
    final sep = t.split('').indexWhere(_separators.contains);
    if (sep >= 0) t = t.substring(0, sep);
    if (t.isEmpty) return const StudyLookup([], null);

    final cached = _cache[t];
    if (cached != null) return cached;

    final result = StudyLookup(await _lookupTerms(t), _kanji.hasMatch(t[0]) ? await _lookupKanji(t[0]) : null);
    if (_cache.length > 500) _cache.remove(_cache.keys.first);
    return _cache[t] = result;
  }

  Future<List<StudyEntry>> _lookupTerms(String text) async {
    // Every prefix (longest first) and every deconjugated form of it.
    final candidates = <({DeconjugatedForm form, int prefixLength})>[];
    for (var len = text.length; len > 0; len--) {
      for (final form in _deconjugator.deconjugate(text.substring(0, len))) {
        candidates.add((form: form, prefixLength: len));
      }
    }

    final keys = <String>{};
    for (final c in candidates) {
      keys
        ..add(c.form.text)
        ..add(_hiraToKata(c.form.text))
        ..add(_kataToHira(c.form.text));
    }
    final rows = await _termsFor(keys);

    final senseCache = <int, List<StudySense>>{};
    final collected = <int, ({_TermRow row, DeconjugatedForm form, int prefixLength})>{};
    var foundPrimary = false;
    var currentLength = -1;
    var lengthHadHit = false;

    for (final c in candidates) {
      if (c.prefixLength != currentLength) {
        if (lengthHadHit) foundPrimary = true;
        currentLength = c.prefixLength;
        lengthHadHit = false;
      }
      final prefix = text.substring(0, c.prefixLength);
      for (final row in _rowsFor(rows, c.form.text)) {
        if (row.written == null && _kanji.hasMatch(c.form.text)) continue;
        if (c.form.tags.isNotEmpty) {
          final senses = senseCache[row.entryId] ??= await _senses(row.entryId);
          if (!senses.any((s) => s.pos.contains(c.form.tags.last))) continue;
        }
        // Once a longer match with kanji exists, kana-only prefixes shouldn't
        // drag in unrelated kanji words.
        if (foundPrimary && !_kanji.hasMatch(prefix) && row.written != null && _kanji.hasMatch(row.written!)) {
          continue;
        }
        lengthHadHit = true;
        collected.putIfAbsent(row.entryId, () => (row: row, form: c.form, prefixLength: c.prefixLength));
      }
    }

    final merged = <String, _Merged>{};
    for (final hit in collected.values) {
      final written = hit.row.written ?? hit.row.key;
      final reading = hit.row.reading ?? '';
      final senses = senseCache[hit.row.entryId] ??= await _senses(hit.row.entryId);
      final priority = _priority(written, hit.row.freq, hit.form, hit.prefixLength, text);
      final m = merged['$written\u0000$reading'];
      if (m == null) {
        merged['$written\u0000$reading'] = _Merged(
          written,
          reading,
          [...senses],
          hit.row.freq,
          hit.form.process,
          priority,
          hit.prefixLength,
          hit.row.entryId,
        );
      } else {
        if (m.entryId != hit.row.entryId) m.senses.addAll(senses);
        if (priority > m.priority) {
          m
            ..priority = priority
            ..process = hit.form.process;
        }
        m
          ..freq = math.min(m.freq, hit.row.freq)
          ..matchLength = math.max(m.matchLength, hit.prefixLength);
      }
    }

    final sorted = merged.values.toList()
      ..sort(
        (a, b) =>
            a.matchLength != b.matchLength ? b.matchLength.compareTo(a.matchLength) : b.priority.compareTo(a.priority),
      );
    final longest = sorted.isEmpty ? 0 : sorted.first.matchLength;
    return [
      for (final m in sorted.where((m) => m.matchLength == longest).take(_maxEntries))
        StudyEntry(
          written: m.written,
          reading: m.reading,
          senses: m.senses,
          freq: m.freq,
          process: m.process,
          matchLength: m.matchLength,
        ),
    ];
  }

  /// Rows for [key], trying katakana then hiragana spellings like meikipop.
  Iterable<_TermRow> _rowsFor(Map<String, List<_TermRow>> rows, String key) {
    for (final k in [key, _hiraToKata(key), _kataToHira(key)]) {
      final hit = rows[k];
      if (hit != null && hit.isNotEmpty) return hit;
    }
    return const [];
  }

  Future<Map<String, List<_TermRow>>> _termsFor(Set<String> keys) async {
    final out = <String, List<_TermRow>>{};
    final list = keys.toList();
    // SQLite's default variable limit is far above this, but keep batches modest.
    for (var i = 0; i < list.length; i += 400) {
      final batch = list.sublist(i, math.min(i + 400, list.length));
      final rows = await _db
          .customSelect(
            'SELECT key, written, reading, freq, entry_id FROM terms WHERE key IN (${List.filled(batch.length, '?').join(',')})',
            variables: [for (final k in batch) Variable.withString(k)],
          )
          .get();
      for (final r in rows) {
        final row = _TermRow(
          r.read<String>('key'),
          r.readNullable<String>('written'),
          r.readNullable<String>('reading'),
          r.read<int>('freq'),
          r.read<int>('entry_id'),
        );
        (out[row.key] ??= []).add(row);
      }
    }
    return out;
  }

  Future<List<StudySense>> _senses(int entryId) async {
    final row = await _db
        .customSelect('SELECT senses FROM entries WHERE id = ?', variables: [Variable.withInt(entryId)])
        .getSingleOrNull();
    if (row == null) return const [];
    return [
      for (final s in jsonDecode(row.read<String>('senses')) as List<dynamic>)
        StudySense(
          [for (final g in (s['glosses'] as List<dynamic>? ?? const [])) g.toString()],
          [for (final p in (s['pos'] as List<dynamic>? ?? const [])) p.toString()],
        ),
    ];
  }

  Future<StudyKanji?> _lookupKanji(String ch) async {
    final row = await _db
        .customSelect('SELECT data FROM kanji WHERE ch = ?', variables: [Variable.withString(ch)])
        .getSingleOrNull();
    if (row == null) return null;
    final data = jsonDecode(row.read<String>('data')) as Map<String, dynamic>;
    return StudyKanji(
      ch,
      [for (final m in (data['meanings'] as List<dynamic>? ?? const [])) m.toString()],
      [for (final r in (data['readings'] as List<dynamic>? ?? const [])) r.toString()],
    );
  }

  double _priority(String written, int freq, DeconjugatedForm form, int matchLength, String original) {
    var priority = matchLength.toDouble();
    // Log scale: rank 1 → ~10, rank 1000 → ~5, unranked → 0.
    if (freq < _defaultFreq) priority += 10 * (1 - math.log(freq) / math.log(_defaultFreq));
    if (!_kanji.hasMatch(original) && !_kanji.hasMatch(written) && form.process.isEmpty) priority += 3;
    return priority - form.process.length;
  }

  static String _hiraToKata(String text) =>
      String.fromCharCodes(text.runes.map((c) => c >= 0x3041 && c <= 0x3096 ? c + 0x60 : c));

  static String _kataToHira(String text) => String.fromCharCodes(
    text.runes.map(
      (c) => switch (c) {
        >= 0x30A1 && <= 0x30F6 => c - 0x60,
        0x30FD => 0x309D,
        0x30FE => 0x309E,
        _ => c,
      },
    ),
  );
}

class _TermRow {
  final String key;
  final String? written;
  final String? reading;
  final int freq;
  final int entryId;

  const _TermRow(this.key, this.written, this.reading, this.freq, this.entryId);
}

class _Merged {
  final String written;
  final String reading;
  final List<StudySense> senses;
  int freq;
  List<String> process;
  double priority;
  int matchLength;
  final int entryId;

  _Merged(
    this.written,
    this.reading,
    this.senses,
    this.freq,
    this.process,
    this.priority,
    this.matchLength,
    this.entryId,
  );
}

/// Schema-less drift database: the dictionary file is built offline, so this
/// only runs raw queries against it.
class _DictionaryDatabase extends GeneratedDatabase {
  _DictionaryDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(onCreate: (_) async {}, onUpgrade: (_, _, _) async {});
}
