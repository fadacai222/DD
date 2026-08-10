import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/chat_appearance_store.dart';

class ChatWallpaperSurface extends StatefulWidget {
  const ChatWallpaperSurface({
    super.key,
    required this.store,
    required this.conversationId,
    this.wallpaperOverride,
  });

  final ChatAppearanceStore store;
  final String conversationId;
  final ChatWallpaper? wallpaperOverride;

  @override
  State<ChatWallpaperSurface> createState() => _ChatWallpaperSurfaceState();
}

class _ChatWallpaperSurfaceState extends State<ChatWallpaperSurface> {
  Uint8List? _bytes;
  String? _loadedReference;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_handleStoreChanged);
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant ChatWallpaperSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_handleStoreChanged);
      widget.store.addListener(_handleStoreChanged);
    }
    if (!identical(oldWidget.store, widget.store) ||
        oldWidget.conversationId != widget.conversationId ||
        oldWidget.wallpaperOverride != widget.wallpaperOverride) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_handleStoreChanged);
    super.dispose();
  }

  void _handleStoreChanged() => unawaited(_refresh());

  Future<void> _refresh() async {
    final generation = ++_loadGeneration;
    await widget.store.load();
    final wallpaper =
        widget.wallpaperOverride ??
        widget.store.state.resolve(widget.conversationId);
    final reference = wallpaper.assetReference;
    Uint8List? bytes;
    if (wallpaper.kind == ChatWallpaperKind.custom && reference != null) {
      bytes = await widget.store.bytesFor(wallpaper);
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loadedReference = reference;
      _bytes = bytes;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final wallpaper =
        widget.wallpaperOverride ??
        (widget.store.loaded
            ? widget.store.state.resolve(widget.conversationId)
            : const ChatWallpaper.system());
    return RepaintBoundary(
      key: const Key('chat-wallpaper-surface'),
      child: switch (wallpaper.kind) {
        ChatWallpaperKind.solid => ColoredBox(
          color: Color(
            wallpaper.colorValue ?? (dark ? 0xFF1D1D1D : 0xFFEDEDED),
          ),
        ),
        ChatWallpaperKind.custom
            when _bytes != null &&
                _loadedReference == wallpaper.assetReference =>
          Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                _bytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
              if (dark) ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
            ],
          ),
        _ => CustomPaint(painter: _DdChatWallpaperPainter(dark: dark)),
      },
    );
  }
}

class _DdChatWallpaperPainter extends CustomPainter {
  const _DdChatWallpaperPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = dark ? const Color(0xFF1D1D1D) : const Color(0xFFECEFEB),
    );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = dark
          ? Colors.white.withValues(alpha: 0.035)
          : const Color(0xFF557266).withValues(alpha: 0.065);
    final dot = Paint()
      ..style = PaintingStyle.fill
      ..color = dark
          ? Colors.white.withValues(alpha: 0.025)
          : const Color(0xFF557266).withValues(alpha: 0.04);
    const cell = 92.0;
    for (double y = -cell; y < size.height + cell; y += cell) {
      final row = (y / cell).round();
      for (double x = -cell; x < size.width + cell; x += cell) {
        final column = (x / cell).round();
        final seed = row * 37 + column * 19;
        final center = Offset(
          x + (seed.isEven ? 24 : 58),
          y + (seed % 3 == 0 ? 28 : 62),
        );
        final radius = 6.0 + (seed.abs() % 7);
        canvas.drawCircle(center, radius, stroke);
        if (seed % 2 == 0) {
          canvas.drawCircle(
            center.translate(radius + 11, -radius / 2),
            2.2,
            dot,
          );
        }
        if (seed % 5 == 0) {
          final rect = Rect.fromCenter(
            center: center.translate(-18, 20),
            width: 20,
            height: 8,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(4)),
            stroke,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DdChatWallpaperPainter oldDelegate) =>
      oldDelegate.dark != dark;
}
