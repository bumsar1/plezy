import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../services/jimaku/jimaku_service.dart';
import '../../services/settings_service.dart';
import '../../utils/dialogs.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';
import '../../widgets/video_controls/sheets/jimaku_strings.dart';

/// Fork: settings group holding the Jimaku API key. An empty submission
/// clears the key, which hides "Search Jimaku" in the player.
class JimakuSettingsGroup extends StatelessWidget {
  const JimakuSettingsGroup({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return ValueListenableBuilder<String?>(
      valueListenable: settings.listenable(JimakuService.apiKey),
      builder: (context, key, _) {
        final isSet = key != null && key.trim().isNotEmpty;
        return SettingsGroup(
          title: JimakuStrings.title,
          children: [
            SettingNavigationTile(
              icon: Symbols.key_rounded,
              title: JimakuStrings.settingsTitle,
              subtitle: isSet ? JimakuStrings.settingsSet : JimakuStrings.settingsUnset,
              trailingIcon: Symbols.edit_rounded,
              onTap: () async {
                final value = await showTextInputDialog(
                  context,
                  title: JimakuStrings.settingsTitle,
                  labelText: JimakuStrings.settingsLabel,
                  initialValue: key,
                  allowEmpty: true,
                  obscureText: true,
                );
                if (value == null) return;
                final trimmed = value.trim();
                await settings.write(JimakuService.apiKey, trimmed.isEmpty ? null : trimmed);
              },
            ),
          ],
        );
      },
    );
  }
}
