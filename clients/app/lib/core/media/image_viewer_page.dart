import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'media_export_service.dart';

class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.bytes,
    required this.mimeType,
    required this.suggestedName,
    this.exporter,
  });

  final Uint8List bytes;
  final String mimeType;
  final String suggestedName;
  final MediaExporter? exporter;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  bool _saving = false;
  bool _copying = false;

  MediaExporter get _exporter => widget.exporter ?? MediaExportService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              minScale: 0.7,
              maxScale: 5,
              child: Center(
                child: Image.memory(
                  widget.bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, _, _) => const Center(
                    child: Text(
                      '图片加载失败',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 10,
              top: 8,
              child: _roundButton(
                tooltip: '关闭',
                onPressed: () => Navigator.maybePop(context),
                icon: Icons.close_rounded,
              ),
            ),
            Positioned(
              right: 10,
              top: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (kIsWeb ||
                      defaultTargetPlatform != TargetPlatform.android) ...[
                    _roundButton(
                      key: const Key('media-viewer-copy'),
                      tooltip: '复制图片',
                      onPressed: _copying ? null : _copy,
                      icon: _copying ? null : Icons.content_copy_rounded,
                      progress: _copying,
                    ),
                    const SizedBox(width: 8),
                  ],
                  _roundButton(
                    key: const Key('media-viewer-download'),
                    tooltip: '保存图片',
                    onPressed: _saving ? null : _save,
                    icon: _saving ? null : Icons.download_rounded,
                    progress: _saving,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({
    Key? key,
    required String tooltip,
    required VoidCallback? onPressed,
    IconData? icon,
    bool progress = false,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.48),
        foregroundColor: Colors.white,
      ),
      icon: progress
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(icon),
    );
  }

  Future<void> _copy() async {
    if (_copying) return;
    setState(() => _copying = true);
    try {
      final message = await _exporter.copyImage(widget.bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('图片复制失败，请稍后重试。')));
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final message = await _exporter.saveImage(
        bytes: widget.bytes,
        mimeType: widget.mimeType,
        suggestedName: widget.suggestedName,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on MediaExportCancelled {
      // User cancelled the platform save dialog; this is not an error.
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('图片保存失败，请稍后重试。')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
