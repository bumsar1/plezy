import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/app_logger.dart';

/// The ffmpeg study mode cuts card media and reads subtitle timings with.
class StudyFfmpeg {
  StudyFfmpeg._();

  static String? _path;

  /// ffmpeg from PATH, or where Homebrew/winget put it (apps started from
  /// Finder don't inherit the shell's PATH).
  static Future<String?> find() async {
    if (_path != null) return _path;
    final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final env = Platform.environment;
    final candidates = <String>[
      for (final dir in (env['PATH'] ?? '').split(Platform.isWindows ? ';' : ':'))
        if (dir.isNotEmpty) '$dir${Platform.pathSeparator}$exe',
      if (Platform.isMacOS) ...['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg'],
      if (Platform.isWindows && env['LOCALAPPDATA'] != null)
        '${env['LOCALAPPDATA']}\\Microsoft\\WinGet\\Links\\ffmpeg.exe',
      if (Platform.isWindows) 'C:\\ffmpeg\\bin\\ffmpeg.exe',
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return _path = c;
    }
    return null;
  }

  /// mpv lists headers comma-joined (`A: x,B: y`); ffmpeg wants CRLF lines.
  static List<String> headerArgs(String? fields) {
    if (fields == null || fields.trim().isEmpty) return const [];
    final headers = fields.split(RegExp(r',(?=[A-Za-z0-9-]+:)')).where((h) => h.contains(':'));
    if (headers.isEmpty) return const [];
    return ['-headers', '${headers.map((h) => h.trim()).join('\r\n')}\r\n'];
  }

  static Future<bool> run(String ffmpeg, List<String> args) async => (await output(ffmpeg, args)) != null;

  /// Runs ffmpeg and returns its stdout as text, or null if it failed.
  static Future<String?> output(
    String ffmpeg,
    List<String> args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      final process = await Process.start(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', ...args]);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      // A Future timeout alone would leave ffmpeg running; kill it.
      final exitCode = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      if (exitCode != 0) {
        appLogger.w('Study mode: ffmpeg failed ($exitCode): ${await stderr}');
        return null;
      }
      return await stdout;
    } catch (e) {
      appLogger.w('Study mode: ffmpeg did not run', error: e);
      return null;
    }
  }
}
