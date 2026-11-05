import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../media/media_item.dart';
import '../mpv/mpv.dart';
import '../theme/mono_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/focusable_list_tile.dart';
import 'study_strings.dart';
import 'study_subtitle_sync.dart';

/// Video settings row: "Sync subtitles to English", with the outcome shown
/// in place of a value.
class StudySyncMenuItem extends StatefulWidget {
  final Player player;
  final MediaItem? metadata;

  const StudySyncMenuItem({super.key, required this.player, required this.metadata});

  @override
  State<StudySyncMenuItem> createState() => _StudySyncMenuItemState();
}

class _StudySyncMenuItemState extends State<StudySyncMenuItem> {
  bool _running = false;
  String? _status;

  Future<void> _sync() async {
    setState(() {
      _running = true;
      _status = StudyStrings.syncing;
    });
    final result = await StudySubtitleSync.syncToEnglish(widget.player, widget.metadata);
    if (!mounted) return;
    setState(() {
      _running = false;
      _status = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = tokens(context);
    return FocusableListTile(
      leading: AppIcon(Symbols.sync_alt_rounded, fill: 1, color: t.textMuted),
      title: const Text(StudyStrings.syncTitle),
      subtitle: Text(_status ?? StudyStrings.syncSubtitle, style: TextStyle(color: t.textMuted, fontSize: 12)),
      onTap: _running ? null : _sync,
    );
  }
}
