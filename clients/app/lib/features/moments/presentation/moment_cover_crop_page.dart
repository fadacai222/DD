import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

final class MomentCoverCropResult {
  const MomentCoverCropResult({required this.focalX, required this.focalY});

  final double focalX;
  final double focalY;
}

class MomentCoverCropPage extends StatefulWidget {
  const MomentCoverCropPage({
    super.key,
    required this.previewBytes,
    required this.width,
    required this.height,
  });

  final Uint8List previewBytes;
  final int width;
  final int height;

  @override
  State<MomentCoverCropPage> createState() => _MomentCoverCropPageState();
}

class _MomentCoverCropPageState extends State<MomentCoverCropPage> {
  double _focalX = 0.5;
  double _focalY = 0.5;

  Alignment get _alignment => Alignment(
    (_focalX * 2 - 1).clamp(-1.0, 1.0),
    (_focalY * 2 - 1).clamp(-1.0, 1.0),
  );

  void _drag(DragUpdateDetails details, Size viewport) {
    final dx = viewport.width <= 0 ? 0 : details.delta.dx / viewport.width;
    final dy = viewport.height <= 0 ? 0 : details.delta.dy / viewport.height;
    setState(() {
      _focalX = (_focalX - dx).clamp(0.0, 1.0);
      _focalY = (_focalY - dy).clamp(0.0, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('调整朋友圈封面'),
        actions: [
          TextButton(
            key: const Key('moment-cover-crop-done'),
            onPressed: () => Navigator.pop(
              context,
              MomentCoverCropResult(focalX: _focalX, focalY: _focalY),
            ),
            child: const Text('完成'),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final viewport = Size(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                return GestureDetector(
                  key: const Key('moment-cover-crop-viewport'),
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) => _drag(details, viewport),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(
                        widget.previewBytes,
                        fit: BoxFit.cover,
                        alignment: _alignment,
                        filterQuality: FilterQuality.medium,
                      ),
                      IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white70, width: 1),
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.add_rounded,
                              size: 24,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
      bottomNavigationBar: const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 10, 20, 18),
          child: Text(
            '拖动图片调整封面构图；最终会裁成 16:9 并本地压缩。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ),
      ),
    );
  }
}

Future<Uint8List> processMomentCoverImage(
  Uint8List source,
  MomentCoverCropResult crop,
) async {
  if (source.isEmpty) throw const FormatException('图片文件为空。');
  if (source.length > 96 * 1024 * 1024) {
    throw const FormatException('封面源图片超过 96 MiB，为避免内存耗尽无法处理。');
  }
  var decoded = img.decodeImage(source);
  if (decoded == null) throw const FormatException('无法解析封面图片。');
  decoded = img.bakeOrientation(decoded);
  const targetRatio = 16 / 9;
  var cropWidth = decoded.width;
  var cropHeight = (cropWidth / targetRatio).round();
  if (cropHeight > decoded.height) {
    cropHeight = decoded.height;
    cropWidth = (cropHeight * targetRatio).round();
  }
  final maxX = decoded.width - cropWidth;
  final maxY = decoded.height - cropHeight;
  final centerX = (crop.focalX.clamp(0.0, 1.0) * decoded.width).round();
  final centerY = (crop.focalY.clamp(0.0, 1.0) * decoded.height).round();
  final left = (centerX - cropWidth ~/ 2).clamp(0, maxX);
  final top = (centerY - cropHeight ~/ 2).clamp(0, maxY);
  var cover = img.copyCrop(
    decoded,
    x: left,
    y: top,
    width: cropWidth,
    height: cropHeight,
  );
  if (cover.width > 1920) {
    cover = img.copyResize(
      cover,
      width: 1920,
      height: 1080,
      interpolation: img.Interpolation.average,
    );
  }
  var quality = 88;
  var encoded = Uint8List.fromList(img.encodeJpg(cover, quality: quality));
  while (encoded.length > 2 * 1024 * 1024 && quality > 64) {
    quality -= 6;
    encoded = Uint8List.fromList(img.encodeJpg(cover, quality: quality));
  }
  return encoded;
}
