import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/logging/client_log.dart';
import '../../../core/media/camera_capture_service.dart';
import '../../../core/media/chat_image_processor.dart';
import '../../../core/media/chat_voice_recorder.dart';
import '../../../core/media/dd_file_picker.dart';
import '../../../core/media/image_viewer_page.dart';
import '../../../core/media/media_cache_manager.dart';
import '../../../core/media/remote_media_action_service.dart';
import '../../../core/platform/external_url_opener.dart';
import '../../../core/widgets/dd_action_sheet.dart';
import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../calls/data/group_call_api_client.dart';
import '../../calls/domain/call_session.dart';
import '../../calls/domain/group_call_models.dart';
import '../../calls/presentation/group_call_page.dart';
import '../../contacts/data/contacts_api_client.dart';
import '../../contacts/domain/contact_models.dart';
import '../../contacts/presentation/peer_profile_page.dart';
import '../../groups/data/groups_api_client.dart';
import '../../groups/domain/group_models.dart';
import '../../groups/presentation/group_details_page.dart';
import '../../moments/presentation/moment_contact_privacy_page.dart';
import '../../moments/presentation/moments_feed_page.dart';
import '../application/media_transfer_controller.dart';
import '../application/messaging_coordinator.dart';
import '../data/chat_appearance_store.dart';
import '../data/chat_voice_player.dart';
import '../data/custom_sticker_processor.dart';
import '../data/link_preview_api_client.dart';
import '../data/media_api_client.dart';
import '../data/media_auto_download_store.dart';
import '../data/media_download_grant_cache.dart';
import '../data/media_download_resolver.dart';
import '../data/media_local_cache.dart';
import '../data/messaging_api_client.dart' show MessagingApiException;
import '../data/sticker_api_client.dart';
import '../data/video_file_cache.dart';
import '../data/video_media_probe.dart';
import '../domain/emoji_catalog.dart';
import '../domain/media_transfer_state.dart';
import '../domain/messaging_models.dart';
import '../domain/sticker_models.dart';
import 'chat_background_settings_page.dart';
import 'chat_details_page.dart';
import 'chat_wallpaper_surface.dart';
import 'conversation_media_page.dart';
import 'desktop_inspector.dart';
import 'desktop_mention_profile_dialog.dart';
import 'desktop_video_pip.dart';
import 'mention_composer_controller.dart';
import 'mention_rich_text.dart';
import 'mention_suggestion_overlay.dart';
import 'sticker_library_sheet.dart';
import 'video_viewer_page.dart';
import 'widgets/inline_video_preview.dart';
import 'widgets/looping_video_sticker.dart';
import 'widgets/media_transfer_progress.dart';
import 'widgets/message_link_preview.dart';
import 'widgets/telegram_tgs_sticker.dart';

class TextChatPage extends StatefulWidget {
  const TextChatPage({
    super.key,
    required this.coordinator,
    required this.conversation,
    required this.currentUserId,
    this.currentUserDisplayName = '',
    this.currentUserAvatarRevision = 0,
    this.onStartCall,
    this.onOpenDirectChat,
    this.mentionSuggestionLoader,
    this.hostVisible = true,
    this.embedded = false,
    this.savedMessagesMode = false,
    this.initialMessageId,
    this.stickerGateway,
    this.groupsGateway,
    this.mediaPreferencesStore,
    this.cameraCapture,
    this.inspectorController,
    this.groupCallGateway,
  });

  final MessagingCoordinator coordinator;
  final ConversationItem conversation;
  final String currentUserId;
  final String currentUserDisplayName;
  final int currentUserAvatarRevision;
  final Future<void> Function(String peerId, String peerName, CallKind kind)?
  onStartCall;
  final Future<void> Function(String userId)? onOpenDirectChat;
  final Future<List<ContactMentionSuggestion>> Function(String query)?
  mentionSuggestionLoader;
  final bool hostVisible;
  final bool embedded;
  final bool savedMessagesMode;
  final String? initialMessageId;
  final StickerGateway? stickerGateway;
  final GroupsGateway? groupsGateway;
  final MediaAutoDownloadStore? mediaPreferencesStore;
  final CameraCaptureGateway? cameraCapture;
  final DesktopInspectorController? inspectorController;
  final GroupCallGateway? groupCallGateway;

  @override
  State<TextChatPage> createState() => _TextChatPageState();
}

class _TextChatPageState extends State<TextChatPage>
    with WidgetsBindingObserver {
  late final TextEditingController _composer;
  late final FocusNode _composerFocusNode;
  late final ScrollController _scrollController;
  late final ChatAppearanceStore _appearanceStore;
  late final MediaApiClient _mediaApi;
  late final LinkPreviewApiClient _linkPreviewApi;
  late final CameraCaptureGateway _cameraCapture;
  late final GroupCallGateway _groupCallGateway;
  late final bool _ownsGroupCallGateway;
  GroupCallInfo? _activeGroupCall;
  bool _groupCallBusy = false;
  Timer? _groupCallRefreshTimer;
  late final MediaAutoDownloadStore _mediaPreferencesStore;
  MediaAutoDownloadPreferences _mediaPreferences =
      const MediaAutoDownloadPreferences();
  final Set<String> _manualMediaLoads = <String>{};
  final Set<String> _autoVideoCacheStarted = <String>{};
  final Set<String> _autoFileCacheStarted = <String>{};
  late final ContactsApiClient _contactsApi;
  late final GroupsGateway _groupsApi;
  late final bool _ownsGroupsApi;
  Map<String, GroupMemberItem> _groupMembers = const {};
  late final MediaLocalCache _mediaCache;
  late final VideoFileCache _videoFileCache;
  late final MentionComposerController _mentionController;
  final LayerLink _mentionLayerLink = LayerLink();
  final GlobalKey _mentionAnchorKey = GlobalKey();
  OverlayEntry? _mentionOverlayEntry;
  late final ChatVoiceRecorder _voiceRecorder;
  late final ChatVoicePlayer _voicePlayer;
  final MediaDownloadGrantCache _mediaDownloadGrants =
      MediaDownloadGrantCache();
  final Map<String, Future<Uri>> _stickerVideoSourceInflight =
      <String, Future<Uri>>{};
  final RemoteMediaActionService _remoteMediaActions =
      RemoteMediaActionService();
  final Map<String, Future<LinkPreviewData>> _linkPreviewCache =
      <String, Future<LinkPreviewData>>{};
  Timer? _draftSaveTimer;
  late final MediaTransferController _uploadTransfers;
  bool _stickerSending = false;

  bool _voiceMode = false;
  bool _voiceRecording = false;
  bool _voiceCancelGesture = false;
  bool _voiceSending = false;
  bool _dropHover = false;
  int _voiceElapsedSeconds = 0;
  double _voiceAmplitude = 0;
  int? _voicePointerId;
  Timer? _voiceTimer;
  StreamSubscription<double>? _voiceAmplitudeSubscription;
  Future<void>? _voiceStartFuture;
  String? _playingVoiceMessageId;
  Duration _voicePosition = Duration.zero;
  Duration _voiceDuration = Duration.zero;
  double _voicePlaybackRate = 1;
  ChatMessage? _replyingTo;
  ChatMessage? _editingMessage;
  String? _draftBeforeEdit;
  final Map<String, GlobalKey> _messageAnchorKeys = {};
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  List<PinnedMessageItem> _pinnedMessages = const [];
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  bool get _keyboardSendEnabled =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;

  bool get _desktopFileDropEnabled =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  void initState() {
    super.initState();
    _composer = TextEditingController(
      text: widget.coordinator.draftFor(widget.conversation.id),
    );
    _composer.addListener(_scheduleDraftSave);
    _composerFocusNode = FocusNode(debugLabel: 'chat-composer');
    _scrollController = ScrollController();
    _appearanceStore = ChatAppearanceStore.shared(widget.currentUserId);
    unawaited(_appearanceStore.load());
    _mediaApi = MediaApiClient();
    _linkPreviewApi = LinkPreviewApiClient();
    _uploadTransfers = widget.coordinator.mediaTransfers;
    _cameraCapture = widget.cameraCapture ?? CameraCaptureService();
    _ownsGroupCallGateway = widget.groupCallGateway == null;
    _groupCallGateway = widget.groupCallGateway ?? GroupCallApiClient();
    if (widget.conversation.type == 'GROUP') {
      unawaited(_refreshActiveGroupCall());
      _groupCallRefreshTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_refreshActiveGroupCall()),
      );
    }
    _mediaPreferencesStore =
        widget.mediaPreferencesStore ??
        MediaAutoDownloadStore.shared(widget.currentUserId);
    _mediaPreferences = _mediaPreferencesStore.value;
    _mediaPreferencesStore.addListener(_onMediaPreferencesChanged);
    unawaited(_loadMediaPreferences());
    _contactsApi = ContactsApiClient();
    _ownsGroupsApi = widget.groupsGateway == null;
    _groupsApi = widget.groupsGateway ?? GroupsApiClient();
    _mentionController = MentionComposerController(
      loader: (query) {
        final injected = widget.mentionSuggestionLoader;
        if (injected != null) return injected(query);
        return widget.coordinator.withAuthorizedToken(
          (token) => _contactsApi.suggestMentions(
            origin: widget.coordinator.origin,
            accessToken: token,
            query: query,
            conversationId: widget.conversation.id,
          ),
        );
      },
    );
    _mentionController.addListener(_syncMentionOverlay);
    _composer.addListener(_updateMentionTrigger);
    _mentionController.update(_composer.value);
    _mediaCache = MediaLocalCache(namespace: widget.currentUserId);
    _videoFileCache = VideoFileCache(
      namespace: '${widget.coordinator.origin.origin}|${widget.currentUserId}',
    );
    _voiceRecorder = ChatVoiceRecorder();
    _voiceAmplitudeSubscription = _voiceRecorder.amplitudes.listen((value) {
      if (mounted && _voiceRecording) {
        setState(() => _voiceAmplitude = value);
      }
    });
    _voicePlayer = ChatVoicePlayer();
    _voicePlayer.completed.listen((_) {
      if (!mounted) return;
      setState(() {
        _playingVoiceMessageId = null;
        _voicePosition = Duration.zero;
      });
    });
    _voicePlayer.playing.listen((_) {
      if (mounted) setState(() {});
    });
    _voicePlayer.position.listen((position) {
      if (mounted) setState(() => _voicePosition = position);
    });
    _voicePlayer.duration.listen((duration) {
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
        _mentionController.close();
        _editingMessage = null;
        _draftBeforeEdit = null;
        _replyingTo = null;
      }
      _updateReadVisibility();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _updateReadVisibility();
  }

  Future<void> _loadMediaPreferences() async {
    try {
      await _mediaPreferencesStore.load();
      if (mounted) _onMediaPreferencesChanged();
    } catch (_) {
      // Auto-download preferences are optional; safe defaults remain active.
    }
  }

  void _onMediaPreferencesChanged() {
    if (!mounted) return;
    setState(() => _mediaPreferences = _mediaPreferencesStore.value);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftSaveTimer?.cancel();
    _voiceTimer?.cancel();
    _highlightTimer?.cancel();
    unawaited(_voiceAmplitudeSubscription?.cancel());
    unawaited(_voiceRecorder.dispose());
    unawaited(_voicePlayer.dispose());
    unawaited(
      widget.coordinator.setDraft(
        widget.conversation.id,
        _editingMessage == null ? _composer.text : (_draftBeforeEdit ?? ''),
      ),
    );
    widget.coordinator.deactivateConversation(widget.conversation.id);
    _removeMentionOverlay();
    _mentionController.removeListener(_syncMentionOverlay);
    _mentionController.dispose();
    _composer.removeListener(_updateMentionTrigger);
    _composer.removeListener(_scheduleDraftSave);
    _composerFocusNode.dispose();
    _composer.dispose();
    _scrollController.dispose();
    _mediaPreferencesStore.removeListener(_onMediaPreferencesChanged);
    _groupCallRefreshTimer?.cancel();
    if (_ownsGroupCallGateway) _groupCallGateway.close();
    _mediaApi.close();
    _linkPreviewApi.close();
    _contactsApi.close();
    if (_ownsGroupsApi) _groupsApi.close();
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
        final replyingTo = _replyingTo;
        if (replyingTo != null &&
            widget.coordinator.isMessageRecalled(
              conversation.id,
              replyingTo.id,
            )) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _replyingTo?.id != replyingTo.id) return;
            setState(() => _replyingTo = null);
          });
        }
        final editingMessage = _editingMessage;
        if (editingMessage != null &&
            !messages.any((message) => message.id == editingMessage.id)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _editingMessage?.id != editingMessage.id) return;
            final restore = _draftBeforeEdit ?? '';
            setState(() {
              _editingMessage = null;
              _draftBeforeEdit = null;
            });
            _composer.text = restore;
          });
        }
        final body = Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: ChatWallpaperSurface(
                store: _appearanceStore,
                conversationId: conversation.id,
              ),
            ),
            SafeArea(
              top: false,
              child: Column(
                children: [
                  if (widget.embedded) _desktopHeader(conversation),
                  if (widget.coordinator.errorMessage != null)
                    _errorBar(widget.coordinator.errorMessage!),
                  if (_pinnedMessages.isNotEmpty) _pinnedMessageBar(),
                  Expanded(
                    child: GestureDetector(
                      key: const Key('chat-message-surface'),
                      behavior: HitTestBehavior.translucent,
                      onTap: _dismissKeyboard,
                      child: AnimatedBuilder(
                        animation: _uploadTransfers,
                        builder: (context, _) {
                          final visualTransfers = _pendingVisualUploadTasks(
                            conversation.id,
                          );
                          if (messages.isEmpty &&
                              pending.isEmpty &&
                              visualTransfers.isEmpty) {
                            return _emptyState(conversation);
                          }
                          return _messageList(
                            conversation,
                            messages,
                            pending,
                            visualTransfers,
                          );
                        },
                      ),
                    ),
                  ),
                  _composerBar(conversation),
                ],
              ),
            ),
          ],
        );

        final interactiveBody = _desktopFileDropEnabled
            ? _desktopDropTarget(body)
            : body;

        if (widget.embedded) return interactiveBody;
        return Scaffold(
          resizeToAvoidBottomInset: false,
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1D1D1D)
              : DdColors.chatBackground,
          appBar: AppBar(
            titleSpacing: 0,
            title: _chatTitle(conversation),
            actions: [
              if (!widget.savedMessagesMode &&
                  conversation.type != 'GROUP') ...[
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
              ],
              IconButton(
                key: const Key('chat-details'),
                tooltip: '聊天详情',
                onPressed: () => unawaited(_openChatDetails(conversation)),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: defaultTargetPlatform == TargetPlatform.android
              ? _AndroidKeyboardLift(child: interactiveBody)
              : interactiveBody,
        );
      },
    );
  }

  Widget _desktopDropTarget(Widget child) {
    return DropTarget(
      enable: widget.hostVisible,
      onDragEntered: (_) {
        if (!_dropHover && mounted) setState(() => _dropHover = true);
      },
      onDragExited: (_) {
        if (_dropHover && mounted) setState(() => _dropHover = false);
      },
      onDragDone: (details) {
        if (mounted) setState(() => _dropHover = false);
        unawaited(_confirmDroppedItems(details.files));
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (_dropHover)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.28),
                  child: Center(
                    child: Container(
                      key: const Key('chat-file-drop-overlay'),
                      width: 280,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 30,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(DdRadii.sheet),
                        border: Border.all(color: DdColors.green, width: 2),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x33000000),
                            blurRadius: 22,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.file_upload_outlined,
                            size: 44,
                            color: DdColors.green,
                          ),
                          SizedBox(height: 12),
                          Text(
                            '松开选择发送方式',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            '图片会按图片消息发送，其他文件按原文件发送',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: DdColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDroppedItems(List<DropItem> items) async {
    final files = items.whereType<DropItemFile>().toList(growable: false);
    if (files.isEmpty) {
      if (mounted) _showImageError('暂不支持直接发送文件夹，请拖入文件。');
      return;
    }
    final imageCount = files
        .where((file) => _isImageFileName(file.name))
        .length;
    var totalBytes = 0;
    for (final file in files) {
      try {
        totalBytes += await file.length();
      } catch (_) {
        // A file can disappear after the OS drop event. Upload will surface the
        // actionable error later; confirmation should still remain usable.
      }
    }
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          files.length == 1
              ? '发送 ${files.first.name}'
              : '发送 ${files.length} 个文件',
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (files.length > 1)
                Text(
                  files.take(5).map((file) => file.name).join('\n') +
                      (files.length > 5 ? '\n…还有 ${files.length - 5} 个' : ''),
                  maxLines: 7,
                  overflow: TextOverflow.ellipsis,
                ),
              if (files.length > 1) const SizedBox(height: 14),
              Text(
                '${files.length} 个文件 · ${_formatBytes(totalBytes)}',
                key: const Key('drop-file-summary'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                imageCount > 0
                    ? '检测到 $imageCount 张图片。可以按图片发送以显示缩略图，也可以全部按原文件发送。'
                    : '确认后才会开始上传；取消不会产生消息。',
                style: const TextStyle(
                  fontSize: 12,
                  color: DdColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          if (imageCount > 0)
            OutlinedButton(
              key: const Key('drop-send-as-files'),
              onPressed: () => Navigator.pop(dialogContext, 'files'),
              child: const Text('作为文件发送'),
            ),
          FilledButton(
            key: const Key('drop-send-smart'),
            onPressed: () => Navigator.pop(dialogContext, 'smart'),
            child: Text(imageCount > 0 ? '发送' : '发送文件'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    await _sendDroppedItems(items, imagesAsFiles: choice == 'files');
  }

  bool _isImageFileName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  Future<void> _sendDroppedItems(
    List<DropItem> items, {
    bool imagesAsFiles = false,
  }) async {
    final files = items.whereType<DropItemFile>().toList(growable: false);
    if (files.isEmpty) {
      if (mounted) _showImageError('暂不支持直接发送文件夹，请拖入文件。');
      return;
    }
    final images = <XFile>[];
    final others = <XFile>[];
    for (final file in files) {
      if (!imagesAsFiles && _isImageFileName(file.name)) {
        images.add(file);
      } else {
        others.add(file);
      }
    }
    if (images.isNotEmpty) await _sendImageFiles(images);
    for (final file in others) {
      if (!mounted) return;
      await _sendFile(file);
    }
  }

  Widget _desktopHeader(ConversationItem conversation) {
    final brightness = Theme.of(context).brightness;
    return Container(
      key: const Key('chat-desktop-header'),
      height: DdDesktopTokens.chatHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: DdDesktopTokens.titleBarSurface(brightness),
        border: Border(
          bottom: BorderSide(
            color: DdDesktopTokens.borderSubtle(brightness),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: _chatTitle(conversation)),
          if (!widget.savedMessagesMode && conversation.type != 'GROUP') ...[
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
          ],
          IconButton(
            key: const Key('chat-details'),
            tooltip: '聊天详情',
            onPressed: () => unawaited(_openChatDetails(conversation)),
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
    );
  }

  Widget _chatTitle(ConversationItem conversation) {
    if (widget.savedMessagesMode) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '我的收藏',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          Text(
            '仅自己可见 · 跨设备同步',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: DdColors.textSecondary,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      );
    }
    if (conversation.type == 'GROUP') {
      final group = conversation.group;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group?.name ?? '群聊',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          Text(
            '${group?.memberCount ?? 0} 位成员',
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
    if (widget.savedMessagesMode) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: DdColors.green,
                child: Icon(
                  Icons.bookmark_rounded,
                  size: 32,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 14),
              Text(
                '我的收藏',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 7),
              Text(
                '给自己发送文字、图片、文件或语音，也可以从其他聊天收藏和转发到这里。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: DdColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final isGroup = conversation.type == 'GROUP';
    final name = isGroup
        ? conversation.group?.name ?? '群聊'
        : conversation.peer?.displayName ?? '对方';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _peerAvatar(conversation, size: 58),
            const SizedBox(height: 14),
            Text(
              isGroup ? '在 $name 开始群聊' : '和 $name 开始聊天',
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

  Widget _pinnedMessageBar() {
    final item = _pinnedMessages.first;
    final message = item.message;
    final summary = _pinnedMessageSummary(message);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        key: const Key('pinned-message-bar'),
        onTap: () => unawaited(
          _pinnedMessages.length > 1
              ? _showPinnedMessageManager()
              : _jumpToMessage(message.id),
        ),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: DdColors.divider, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 30,
                decoration: BoxDecoration(
                  color: DdColors.greenPressed,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _pinnedMessages.length == 1
                          ? '置顶消息'
                          : '置顶消息 · 1/${_pinnedMessages.length}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: DdColors.greenPressed,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(
                _pinnedMessages.length > 1
                    ? Icons.list_alt_rounded
                    : Icons.chevron_right_rounded,
                key: _pinnedMessages.length > 1
                    ? const Key('pinned-message-manager-icon')
                    : null,
                size: 18,
                color: DdColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _pinnedMessageSummary(ChatMessage message) {
    if (message.isRecalled) return '';
    return switch (message.type) {
      'TEXT' => message.content?.text ?? '消息',
      'IMAGE' => '[图片]',
      'GIF' => '[GIF]',
      'STICKER' => '[表情]',
      'STICKER_PACK' => '[表情包]',
      'VOICE' => '[语音]',
      'VIDEO' => '[视频]',
      'FILE' => '[文件] ${message.content?.fileName ?? ''}',
      _ => '[消息]',
    };
  }

  String _formatMessageTime(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    final sameDay =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final hhmm =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (sameDay) return hhmm;
    return '${local.month}/${local.day} $hhmm';
  }

  Future<void> _showPinnedMessageManager() async {
    if (_pinnedMessages.isEmpty || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.68,
        child: Column(
          key: const Key('pinned-message-manager'),
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: DdColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const SizedBox(width: 18),
                const Expanded(
                  child: Text(
                    '置顶消息',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${_pinnedMessages.length} 条',
                  style: const TextStyle(
                    fontSize: 12,
                    color: DdColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 18),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                itemCount: _pinnedMessages.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = _pinnedMessages[index];
                  final message = item.message;
                  return ListTile(
                    key: Key('pinned-manager-message-${message.id}'),
                    leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: DdColors.green.withValues(alpha: 0.12),
                      child: const Icon(
                        Icons.push_pin_rounded,
                        size: 18,
                        color: DdColors.greenPressed,
                      ),
                    ),
                    title: Text(
                      _pinnedMessageSummary(message),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      _formatMessageTime(message.createdAt),
                      style: const TextStyle(
                        fontSize: 11,
                        color: DdColors.textTertiary,
                      ),
                    ),
                    trailing: IconButton(
                      key: Key('pinned-manager-unpin-${message.id}'),
                      tooltip: '取消置顶',
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        await widget.coordinator.unpinMessage(message);
                        await _refreshPinnedMessages();
                      },
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_jumpToMessage(message.id));
                    },
                  );
                },
              ),
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
    List<MediaTransferTask> visualTransfers,
  ) {
    final hasOlder = widget.coordinator.canLoadOlder(conversation.id);
    final offset = hasOlder ? 1 : 0;
    final count =
        offset + messages.length + pending.length + visualTransfers.length;
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
          final message = messages[contentIndex];
          final previousTime = contentIndex == 0
              ? null
              : messages[contentIndex - 1].createdAt;
          return _withDateSeparator(
            message.createdAt,
            previousTime: previousTime,
            child: KeyedSubtree(
              key: _messageAnchorKeys.putIfAbsent(message.id, GlobalKey.new),
              child: RepaintBoundary(child: _messageRow(conversation, message)),
            ),
          );
        }
        final pendingIndex = contentIndex - messages.length;
        if (pendingIndex < pending.length) {
          final pendingMessage = pending[pendingIndex];
          final previousTime = pendingIndex > 0
              ? pending[pendingIndex - 1].createdAt
              : (messages.isEmpty ? null : messages.last.createdAt);
          return _withDateSeparator(
            pendingMessage.createdAt,
            previousTime: previousTime,
            child: RepaintBoundary(child: _pendingRow(pendingMessage)),
          );
        }
        final transferIndex = pendingIndex - pending.length;
        final transfer = visualTransfers[transferIndex];
        final previousTime = transferIndex > 0
            ? visualTransfers[transferIndex - 1].createdAt
            : pending.isNotEmpty
            ? pending.last.createdAt
            : (messages.isEmpty ? null : messages.last.createdAt);
        return _withDateSeparator(
          transfer.createdAt,
          previousTime: previousTime,
          child: RepaintBoundary(child: _pendingMediaTransferRow(transfer)),
        );
      },
    );
  }

  List<MediaTransferTask> _pendingVisualUploadTasks(String conversationId) {
    final tasks = _uploadTransfers
        .tasksForConversation(conversationId)
        .where(
          (task) =>
              _isInlineVisualUploadTask(task) &&
              task.state.phase != MediaTransferPhase.canceled &&
              task.state.phase != MediaTransferPhase.done,
        )
        .toList(growable: false);
    tasks.sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return tasks;
  }

  bool _isInlineVisualUploadTask(MediaTransferTask task) =>
      task.direction == MediaTransferDirection.upload &&
      (task.kind == MediaTransferKind.image ||
          task.kind == MediaTransferKind.video);

  Widget _pendingMediaTransferRow(MediaTransferTask task) {
    final preview = task.visualPreview;
    final width = preview == null || preview.width <= 0 ? 4 : preview.width;
    final height = preview == null || preview.height <= 0 ? 3 : preview.height;
    final size = preview == null
        ? const Size(196, 147)
        : _chatImageDisplaySize(width, height);
    return Padding(
      key: Key('pending-media-transfer-${task.id}'),
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(DdRadii.media),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _pendingMediaPreviewSurface(task),
                    _pendingMediaTransferControl(task),
                  ],
                ),
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
  }

  Widget _pendingMediaPreviewSurface(MediaTransferTask task) {
    final preview = task.visualPreview;
    if (preview == null || preview.posterBytes.isEmpty) {
      return ColoredBox(
        color: const Color(0xFFE2E2E2),
        child: Center(
          child: Icon(
            task.kind == MediaTransferKind.video
                ? Icons.videocam_outlined
                : Icons.image_outlined,
            size: 34,
            color: DdColors.textTertiary,
          ),
        ),
      );
    }
    if (task.kind == MediaTransferKind.video &&
        preview.localPlaybackUri != null) {
      final durationMs = preview.durationMs ?? 0;
      return InlineVideoPreview(
        key: Key('pending-video-preview-${task.id}'),
        playbackId: 'pending-${task.id}',
        posterBytes: preview.posterBytes,
        declaredDuration: Duration(milliseconds: durationMs),
        sourceResolver: () async => preview.localPlaybackUri!,
        onOpenFull: () {},
        scrollListenable: _scrollController,
        autoPlayWhenVisible:
            !kIsWeb &&
            defaultTargetPlatform == TargetPlatform.android &&
            widget.hostVisible,
        openFullOnTap: false,
      );
    }
    return Image.memory(
      preview.posterBytes,
      key: Key('pending-image-preview-${task.id}'),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => const ColoredBox(
        color: Color(0xFFE2E2E2),
        child: Center(
          child: Icon(
            Icons.broken_image_outlined,
            color: DdColors.textTertiary,
          ),
        ),
      ),
    );
  }

  Widget _pendingMediaTransferControl(MediaTransferTask task) {
    final state = task.state;
    final failed = state.phase == MediaTransferPhase.failed;
    final paused = state.phase == MediaTransferPhase.paused;
    final primaryIcon = failed
        ? Icons.refresh_rounded
        : paused
        ? Icons.play_arrow_rounded
        : state.canCancel
        ? Icons.close_rounded
        : Icons.more_horiz_rounded;
    final VoidCallback? primaryAction = failed && task.canRetry
        ? () => _uploadTransfers.retry(task.id)
        : paused
        ? () => _uploadTransfers.resume(task.id)
        : state.canCancel
        ? () => _uploadTransfers.cancel(task.id)
        : null;
    final primaryKey = failed
        ? Key('pending-media-retry-${task.id}')
        : paused
        ? Key('pending-media-resume-${task.id}')
        : Key('pending-media-cancel-${task.id}');

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.08),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (paused || failed) ...[
              Material(
                color: Colors.black.withValues(alpha: 0.58),
                shape: const CircleBorder(),
                child: IconButton(
                  key: Key('pending-media-dismiss-${task.id}'),
                  tooltip: failed ? '关闭' : '取消传输',
                  onPressed: failed
                      ? () => _uploadTransfers.dismiss(task.id)
                      : () => _uploadTransfers.cancel(task.id),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            SizedBox.square(
              dimension: 54,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(3),
                    child: CircularProgressIndicator(
                      key: Key('pending-media-progress-${task.id}'),
                      value: state.progress,
                      strokeWidth: 2.8,
                      backgroundColor: Colors.white30,
                      color: failed ? DdColors.danger : Colors.white,
                    ),
                  ),
                  IconButton(
                    key: primaryKey,
                    tooltip: failed
                        ? '重试'
                        : paused
                        ? '继续'
                        : state.canCancel
                        ? '取消传输'
                        : '正在提交',
                    onPressed: primaryAction,
                    padding: EdgeInsets.zero,
                    icon: Icon(primaryIcon, color: Colors.white, size: 24),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _withDateSeparator(
    DateTime timestamp, {
    required DateTime? previousTime,
    required Widget child,
  }) {
    final currentLocal = timestamp.toLocal();
    final previousLocal = previousTime?.toLocal();
    final show =
        previousLocal == null || !_sameLocalDay(currentLocal, previousLocal);
    if (!show) return child;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [_dateSeparator(currentLocal), child],
    );
  }

  bool _sameLocalDay(DateTime left, DateTime right) =>
      left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;

  Widget _dateSeparator(DateTime local) {
    final label = _dateSeparatorLabel(local);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(DdRadii.pill),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: DdColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _dateSeparatorLabel(DateTime local) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(local.year, local.month, local.day);
    if (date == today) return '今天';
    if (date == today.subtract(const Duration(days: 1))) return '昨天';
    if (date.year == today.year) return '${date.month}月${date.day}日';
    return '${date.year}年${date.month}月${date.day}日';
  }

  Widget _messageRow(ConversationItem conversation, ChatMessage message) {
    if (message.isRecalled) return const SizedBox.shrink();
    if (message.type == 'SYSTEM') {
      return _systemMessageRow(message);
    }
    final mine = message.senderUserId == widget.currentUserId;
    final senderMember = conversation.type == 'GROUP' && !mine
        ? _groupMembers[message.senderUserId]
        : null;
    final bubble = _messageBubble(conversation, message, mine);
    final row = AnimatedContainer(
      key: Key('message-${message.id}'),
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.only(bottom: 14),
      color: _highlightedMessageId == message.id
          ? DdColors.green.withValues(alpha: 0.12)
          : Colors.transparent,
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            _messageSenderAvatar(conversation, message, senderMember),
            const SizedBox(width: 9),
          ],
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (senderMember != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 3),
                    child: Text(
                      senderMember.effectiveName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: DdColors.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
                bubble,
              ],
            ),
          ),
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

    final secondaryTap = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if ((event.buttons & kSecondaryMouseButton) == 0) return;
        unawaited(_showMessageMenuAt(message, mine, event.position));
      },
      child: row,
    );
    final fastVoiceLongPress =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        message.type == 'VOICE';
    if (fastVoiceLongPress) {
      return RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: <Type, GestureRecognizerFactory>{
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(
                  duration: const Duration(milliseconds: 320),
                  allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
                ),
                (recognizer) {
                  recognizer.onLongPress = () =>
                      _showMessageActions(message, mine);
                },
              ),
        },
        child: secondaryTap,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: () => _showMessageActions(message, mine),
      child: secondaryTap,
    );
  }

  Widget _systemMessageRow(ChatMessage message) {
    final text = message.content?.text.trim();
    return AnimatedContainer(
      key: Key('message-${message.id}'),
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 16),
      color: _highlightedMessageId == message.id
          ? DdColors.green.withValues(alpha: 0.12)
          : Colors.transparent,
      alignment: Alignment.center,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x19000000),
          borderRadius: BorderRadius.circular(DdRadii.pill),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            text == null || text.isEmpty ? '系统消息' : text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: DdColors.textSecondary,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }

  Widget _messageBubble(
    ConversationItem conversation,
    ChatMessage message,
    bool mine,
  ) {
    final recalled = message.isRecalled;
    if (recalled) return const SizedBox.shrink();
    final callSummary = _parseCallSummary(message.content?.text);
    final stickerPackShare =
        (message.type == 'TEXT' || message.type == 'STICKER_PACK')
        ? _parseStickerPackShare(message.content?.text)
        : null;
    final stickerVideoVisual =
        message.type == 'STICKER' &&
        _isVideoStickerMime(message.content?.mimeType) &&
        message.content?.isImage == true;
    final imageVisual =
        const {'IMAGE', 'GIF', 'STICKER'}.contains(message.type) &&
        !stickerVideoVisual &&
        message.content?.isImage == true;
    final videoVisual =
        message.type == 'VIDEO' &&
        message.content?.hasMedia == true &&
        message.content?.hasVideoPoster == true &&
        message.content?.durationMs != null;
    final standaloneVisual = imageVisual || stickerVideoVisual || videoVisual;
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
            key: Key('message-bubble-surface-${message.id}'),
            padding: standaloneVisual
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: standaloneVisual
                ? null
                : BoxDecoration(
                    color: mine
                        ? DdColors.ownBubble
                        : Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(DdRadii.messageBubble),
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.replyToMessageId != null && !recalled) ...[
                  _replyReference(message.replyToMessageId!, mine),
                  const SizedBox(height: 6),
                ],
                if (callSummary != null)
                  _callSummaryBubble(callSummary)
                else if (stickerPackShare != null)
                  _stickerPackShareCard(
                    stickerPackShare,
                    previewMessage: message.type == 'STICKER_PACK'
                        ? message
                        : null,
                  )
                else if (stickerVideoVisual)
                  _chatVideoSticker(message)
                else if (imageVisual)
                  _chatImage(message)
                else if (videoVisual)
                  _chatVideo(message)
                else if (voiceContent)
                  _voiceBubble(message, mine)
                else if (fileContent)
                  _fileBubble(message, mine)
                else
                  _textMessageBody(message),
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
              if (message.isEdited) ...[
                const SizedBox(width: 5),
                const Text(
                  '已更新',
                  style: TextStyle(fontSize: 10, color: DdColors.textTertiary),
                ),
              ],
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

  Widget _textMessageBody(ChatMessage message) {
    final text = message.content?.text ?? '[${message.type}]';
    final links = extractHttpUrls(text);
    final firstLink = links.isEmpty ? null : links.first;
    final brightness = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MentionRichText(
          text: text,
          entities: message.content?.entities ?? const <MessageEntity>[],
          style: TextStyle(
            fontSize: 15,
            height: 1.38,
            color: brightness == Brightness.dark
                ? Colors.white
                : DdColors.textPrimary,
          ),
          mentionStyle: TextStyle(
            fontSize: 15,
            height: 1.38,
            fontWeight: FontWeight.w600,
            color: ddMentionColor(brightness),
          ),
          linkStyle: TextStyle(
            fontSize: 15,
            height: 1.38,
            color: ddMentionColor(brightness),
          ),
          onMentionTap: (userId) => unawaited(_openMentionProfile(userId)),
          onLinkTap: (uri) => unawaited(_openExternalLink(uri)),
        ),
        if (firstLink != null)
          MessageLinkPreview(
            key: Key('message-link-preview-${message.id}'),
            url: firstLink,
            loader: _loadLinkPreview,
            onOpen: (uri) => unawaited(_openExternalLink(uri)),
          ),
      ],
    );
  }

  Future<LinkPreviewData> _loadLinkPreview(Uri url) {
    final key = url.toString();
    final cached = _linkPreviewCache[key];
    if (cached != null) return cached;
    if (_linkPreviewCache.length >= 64) {
      _linkPreviewCache.remove(_linkPreviewCache.keys.first);
    }
    final future = widget.coordinator.withAuthorizedToken(
      (token) => _linkPreviewApi.getPreview(
        origin: widget.coordinator.origin,
        accessToken: token,
        url: url,
      ),
    );
    _linkPreviewCache[key] = future;
    return future;
  }

  Future<void> _openExternalLink(Uri uri) async {
    final opened = await openExternalHttpUrl(uri);
    if (opened || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法调用系统浏览器打开这个链接。')));
  }

  ({bool video, String text})? _parseCallSummary(String? raw) {
    final text = raw?.trim() ?? '';
    const audioPrefix = '语音通话 · ';
    const videoPrefix = '视频通话 · ';
    if (text.startsWith(audioPrefix)) {
      final detail = text.substring(audioPrefix.length);
      if (detail.startsWith('通话时长 ') || detail == '对方拒接') {
        return (video: false, text: detail);
      }
    }
    if (text.startsWith(videoPrefix)) {
      final detail = text.substring(videoPrefix.length);
      if (detail.startsWith('通话时长 ') || detail == '对方拒接') {
        return (video: true, text: detail);
      }
    }
    return null;
  }

  ({String setName, String title})? _parseStickerPackShare(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'dd' ||
        uri.host != 'stickers' ||
        uri.pathSegments.length != 2 ||
        uri.pathSegments.first != 'telegram') {
      return null;
    }
    final setName = uri.pathSegments[1].trim();
    if (setName.isEmpty) return null;
    final title = uri.queryParameters['title']?.trim() ?? '';
    return (setName: setName, title: title.isEmpty ? setName : title);
  }

  Widget _stickerPackShareCard(
    ({String setName, String title}) share, {
    ChatMessage? previewMessage,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('telegram-sticker-pack-card-${share.setName}'),
        borderRadius: BorderRadius.circular(DdRadii.control),
        onTap: () => unawaited(_importSharedStickerPack(share)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(
              children: [
                _stickerPackSharePreview(previewMessage),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        share.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Telegram 表情包 · 点击添加',
                        style: TextStyle(
                          fontSize: 11,
                          color: DdColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: DdColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stickerPackSharePreview(ChatMessage? message) {
    final content = message?.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    if (message == null ||
        content == null ||
        mediaId.isEmpty ||
        (content.width ?? 0) <= 0 ||
        (content.height ?? 0) <= 0) {
      return _stickerPackShareFallback();
    }

    const previewSize = 48.0;
    final mimeType = content.mimeType?.trim() ?? '';
    if (_isVideoStickerMime(mimeType)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          key: Key('telegram-sticker-pack-preview-${message.id}'),
          width: previewSize,
          height: previewSize,
          child: LoopingVideoSticker(
            playbackId: 'sticker-pack-preview-${message.id}',
            sourceResolver: () => _resolveCachedStickerVideo(
              mediaId,
              expectedSizeBytes: content.sizeBytes ?? 0,
            ),
            scrollListenable: _scrollController,
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        key: Key('telegram-sticker-pack-preview-${message.id}'),
        width: previewSize,
        height: previewSize,
        child: FutureBuilder<Uint8List>(
          future: _mediaBytesFor(mediaId, kind: MediaCacheKind.stickerGif),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null || bytes.isEmpty) {
              if (snapshot.hasError) return _stickerPackShareFallback();
              return _imageLoadingSurface();
            }
            if (isTelegramTgsMime(mimeType)) {
              return TelegramTgsSticker(bytes: bytes);
            }
            return Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => _stickerPackShareFallback(),
            );
          },
        ),
      ),
    );
  }

  Widget _stickerPackShareFallback() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: DdColors.green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.auto_awesome_rounded,
        color: DdColors.greenPressed,
        size: 24,
      ),
    );
  }

  Future<void> _importSharedStickerPack(
    ({String setName, String title}) share,
  ) async {
    final ownsGateway = widget.stickerGateway == null;
    final gateway = widget.stickerGateway ?? StickerApiClient();
    try {
      final pack = await gateway.importTelegramPack(
        origin: widget.coordinator.origin,
        accessToken: widget.coordinator.accessToken,
        setName: share.setName,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已添加表情包「${pack.title}」')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('表情包添加失败：$error')));
    } finally {
      if (ownsGateway) gateway.close();
    }
  }

  Widget _callSummaryBubble(({bool video, String text}) summary) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('call-summary-${summary.video ? 'video' : 'audio'}'),
        borderRadius: BorderRadius.circular(DdRadii.control),
        onTap: () =>
            _startCall(summary.video ? CallKind.video : CallKind.audio),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                summary.video ? Icons.videocam_outlined : Icons.call_outlined,
                size: 20,
                color: DdColors.greenPressed,
              ),
              const SizedBox(width: 8),
              Text(
                summary.text,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: DdColors.textTertiary,
              ),
            ],
          ),
        ),
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
    if (_mediaPreferences.files &&
        !_autoFileCacheStarted.contains(message.id)) {
      _autoFileCacheStarted.add(message.id);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ensureAutoFileCached(message));
      });
    }
    final name = (content.fileName ?? '').trim().isEmpty
        ? '文件'
        : content.fileName!.trim();
    return AnimatedBuilder(
      animation: _uploadTransfers,
      builder: (context, _) {
        final task = _uploadTransfers.task(_fileDownloadTaskId(message.id));
        final transferring = task?.isActive == true;
        final paused = task?.isPaused == true;
        final progress = task?.state.progress;
        return InkWell(
          borderRadius: BorderRadius.circular(DdRadii.control),
          onTap: transferring
              ? () => _uploadTransfers.pause(task!.id)
              : paused
              ? () => _uploadTransfers.resume(task!.id)
              : () => unawaited(_showFileActions(message)),
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
                      if (transferring || paused)
                        Text(
                          paused
                              ? '已暂停 · 点击继续'
                              : progress == null
                              ? '准备下载… · 点击暂停'
                              : '下载 ${(progress * 100).round()}% · 点击暂停',
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
      },
    );
  }

  Future<void> _showFileActions(ChatMessage message) async {
    final content = message.content;
    if (content?.mediaId?.trim().isEmpty != false) return;
    final action = await showDdActionSheet<String>(
      context,
      items: const [
        DdActionSheetItem<String>(
          value: 'open',
          icon: Icons.open_in_new_rounded,
          label: '打开文件',
          subtitle: '使用系统中支持此格式的应用打开',
        ),
        DdActionSheetItem<String>(
          value: 'save',
          icon: Icons.download_rounded,
          label: '保存文件',
          subtitle: '保存到系统文件位置',
        ),
        DdActionSheetItem<String>(
          value: 'share',
          icon: Icons.ios_share_rounded,
          label: '系统分享',
          subtitle: '交给系统分享面板发送到其他应用',
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        await _openMediaFile(message);
        break;
      case 'save':
        await _saveMediaFile(message);
        break;
      case 'share':
        await _shareMediaFile(message);
        break;
    }
  }

  Future<void> _openMediaFile(ChatMessage message) async {
    final content = message.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    if (content == null || mediaId.isEmpty) return;
    final fileName = (content.fileName ?? '').trim().isEmpty
        ? 'DD-file.bin'
        : content.fileName!.trim();
    final mimeType = (content.mimeType ?? '').trim().isEmpty
        ? 'application/octet-stream'
        : content.mimeType!.trim();
    try {
      final result = await _withFreshFileGrant(
        mediaId,
        (url) => _remoteMediaActions.openFile(
          url: url,
          mimeType: mimeType,
          suggestedName: fileName,
          transferKey: mediaId,
          expectedBytes: content.sizeBytes,
        ),
      );
      if (mounted) _showImageError(result);
    } on PlatformException catch (error) {
      if (mounted) {
        _showImageError(error.message ?? '文件打开失败，请检查是否安装了支持此格式的应用。');
      }
    } catch (_) {
      if (mounted) _showImageError('文件打开失败，请检查是否安装了支持此格式的应用。');
    }
  }

  Future<void> _saveMediaFile(ChatMessage message) async {
    final content = message.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    if (content == null || mediaId.isEmpty) return;
    final taskId = _fileDownloadTaskId(message.id);
    final existing = _uploadTransfers.task(taskId);
    if (existing?.isActive == true) return;
    if (existing?.isPaused == true) {
      _uploadTransfers.resume(taskId);
      return;
    }
    if (existing?.canRetry == true) {
      _uploadTransfers.retry(taskId);
      return;
    }
    if (existing?.state.phase == MediaTransferPhase.done) {
      await existing?.saveAction?.call();
      return;
    }
    final fileName = (content.fileName ?? '').trim().isEmpty
        ? 'download.bin'
        : content.fileName!.trim();
    _uploadTransfers.enqueue(
      id: taskId,
      kind: MediaTransferKind.file,
      direction: MediaTransferDirection.download,
      label: fileName,
      conversationId: widget.conversation.id,
      openAction: () => _openMediaFile(message),
      saveAction: () async {
        await _performSaveMediaFile(message);
      },
      shareAction: () => _shareMediaFile(message),
      operation: (task) async {
        final cancellation = MediaDownloadCancellation();
        task.setAbortHandler(() {
          cancellation.preservePartialOnCancel = task.pauseRequested;
          cancellation.cancel();
        });
        task.update(
          MediaTransferState(
            phase: MediaTransferPhase.uploading,
            totalBytes: content.sizeBytes,
          ),
        );
        final result = await _performSaveMediaFile(
          message,
          cancellation: cancellation,
          onProgress: (received, total) {
            task.update(
              MediaTransferState(
                phase: MediaTransferPhase.uploading,
                transferredBytes: received,
                totalBytes: total ?? content.sizeBytes,
              ),
            );
          },
        );
        if (cancellation.isCancelled) throw const MediaDownloadCancelled();
        if (mounted) _showImageError(result);
      },
    );
  }

  Future<String> _performSaveMediaFile(
    ChatMessage message, {
    MediaDownloadCancellation? cancellation,
    void Function(int received, int? total)? onProgress,
  }) async {
    final content = message.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    if (content == null || mediaId.isEmpty) {
      throw const FormatException('文件媒体信息无效。');
    }
    final fileName = (content.fileName ?? '').trim().isEmpty
        ? 'download.bin'
        : content.fileName!.trim();
    final mimeType = (content.mimeType ?? '').trim().isEmpty
        ? 'application/octet-stream'
        : content.mimeType!.trim();
    return _withFreshFileGrant(
      mediaId,
      (url) => _remoteMediaActions.saveFile(
        url: url,
        mimeType: mimeType,
        suggestedName: fileName,
        transferKey: mediaId,
        expectedBytes: content.sizeBytes,
        cancellation: cancellation,
        onProgress: onProgress,
      ),
    );
  }

  String _fileDownloadTaskId(String messageId) => 'download-file-$messageId';

  String _videoDownloadTaskId(String messageId) => 'download-video-$messageId';

  Future<void> _shareMediaFile(ChatMessage message) async {
    final content = message.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    if (content == null || mediaId.isEmpty) return;
    final fileName = (content.fileName ?? '').trim().isEmpty
        ? 'DD-file.bin'
        : content.fileName!.trim();
    final mimeType = (content.mimeType ?? '').trim().isEmpty
        ? 'application/octet-stream'
        : content.mimeType!.trim();
    try {
      final result = await _withFreshFileGrant(
        mediaId,
        (url) => _remoteMediaActions.shareFile(
          url: url,
          mimeType: mimeType,
          suggestedName: fileName,
          transferKey: mediaId,
          expectedBytes: content.sizeBytes,
        ),
      );
      if (mounted) _showImageError(result);
    } on PlatformException catch (error) {
      if (mounted) {
        _showImageError(error.message ?? '文件分享失败，请稍后重试。');
      }
    } catch (_) {
      if (mounted) _showImageError('文件分享失败，请稍后重试。');
    }
  }

  Future<T> _withFreshFileGrant<T>(
    String mediaId,
    Future<T> Function(Uri url) action,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final grant = await _downloadGrantFor(mediaId);
        return await action(grant.url);
      } catch (error) {
        lastError = error;
        if (attempt == 0) {
          _mediaDownloadGrants.clear(mediaId);
          continue;
        }
      }
    }
    throw lastError ?? StateError('文件操作失败。');
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
        _playingVoiceMessageId == message.id && _voicePlayer.isPlaying;
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
        borderRadius: BorderRadius.circular(DdRadii.control),
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
                borderRadius: BorderRadius.circular(DdRadii.pill),
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
        if (_voicePlayer.isPlaying) {
          await _voicePlayer.pause();
        } else {
          await _voicePlayer.resume();
        }
        return;
      }
      final bytes = await _mediaBytesFor(mediaId, kind: MediaCacheKind.voice);
      await _voicePlayer.stop();
      if (mounted) {
        setState(() {
          _playingVoiceMessageId = message.id;
          _voicePosition = Duration.zero;
          _voiceDuration = Duration.zero;
        });
      }
      await widget.coordinator.markVoiceHeard(message.id);
      await _voicePlayer.play(
        bytes: bytes,
        namespace: widget.currentUserId,
        mediaId: mediaId,
        mimeType: message.content?.mimeType,
        rate: _voicePlaybackRate,
      );
    } catch (error, stackTrace) {
      unawaited(
        ClientLog.error(
          'Voice playback failed: message=${message.id} media=$mediaId mime=${message.content?.mimeType ?? ''}',
          error: error,
          stackTrace: stackTrace,
        ),
      );
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
      await _voicePlayer.setRate(next);
    }
  }

  Widget _chatImage(ChatMessage message) {
    final content = message.content!;
    final mediaId = content.mediaId!;
    final sticker = message.type == 'STICKER';
    final size = sticker
        ? _chatStickerDisplaySize(content.width!, content.height!)
        : _chatImageDisplaySize(content.width!, content.height!);
    final kind = message.type == 'IMAGE'
        ? MediaCacheKind.image
        : MediaCacheKind.stickerGif;
    final autoLoad = message.type == 'IMAGE'
        ? _mediaPreferences.images
        : _mediaPreferences.gifAndStickers;
    final allowed = autoLoad || _manualMediaLoads.contains(mediaId);
    return ClipRRect(
      borderRadius: sticker
          ? BorderRadius.zero
          : BorderRadius.circular(DdRadii.media),
      child: SizedBox(
        key: Key('chat-visual-frame-${message.id}'),
        width: size.width,
        height: size.height,
        child: !allowed
            ? _manualVisualDownloadSurface(
                mediaId,
                label: message.type == 'IMAGE' ? '点击下载图片' : '点击下载表情',
              )
            : FutureBuilder<Uint8List>(
                future: _mediaBytesFor(mediaId, kind: kind),
                builder: (context, snapshot) {
                  if (snapshot.hasData) {
                    final bytes = snapshot.data!;
                    if (sticker && isTelegramTgsMime(content.mimeType)) {
                      return TelegramTgsSticker(
                        key: Key('chat-tgs-sticker-${message.id}'),
                        bytes: bytes,
                      );
                    }
                    return GestureDetector(
                      key: Key('chat-image-${message.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _openImageViewer(message, bytes),
                      child: Image.memory(
                        bytes,
                        fit: sticker ? BoxFit.contain : BoxFit.cover,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, _, _) => _imageLoadFailure(mediaId),
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

  Widget _chatVideoSticker(ChatMessage message) {
    final content = message.content!;
    final mediaId = content.mediaId!;
    final size = _chatStickerDisplaySize(content.width!, content.height!);
    final autoLoad =
        _mediaPreferences.gifAndStickers || _manualMediaLoads.contains(mediaId);
    if (!autoLoad) {
      return SizedBox(
        width: size.width,
        height: size.height,
        child: _manualVisualDownloadSurface(mediaId, label: '点击播放表情'),
      );
    }
    return SizedBox(
      key: Key('chat-video-sticker-frame-${message.id}'),
      width: size.width,
      height: size.height,
      child: LoopingVideoSticker(
        key: Key('chat-video-sticker-${message.id}'),
        playbackId: 'sticker-${message.id}',
        sourceResolver: () => _resolveCachedStickerVideo(
          mediaId,
          expectedSizeBytes: content.sizeBytes ?? 0,
        ),
        scrollListenable: _scrollController,
      ),
    );
  }

  Widget _chatVideo(ChatMessage message) {
    final content = message.content!;
    final posterMediaId = content.posterMediaId!;
    final size = _chatImageDisplaySize(content.width!, content.height!);
    final duration = Duration(milliseconds: content.durationMs!);
    if (_mediaPreferences.videos &&
        !_autoVideoCacheStarted.contains(message.id)) {
      _autoVideoCacheStarted.add(message.id);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ensureAutoVideoCached(message));
      });
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(DdRadii.media),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: FutureBuilder<Uint8List>(
          future: _mediaBytesFor(posterMediaId, kind: MediaCacheKind.image),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              if (snapshot.hasError) return _imageLoadFailure(posterMediaId);
              return _imageLoadingSurface();
            }
            return InlineVideoPreview(
              key: Key('chat-video-${message.id}'),
              playbackId: message.id,
              posterBytes: snapshot.data!,
              declaredDuration: duration,
              sourceResolver: () => _resolveVideoPlaybackSource(message),
              onOpenFull: () => unawaited(_openVideoViewer(message)),
              scrollListenable: _scrollController,
            );
          },
        ),
      ),
    );
  }

  Future<void> _openImageViewer(ChatMessage message, Uint8List bytes) async {
    final content = message.content!;
    final mimeType = (content.mimeType ?? '').trim().isEmpty
        ? (message.type == 'GIF' ? 'image/gif' : 'image/jpeg')
        : content.mimeType!.trim();
    final fileName = (content.fileName ?? '').trim().isEmpty
        ? 'DD-${message.type.toLowerCase()}-${message.id}.${_imageExtension(mimeType)}'
        : content.fileName!.trim();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ImageViewerPage(
          bytes: bytes,
          mimeType: mimeType,
          suggestedName: fileName,
        ),
      ),
    );
  }

  Future<Uri> _resolveVideoPlaybackSource(ChatMessage message) async {
    final content = message.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    if (content == null || mediaId.isEmpty) {
      throw const FormatException('视频媒体引用无效。');
    }
    final cached = await _videoFileCache.cachedUri(
      mediaId,
      expectedSizeBytes: content.sizeBytes ?? 0,
    );
    if (cached != null) return cached;
    return (await _downloadGrantFor(mediaId)).url;
  }

  Future<void> _openVideoViewer(
    ChatMessage message, {
    Duration initialPosition = Duration.zero,
    bool autoPlay = true,
  }) async {
    final content = message.content;
    final mediaId = content?.mediaId;
    if (content == null || mediaId == null || mediaId.isEmpty) return;
    try {
      final expectedSizeBytes = content.sizeBytes ?? 0;
      final source = await _resolveVideoPlaybackSource(message);
      final cached = source.scheme == 'file' ? source : null;
      if (!mounted) return;
      final fileName = (content.fileName ?? '').trim().isEmpty
          ? 'DD-video-${message.id}.mp4'
          : content.fileName!.trim();
      final mimeType = (content.mimeType ?? '').trim().isEmpty
          ? 'video/mp4'
          : content.mimeType!.trim();
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => VideoViewerPage(
            url: source,
            fileName: fileName,
            mimeType: mimeType,
            remoteUrlResolver: () =>
                _downloadGrantFor(mediaId).then((grant) => grant.url),
            retryUrlResolver: () async {
              _mediaDownloadGrants.clear(mediaId);
              return (await _downloadGrantFor(mediaId)).url;
            },
            cacheInBackground: cached != null
                ? null
                : (onProgress) => _cacheVideoInBackground(
                    mediaId,
                    expectedSizeBytes: expectedSizeBytes,
                    onProgress: onProgress,
                  ),
            initialPosition: initialPosition,
            autoPlay: autoPlay,
            onPictureInPicture:
                !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
                ? (position, playing) =>
                      _startDesktopVideoPip(message, position, playing)
                : null,
          ),
        ),
      );
    } catch (_) {
      if (mounted) _showImageError('视频加载失败，请稍后重试。');
    }
  }

  Future<void> _startDesktopVideoPip(
    ChatMessage message,
    Duration position,
    bool playing,
  ) async {
    final content = message.content;
    final title = (content?.fileName ?? '').trim().isEmpty
        ? 'DD 视频'
        : content!.fileName!.trim();
    DesktopVideoPipController.shared.open(
      DesktopVideoPipRequest(
        id: message.id,
        title: title,
        sourceResolver: () => _resolveVideoPlaybackSource(message),
        initialPosition: position,
        initialPlaying: playing,
        onRestore: (restoredPosition, restoredPlaying) => _openVideoViewer(
          message,
          initialPosition: restoredPosition,
          autoPlay: restoredPlaying,
        ),
      ),
    );
    if (mounted) await Navigator.of(context).maybePop();
  }

  Future<void> _ensureAutoVideoCached(ChatMessage message) async {
    if (!_mediaPreferences.videos) return;
    final content = message.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    if (content == null || mediaId.isEmpty) return;
    final expectedSizeBytes = content.sizeBytes ?? 0;
    if (await _videoFileCache.cachedUri(
          mediaId,
          expectedSizeBytes: expectedSizeBytes,
        ) !=
        null) {
      return;
    }
    final taskId = _videoDownloadTaskId(message.id);
    if (_uploadTransfers.task(taskId) != null) return;
    final fileName = (content.fileName ?? '').trim().isEmpty
        ? 'DD-video-${message.id}.mp4'
        : content.fileName!.trim();
    _uploadTransfers.enqueue(
      id: taskId,
      kind: MediaTransferKind.video,
      direction: MediaTransferDirection.download,
      label: fileName,
      conversationId: widget.conversation.id,
      operation: (task) async {
        final cancellation = MediaDownloadCancellation();
        task.setAbortHandler(() {
          cancellation.preservePartialOnCancel = task.pauseRequested;
          cancellation.cancel();
        });
        task.update(
          MediaTransferState(
            phase: MediaTransferPhase.uploading,
            totalBytes: expectedSizeBytes > 0 ? expectedSizeBytes : null,
          ),
        );
        try {
          await _cacheVideoInBackground(
            mediaId,
            expectedSizeBytes: expectedSizeBytes,
            cancellation: cancellation,
            onProgress: (received, total) {
              task.update(
                MediaTransferState(
                  phase: MediaTransferPhase.uploading,
                  transferredBytes: received,
                  totalBytes:
                      total ??
                      (expectedSizeBytes > 0 ? expectedSizeBytes : null),
                ),
              );
            },
          );
          if (cancellation.isCancelled) throw const MediaDownloadCancelled();
        } catch (error, stackTrace) {
          if (error is! MediaDownloadCancelled) {
            unawaited(
              ClientLog.error(
                'Auto video cache failed: media=$mediaId',
                error: error,
                stackTrace: stackTrace,
              ),
            );
          }
          rethrow;
        }
      },
    );
  }

  Future<void> _ensureAutoFileCached(ChatMessage message) async {
    if (!_mediaPreferences.files) return;
    final content = message.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    if (content == null || mediaId.isEmpty) return;
    final taskId = _fileDownloadTaskId(message.id);
    if (_uploadTransfers.task(taskId) != null) return;
    final fileName = (content.fileName ?? '').trim().isEmpty
        ? 'DD-file.bin'
        : content.fileName!.trim();
    _uploadTransfers.enqueue(
      id: taskId,
      kind: MediaTransferKind.file,
      direction: MediaTransferDirection.download,
      label: fileName,
      conversationId: widget.conversation.id,
      openAction: () => _openMediaFile(message),
      saveAction: () async {
        await _performSaveMediaFile(message);
      },
      shareAction: () => _shareMediaFile(message),
      operation: (task) async {
        final cancellation = MediaDownloadCancellation();
        task.setAbortHandler(() {
          cancellation.preservePartialOnCancel = task.pauseRequested;
          cancellation.cancel();
        });
        task.update(
          MediaTransferState(
            phase: MediaTransferPhase.uploading,
            totalBytes: content.sizeBytes,
          ),
        );
        try {
          await _withFreshFileGrant(
            mediaId,
            (url) => _remoteMediaActions.cacheFile(
              url: url,
              suggestedName: fileName,
              transferKey: mediaId,
              expectedBytes: content.sizeBytes,
              cancellation: cancellation,
              onProgress: (received, total) {
                task.update(
                  MediaTransferState(
                    phase: MediaTransferPhase.uploading,
                    transferredBytes: received,
                    totalBytes: total ?? content.sizeBytes,
                  ),
                );
              },
            ),
          );
          if (cancellation.isCancelled) throw const MediaDownloadCancelled();
        } catch (error, stackTrace) {
          if (error is! MediaDownloadCancelled) {
            unawaited(
              ClientLog.error(
                'Auto file cache failed: media=$mediaId',
                error: error,
                stackTrace: stackTrace,
              ),
            );
          }
          rethrow;
        }
      },
    );
  }

  Future<Uri> _resolveCachedStickerVideo(
    String mediaId, {
    required int expectedSizeBytes,
  }) {
    final id = mediaId.trim();
    if (id.isEmpty) {
      return Future<Uri>.error(const FormatException('视频表情媒体引用无效。'));
    }
    final current = _stickerVideoSourceInflight[id];
    if (current != null) return current;

    final request =
        _resolveCachedStickerVideoOnce(
          id,
          expectedSizeBytes: expectedSizeBytes,
        ).whenComplete(() {
          _stickerVideoSourceInflight.remove(id);
        });
    _stickerVideoSourceInflight[id] = request;
    return request;
  }

  Future<Uri> _resolveCachedStickerVideoOnce(
    String mediaId, {
    required int expectedSizeBytes,
  }) async {
    final cached = await _videoFileCache.cachedUri(
      mediaId,
      expectedSizeBytes: expectedSizeBytes,
    );
    if (cached != null) return cached;

    await _cacheVideoInBackground(
      mediaId,
      expectedSizeBytes: expectedSizeBytes,
      onProgress: (_, _) {},
    );
    final stored = await _videoFileCache.cachedUri(
      mediaId,
      expectedSizeBytes: expectedSizeBytes,
    );
    if (stored != null) return stored;

    // Web/no-file-cache fallback: still allow playback from a fresh signed URL.
    return (await _downloadGrantFor(mediaId)).url;
  }

  Future<void> _cacheVideoInBackground(
    String mediaId, {
    required int expectedSizeBytes,
    MediaDownloadCancellation? cancellation,
    required void Function(int received, int? total) onProgress,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final grant = await _downloadGrantFor(mediaId);
      try {
        await _videoFileCache.cacheFromUrl(
          mediaId: mediaId,
          url: grant.url,
          expectedSizeBytes: expectedSizeBytes,
          cancellation: cancellation,
          onProgress: onProgress,
        );
        return;
      } on VideoFileCacheHttpException catch (error) {
        if (attempt == 0 && const {401, 403, 410}.contains(error.statusCode)) {
          _mediaDownloadGrants.clear(mediaId);
          continue;
        }
        rethrow;
      }
    }
  }

  String _imageExtension(String mimeType) => switch (mimeType.toLowerCase()) {
    'image/png' => 'png',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    _ => 'jpg',
  };

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

  bool _isVideoStickerMime(String? mimeType) {
    final normalized = (mimeType ?? '').split(';').first.trim().toLowerCase();
    return normalized == 'video/mp4' || normalized == 'video/webm';
  }

  Size _chatStickerDisplaySize(int width, int height) {
    final maxEdge = widget.embedded ? 220.0 : 176.0;
    final ratio = width / height;
    if (ratio >= 1) {
      return Size(maxEdge, maxEdge / ratio);
    }
    return Size(maxEdge * ratio, maxEdge);
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
        _mediaDownloadGrants.clear(mediaId);
        unawaited(_mediaCache.evict(mediaId));
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

  Widget _manualVisualDownloadSurface(
    String mediaId, {
    required String label,
  }) => Material(
    color: const Color(0xFFE9E9E9),
    child: InkWell(
      key: Key('manual-media-$mediaId'),
      onTap: () => setState(() => _manualMediaLoads.add(mediaId)),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download_rounded, color: DdColors.textSecondary),
            const SizedBox(height: 5),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    ),
  );

  Future<Uint8List> _mediaBytesFor(
    String mediaId, {
    MediaCacheKind kind = MediaCacheKind.image,
  }) => _mediaCache.resolve(
    mediaId,
    kind: kind,
    loader: () => downloadMediaWithGrantRefresh(
      mediaId: mediaId,
      grants: _mediaDownloadGrants,
      grantLoader: () => widget.coordinator.withAuthorizedToken(
        (token) => _mediaApi.createDownloadUrl(
          origin: widget.coordinator.origin,
          accessToken: token,
          mediaId: mediaId,
        ),
      ),
      downloader: (url) => _mediaApi.downloadMedia(url: url),
    ),
  );

  Future<MediaDownloadGrant> _downloadGrantFor(String mediaId) =>
      _mediaDownloadGrants.resolve(
        mediaId,
        loader: () => widget.coordinator.withAuthorizedToken(
          (token) => _mediaApi.createDownloadUrl(
            origin: widget.coordinator.origin,
            accessToken: token,
            mediaId: mediaId,
          ),
        ),
      );

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
                      borderRadius: BorderRadius.circular(
                        DdRadii.messageBubble,
                      ),
                    ),
                    child:
                        item.isImage ||
                            item.isGif ||
                            item.isSticker ||
                            item.isVoice ||
                            item.isFile ||
                            item.isVideo
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
                                        : item.isVideo
                                        ? Icons.videocam_outlined
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
    if (item.isVideo) return '视频';
    return '图片';
  }

  Widget _messageSenderAvatar(
    ConversationItem conversation,
    ChatMessage message,
    GroupMemberItem? member,
  ) {
    if (conversation.type != 'GROUP') return _peerAvatar(conversation);
    final name = member?.effectiveName ?? '群成员';
    final avatar = _avatar(message.senderUserId, name);
    if (member == null || message.senderUserId.isEmpty) return avatar;
    return Tooltip(
      message: '查看 $name 的资料',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_openGroupMemberProfile(member)),
        child: avatar,
      ),
    );
  }

  Future<void> _openGroupMemberProfile(GroupMemberItem member) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PeerProfilePage(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          userId: member.user.id,
          handle: member.user.handle,
          displayName: member.user.displayName,
          onOpenMoments: () =>
              _openPeerMoments(member.user.id, member.user.displayName),
          onOpenMomentPrivacy: () =>
              _openPeerMomentPrivacy(member.user.id, member.user.displayName),
          onMessage: widget.onOpenDirectChat == null
              ? null
              : () => widget.onOpenDirectChat!(member.user.id),
          onAudioCall: widget.onStartCall == null
              ? null
              : () => widget.onStartCall!(
                  member.user.id,
                  member.user.displayName,
                  CallKind.audio,
                ),
          onVideoCall: widget.onStartCall == null
              ? null
              : () => widget.onStartCall!(
                  member.user.id,
                  member.user.displayName,
                  CallKind.video,
                ),
        ),
      ),
    );
  }

  Widget _peerAvatar(ConversationItem conversation, {double size = 38}) {
    if (conversation.type == 'GROUP') {
      final name = conversation.group?.name ?? '群聊';
      final letter = name.trim().isEmpty ? '群' : name.trim().characters.first;
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF5D8FB8),
          borderRadius: BorderRadius.circular(size * 0.28),
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
    final peer = conversation.peer;
    final name = peer?.displayName ?? '对方';
    final avatar = _avatar(peer?.id ?? '', name, size: size);
    if (widget.savedMessagesMode ||
        peer == null ||
        peer.id.isEmpty ||
        peer.handle.isEmpty) {
      return avatar;
    }
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
          shape: BoxShape.circle,
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

  Widget _restrictedComposer(ConversationItem conversation) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: InkWell(
          key: const Key('restricted-blocked-conversation'),
          onTap: () => unawaited(_openPeerProfile(conversation)),
          child: Container(
            constraints: const BoxConstraints(minHeight: 58),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: DdColors.divider, width: 0.5),
              ),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.block_rounded,
                  size: 17,
                  color: DdColors.textSecondary,
                ),
                SizedBox(width: 7),
                Flexible(
                  child: Text(
                    '当前关系已被拉黑，无法发送消息。点击查看资料',
                    style: TextStyle(
                      fontSize: 13,
                      color: DdColors.textSecondary,
                    ),
                  ),
                ),
                SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: DdColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _updateMentionTrigger() {
    _mentionController.update(_composer.value);
  }

  void _syncMentionOverlay() {
    if (!mounted) return;
    if (!_mentionController.visible) {
      _removeMentionOverlay();
      return;
    }
    final existing = _mentionOverlayEntry;
    if (existing != null) {
      existing.markNeedsBuild();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_mentionController.visible ||
          _mentionOverlayEntry != null) {
        return;
      }
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null || _mentionAnchorKey.currentContext == null) return;
      final entry = OverlayEntry(builder: _buildMentionOverlayEntry);
      _mentionOverlayEntry = entry;
      overlay.insert(entry);
    });
  }

  Widget _buildMentionOverlayEntry(BuildContext overlayContext) {
    final renderObject = _mentionAnchorKey.currentContext?.findRenderObject();
    final targetWidth = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.size.width
        : MediaQuery.sizeOf(context).width;
    return Positioned(
      left: 0,
      top: 0,
      width: targetWidth,
      child: CompositedTransformFollower(
        link: _mentionLayerLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        child: MentionSuggestionOverlay(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          suggestions: _mentionController.suggestions,
          selectedIndex: _mentionController.selectedIndex,
          loading: _mentionController.loading,
          width: targetWidth,
          onSelect: _acceptMentionAt,
        ),
      ),
    );
  }

  void _removeMentionOverlay() {
    final entry = _mentionOverlayEntry;
    if (entry == null) return;
    _mentionOverlayEntry = null;
    entry.remove();
    entry.dispose();
  }

  bool _acceptSelectedMention() {
    final suggestion = _mentionController.selectedSuggestion;
    final trigger = _mentionController.trigger;
    if (suggestion == null || trigger == null || !_mentionController.visible) {
      return false;
    }
    _applyMention(trigger, suggestion);
    return true;
  }

  void _acceptMentionAt(int index) {
    _mentionController.selectIndex(index);
    final suggestion = _mentionController.selectedSuggestion;
    final trigger = _mentionController.trigger;
    if (suggestion == null || trigger == null) return;
    _applyMention(trigger, suggestion);
  }

  void _applyMention(
    MentionTrigger trigger,
    ContactMentionSuggestion suggestion,
  ) {
    final updated = applyMentionSuggestion(
      value: _composer.value,
      trigger: trigger,
      suggestion: suggestion,
    );
    _mentionController.close();
    _composer.value = updated;
    _composerFocusNode.requestFocus();
  }

  void _moveMentionSelection(int delta) {
    if (!_mentionController.visible) return;
    _mentionController.moveSelection(delta);
  }

  void _closeMentionSuggestions() {
    if (_mentionController.visible) _mentionController.close();
  }

  Widget _composerBar(ConversationItem conversation) {
    if (!conversation.canWrite) {
      return _restrictedComposer(conversation);
    }
    final replyingTo = _replyingTo;
    final editingMessage = _editingMessage;
    final surface = Theme.of(context).colorScheme.surface;
    return CompositedTransformTarget(
      key: _mentionAnchorKey,
      link: _mentionLayerLink,
      child: Material(
        color: surface,
        child: Container(
          key: const Key('chat-composer-footer'),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: DdColors.divider, width: 0.5),
            ),
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
              if (editingMessage != null) _editPreview(editingMessage),
              if (replyingTo != null && editingMessage == null)
                _replyPreview(replyingTo),
              if (widget.conversation.type == 'GROUP' &&
                  _activeGroupCall != null)
                _groupCallBanner(),
              AnimatedBuilder(
                animation: _uploadTransfers,
                builder: (context, _) => _uploadTransferBanners(),
              ),
              if (_voiceRecording) _voiceRecordingBanner(),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _voiceControlButton(),
                  Expanded(
                    child: _mobileHoldToTalk && _voiceMode
                        ? _holdToTalkField()
                        : _composerField(),
                  ),
                  if (!_androidVoiceInputActive)
                    IconButton(
                      key: const Key('chat-emoji'),
                      tooltip: '表情',
                      onPressed: _showEmojiPicker,
                      icon: const Icon(
                        Icons.sentiment_satisfied_alt_rounded,
                        size: 25,
                      ),
                    ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _composer,
                    builder: (context, value, _) {
                      final hasText =
                          !_voiceMode && value.text.trim().isNotEmpty;
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
                              child: Text(
                                editingMessage == null ? '发送' : '更新',
                                style: const TextStyle(fontSize: 13),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _uploadTransferBanners() {
    final tasks = _uploadTransfers
        .tasksForConversation(widget.conversation.id)
        .where((task) => !_isInlineVisualUploadTask(task))
        .toList(growable: false);
    if (tasks.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (final task in tasks) _uploadTransferBanner(task)],
    );
  }

  Widget _uploadTransferBanner(MediaTransferTask task) {
    final state = task.state;
    final progress = state.progress;
    final detail = state.phase == MediaTransferPhase.failed
        ? (state.errorMessage ?? '传输失败，可重试')
        : progress == null
        ? _transferPhaseLabel(state.phase, task.direction)
        : '${(progress * 100).clamp(0, 100).round()}% · '
              '${_formatTransferBytes(state.transferredBytes)} / '
              '${_formatTransferBytes(state.totalBytes ?? 0)}';
    final icon = switch (task.kind) {
      MediaTransferKind.image => Icons.image_outlined,
      MediaTransferKind.video => Icons.videocam_outlined,
      MediaTransferKind.file =>
        task.direction == MediaTransferDirection.download
            ? Icons.download_rounded
            : Icons.upload_file_rounded,
      MediaTransferKind.voice => Icons.mic_none_rounded,
      MediaTransferKind.gif => Icons.gif_box_outlined,
      MediaTransferKind.sticker => Icons.emoji_emotions_outlined,
    };
    return Container(
      key: Key('upload-transfer-${task.id}'),
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(DdRadii.control),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: DdColors.greenPressed),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: state.phase == MediaTransferPhase.failed
                        ? DdColors.danger
                        : DdColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (state.phase == MediaTransferPhase.failed && task.canRetry)
            IconButton(
              key: Key('retry-upload-${task.id}'),
              tooltip: '重试',
              onPressed: () => _uploadTransfers.retry(task.id),
              icon: const Icon(Icons.refresh_rounded, size: 20),
            )
          else if (state.phase == MediaTransferPhase.paused)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('cancel-upload-${task.id}'),
                  tooltip: '取消传输',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  onPressed: () => _uploadTransfers.cancel(task.id),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: DdColors.danger,
                  ),
                ),
                IconButton(
                  key: Key('resume-upload-${task.id}'),
                  tooltip: '继续',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  onPressed: () => _uploadTransfers.resume(task.id),
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                ),
              ],
            )
          else if (state.phase == MediaTransferPhase.canceled ||
              state.phase == MediaTransferPhase.failed)
            IconButton(
              key: Key('dismiss-upload-${task.id}'),
              tooltip: '关闭',
              onPressed: () => _uploadTransfers.dismiss(task.id),
              icon: const Icon(Icons.close_rounded, size: 20),
            )
          else
            MediaTransferProgress(
              state: state,
              onCancel: state.canCancel
                  ? () => _uploadTransfers.cancel(task.id)
                  : null,
            ),
        ],
      ),
    );
  }

  String _transferPhaseLabel(
    MediaTransferPhase phase,
    MediaTransferDirection direction,
  ) => switch (phase) {
    MediaTransferPhase.queued => '等待中',
    MediaTransferPhase.preparing => '处理中…',
    MediaTransferPhase.uploading =>
      direction == MediaTransferDirection.upload ? '上传中…' : '下载中…',
    MediaTransferPhase.paused => '已暂停',
    MediaTransferPhase.committing => '正在提交…',
    MediaTransferPhase.done => '已完成',
    MediaTransferPhase.failed => '失败',
    MediaTransferPhase.canceled => '已取消',
  };

  String _formatTransferBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  bool get _mobileHoldToTalk =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _androidVoiceInputActive =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android && _voiceMode;

  Widget _voiceRecordingBanner() {
    final cancelling = _voiceCancelGesture;
    final activeBars = (2 + (_voiceAmplitude * 7).round()).clamp(2, 9);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
      decoration: BoxDecoration(
        color: cancelling
            ? const Color(0xFFFFE5E5)
            : DdColors.ownBubble.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(DdRadii.surface),
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 58,
            height: 44,
            decoration: BoxDecoration(
              color: cancelling
                  ? DdColors.danger
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(DdRadii.control),
            ),
            child: Icon(
              Icons.delete_outline_rounded,
              color: cancelling ? Colors.white : DdColors.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 27,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: List<Widget>.generate(11, (index) {
                      final distance = (index - 5).abs();
                      final base = 5.0 + (5 - distance).clamp(0, 5) * 1.7;
                      final energized =
                          index < activeBars || index >= 11 - activeBars;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 80),
                        width: 3,
                        height: energized ? base + _voiceAmplitude * 11 : base,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: cancelling
                              ? DdColors.danger
                              : DdColors.greenPressed,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  cancelling ? '松手取消' : '松开发送',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cancelling ? DdColors.danger : DdColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
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
    final mobile = _mobileHoldToTalk;
    final icon = mobile && _voiceMode
        ? Icons.keyboard_alt_outlined
        : _voiceRecording
        ? Icons.stop_circle_outlined
        : Icons.mic_none_rounded;
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
            : Icon(
                icon,
                size: 25,
                color: _voiceRecording ? DdColors.danger : null,
              ),
      ),
    );
    if (mobile) {
      return Tooltip(
        message: _voiceMode ? '切换到键盘' : '切换到语音',
        child: GestureDetector(
          key: const Key('chat-voice'),
          behavior: HitTestBehavior.opaque,
          onTap: _voiceSending || _voiceRecording
              ? null
              : () {
                  _dismissKeyboard();
                  setState(() => _voiceMode = !_voiceMode);
                  if (!_voiceMode) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _composerFocusNode.requestFocus();
                    });
                  }
                },
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

  Widget _holdToTalkField() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Listener(
        key: const Key('chat-hold-to-talk'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (_voiceSending || _voicePointerId != null) return;
          _voicePointerId = event.pointer;
          if (_voiceCancelGesture && mounted) {
            setState(() => _voiceCancelGesture = false);
          }
          unawaited(_beginVoiceRecording());
        },
        onPointerMove: (event) {
          if (event.pointer != _voicePointerId) return;
          final nextCancel = event.localPosition.dx <= 66;
          if (nextCancel != _voiceCancelGesture && mounted) {
            setState(() => _voiceCancelGesture = nextCancel);
          }
        },
        onPointerUp: (event) {
          if (event.pointer != _voicePointerId) return;
          _voicePointerId = null;
          unawaited(_finishVoiceRecording(cancel: _voiceCancelGesture));
        },
        onPointerCancel: (event) {
          if (event.pointer != _voicePointerId) return;
          _voicePointerId = null;
          unawaited(_finishVoiceRecording(cancel: true));
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _voiceRecording
                ? (_voiceCancelGesture
                      ? const Color(0xFFFFE4E4)
                      : const Color(0xFFE7E7E7))
                : Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF2B2B2B)
                : const Color(0xFFF3F3F3),
            borderRadius: BorderRadius.circular(DdRadii.pill),
          ),
          child: Text(
            _voiceRecording ? (_voiceCancelGesture ? '松手取消' : '松开发送') : '按住说话',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: _voiceCancelGesture ? DdColors.danger : null,
            ),
          ),
        ),
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
      final replyToMessageId = _replyingTo?.id;
      if (_replyingTo != null && mounted) {
        setState(() => _replyingTo = null);
      }
      final taskId = _newUploadTaskId('voice');
      final fileName =
          'voice-${DateTime.now().microsecondsSinceEpoch}.${recorded.fileExtension}';
      _uploadTransfers.enqueue(
        id: taskId,
        kind: MediaTransferKind.voice,
        label: '语音 ${(recorded.durationMs / 1000).ceil()} 秒',
        conversationId: widget.conversation.id,
        operation: (task) async {
          task.update(
            MediaTransferState(
              phase: MediaTransferPhase.uploading,
              totalBytes: recorded.bytes.length,
            ),
          );
          final grant = await widget.coordinator.withAuthorizedToken(
            (token) => widget.coordinator.transferMediaApi.uploadMedia(
              origin: widget.coordinator.origin,
              accessToken: token,
              bytes: recorded.bytes,
              fileName: fileName,
              mimeType: recorded.mimeType,
              purpose: 'CHAT_VOICE',
              cancellation: task.cancellation,
              onProgress: (sent, total) {
                task.update(
                  MediaTransferState(
                    phase: MediaTransferPhase.uploading,
                    transferredBytes: sent,
                    totalBytes: total,
                  ),
                );
              },
            ),
          );
          task.throwIfCancelled();
          task.update(
            MediaTransferState(
              phase: MediaTransferPhase.committing,
              transferredBytes: recorded.bytes.length,
              totalBytes: recorded.bytes.length,
            ),
          );
          await widget.coordinator.sendMedia(
            widget.conversation.id,
            type: 'VOICE',
            mediaId: grant.mediaId,
            mimeType: recorded.mimeType,
            sizeBytes: recorded.bytes.length,
            durationMs: recorded.durationMs,
            replyToMessageId: replyToMessageId,
          );
          if (mounted) _scrollToBottom();
        },
      );
    } on FormatException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('语音录制结束失败，请稍后重试。');
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
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final field = TextField(
      key: const Key('chat-composer'),
      controller: _composer,
      focusNode: _composerFocusNode,
      minLines: 1,
      maxLines: 5,
      maxLength: 4000,
      keyboardType: TextInputType.multiline,
      textInputAction: android ? TextInputAction.send : TextInputAction.newline,
      onSubmitted: android ? (_) => _sendFromKeyboard() : null,
      decoration: const InputDecoration(
        hintText: '输入消息',
        counterText: '',
        filled: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      ),
    );
    if (!_keyboardSendEnabled) return field;
    return AnimatedBuilder(
      animation: _mentionController,
      child: field,
      builder: (context, child) => CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): _sendFromKeyboard,
          if (_mentionController.visible) ...{
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                _moveMentionSelection(-1),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                _moveMentionSelection(1),
            const SingleActivator(LogicalKeyboardKey.escape):
                _closeMentionSuggestions,
          },
        },
        child: child!,
      ),
    );
  }

  Widget _editPreview(ChatMessage message) {
    return Container(
      key: const Key('chat-edit-preview'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF2C2C2C)
            : const Color(0xFFF1F1F1),
        borderRadius: BorderRadius.circular(DdRadii.control),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 28,
            decoration: BoxDecoration(
              color: DdColors.greenPressed,
              borderRadius: BorderRadius.circular(DdRadii.pill),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '正在编辑消息',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: DdColors.greenPressed,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message.content?.text ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DdColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('chat-cancel-edit'),
            tooltip: '取消编辑',
            visualDensity: VisualDensity.compact,
            onPressed: _cancelEditing,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  void _beginEditing(ChatMessage message) {
    if (message.senderUserId != widget.currentUserId ||
        message.type != 'TEXT' ||
        message.isRecalled ||
        message.content == null) {
      return;
    }
    _draftSaveTimer?.cancel();
    final originalDraft = _editingMessage == null
        ? _composer.text
        : (_draftBeforeEdit ?? '');
    setState(() {
      _draftBeforeEdit = originalDraft;
      _editingMessage = message;
      _replyingTo = null;
      _voiceMode = false;
    });
    final text = message.content!.text;
    _composer.text = text;
    _composer.selection = TextSelection.collapsed(offset: text.length);
    _composerFocusNode.requestFocus();
  }

  void _cancelEditing() {
    if (_editingMessage == null) return;
    final restore = _draftBeforeEdit ?? '';
    setState(() {
      _editingMessage = null;
      _draftBeforeEdit = null;
    });
    _composer.text = restore;
    _composer.selection = TextSelection.collapsed(offset: restore.length);
    unawaited(
      widget.coordinator.setDraft(
        widget.conversation.id,
        restore,
        notify: false,
      ),
    );
    _composerFocusNode.requestFocus();
  }

  Widget _replyPreview(ChatMessage message) {
    if (message.isRecalled) return const SizedBox.shrink();
    return Container(
      key: const Key('chat-reply-preview'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF2C2C2C)
            : const Color(0xFFF1F1F1),
        borderRadius: BorderRadius.circular(DdRadii.control),
      ),
      child: Row(
        children: [
          Container(width: 2, height: 24, color: DdColors.green),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '回复：${message.content?.text ?? '[${message.type}]'}',
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

  Future<void> _openPeerMoments(String userId, String displayName) async {
    final normalized = userId.trim();
    if (normalized.isEmpty || !mounted) return;
    final inspector = widget.inspectorController;
    if (inspector != null) {
      inspector.push(
        DesktopInspectorEntry(
          id: 'moments:$normalized',
          title: '$displayName的朋友圈',
          builder: (_) => MomentsFeedPage(
            origin: widget.coordinator.origin,
            accessToken: widget.coordinator.accessToken,
            currentUserId: widget.currentUserId,
            currentUserDisplayName: widget.currentUserDisplayName,
            authorId: normalized,
            authorDisplayName: displayName,
            onUnauthorized:
                widget.coordinator.onUnauthorized ?? () async => null,
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MomentsFeedPage(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          currentUserId: widget.currentUserId,
          currentUserDisplayName: widget.currentUserDisplayName,
          authorId: normalized,
          authorDisplayName: displayName,
          onUnauthorized: widget.coordinator.onUnauthorized ?? () async => null,
        ),
      ),
    );
  }

  Future<void> _openPeerMomentPrivacy(String userId, String displayName) async {
    final normalized = userId.trim();
    if (normalized.isEmpty || !mounted) return;
    final inspector = widget.inspectorController;
    if (inspector != null) {
      inspector.push(
        DesktopInspectorEntry(
          id: 'moment-privacy:$normalized',
          title: '朋友圈权限',
          builder: (_) => MomentContactPrivacyPage(
            origin: widget.coordinator.origin,
            accessToken: widget.coordinator.accessToken,
            targetUserId: normalized,
            targetDisplayName: displayName,
            onUnauthorized:
                widget.coordinator.onUnauthorized ?? () async => null,
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MomentContactPrivacyPage(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          targetUserId: normalized,
          targetDisplayName: displayName,
          onUnauthorized: widget.coordinator.onUnauthorized ?? () async => null,
        ),
      ),
    );
  }

  Future<void> _openMentionProfile(String userId) async {
    final normalized = userId.trim();
    if (normalized.isEmpty || !mounted) return;
    final displayName = _mentionDisplayName(normalized);
    final handle = _mentionHandle(normalized);
    final canTarget = normalized != widget.currentUserId;
    final inspector = widget.inspectorController;
    final nativeDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    if (inspector != null || nativeDesktop) {
      inspector?.close();
      await showDesktopMentionProfileDialog(
        context: context,
        origin: widget.coordinator.origin,
        accessToken: widget.coordinator.accessToken,
        userId: normalized,
        handle: handle,
        displayName: displayName,
        onOpenMoments: () => _openPeerMoments(normalized, displayName),
        onOpenMomentPrivacy: () =>
            _openPeerMomentPrivacy(normalized, displayName),
        onMessage: !canTarget || widget.onOpenDirectChat == null
            ? null
            : () => widget.onOpenDirectChat!(normalized),
        onAudioCall: !canTarget || widget.onStartCall == null
            ? null
            : () =>
                  widget.onStartCall!(normalized, displayName, CallKind.audio),
        onVideoCall: !canTarget || widget.onStartCall == null
            ? null
            : () =>
                  widget.onStartCall!(normalized, displayName, CallKind.video),
      );
      return;
    }
    widget.coordinator.deactivateConversation(widget.conversation.id);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PeerProfilePage(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          userId: normalized,
          handle: handle,
          displayName: displayName,
          onOpenMoments: () => _openPeerMoments(normalized, displayName),
          onOpenMomentPrivacy: () =>
              _openPeerMomentPrivacy(normalized, displayName),
          onMessage: !canTarget || widget.onOpenDirectChat == null
              ? null
              : () async {
                  if (mounted) Navigator.of(context).pop();
                  await widget.onOpenDirectChat!(normalized);
                },
        ),
      ),
    );
    if (mounted) _updateReadVisibility();
  }

  String _mentionDisplayName(String userId) {
    final peer = widget.conversation.peer;
    if (peer != null &&
        peer.id == userId &&
        peer.displayName.trim().isNotEmpty) {
      return peer.displayName.trim();
    }
    final member = _groupMembers[userId];
    if (member != null && member.effectiveName.trim().isNotEmpty) {
      return member.effectiveName.trim();
    }
    return '用户';
  }

  String _mentionHandle(String userId) {
    final peer = widget.conversation.peer;
    if (peer != null && peer.id == userId && peer.handle.trim().isNotEmpty) {
      return peer.handle.trim();
    }
    return _groupMembers[userId]?.user.handle.trim() ?? '';
  }

  Future<void> _openPeerProfile(ConversationItem conversation) async {
    final peer = conversation.peer;
    if (peer == null || peer.id.isEmpty || peer.handle.isEmpty || !mounted) {
      return;
    }
    final inspector = widget.inspectorController;
    if (inspector != null) {
      inspector.open(
        DesktopInspectorEntry(
          id: 'peer:${peer.id}',
          title: '详细资料',
          builder: (_) => PeerProfilePage(
            origin: widget.coordinator.origin,
            accessToken: widget.coordinator.accessToken,
            userId: peer.id,
            handle: peer.handle,
            displayName: peer.displayName,
            embedded: true,
            onOpenMoments: () => _openPeerMoments(peer.id, peer.displayName),
            onOpenMomentPrivacy: () =>
                _openPeerMomentPrivacy(peer.id, peer.displayName),
            onMessage: () async => inspector.close(),
            onAudioCall: widget.onStartCall == null
                ? null
                : () async {
                    inspector.close();
                    await _startCall(CallKind.audio);
                  },
            onVideoCall: widget.onStartCall == null
                ? null
                : () async {
                    inspector.close();
                    await _startCall(CallKind.video);
                  },
          ),
        ),
      );
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
          onOpenMoments: () => _openPeerMoments(peer.id, peer.displayName),
          onOpenMomentPrivacy: () =>
              _openPeerMomentPrivacy(peer.id, peer.displayName),
          onMessage: () async {
            if (mounted) Navigator.of(context).pop();
          },
          onAudioCall: widget.onStartCall == null
              ? null
              : () async {
                  if (mounted) Navigator.of(context).pop();
                  await _startCall(CallKind.audio);
                },
          onVideoCall: widget.onStartCall == null
              ? null
              : () async {
                  if (mounted) Navigator.of(context).pop();
                  await _startCall(CallKind.video);
                },
        ),
      ),
    );
    if (mounted) _updateReadVisibility();
  }

  Future<void> _load() async {
    try {
      if (widget.conversation.type == 'GROUP') {
        await _loadGroupMembers();
      }
      await widget.coordinator.loadMessages(
        widget.conversation.id,
        markRead: false,
      );
      final pinned = await widget.coordinator.listPinnedMessages(
        widget.conversation.id,
      );
      if (mounted) setState(() => _pinnedMessages = pinned);
      await _markLatestReadIfVisible();
      if (widget.initialMessageId case final messageId?
          when messageId.isNotEmpty) {
        await WidgetsBinding.instance.endOfFrame;
        await _jumpToMessage(messageId);
      } else {
        _scrollToBottom(immediate: true);
      }
    } catch (_) {
      // Coordinator/API state already carries the actionable error.
    }
  }

  Future<void> _loadOlder() async {
    await widget.coordinator.loadOlder(widget.conversation.id);
  }

  Future<void> _loadGroupMembers() async {
    if (widget.conversation.type != 'GROUP') return;
    final members = await widget.coordinator.withAuthorizedToken(
      (token) => _groupsApi.listMembers(
        origin: widget.coordinator.origin,
        accessToken: token,
        groupId: widget.conversation.id,
      ),
    );
    if (!mounted) return;
    setState(() {
      _groupMembers = {for (final member in members) member.user.id: member};
    });
  }

  Future<void> _openChatDetails(ConversationItem conversation) async {
    if (!mounted || widget.savedMessagesMode) return;
    final inspector = widget.inspectorController;
    if (inspector != null) {
      if (conversation.type == 'GROUP') {
        inspector.open(
          DesktopInspectorEntry(
            id: 'group-details:${conversation.id}',
            title: '群聊信息',
            builder: (_) => GroupDetailsPage(
              coordinator: widget.coordinator,
              groupId: conversation.id,
              currentUserId: widget.currentUserId,
              embedded: true,
              onResult: (result) =>
                  unawaited(_handleGroupDetailsResult(result)),
            ),
          ),
        );
      } else {
        inspector.open(
          DesktopInspectorEntry(
            id: 'chat-details:${conversation.id}',
            title: '聊天详情',
            builder: (_) => ChatDetailsPage(
              coordinator: widget.coordinator,
              conversation: conversation,
              embedded: true,
              onResult: (result) => unawaited(_handleChatDetailsResult(result)),
              onOpenProfile: () => _pushPeerProfile(conversation),
              onOpenMomentPrivacy: conversation.peer == null
                  ? null
                  : () => _openPeerMomentPrivacy(
                      conversation.peer!.id,
                      conversation.peer!.displayName,
                    ),
              onChangeBackground: () async {
                inspector.push(
                  DesktopInspectorEntry(
                    id: 'chat-background:${conversation.id}',
                    title: '聊天背景',
                    builder: (_) => ChatBackgroundSettingsPage(
                      store: _appearanceStore,
                      conversationId: conversation.id,
                    ),
                  ),
                );
              },
              onOpenSearch: () async {
                inspector.push(
                  DesktopInspectorEntry(
                    id: 'chat-search:${conversation.id}',
                    title: '查找聊天记录',
                    builder: (_) => ConversationMessageSearchPage(
                      coordinator: widget.coordinator,
                      conversation: conversation,
                      embedded: true,
                      onSelected: (messageId) => unawaited(
                        _handleChatDetailsResult(
                          ChatDetailsResult(messageId: messageId),
                        ),
                      ),
                    ),
                  ),
                );
              },
              onOpenMedia: () async {
                inspector.push(
                  DesktopInspectorEntry(
                    id: 'chat-media:${conversation.id}',
                    title: '聊天文件',
                    builder: (_) => ConversationMediaPage(
                      coordinator: widget.coordinator,
                      conversation: conversation,
                      embedded: true,
                      onSelected: (messageId) => unawaited(
                        _handleChatDetailsResult(
                          ChatDetailsResult(messageId: messageId),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      }
      return;
    }
    widget.coordinator.deactivateConversation(widget.conversation.id);
    if (conversation.type == 'GROUP') {
      final result = await Navigator.of(context).push<GroupDetailsResult>(
        MaterialPageRoute<GroupDetailsResult>(
          builder: (_) => GroupDetailsPage(
            coordinator: widget.coordinator,
            groupId: conversation.id,
            currentUserId: widget.currentUserId,
          ),
        ),
      );
      if (!mounted) return;
      if (result?.membershipEnded == true) {
        await Navigator.of(context).maybePop();
        return;
      }
      await widget.coordinator.refreshConversations();
      try {
        await _loadGroupMembers();
      } catch (_) {
        // Membership refresh is best-effort here; the next realtime/sync or
        // page refresh will retry without hiding the chat itself.
      }
      _updateReadVisibility();
      return;
    }
    final result = await Navigator.of(context).push<ChatDetailsResult>(
      MaterialPageRoute<ChatDetailsResult>(
        builder: (_) => ChatDetailsPage(
          coordinator: widget.coordinator,
          conversation: conversation,
          onOpenProfile: () => _openPeerProfile(conversation),
          onOpenMomentPrivacy: conversation.peer == null
              ? null
              : () => _openPeerMomentPrivacy(
                  conversation.peer!.id,
                  conversation.peer!.displayName,
                ),
          onChangeBackground: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ChatBackgroundSettingsPage(
                store: _appearanceStore,
                conversationId: conversation.id,
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (result?.conversationHidden == true) {
      await Navigator.of(context).maybePop();
      return;
    }
    _updateReadVisibility();
    final messageId = result?.messageId;
    if (messageId != null && messageId.isNotEmpty) {
      await _jumpToMessage(messageId);
    }
  }

  Future<void> _pushPeerProfile(ConversationItem conversation) async {
    final peer = conversation.peer;
    final inspector = widget.inspectorController;
    if (peer == null || inspector == null) return;
    inspector.push(
      DesktopInspectorEntry(
        id: 'peer:${peer.id}',
        title: '详细资料',
        builder: (_) => PeerProfilePage(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          userId: peer.id,
          handle: peer.handle,
          displayName: peer.displayName,
          embedded: true,
          onOpenMoments: () => _openPeerMoments(peer.id, peer.displayName),
          onOpenMomentPrivacy: () =>
              _openPeerMomentPrivacy(peer.id, peer.displayName),
          onMessage: () async => inspector.close(),
          onAudioCall: widget.onStartCall == null
              ? null
              : () async {
                  inspector.close();
                  await _startCall(CallKind.audio);
                },
          onVideoCall: widget.onStartCall == null
              ? null
              : () async {
                  inspector.close();
                  await _startCall(CallKind.video);
                },
        ),
      ),
    );
  }

  Future<void> _handleGroupDetailsResult(GroupDetailsResult result) async {
    widget.inspectorController?.close();
    if (result.membershipEnded) return;
    await widget.coordinator.refreshConversations();
    try {
      await _loadGroupMembers();
    } catch (_) {}
  }

  Future<void> _handleChatDetailsResult(ChatDetailsResult result) async {
    widget.inspectorController?.close();
    if (result.conversationHidden) return;
    final messageId = result.messageId;
    if (messageId != null && messageId.isNotEmpty) {
      await _jumpToMessage(messageId);
    }
  }

  Widget _groupCallBanner() {
    final active = _activeGroupCall;
    return Container(
      key: const Key('group-call-banner'),
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
      decoration: BoxDecoration(
        color: active == null
            ? Theme.of(context).colorScheme.surface.withValues(alpha: 0.94)
            : DdColors.green.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DdRadii.control),
      ),
      child: Row(
        children: [
          Icon(
            active?.isVideo == true
                ? Icons.video_call_rounded
                : Icons.call_rounded,
            size: 19,
            color: active == null ? DdColors.textSecondary : DdColors.green,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              active == null
                  ? '发起群通话'
                  : '${active.isVideo ? '群视频通话' : '群语音通话'}进行中 · ${active.participants.length}/${active.maxParticipants} 人',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (_groupCallBusy)
            const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (active != null)
            TextButton(
              key: const Key('group-call-join-active'),
              onPressed: _joinActiveGroupCall,
              child: const Text('加入'),
            )
          else ...[
            IconButton(
              key: const Key('group-call-start-audio'),
              tooltip: '发起群语音通话',
              visualDensity: VisualDensity.compact,
              onPressed: () => _startGroupCall('AUDIO'),
              icon: const Icon(Icons.call_outlined, size: 20),
            ),
            IconButton(
              key: const Key('group-call-start-video'),
              tooltip: '发起群视频通话',
              visualDensity: VisualDensity.compact,
              onPressed: () => _startGroupCall('VIDEO'),
              icon: const Icon(Icons.videocam_outlined, size: 20),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _refreshActiveGroupCall() async {
    if (widget.conversation.type != 'GROUP') return;
    try {
      final active = await widget.coordinator.withAuthorizedToken(
        (token) => _groupCallGateway.active(
          origin: widget.coordinator.origin,
          accessToken: token,
          groupId: widget.conversation.id,
        ),
      );
      if (mounted) setState(() => _activeGroupCall = active);
    } catch (_) {
      // Active-call discovery is best effort; the chat itself must stay usable.
    }
  }

  Future<bool> _confirmStartGroupCall(String kind) async {
    final video = kind == 'VIDEO';
    final memberCount = _groupMembers.isNotEmpty
        ? _groupMembers.length
        : widget.conversation.group?.memberCount ?? 0;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(video ? '发起群视频通话？' : '发起群语音通话？'),
            content: Text(
              '当前群共有 $memberCount 位成员。发起后会通过 DD 实时通道通知在线成员；'
              '会话免打扰只抑制提醒，不影响成员主动加入。离线系统 Push 仍由 P10 Push 能力负责。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('confirm-start-group-call'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('发起'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _startGroupCall(String kind) async {
    if (_groupCallBusy || !mounted) return;
    if (!await _confirmStartGroupCall(kind) || !mounted) return;
    setState(() => _groupCallBusy = true);
    try {
      final joined = await widget.coordinator.withAuthorizedToken(
        (token) => _groupCallGateway.start(
          origin: widget.coordinator.origin,
          accessToken: token,
          groupId: widget.conversation.id,
          kind: kind,
        ),
      );
      if (!mounted) return;
      setState(() => _activeGroupCall = joined.call);
      await _openGroupCall(joined);
    } on GroupCallApiException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('群通话发起失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _groupCallBusy = false);
      unawaited(_refreshActiveGroupCall());
    }
  }

  Future<void> _joinActiveGroupCall() async {
    final active = _activeGroupCall;
    if (active == null || _groupCallBusy || !mounted) return;
    setState(() => _groupCallBusy = true);
    try {
      final joined = await widget.coordinator.withAuthorizedToken(
        (token) => _groupCallGateway.join(
          origin: widget.coordinator.origin,
          accessToken: token,
          groupId: widget.conversation.id,
          callId: active.id,
        ),
      );
      if (!mounted) return;
      await _openGroupCall(joined);
    } on GroupCallApiException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('加入群通话失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _groupCallBusy = false);
      unawaited(_refreshActiveGroupCall());
    }
  }

  Future<void> _openGroupCall(GroupCallJoinInfo joined) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => GroupCallPage(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          groupName: widget.conversation.group?.name ?? '群聊',
          join: joined,
          gateway: _groupCallGateway,
        ),
      ),
    );
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
    if (_acceptSelectedMention()) return;
    unawaited(_send());
  }

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    final editing = _editingMessage;
    if (editing != null) {
      try {
        await widget.coordinator.editMessage(editing, text);
        if (!mounted) return;
        final restore = _draftBeforeEdit ?? '';
        setState(() {
          _editingMessage = null;
          _draftBeforeEdit = null;
        });
        _composer.text = restore;
        _composer.selection = TextSelection.collapsed(offset: restore.length);
        unawaited(
          widget.coordinator.setDraft(
            widget.conversation.id,
            restore,
            notify: false,
          ),
        );
        _composerFocusNode.requestFocus();
      } on FormatException catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('消息更新失败，请稍后重试。')));
      }
      return;
    }

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

  Future<void> _shareStickerPack(StickerPackItemGroup pack) async {
    final setName = pack.setName.trim();
    if (setName.isEmpty) {
      _showImageError('这个表情包缺少可分享的 Telegram 标识。');
      return;
    }
    if (pack.items.isEmpty) {
      _showImageError('这个表情包没有可用的表情，暂时无法分享。');
      return;
    }
    final sortedItems = List<StickerPackItem>.from(pack.items)
      ..sort((left, right) {
        final byOrder = left.sortOrder.compareTo(right.sortOrder);
        return byOrder != 0 ? byOrder : left.id.compareTo(right.id);
      });
    final preview = sortedItems.first;
    final title = pack.title.trim().isEmpty ? setName : pack.title.trim();
    await widget.coordinator.sendMedia(
      widget.conversation.id,
      type: 'STICKER_PACK',
      mediaId: preview.mediaId,
      width: preview.width,
      height: preview.height,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已分享表情包「$title」')));
    _scrollToBottom();
  }

  Future<void> _showEmojiPicker() async {
    final selected = await showModalBottomSheet<StickerPanelResult>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => StickerLibrarySheet(
        origin: widget.coordinator.origin,
        accessToken: widget.coordinator.accessToken,
        emoji: EmojiCatalog.all,
        emojiCategories: EmojiCatalog.categories,
        recentEmoji: widget.coordinator.recentEmoji,
        mediaBytesLoader: _mediaBytesFor,
        mediaUrlResolver: (mediaId, expectedSizeBytes) =>
            _resolveCachedStickerVideo(
              mediaId,
              expectedSizeBytes: expectedSizeBytes,
            ),
        onAddCustomSticker: _pickAndCreateCustomSticker,
        initialTabKey: widget.coordinator.stickerPanelTabKey,
        onTabChanged: (tabKey) =>
            unawaited(widget.coordinator.rememberStickerPanelTab(tabKey)),
        gateway: widget.stickerGateway,
      ),
    );
    if (selected == null || !mounted) return;
    switch (selected) {
      case EmojiPanelResult(:final emoji):
        _insertAtSelection(emoji);
        unawaited(widget.coordinator.rememberRecentEmoji(emoji));
      case StickerAssetPanelResult(:final asset):
        await _sendStickerAsset(asset);
      case StickerPackSharePanelResult(:final pack):
        await _shareStickerPack(pack);
    }
    if (mounted) _composerFocusNode.requestFocus();
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
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 4,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.86,
            children: [
              _ComposerAction(
                icon: Icons.photo_library_outlined,
                label: '相册',
                enabled: true,
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_pickAndSendAlbum());
                },
              ),
              _ComposerAction(
                icon: Icons.photo_camera_outlined,
                label: '拍摄',
                enabled: _cameraCapture.isSupported,
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_captureAndSendPhoto());
                },
              ),
              _ComposerAction(
                icon: Icons.insert_drive_file_outlined,
                label: '文件',
                enabled: true,
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_pickAndSendFile());
                },
              ),
              if (widget.conversation.type == 'GROUP' &&
                  _activeGroupCall == null) ...[
                KeyedSubtree(
                  key: const Key('group-call-menu-audio'),
                  child: _ComposerAction(
                    icon: Icons.call_outlined,
                    label: '语音通话',
                    enabled: !_groupCallBusy,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      unawaited(_startGroupCall('AUDIO'));
                    },
                  ),
                ),
                KeyedSubtree(
                  key: const Key('group-call-menu-video'),
                  child: _ComposerAction(
                    icon: Icons.videocam_outlined,
                    label: '视频通话',
                    enabled: !_groupCallBusy,
                    onTap: () {
                      Navigator.pop(sheetContext);
                      unawaited(_startGroupCall('VIDEO'));
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _captureAndSendPhoto() async {
    if (!_cameraCapture.isSupported) return;
    try {
      final file = await _cameraCapture.capturePhoto();
      if (file == null || !mounted) return;
      await _sendImageFiles(<XFile>[file]);
    } on PlatformException catch (error) {
      if (!mounted) return;
      if (error.code == 'CAMERA_PERMISSION_DENIED') {
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(error.message ?? '相机权限被拒绝。'),
            action: SnackBarAction(
              label: '去设置',
              onPressed: () => unawaited(_cameraCapture.openAppSettings()),
            ),
          ),
        );
        return;
      }
      _showImageError(error.message ?? '拍摄失败，请稍后重试。');
    } on UnsupportedError catch (error) {
      if (mounted) _showImageError(error.message ?? '当前平台暂不支持拍摄。');
    } catch (_) {
      if (mounted) _showImageError('拍摄失败，请稍后重试。');
    }
  }

  Future<void> _pickAndSendAlbum() async {
    const typeGroup = XTypeGroup(
      label: '相册',
      extensions: <String>[
        'jpg',
        'jpeg',
        'png',
        'webp',
        'bmp',
        'gif',
        'mp4',
        'webm',
        'mov',
        'mkv',
      ],
      mimeTypes: <String>[
        'image/jpeg',
        'image/png',
        'image/webp',
        'image/bmp',
        'image/gif',
        'video/mp4',
        'video/webm',
        'video/quicktime',
        'video/x-matroska',
      ],
    );
    late final List<XFile> files;
    try {
      files = await ddOpenFiles(
        acceptedTypeGroups: const [typeGroup],
        source: DdFilePickerSource.photos,
        maxFiles: 30,
        maxBytes: 2 * 1024 * 1024 * 1024,
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      if (isDdPhotoLibraryPermissionError(error)) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(error.message ?? '照片权限被拒绝。'),
            action: SnackBarAction(
              label: '去设置',
              onPressed: () => unawaited(ddOpenFilePickerAppSettings()),
            ),
          ),
        );
      } else {
        _showImageError(error.message ?? '读取所选媒体失败。');
      }
      return;
    }
    if (files.isEmpty || !mounted) return;
    if (files.length > 30) {
      _showImageError('一次最多从相册发送 30 个媒体文件。');
      return;
    }
    for (final file in files) {
      if (!mounted) return;
      final lower = file.name.toLowerCase();
      if (lower.endsWith('.gif')) {
        await _sendGif(file);
      } else if (_videoMimeType(lower) != null) {
        await _sendVideo(file);
      } else if (_isImageFileName(lower)) {
        await _sendImageFiles(<XFile>[file]);
      } else {
        _showImageError(
          '${file.name.isEmpty ? '所选媒体' : file.name} 的格式不受支持，已跳过。',
        );
      }
    }
  }

  Future<void> _sendImageFiles(List<XFile> files) async {
    if (files.isEmpty || !mounted) return;
    if (files.length > 30) {
      _showImageError('一次最多发送 30 张图片。');
      return;
    }
    final replyToMessageId = _replyingTo?.id;
    if (_replyingTo != null) setState(() => _replyingTo = null);
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      final taskId = _newUploadTaskId('image');
      _uploadTransfers.enqueue(
        id: taskId,
        kind: MediaTransferKind.image,
        label: file.name.isEmpty ? '图片 ${index + 1}' : file.name,
        conversationId: widget.conversation.id,
        operation: (task) => _runImageUpload(
          file,
          task,
          replyToMessageId: index == 0 ? replyToMessageId : null,
        ),
      );
      _scrollToBottom();
    }
  }

  Future<void> _runImageUpload(
    XFile file,
    MediaTransferExecution task, {
    String? replyToMessageId,
  }) async {
    final sourceLength = await file.length();
    if (sourceLength <= 0) throw const FormatException('不能发送空图片。');
    if (sourceLength > maxChatImageSourceBytes) {
      throw FormatException(
        '${file.name.isEmpty ? '图片' : file.name} 超过 96 MiB。',
      );
    }
    task.update(
      MediaTransferState(
        phase: MediaTransferPhase.preparing,
        totalBytes: sourceLength,
      ),
    );
    task.throwIfCancelled();
    final source = await file.readAsBytes();
    task.throwIfCancelled();
    final processed = await processChatImage(source);
    task.throwIfCancelled();
    task.setVisualPreview(
      MediaTransferVisualPreview(
        posterBytes: processed.bytes,
        width: processed.width,
        height: processed.height,
      ),
    );
    task.update(
      MediaTransferState(
        phase: MediaTransferPhase.uploading,
        totalBytes: processed.bytes.length,
      ),
    );
    final grant = await widget.coordinator.withAuthorizedToken(
      (token) => widget.coordinator.transferMediaApi.uploadChatImage(
        origin: widget.coordinator.origin,
        accessToken: token,
        bytes: processed.bytes,
        fileName: '${DateTime.now().microsecondsSinceEpoch}.jpg',
        cancellation: task.cancellation,
        onProgress: (sent, total) {
          if (total <= 0) return;
          final current = _uploadTransfers.task(task.id)?.state.progress ?? 0;
          final next = (sent / total).clamp(0.0, 1.0);
          if ((next - current).abs() < 0.02 && next < 1) return;
          task.update(
            MediaTransferState(
              phase: MediaTransferPhase.uploading,
              transferredBytes: sent,
              totalBytes: total,
            ),
          );
        },
      ),
    );
    task.throwIfCancelled();
    task.update(
      MediaTransferState(
        phase: MediaTransferPhase.committing,
        transferredBytes: processed.bytes.length,
        totalBytes: processed.bytes.length,
      ),
    );
    await widget.coordinator.sendImage(
      widget.conversation.id,
      mediaId: grant.mediaId,
      width: processed.width,
      height: processed.height,
      replyToMessageId: replyToMessageId,
    );
    if (mounted) _scrollToBottom();
  }

  Future<CustomStickerItem?> _pickAndCreateCustomSticker(
    StickerGateway gateway,
  ) async {
    if (_stickerSending) return null;
    const typeGroup = XTypeGroup(
      label: '自定义表情',
      extensions: <String>['png', 'jpg', 'jpeg', 'webp', 'gif', 'mp4', 'webm'],
      mimeTypes: <String>[
        'image/png',
        'image/jpeg',
        'image/webp',
        'image/gif',
        'video/mp4',
        'video/webm',
      ],
    );
    XFile? file;
    try {
      file = await ddOpenFile(
        acceptedTypeGroups: const [typeGroup],
        maxBytes: 64 * 1024 * 1024,
      );
    } on PlatformException catch (error) {
      if (mounted) _showImageError(error.message ?? '读取自定义表情失败。');
      return null;
    }
    final selectedFile = file;
    if (selectedFile == null || !mounted) return null;

    final cancellation = MediaUploadCancellation();
    final transferState = ValueNotifier<MediaTransferState>(
      const MediaTransferState(phase: MediaTransferPhase.preparing),
    );
    setState(() => _stickerSending = true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _StickerTransferDialog(
          state: transferState,
          fileName: selectedFile.name.isEmpty ? '自定义表情' : selectedFile.name,
          onCancel: cancellation.cancel,
        ),
      ),
    );

    try {
      final prepared = await prepareCustomSticker(
        selectedFile,
        cancellation: cancellation,
        onProgress: (processed, total) {
          if (transferState.value.phase != MediaTransferPhase.preparing) {
            return;
          }
          transferState.value = MediaTransferState(
            phase: MediaTransferPhase.preparing,
            transferredBytes: processed,
            totalBytes: total,
          );
        },
      );
      if (cancellation.isCancelled) throw const MediaUploadCancelled();
      transferState.value = MediaTransferState(
        phase: MediaTransferPhase.uploading,
        totalBytes: prepared.sizeBytes,
      );
      final grant = await widget.coordinator.withAuthorizedToken(
        (token) => widget.coordinator.transferMediaApi.uploadStream(
          origin: widget.coordinator.origin,
          accessToken: token,
          streamFactory: prepared.streamFactory,
          size: prepared.sizeBytes,
          fileName: prepared.fileName,
          mimeType: prepared.mimeType,
          purpose: 'STICKER',
          cancellation: cancellation,
          onProgress: (sent, total) {
            transferState.value = MediaTransferState(
              phase: MediaTransferPhase.uploading,
              transferredBytes: sent,
              totalBytes: total,
            );
          },
        ),
      );
      if (cancellation.isCancelled) throw const MediaUploadCancelled();
      transferState.value = MediaTransferState(
        phase: MediaTransferPhase.committing,
        transferredBytes: prepared.sizeBytes,
        totalBytes: prepared.sizeBytes,
      );
      final item = await widget.coordinator.withAuthorizedToken(
        (token) => gateway.createCustomSticker(
          origin: widget.coordinator.origin,
          accessToken: token,
          mediaId: grant.mediaId,
          width: prepared.width,
          height: prepared.height,
        ),
      );
      transferState.value = MediaTransferState(
        phase: MediaTransferPhase.done,
        transferredBytes: prepared.sizeBytes,
        totalBytes: prepared.sizeBytes,
      );
      return item;
    } on MediaUploadCancelled {
      transferState.value = const MediaTransferState(
        phase: MediaTransferPhase.canceled,
      );
    } on StickerApiException catch (error) {
      transferState.value = MediaTransferState(
        phase: MediaTransferPhase.failed,
        errorMessage: error.message,
      );
      if (mounted) _showImageError(error.message);
    } on MessagingApiException catch (error) {
      transferState.value = MediaTransferState(
        phase: MediaTransferPhase.failed,
        errorMessage: error.message,
      );
      if (mounted) _showImageError(error.message);
    } on FormatException catch (error) {
      transferState.value = MediaTransferState(
        phase: MediaTransferPhase.failed,
        errorMessage: error.message,
      );
      if (mounted) _showImageError(error.message);
    } catch (_) {
      transferState.value = const MediaTransferState(
        phase: MediaTransferPhase.failed,
        errorMessage: '自定义表情添加失败，请稍后重试。',
      );
      if (mounted) _showImageError('自定义表情添加失败，请稍后重试。');
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        setState(() => _stickerSending = false);
      }
      transferState.dispose();
    }
    return null;
  }

  Future<void> _sendStickerAsset(StickerAsset asset) async {
    if (_stickerSending || !mounted) return;
    setState(() => _stickerSending = true);
    try {
      final replyToMessageId = _replyingTo?.id;
      if (_replyingTo != null) setState(() => _replyingTo = null);
      await widget.coordinator.sendMedia(
        widget.conversation.id,
        type: 'STICKER',
        mediaId: asset.mediaId,
        width: asset.width,
        height: asset.height,
        replyToMessageId: replyToMessageId,
      );
      if (mounted) _scrollToBottom();
    } on MessagingApiException catch (error) {
      if (mounted) _showImageError(error.message);
    } on FormatException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('表情发送失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _stickerSending = false);
    }
  }

  Future<void> _sendGif(XFile file) async {
    if (!mounted) return;
    final sourceLength = await file.length();
    if (!mounted) return;
    if (sourceLength <= 0) {
      _showImageError('不能发送空 GIF。');
      return;
    }
    if (sourceLength > 50 * 1024 * 1024) {
      _showImageError('GIF 超过 50 MiB，暂时无法发送。');
      return;
    }
    try {
      final prepared = await prepareCustomSticker(file);
      if (!prepared.animated || prepared.mimeType != 'image/gif') {
        throw const FormatException('所选文件不是有效 GIF。');
      }
      final replyToMessageId = _replyingTo?.id;
      if (_replyingTo != null && mounted) {
        setState(() => _replyingTo = null);
      }
      final taskId = _newUploadTaskId('gif');
      _uploadTransfers.enqueue(
        id: taskId,
        kind: MediaTransferKind.gif,
        label: file.name.isEmpty ? 'GIF' : file.name,
        conversationId: widget.conversation.id,
        operation: (task) async {
          task.update(
            MediaTransferState(
              phase: MediaTransferPhase.uploading,
              totalBytes: prepared.sizeBytes,
            ),
          );
          final grant = await widget.coordinator.withAuthorizedToken(
            (token) => widget.coordinator.transferMediaApi.uploadStream(
              origin: widget.coordinator.origin,
              accessToken: token,
              streamFactory: prepared.streamFactory,
              size: prepared.sizeBytes,
              fileName: prepared.fileName,
              mimeType: 'image/gif',
              purpose: 'GIF',
              cancellation: task.cancellation,
              onProgress: (sent, total) {
                task.update(
                  MediaTransferState(
                    phase: MediaTransferPhase.uploading,
                    transferredBytes: sent,
                    totalBytes: total,
                  ),
                );
              },
            ),
          );
          task.throwIfCancelled();
          task.update(
            MediaTransferState(
              phase: MediaTransferPhase.committing,
              transferredBytes: prepared.sizeBytes,
              totalBytes: prepared.sizeBytes,
            ),
          );
          await widget.coordinator.sendMedia(
            widget.conversation.id,
            type: 'GIF',
            mediaId: grant.mediaId,
            width: prepared.width,
            height: prepared.height,
            fileName: file.name,
            mimeType: 'image/gif',
            sizeBytes: prepared.sizeBytes,
            replyToMessageId: replyToMessageId,
          );
          if (mounted) _scrollToBottom();
        },
      );
    } on FormatException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (_) {
      if (mounted) _showImageError('GIF 处理失败，请稍后重试。');
    }
  }

  Future<void> _sendVideo(XFile file) async {
    if (!mounted) return;
    final sourceLength = await file.length();
    if (!mounted) return;
    if (sourceLength <= 0) {
      _showImageError('不能发送空视频。');
      return;
    }
    if (sourceLength > 2 * 1024 * 1024 * 1024) {
      _showImageError('视频超过 2 GiB，当前实例拒绝上传。');
      return;
    }
    final mimeType = _videoMimeType(file.name);
    if (mimeType == null) {
      _showImageError('当前只支持 MP4、WebM、MOV、MKV 视频。');
      return;
    }
    final replyToMessageId = _replyingTo?.id;
    if (_replyingTo != null) setState(() => _replyingTo = null);
    final taskId = _newUploadTaskId('video');
    _uploadTransfers.enqueue(
      id: taskId,
      kind: MediaTransferKind.video,
      label: file.name.isEmpty ? '视频' : file.name,
      conversationId: widget.conversation.id,
      operation: (task) => _runVideoUpload(
        file,
        sourceLength,
        mimeType,
        task,
        replyToMessageId: replyToMessageId,
      ),
    );
    _scrollToBottom();
  }

  Future<void> _runVideoUpload(
    XFile file,
    int sourceLength,
    String mimeType,
    MediaTransferExecution task, {
    String? replyToMessageId,
  }) async {
    task.update(
      MediaTransferState(
        phase: MediaTransferPhase.preparing,
        totalBytes: sourceLength,
      ),
    );
    final metadata = await const VideoMediaProbe().probeFile(file);
    task.throwIfCancelled();
    task.setVisualPreview(
      MediaTransferVisualPreview(
        posterBytes: metadata.posterJpeg,
        width: metadata.width,
        height: metadata.height,
        durationMs: metadata.durationMs,
        localPlaybackUri: _localPlaybackUri(file),
      ),
    );
    task.update(
      MediaTransferState(
        phase: MediaTransferPhase.uploading,
        totalBytes: sourceLength,
      ),
    );
    final primary = await widget.coordinator.withAuthorizedToken(
      (token) => widget.coordinator.transferMediaApi.uploadStream(
        origin: widget.coordinator.origin,
        accessToken: token,
        streamFactory: file.openRead,
        size: sourceLength,
        fileName: file.name.isEmpty ? 'video.mp4' : file.name,
        mimeType: mimeType,
        purpose: 'CHAT_VIDEO',
        cancellation: task.cancellation,
        onProgress: (sent, total) {
          if (total <= 0) return;
          final current = _uploadTransfers.task(task.id)?.state.progress ?? 0;
          final next = (sent / total).clamp(0.0, 1.0);
          if ((next - current).abs() < 0.01 && next < 1) return;
          task.update(
            MediaTransferState(
              phase: MediaTransferPhase.uploading,
              transferredBytes: sent,
              totalBytes: total,
            ),
          );
        },
      ),
    );
    task.throwIfCancelled();
    task.update(
      MediaTransferState(
        phase: MediaTransferPhase.committing,
        transferredBytes: sourceLength,
        totalBytes: sourceLength,
      ),
    );
    final poster = await widget.coordinator.withAuthorizedToken(
      (token) => widget.coordinator.transferMediaApi.uploadChatImage(
        origin: widget.coordinator.origin,
        accessToken: token,
        bytes: metadata.posterJpeg,
        fileName: 'video-poster-${DateTime.now().microsecondsSinceEpoch}.jpg',
        cancellation: task.cancellation,
      ),
    );
    task.throwIfCancelled();
    await widget.coordinator.sendMedia(
      widget.conversation.id,
      type: 'VIDEO',
      mediaId: primary.mediaId,
      posterMediaId: poster.mediaId,
      width: metadata.width,
      height: metadata.height,
      durationMs: metadata.durationMs,
      fileName: file.name,
      mimeType: mimeType,
      sizeBytes: sourceLength,
      replyToMessageId: replyToMessageId,
    );
    if (mounted) _scrollToBottom();
  }

  Uri _localPlaybackUri(XFile file) {
    final raw = file.path.trim();
    final parsed = Uri.tryParse(raw);
    if (parsed != null &&
        parsed.scheme.isNotEmpty &&
        parsed.scheme.length > 1) {
      return parsed;
    }
    final windowsPath = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw);
    return Uri.file(raw, windows: windowsPath);
  }

  String? _videoMimeType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    return null;
  }

  Future<void> _pickAndSendFile() async {
    XFile? file;
    try {
      file = await ddOpenFile(maxBytes: 2 * 1024 * 1024 * 1024);
    } on PlatformException catch (error) {
      if (mounted) _showImageError(error.message ?? '读取所选文件失败。');
      return;
    }
    if (file == null || !mounted) return;
    await _sendFile(file);
  }

  Future<void> _sendFile(XFile file) async {
    if (!mounted) return;
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
    final replyToMessageId = _replyingTo?.id;
    if (_replyingTo != null) setState(() => _replyingTo = null);
    final mimeType = _fileMimeType(file.name);
    final taskId = _newUploadTaskId('file');
    _uploadTransfers.enqueue(
      id: taskId,
      kind: MediaTransferKind.file,
      label: file.name.isEmpty ? '文件' : file.name,
      conversationId: widget.conversation.id,
      operation: (task) => _runFileUpload(
        file,
        sourceLength,
        mimeType,
        task,
        replyToMessageId: replyToMessageId,
      ),
    );
  }

  Future<void> _runFileUpload(
    XFile file,
    int sourceLength,
    String mimeType,
    MediaTransferExecution task, {
    String? replyToMessageId,
  }) async {
    task.update(
      MediaTransferState(
        phase: MediaTransferPhase.uploading,
        totalBytes: sourceLength,
      ),
    );
    final grant = await widget.coordinator.withAuthorizedToken(
      (token) => widget.coordinator.transferMediaApi.uploadStream(
        origin: widget.coordinator.origin,
        accessToken: token,
        streamFactory: file.openRead,
        size: sourceLength,
        fileName: file.name.isEmpty ? 'file.bin' : file.name,
        mimeType: mimeType,
        purpose: 'CHAT_FILE',
        cancellation: task.cancellation,
        onProgress: (sent, total) {
          if (total <= 0) return;
          final current = _uploadTransfers.task(task.id)?.state.progress ?? 0;
          final next = (sent / total).clamp(0.0, 1.0);
          if ((next - current).abs() < 0.01 && next < 1) return;
          task.update(
            MediaTransferState(
              phase: MediaTransferPhase.uploading,
              transferredBytes: sent,
              totalBytes: total,
            ),
          );
        },
      ),
    );
    task.throwIfCancelled();
    task.update(
      MediaTransferState(
        phase: MediaTransferPhase.committing,
        transferredBytes: sourceLength,
        totalBytes: sourceLength,
      ),
    );
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
  }

  String _newUploadTaskId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_uploadTransfers.tasks.length}';

  String _fileMimeType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.apk')) {
      return 'application/vnd.android.package-archive';
    }
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
    unawaited(ClientLog.error('Chat media: $message'));
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
        if (_canCopyMessage(message))
          const DdActionSheetItem(
            value: 'copy',
            icon: Icons.content_copy_rounded,
            label: '复制',
          ),
        if (!message.isRecalled) ...[
          const DdActionSheetItem(
            value: 'forward',
            icon: Icons.forward_rounded,
            label: '转发',
          ),
          if (!mine && _canAddStickerToLibrary(message))
            const DdActionSheetItem(
              value: 'add-sticker',
              icon: Icons.add_reaction_outlined,
              label: '添加到我的表情',
            ),
          if (!widget.savedMessagesMode)
            const DdActionSheetItem(
              value: 'save',
              icon: Icons.bookmark_border_rounded,
              label: '收藏',
            ),
          DdActionSheetItem(
            value: _isMessagePinned(message) ? 'unpin-message' : 'pin-message',
            icon: _isMessagePinned(message)
                ? Icons.push_pin_outlined
                : Icons.push_pin_rounded,
            label: _isMessagePinned(message) ? '取消置顶消息' : '置顶消息',
          ),
        ],
        if (mine && !message.isRecalled && message.type == 'TEXT')
          const DdActionSheetItem(
            value: 'edit',
            icon: Icons.edit_outlined,
            label: '编辑',
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
      if (_canCopyMessage(message))
        _contextMenuItem(
          value: 'copy',
          icon: Icons.content_copy_rounded,
          label: '复制',
        ),
      if (!message.isRecalled) ...[
        _contextMenuItem(
          value: 'forward',
          icon: Icons.forward_rounded,
          label: '转发',
        ),
        if (!mine && _canAddStickerToLibrary(message))
          _contextMenuItem(
            value: 'add-sticker',
            icon: Icons.add_reaction_outlined,
            label: '添加到我的表情',
          ),
        if (!widget.savedMessagesMode)
          _contextMenuItem(
            value: 'save',
            icon: Icons.bookmark_border_rounded,
            label: '收藏',
          ),
        _contextMenuItem(
          value: _isMessagePinned(message) ? 'unpin-message' : 'pin-message',
          icon: _isMessagePinned(message)
              ? Icons.push_pin_outlined
              : Icons.push_pin_rounded,
          label: _isMessagePinned(message) ? '取消置顶消息' : '置顶消息',
        ),
      ],
      if (mine && !message.isRecalled && message.type == 'TEXT')
        _contextMenuItem(value: 'edit', icon: Icons.edit_outlined, label: '编辑'),
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

  bool _canCopyMessage(ChatMessage message) =>
      !message.isRecalled &&
      message.type == 'TEXT' &&
      (message.content?.text.trim().isNotEmpty ?? false);

  bool _canAddStickerToLibrary(ChatMessage message) {
    final content = message.content;
    return !message.isRecalled &&
        message.type == 'STICKER' &&
        content?.hasMedia == true &&
        (content?.width ?? 0) > 0 &&
        (content?.height ?? 0) > 0;
  }

  Future<void> _applyMessageAction(ChatMessage message, String? action) async {
    if (action == 'reply') {
      if (_editingMessage != null) _cancelEditing();
      setState(() => _replyingTo = message);
    } else if (action == 'edit') {
      _beginEditing(message);
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.content?.text ?? ''));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制')));
      }
    } else if (action == 'forward') {
      await _forwardMessage(message);
    } else if (action == 'add-sticker') {
      await _addMessageStickerToLibrary(message);
    } else if (action == 'save') {
      await widget.coordinator.saveMessage(message);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已收藏')));
      }
    } else if (action == 'pin-message') {
      await widget.coordinator.pinMessage(message);
      await _refreshPinnedMessages();
    } else if (action == 'unpin-message') {
      await widget.coordinator.unpinMessage(message);
      await _refreshPinnedMessages();
    } else if (action == 'recall') {
      await widget.coordinator.recall(message);
      await _refreshPinnedMessages();
    } else if (action == 'delete') {
      await widget.coordinator.deleteLocally(message);
    }
  }

  Future<void> _addMessageStickerToLibrary(ChatMessage message) async {
    final content = message.content;
    final mediaId = content?.mediaId?.trim() ?? '';
    final width = content?.width ?? 0;
    final height = content?.height ?? 0;
    if (!_canAddStickerToLibrary(message) || mediaId.isEmpty) return;

    final ownsGateway = widget.stickerGateway == null;
    final gateway = widget.stickerGateway ?? StickerApiClient();
    try {
      await widget.coordinator.withAuthorizedToken(
        (token) => gateway.createCustomSticker(
          origin: widget.coordinator.origin,
          accessToken: token,
          mediaId: mediaId,
          width: width,
          height: height,
        ),
      );
    } on StickerApiException catch (error) {
      if (mounted) _showImageError(error.message);
    } catch (error, stackTrace) {
      unawaited(
        ClientLog.error(
          'Add received sticker failed: message=${message.id} media=$mediaId',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      if (mounted) _showImageError('添加表情失败，请稍后重试。');
    } finally {
      if (ownsGateway) gateway.close();
    }
  }

  bool _isMessagePinned(ChatMessage message) =>
      _pinnedMessages.any((item) => item.message.id == message.id);

  Future<void> _refreshPinnedMessages() async {
    try {
      final items = await widget.coordinator.listPinnedMessages(
        widget.conversation.id,
      );
      if (mounted) setState(() => _pinnedMessages = items);
    } catch (_) {
      // The coordinator/API surface already carries the actionable error.
    }
  }

  Future<void> _forwardMessage(ChatMessage message) async {
    final conversations = widget.coordinator.conversations
        .where(
          (conversation) =>
              conversation.type != 'SELF' &&
              !conversation.preferences.isArchived,
        )
        .toList(growable: false);
    final target = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.72,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: DdColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              '选择转发对象',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: conversations.length + 1,
                itemBuilder: (_, index) {
                  if (index == 0) {
                    return ListTile(
                      key: const Key('forward-target-saved'),
                      leading: const CircleAvatar(
                        backgroundColor: Color(0xFF4E9BEA),
                        child: Icon(
                          Icons.bookmark_rounded,
                          color: Colors.white,
                        ),
                      ),
                      title: const Text('我的收藏'),
                      subtitle: const Text('保存到自己的收藏'),
                      trailing: const Icon(
                        Icons.push_pin_rounded,
                        size: 16,
                        color: DdColors.textTertiary,
                      ),
                      onTap: () => Navigator.pop(sheetContext, 'saved'),
                    );
                  }
                  final conversation = conversations[index - 1];
                  final peer = conversation.peer;
                  return ListTile(
                    key: Key('forward-target-${conversation.id}'),
                    leading: const CircleAvatar(
                      backgroundColor: Color(0xFF6F9FCA),
                      child: Icon(Icons.person_rounded, color: Colors.white),
                    ),
                    title: Text(peer?.displayName ?? '会话'),
                    subtitle: peer?.handle.isNotEmpty == true
                        ? Text('DDID：${peer!.handle}')
                        : null,
                    onTap: () => Navigator.pop(sheetContext, conversation),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    try {
      if (target == 'saved') {
        await widget.coordinator.saveMessage(message);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已保存到我的收藏')));
        return;
      }
      final conversation = target as ConversationItem;
      await widget.coordinator.forwardMessage(message, conversation.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已转发给 ${conversation.peer?.displayName ?? '目标会话'}'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('转发失败：$error')));
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DdRadii.surface),
      ),
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
    if (widget.coordinator.isMessageRecalled(
      widget.conversation.id,
      messageId,
    )) {
      return const SizedBox.shrink();
    }
    return Material(
      color: mine
          ? Colors.white.withValues(alpha: 0.35)
          : const Color(0xFFF3F3F3),
      borderRadius: BorderRadius.circular(DdRadii.control),
      child: InkWell(
        key: Key('reply-reference-$messageId'),
        borderRadius: BorderRadius.circular(DdRadii.control),
        onTap: () => unawaited(_jumpToMessage(messageId)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          child: Text(
            _replyLabel(messageId),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: DdColors.textSecondary),
          ),
        ),
      ),
    );
  }

  String _replyLabel(String messageId) {
    final messages = widget.coordinator.messagesFor(widget.conversation.id);
    for (final message in messages) {
      if (message.id != messageId) continue;
      final text = message.content?.text;
      if (text != null && text.isNotEmpty) return text;
      return switch (message.type) {
        'IMAGE' => '[图片]',
        'GIF' => '[GIF]',
        'STICKER' => '[表情]',
        'STICKER_PACK' => '[表情包]',
        'VOICE' => '[语音]',
        'FILE' => '[文件]',
        _ => '引用消息',
      };
    }
    return '引用消息';
  }

  Future<void> _jumpToMessage(String messageId) async {
    var found = widget.coordinator
        .messagesFor(widget.conversation.id)
        .any((message) => message.id == messageId);
    var pages = 0;
    while (!found &&
        widget.coordinator.canLoadOlder(widget.conversation.id) &&
        pages < 40) {
      await widget.coordinator.loadOlder(widget.conversation.id);
      pages++;
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      found = widget.coordinator
          .messagesFor(widget.conversation.id)
          .any((message) => message.id == messageId);
    }
    if (!mounted) return;
    if (!found) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('原消息已不可见或不在当前历史中。')));
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final targetContext = _messageAnchorKeys[messageId]?.currentContext;
    if (targetContext == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在定位原消息，请再试一次。')));
      return;
    }
    if (!targetContext.mounted) return;
    await Scrollable.ensureVisible(
      targetContext,
      alignment: 0.45,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted && _highlightedMessageId == messageId) {
        setState(() => _highlightedMessageId = null);
      }
    });
  }

  void _scheduleDraftSave() {
    _draftSaveTimer?.cancel();
    if (_editingMessage != null) return;
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

class _StickerTransferDialog extends StatelessWidget {
  const _StickerTransferDialog({
    required this.state,
    required this.fileName,
    required this.onCancel,
  });

  final ValueListenable<MediaTransferState> state;
  final String fileName;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('正在添加表情'),
      content: ValueListenableBuilder<MediaTransferState>(
        valueListenable: state,
        builder: (context, value, _) {
          final progress = value.progress;
          final phase = switch (value.phase) {
            MediaTransferPhase.queued => '等待处理',
            MediaTransferPhase.preparing => '正在压缩 / 检查',
            MediaTransferPhase.uploading => '正在上传',
            MediaTransferPhase.paused => '已暂停',
            MediaTransferPhase.committing => '正在保存表情',
            MediaTransferPhase.done => '已完成',
            MediaTransferPhase.failed => '处理失败',
            MediaTransferPhase.canceled => '已取消',
          };
          return SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: DdColors.divider,
                  color: DdColors.green,
                ),
                const SizedBox(height: 8),
                Text(
                  progress == null
                      ? phase
                      : '$phase · ${(progress * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 12,
                    color: DdColors.textSecondary,
                  ),
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          key: const Key('cancel-custom-sticker-transfer'),
          onPressed: onCancel,
          child: const Text('取消'),
        ),
      ],
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
    return InkWell(
      borderRadius: BorderRadius.circular(DdRadii.control),
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.42,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF303030)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(DdRadii.surface),
                ),
                child: Icon(icon, size: 25),
              ),
              const SizedBox(height: 7),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
