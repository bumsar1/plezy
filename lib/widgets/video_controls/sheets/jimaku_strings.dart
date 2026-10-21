/// Fork-only UI text for the Jimaku integration. Kept out of the slang i18n
/// files so upstream translation updates never conflict with the fork; move
/// these into `lib/i18n/*.i18n.json` if this is ever sent upstream.
class JimakuStrings {
  JimakuStrings._();

  static const title = 'Jimaku';
  static const menuTile = 'Search Jimaku';
  static const searchHint = 'Search Jimaku';
  static const pickFromArchive = 'Choose subtitle';
  static const showAllFiles = 'Show all files';
  static String onlyEpisode(int episode) => 'Only episode $episode';
  static const noEntries = 'No Jimaku entries found';
  static const noFiles = 'This entry has no files';
  static const noSubtitlesInArchive = 'The archive holds no subtitle files';
  static String unsupportedArchive(String ext) => '.$ext archives are not supported yet';
  static String loaded(String name) => 'Loaded $name';
  static String failed(String error) => 'Jimaku: $error';
  static const invalidKey = 'Jimaku rejected the API key. Check it under Settings → Services.';
  static const rateLimited = 'Jimaku rate limit reached. Try again in a moment.';

  static const settingsTitle = 'Jimaku API key';
  static const settingsSet = 'Set — Japanese subtitles from jimaku.cc';
  static const settingsUnset = 'Not set. Create one on jimaku.cc → Account';
  static const settingsLabel = 'API key';
}
