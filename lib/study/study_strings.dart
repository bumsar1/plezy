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
}
