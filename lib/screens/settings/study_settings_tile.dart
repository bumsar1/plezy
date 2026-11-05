import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../services/settings_service.dart';
import '../../study/study_anki.dart';
import '../../study/study_strings.dart';
import '../../utils/dialogs.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';

/// Fork: where study mode's "Add to Anki" puts cards. Picks from Anki's own
/// decks and note types when Anki is running, otherwise takes a typed name.
class StudySettingsGroup extends StatelessWidget {
  const StudySettingsGroup({super.key});

  static const _automatic = '\u0000auto';

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return SettingsGroup(
      title: StudyStrings.settingsTitle,
      children: [
        ValueListenableBuilder<String?>(
          valueListenable: settings.listenable(StudyAnki.deck),
          builder: (context, deck, _) => SettingNavigationTile(
            icon: Symbols.style_rounded,
            title: StudyStrings.deckTitle,
            subtitle: StudyAnki.deckName,
            trailingIcon: Symbols.edit_rounded,
            onTap: () => _pick(context, StudyAnki.deck, StudyStrings.deckTitle, StudyAnki.deckNames, deck),
          ),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: settings.listenable(StudyAnki.noteType),
          builder: (context, model, _) => SettingNavigationTile(
            icon: Symbols.note_stack_rounded,
            title: StudyStrings.noteTypeTitle,
            subtitle: model ?? StudyStrings.noteTypeAuto,
            trailingIcon: Symbols.edit_rounded,
            onTap: () => _pick(
              context,
              StudyAnki.noteType,
              StudyStrings.noteTypeTitle,
              StudyAnki.noteTypeNames,
              model,
              allowAutomatic: true,
            ),
          ),
        ),
        FutureBuilder<String?>(
          future: StudyAnki.findFfmpeg(),
          builder: (context, snapshot) => SettingNavigationTile(
            icon: Symbols.movie_rounded,
            title: StudyStrings.ffmpegTitle,
            subtitle: snapshot.connectionState == ConnectionState.done ? StudyStrings.ffmpegStatus(snapshot.data) : '…',
            trailingIcon: snapshot.data == null ? Symbols.warning_rounded : Symbols.check_rounded,
          ),
        ),
      ],
    );
  }

  Future<void> _pick(
    BuildContext context,
    NullableStringPref pref,
    String title,
    Future<List<String>> Function() load,
    String? current, {
    bool allowAutomatic = false,
  }) async {
    List<String>? options;
    try {
      options = await load();
    } catch (_) {
      // Anki isn't reachable: fall back to typing the name.
    }
    if (!context.mounted) return;

    final String? value;
    if (options == null || options.isEmpty) {
      value = await showTextInputDialog(
        context,
        title: title,
        labelText: title,
        initialValue: current,
        allowEmpty: allowAutomatic,
      );
    } else {
      value = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(title),
          children: [
            if (allowAutomatic)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, _automatic),
                child: Text(StudyStrings.noteTypeAuto, style: TextStyle(fontWeight: _weight(current == null))),
              ),
            for (final o in options!)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, o),
                child: Text(o, style: TextStyle(fontWeight: _weight(o == current))),
              ),
          ],
        ),
      );
    }
    if (value == null) return;
    final trimmed = value == _automatic ? '' : value.trim();
    await SettingsService.instance.write(pref, trimmed.isEmpty ? null : trimmed);
  }

  static FontWeight _weight(bool selected) => selected ? FontWeight.bold : FontWeight.normal;
}
