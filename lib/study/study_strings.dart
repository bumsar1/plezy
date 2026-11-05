/// Fork-only UI text for study mode, kept out of slang i18n like
/// `JimakuStrings` so upstream translation updates never conflict.
class StudyStrings {
  StudyStrings._();

  static const toggle = 'Study mode';
  static const toggleSubtitle = 'Hover Japanese subtitles to look up words';
  static String downloading(int percent) => 'Downloading dictionary… $percent%';
  static const loading = 'Loading dictionary…';
  static String failed(String error) => 'Study mode: $error';
  static const noMatch = 'No dictionary match';

  static const ankiAdd = 'Add to Anki';
  static const ankiAdding = 'Adding to Anki…';
  static const ankiAdded = 'Added to Anki';
  static const ankiRetry = 'Failed — click to try again';
  static const ankiDuplicate = 'Already in this deck';

  static const settingsTitle = 'Study mode';
  static const deckTitle = 'Anki deck';
  static const noteTypeTitle = 'Anki note type';
  static const noteTypeAuto = 'Automatic (Lapis if installed, else Basic)';
  static String ffmpegStatus(String? path) => path ?? 'Not found — install ffmpeg for sentence audio and GIFs';
  static const ffmpegTitle = 'ffmpeg';

  static const importTitle = 'Import Yomitan dictionary';
  static const importSubtitle = 'A term dictionary .zip — shown below JMdict in the popup';
  static String imported(String title) => 'Imported $title';
  static String importFailed(String error) => 'Import failed: $error';
  static String dictionaryEntries(int count) => '$count entries — tap to remove';
  static const removeTitle = 'Remove dictionary?';
  static String removeMessage(String title) => '"$title" will no longer appear in study mode.';
  static const remove = 'Remove';

  static const syncTitle = 'Sync subtitles to English';
  static const syncSubtitle = 'Line the selected subtitles up with the video\'s English track';
  static const syncing = 'Syncing…';
}
