import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/media/media_cache_manager.dart';
import '../../../theme/app_theme.dart';
import '../application/media_transfer_controller.dart';
import '../domain/media_transfer_state.dart';

class TransferCenterPage extends StatefulWidget {
  const TransferCenterPage({
    super.key,
    required this.controller,
    this.cacheManager,
  });

  final MediaTransferController controller;
  final MediaCacheGateway? cacheManager;

  @override
  State<TransferCenterPage> createState() => _TransferCenterPageState();
}

class _TransferCenterPageState extends State<TransferCenterPage> {
  late final MediaCacheGateway _cache;
  MediaCacheSummary _cacheSummary =
      const MediaCacheSummary(<MediaCacheKind, int>{});
  bool _loadingCache = true;

  @override
  void initState() {
    super.initState();
    _cache = widget.cacheManager ?? const MediaCacheManager();
    unawaited(_refreshCache());
  }

  Future<void> _refreshCache() async {
    try {
      final summary = await _cache.snapshot();
      if (mounted) {
        setState(() {
          _cacheSummary = summary;
          _loadingCache = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingCache = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('传输中心'),
        actions: [
          PopupMenuButton<String>(
            key: const Key('transfer-center-clear-menu'),
            tooltip: '清理记录',
            onSelected: _handleClear,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'completed', child: Text('清除已完成记录')),
              PopupMenuItem(value: 'inactive', child: Text('清除非活动记录')),
            ],
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final tasks = widget.controller.tasks.reversed.toList(growable: false);
          final active = tasks.where((task) => task.isActive).toList(growable: false);
          final paused = tasks.where((task) => task.isPaused).toList(growable: false);
          final failed = tasks
              .where((task) => task.state.phase == MediaTransferPhase.failed)
              .toList(growable: false);
          final completed = tasks
              .where(
                (task) =>
                    task.state.phase == MediaTransferPhase.done ||
                    task.state.phase == MediaTransferPhase.canceled,
              )
              .toList(growable: false);
          return ListView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
            children: [
              _summaryCard(tasks),
              const SizedBox(height: 18),
              if (tasks.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 72),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.swap_vert_circle_outlined,
                          size: 46,
                          color: DdColors.textTertiary,
                        ),
                        SizedBox(height: 12),
                        Text(
                          '暂无传输任务',
                          style: TextStyle(color: DdColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                _section('正在传输', active),
                _section('已暂停', paused),
                _section('失败', failed),
                _section('已完成 / 已取消', completed),
              ],
              const SizedBox(height: 14),
              const Text(
                '“清除非活动记录”只删除任务记录，不会中断正在传输的任务，也不会删除聊天消息、服务端媒体或系统 Downloads/相册中的文件。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: DdColors.textSecondary,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _summaryCard(List<MediaTransferTask> tasks) {
    final knownBytes = tasks.fold<int>(
      0,
      (sum, task) => sum + (task.state.totalBytes ?? 0),
    );
    final activeCount = tasks.where((task) => task.isActive).length;
    return Container(
      key: const Key('transfer-center-summary'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(DdRadii.surface),
      ),
      child: Row(
        children: [
          const Icon(Icons.sync_alt_rounded, color: DdColors.green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$activeCount 个活动任务 · ${tasks.length} 条记录',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  '任务数据 ${formatMediaCacheBytes(knownBytes)} · '
                  '本地缓存 ${_loadingCache ? '统计中…' : formatMediaCacheBytes(_cacheSummary.totalBytes)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: DdColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新缓存统计',
            onPressed: _refreshCache,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<MediaTransferTask> tasks) {
    if (tasks.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 7),
            child: Text(
              '$title · ${tasks.length}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          ...tasks.map(_taskTile),
        ],
      ),
    );
  }

  Widget _taskTile(MediaTransferTask task) {
    final progress = task.state.progress;
    final total = task.state.totalBytes;
    final transferred = task.state.transferredBytes;
    return Card(
      key: Key('transfer-task-${task.id}'),
      margin: const EdgeInsets.only(bottom: 7),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  _kindIcon(task.kind),
                  size: 26,
                  color: DdColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${task.direction == MediaTransferDirection.upload ? '上传' : '下载'} · '
                        '${_statusLabel(task)} · ${_timeLabel(task.updatedAt)}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: DdColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                ..._taskActions(task),
              ],
            ),
            if (task.isActive || task.isPaused) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                backgroundColor: DdColors.divider,
              ),
              const SizedBox(height: 5),
              Text(
                '${formatMediaCacheBytes(transferred)}'
                '${total == null ? '' : ' / ${formatMediaCacheBytes(total)}'}'
                '${task.bytesPerSecond <= 0 || task.isPaused ? '' : ' · ${formatMediaCacheBytes(task.bytesPerSecond.round())}/s'}',
                style: const TextStyle(
                  fontSize: 10,
                  color: DdColors.textSecondary,
                ),
              ),
            ],
            if (task.state.errorMessage?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 5),
              Text(
                task.state.errorMessage!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: DdColors.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _taskActions(MediaTransferTask task) {
    if (task.isActive) {
      return [
        IconButton(
          key: Key('pause-transfer-${task.id}'),
          tooltip: '暂停',
          onPressed: () => widget.controller.pause(task.id),
          icon: const Icon(Icons.pause_rounded),
        ),
        IconButton(
          key: Key('cancel-transfer-${task.id}'),
          tooltip: '取消',
          onPressed: () => widget.controller.cancel(task.id),
          icon: const Icon(Icons.close_rounded),
        ),
      ];
    }
    if (task.isPaused) {
      return [
        IconButton(
          key: Key('resume-transfer-${task.id}'),
          tooltip: '继续',
          onPressed: () => widget.controller.resume(task.id),
          icon: const Icon(Icons.play_arrow_rounded),
        ),
        IconButton(
          tooltip: '取消',
          onPressed: () => widget.controller.cancel(task.id),
          icon: const Icon(Icons.close_rounded),
        ),
      ];
    }
    if (task.state.phase == MediaTransferPhase.failed) {
      return [
        if (task.canRetry)
          IconButton(
            key: Key('retry-transfer-${task.id}'),
            tooltip: '重试',
            onPressed: () => widget.controller.retry(task.id),
            icon: const Icon(Icons.refresh_rounded),
          ),
        IconButton(
          tooltip: '移除记录',
          onPressed: () => widget.controller.dismiss(task.id),
          icon: const Icon(Icons.close_rounded),
        ),
      ];
    }
    if (task.state.phase == MediaTransferPhase.done &&
        task.direction == MediaTransferDirection.download) {
      return [
        if (task.openAction != null)
          IconButton(
            tooltip: '打开',
            onPressed: () => _runAction(task.openAction!),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        if (task.saveAction != null)
          IconButton(
            tooltip: '另存',
            onPressed: () => _runAction(task.saveAction!),
            icon: const Icon(Icons.download_rounded),
          ),
        if (task.shareAction != null)
          IconButton(
            tooltip: '分享',
            onPressed: () => _runAction(task.shareAction!),
            icon: const Icon(Icons.ios_share_rounded),
          ),
      ];
    }
    return [
      IconButton(
        tooltip: '移除记录',
        onPressed: () => widget.controller.dismiss(task.id),
        icon: const Icon(Icons.close_rounded),
      ),
    ];
  }

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作已完成')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：$error')),
        );
      }
    }
  }

  Future<void> _handleClear(String action) async {
    final count = action == 'completed'
        ? widget.controller.clearCompleted()
        : widget.controller.clearInactive();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(count == 0 ? '没有可清理的记录' : '已清理 $count 条记录')),
    );
  }

  IconData _kindIcon(MediaTransferKind kind) => switch (kind) {
    MediaTransferKind.image => Icons.image_outlined,
    MediaTransferKind.video => Icons.video_file_outlined,
    MediaTransferKind.file => Icons.insert_drive_file_outlined,
    MediaTransferKind.voice => Icons.mic_none_rounded,
    MediaTransferKind.gif => Icons.gif_box_outlined,
    MediaTransferKind.sticker => Icons.emoji_emotions_outlined,
  };

  String _statusLabel(MediaTransferTask task) => switch (task.state.phase) {
    MediaTransferPhase.queued => '等待中',
    MediaTransferPhase.preparing => '处理中',
    MediaTransferPhase.uploading =>
      task.direction == MediaTransferDirection.upload ? '上传中' : '下载中',
    MediaTransferPhase.paused => '已暂停',
    MediaTransferPhase.committing => '提交中',
    MediaTransferPhase.done => '已完成',
    MediaTransferPhase.failed => '失败',
    MediaTransferPhase.canceled => '已取消',
  };

  String _timeLabel(DateTime utc) {
    final local = utc.toLocal();
    final now = DateTime.now();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
