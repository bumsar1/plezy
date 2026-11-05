import 'package:flutter/foundation.dart';

import '../mpv/mpv.dart';
import '../mpv/player/platform/player_android.dart';
import '../services/settings_service.dart';

/// Study mode: Plezy draws the subtitles itself so each word can be hovered
/// for a dictionary popup (see [StudySubtitleOverlay]), while mpv's own
/// subtitle rendering is switched off.
class StudyMode {
  StudyMode._();

  static const enabled = BoolPref('study_mode');

  /// The viewer's subtitle on/off toggle. In study mode mpv always renders
  /// nothing, so this tells the overlay whether to draw.
  static final subtitlesVisible = ValueNotifier<bool>(true);

  static bool get isOn => SettingsService.instanceOrNull?.read(enabled) ?? false;

  /// The overlay reads mpv's `sub-text`; ExoPlayer has no such property.
  static bool supports(Player player) => player is! PlayerAndroid;

  /// What mpv's own `sub-visibility` should be for the viewer's [visible].
  static String mpvSubVisibility(Player player, bool visible) => visible && !(isOn && supports(player)) ? 'yes' : 'no';
}
