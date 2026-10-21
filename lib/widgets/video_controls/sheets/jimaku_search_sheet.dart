import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_text_field.dart';
import '../../../media/ids.dart';
import '../../../media/media_item.dart';
import '../../../mixins/controller_disposer_mixin.dart';
import '../../../services/jimaku/jimaku_client.dart';
import '../../../services/jimaku/jimaku_service.dart';
import '../../../utils/provider_extensions.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import '../../../widgets/pill_input_decoration.dart';
import '../../loading_indicator_box.dart';
import 'base_video_control_sheet.dart';
import 'jimaku_strings.dart';

/// Loads a subtitle file from disk into the running player and selects it.
typedef JimakuAddSubtitle = Future<void> Function(String path, String title);

/// Jimaku search: entries for the playing item, then that entry's files, then
/// (for archives holding several subtitles) the subtitle to load.
class JimakuSearchSheet extends StatefulWidget {
  final MediaItem item;
  final JimakuAddSubtitle onAddSubtitle;

  const JimakuSearchSheet({super.key, required this.item, required this.onAddSubtitle});

  @override
  State<JimakuSearchSheet> createState() => _JimakuSearchSheetState();
}

enum _View { entries, files, archive }

class _JimakuSearchSheetState extends State<JimakuSearchSheet> with ControllerDisposerMixin {
  late final JimakuClient _jimaku = JimakuClient(JimakuService.readApiKey() ?? '');
  late final _queryController = createTextEditingController();
  Timer? _debounce;
  int _generation = 0;

  _View _view = _View.entries;
  bool _loading = true;
  String? _error;

  int? _episode;
  List<JimakuEntry> _entries = const [];
  JimakuEntry? _entry;
  List<JimakuFile> _files = const [];
  bool _showAllFiles = false;
  List<File> _archiveSubtitles = const [];
  String? _busyName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialLookup());
  }

  @override
  void dispose() {
    ++_generation;
    _debounce?.cancel();
    _jimaku.close();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(int generation) body) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await body(generation);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = _describe(e));
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  String _describe(Object e) {
    if (e is JimakuException) {
      if (e.isUnauthorized) return JimakuStrings.invalidKey;
      if (e.isRateLimited) return JimakuStrings.rateLimited;
    }
    return JimakuStrings.failed(e.toString());
  }

  Future<void> _initialLookup() => _run((generation) async {
    final serverId = widget.item.serverId;
    final server = serverId == null ? null : context.tryGetMediaClientForServer(ServerId(serverId));
    if (server == null) throw const JimakuException('No server connection');
    final result = await JimakuService.lookup(_jimaku, server, widget.item);
    if (!mounted || generation != _generation) return;
    _episode = result.episode;
    _queryController.text = result.query;
    _entries = result.entries;
    if (_entries.length == 1) await _openEntry(_entries.single, generation);
  });

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _searchByQuery);
  }

  Future<void> _searchByQuery() => _run((generation) async {
    final query = _queryController.text.trim();
    final entries = query.isEmpty ? const <JimakuEntry>[] : await _jimaku.searchEntries(query: query);
    if (!mounted || generation != _generation) return;
    setState(() {
      _view = _View.entries;
      _entries = entries;
    });
  });

  Future<void> _openEntry(JimakuEntry entry, int generation) async {
    var files = _showAllFiles || _episode == null
        ? await _jimaku.listFiles(entry.id)
        : await _jimaku.listFiles(entry.id, episode: _episode);
    // Jimaku's episode filter guesses from filenames; season packs often match nothing.
    if (files.isEmpty && !_showAllFiles && _episode != null) {
      files = await _jimaku.listFiles(entry.id);
      _showAllFiles = true;
    }
    if (!mounted || generation != _generation) return;
    files.sort((a, b) {
      final usable = (JimakuService.isUsable(a) ? 0 : 1) - (JimakuService.isUsable(b) ? 0 : 1);
      return usable != 0 ? usable : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    setState(() {
      _entry = entry;
      _files = files;
      _view = _View.files;
    });
  }

  Future<void> _toggleShowAll() async {
    final entry = _entry;
    if (entry == null) return;
    _showAllFiles = !_showAllFiles;
    await _run((generation) => _openEntry(entry, generation));
  }

  Future<void> _pickFile(JimakuFile file) async {
    if (_busyName != null) return;
    setState(() => _busyName = file.name);
    try {
      final subtitles = await JimakuService.fetchSubtitleFiles(_jimaku, file, episode: _episode);
      if (!mounted) return;
      if (subtitles.isEmpty) {
        showErrorSnackBar(context, JimakuStrings.noSubtitlesInArchive);
      } else if (subtitles.length == 1) {
        await _apply(subtitles.single);
      } else {
        setState(() {
          _archiveSubtitles = subtitles;
          _view = _View.archive;
        });
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, _describe(e));
    } finally {
      if (mounted) setState(() => _busyName = null);
    }
  }

  Future<void> _apply(File subtitle) async {
    final name = subtitle.uri.pathSegments.last;
    try {
      await widget.onAddSubtitle(subtitle.path, 'Jimaku: $name');
      if (!mounted) return;
      showSuccessSnackBar(context, JimakuStrings.loaded(name));
      OverlaySheetController.of(context).close();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, JimakuStrings.failed(e.toString()));
    }
  }

  void _back() {
    switch (_view) {
      case _View.archive:
        setState(() => _view = _View.files);
      case _View.files when _entries.length > 1:
        setState(() => _view = _View.entries);
      case _View.files || _View.entries:
        OverlaySheetController.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return BaseVideoControlSheet(
      title: switch (_view) {
        _View.entries => JimakuStrings.title,
        _View.files => _entry?.name ?? JimakuStrings.title,
        _View.archive => JimakuStrings.pickFromArchive,
      },
      icon: Symbols.subtitles_rounded,
      onBack: _back,
      child: Column(
        children: [
          if (_view == _View.entries)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: FocusableTextField(
                controller: _queryController,
                tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
                decoration: pillInputDecoration(
                  context,
                  hintText: JimakuStrings.searchHint,
                  prefixIcon: const AppIcon(Symbols.search_rounded, size: 20),
                ),
                onChanged: _onQueryChanged,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => unawaited(_searchByQuery()),
              ),
            ),
          if (_view == _View.files && _episode != null)
            FocusableListTile(
              leading: AppIcon(_showAllFiles ? Symbols.filter_alt_off_rounded : Symbols.filter_alt_rounded),
              title: Text(_showAllFiles ? JimakuStrings.onlyEpisode(_episode!) : JimakuStrings.showAllFiles),
              onTap: _loading ? null : _toggleShowAll,
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: colorScheme.error)),
        ),
      );
    }

    Widget empty(String text) => Center(
      child: Text(text, style: TextStyle(color: colorScheme.onSurfaceVariant)),
    );

    switch (_view) {
      case _View.entries:
        if (_entries.isEmpty) return empty(JimakuStrings.noEntries);
        return ListView.builder(
          itemCount: _entries.length,
          itemBuilder: (context, index) {
            final entry = _entries[index];
            final subtitle = [entry.japaneseName, entry.englishName].whereType<String>().join(' · ');
            return FocusableListTile(
              title: Text(entry.name, maxLines: 1, overflow: .ellipsis),
              subtitle: subtitle.isEmpty
                  ? null
                  : Text(
                      subtitle,
                      maxLines: 1,
                      overflow: .ellipsis,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
              onTap: () => _run((generation) => _openEntry(entry, generation)),
            );
          },
        );
      case _View.files:
        if (_files.isEmpty) return empty(JimakuStrings.noFiles);
        return ListView.builder(
          itemCount: _files.length,
          itemBuilder: (context, index) {
            final file = _files[index];
            final usable = JimakuService.isUsable(file);
            final busy = _busyName == file.name;
            return FocusableListTile(
              leading: AppIcon(
                JimakuService.subtitleExtensions.contains(file.extension)
                    ? Symbols.subtitles_rounded
                    : Symbols.folder_zip_rounded,
                color: usable ? null : colorScheme.onSurfaceVariant,
              ),
              title: Text(
                file.name,
                maxLines: 2,
                overflow: .ellipsis,
                style: TextStyle(color: usable ? null : colorScheme.onSurfaceVariant),
              ),
              subtitle: Text(
                usable ? _formatSize(file.size) : JimakuStrings.unsupportedArchive(file.extension),
                style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
              ),
              trailing: busy ? const LoadingIndicatorBox(size: 20) : null,
              onTap: usable && _busyName == null ? () => _pickFile(file) : null,
            );
          },
        );
      case _View.archive:
        return ListView.builder(
          itemCount: _archiveSubtitles.length,
          itemBuilder: (context, index) {
            final subtitle = _archiveSubtitles[index];
            final name = subtitle.uri.pathSegments.last;
            final matches = _episode != null && JimakuService.matchesEpisode(name, _episode!);
            return FocusableListTile(
              leading: AppIcon(Symbols.subtitles_rounded, color: matches ? colorScheme.primary : null),
              title: Text(name, maxLines: 2, overflow: .ellipsis),
              onTap: () => _apply(subtitle),
            );
          },
        );
    }
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
