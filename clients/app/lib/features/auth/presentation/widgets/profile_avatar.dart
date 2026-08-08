import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ProfileAvatar extends StatefulWidget {
  const ProfileAvatar({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.userId,
    required this.displayName,
    this.size = 40,
    this.revision = 0,
    this.fallbackColor,
  });

  final Uri origin;
  final String accessToken;
  final String userId;
  final String displayName;
  final double size;
  final int revision;
  final Color? fallbackColor;

  static final Map<String, Future<Uint8List?>> _cache = {};
  static final http.Client _httpClient = http.Client();

  static void evict(Uri origin, String userId) {
    final prefix = '${origin.origin}|$userId|';
    _cache.removeWhere((key, _) => key.startsWith(prefix));
  }

  @override
  State<ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<ProfileAvatar> {
  late Future<Uint8List?> _imageFuture;
  late int _resolvedRevision;

  int get _effectiveRevision => widget.revision != 0
      ? widget.revision
      : DateTime.now().millisecondsSinceEpoch ~/
            const Duration(minutes: 1).inMilliseconds;

  String get _cacheKey =>
      '${widget.origin.origin}|${widget.userId}|$_resolvedRevision';

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant ProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextRevision = _effectiveRevision;
    if (oldWidget.userId != widget.userId ||
        oldWidget.accessToken != widget.accessToken ||
        oldWidget.origin != widget.origin ||
        oldWidget.revision != widget.revision ||
        nextRevision != _resolvedRevision) {
      _resolveImage();
    }
  }

  void _resolveImage() {
    _resolvedRevision = _effectiveRevision;
    _imageFuture = ProfileAvatar._cache.putIfAbsent(_cacheKey, _loadAvatar);
  }

  Future<Uint8List?> _loadAvatar() async {
    try {
      final response = await ProfileAvatar._httpClient.get(
        widget.origin.resolve('/api/v1/avatars/${widget.userId}'),
        headers: {
          'Accept': 'image/avif,image/webp,image/png,image/jpeg,*/*',
          'Authorization': 'Bearer ${widget.accessToken}',
        },
      );
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.size <= 42 ? 5.0 : 7.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: FutureBuilder<Uint8List?>(
          future: _imageFuture,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes != null && bytes.isNotEmpty) {
              final pixelRatio = View.of(context).devicePixelRatio;
              final decodeSize = (widget.size * pixelRatio).ceil().clamp(
                16,
                512,
              );
              return Image.memory(
                bytes,
                width: widget.size,
                height: widget.size,
                cacheWidth: decodeSize,
                cacheHeight: decodeSize,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => _fallback(),
              );
            }
            return _fallback();
          },
        ),
      ),
    );
  }

  Widget _fallback() {
    final trimmed = widget.displayName.trim();
    final letter = trimmed.isEmpty ? '?' : trimmed.characters.first;
    return ColoredBox(
      color: widget.fallbackColor ?? const Color(0xFF6F9FCA),
      child: Center(
        child: Text(
          letter,
          style: TextStyle(
            color: Colors.white,
            fontSize: widget.size * 0.42,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
