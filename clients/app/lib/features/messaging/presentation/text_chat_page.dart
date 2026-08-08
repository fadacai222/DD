import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/media/chat_image_processor.dart';
import '../../../core/media/chat_voice_recorder.dart';
import '../../../core/widgets/dd_action_sheet.dart';
import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../calls/domain/call_session.dart';
import '../../contacts/presentation/peer_profile_page.dart';
import '../application/messaging_coordinator.dart';
import '../data/media_api_client.dart';
import '../data/messaging_api_client.dart' show MessagingApiException;
import '../domain/messaging_models.dart';

class TextChatPage extends StatefulWidget {
  const TextChatPage({
    super.key,
    required this.coordinator,
    required this.conversation,
    required this.currentUserId,
    this.currentUserDisplayName = '',
    this.currentUserAvatarRevision = 0,
    this.onStartCall,
    this.hostVisible = true,
    this.embedded = false,
  });

  final MessagingCoordinator coordinator;
  final ConversationItem conversation;
  final String currentUserId;
  final String currentUserDisplayName;
  final int currentUserAvatarRevision;
  final Future<void> Function(String peerId, String peerName, CallKind kind)?
  onStartCall;
  final bool hostVisible;
  final bool embedded;

  @override
  State<TextChatPage> createState() => _TextChatPageState();
}

class _TextChatPageState extends State<TextChatPage>
    with WidgetsBindingObserver {
  static const _emoji = <String>[
    '😀',
    '😃',
    '😄',
    '😁',
    '😆',
    '🥹',
    '😂',
    '🙂',
    '🙃',
    '😉',
    '😊',
    '🥰',
    '😍',
    '😘',
    '😋',
    '😎',
    '🤔',
    '🫡',
    '😴',
    '😭',
    '😤',
    '😡',
    '🤯',
    '🥳',
    '👍',
    '👎',
    '👌',
    '✌️',
    '🤝',
    '👏',
    '🙏',
    '💪',
    '❤️',
    '💔',
    '🔥',
    '✨',
    '🎉',
    '💯',
    '👀',
    '🚀',
  ];

  late final TextEditingController _composer;
  late final FocusNode _composerFocusNode;
  late final ScrollController _scrollController;
  late final MediaApiClient _mediaApi;
  late final ChatVoiceRecorder _voiceRecorder;
  late final AudioPlayer _voicePlayer;
  final Map<String, MediaDownloadGrant> _mediaDownloadCache = {};
  final Map<String, Future<MediaDownloadGrant>> _mediaDownloadInflight = {};
  Timer? _draftSaveTimer;
  bool _imageSending = false;
  int _imageBatchCurrent = 0;
  int _imageBatchTotal = 0;
  double _imageUploadProgress = 0;
  bool _gifSending = false;
  bool _stickerSending = false;
  bool _fileSending = false;
  final Map<String, double> _fileDownloadProgress = {};
  final Map<String, MediaDownloadCancellation> _fileDownloadCancellations = {};
  double _fileUploadProgress = 0;
  MediaUploadCancellation? _fileUploadCancellation;
  bool _voiceRecording = false;
  bool _voiceCancelGesture = false;
  bool _voiceSending = false;
  int _voiceElapsedSeconds = 0;
  Timer? _voiceTimer;
  Future<void>? _voiceStartFuture;
  String? _playingVoiceMessageId;
  Duration _voicePosition = Duration.zero;
  Duration _voiceDuration = Duration.zero;
  double _voicePlaybackRate = 1;
  ChatMessage? _replyingTo;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  bool get _keyboardSendEnabled =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  void initState() {
    super.initState();
    _composer = TextEditingController(
      text: widget.coordinator.draftFor(widget.conversation.id),
    );
    _composer.addListener(_scheduleDraftSave);
    _composerFocusNode = FocusNode(debugLabel: 'chat-composer');
    _scrollController = ScrollController();
    _mediaApi = MediaApiClient();
    _voiceRecorder = ChatVoiceRecorder();
    _voicePlayer = AudioPlayer();
    _voicePlayer.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      if (state == PlayerState.completed) {
        setState(() {
          _playingVoiceMessageId = null;
          _voicePosition = Duration.zero;
        });
      } else {
        setState(() {});
      }
    });
    _voicePlayer.onPositionChanged.listen((position) {
      if (mounted) setState(() => _voicePosition = position);
    });
    _voicePlayer.onDurationChanged.listen((duration) {
      if (mounted) setState(() => _voiceDuration = duration);
    });
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _updateReadVisibility(),
    );
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant TextChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hostVisible != widget.hostVisible ||
        oldWidget.conversation.id != widget.conversation.id) {
      if (oldWidget.conversation.id != widget.conversation.id) {
        widget.coordinator.deactivateConversation(oldWidget.conversation.id);
      }
      _updateReadVisibility();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _updateReadVisibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftSaveTimer?.cancel();
    _voiceTimer?.cancel();
    unawaited(_voiceRecorder.dispose());
    unawaited(_voicePlayer.dispose());
    unawaited(
      widget.coordinator.setDraft(widget.conversation.id, _composer.text),
    );
    widget.coordinator.deactivateConversation(widget.conversation.id);
    _composer.removeListener(_scheduleDraftSave);
    _composerFocusNode.dispose();
    _composer.dispose();
    _scrollController.dispose();
    _mediaApi.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.coordinator,
      builder: (context, _) {
        final conversation =
            widget.coordinator.conversationFor(widget.conversation.id) ??
            widget.conversation;
        final messages = widget.coordinator.messagesFor(conversation.id);
        final pending = widget.coordinator.pendingFor(conversation.id);
        final body = ColoredBox(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1D1D1D)
              : DdColors.chatBackground,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                if (widget.embedded) _desktopHeader(conversation),
                if (widget.coordinator.errorMessage != null)
                  _errorBar(widget.coordinator.errorMessage!),
                Expanded(
                  child: GestureDetector(
                    key: const Key('chat-message-surface'),
                    behavior: HitTestBehavior.translucent,
                    onTap: _dismissKeyboard,
                    child: messages.isEmpty && pending.isEmpty
                        ? _emptyState(conversation)
                        : _messageList(conversation, messages, pending),
                  ),
                ),
                _composerBar(),
              ],
            ),
          ),
        );

        if (widget.embedded) return body;
        return Scaffold(
          resizeToAvoidBottomInset: false,
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1D1D1D)
              : DdColors.chatBackground,
          appBar: AppBar(
            titleSpacing: 0,
            title: _chatTitle(conversation),
            actions: [
              IconButton(
                key: const Key('chat-audio-call-mobile'),
                tooltip: '语音通话',
                onPressed: () => _startCall(CallKind.audio),
                icon: const Icon(Icons.call_outlined, size: 21),
              ),
              IconButton(
                key: const Key('chat-video-call-mobile'),
                tooltip: '视频通话',
                onPressed: () => _startCall(CallKind.video),
                icon: const Icon(Icons.videocam_outlined, size: 23),
              ),
              IconButton(
                key: const Key('chat-sync'),
                tooltip: '更多',
                onPressed: _sync,
                icon: const Icon(Icons.more_horiz_rounded),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: defaultTargetPlatform == TargetPlatform.android
              ? _AndroidKeyboardLift(child: body)
              : body,
        );
      },
    );
  }

  Widget _desktopHeader(ConversationItem conversation) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: const Border(
          bottom: BorderSide(color: DdColors.divider, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: _chatTitle(conversation)),
          IconButton(
            key: const Key('chat-audio-call'),
            tooltip: '语音通话',
            onPressed: () => _startCall(CallKind.audio),
            icon: const Icon(Icons.call_outlined, size: 20),
          ),
          IconButton(
            key: const Key('chat-video-call'),
            tooltip: '视频通话',
            onPressed: () => _startCall(CallKind.video),
            icon: const Icon(Icons.videocam_outlined, size: 22),
          ),
          IconButton(
            key: const Key('chat-sync'),
            tooltip: '更多',
            onPressed: _sync,
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
    );
  }

  Widget _chatTitle(ConversationItem conversation) {
    final peer = conversation.peer;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          peer?.displayName ?? '聊天',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        if (peer != null)
          Text(
            '@${peer.handle}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: DdColors.textSecondary,
              fontWeight: FontWeight.w400,
            ),
          ),
      ],
    );
  }

  Widget _emptyState(ConversationItem conversation) {
    final name = conversation.peer?.displayName ?? '对方';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _peerAvatar(conversation, size: 58),
            const SizedBox(height: 14),
            Text(
              '和 $name 开始聊天',
              style: const TextStyle(
                fontSize: 15,
                color: DdColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBar(String message) {
    return Material(
      color: const Color(0xFFFFE8E8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 7, 6, 7),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: DdColors.danger,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9D2323)),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              visualDensity: VisualDensity.compact,
              onPressed: widget.coordinator.clearError,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _messageList(
    ConversationItem conversation,
    List<ChatMessage> messages,
    List<PendingTextMessage> pending,
  ) {
    final hasOlder = widget.coordinator.canLoadOlder(conversation.id);
    final offset = hasOlder ? 1 : 0;
    final count = offset + messages.length + pending.length;
    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(
        widget.embedded ? 24 : 12,
        18,
        widget.embedded ? 24 : 12,
        18,
      ),
      itemCount: count,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemBuilder: (_, index) {
        if (hasOlder && index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Center(
              child: TextButton(
                key: const Key('chat-load-older'),
                onPressed: _loadOlder,
                child: const Text('查看更多消息'),
              ),
            ),
          );
        }
        final contentIndex = index - offset;
        if (contentIndex < messages.length) {
          return RepaintBoundary(
            child: _messageRow(conversation, messages[contentIndex]),
          );
        }
        return RepaintBoundary(
          child: _pendingRow(pending[contentIndex - messages.length]),
        );
      },
    );
  }

  Widget _messageRow(ConversationItem conversation, ChatMessage message) {
    final mine = message.senderUserId == widget.currentUserId;
    final bubble = _messageBubble(conversation, message, mine);
    final row = Padding(
      key: Key('message-${message.id}'),
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[_peerAvatar(conversation), const SizedBox(width: 9)],
          Flexible(child: bubble),
          if (mine) ...[
            const SizedBox(width: 9),
            _avatar(
              widget.currentUserId,
              widget.currentUserDisplayName.isEmpty
                  ? '我'
                  : widget.currentUserDisplayName,
              mine: true,
            ),
          ],
        ],
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: () => _showMessageActions(message, mine),
      onSecondaryTapDown: (details) =>
          _showMessageMenuAt(message, mine, details.globalPosition),
      child: row,
    );
  }

  Widget _messageBubble(
    ConversationItem conversation,
    ChatMessage message,
    bool mine,
  ) {
    final recalled = message.isRecalled;
    final visualContent =
        !recalled &&
        const {'IMAGE', 'GIF', 'STICKER'}.contains(message.type) &&
        message.content?.isImage == true;
    final standaloneSticker = visualContent && message.type == 'STICKER';
    final voiceContent =
        !recalled &&
        message.type == 'VOICE' &&
        message.content?.hasMedia == true &&
        message.content?.durationMs != null;
    final fileContent =
        !recalled &&
        message.type == 'FILE' &&
        message.content?.hasMedia == true;
    final maxWidth = widget.embedded ? 520.0 : 290.0;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            padding: recalled
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
                : standaloneSticker
                ? EdgeInsets.zero
                : visualContent
                ? const EdgeInsets.all(3)
                : const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: recalled || standaloneSticker
                ? null
                : BoxDecoration(
                    color: mine
                        ? DdColors.ownBubble
                        : Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(5),
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.replyToMessageId != null && !recalled) ...[
                  _replyReference(message.replyToMessageId!, mine),
                  const SizedBox(height: 6),
                ],
                if (visualContent)
                  _chatImage(message.content!)
                else if (voiceContent)
                  _voiceBubble(message, mine)
                else if (fileContent)
                  _fileBubble(message, mine)
                else
                  Text(
                    recalled
                        ? '你${mine ? '' : '的好友'}撤回了一条消息'
                        : (message.content?.text ?? '[${message.type}]'),
                    style: TextStyle(
                      fontSize: recalled ? 12 : 15,
                      height: 1.38,
                      fontStyle: recalled ? FontStyle.italic : FontStyle.normal,
                      color: recalled
                          ? DdColors.textSecondary
                          : (Theme.of(context).brightness == Brightness.dark
                                ? Colors.white
                                : DdColors.textPrimary),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _shortTime(message.createdAt.toLocal()),
                style: const TextStyle(
                  fontSize: 10,
                  color: DdColors.textTertiary,
                ),
              ),
              if (mine && !recalled) ...[
                const SizedBox(width: 5),
                Text(
                  _messageDeliveryLabel(conversation, message),
                  key: Key('message-status-${message.id}'),
                  style: TextStyle(
                    fontSize: 10,
                    color: _messageDeliveryLabel(conversation, message) == '已读'
                        ? DdColors.greenPressed
                        : DdColors.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _messageDeliveryLabel(
    ConversationItem conversation,
    ChatMessage message,
  ) {
    final peerRead = conversation.peerLastReadSequence;
    if (peerRead != null && peerRead >= message.sequence) return '已读';
    return '已发送';
  }

  Widget _fileBubble(ChatMessage message, bool mine) {
    final content = message.content!;
    final name = (content.fileName ?? '').trim().isEmpty
        ? '文件'
        : content.fileName!.trim();
    final downloading = _fileDownloadCancellations.containsKey(message.id);
    final progress = _fileDownloadProgress[message.id] ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: downloading
          ? () => _fileDownloadCancellations[message.id]?.cancel()
          : () => unawaited(_saveMediaFile(message)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, size: 32),
            const SizedBox(width: 9),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (downloading)
                    Text(
                      progress > 0
                          ? '下载 ${(progress * 100).round()}% · 点击取消'
                          : '准备下载… · 点击取消',
                      style: const TextStyle(
                        fontSize: 11,
                        color: DdColors.textSecondary,
                      ),
                    )
                  else if (content.sizeBytes != null)
                    Text(
                      _formatBytes(content.sizeBytes!),
                      style: const TextStyle(
                        fontSize: 11,
                        color: DdColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveMediaFile(ChatMessage message) async {
    final content = message.content;
    final mediaId = content?.mediaId;
    if (content == null || mediaId == null || mediaId.isEmpty) return;
    final fileName = (content.fileName ?? '').trim().isEmpty
        ? 'download.bin'
        : content.fileName!.trim();
    final location = await getSaveLocation(suggestedName: fileName);
    if (location == null || !mounted) return;
    final cancellation = MediaDownloadCancellation();
    setState(() {
      _fileDownloadCancellations[message.id] = cancellation;
      _fileDownloadProgress[message.id] = 0;
    });
    try {
      final grant = await _downloadGrantFor(mediaId);
      final bytes = await _mediaApi.downloadMedia(
        url: grant.url,
        cancellation: cancellation,
        onProgress: (received, total) {
          if (!mounted || total == null || total <= 0) return;
          final next = (received / total).clamp(0.0, 1.0);
          if ((next - (_fileDownloadProgress[message.id] ?? 0)).abs() < 0.01 &&
              next < 1)
            return;
          setState(() => _fileDownloadProgress[message.id] = next);
        },
      );
      if (cancellation.isCancelled) throw const MediaDownloadCancelled();
      await XFile.fromData(
        bytes,
        mimeType: content.mimeType,
        name: fileName,
      ).saveTo(location.path);
      if (mounted) _showImageError('文件已保存。');
    } on MediaDownloadCancelled {
      if (mounted) _showImageError('已取消文件下载。');
    } catch (_) {
      if (mounted) _showImageError('文件下载失败，请稍后重试。');
    } finally {
      if (mounted) {
        setState(() {
          _fileDownloadCancellations.remove(message.id);
          _fileDownloadProgress.remove(message.id);
        });
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
  }

  Widget _voiceBubble(ChatMessage message, bool mine) {
    final content = message.content!;
    final durationMs = content.durationMs!.clamp(250, maxChatVoiceDurationMs);
    final durationSeconds = (durationMs / 1000).ceil();
    final width = (112.0 + durationSeconds * 2.4).clamp(126.0, 248.0);
    final playing =
        _playingVoiceMessageId == message.id &&
        _voicePlayer.state == PlayerState.playing;
    final progress =
        _playingVoiceMessageId == message.id &&
            _voiceDuration.inMilliseconds > 0
        ? (_voicePosition.inMilliseconds / _voiceDuration.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    final heard = widget.coordinator.isVoiceHeard(message.id);
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: () => unawaited(_toggleVoicePlayback(message)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            children: [
              Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 24,
                color: mine ? const Color(0xFF355F2B) : DdColors.textPrimary,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: List.generate(18, (index) {
                    final normalized = index / 17;
                    final active = normalized <= progress;
                    final height = 7.0 + ((index * 7) % 13);
                    return Expanded(
                      child: Align(
                        alignment: Alignment.center,
                        child: Container(
                          width: 2,
                          height: height,
                          decoration: BoxDecoration(
                            color: active
                                ? DdColors.greenPressed
                                : (mine
                                      ? const Color(0xFF6B9C5E)
                                      : DdColors.textSecondary),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(width: 7),
              Text('$durationSeconds″', style: const TextStyle(fontSize: 12)),
              if (heard) ...[
                const SizedBox(width: 4),
                const Icon(
                  Icons.check_rounded,
                  size: 13,
                  color: DdColors.textSecondary,
                ),
              ],
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () => unawaited(_cycleVoicePlaybackRate(message)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 2,
                  ),
                  child: Text(
                    '${_voicePlaybackRate.toStringAsFixed(_voicePlaybackRate == 1 ? 0 : 1)}x',
                    style: const TextStyle(
                      fontSize: 9,
                      color: DdColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleVoicePlayback(ChatMessage message) async {
    final mediaId = message.content?.mediaId;
    if (mediaId == null || mediaId.isEmpty) return;
    try {
      if (_playingVoiceMessageId == message.id) {
        if (_voicePlayer.state == PlayerState.playing) {
          await _voicePlayer.pause();
        } else {
          await _voicePlayer.resume();
        }
        return;
      }
      final grant = await _downloadGrantFor(mediaId);
      await _voicePlayer.stop();
      await _voicePlayer.setPlaybackRate(_voicePlaybackRate);
      if (mounted) {
        setState(() {
          _playingVoiceMessageId = message.id;
          _voicePosition = Duration.zero;
          _voiceDuration = Duration.zero;
        });
      }
      await widget.coordinator.markVoiceHeard(message.id);
      await _voicePlayer.play(UrlSource(grant.url.toString()));
    } catch (_) {
      if (mounted) _showImageError('语音播放失败，请稍后重试。');
    }
  }

  Future<void> _cycleVoicePlaybackRate(ChatMessage message) async {
    final next = _voicePlaybackRate == 1
        ? 1.5
        : _voicePlaybackRate == 1.5
        ? 2.0
        : 1.0;
    setState(() => _voicePlaybackRate = next);
    if (_playingVoiceMessageId == message.id) {
      await _voicePlayer.setPlaybackRate(next);
    }
  }

  Widget _chatImage(TextMessageContent content) {
    final mediaId = content.mediaId!;
    final size = _chatImageDisplaySize(content.width!, content.height!);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: FutureBuilder<MediaDownloadGrant>(
          future: _downloadGrantFor(mediaId),
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              final grant = snapshot.data!;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openMediaPreview(grant),
                child: Image.network(
                  grant.url.toString(),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => _imageLoadFailure(mediaId),
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : _imageLoadingSurface(),
                ),
              );
            }
            if (snapshot.hasError) return _imageLoadFailure(mediaId);
            return _imageLoadingSurface();
          },
        ),
      ),
    );
  }

  Future<void> _openMediaPreview(MediaDownloadGrant grant) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.94),
      builder: (dialogContext) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.7,
                maxScale: 5,
                child: Center(
                  child: Image.network(
                    grant.url.toString(),
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, _, _) => const Center(
                      child: Text(
                        '媒体加载失败',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Size _chatImageDisplaySize(int width, int height) {
    final maxWidth = widget.embedded ? 360.0 : 238.0;
    final maxHeight = widget.embedded ? 360.0 : 300.0;
    final ratio = width / height;
    var displayWidth = width.toDouble();
    var displayHeight = height.toDouble();
    if (displayWidth > maxWidth) {
      displayWidth = maxWidth;
      displayHeight = displayWidth / ratio;
    }
    if (displayHeight > maxHeight) {
      displayHeight = maxHeight;
      displayWidth = displayHeight * ratio;
    }
    if (displayWidth < 96) {
      displayWidth = 96;
      displayHeight = (displayWidth / ratio).clamp(72.0, maxHeight);
    }
    if (displayHeight < 72) {
      displayHeight = 72;
      displayWidth = (displayHeight * ratio).clamp(96.0, maxWidth);
    }
    return Size(displayWidth, displayHeight);
  }

  Widget _imageLoadingSurface() => Container(
    color: const Color(0xFFE9E9E9),
    alignment: Alignment.center,
    child: const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );

  Widget _imageLoadFailure(String mediaId) => Material(
    color: const Color(0xFFE9E9E9),
    child: InkWell(
      onTap: () {
        _mediaDownloadCache.remove(mediaId);
        _mediaDownloadInflight.remove(mediaId);
        setState(() {});
      },
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, color: DdColors.textSecondary),
            SizedBox(height: 5),
            Text('加载失败，点击重试', style: TextStyle(fontSize: 11)),
          ],
        ),
      ),
    ),
  );

  Future<MediaDownloadGrant> _downloadGrantFor(String mediaId) {
    final cached = _mediaDownloadCache[mediaId];
    final now = DateTime.now().toUtc();
    if (cached != null &&
        cached.expiresAt.isAfter(now.add(const Duration(seconds: 20)))) {
      return Future.value(cached);
    }
    final inflight = _mediaDownloadInflight[mediaId];
    if (inflight != null) return inflight;
    final request = _mediaApi
        .createDownloadUrl(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          mediaId: mediaId,
        )
        .then((grant) {
          _mediaDownloadCache[mediaId] = grant;
          return grant;
        })
        .whenComplete(() => _mediaDownloadInflight.remove(mediaId));
    _mediaDownloadInflight[mediaId] = request;
    return request;
  }

  Widget _pendingRow(PendingTextMessage item) {
    final failed = item.lastError != null;
    final row = Padding(
      key: Key('pending-${item.clientMessageId}'),
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: widget.embedded ? 520 : 290,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: failed
                          ? const Color(0xFFFFDCDC)
                          : DdColors.ownBubble,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child:
                        item.isImage ||
                            item.isGif ||
                            item.isSticker ||
                            item.isVoice ||
                            item.isFile
                        ? SizedBox(
                            width: 150,
                            height: 116,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    failed
                                        ? Icons.error_outline_rounded
                                        : item.isGif
                                        ? Icons.gif_box_outlined
                                        : item.isVoice
                                        ? Icons.mic_none_rounded
                                        : item.isFile
                                        ? Icons.insert_drive_file_outlined
                                        : Icons.image_outlined,
                                    size: 30,
                                    color: failed
                                        ? DdColors.danger
                                        : DdColors.textSecondary,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    failed
                                        ? '${_pendingMediaLabel(item)}发送失败'
                                        : '${_pendingMediaLabel(item)}发送中…',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Text(
                            item.text,
                            style: const TextStyle(
                              fontSize: 15,
                              height: 1.38,
                              color: DdColors.textPrimary,
                            ),
                          ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (failed)
                        const Icon(
                          Icons.error_rounded,
                          size: 12,
                          color: DdColors.danger,
                        ),
                      if (failed) const SizedBox(width: 3),
                      Text(
                        failed ? '发送失败' : '发送中…',
                        style: TextStyle(
                          fontSize: 10,
                          color: failed
                              ? DdColors.danger
                              : DdColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 9),
          _avatar(
            widget.currentUserId,
            widget.currentUserDisplayName.isEmpty
                ? '我'
                : widget.currentUserDisplayName,
            mine: true,
          ),
        ],
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: () => _showPendingActions(item),
      onSecondaryTapDown: (details) =>
          _showPendingMenuAt(item, details.globalPosition),
      child: row,
    );
  }

  String _pendingMediaLabel(PendingTextMessage item) {
    if (item.isGif) return 'GIF';
    if (item.isSticker) return '表情';
    if (item.isVoice) return '语音';
    if (item.isFile) return '文件';
    return '图片';
  }

  Widget _peerAvatar(ConversationItem conversation, {double size = 38}) {
    final peer = conversation.peer;
    final name = peer?.displayName ?? '对方';
    final avatar = _avatar(peer?.id ?? '', name, size: size);
    if (peer == null || peer.id.isEmpty || peer.handle.isEmpty) return avatar;
    return Tooltip(
      message: '查看 ${peer.displayName} 的资料',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openPeerProfile(conversation),
        child: avatar,
      ),
    );
  }

  Widget _avatar(
    String userId,
    String name, {
    double size = 38,
    bool mine = false,
  }) {
    if (userId.isEmpty) {
      final letter = name.trim().isEmpty ? '?' : name.trim().characters.first;
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF6EBB5A) : const Color(0xFF6F9FCA),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          letter,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.42,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return ProfileAvatar(
      origin: widget.coordinator.origin,
      accessToken: widget.coordinator.accessToken,
      userId: userId,
      displayName: name,
      size: size,
      revision: mine ? widget.currentUserAvatarRevision : 0,
      fallbackColor: mine ? const Color(0xFF6EBB5A) : const Color(0xFF6F9FCA),
    );
  }

  Widget _composerBar() {
    final replyingTo = _replyingTo;
    final surface = Theme.of(context).colorScheme.surface;
    return Material(
      color: surface,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: DdColors.divider, width: 0.5)),
        ),
        padding: EdgeInsets.fromLTRB(
          widget.embedded ? 14 : 8,
          8,
          widget.embedded ? 14 : 8,
          10,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyingTo != null) _replyPreview(replyingTo),
            if (_imageSending) _imageUploadBanner(),
            if (_fileSending) _fileUploadBanner(),
            if (_voiceRecording) _voiceRecordingBanner(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _voiceControlButton(),
                Expanded(child: _composerField()),
                IconButton(
                  key: const Key('chat-emoji'),
                  tooltip: 'Emoji',
                  onPressed: _showEmojiPicker,
                  icon: const Icon(
                    Icons.sentiment_satisfied_alt_rounded,
                    size: 25,
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _composer,
                  builder: (context, value, _) {
                    final hasText = value.text.trim().isNotEmpty;
                    if (hasText) {
                      return Padding(
                        padding: const EdgeInsets.only(left: 2, bottom: 3),
                        child: SizedBox(
                          height: 34,
                          child: FilledButton(
                            key: const Key('chat-send'),
                            onPressed: _send,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              minimumSize: const Size(0, 34),
                            ),
                            child: const Text(
                              '发送',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      );
                    }
                    return IconButton(
                      key: const Key('chat-more'),
                      tooltip: '更多',
                      onPressed: _showMoreMenu,
                      icon: const Icon(
                        Icons.add_circle_outline_rounded,
                        size: 26,
                      ),
                    );
                  },
                ),
              ],
            ),
            if (_keyboardSendEnabled)
              const Padding(
                padding: EdgeInsets.only(top: 3, right: 46),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'Enter 发送 · Shift+Enter 换行',
                    style: TextStyle(fontSize: 9, color: DdColors.textTertiary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _imageUploadBanner() {
    final percent = (_imageUploadProgress * 100).clamp(0, 100).round();
    final batch = _imageBatchTotal > 1
        ? ' · $_imageBatchCurrent/$_imageBatchTotal'
        : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: DdColors.ownBubble.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.image_outlined,
            size: 18,
            color: DdColors.greenPressed,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '正在发送图片$batch · $percent%',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 5),
                LinearProgressIndicator(
                  value: _imageUploadProgress.clamp(0, 1),
                  minHeight: 3,
                  backgroundColor: DdColors.divider,
                  color: DdColors.greenPressed,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileUploadBanner() {
    final percent = (_fileUploadProgress * 100).clamp(0, 100).round();
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
      decoration: BoxDecoration(
        color: DdColors.ownBubble.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.upload_file_rounded,
            size: 18,
            color: DdColors.greenPressed,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '正在上传文件 · $percent%',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 5),
                LinearProgressIndicator(
                  value: _fileUploadProgress.clamp(0, 1),
                  minHeight: 3,
                  backgroundColor: DdColors.divider,
                  color: DdColors.greenPressed,
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('cancel-file-upload'),
            tooltip: '取消上传',
            visualDensity: VisualDensity.compact,
            onPressed: _fileUploadCancellation?.cancel,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  bool get _mobileHoldToTalk =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Widget _voiceRecordingBanner() {
    final cancelling = _voiceCancelGesture;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cancelling
            ? const Color(0xFFFFE5E5)
            : DdColors.ownBubble.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(
            cancelling ? Icons.delete_outline_rounded : Icons.mic_rounded,
            size: 18,
            color: cancelling ? DdColors.danger : DdColors.greenPressed,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              cancelling
                  ? '松开取消发送'
                  : _mobileHoldToTalk
                  ? '正在录音 · 上滑取消'
                  : '正在录音 · 再点一次发送',
              style: TextStyle(
                fontSize: 12,
                color: cancelling ? DdColors.danger : DdColors.textPrimary,
              ),
            ),
          ),
          Text(
            '${_voiceElapsedSeconds ~/ 60}:${(_voiceElapsedSeconds % 60).toString().padLeft(2, '0')}',
            style: const TextStyle(
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _voiceControlButton() {
    final icon = _voiceRecording
        ? Icons.stop_circle_outlined
        : Icons.mic_none_rounded;
    final color = _voiceRecording ? DdColors.danger : null;
    final child = SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: _voiceSending
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 25, color: color),
      ),
    );
    if (_mobileHoldToTalk) {
      return Tooltip(
        message: '按住说话，上滑取消',
        child: GestureDetector(
          key: const Key('chat-voice'),
          behavior: HitTestBehavior.opaque,
          onLongPressStart: _voiceSending
              ? null
              : (_) => unawaited(_beginVoiceRecording()),
          onLongPressMoveUpdate: _voiceSending
              ? null
              : (details) {
                  final next = details.offsetFromOrigin.dy < -72;
                  if (next != _voiceCancelGesture && mounted) {
                    setState(() => _voiceCancelGesture = next);
                  }
                },
          onLongPressEnd: _voiceSending
              ? null
              : (_) => unawaited(
                  _finishVoiceRecording(cancel: _voiceCancelGesture),
                ),
          onLongPressCancel: _voiceSending
              ? null
              : () => unawaited(_finishVoiceRecording(cancel: true)),
          child: child,
        ),
      );
    }
    return Tooltip(
      message: _voiceRecording ? '结束并发送语音' : '录制语音',
      child: GestureDetector(
        key: const Key('chat-voice'),
        behavior: HitTestBehavior.opaque,
        onTap: _voiceSending
            ? null
            : () => unawaited(
                _voiceRecording
                    ? _finishVoiceRecording(cancel: false)
                    : _beginVoiceRecording(),
              ),
        child: child,
      ),
    );
  }

  Future<void> _beginVoiceRecording() async {
    if (_voiceSending || _voiceRecording || _voiceStartFuture != null) return;
    _dismissKeyboard();
    final startFuture = _startVoiceRecording();
    _voiceStartFuture = startFuture;
    try {
      await startFuture;
    } finally {
      if (identical(_voiceStartFuture, startFuture)) {
        _voiceStartFuture = null;
      }
    }
  }

  Future<void> _startVoiceRecording() async {
    try {
      await _voiceRecorder.start();
      if (!mounted) {
        await _voiceRecorder.cancel();
        return;
      }
      _voiceTimer?.cancel();
      setState(() {
        _voiceRecording = true;
        _voiceCancelGesture = false;
        _voiceElapsedSeconds = 0;
      });
      _voiceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || !_voiceRecording) {
          timer.cancel();
          return;
        }
        final next = _voiceElapsedSeconds + 1;
        setState(() => _voiceElapsedSeconds = next);
        if (next >= maxChatVoiceDurationMs ~/ 1000) {
          timer.cancel();
          unawaited(_finishVoiceRecording(cancel: false));
        }
      });
    } on FormatException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('麦克风启动失败，请检查系统权限和输入设备。');
    }
  }

  Future<void> _finishVoiceRecording({required bool cancel}) async {
    final starting = _voiceStartFuture;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        return;
      }
    }
    if (!_voiceRecorder.isRecording) return;
    _voiceTimer?.cancel();
    if (mounted) {
      setState(() {
        _voiceRecording = false;
        _voiceCancelGesture = false;
      });
    }
    if (cancel) {
      await _voiceRecorder.cancel();
      return;
    }
    if (mounted) setState(() => _voiceSending = true);
    try {
      final recorded = await _voiceRecorder.stop();
      final grant = await _mediaApi.uploadMedia(
        origin: widget.coordinator.origin,
        accessToken: widget.coordinator.accessToken,
        bytes: recorded.bytes,
        fileName: 'voice-${DateTime.now().microsecondsSinceEpoch}.wav',
        mimeType: 'audio/wav',
        purpose: 'CHAT_VOICE',
      );
      final replyToMessageId = _replyingTo?.id;
      if (_replyingTo != null && mounted) {
        setState(() => _replyingTo = null);
      }
      await widget.coordinator.sendMedia(
        widget.conversation.id,
        type: 'VOICE',
        mediaId: grant.mediaId,
        mimeType: 'audio/wav',
        sizeBytes: recorded.bytes.length,
        durationMs: recorded.durationMs,
        replyToMessageId: replyToMessageId,
      );
      if (mounted) _scrollToBottom();
    } on MessagingApiException catch (error) {
      if (mounted) _showImageError(error.message);
    } on FormatException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('语音发送失败，请稍后重试。');
    } finally {
      if (mounted) {
        setState(() {
          _voiceSending = false;
          _voiceElapsedSeconds = 0;
        });
      }
    }
  }

  Widget _composerField() {
    final field = TextField(
      key: const Key('chat-composer'),
      controller: _composer,
      focusNode: _composerFocusNode,
      minLines: 1,
      maxLines: 5,
      maxLength: 4000,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      decoration: const InputDecoration(
        hintText: '输入消息',
        counterText: '',
        filled: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      ),
    );
    if (!_keyboardSendEnabled) return field;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): _sendFromKeyboard,
      },
      child: field,
    );
  }

  Widget _replyPreview(ChatMessage message) {
    return Container(
      key: const Key('chat-reply-preview'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF2C2C2C)
            : const Color(0xFFF1F1F1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Container(width: 2, height: 24, color: DdColors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.isRecalled
                  ? '回复：该消息已撤回'
                  : '回复：${message.content?.text ?? '[${message.type}]'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: DdColors.textSecondary,
              ),
            ),
          ),
          IconButton(
            key: const Key('chat-cancel-reply'),
            tooltip: '取消回复',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _replyingTo = null),
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  bool _canAutoReadNow() {
    if (!mounted || !widget.hostVisible) return false;
    if (_lifecycleState != AppLifecycleState.resumed) return false;
    return ModalRoute.of(context)?.isCurrent ?? true;
  }

  void _updateReadVisibility() {
    if (!mounted) return;
    if (_canAutoReadNow()) {
      widget.coordinator.activateConversation(widget.conversation.id);
      unawaited(_markLatestReadIfVisible());
    } else {
      widget.coordinator.deactivateConversation(widget.conversation.id);
    }
  }

  Future<void> _markLatestReadIfVisible() async {
    if (!_canAutoReadNow()) return;
    final messages = widget.coordinator.messagesFor(widget.conversation.id);
    if (messages.isEmpty) return;
    final latestSequence = messages.last.sequence;
    final conversation =
        widget.coordinator.conversationFor(widget.conversation.id) ??
        widget.conversation;
    if (latestSequence <= conversation.lastReadSequence) return;
    await widget.coordinator.markReadThrough(
      widget.conversation.id,
      latestSequence,
    );
  }

  void _dismissKeyboard() {
    if (_composerFocusNode.hasFocus) _composerFocusNode.unfocus();
  }

  Future<void> _openPeerProfile(ConversationItem conversation) async {
    final peer = conversation.peer;
    if (peer == null || peer.id.isEmpty || peer.handle.isEmpty || !mounted) {
      return;
    }
    widget.coordinator.deactivateConversation(widget.conversation.id);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PeerProfilePage(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          userId: peer.id,
          handle: peer.handle,
          displayName: peer.displayName,
        ),
      ),
    );
    if (mounted) _updateReadVisibility();
  }

  Future<void> _load() async {
    try {
      await widget.coordinator.loadMessages(
        widget.conversation.id,
        markRead: false,
      );
      await _markLatestReadIfVisible();
      _scrollToBottom(immediate: true);
    } catch (_) {
      // Coordinator/API state already carries the actionable error.
    }
  }

  Future<void> _loadOlder() async {
    await widget.coordinator.loadOlder(widget.conversation.id);
  }

  Future<void> _sync() async {
    await widget.coordinator.flushPending();
    await widget.coordinator.syncNow();
    await widget.coordinator.loadMessages(
      widget.conversation.id,
      markRead: false,
    );
    await _markLatestReadIfVisible();
    _scrollToBottom();
  }

  Future<void> _startCall(CallKind kind) async {
    final conversation =
        widget.coordinator.conversationFor(widget.conversation.id) ??
        widget.conversation;
    final peer = conversation.peer;
    final handler = widget.onStartCall;
    if (peer == null || handler == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前入口尚未连接通话服务。')));
      }
      return;
    }
    await handler(peer.id, peer.displayName, kind);
  }

  void _sendFromKeyboard() {
    final composing = _composer.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    unawaited(_send());
  }

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    final replyToMessageId = _replyingTo?.id;
    if (_replyingTo != null) {
      setState(() => _replyingTo = null);
    }
    _composer.clear();
    // 不要在发送期间 disable TextField。Android IME 在 enabled true/false 切换时
    // 会重建 input connection，既掉帧又会把输入焦点吃掉。
    _composerFocusNode.requestFocus();
    unawaited(
      widget.coordinator.setDraft(widget.conversation.id, '', notify: false),
    );
    await widget.coordinator.sendText(
      widget.conversation.id,
      text,
      replyToMessageId: replyToMessageId,
    );
    if (mounted) {
      _composerFocusNode.requestFocus();
      _scrollToBottom();
    }
  }

  Future<void> _showEmojiPicker() async {
    final recent = widget.coordinator.recentEmoji;
    final selected = await showModalBottomSheet<String>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (context) => SafeArea(
        child: SizedBox(
          height: recent.isEmpty ? 280 : 356,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text(
                  'Emoji',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              if (recent.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    '最近使用',
                    style: TextStyle(
                      fontSize: 11,
                      color: DdColors.textSecondary,
                    ),
                  ),
                ),
                SizedBox(
                  height: 54,
                  child: ListView.separated(
                    key: const Key('chat-emoji-recent'),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    scrollDirection: Axis.horizontal,
                    itemCount: recent.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 2),
                    itemBuilder: (_, index) => InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => Navigator.pop(context, recent[index]),
                      child: SizedBox(
                        width: 46,
                        child: Center(
                          child: Text(
                            recent[index],
                            style: const TextStyle(fontSize: 25),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
              ],
              Expanded(
                child: GridView.builder(
                  key: const Key('chat-emoji-all'),
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 52,
                    mainAxisExtent: 48,
                  ),
                  itemCount: _emoji.length,
                  itemBuilder: (_, index) => InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => Navigator.pop(context, _emoji[index]),
                    child: Center(
                      child: Text(
                        _emoji[index],
                        style: const TextStyle(fontSize: 25),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    _insertAtSelection(selected);
    unawaited(widget.coordinator.rememberRecentEmoji(selected));
    _composerFocusNode.requestFocus();
  }

  void _insertAtSelection(String text) {
    final value = _composer.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start.clamp(0, value.text.length);
    final end = selection.end.clamp(0, value.text.length);
    final nextText = value.text.replaceRange(start, end, text);
    _composer.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  Future<void> _showMoreMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Row(
            children: [
              _ComposerAction(
                icon: Icons.image_outlined,
                label: _imageSending ? '处理中…' : '图片',
                enabled: !_imageSending,
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_pickAndSendImage());
                },
              ),
              const SizedBox(width: 14),
              _ComposerAction(
                icon: Icons.gif_box_outlined,
                label: _gifSending ? '处理中…' : 'GIF',
                enabled: !_gifSending,
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_pickAndSendGif());
                },
              ),
              const SizedBox(width: 10),
              _ComposerAction(
                icon: Icons.auto_awesome_outlined,
                label: _stickerSending ? '处理中…' : '表情',
                enabled: !_stickerSending,
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_pickAndSendSticker());
                },
              ),
              const SizedBox(width: 10),
              _ComposerAction(
                icon: _fileSending
                    ? Icons.close_rounded
                    : Icons.insert_drive_file_outlined,
                label: _fileSending
                    ? '取消 ${(100 * _fileUploadProgress).round()}%'
                    : '文件',
                enabled: true,
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (_fileSending) {
                    _fileUploadCancellation?.cancel();
                  } else {
                    unawaited(_pickAndSendFile());
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndSendImage() async {
    if (_imageSending) return;
    const typeGroup = XTypeGroup(
      label: '图片',
      extensions: <String>['jpg', 'jpeg', 'png', 'webp', 'bmp'],
    );
    final files = await openFiles(acceptedTypeGroups: const [typeGroup]);
    if (files.isEmpty || !mounted) return;
    if (files.length > 30) {
      _showImageError('一次最多发送 30 张图片。');
      return;
    }
    final replyToMessageId = _replyingTo?.id;
    if (_replyingTo != null) setState(() => _replyingTo = null);
    setState(() {
      _imageSending = true;
      _imageBatchCurrent = 0;
      _imageBatchTotal = files.length;
      _imageUploadProgress = 0;
    });
    var sentCount = 0;
    try {
      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        final sourceLength = await file.length();
        if (sourceLength > maxChatImageSourceBytes) {
          _showImageError(
            '${file.name.isEmpty ? '第 ${index + 1} 张图片' : file.name} 超过 96 MiB，已跳过。',
          );
          continue;
        }
        if (mounted) {
          setState(() {
            _imageBatchCurrent = index + 1;
            _imageUploadProgress = 0;
          });
        }
        final source = await file.readAsBytes();
        final processed = await processChatImage(source);
        final grant = await _mediaApi.uploadChatImage(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          bytes: processed.bytes,
          fileName: '${DateTime.now().microsecondsSinceEpoch}-$index.jpg',
          onProgress: (sent, total) {
            if (!mounted || total <= 0) return;
            final next = (sent / total).clamp(0.0, 1.0);
            if ((next - _imageUploadProgress).abs() < 0.02 && next < 1) return;
            setState(() => _imageUploadProgress = next);
          },
        );
        await widget.coordinator.sendImage(
          widget.conversation.id,
          mediaId: grant.mediaId,
          width: processed.width,
          height: processed.height,
          replyToMessageId: sentCount == 0 ? replyToMessageId : null,
        );
        sentCount++;
        if (mounted) _scrollToBottom();
      }
      if (sentCount == 0 && mounted) _showImageError('没有可发送的图片。');
    } on MessagingApiException catch (error) {
      if (mounted) _showImageError(error.message);
    } on FormatException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('图片发送失败，请稍后重试。');
    } finally {
      if (mounted) {
        setState(() {
          _imageSending = false;
          _imageBatchCurrent = 0;
          _imageBatchTotal = 0;
          _imageUploadProgress = 0;
        });
      }
    }
  }

  Future<void> _pickAndSendSticker() async {
    if (_stickerSending) return;
    const typeGroup = XTypeGroup(
      label: '图片表情',
      extensions: <String>['png', 'webp', 'gif'],
    );
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null || !mounted) return;
    final sourceLength = await file.length();
    if (!mounted) return;
    if (sourceLength > 10 * 1024 * 1024) {
      _showImageError('图片表情超过 10 MiB，暂时无法发送。');
      return;
    }
    setState(() => _stickerSending = true);
    try {
      final source = await file.readAsBytes();
      final metadata = await inspectChatVisual(source);
      final lowerName = file.name.toLowerCase();
      final mimeType = lowerName.endsWith('.gif')
          ? 'image/gif'
          : lowerName.endsWith('.webp')
          ? 'image/webp'
          : 'image/png';
      final grant = await _mediaApi.uploadMedia(
        origin: widget.coordinator.origin,
        accessToken: widget.coordinator.accessToken,
        bytes: source,
        fileName: file.name.isEmpty ? 'sticker.png' : file.name,
        mimeType: mimeType,
        purpose: 'STICKER',
      );
      final replyToMessageId = _replyingTo?.id;
      if (_replyingTo != null && mounted) {
        setState(() => _replyingTo = null);
      }
      await widget.coordinator.sendMedia(
        widget.conversation.id,
        type: 'STICKER',
        mediaId: grant.mediaId,
        width: metadata.width,
        height: metadata.height,
        fileName: file.name,
        mimeType: mimeType,
        sizeBytes: source.length,
        replyToMessageId: replyToMessageId,
      );
      if (mounted) _scrollToBottom();
    } on MessagingApiException catch (error) {
      if (mounted) _showImageError(error.message);
    } on FormatException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('图片表情发送失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _stickerSending = false);
    }
  }

  Future<void> _pickAndSendGif() async {
    if (_gifSending) return;
    const typeGroup = XTypeGroup(label: 'GIF', extensions: <String>['gif']);
    final file = await openFile(acceptedTypeGroups: const [typeGroup]);
    if (file == null || !mounted) return;
    final sourceLength = await file.length();
    if (!mounted) return;
    if (sourceLength > 50 * 1024 * 1024) {
      _showImageError('GIF 超过 50 MiB，暂时无法发送。');
      return;
    }
    setState(() => _gifSending = true);
    try {
      final source = await file.readAsBytes();
      final metadata = await inspectChatVisual(source);
      final grant = await _mediaApi.uploadMedia(
        origin: widget.coordinator.origin,
        accessToken: widget.coordinator.accessToken,
        bytes: source,
        fileName: file.name.isEmpty ? 'animation.gif' : file.name,
        mimeType: 'image/gif',
        purpose: 'GIF',
      );
      final replyToMessageId = _replyingTo?.id;
      if (_replyingTo != null && mounted) {
        setState(() => _replyingTo = null);
      }
      await widget.coordinator.sendMedia(
        widget.conversation.id,
        type: 'GIF',
        mediaId: grant.mediaId,
        width: metadata.width,
        height: metadata.height,
        fileName: file.name,
        mimeType: 'image/gif',
        sizeBytes: source.length,
        replyToMessageId: replyToMessageId,
      );
      if (mounted) _scrollToBottom();
    } on MessagingApiException catch (error) {
      if (mounted) _showImageError(error.message);
    } on FormatException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('GIF 发送失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _gifSending = false);
    }
  }

  Future<void> _pickAndSendFile() async {
    if (_fileSending) return;
    final file = await openFile();
    if (file == null || !mounted) return;
    final sourceLength = await file.length();
    if (!mounted) return;
    if (sourceLength <= 0) {
      _showImageError('不能发送空文件。');
      return;
    }
    if (sourceLength > 2 * 1024 * 1024 * 1024) {
      _showImageError('文件超过 2 GiB，当前实例拒绝上传。');
      return;
    }
    final cancellation = MediaUploadCancellation();
    _fileUploadCancellation = cancellation;
    setState(() {
      _fileSending = true;
      _fileUploadProgress = 0;
    });
    try {
      final mimeType = _fileMimeType(file.name);
      final grant = await _mediaApi.uploadStream(
        origin: widget.coordinator.origin,
        accessToken: widget.coordinator.accessToken,
        streamFactory: file.openRead,
        size: sourceLength,
        fileName: file.name.isEmpty ? 'file.bin' : file.name,
        mimeType: mimeType,
        purpose: 'CHAT_FILE',
        cancellation: cancellation,
        onProgress: (sent, total) {
          if (!mounted || total <= 0) return;
          final progress = sent / total;
          if ((progress - _fileUploadProgress).abs() < 0.01 && progress < 1)
            return;
          setState(() => _fileUploadProgress = progress.clamp(0, 1));
        },
      );
      final replyToMessageId = _replyingTo?.id;
      if (_replyingTo != null && mounted) setState(() => _replyingTo = null);
      await widget.coordinator.sendMedia(
        widget.conversation.id,
        type: 'FILE',
        mediaId: grant.mediaId,
        fileName: file.name,
        mimeType: mimeType,
        sizeBytes: sourceLength,
        replyToMessageId: replyToMessageId,
      );
      if (mounted) _scrollToBottom();
    } on MediaUploadCancelled {
      if (mounted) _showImageError('已取消文件上传。');
    } on MessagingApiException catch (error) {
      if (mounted) _showImageError(error.message);
    } on FormatException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('文件发送失败，请稍后重试。');
    } finally {
      if (identical(_fileUploadCancellation, cancellation)) {
        _fileUploadCancellation = null;
      }
      if (mounted) {
        setState(() {
          _fileSending = false;
          _fileUploadProgress = 0;
        });
      }
    }
  }

  String _fileMimeType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.txt') ||
        lower.endsWith('.log') ||
        lower.endsWith('.md')) {
      return 'text/plain';
    }
    if (lower.endsWith('.zip')) return 'application/zip';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    return 'application/octet-stream';
  }

  void _showImageError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showPendingActions(PendingTextMessage item) async {
    final action = await showDdActionSheet<String>(
      context,
      items: const [
        DdActionSheetItem(
          value: 'retry',
          icon: Icons.refresh_rounded,
          label: '立即重试',
        ),
        DdActionSheetItem(
          value: 'cancel',
          icon: Icons.close_rounded,
          label: '取消发送',
          destructive: true,
        ),
      ],
    );
    await _applyPendingAction(item, action);
  }

  Future<void> _showPendingMenuAt(
    PendingTextMessage item,
    Offset globalPosition,
  ) async {
    final action = await _showContextMenu(globalPosition, [
      _contextMenuItem(
        value: 'retry',
        icon: Icons.refresh_rounded,
        label: '立即重试',
      ),
      _contextMenuItem(
        value: 'cancel',
        icon: Icons.close_rounded,
        label: '取消发送',
        destructive: true,
      ),
    ]);
    await _applyPendingAction(item, action);
  }

  Future<void> _applyPendingAction(
    PendingTextMessage item,
    String? action,
  ) async {
    if (action == 'retry') {
      await widget.coordinator.retryPending(item.clientMessageId);
    } else if (action == 'cancel') {
      await widget.coordinator.cancelPending(item.clientMessageId);
    }
  }

  Future<void> _showMessageActions(ChatMessage message, bool mine) async {
    final action = await showDdActionSheet<String>(
      context,
      items: [
        if (!message.isRecalled)
          const DdActionSheetItem(
            value: 'reply',
            icon: Icons.reply_rounded,
            label: '回复',
          ),
        if (!message.isRecalled && message.content?.text.isNotEmpty == true)
          const DdActionSheetItem(
            value: 'copy',
            icon: Icons.content_copy_rounded,
            label: '复制文字',
          ),
        if (mine && !message.isRecalled)
          const DdActionSheetItem(
            value: 'recall',
            icon: Icons.undo_rounded,
            label: '撤回',
            subtitle: '自己的消息默认不限时',
          ),
        const DdActionSheetItem(
          value: 'delete',
          icon: Icons.delete_outline_rounded,
          label: '仅本地删除',
          destructive: true,
        ),
      ],
    );
    await _applyMessageAction(message, action);
  }

  Future<void> _showMessageMenuAt(
    ChatMessage message,
    bool mine,
    Offset globalPosition,
  ) async {
    final entries = <PopupMenuEntry<String>>[
      if (!message.isRecalled)
        _contextMenuItem(
          value: 'reply',
          icon: Icons.reply_rounded,
          label: '回复',
        ),
      if (!message.isRecalled && message.content?.text.isNotEmpty == true)
        _contextMenuItem(
          value: 'copy',
          icon: Icons.content_copy_rounded,
          label: '复制文字',
        ),
      if (mine && !message.isRecalled)
        _contextMenuItem(
          value: 'recall',
          icon: Icons.undo_rounded,
          label: '撤回',
        ),
      const PopupMenuDivider(height: 5),
      _contextMenuItem(
        value: 'delete',
        icon: Icons.delete_outline_rounded,
        label: '仅本地删除',
        destructive: true,
      ),
    ];
    final action = await _showContextMenu(globalPosition, entries);
    await _applyMessageAction(message, action);
  }

  Future<void> _applyMessageAction(ChatMessage message, String? action) async {
    if (action == 'reply') {
      setState(() => _replyingTo = message);
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.content?.text ?? ''));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制')));
      }
    } else if (action == 'recall') {
      await widget.coordinator.recall(message);
    } else if (action == 'delete') {
      await widget.coordinator.deleteLocally(message);
    }
  }

  PopupMenuItem<String> _contextMenuItem({
    required String value,
    required IconData icon,
    required String label,
    bool destructive = false,
  }) {
    final color = destructive
        ? DdColors.danger
        : Theme.of(context).colorScheme.onSurface;
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 11),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 13, color: color)),
          ),
        ],
      ),
    );
  }

  Future<String?> _showContextMenu(
    Offset globalPosition,
    List<PopupMenuEntry<String>> items,
  ) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return showMenu<String>(
      context: context,
      color: Theme.of(context).colorScheme.surface,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 224),
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
  }

  Widget _replyReference(String messageId, bool mine) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: mine
            ? Colors.white.withValues(alpha: 0.35)
            : const Color(0xFFF3F3F3),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        _replyLabel(messageId),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11, color: DdColors.textSecondary),
      ),
    );
  }

  String _replyLabel(String messageId) {
    final messages = widget.coordinator.messagesFor(widget.conversation.id);
    for (final message in messages) {
      if (message.id != messageId) continue;
      if (message.isRecalled) return '该消息已撤回';
      final text = message.content?.text;
      if (text != null && text.isNotEmpty) return text;
      return '[${message.type}]';
    }
    return '引用消息';
  }

  void _scheduleDraftSave() {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(
        widget.coordinator.setDraft(
          widget.conversation.id,
          _composer.text,
          notify: false,
        ),
      );
    });
  }

  void _scrollToBottom({bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (immediate) {
        _scrollController.jumpTo(target);
        return;
      }
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    });
  }

  String _shortTime(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

class _AndroidKeyboardLift extends StatefulWidget {
  const _AndroidKeyboardLift({required this.child});

  final Widget child;

  @override
  State<_AndroidKeyboardLift> createState() => _AndroidKeyboardLiftState();
}

class _AndroidKeyboardLiftState extends State<_AndroidKeyboardLift>
    with WidgetsBindingObserver {
  double _bottomInset = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshInset());
  }

  @override
  void didChangeMetrics() => _refreshInset();

  void _refreshInset() {
    if (!mounted) return;
    final view = View.of(context);
    final next = view.viewInsets.bottom / view.devicePixelRatio;
    if ((next - _bottomInset).abs() < 0.5) return;
    setState(() => _bottomInset = next);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Android 键盘动画期间只移动已经完成布局的聊天表面，不重新计算整条
    // 消息列表的高度。Transform 走合成层，避免 IME 每一帧把长历史重新 layout。
    return ClipRect(
      child: Transform.translate(
        offset: Offset(0, -_bottomInset),
        child: widget.child,
      ),
    );
  }
}

class _ComposerAction extends StatelessWidget {
  const _ComposerAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Icon(icon, size: 25),
                ),
                const SizedBox(height: 7),
                Text(label, style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 11),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DisabledComposerAction extends StatelessWidget {
  const _DisabledComposerAction({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Opacity(
        opacity: 0.42,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Icon(icon, size: 25),
            ),
            const SizedBox(height: 7),
            Text(label, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 2),
            const Text(
              '开发中',
              style: TextStyle(fontSize: 9, color: DdColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
