import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'avatar_image_processor.dart';

class AvatarCropPage extends StatefulWidget {
  const AvatarCropPage({super.key, required this.preview});

  final AvatarCropPreview preview;

  @override
  State<AvatarCropPage> createState() => _AvatarCropPageState();
}

class _AvatarCropPageState extends State<AvatarCropPage> {
  double _viewport = 0;
  double _zoom = 1;
  Offset _offset = Offset.zero;
  double _startZoom = 1;
  Offset _anchorImagePoint = Offset.zero;

  double get _baseScale => _viewport <= 0
      ? 1
      : math.max(
          _viewport / widget.preview.width,
          _viewport / widget.preview.height,
        );

  void _configureViewport(double size) {
    if (size <= 0 || (_viewport - size).abs() < 0.5) return;
    _viewport = size;
    _zoom = 1;
    final width = widget.preview.width * _baseScale;
    final height = widget.preview.height * _baseScale;
    _offset = Offset((_viewport - width) / 2, (_viewport - height) / 2);
  }

  void _startScale(ScaleStartDetails details) {
    _startZoom = _zoom;
    final scale = _baseScale * _zoom;
    _anchorImagePoint = Offset(
      (details.localFocalPoint.dx - _offset.dx) / scale,
      (details.localFocalPoint.dy - _offset.dy) / scale,
    );
  }

  void _updateScale(ScaleUpdateDetails details) {
    final nextZoom = (_startZoom * details.scale).clamp(1.0, 6.0);
    final scale = _baseScale * nextZoom;
    final desired = Offset(
      details.localFocalPoint.dx - _anchorImagePoint.dx * scale,
      details.localFocalPoint.dy - _anchorImagePoint.dy * scale,
    );
    setState(() {
      _zoom = nextZoom;
      _offset = _clampOffset(desired, nextZoom);
    });
  }

  Offset _clampOffset(Offset value, double zoom) {
    final scale = _baseScale * zoom;
    final width = widget.preview.width * scale;
    final height = widget.preview.height * scale;
    final minX = _viewport - width;
    final minY = _viewport - height;
    return Offset(
      value.dx.clamp(minX, 0.0),
      value.dy.clamp(minY, 0.0),
    );
  }

  void _reset() {
    final width = widget.preview.width * _baseScale;
    final height = widget.preview.height * _baseScale;
    setState(() {
      _zoom = 1;
      _offset = Offset((_viewport - width) / 2, (_viewport - height) / 2);
    });
  }

  void _complete() {
    if (_viewport <= 0) return;
    final scale = _baseScale * _zoom;
    final leftPixels = (-_offset.dx / scale).clamp(
      0.0,
      widget.preview.width.toDouble(),
    );
    final topPixels = (-_offset.dy / scale).clamp(
      0.0,
      widget.preview.height.toDouble(),
    );
    final sidePixels = (_viewport / scale).clamp(
      1.0,
      math.min(widget.preview.width, widget.preview.height).toDouble(),
    );
    Navigator.of(context).pop(
      AvatarCropSelection(
        left: leftPixels / widget.preview.width,
        top: topPixels / widget.preview.height,
        width: sidePixels / widget.preview.width,
        height: sidePixels / widget.preview.height,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111111),
        foregroundColor: Colors.white,
        title: const Text('裁剪头像'),
        actions: [
          TextButton(
            onPressed: _complete,
            child: const Text(
              '完成',
              style: TextStyle(color: Color(0xFF07C160)),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final viewport = math.min(
            constraints.maxWidth - 24,
            math.min(constraints.maxHeight - 110, 520.0),
          ).clamp(180.0, 520.0);
          _configureViewport(viewport);
          final scale = _baseScale * _zoom;
          final width = widget.preview.width * scale;
          final height = widget.preview.height * scale;

          return Column(
            children: [
              const Spacer(),
              Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _startScale,
                  onScaleUpdate: _updateScale,
                  onDoubleTap: _reset,
                  child: ClipRect(
                    child: SizedBox(
                      width: viewport,
                      height: viewport,
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: [
                          Transform.translate(
                            offset: _offset,
                            child: SizedBox(
                              width: width,
                              height: height,
                              child: Image.memory(
                                widget.preview.bytes,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.medium,
                                gaplessPlayback: true,
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.92),
                                    width: 1.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const Text(
                '拖动调整位置 · 双指缩放 · 双击复位',
                style: TextStyle(color: Colors.white60, fontSize: 13),
              ),
              const Spacer(),
            ],
          );
        },
      ),
    );
  }
}
