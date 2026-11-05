import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../services/file_picker_service.dart';
import '../../services/settings_service.dart';
import '../../study/study_anki.dart';
import '../../study/study_dictionary.dart';
import '../../study/study_strings.dart';
import '../../study/study_user_dictionaries.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
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
        const _StudyDictionaryTiles(),
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

/// Imported Yomitan dictionaries (tap one to remove it) and the import tile.
class _StudyDictionaryTiles extends StatefulWidget {
  const _StudyDictionaryTiles();

  @override
  State<_StudyDictionaryTiles> createState() => _StudyDictionaryTilesState();
}

class _StudyDictionaryTilesState extends State<_StudyDictionaryTiles> {
  List<StudyUserDictionary> _installed = const [];
  String? _progress;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final installed = await StudyUserDictionaries.list();
    if (mounted) setState(() => _installed = installed);
  }

  Future<void> _import() async {
    final picked = await FilePickerService.instance.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    final path = picked?.files.singleOrNull?.path;
    if (path == null || !mounted) return;
    setState(() => _progress = '…');
    try {
      final title = await StudyUserDictionaries.import(
        path,
        onProgress: (s) {
          if (mounted) setState(() => _progress = s);
        },
      );
      await StudyDictionary.userDictionariesChanged();
      if (mounted) showAppSnackBar(context, StudyStrings.imported(title));
    } catch (e) {
      if (mounted) showAppSnackBar(context, StudyStrings.importFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _progress = null);
      await _refresh();
    }
  }

  Future<void> _remove(StudyUserDictionary dictionary) async {
    final confirmed = await showConfirmDialog(
      context,
      title: StudyStrings.removeTitle,
      message: StudyStrings.removeMessage(dictionary.title),
      confirmText: StudyStrings.remove,
      isDestructive: true,
    );
    if (!confirmed) return;
    // Close it in the open dictionary first, then delete the file.
    final remaining = [
      for (final d in _installed)
        if (d.file.path != dictionary.file.path) d,
    ];
    setState(() => _installed = remaining);
    await StudyDictionary.userDictionariesChanged(only: remaining);
    await StudyUserDictionaries.remove(dictionary);
    await StudyDictionary.userDictionariesChanged();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final d in _installed)
          SettingNavigationTile(
            icon: Symbols.menu_book_rounded,
            title: d.title,
            subtitle: StudyStrings.dictionaryEntries(d.entries),
            trailingIcon: Symbols.delete_rounded,
            onTap: _progress == null ? () => _remove(d) : null,
          ),
        SettingNavigationTile(
          icon: Symbols.library_add_rounded,
          title: StudyStrings.importTitle,
          subtitle: _progress ?? StudyStrings.importSubtitle,
          trailingIcon: Symbols.upload_file_rounded,
          onTap: _progress == null ? _import : null,
        ),
      ],
    );
  }
}
