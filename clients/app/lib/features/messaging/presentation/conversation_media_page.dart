import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/media/image_viewer_page.dart';
import '../../../theme/app_theme.dart';
import '../application/messaging_coordinator.dart';
import '../data/media_api_client.dart';
import '../domain/messaging_models.dart';
import 'video_viewer_page.dart';

class ConversationMediaPage extends StatefulWidget {
  const ConversationMediaPage({
    super.key,
    required this.coordinator,
    required this.conversation,
    this.embedded = false,
    this.onSelected,
  });

  final MessagingCoordinator coordinator;
  final ConversationItem conversation;
  final bool embedded;
  final ValueChanged<String>? onSelected;

  @override
  State<ConversationMediaPage> createState() => _ConversationMediaPageState();
}

class _ConversationMediaPageState extends State<ConversationMediaPage> {
  late final MediaApiClient _mediaApi;
  final Map<String, Future<Uint8List>> _thumbnailLoads = {};
  bool _loadingOlder = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mediaApi = MediaApiClient();
  }

  @override
  void dispose() {
    _mediaApi.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('聊天文件'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '图片'),
              Tab(text: '视频'),
              Tab(text: '文件'),
            ],
          ),
        ),
        body: AnimatedBuilder(
          animation: widget.coordinator,
          builder: (context, _) {
            final visible = widget.coordinator
                .messagesFor(widget.conversation.id)
                .where((message) => !message.isRecalled)
                .toList(growable: false)
                .reversed
                .toList(growable: false);
            final images = visible
                .where(
                  (message) =>
                      const {'IMAGE', 'GIF', 'STICKER'}.contains(message.type),
                )
                .toList(growable: false);
            final videos = visible
                .where((message) => message.type == 'VIDEO')
                .toList(growable: false);
            final files = visible
                .where((message) => message.type == 'FILE')
                .toList(growable: false);

            return Column(
              children: [
                if (_error != null)
                  Material(
                    color: const Color(0xFFFFE8E8),
                    child: ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.error_outline_rounded,
                        color: DdColors.danger,
                      ),
                      title: Text(
                        _error!,
                        style: const TextStyle(color: DdColors.danger),
                      ),
                      trailing: IconButton(
                        tooltip: '关闭提示',
                        onPressed: () => setState(() => _error = null),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ),
                  ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _imageGrid(images),
                      _videoGrid(videos),
                      _fileList(files),
                    ],
                  ),
                ),
                _historyFooter(),
              ],
            );
          },
        ),
      ),
    );
    if (!widget.embedded) return page;
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: '图片'),
              Tab(text: '视频'),
              Tab(text: '文件'),
            ],
          ),
          Expanded(child: (page.child as Scaffold).body!),
        ],
      ),
    );
  }

  Widget _imageGrid(List<ChatMessage> items) {
    if (items.isEmpty) return _empty('当前已加载历史里没有图片或 GIF');
    return GridView.builder(
      key: const Key('conversation-media-images'),
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final message = items[index];
        final content = message.content;
        final mediaId = content?.mediaId;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(DdRadii.media),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('conversation-media-image-${message.id}'),
            onTap: mediaId == null || mediaId.isEmpty
                ? null
                : () => unawaited(_openImage(message)),
            child: mediaId == null || mediaId.isEmpty
                ? const Center(child: Icon(Icons.broken_image_outlined))
                : FutureBuilder<Uint8List>(
                    future: _thumbnail(mediaId),
                    builder: (context, snapshot) {
                      if (snapshot.hasData) {
                        return Image.memory(
                          snapshot.data!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        );
                      }
                      if (snapshot.hasError) {
                        return const Center(
                          child: Icon(Icons.broken_image_outlined),
                        );
                      }
                      return const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }

  Widget _videoGrid(List<ChatMessage> items) {
    if (items.isEmpty) return _empty('当前已加载历史里没有视频');
    return GridView.builder(
      key: const Key('conversation-media-videos'),
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 16 / 10,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final message = items[index];
        final content = message.content;
        final posterId = content?.posterMediaId;
        return Material(
          color: Colors.black,
          borderRadius: BorderRadius.circular(DdRadii.media),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('conversation-media-video-${message.id}'),
            onTap: content?.mediaId == null || content!.mediaId!.isEmpty
                ? null
                : () => unawaited(_openVideo(message)),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (posterId != null && posterId.isNotEmpty)
                  FutureBuilder<Uint8List>(
                    future: _thumbnail(posterId),
                    builder: (context, snapshot) {
                      if (snapshot.hasData) {
                        return Image.memory(snapshot.data!, fit: BoxFit.cover);
                      }
                      return const ColoredBox(color: Color(0xFF161616));
                    },
                  )
                else
                  const ColoredBox(color: Color(0xFF161616)),
                const Center(
                  child: CircleAvatar(
                    radius: 23,
                    backgroundColor: Color(0x99000000),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
                if ((content?.durationMs ?? 0) > 0)
                  Positioned(
                    right: 7,
                    bottom: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0x99000000),
                        borderRadius: BorderRadius.circular(DdRadii.pill),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        child: Text(
                          _durationLabel(content!.durationMs!),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _fileList(List<ChatMessage> items) {
    if (items.isEmpty) return _empty('当前已加载历史里没有文件');
    return ListView.separated(
      key: const Key('conversation-media-files'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 64),
      itemBuilder: (context, index) {
        final message = items[index];
        final content = message.content;
        final name = (content?.fileName ?? '').trim().isEmpty
            ? '文件'
            : content!.fileName!.trim();
        return ListTile(
          key: Key('conversation-media-file-${message.id}'),
          leading: const CircleAvatar(
            backgroundColor: Color(0xFFE8F4FF),
            child: Icon(
              Icons.insert_drive_file_outlined,
              color: Color(0xFF4E9BEA),
            ),
          ),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            content?.sizeBytes == null
                ? '定位到原消息'
                : '${_formatBytes(content!.sizeBytes!)} · 定位到原消息',
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () {
            final callback = widget.onSelected;
            if (callback != null) {
              callback(message.id);
            } else {
              Navigator.of(context).pop(message.id);
            }
          },
        );
      },
    );
  }

  Widget _historyFooter() {
    final canLoadOlder = widget.coordinator.canLoadOlder(
      widget.conversation.id,
    );
    if (!canLoadOlder) {
      return const SizedBox(height: 8);
    }
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: OutlinedButton.icon(
        key: const Key('conversation-media-load-older'),
        onPressed: _loadingOlder ? null : _loadOlder,
        icon: _loadingOlder
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.history_rounded),
        label: Text(_loadingOlder ? '正在加载…' : '加载更早媒体'),
      ),
    );
  }

  Widget _empty(String label) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(label, style: const TextStyle(color: DdColors.textSecondary)),
    ),
  );

  Future<Uint8List> _thumbnail(String mediaId) =>
      _thumbnailLoads.putIfAbsent(mediaId, () => _download(mediaId));

  Future<Uint8List> _download(String mediaId) async {
    final grant = await _downloadGrant(mediaId);
    return _mediaApi.downloadMedia(url: grant.url);
  }

  Future<MediaDownloadGrant> _downloadGrant(String mediaId) =>
      widget.coordinator.withAuthorizedToken(
        (token) => _mediaApi.createDownloadUrl(
          origin: widget.coordinator.origin,
          accessToken: token,
          mediaId: mediaId,
        ),
      );

  Future<void> _openImage(ChatMessage message) async {
    final content = message.content;
    final mediaId = content?.mediaId;
    if (mediaId == null || mediaId.isEmpty) return;
    try {
      final bytes = await _thumbnail(mediaId);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ImageViewerPage(
            bytes: bytes,
            mimeType: content?.mimeType ?? 'image/jpeg',
            suggestedName: content?.fileName ?? 'DD-image.jpg',
          ),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _error = '图片加载失败，请检查网络后重试。');
    }
  }

  Future<void> _openVideo(ChatMessage message) async {
    final content = message.content;
    final mediaId = content?.mediaId;
    if (content == null || mediaId == null || mediaId.isEmpty) return;
    try {
      final grant = await _downloadGrant(mediaId);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => VideoViewerPage(
            url: grant.url,
            fileName: (content.fileName ?? '').trim().isEmpty
                ? 'DD-video.mp4'
                : content.fileName!.trim(),
            mimeType: content.mimeType ?? 'video/mp4',
          ),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _error = '视频加载失败，请检查网络后重试。');
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder) return;
    setState(() {
      _loadingOlder = true;
      _error = null;
    });
    try {
      await widget.coordinator.loadOlder(widget.conversation.id);
    } catch (_) {
      if (mounted) setState(() => _error = '加载更早媒体失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  String _durationLabel(int durationMs) {
    final totalSeconds = (durationMs / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
