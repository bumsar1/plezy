import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../mpv/mpv.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import 'study_dictionary.dart';

enum StudyAnkiOutcome { added, duplicate, failed }

class StudyAnkiResult {
  final StudyAnkiOutcome outcome;

  /// Why it failed, or what was left out of an added card (e.g. no ffmpeg).
  final String? message;

  const StudyAnkiResult(this.outcome, [this.message]);
}

/// The moment being mined: what was on screen and where to cut media from.
class StudyMiningContext {
  /// Subtitle text with the mined word wrapped in `<b>`.
  final String sentenceHtml;
  final String? sourceLabel;
  final Player player;

  const StudyMiningContext({required this.sentenceHtml, required this.sourceLabel, required this.player});

  static String? labelFor(MediaItem? item, Duration position) {
    if (item == null) return null;
    final time =
        '${position.inMinutes.toString().padLeft(2, '0')}:${(position.inSeconds % 60).toString().padLeft(2, '0')}';
    if (item.kind == MediaKind.episode) {
      final s = item.parentIndex;
      final e = item.index;
      final code = s != null && e != null ? ' S${s}E$e' : (e != null ? ' E$e' : '');
      return '${item.displayTitle}$code ($time)';
    }
    return '${item.displayTitle} ($time)';
  }
}

/// Adds study-mode lookups to Anki through AnkiConnect, with the subtitle
/// line's audio and an animated GIF cut from the playing video by ffmpeg,
/// plus the word's own pronunciation from JapanesePod101.
///
/// Fields are filled by name, so Lapis and most Japanese mining note types
/// work without setup; a plain Basic note gets everything on its back.
class StudyAnki {
  StudyAnki._();

  static const deck = NullableStringPref('study_anki_deck');
  static const noteType = NullableStringPref('study_anki_note_type');

  /// PLEZY_ANKICONNECT_URL points tests at a stand-in instead of the real Anki.
  static final _ankiConnect = Platform.environment['PLEZY_ANKICONNECT_URL'] ?? 'http://127.0.0.1:8765';
  static const _preferredNoteType = 'Lapis';

  /// JapanesePod101 answers unknown words with this "not available" clip.
  static const _jpodMissingMd5 = '7e2c2f954ef6051373ba916f000168dc';

  static const _audioPadding = Duration(milliseconds: 250);
  static const _maxClip = Duration(seconds: 12);
  static const _maxGif = Duration(seconds: 6);

  static String get deckName => _read(deck) ?? 'Default';

  static String? _read(NullableStringPref pref) {
    final v = SettingsService.instanceOrNull?.read(pref)?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  static Future<Object?> _invoke(String action, [Map<String, Object?> params = const {}]) async {
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse(_ankiConnect),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'action': action, 'version': 6, 'params': params}),
          )
          .timeout(const Duration(seconds: 30));
    } on SocketException {
      throw const StudyAnkiException('Anki is not running (or AnkiConnect is not installed)');
    } on TimeoutException {
      throw const StudyAnkiException('Anki did not answer');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final error = body['error'];
    if (error != null) throw StudyAnkiException(error.toString());
    return body['result'];
  }

  static Future<List<String>> deckNames() async => [for (final d in await _invoke('deckNames') as List) '$d'];

  static Future<List<String>> noteTypeNames() async => [for (final m in await _invoke('modelNames') as List) '$m'];

  static Future<StudyAnkiResult> addCard(StudyEntry entry, StudyMiningContext context) async {
    try {
      final model = _read(noteType) ?? await _defaultNoteType();
      final fieldNames = [
        for (final f in await _invoke('modelFieldNames', {'modelName': model}) as List) '$f',
      ];
      final fields = _FieldMap(fieldNames);

      final glossary = _glossaryHtml(entry);
      fields
        ..set(_FieldRole.word, entry.written)
        ..set(_FieldRole.reading, entry.reading.isEmpty ? entry.written : entry.reading)
        ..set(_FieldRole.furigana, furigana(entry.written, entry.reading))
        ..set(_FieldRole.meaning, glossary)
        ..set(_FieldRole.glossary, glossary)
        ..set(_FieldRole.sentence, context.sentenceHtml)
        ..set(_FieldRole.source, context.sourceLabel ?? '');
      // Lapis: a word card that also shows the sentence, like the user's Yomitan setup.
      if (fieldNames.contains('IsWordAndSentenceCard')) fields.raw['IsWordAndSentenceCard'] = 'x';
      if (fields.isBasic) {
        fields.raw[fieldNames[1]] = [
          if (entry.reading.isNotEmpty) entry.reading,
          glossary,
          context.sentenceHtml,
        ].join('<br>');
      }

      final notes = <String>[];
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final audio = <Map<String, Object?>>[];
      final pictures = <Map<String, Object?>>[];

      final wordAudio = await _wordAudio(entry);
      final wordAudioField = fields.fieldFor(_FieldRole.wordAudio) ?? fields.fallbackMediaField;
      if (wordAudio != null && wordAudioField != null) {
        audio.add({
          'data': base64Encode(wordAudio),
          'filename': 'plezy_word_$stamp.mp3',
          'fields': [wordAudioField],
        });
      }

      final clip = await _cutClip(context.player, stamp, notes);
      final sentenceAudioField = fields.fieldFor(_FieldRole.sentenceAudio) ?? fields.fallbackMediaField;
      if (clip.audio != null && sentenceAudioField != null) {
        audio.add({
          'data': base64Encode(clip.audio!),
          'filename': 'plezy_sentence_$stamp.mp3',
          'fields': [sentenceAudioField],
        });
      }
      final pictureField = fields.fieldFor(_FieldRole.picture) ?? fields.fallbackMediaField;
      if (clip.gif != null && pictureField != null) {
        pictures.add({
          'data': base64Encode(clip.gif!),
          'filename': 'plezy_$stamp.gif',
          'fields': [pictureField],
        });
      }

      await _invoke('addNote', {
        'note': {
          'deckName': deckName,
          'modelName': model,
          'fields': fields.raw,
          'tags': ['plezy'],
          'options': {'allowDuplicate': false, 'duplicateScope': 'deck'},
          if (audio.isNotEmpty) 'audio': audio,
          if (pictures.isNotEmpty) 'picture': pictures,
        },
      });
      return StudyAnkiResult(StudyAnkiOutcome.added, notes.isEmpty ? null : notes.join(' · '));
    } on StudyAnkiException catch (e) {
      if (e.message.contains('duplicate')) return const StudyAnkiResult(StudyAnkiOutcome.duplicate);
      return StudyAnkiResult(StudyAnkiOutcome.failed, e.message);
    } catch (e, st) {
      appLogger.w('Study mode: Anki export failed', error: e, stackTrace: st);
      return StudyAnkiResult(StudyAnkiOutcome.failed, e.toString());
    }
  }

  static Future<String> _defaultNoteType() async {
    final models = await noteTypeNames();
    if (models.contains(_preferredNoteType)) return _preferredNoteType;
    return models.contains('Basic') ? 'Basic' : models.first;
  }

  static String _glossaryHtml(StudyEntry entry) {
    String sense(StudySense s) => s.glosses.join('; ');
    final senses = entry.senses.take(8).toList();
    if (senses.length == 1) return const HtmlEscape().convert(sense(senses.single));
    return '<ol>${senses.map((s) => '<li>${const HtmlEscape().convert(sense(s))}</li>').join()}</ol>';
  }

  /// Anki's furigana syntax, `食[た]べる`: the kana the word and its reading
  /// share at either end stays plain, the rest gets the reading.
  static String furigana(String written, String reading) {
    if (reading.isEmpty || reading == written) return written;
    var head = 0;
    while (head < written.length && head < reading.length && written[head] == reading[head]) {
      head++;
    }
    var tail = 0;
    while (tail < written.length - head &&
        tail < reading.length - head &&
        written[written.length - 1 - tail] == reading[reading.length - 1 - tail]) {
      tail++;
    }
    final kanji = written.substring(head, written.length - tail);
    final kana = reading.substring(head, reading.length - tail);
    if (kanji.isEmpty || kana.isEmpty) return written;
    final prefix = written.substring(0, head);
    return '${prefix.isEmpty ? '' : '$prefix '}$kanji[$kana]${written.substring(written.length - tail)}';
  }

  static Future<List<int>?> _wordAudio(StudyEntry entry) async {
    final uri = Uri.https('assets.languagepod101.com', '/dictionary/japanese/audiomp3.php', {
      'kanji': entry.written,
      if (entry.reading.isNotEmpty) 'kana': entry.reading,
    });
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      if (md5.convert(response.bodyBytes).toString() == _jpodMissingMd5) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Media from the playing video.

  static Future<({List<int>? audio, List<int>? gif})> _cutClip(Player player, int stamp, List<String> notes) async {
    final ffmpeg = await findFfmpeg();
    if (ffmpeg == null) {
      notes.add('No ffmpeg found, so no sentence audio or GIF');
      return (audio: null, gif: null);
    }

    final source = await player.getProperty('path');
    if (source == null || source.isEmpty) return (audio: null, gif: null);

    final start = _seconds(await player.getProperty('sub-start'));
    final end = _seconds(await player.getProperty('sub-end'));
    final now = _seconds(await player.getProperty('time-pos')) ?? 0;
    var from = (start ?? now - 2) - _audioPadding.inMilliseconds / 1000;
    var to = (end ?? now + 1) + _audioPadding.inMilliseconds / 1000;
    if (from < 0) from = 0;
    if (to - from > _maxClip.inSeconds) to = from + _maxClip.inSeconds;

    final input = <String>[
      ..._headerArgs(await player.getProperty('http-header-fields')),
      '-ss',
      from.toStringAsFixed(3),
      '-i',
      source,
    ];
    final audioIndex = await player.getProperty('current-tracks/audio/ff-index');
    final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}plezy_study');
    await dir.create(recursive: true);
    final audioFile = File('${dir.path}${Platform.pathSeparator}$stamp.mp3');
    final gifFile = File('${dir.path}${Platform.pathSeparator}$stamp.gif');
    final gifLength = (to - from).clamp(0.5, _maxGif.inSeconds.toDouble());

    final results = await Future.wait([
      _runFfmpeg(ffmpeg, [
        ...input,
        '-t', (to - from).toStringAsFixed(3), //
        '-map', audioIndex == null || audioIndex.isEmpty ? '0:a:0' : '0:$audioIndex',
        '-vn', '-ac', '2', '-c:a', 'libmp3lame', '-q:a', '4',
        audioFile.path,
      ]),
      _runFfmpeg(ffmpeg, [
        ...input,
        '-t', gifLength.toStringAsFixed(3), //
        '-map', '0:v:0', '-an',
        '-vf',
        'fps=10,scale=480:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer',
        '-loop', '0',
        gifFile.path,
      ]),
    ]);

    Future<List<int>?> read(File f, bool ok) async {
      if (!ok || !await f.exists()) return null;
      final bytes = await f.readAsBytes();
      await f.delete();
      return bytes.isEmpty ? null : bytes;
    }

    final audio = await read(audioFile, results[0]);
    final gif = await read(gifFile, results[1]);
    if (audio == null) notes.add('Sentence audio could not be cut');
    if (gif == null) notes.add('GIF could not be made');
    return (audio: audio, gif: gif);
  }

  static double? _seconds(String? value) => value == null ? null : double.tryParse(value);

  /// mpv lists headers comma-joined (`A: x,B: y`); ffmpeg wants CRLF lines.
  static List<String> _headerArgs(String? fields) {
    if (fields == null || fields.trim().isEmpty) return const [];
    final headers = fields.split(RegExp(r',(?=[A-Za-z0-9-]+:)')).where((h) => h.contains(':'));
    if (headers.isEmpty) return const [];
    return ['-headers', '${headers.map((h) => h.trim()).join('\r\n')}\r\n'];
  }

  static Future<bool> _runFfmpeg(String ffmpeg, List<String> args) async {
    try {
      final result = await Process.run(ffmpeg, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        ...args,
      ]).timeout(const Duration(seconds: 60));
      if (result.exitCode != 0) appLogger.w('Study mode: ffmpeg failed: ${result.stderr}');
      return result.exitCode == 0;
    } catch (e) {
      appLogger.w('Study mode: ffmpeg did not run', error: e);
      return false;
    }
  }

  static String? _ffmpegPath;

  /// ffmpeg from PATH, or where Homebrew/winget put it (apps started from
  /// Finder don't inherit the shell's PATH).
  static Future<String?> findFfmpeg() async {
    if (_ffmpegPath != null) return _ffmpegPath;
    final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final env = Platform.environment;
    final candidates = <String>[
      for (final dir in (env['PATH'] ?? '').split(Platform.isWindows ? ';' : ':'))
        if (dir.isNotEmpty) '$dir${Platform.pathSeparator}$exe',
      if (Platform.isMacOS) ...['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'],
      if (Platform.isWindows && env['LOCALAPPDATA'] != null)
        '${env['LOCALAPPDATA']}\\Microsoft\\WinGet\\Links\\ffmpeg.exe',
      if (Platform.isWindows) 'C:\\ffmpeg\\bin\\ffmpeg.exe',
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return _ffmpegPath = c;
    }
    return null;
  }
}

class StudyAnkiException implements Exception {
  final String message;

  const StudyAnkiException(this.message);

  @override
  String toString() => message;
}

enum _FieldRole { word, reading, furigana, meaning, glossary, sentence, source, wordAudio, sentenceAudio, picture }

/// Matches a note type's fields to what study mode knows, by common names.
class _FieldMap {
  static const _names = {
    _FieldRole.word: ['expression', 'word', 'vocab', 'vocabulary', 'term', 'front'],
    _FieldRole.reading: ['expressionreading', 'reading', 'vocabreading', 'kana', 'hiragana'],
    _FieldRole.furigana: ['expressionfurigana', 'furigana', 'vocabfurigana', 'wordfurigana'],
    _FieldRole.meaning: ['maindefinition', 'meaning', 'definition', 'vocabdef', 'english'],
    _FieldRole.glossary: ['glossary'],
    _FieldRole.sentence: ['sentence', 'context', 'sentkanji', 'example'],
    _FieldRole.source: ['miscinfo', 'source', 'notes'],
    _FieldRole.wordAudio: ['expressionaudio', 'wordaudio', 'vocabaudio'],
    _FieldRole.sentenceAudio: ['sentenceaudio', 'sentaudio', 'audio'],
    _FieldRole.picture: ['picture', 'image', 'screenshot', 'pic'],
  };

  final List<String> names;
  final Map<String, String> raw;

  _FieldMap(this.names) : raw = {for (final n in names) n: ''};

  String? fieldFor(_FieldRole role) {
    for (final candidate in _names[role]!) {
      for (final n in names) {
        if (n.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '') == candidate) return n;
      }
    }
    return null;
  }

  /// A plain Front/Back note: nothing beyond the word matched by name.
  bool get isBasic =>
      names.length >= 2 &&
      fieldFor(_FieldRole.meaning) == null &&
      fieldFor(_FieldRole.glossary) == null &&
      fieldFor(_FieldRole.sentence) == null;

  /// Where media goes when the note type has no field for it.
  String? get fallbackMediaField => isBasic ? names[1] : null;

  void set(_FieldRole role, String value) {
    final field = fieldFor(role);
    if (field != null && (raw[field] ?? '').isEmpty) raw[field] = value;
  }
}
