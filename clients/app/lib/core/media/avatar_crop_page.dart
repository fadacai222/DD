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
  static const double _editorHorizontalInset = 14;
  static const double _toolbarReserve = 92;

  Size _editorSize = Size.zero;
  double _imageScale = 1;
  Offset _imageOffset = Offset.zero;
  Rect _cropRect = Rect.zero;
  int _quarterTurns = 0;

  double _gestureStartScale = 1;
  Offset _gestureAnchorImagePoint = Offset.zero;
  Rect _handleStartCrop = Rect.zero;
  Offset _handleDragDelta = Offset.zero;

  Size get _orientedImageSize => AvatarCropGeometry.orientedSize(
    imageWidth: widget.preview.width,
    imageHeight: widget.preview.height,
    quarterTurns: _quarterTurns,
  );

  Rect get _imageRect => Rect.fromLTWH(
    _imageOffset.dx,
    _imageOffset.dy,
    _orientedImageSize.width * _imageScale,
    _orientedImageSize.height * _imageScale,
  );

  Rect get _editorRect => Offset.zero & _editorSize;

  void _configureEditor(Size bodySize) {
    final width = math.max(180.0, bodySize.width - _editorHorizontalInset * 2);
    final height = math.max(180.0, bodySize.height - _toolbarReserve);
    final next = Size(width, height);
    if ((_editorSize.width - next.width).abs() < 0.5 &&
        (_editorSize.height - next.height).abs() < 0.5) {
      return;
    }
    _editorSize = next;
    _applyInitialLayout();
  }

  void _applyInitialLayout() {
    if (_editorSize.isEmpty) return;
    final layout = AvatarCropGeometry.initialLayout(
      editorSize: _editorSize,
      imageWidth: widget.preview.width,
      imageHeight: widget.preview.height,
      quarterTurns: _quarterTurns,
    );
    _imageScale = layout.imageScale;
    _imageOffset = layout.imageOffset;
    _cropRect = layout.cropRect;
  }

  void _startImageGesture(ScaleStartDetails details) {
    if (_editorSize.isEmpty) return;
    _gestureStartScale = _imageScale;
    final scale = math.max(_imageScale, 0.000001);
    _gestureAnchorImagePoint = Offset(
      (details.localFocalPoint.dx - _imageOffset.dx) / scale,
      (details.localFocalPoint.dy - _imageOffset.dy) / scale,
    );
  }

  void _updateImageGesture(ScaleUpdateDetails details) {
    if (_editorSize.isEmpty) return;
    final oriented = _orientedImageSize;
    final minScale = AvatarCropGeometry.minimumImageScale(
      cropRect: _cropRect,
      imageSize: oriented,
    );
    final maxScale = math.max(
      minScale,
      AvatarCropGeometry.maximumImageScale(
        editorSize: _editorSize,
        imageSize: oriented,
      ),
    );
    final nextScale = (_gestureStartScale * details.scale).clamp(
      minScale,
      maxScale,
    );
    final desiredOffset = Offset(
      details.localFocalPoint.dx - _gestureAnchorImagePoint.dx * nextScale,
      details.localFocalPoint.dy - _gestureAnchorImagePoint.dy * nextScale,
    );
    final nextOffset = AvatarCropGeometry.clampImageOffset(
      desired: desiredOffset,
      scale: nextScale,
      imageSize: oriented,
      cropRect: _cropRect,
    );
    setState(() {
      _imageScale = nextScale;
      _imageOffset = nextOffset;
    });
  }

  void _startHandleDrag(DragStartDetails details) {
    _handleStartCrop = _cropRect;
    _handleDragDelta = Offset.zero;
  }

  void _updateHandleDrag(AvatarCropHandle handle, DragUpdateDetails details) {
    final bounds = _imageRect.intersect(_editorRect);
    _handleDragDelta += details.delta;
    final next = AvatarCropGeometry.resizeCrop(
      start: _handleStartCrop,
      handle: handle,
      delta: _handleDragDelta,
      bounds: bounds,
      minSide: math.min(88, math.min(bounds.width, bounds.height)),
    );
    if (next == _cropRect) return;
    setState(() {
      _cropRect = next;
      final oriented = _orientedImageSize;
      final minScale = AvatarCropGeometry.minimumImageScale(
        cropRect: next,
        imageSize: oriented,
      );
      if (_imageScale < minScale) _imageScale = minScale;
      _imageOffset = AvatarCropGeometry.clampImageOffset(
        desired: _imageOffset,
        scale: _imageScale,
        imageSize: oriented,
        cropRect: next,
      );
    });
  }

  void _rotate() {
    if (_editorSize.isEmpty) return;
    setState(() {
      _quarterTurns = (_quarterTurns + 1) % 4;
      _applyInitialLayout();
    });
  }

  void _reset() {
    if (_editorSize.isEmpty) return;
    setState(() {
      _quarterTurns = 0;
      _applyInitialLayout();
    });
  }

  void _complete() {
    if (_editorSize.isEmpty || _cropRect.isEmpty || _imageScale <= 0) return;
    final selection = AvatarCropGeometry.selection(
      cropRect: _cropRect,
      imageOffset: _imageOffset,
      imageScale: _imageScale,
      imageWidth: widget.preview.width,
      imageHeight: widget.preview.height,
      quarterTurns: _quarterTurns,
    );
    Navigator.of(context).pop(selection);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        foregroundColor: Colors.white,
        centerTitle: true,
        title: const Text('裁剪头像'),
        automaticallyImplyLeading: false,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          _configureEditor(Size(constraints.maxWidth, constraints.maxHeight));
          final editorLeft = (constraints.maxWidth - _editorSize.width) / 2;
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                left: editorLeft,
                top: 0,
                width: _editorSize.width,
                height: _editorSize.height,
                child: ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        left: _imageOffset.dx,
                        top: _imageOffset.dy,
                        width: _imageRect.width,
                        height: _imageRect.height,
                        child: RotatedBox(
                          quarterTurns: _quarterTurns,
                          child: Image.memory(
                            widget.preview.bytes,
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.medium,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) =>
                                const ColoredBox(color: Color(0xFF222222)),
                          ),
                        ),
                      ),
                      GestureDetector(
                        key: const Key('avatar-crop-image-gesture'),
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: _startImageGesture,
                        onScaleUpdate: _updateImageGesture,
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _AvatarCropOverlayPainter(_cropRect),
                          ),
                        ),
                      ),
                      ...AvatarCropHandle.values.map(
                        (handle) => _buildHandle(handle),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 10,
                child: SafeArea(top: false, child: _buildToolbar()),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHandle(AvatarCropHandle handle) {
    final center = AvatarCropGeometry.handleCenter(_cropRect, handle);
    const hit = 36.0;
    const visual = 10.0;
    return Positioned(
      left: center.dx - hit / 2,
      top: center.dy - hit / 2,
      width: hit,
      height: hit,
      child: GestureDetector(
        key: Key('avatar-crop-handle-${handle.name}'),
        behavior: HitTestBehavior.opaque,
        onPanStart: _startHandleDrag,
        onPanUpdate: (details) => _updateHandleDrag(handle, details),
        child: Center(
          child: Container(
            width: visual,
            height: visual,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(3),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1B1B),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white12, width: 0.6),
      ),
      child: Row(
        children: [
          Expanded(
            child: _CropToolbarButton(
              key: const Key('avatar-crop-cancel'),
              icon: Icons.close_rounded,
              label: '取消',
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
          Expanded(
            child: _CropToolbarButton(
              key: const Key('avatar-crop-rotate'),
              icon: Icons.rotate_90_degrees_cw_rounded,
              label: '旋转',
              onTap: _rotate,
            ),
          ),
          Expanded(
            child: _CropToolbarButton(
              key: const Key('avatar-crop-reset'),
              icon: Icons.restart_alt_rounded,
              label: '还原',
              onTap: _reset,
            ),
          ),
          Expanded(
            child: _CropToolbarButton(
              key: const Key('avatar-crop-complete'),
              icon: Icons.check_rounded,
              label: '完成',
              foreground: const Color(0xFF42D77D),
              onTap: _complete,
            ),
          ),
        ],
      ),
    );
  }
}

enum AvatarCropHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left,
}

final class AvatarCropLayout {
  const AvatarCropLayout({
    required this.imageScale,
    required this.imageOffset,
    required this.cropRect,
  });

  final double imageScale;
  final Offset imageOffset;
  final Rect cropRect;
}

abstract final class AvatarCropGeometry {
  static Size orientedSize({
    required int imageWidth,
    required int imageHeight,
    required int quarterTurns,
  }) {
    final turns = quarterTurns % 4;
    return turns.isOdd
        ? Size(imageHeight.toDouble(), imageWidth.toDouble())
        : Size(imageWidth.toDouble(), imageHeight.toDouble());
  }

  static AvatarCropLayout initialLayout({
    required Size editorSize,
    required int imageWidth,
    required int imageHeight,
    int quarterTurns = 0,
  }) {
    final imageSize = orientedSize(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      quarterTurns: quarterTurns,
    );
    if (editorSize.isEmpty || imageSize.isEmpty) {
      return const AvatarCropLayout(
        imageScale: 1,
        imageOffset: Offset.zero,
        cropRect: Rect.zero,
      );
    }
    final scale = editorSize.width / imageSize.width;
    final displaySize = Size(imageSize.width * scale, imageSize.height * scale);
    final imageOffset = Offset(0, (editorSize.height - displaySize.height) / 2);
    final imageRect = imageOffset & displaySize;
    final available = imageRect.intersect(Offset.zero & editorSize);
    final maxSide = math.max(1.0, math.min(available.width, available.height));
    final preferred = maxSide < 180 ? maxSide * 0.94 : maxSide * 0.82;
    final side = preferred.clamp(math.min(88.0, maxSide), maxSide).toDouble();
    final cropRect = Rect.fromCenter(
      center: available.center,
      width: side,
      height: side,
    );
    return AvatarCropLayout(
      imageScale: scale,
      imageOffset: imageOffset,
      cropRect: cropRect,
    );
  }

  static double minimumImageScale({
    required Rect cropRect,
    required Size imageSize,
  }) {
    if (cropRect.isEmpty || imageSize.isEmpty) return 1;
    return math.max(
      cropRect.width / imageSize.width,
      cropRect.height / imageSize.height,
    );
  }

  static double maximumImageScale({
    required Size editorSize,
    required Size imageSize,
  }) {
    if (editorSize.isEmpty || imageSize.isEmpty) return 8;
    final base = editorSize.width / imageSize.width;
    return math.max(base, base * 8);
  }

  static Offset clampImageOffset({
    required Offset desired,
    required double scale,
    required Size imageSize,
    required Rect cropRect,
  }) {
    if (scale <= 0 || imageSize.isEmpty || cropRect.isEmpty) return desired;
    final width = imageSize.width * scale;
    final height = imageSize.height * scale;
    final minX = cropRect.right - width;
    final maxX = cropRect.left;
    final minY = cropRect.bottom - height;
    final maxY = cropRect.top;
    return Offset(
      desired.dx.clamp(math.min(minX, maxX), math.max(minX, maxX)),
      desired.dy.clamp(math.min(minY, maxY), math.max(minY, maxY)),
    );
  }

  static Offset handleCenter(Rect rect, AvatarCropHandle handle) =>
      switch (handle) {
        AvatarCropHandle.topLeft => rect.topLeft,
        AvatarCropHandle.top => Offset(rect.center.dx, rect.top),
        AvatarCropHandle.topRight => rect.topRight,
        AvatarCropHandle.right => Offset(rect.right, rect.center.dy),
        AvatarCropHandle.bottomRight => rect.bottomRight,
        AvatarCropHandle.bottom => Offset(rect.center.dx, rect.bottom),
        AvatarCropHandle.bottomLeft => rect.bottomLeft,
        AvatarCropHandle.left => Offset(rect.left, rect.center.dy),
      };

  static Rect resizeCrop({
    required Rect start,
    required AvatarCropHandle handle,
    required Offset delta,
    required Rect bounds,
    required double minSide,
  }) {
    if (start.isEmpty || bounds.isEmpty) return start;
    final safeMin = math.min(minSide, math.min(bounds.width, bounds.height));
    double sideFor(double desired, double maxSide) =>
        desired.clamp(safeMin, math.max(safeMin, maxSide)).toDouble();

    Rect next;
    switch (handle) {
      case AvatarCropHandle.topLeft:
        final anchor = start.bottomRight;
        final side = sideFor(
          start.width - (delta.dx + delta.dy) / 2,
          math.min(anchor.dx - bounds.left, anchor.dy - bounds.top),
        );
        next = Rect.fromLTRB(
          anchor.dx - side,
          anchor.dy - side,
          anchor.dx,
          anchor.dy,
        );
      case AvatarCropHandle.topRight:
        final anchor = start.bottomLeft;
        final side = sideFor(
          start.width + (delta.dx - delta.dy) / 2,
          math.min(bounds.right - anchor.dx, anchor.dy - bounds.top),
        );
        next = Rect.fromLTWH(anchor.dx, anchor.dy - side, side, side);
      case AvatarCropHandle.right:
        final anchorX = start.left;
        final centerY = start.center.dy;
        final side = sideFor(
          start.width + delta.dx,
          math.min(
            bounds.right - anchorX,
            2 * math.min(centerY - bounds.top, bounds.bottom - centerY),
          ),
        );
        next = Rect.fromLTWH(anchorX, centerY - side / 2, side, side);
      case AvatarCropHandle.bottomRight:
        final anchor = start.topLeft;
        final side = sideFor(
          start.width + (delta.dx + delta.dy) / 2,
          math.min(bounds.right - anchor.dx, bounds.bottom - anchor.dy),
        );
        next = Rect.fromLTWH(anchor.dx, anchor.dy, side, side);
      case AvatarCropHandle.bottom:
        final anchorY = start.top;
        final centerX = start.center.dx;
        final side = sideFor(
          start.height + delta.dy,
          math.min(
            bounds.bottom - anchorY,
            2 * math.min(centerX - bounds.left, bounds.right - centerX),
          ),
        );
        next = Rect.fromLTWH(centerX - side / 2, anchorY, side, side);
      case AvatarCropHandle.bottomLeft:
        final anchor = start.topRight;
        final side = sideFor(
          start.width + (-delta.dx + delta.dy) / 2,
          math.min(anchor.dx - bounds.left, bounds.bottom - anchor.dy),
        );
        next = Rect.fromLTRB(
          anchor.dx - side,
          anchor.dy,
          anchor.dx,
          anchor.dy + side,
        );
      case AvatarCropHandle.left:
        final anchorX = start.right;
        final centerY = start.center.dy;
        final side = sideFor(
          start.width - delta.dx,
          math.min(
            anchorX - bounds.left,
            2 * math.min(centerY - bounds.top, bounds.bottom - centerY),
          ),
        );
        next = Rect.fromLTRB(
          anchorX - side,
          centerY - side / 2,
          anchorX,
          centerY + side / 2,
        );
      case AvatarCropHandle.top:
        final anchorY = start.bottom;
        final centerX = start.center.dx;
        final side = sideFor(
          start.height - delta.dy,
          math.min(
            anchorY - bounds.top,
            2 * math.min(centerX - bounds.left, bounds.right - centerX),
          ),
        );
        next = Rect.fromLTRB(
          centerX - side / 2,
          anchorY - side,
          centerX + side / 2,
          anchorY,
        );
    }
    return _clampSquareInside(next, bounds, safeMin);
  }

  static Rect _clampSquareInside(Rect rect, Rect bounds, double minSide) {
    final side = rect.width
        .clamp(minSide, math.min(bounds.width, bounds.height))
        .toDouble();
    var left = rect.left;
    var top = rect.top;
    if (left < bounds.left) left = bounds.left;
    if (top < bounds.top) top = bounds.top;
    if (left + side > bounds.right) left = bounds.right - side;
    if (top + side > bounds.bottom) top = bounds.bottom - side;
    return Rect.fromLTWH(left, top, side, side);
  }

  static AvatarCropSelection selection({
    required Rect cropRect,
    required Offset imageOffset,
    required double imageScale,
    required int imageWidth,
    required int imageHeight,
    required int quarterTurns,
  }) {
    final oriented = orientedSize(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      quarterTurns: quarterTurns,
    );
    if (cropRect.isEmpty || imageScale <= 0 || oriented.isEmpty) {
      return AvatarCropSelection(
        left: 0,
        top: 0,
        width: 1,
        height: 1,
        quarterTurns: quarterTurns % 4,
      );
    }
    final leftPixels = (cropRect.left - imageOffset.dx) / imageScale;
    final topPixels = (cropRect.top - imageOffset.dy) / imageScale;
    final sidePixels = cropRect.width / imageScale;
    return AvatarCropSelection(
      left: (leftPixels / oriented.width).clamp(0.0, 1.0),
      top: (topPixels / oriented.height).clamp(0.0, 1.0),
      width: (sidePixels / oriented.width).clamp(0.0, 1.0),
      height: (sidePixels / oriented.height).clamp(0.0, 1.0),
      quarterTurns: quarterTurns % 4,
    );
  }
}

class _AvatarCropOverlayPainter extends CustomPainter {
  const _AvatarCropOverlayPainter(this.cropRect);

  final Rect cropRect;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    if (cropRect.isEmpty) return;
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds)
      ..addRect(cropRect);
    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.56),
    );
    canvas.drawRect(
      cropRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: 0.96),
    );
    final gridPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.65
      ..color = Colors.white.withValues(alpha: 0.42);
    for (var index = 1; index <= 2; index++) {
      final fraction = index / 3;
      final x = cropRect.left + cropRect.width * fraction;
      final y = cropRect.top + cropRect.height * fraction;
      canvas.drawLine(
        Offset(x, cropRect.top),
        Offset(x, cropRect.bottom),
        gridPaint,
      );
      canvas.drawLine(
        Offset(cropRect.left, y),
        Offset(cropRect.right, y),
        gridPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AvatarCropOverlayPainter oldDelegate) =>
      oldDelegate.cropRect != cropRect;
}

class _CropToolbarButton extends StatelessWidget {
  const _CropToolbarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.foreground = Colors.white,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: SizedBox(
          height: 54,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: foreground, size: 22),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
