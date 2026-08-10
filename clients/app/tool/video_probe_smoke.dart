import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:im_client/features/messaging/data/video_media_probe.dart';
import 'package:media_kit/media_kit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final samplePath = Platform.environment['DD_VIDEO_SAMPLE_MP4']?.trim() ?? '';
  if (samplePath.isEmpty || !File(samplePath).existsSync()) {
    stderr.writeln(
      'DD_VIDEO_SAMPLE_MP4 must point to a readable real MP4 fixture.',
    );
    exitCode = 2;
    return;
  }

  runApp(_VideoProbeSmokeApp(samplePath: samplePath));
}

class _VideoProbeSmokeApp extends StatefulWidget {
  const _VideoProbeSmokeApp({required this.samplePath});

  final String samplePath;

  @override
  State<_VideoProbeSmokeApp> createState() => _VideoProbeSmokeAppState();
}

class _VideoProbeSmokeAppState extends State<_VideoProbeSmokeApp> {
  String _status = '正在启动真实视频解码器…';

  void _recordResult(String value) {
    final path = Platform.environment['DD_VIDEO_PROBE_RESULT']?.trim() ?? '';
    if (path.isEmpty) return;
    try {
      File(path).writeAsStringSync(value, flush: true);
    } catch (_) {
      // The process exit code remains authoritative if the diagnostics file
      // cannot be written on a constrained CI runner.
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runProbe());
    });
  }

  Future<void> _runProbe() async {
    try {
      final metadata = await const VideoMediaProbe()
          .probeFile(XFile(widget.samplePath))
          .timeout(const Duration(seconds: 25));
      if (metadata.width <= 0 ||
          metadata.height <= 0 ||
          metadata.durationMs <= 0 ||
          metadata.posterJpeg.isEmpty) {
        throw StateError(
          'Invalid probe result: ${metadata.width}x${metadata.height} '
          '${metadata.durationMs}ms poster=${metadata.posterJpeg.length}',
        );
      }
      final result =
          'DD_VIDEO_PROBE_OK '
          '${metadata.width}x${metadata.height} '
          '${metadata.durationMs}ms poster=${metadata.posterJpeg.length}';
      stdout.writeln(result);
      _recordResult(result);
      if (mounted) setState(() => _status = '视频探针通过');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      exit(0);
    } catch (error, stackTrace) {
      final result = 'DD_VIDEO_PROBE_FAILED: $error\n$stackTrace';
      stderr.writeln(result);
      _recordResult(result);
      if (mounted) setState(() => _status = '视频探针失败：$error');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
          ),
        ),
      ),
    );
  }
}
