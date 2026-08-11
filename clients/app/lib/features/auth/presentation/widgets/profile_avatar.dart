import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../data/avatar_memory_cache.dart';

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

  static final AvatarMemoryCache _memoryCache = AvatarMemoryCache();
  static final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};
  static final http.Client _httpClient = http.Client();

  static void evict(Uri origin, String userId) {
    final prefix = '${origin.origin}|$userId|';
    _memoryCache.removeWhere((key) => key.startsWith(prefix));
    _inFlight.removeWhere((key, _) => key.startsWith(prefix));
  }

  static Future<Uint8List?> _resolveBytes({
    required Uri origin,
    required String accessToken,
    required String userId,
    required int revision,
  }) {
    final cacheKey = '${origin.origin}|$userId|$revision';
    final cached = _memoryCache.get(cacheKey);
    if (cached != null) return Future<Uint8List?>.value(cached);
    final active = _inFlight[cacheKey];
    if (active != null) return active;
    final future = _loadBytes(
      origin: origin,
      accessToken: accessToken,
      userId: userId,
    );
    _inFlight[cacheKey] = future;
    future.then((bytes) {
      _inFlight.remove(cacheKey);
      if (bytes != null && bytes.isNotEmpty) {
        _memoryCache.put(cacheKey, bytes);
      }
    }, onError: (_) {
      _inFlight.remove(cacheKey);
    });
    return future;
  }

  static Future<Uint8List?> _loadBytes({
    required Uri origin,
    required String accessToken,
    required String userId,
  }) async {
    try {
      final response = await _httpClient.get(
        origin.resolve('/api/v1/avatars/$userId'),
        headers: {
          'Accept': 'image/avif,image/webp,image/png,image/jpeg,*/*',
          'Authorization': 'Bearer $accessToken',
        },
      );
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }
      return Uint8List.fromList(response.bodyBytes);
    } catch (_) {
      return null;
    }
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
    _imageFuture = ProfileAvatar._resolveBytes(
      origin: widget.origin,
      accessToken: widget.accessToken,
      userId: widget.userId,
      revision: _resolvedRevision,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipOval(
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

class ProfileAvatarViewerPage extends StatelessWidget {
  const ProfileAvatarViewerPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.userId,
    required this.displayName,
    this.revision = 0,
  });

  final Uri origin;
  final String accessToken;
  final String userId;
  final String displayName;
  final int revision;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('profile-avatar-viewer'),
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(displayName),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final side = constraints.maxWidth.clamp(240.0, 720.0);
          final resolvedRevision = revision != 0
              ? revision
              : DateTime.now().millisecondsSinceEpoch ~/
                    const Duration(minutes: 1).inMilliseconds;
          return FutureBuilder<Uint8List?>(
            future: ProfileAvatar._resolveBytes(
              origin: origin,
              accessToken: accessToken,
              userId: userId,
              revision: resolvedRevision,
            ),
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null || bytes.isEmpty) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.white70),
                  );
                }
                return Center(
                  child: Text(
                    '暂无头像',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.white60),
                  ),
                );
              }
              return Center(
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 5,
                  child: SizedBox.square(
                    dimension: side,
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
