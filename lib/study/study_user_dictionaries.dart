import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

import 'study_database.dart';

/// An imported Yomitan dictionary, stored as SQLite with the same tables as
/// the main study dictionary (terms + entries), plus its title in `meta`.
class StudyUserDictionary {
  final File file;
  final String title;
  final int entries;

  const StudyUserDictionary(this.file, this.title, this.entries);
}

class StudyImportException implements Exception {
  final String message;

  const StudyImportException(this.message);

  @override
  String toString() => message;
}

/// Imports Yomitan term dictionaries (.zip) for study mode, a port of
/// meikipop's importer: structured content is flattened to plain text,
/// rows sharing a sequence number become one entry, and frequencies come
/// from the zip's own term_meta_bank files when it has them.
class StudyUserDictionaries {
  StudyUserDictionaries._();

  static Future<Directory> directory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}study_user_dicts');

  /// Installed dictionaries in load order (file name order).
  /// [from] overrides the app's directory (tests).
  static Future<List<StudyUserDictionary>> list({Directory? from}) async {
    final dir = from ?? await directory();
    if (!await dir.exists()) return const [];
    final files = await dir.list().where((f) => f is File && f.path.endsWith('.sqlite')).cast<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final result = <StudyUserDictionary>[];
    for (final file in files) {
      final db = StudyDatabase(NativeDatabase(file));
      try {
        final rows = await db.customSelect('SELECT key, value FROM meta').get();
        final meta = {for (final r in rows) r.read<String>('key'): r.read<String>('value')};
        result.add(
          StudyUserDictionary(
            file,
            meta['title'] ?? file.uri.pathSegments.last,
            int.tryParse(meta['entries'] ?? '') ?? 0,
          ),
        );
      } catch (_) {
        // A half-written or foreign file: not a usable dictionary.
      } finally {
        await db.close();
      }
    }
    return result;
  }

  static Future<void> remove(StudyUserDictionary dictionary) async {
    if (await dictionary.file.exists()) await dictionary.file.delete();
  }

  /// Imports [zipPath] and returns its title. [onProgress] gets short status
  /// lines. Runs in a background isolate; large dictionaries take a while.
  static Future<String> import(String zipPath, {void Function(String status)? onProgress, Directory? into}) async {
    final dir = into ?? await directory();
    await dir.create(recursive: true);
    final installed = await list(from: dir);
    final existing = [for (final d in installed) d.title];
    final names = [for (final d in installed) d.file.uri.pathSegments.last];
    final slot = names.map((n) => int.tryParse(n.split('-').first) ?? 0).fold(0, (a, b) => a > b ? a : b) + 1;

    final port = ReceivePort();
    final sendPort = port.sendPort;
    final sub = port.listen((m) {
      if (m is String) onProgress?.call(m);
    });
    try {
      final result = await _spawnImport(zipPath, dir.path, slot, existing, sendPort);
      if (result.startsWith('error:')) throw StudyImportException(result.substring(6));
      return result;
    } finally {
      await sub.cancel();
      port.close();
    }
  }
}

/// Its own function so the isolate closure captures only these plain values,
/// not the caller's scope (callbacks and ports there can't be sent).
Future<String> _spawnImport(String zipPath, String dirPath, int slot, List<String> existing, SendPort progress) =>
    Isolate.run(() => _importInIsolate(zipPath, dirPath, slot, existing, progress));

final _termBank = RegExp(r'(^|/)term_bank_\d+\.json$');
final _metaBank = RegExp(r'(^|/)term_meta_bank_\d+\.json$');
final _kanjiChar = RegExp(r'[一-鿿]');
const _defaultFreq = 999999;

/// Returns the title, or `error:<message>`: exceptions don't cross isolates
/// with their message intact.
Future<String> _importInIsolate(
  String zipPath,
  String dirPath,
  int slot,
  List<String> existing,
  SendPort progress,
) async {
  final input = InputFileStream(zipPath);
  File? out;
  StudyDatabase? db;
  try {
    final archive = ZipDecoder().decodeStream(input);
    final index = archive.findFile('index.json');
    if (index == null) return 'error:This is not a Yomitan dictionary (index.json is missing).';
    final title = (jsonDecode(utf8.decode(index.readBytes()!)) as Map)['title']?.toString() ?? 'Dictionary';
    if (existing.contains(title)) return 'error:"$title" is already installed.';

    final termBanks = archive.files.where((f) => f.isFile && _termBank.hasMatch(f.name)).toList()
      ..sort((a, b) => _bankNumber(a.name).compareTo(_bankNumber(b.name)));
    if (termBanks.isEmpty) {
      return 'error:"$title" has no word entries. Kanji and frequency-only dictionaries are not supported.';
    }

    progress.send('Reading $title…');
    final freq = <String, int>{};
    for (final f in archive.files.where((f) => f.isFile && _metaBank.hasMatch(f.name))) {
      for (final row in jsonDecode(utf8.decode(f.readBytes()!)) as List) {
        if (row is! List || row.length < 3 || row[1] != 'freq') continue;
        final raw = row[2];
        var reading = '';
        int? rank;
        if (raw is Map && raw.containsKey('reading')) {
          reading = raw['reading'].toString();
          rank = _rank(raw['frequency']);
        } else {
          rank = _rank(raw);
        }
        if (rank == null) continue;
        final key = '${row[0]}\u0000$reading';
        if (rank < (freq[key] ?? 1 << 62)) freq[key] = rank;
      }
      f.closeSync();
    }

    final slug = title.replaceAll(RegExp(r'[^\w]+', unicode: true), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    out = File(
      '$dirPath${Platform.pathSeparator}${slot.toString().padLeft(3, '0')}-${slug.isEmpty ? 'dictionary' : slug.substring(0, slug.length.clamp(0, 40))}.sqlite',
    );
    final partial = File('${out.path}.part');
    if (await partial.exists()) await partial.delete();
    db = StudyDatabase(NativeDatabase(partial));
    await db.customStatement('PRAGMA journal_mode=OFF');
    await db.customStatement('PRAGMA synchronous=OFF');
    await db.customStatement(
      'CREATE TABLE rows (seq INTEGER NOT NULL, term TEXT NOT NULL, reading TEXT NOT NULL, rules TEXT NOT NULL, tags TEXT NOT NULL, glosses TEXT NOT NULL)',
    );

    // Pass 1: flatten every row into a staging table, one bank at a time,
    // so a 600 MB dictionary never sits in memory at once.
    var standalone = 1000000000;
    for (final (i, bank) in termBanks.indexed) {
      progress.send('Reading $title… ${i + 1}/${termBanks.length}');
      final rows = jsonDecode(utf8.decode(bank.readBytes()!)) as List;
      bank.closeSync();
      await db.batch((b) {
        for (final row in rows) {
          if (row is! List || row.length < 6) continue;
          final glosses = _glosses(row[5]);
          if (glosses.isEmpty) continue;
          final seq = row.length > 6 && row[6] is int && row[6] != 0 ? row[6] as int : standalone++;
          b.customStatement('INSERT INTO rows VALUES (?, ?, ?, ?, ?, ?)', [
            seq,
            row[0].toString(),
            row[1]?.toString() ?? '',
            row[3]?.toString() ?? '',
            '${row[2] ?? ''} ${row.length > 7 ? row[7] ?? '' : ''}'.trim(),
            jsonEncode(glosses),
          ]);
        }
      });
    }

    // Pass 2: group by sequence into entries and lookup keys.
    progress.send('Indexing $title…');
    await db.customStatement('CREATE INDEX rows_seq ON rows (seq)');
    await db.customStatement(
      'CREATE TABLE terms (key TEXT NOT NULL, written TEXT, reading TEXT, freq INTEGER NOT NULL, entry_id INTEGER NOT NULL)',
    );
    await db.customStatement('CREATE TABLE entries (id INTEGER PRIMARY KEY, senses TEXT NOT NULL)');
    await db.customStatement('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');

    final seqs = [
      for (final r in await db.customSelect('SELECT DISTINCT seq FROM rows ORDER BY seq').get()) r.read<int>('seq'),
    ];
    var entryCount = 0;
    for (var i = 0; i < seqs.length; i += 2000) {
      final chunk = seqs.sublist(i, (i + 2000).clamp(0, seqs.length));
      final rows = await db
          .customSelect(
            'SELECT seq, term, reading, rules, tags, glosses FROM rows WHERE seq BETWEEN ? AND ? ORDER BY seq, rowid',
            variables: [Variable.withInt(chunk.first), Variable.withInt(chunk.last)],
          )
          .get();
      final groups = <int, List<QueryRow>>{};
      for (final r in rows) {
        (groups[r.read<int>('seq')] ??= []).add(r);
      }
      await db.batch((b) {
        for (final MapEntry(key: seq, value: group) in groups.entries) {
          final canonTerm = group.first.read<String>('term');
          final canonReading = group.first.read<String>('reading');
          b.customStatement('INSERT INTO entries VALUES (?, ?)', [
            seq,
            jsonEncode([
              for (final r in group)
                {
                  'glosses': jsonDecode(r.read<String>('glosses')),
                  'pos': r.read<String>('rules').split(' ').where((s) => s.isNotEmpty).toList(),
                  'tags': r.read<String>('tags').split(' ').where((s) => s.isNotEmpty).toList(),
                },
            ]),
          ]);
          entryCount++;

          int freqOf(String term, String reading) => freq['$term\u0000$reading'] ?? freq['$term\u0000'] ?? _defaultFreq;
          final seenTerms = <String>{};
          final seenReadings = <String>{};
          for (final r in group) {
            final term = r.read<String>('term');
            final reading = r.read<String>('reading');
            if (_kanjiChar.hasMatch(term) && seenTerms.add(term)) {
              final shown = reading.isEmpty ? canonReading : reading;
              b.customStatement('INSERT INTO terms VALUES (?, ?, ?, ?, ?)', [
                term,
                canonTerm,
                shown,
                freqOf(term, shown),
                seq,
              ]);
            }
            final kana = reading.isEmpty ? term : reading;
            if (seenReadings.add(kana)) {
              if (reading.isNotEmpty) {
                b.customStatement('INSERT INTO terms VALUES (?, ?, ?, ?, ?)', [
                  kana,
                  canonTerm,
                  reading,
                  freqOf(kana, reading),
                  seq,
                ]);
              } else {
                b.customStatement('INSERT INTO terms VALUES (?, ?, ?, ?, ?)', [
                  term,
                  term,
                  null,
                  freqOf(term, ''),
                  seq,
                ]);
              }
            }
          }
        }
      });
      progress.send('Indexing $title… ${(100 * (i + chunk.length) / seqs.length).round()}%');
    }

    if (entryCount == 0) return 'error:"$title" contains no definitions that study mode can show.';
    await db.customStatement('DROP TABLE rows');
    await db.customStatement('CREATE INDEX terms_key ON terms (key)');
    await db.customStatement("INSERT INTO meta VALUES ('title', ?), ('entries', ?)", [title, '$entryCount']);
    progress.send('Saving $title…');
    await db.customStatement('VACUUM');
    await db.close();
    db = null;
    await partial.rename(out.path);
    return title;
  } catch (e) {
    return 'error:$e';
  } finally {
    await db?.close();
    if (out != null) {
      final partial = File('${out.path}.part');
      if (await partial.exists()) await partial.delete();
    }
    await input.close();
  }
}

int _bankNumber(String name) => int.tryParse(RegExp(r'(\d+)\.json$').firstMatch(name)?.group(1) ?? '') ?? 0;

int? _rank(Object? v) => switch (v) {
  final num n => n.toInt(),
  final String s => int.tryParse(s),
  final Map<dynamic, dynamic> m when m.containsKey('value') => _rank(m['value']),
  final Map<dynamic, dynamic> m => _rank(m['frequency']),
  _ => null,
};

/// A Yomitan definitions array as plain-text glosses; images and
/// deinflection entries are skipped.
List<String> _glosses(Object? definitions) {
  if (definitions is! List) return const [];
  final out = <String>[];
  for (final d in definitions) {
    final String text = switch (d) {
      final String s => s,
      final Map<dynamic, dynamic> m when m['type'] == 'text' => m['text']?.toString() ?? '',
      final Map<dynamic, dynamic> m when m['type'] == 'structured-content' => _text(m['content']),
      _ => '',
    };
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isNotEmpty) out.add(clean);
  }
  return out;
}

/// Plain text of a structured-content node: ruby keeps its base text (no
/// readings), block elements get a space after them.
String _text(Object? node) {
  if (node == null) return '';
  if (node is String) return node;
  if (node is List) return node.map(_text).join();
  if (node is! Map) return '';
  final tag = node['tag'];
  final content = node['content'];
  if (tag == 'rt' || tag == 'img') return '';
  if (tag == 'ruby' && content is List) {
    return content.where((c) => !(c is Map && (c['tag'] == 'rt' || c['tag'] == 'rp'))).map(_text).join();
  }
  if (tag == 'rp') return '';
  final inner = _text(content);
  return const {'div', 'li', 'tr', 'br'}.contains(tag) ? '$inner ' : inner;
}
