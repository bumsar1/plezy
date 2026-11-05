import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../mpv/mpv.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
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

  const StudySubtitleOverlay({super.key, required this.player, this.controlsVisible});

  @override
  State<StudySubtitleOverlay> createState() => _StudySubtitleOverlayState();
}

class _StudySubtitleOverlayState extends State<StudySubtitleOverlay> {
  static const _pollInterval = Duration(milliseconds: 100);
  static const _popupWidth = 380.0;

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
      onEnter: (_) => _pointerInside = true,
      onExit: (_) {
        _pointerInside = false;
        _clearHover(resume: true);
        // Catch up with any controls change that happened while frozen.
        if (mounted) setState(() {});
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
      child: IgnorePointer(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: _StudyPopup(lookup: lookup),
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

class _StudyPopup extends StatelessWidget {
  final StudyLookup lookup;

  const _StudyPopup({required this.lookup});

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
          physics: const NeverScrollableScrollPhysics(),
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
                  _entry(entry),
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

  Widget _entry(StudyEntry entry) {
    final process = entry.process.where((p) => p.isNotEmpty).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
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
        ),
        if (process.isNotEmpty) Text(process.join(' › '), style: const TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(height: 4),
        for (final (i, sense) in entry.senses.take(5).indexed)
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
      ],
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
