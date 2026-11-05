// Study-mode test harness. NOT part of the app.
//
// Plays a local file with a subtitle, turns study mode on, hovers a word and
// writes a PNG of the Flutter layer (video excluded) plus a log line:
//   PLEZY_HARNESS_MEDIA=/path/video.mp4 PLEZY_HARNESS_SUB=/path/sub.srt \
//   PLEZY_HARNESS_OUT=/path/out flutter run -d macos -t lib/dev/study_harness_main.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../mpv/models.dart';
import '../mpv/player/player.dart';
import '../mpv/video.dart';
import '../services/settings_service.dart';
import '../study/study_mode.dart';
import '../study/study_subtitle_overlay.dart';
import '../study/study_subtitle_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsService.getInstance();
  await settings.write(StudyMode.enabled, true);
  runApp(const _HarnessApp());
}

class _HarnessApp extends StatefulWidget {
  const _HarnessApp();

  @override
  State<_HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<_HarnessApp> {
  final _boundary = GlobalKey();
  final _controls = ValueNotifier<bool>(Platform.environment['PLEZY_HARNESS_CONTROLS'] == '1');
  Player? _player;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final env = Platform.environment;
    final out = env['PLEZY_HARNESS_OUT']!;
    final player = Player();
    setState(() => _player = player);
    await player.open(Media('file://${env['PLEZY_HARNESS_MEDIA']}'));
    await player.command(['sub-add', env['PLEZY_HARNESS_SUB']!, 'select']);
    await Future<void>.delayed(const Duration(seconds: 3));

    // PLEZY_HARNESS_SYNC=1: line the loaded subtitle up with the file's English track.
    if (env['PLEZY_HARNESS_SYNC'] == '1') {
      final seek = env['PLEZY_HARNESS_SEEK'];
      if (seek != null) {
        await player.command(['seek', seek, 'absolute']);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      final result = await StudySubtitleSync.syncToEnglish(
        player,
        null,
        onStatus: (s) => stdout.writeln('HARNESS status: $s'),
      );
      stdout.writeln(
        'HARNESS sync offset=${result.offset} "${result.message}" '
        'sub-delay=${await player.getProperty('sub-delay')}',
      );
    }
    stdout.writeln(
      'HARNESS sub-text=${await player.getProperty('sub-text')} '
      'sub-visibility=${await player.getProperty('sub-visibility')} playing=${player.state.playing}',
    );

    final indices = (env['PLEZY_HARNESS_HOVER'] ?? '6').split(',').map(int.parse).toList();
    for (final (n, index) in indices.indexed) {
      final target = _findCharacter(index);
      if (target == null) {
        stdout.writeln('HARNESS no subtitle paragraph found');
        break;
      }
      GestureBinding.instance.handlePointerEvent(PointerHoverEvent(position: target, kind: PointerDeviceKind.mouse));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      stdout.writeln('HARNESS hover[$index] at $target playing=${player.state.playing}');
      await _capture('$out/hover_$n.png');
    }

    // PLEZY_HARNESS_ANKI=1: click the first entry's "Add to Anki" button.
    if (env['PLEZY_HARNESS_ANKI'] == '1') {
      final button = _findIcon(Symbols.add_circle_rounded);
      stdout.writeln('HARNESS anki button at $button');
      if (button != null) {
        // Move onto the popup first, as a user would, so it stays open.
        GestureBinding.instance.handlePointerEvent(PointerHoverEvent(position: button, kind: PointerDeviceKind.mouse));
        GestureBinding.instance.handlePointerEvent(PointerDownEvent(position: button, kind: PointerDeviceKind.mouse));
        GestureBinding.instance.handlePointerEvent(PointerUpEvent(position: button, kind: PointerDeviceKind.mouse));
        for (var i = 0; i < 60 && _findIcon(Symbols.hourglass_top_rounded) != null || i < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        stdout.writeln(
          'HARNESS anki done=${_findIcon(Symbols.check_circle_rounded) != null} '
          'failed=${_findIcon(Symbols.error_rounded) != null}',
        );
        await _capture('$out/anki.png');
      }
    }

    GestureBinding.instance.handlePointerEvent(
      const PointerHoverEvent(position: Offset(5, 5), kind: PointerDeviceKind.mouse),
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    stdout.writeln('HARNESS after exit playing=${player.state.playing}');
    await _capture('$out/exit.png');
    exit(0);
  }

  /// Global centre of character [index] in the first subtitle line.
  Offset? _findCharacter(int index) {
    RenderParagraph? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderParagraph && o.text.toPlainText().length > 3 && o.text.style?.foreground == null) {
        found = o;
        return;
      }
      o.visitChildren(visit);
    }

    visit(_boundary.currentContext!.findRenderObject()!);
    final p = found;
    if (p == null) return null;
    final box = p.getBoxesForSelection(TextSelection(baseOffset: index, extentOffset: index + 1)).first;
    return p.localToGlobal(box.toRect().center);
  }

  /// Global centre of the first drawn [icon].
  Offset? _findIcon(IconData icon) {
    final glyph = String.fromCharCode(icon.codePoint);
    Offset? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderParagraph && o.text.toPlainText() == glyph) {
        found = o.localToGlobal(o.size.center(Offset.zero));
        return;
      }
      o.visitChildren(visit);
    }

    visit(_boundary.currentContext!.findRenderObject()!);
    return found;
  }

  Future<void> _capture(String path) async {
    final boundary = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // Like the app: a themed DefaultTextStyle the overlay must not pick up.
      theme: ThemeData(textTheme: const TextTheme(bodyMedium: TextStyle(letterSpacing: 2))),
      home: Material(
        child: RepaintBoundary(
          key: _boundary,
          child: ColoredBox(
            color: const Color(0xFF203050),
            child: player == null
                ? const SizedBox.expand()
                : Stack(
                    children: [
                      Video(player: player),
                      Positioned.fill(
                        child: StudySubtitleOverlay(player: player, controlsVisible: _controls),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
