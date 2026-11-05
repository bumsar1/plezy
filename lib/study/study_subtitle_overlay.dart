import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../media/media_item.dart';
import '../mpv/mpv.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../widgets/app_icon.dart';
import 'study_anki.dart';
import 'study_dictionary.dart';
import 'study_mode.dart';
import 'study_strings.dart';

/// Draws the current subtitle as hoverable text while study mode is on.
/// Hovering a character pauses playback, highlights the word starting there
/// and shows its dictionary entry; leaving the subtitle resumes playback if
/// study mode was what paused it.
///
/// Sits above the video controls in the player's Stack so hover reaches it,
/// and claims hits only on the subtitle text itself.
class StudySubtitleOverlay extends StatefulWidget {
  final Player player;

  /// Whether the player controls are showing; the subtitle moves up so the
  /// bottom bar doesn't cover it.
  final ValueListenable<bool>? controlsVisible;

  /// What is playing, for the card's source line.
  final MediaItem? metadata;

  const StudySubtitleOverlay({super.key, required this.player, this.controlsVisible, this.metadata});

  @override
  State<StudySubtitleOverlay> createState() => _StudySubtitleOverlayState();
}

class _StudySubtitleOverlayState extends State<StudySubtitleOverlay> {
  static const _pollInterval = Duration(milliseconds: 100);
  static const _popupWidth = 440.0;

  /// Clearance above the desktop controls' seek bar and button row.
  static const _controlsClearance = 130.0;

  final _overlayKey = GlobalKey();
  final List<GlobalKey> _lineKeys = [];

  late final ValueNotifier<bool> _enabled;
  Timer? _poll;
  bool _polling = false;
  String _text = '';

  StudyDictionary? _dictionary;
  double? _downloadProgress;
  String? _loadError;

  // Hover state.
  int? _hoverLine;
  int? _hoverIndex;
  StudyLookup? _lookup;
  Rect? _wordRect;
  int _lookupToken = 0;
  bool _pausedByUs = false;

  // While the pointer is on the subtitle it stays put, so showing or hiding
  // the controls never slides the text out from under the cursor.
  bool _pointerInside = false;
  double? _frozenBottom;

  // The popup can be entered (for its Anki buttons); it closes once the
  // pointer is on neither it nor the subtitle.
  bool _pointerOnPopup = false;
  Timer? _closeTimer;
  final Map<int, _AnkiState> _ankiStates = {};

  @override
  void initState() {
    super.initState();
    // A new player starts with subtitles shown, like the controls' own toggle.
    StudyMode.subtitlesVisible.value = true;
    _enabled = SettingsService.instance.listenable(StudyMode.enabled);
    _enabled.addListener(_onEnabledChanged);
    StudyMode.subtitlesVisible.addListener(_applyMpvVisibility);
    widget.controlsVisible?.addListener(_onControlsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onEnabledChanged();
    });
  }

  @override
  void didUpdateWidget(covariant StudySubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controlsVisible != widget.controlsVisible) {
      oldWidget.controlsVisible?.removeListener(_onControlsChanged);
      widget.controlsVisible?.addListener(_onControlsChanged);
    }
    if (oldWidget.player != widget.player) {
      _clearHover(resume: false);
      _onEnabledChanged();
    }
  }

  @override
  void dispose() {
    _enabled.removeListener(_onEnabledChanged);
    StudyMode.subtitlesVisible.removeListener(_applyMpvVisibility);
    widget.controlsVisible?.removeListener(_onControlsChanged);
    _poll?.cancel();
    _closeTimer?.cancel();
    super.dispose();
  }

  void _onControlsChanged() {
    if (mounted && !_pointerInside) setState(() {});
  }

  bool get _active => _enabled.value && StudyMode.supports(widget.player);

  void _onEnabledChanged() {
    _applyMpvVisibility();
    _poll?.cancel();
    _poll = null;
    if (!_active) {
      _clearHover(resume: true);
      if (mounted) setState(() => _text = '');
      return;
    }
    _poll = Timer.periodic(_pollInterval, (_) => _pollSubtitle());
    _loadDictionary();
  }

  void _applyMpvVisibility() {
    final player = widget.player;
    unawaited(
      player
          .setProperty('sub-visibility', StudyMode.mpvSubVisibility(player, StudyMode.subtitlesVisible.value))
          .catchError((Object e) => appLogger.w('Study mode: failed to set sub-visibility', error: e)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _loadDictionary() async {
    if (_dictionary != null) return;
    setState(() => _loadError = null);
    try {
      final dictionary = await StudyDictionary.open(
        onProgress: (p) {
          if (mounted) setState(() => _downloadProgress = p);
        },
      );
      if (mounted) setState(() => _dictionary = dictionary);
    } catch (e, st) {
      appLogger.w('Study mode: dictionary unavailable', error: e, stackTrace: st);
      if (mounted) setState(() => _loadError = e.toString());
    } finally {
      if (mounted) setState(() => _downloadProgress = null);
    }
  }

  Future<void> _pollSubtitle() async {
    if (_polling) return;
    _polling = true;
    try {
      final text = (await widget.player.getProperty('sub-text') ?? '').trim();
      if (!mounted || text == _text) return;
      _clearHover(resume: false);
      setState(() => _text = text);
    } catch (_) {
      // Player not ready or already disposed; the next tick tries again.
    } finally {
      _polling = false;
    }
  }

  void _clearHover({required bool resume}) {
    _lookupToken++;
    if (resume && _pausedByUs && !widget.player.state.playing) unawaited(widget.player.play());
    if (resume) _pausedByUs = false;
    if (_hoverIndex == null && _lookup == null) return;
    _hoverLine = null;
    _hoverIndex = null;
    _lookup = null;
    _wordRect = null;
    if (mounted) setState(() {});
  }

  void _onHover(int line, String text, Offset local) {
    final paragraph = _lineKeys[line].currentContext?.findRenderObject();
    if (paragraph is! RenderParagraph) return;
    final index = _characterAt(paragraph, text, local);
    if (index == null) return;
    if (line == _hoverLine && index == _hoverIndex) return;

    if (widget.player.state.playing) {
      _pausedByUs = true;
      unawaited(widget.player.pause());
    }
    _hoverLine = line;
    _hoverIndex = index;
    _lookupWord(paragraph, text, line, index);
  }

  /// The character under [local], or null when the pointer is between glyphs.
  int? _characterAt(RenderParagraph paragraph, String text, Offset local) {
    final caret = paragraph.getPositionForOffset(local).offset;
    for (final i in [caret, caret - 1]) {
      if (i < 0 || i >= text.length) continue;
      final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1));
      if (boxes.any((b) => b.toRect().inflate(1).contains(local))) return i;
    }
    return null;
  }

  Future<void> _lookupWord(RenderParagraph paragraph, String text, int line, int index) async {
    final dictionary = _dictionary;
    if (dictionary == null) return;
    final token = ++_lookupToken;
    final lookup = await dictionary.lookup(text.substring(index));
    if (!mounted || token != _lookupToken) return;

    final end = math.min(text.length, index + math.max(1, lookup.matchLength).toInt());
    final overlay = _overlayKey.currentContext?.findRenderObject() as RenderBox?;
    Rect? rect;
    if (overlay != null && paragraph.attached) {
      for (final box in paragraph.getBoxesForSelection(TextSelection(baseOffset: index, extentOffset: end))) {
        final r = box.toRect();
        final global = Rect.fromPoints(paragraph.localToGlobal(r.topLeft), paragraph.localToGlobal(r.bottomRight));
        final local = Rect.fromPoints(overlay.globalToLocal(global.topLeft), overlay.globalToLocal(global.bottomRight));
        rect = rect == null ? local : rect.expandToInclude(local);
      }
    }
    setState(() {
      _lookup = lookup;
      _wordRect = rect;
      _ankiStates.clear();
    });
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _pointerInside || _pointerOnPopup) return;
      _clearHover(resume: true);
      // Catch up with any controls change that happened while frozen.
      setState(() {});
    });
  }

  /// The hovered subtitle with the matched word in bold, as card HTML.
  String _sentenceHtml(StudyEntry entry) {
    const escape = HtmlEscape(HtmlEscapeMode.element);
    final lines = _text.split('\n');
    final line = _hoverLine;
    final start = _hoverIndex;
    return [
      for (var i = 0; i < lines.length; i++)
        if (i == line && start != null && start < lines[i].length)
          '${escape.convert(lines[i].substring(0, start))}'
              '<b>${escape.convert(lines[i].substring(start, math.min(lines[i].length, start + entry.matchLength)))}</b>'
              '${escape.convert(lines[i].substring(math.min(lines[i].length, start + entry.matchLength)))}'
        else
          escape.convert(lines[i]),
    ].join('<br>');
  }

  Future<void> _addToAnki(int index, StudyEntry entry) async {
    final token = _lookupToken;
    setState(() => _ankiStates[index] = const _AnkiState(_AnkiStatus.adding));
    final result = await StudyAnki.addCard(
      entry,
      StudyMiningContext(
        sentenceHtml: _sentenceHtml(entry),
        sourceLabel: StudyMiningContext.labelFor(widget.metadata, widget.player.state.position),
        player: widget.player,
      ),
    );
    if (!mounted || token != _lookupToken) return;
    setState(() {
      _ankiStates[index] = switch (result.outcome) {
        StudyAnkiOutcome.added => _AnkiState(_AnkiStatus.added, result.message),
        StudyAnkiOutcome.duplicate => const _AnkiState(_AnkiStatus.added, StudyStrings.ankiDuplicate),
        StudyAnkiOutcome.failed => _AnkiState(_AnkiStatus.failed, result.message),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();
    final settings = SettingsService.instance;

    return LayoutBuilder(
      key: _overlayKey,
      builder: (context, constraints) {
        final scale = constraints.maxHeight / 720;
        final fontSize = settings.read(SettingsService.subtitleFontSize) * scale;
        final border = settings.read(SettingsService.subtitleBorderSize) * scale;
        // mpv's sub-pos: 100 is the bottom edge, with its default 22px margin.
        final position = settings.read(SettingsService.subtitlePosition);
        var bottom = (22 * scale) + (100 - position) / 100 * constraints.maxHeight;
        if (widget.controlsVisible?.value ?? false) bottom = math.max(bottom, _controlsClearance);
        if (_pointerInside) bottom = _frozenBottom ?? bottom;
        _frozenBottom = bottom;

        return Stack(
          children: [
            if (StudyMode.subtitlesVisible.value && _text.isNotEmpty)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                left: 24,
                right: 24,
                bottom: bottom,
                child: Center(child: _buildSubtitle(fontSize, border, settings.read(SettingsService.subtitleBold))),
              ),
            if (_lookup != null && _wordRect != null) _buildPopup(constraints, _lookup!, _wordRect!),
            if (_downloadProgress != null || _loadError != null || (_dictionary == null && _text.isNotEmpty))
              Positioned(left: 16, bottom: 16, child: _buildStatus()),
          ],
        );
      },
    );
  }

  Widget _buildSubtitle(double fontSize, double border, bool bold) {
    final lines = _text.split('\n');
    while (_lineKeys.length < lines.length) {
      _lineKeys.add(GlobalKey());
    }
    final base = TextStyle(
      fontSize: fontSize,
      height: 1.25,
      decoration: TextDecoration.none,
      fontWeight: bold ? FontWeight.bold : FontWeight.w500,
      color: Colors.white,
    );

    return MouseRegion(
      onEnter: (_) {
        _pointerInside = true;
        _closeTimer?.cancel();
      },
      onExit: (_) {
        _pointerInside = false;
        _scheduleClose();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < lines.length; i++)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              onHover: (e) => _onHover(i, lines[i], e.localPosition),
              child: Stack(
                children: [
                  // Outline underneath, laid out identically to the hit-tested text.
                  // RichText for both: Text would merge the app's DefaultTextStyle
                  // and lay out differently from the text on top.
                  RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      text: lines[i],
                      style: base.copyWith(
                        foreground: Paint()
                          ..style = PaintingStyle.stroke
                          ..strokeWidth = border * 2
                          ..strokeJoin = StrokeJoin.round
                          ..color = Colors.black,
                      ),
                    ),
                  ),
                  RichText(key: _lineKeys[i], textAlign: TextAlign.center, text: _highlighted(lines[i], i, base)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  TextSpan _highlighted(String line, int lineIndex, TextStyle base) {
    final start = _hoverIndex;
    final lookup = _lookup;
    if (_hoverLine != lineIndex || start == null || lookup == null || lookup.isEmpty) {
      return TextSpan(text: line, style: base);
    }
    final end = math.min(line.length, start + lookup.matchLength);
    return TextSpan(
      style: base,
      children: [
        TextSpan(text: line.substring(0, start)),
        TextSpan(
          text: line.substring(start, end),
          style: const TextStyle(color: Color(0xFFFFD54F)),
        ),
        TextSpan(text: line.substring(end)),
      ],
    );
  }

  Widget _buildPopup(BoxConstraints constraints, StudyLookup lookup, Rect word) {
    final width = math.min(_popupWidth, constraints.maxWidth - 16);
    final left = (word.center.dx - width / 2).clamp(8.0, constraints.maxWidth - width - 8);
    final maxHeight = math.max(80.0, word.top - 16);

    return Positioned(
      left: left,
      bottom: constraints.maxHeight - word.top + 8,
      width: width,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) {
          _pointerOnPopup = true;
          _closeTimer?.cancel();
        },
        onExit: (_) {
          _pointerOnPopup = false;
          _scheduleClose();
        },
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: _StudyPopup(lookup: lookup, ankiStates: _ankiStates, onAdd: _addToAnki),
        ),
      ),
    );
  }

  Widget _buildStatus() {
    final progress = _downloadProgress;
    final text = _loadError != null
        ? StudyStrings.failed(_loadError!)
        : progress != null
        ? StudyStrings.downloading((progress * 100).round())
        : StudyStrings.loading;
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
      ),
    );
  }
}

enum _AnkiStatus { adding, added, failed }

class _AnkiState {
  final _AnkiStatus status;
  final String? message;

  const _AnkiState(this.status, [this.message]);
}

class _StudyPopup extends StatelessWidget {
  final StudyLookup lookup;
  final Map<int, _AnkiState> ankiStates;
  final void Function(int index, StudyEntry entry) onAdd;

  const _StudyPopup({required this.lookup, required this.ankiStates, required this.onAdd});

  static const _muted = Color(0xFFB0B0B8);
  static const _accent = Color(0xFFFFD54F);

  @override
  Widget build(BuildContext context) {
    final kanji = lookup.kanji;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xF01C1C22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 16)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.35, decoration: TextDecoration.none),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (lookup.isEmpty) const Text(StudyStrings.noMatch, style: TextStyle(color: _muted)),
                for (final (i, entry) in lookup.entries.indexed) ...[
                  if (i > 0) const Divider(color: Colors.white12, height: 16),
                  _entry(i, entry),
                ],
                if (kanji != null) ...[
                  if (lookup.entries.isNotEmpty) const Divider(color: Colors.white12, height: 16),
                  _kanji(kanji),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _ankiButton(int index, StudyEntry entry) {
    final state = ankiStates[index];
    final (IconData icon, Color color, String tooltip) = switch (state?.status) {
      null => (Symbols.add_circle_rounded, Colors.white, StudyStrings.ankiAdd),
      _AnkiStatus.adding => (Symbols.hourglass_top_rounded, _muted, StudyStrings.ankiAdding),
      _AnkiStatus.added => (Symbols.check_circle_rounded, const Color(0xFF81C784), StudyStrings.ankiAdded),
      _AnkiStatus.failed => (Symbols.error_rounded, const Color(0xFFE57373), StudyStrings.ankiRetry),
    };
    final enabled = state == null || state.status == _AnkiStatus.failed;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? () => onAdd(index, entry) : null,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AppIcon(icon, size: 22, color: color, fill: state == null ? 0 : 1),
        ),
      ),
    );
  }

  Widget _entry(int index, StudyEntry entry) {
    final process = entry.process.where((p) => p.isNotEmpty).toList();
    final message = ankiStates[index]?.message;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _headword(entry)),
            _ankiButton(index, entry),
          ],
        ),
        if (message != null)
          Text(
            message,
            style: TextStyle(
              color: ankiStates[index]?.status == _AnkiStatus.failed ? const Color(0xFFE57373) : _muted,
              fontSize: 12,
            ),
          ),
        if (process.isNotEmpty) Text(process.join(' › '), style: const TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 4),
        for (final (i, sense) in entry.senses.where((s) => s.dictionary == null).take(5).indexed)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${i + 1}. ',
                    style: const TextStyle(color: _muted),
                  ),
                  TextSpan(text: sense.glosses.join('; ')),
                  if (sense.pos.isNotEmpty)
                    TextSpan(
                      text: '  ${sense.pos.join(', ')}',
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                ],
              ),
            ),
          ),
        for (final MapEntry(key: title, value: senses) in _imported(entry).entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(
              title,
              style: const TextStyle(color: _muted, fontSize: 11, fontStyle: FontStyle.italic),
            ),
          ),
          for (final sense in senses.take(3))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(sense.glosses.join(' '), maxLines: 8, overflow: TextOverflow.ellipsis),
            ),
        ],
      ],
    );
  }

  static Map<String, List<StudySense>> _imported(StudyEntry entry) {
    final out = <String, List<StudySense>>{};
    for (final s in entry.senses) {
      if (s.dictionary != null) (out[s.dictionary!] ??= []).add(s);
    }
    return out;
  }

  Widget _headword(StudyEntry entry) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: entry.written,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: _accent),
          ),
          if (entry.reading.isNotEmpty && entry.reading != entry.written)
            TextSpan(text: '  ${entry.reading}', style: const TextStyle(fontSize: 15)),
        ],
      ),
    );
  }

  Widget _kanji(StudyKanji kanji) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(kanji.character, style: const TextStyle(fontSize: 28, color: _accent)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (kanji.readings.isNotEmpty) Text(kanji.readings.join('、'), style: const TextStyle(fontSize: 13)),
              Text(kanji.meanings.join(', '), style: const TextStyle(color: _muted, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }
}
