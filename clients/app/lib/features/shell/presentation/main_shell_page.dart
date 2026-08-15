import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../../core/media/avatar_crop_page.dart';
import '../../../core/media/avatar_image_processor.dart';
import '../../../core/media/image_viewer_page.dart';
import '../../../core/media/media_cache_budget.dart';
import '../../../core/media/profile_avatar_picker.dart';
import '../../../core/notifications/app_notification_service.dart';
import '../../../core/performance/app_performance_store.dart';
import '../../../core/sound/app_sound_service.dart';
import '../../../core/theme/app_theme_mode_store.dart';
import '../../../core/widgets/dd_floating_navigation_bar.dart';
import '../../../theme/app_theme.dart';
import '../../auth/data/auth_api_client.dart';
import '../../auth/domain/account_management.dart';
import '../../auth/domain/auth_session.dart';
import '../../auth/presentation/account_management_page.dart';
import '../../auth/presentation/performance_settings_page.dart';
import '../../auth/presentation/personal_profile_page.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../calls/domain/call_session.dart';
import '../../calls/presentation/call_debug_controller.dart';
import '../../calls/presentation/chat_call_page.dart';
import '../../calls/presentation/two_party_call_controller.dart';
import '../../contacts/data/contacts_api_client.dart';
import '../../contacts/domain/contact_models.dart';
import '../../contacts/presentation/contacts_page.dart';
import '../../contacts/presentation/peer_profile_page.dart';
import '../../messaging/application/messaging_coordinator.dart';
import '../../messaging/data/chat_appearance_store.dart';
import '../../messaging/domain/emoji_catalog.dart';
import '../../messaging/domain/sticker_models.dart';
import '../../messaging/presentation/chat_background_settings_page.dart';
import '../../messaging/presentation/conversations_page.dart';
import '../../messaging/presentation/conversations_page_controller.dart';
import '../../messaging/presentation/desktop_video_pip.dart';
import '../../messaging/presentation/group_chats_page.dart';
import '../../messaging/presentation/media_storage_settings_page.dart';
import '../../messaging/presentation/saved_messages_page.dart';
import '../../messaging/presentation/sticker_library_sheet.dart';
import '../../messaging/presentation/text_chat_page.dart';
import '../../messaging/presentation/transfer_center_page.dart';
import '../../moments/application/moment_activity_controller.dart';
import '../../moments/data/moments_api_client.dart';
import '../../moments/presentation/moment_contact_privacy_page.dart';
import '../../moments/presentation/moments_feed_page.dart';
import '../../push/application/push_navigation_intent.dart';
import '../../push/application/push_registration_service.dart';
import '../../qrcode/presentation/my_qr_page.dart';
import '../../qrcode/presentation/qr_scanner_page.dart';

class MainShellPage extends StatefulWidget {
  const MainShellPage({
    super.key,
    required this.origin,
    required this.session,
    required this.authGateway,
    required this.onRefreshSession,
    required this.onProfileChanged,
    required this.onManageAccounts,
    required this.onLogout,
  });

  final Uri origin;
  final AuthSession session;
  final AuthGateway authGateway;
  final Future<String?> Function() onRefreshSession;
  final Future<void> Function(AccountProfile profile) onProfileChanged;
  final Future<void> Function() onManageAccounts;
  final Future<void> Function() onLogout;

  @override
  State<MainShellPage> createState() => _MainShellPageState();
}

class _MainShellPageState extends State<MainShellPage>
    with WidgetsBindingObserver {
  int _index = 0;
  int _contactsRootRequestToken = 0;
  int _contactsAddFriendRequestToken = 0;
  int _contactsRefreshRequestToken = 0;
  late final MessagingCoordinator _messagingCoordinator;
  late final ConversationsPageController _conversationsController;
  late final AppNotificationService _notificationService;
  StreamSubscription<IncomingMessageNotice>? _incomingMessageSubscription;
  StreamSubscription<RelationshipNotice>? _relationshipSubscription;
  StreamSubscription<String>? _eventAvailableReasonSubscription;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  late final CallDebugController _callMediaController;
  late final TwoPartyCallController _callController;
  late final PushRegistrationService _pushRegistrationService;
  Object? _pushCallbackOwner;
  late final MomentsApiClient _momentsApi;
  late final MomentActivityController _momentActivityController;
  late final Future<bool> _callStartup;
  bool _callRouteOpen = false;
  int _avatarRevision = 0;
  bool _avatarBusy = false;
  bool _notificationPreviewEnabled = true;
  OverlayEntry? _messageBanner;
  Timer? _messageBannerTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _conversationsController = ConversationsPageController();
    _messagingCoordinator = MessagingCoordinator(
      origin: widget.origin,
      accessToken: widget.session.tokens.accessToken,
      currentUserId: widget.session.user.id,
      deviceId: widget.session.device.id,
      onUnauthorized: widget.onRefreshSession,
    );
    unawaited(MediaCacheBudgetStore.shared(widget.session.user.id).load());
    unawaited(_refreshNotificationPreviewPreference());
    _notificationService = AppNotificationService.shared;
    unawaited(_notificationService.initialize(requestPermission: false));
    _callMediaController = CallDebugController();
    _callController = TwoPartyCallController(
      _callMediaController,
      accessTokenProvider: () async => widget.session.tokens.accessToken,
    );
    _callController.addListener(_handleCallState);
    _callStartup = _callController.start(
      apiBaseUrl: widget.origin.toString(),
      participantIdentity: widget.session.user.id,
      participantName: widget.session.user.displayName,
    );
    _pushRegistrationService = PushRegistrationService.shared;
    _pushCallbackOwner = _pushRegistrationService.bindCallbacks(
      onNotificationOpened: _handlePushNotificationOpened,
      onNotificationReceived: _handlePushNotificationReceived,
    );
    unawaited(
      _pushRegistrationService.start(
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
        userId: widget.session.user.id,
        deviceId: widget.session.device.id,
      ),
    );
    _incomingMessageSubscription = _messagingCoordinator.incomingMessages
        .listen(_handleIncomingMessage);
    _relationshipSubscription = _messagingCoordinator.relationshipNotices
        .listen(_handleRelationshipNotice);
    _momentsApi = MomentsApiClient();
    _momentActivityController = MomentActivityController(
      origin: widget.origin,
      accessToken: widget.session.tokens.accessToken,
      gateway: _momentsApi,
    );
    _messagingCoordinator.addListener(_syncNotificationBadge);
    _momentActivityController.addListener(_syncNotificationBadge);
    _eventAvailableReasonSubscription = _messagingCoordinator
        .eventAvailableReasons
        .listen(_handleEventAvailableReason);
    unawaited(_momentActivityController.refresh());
    unawaited(_messagingCoordinator.initialize());
  }

  void _handleEventAvailableReason(String reason) {
    _momentActivityController.handleRealtimeReason(reason);
    _callController.handleRealtimeReason(reason);
  }

  @override
  void didUpdateWidget(covariant MainShellPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldToken = oldWidget.session.tokens.accessToken;
    final nextToken = widget.session.tokens.accessToken;
    if (oldToken != nextToken) {
      unawaited(_messagingCoordinator.updateAccessToken(nextToken));
      _callController.updateAccessToken(nextToken);
      _momentActivityController.updateAccessToken(nextToken);
      unawaited(_momentActivityController.refresh());
      unawaited(
        _pushRegistrationService.updateSession(
          origin: widget.origin,
          accessToken: nextToken,
          userId: widget.session.user.id,
          deviceId: widget.session.device.id,
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      unawaited(_momentActivityController.refresh());
      unawaited(_messagingCoordinator.onAppResumed());
      unawaited(_pushRegistrationService.onAppResumed());
      unawaited(_recoverCallFromExternalSignal(clearWhenMissing: true));
      _syncNotificationBadge();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_incomingMessageSubscription?.cancel());
    unawaited(_relationshipSubscription?.cancel());
    unawaited(_eventAvailableReasonSubscription?.cancel());
    _messageBannerTimer?.cancel();
    _messageBanner?.remove();
    _messageBanner = null;
    _messagingCoordinator.removeListener(_syncNotificationBadge);
    _momentActivityController.removeListener(_syncNotificationBadge);
    _messagingCoordinator.dispose();
    _momentActivityController.dispose();
    _momentsApi.close();
    _conversationsController.dispose();
    _callController.removeListener(_handleCallState);
    _callController.dispose();
    _callMediaController.dispose();
    final pushCallbackOwner = _pushCallbackOwner;
    if (pushCallbackOwner != null) {
      _pushRegistrationService.unbindCallbacks(pushCallbackOwner);
    }
    _pushCallbackOwner = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 720;
          final pages = _buildPages();
          final pageStack = IndexedStack(index: _index, children: pages);
          if (desktop) {
            return Stack(
              fit: StackFit.expand,
              children: [
                Row(
                  children: [
                    AnimatedBuilder(
                      animation: _messagingCoordinator,
                      builder: (context, _) => _DesktopRail(
                        origin: widget.origin,
                        session: widget.session,
                        avatarRevision: _avatarRevision,
                        unreadCount: _messagingCoordinator.totalUnreadCount,
                        momentActivityController: _momentActivityController,
                        selectedIndex: _index,
                        onSelected: _selectMainSection,
                        onSettings: _openAccountManagement,
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 0.5,
                      color: DdDesktopTokens.borderSubtle(
                        Theme.of(context).brightness,
                      ),
                    ),
                    Expanded(child: SafeArea(left: false, child: pageStack)),
                  ],
                ),
                const DesktopVideoPipHost(),
              ],
            );
          }
          return SafeArea(
            bottom: false,
            child: Column(
              children: [
                Expanded(child: pageStack),
                DdFloatingNavigationBar(
                  selectedIndex: _index,
                  hidden: keyboardVisible,
                  onDestinationSelected: _selectMainSection,
                  destinations: [
                    DdFloatingNavigationDestination(
                      icon: _UnreadNavigationIcon(
                        coordinator: _messagingCoordinator,
                        icon: Icons.chat_bubble_outline_rounded,
                      ),
                      selectedIcon: _UnreadNavigationIcon(
                        coordinator: _messagingCoordinator,
                        icon: Icons.chat_bubble_rounded,
                      ),
                      label: 'DD',
                    ),
                    const DdFloatingNavigationDestination(
                      icon: Icon(Icons.people_outline_rounded),
                      selectedIcon: Icon(Icons.people_rounded),
                      label: '联系人',
                    ),
                    DdFloatingNavigationDestination(
                      icon: _MomentActivityNavigationIcon(
                        controller: _momentActivityController,
                        icon: Icons.explore_outlined,
                      ),
                      selectedIcon: _MomentActivityNavigationIcon(
                        controller: _momentActivityController,
                        icon: Icons.explore_rounded,
                      ),
                      label: '发现',
                    ),
                    const DdFloatingNavigationDestination(
                      icon: Icon(Icons.person_outline_rounded),
                      selectedIcon: Icon(Icons.person_rounded),
                      label: '我的',
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _handlePushNotificationReceived(Map<String, dynamic> data) {
    final intent = PushNavigationIntent.fromData(
      data,
      currentUserId: widget.session.user.id,
    );
    if (intent.target == PushNavigationTarget.ignored) return;
    if (intent.target == PushNavigationTarget.call) {
      unawaited(_recoverCallFromExternalSignal());
      return;
    }
    if (intent.target == PushNavigationTarget.moments) {
      unawaited(_momentActivityController.refresh());
      return;
    }
    if (intent.target == PushNavigationTarget.conversation) {
      // Foreground iOS system presentation is suppressed; Sync/realtime remains
      // the single app-visible truth path and avoids a duplicate local banner.
      unawaited(_messagingCoordinator.syncNow());
    }
  }

  void _handlePushNotificationOpened(Map<String, dynamic> data) {
    unawaited(_routePushNotification(data));
  }

  Future<void> _routePushNotification(Map<String, dynamic> data) async {
    final intent = PushNavigationIntent.fromData(
      data,
      currentUserId: widget.session.user.id,
    );
    if (!mounted || intent.target == PushNavigationTarget.ignored) return;

    switch (intent.target) {
      case PushNavigationTarget.conversation:
        setState(() => _index = 0);
        await _messagingCoordinator.syncNow();
        if (!mounted) return;
        final conversation = await _messagingCoordinator.resolveConversation(
          intent.conversationId,
        );
        if (!mounted) return;
        if (conversation == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('通知对应的会话已不存在或当前账号无权访问。')),
          );
          return;
        }
        _conversationsController.openConversation(conversation.id);
      case PushNavigationTarget.call:
        await _recoverCallFromExternalSignal();
      case PushNavigationTarget.moments:
        setState(() => _index = 2);
        await _momentActivityController.refresh();
        if (!mounted) return;
        await _openMoments();
      case PushNavigationTarget.generic:
        setState(() => _index = 0);
        await _messagingCoordinator.syncNow();
      case PushNavigationTarget.ignored:
        return;
    }
  }

  Future<void> _recoverCallFromExternalSignal({
    bool clearWhenMissing = false,
  }) async {
    final ready = await _callStartup;
    if (!mounted || !ready) return;
    await _callController.recoverFromExternalSignal(
      clearWhenMissing: clearWhenMissing,
    );
  }

  void _syncNotificationBadge() {
    if (!mounted) return;
    final count =
        _messagingCoordinator.totalUnreadCount +
        _momentActivityController.unreadCount;
    unawaited(_pushRegistrationService.setBadgeCount(count));
  }

  void _selectMainSection(int value) {
    setState(() {
      _index = value;
      if (value == 1) _contactsRootRequestToken++;
    });
  }

  void _openAddFriend() {
    setState(() {
      _index = 1;
      _contactsAddFriendRequestToken++;
    });
  }

  List<Widget> _buildPages() {
    return [
      ConversationsPage(
        key: ValueKey(
          'shell-messages-${widget.session.user.id}-${widget.session.device.id}',
        ),
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
        currentUserId: widget.session.user.id,
        deviceId: widget.session.device.id,
        currentUserDisplayName: widget.session.user.displayName,
        currentUserAvatarRevision: _avatarRevision,
        coordinator: _messagingCoordinator,
        navigationController: _conversationsController,
        hostVisible: _index == 0,
        onStartCall: _startCall,
        onOpenContacts: () => _selectMainSection(1),
        onOpenAddFriend: _openAddFriend,
        onOpenScanner: _openQrScanner,
        embedded: true,
      ),
      ContactsPage(
        key: ValueKey(
          'shell-contacts-${widget.session.user.id}-${widget.session.device.id}',
        ),
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
        currentUserId: widget.session.user.id,
        embedded: true,
        rootRequestToken: _contactsRootRequestToken,
        addFriendRequestToken: _contactsAddFriendRequestToken,
        refreshRequestToken: _contactsRefreshRequestToken,
        onUnauthorized: widget.onRefreshSession,
        onOpenDirectChat: _openDirectChatFromContacts,
        onOpenGroups: _openGroupDirectory,
        onRefreshGroups: _refreshGroupDirectory,
        desktopGroupsContent: AnimatedBuilder(
          animation: _messagingCoordinator,
          builder: (context, _) => GroupChatsPage(
            origin: widget.origin,
            accessToken: widget.session.tokens.accessToken,
            conversations: _messagingCoordinator.conversations,
            embedded: true,
            onOpenConversation: (conversation) async {
              if (!mounted) return;
              setState(() => _index = 0);
              _conversationsController.openConversation(conversation.id);
            },
          ),
        ),
        onStartAudioCall: (peerId, peerName) =>
            _startCall(peerId, peerName, CallKind.audio),
        onStartVideoCall: (peerId, peerName) =>
            _startCall(peerId, peerName, CallKind.video),
        onContactsChanged: _messagingCoordinator.refreshConversations,
      ),
      _DiscoveryPage(
        activityController: _momentActivityController,
        onOpenMoments: _openMoments,
        onOpenScanner: _openQrScanner,
        onOpenStickers: _openStickerManagement,
      ),
      _MePage(
        origin: widget.origin,
        session: widget.session,
        avatarRevision: _avatarRevision,
        avatarBusy: _avatarBusy,
        onOpenProfile: _openPersonalProfile,
        onOpenSaved: _openSavedMessagesFromMe,
        onOpenMyQr: _openMyQr,
        onManageAccounts: widget.onManageAccounts,
        onOpenPrivacyAndDevices: _openAccountManagement,
        onOpenAppearance: _openAppearance,
        onOpenChatBackground: _openChatBackgroundSettings,
        onOpenMediaAndCache: _openMediaStorageSettings,
        onOpenPerformance: _openPerformanceSettings,
        onOpenTransferCenter: _openTransferCenter,
        onLogout: widget.onLogout,
      ),
    ];
  }

  void _handleIncomingMessage(IncomingMessageNotice notice) {
    if (!mounted) return;
    if (notice.messageType == 'SYSTEM' && notice.preview == '我刚刚同意了你的好友请求') {
      setState(() => _contactsRefreshRequestToken++);
    }
    if (notice.muted) return;
    final alreadyReading =
        _index == 0 &&
        _messagingCoordinator.activeConversationId == notice.conversationId;
    if (alreadyReading) return;
    final appIsForeground = _lifecycleState == AppLifecycleState.resumed;
    final iosSystemOwnsBackgroundMessageNotification =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && !appIsForeground;
    if (iosSystemOwnsBackgroundMessageNotification) {
      // APNs/FCM owns the background/killed system notification on iOS. Do not
      // add a second local notification or a second app-side sound.
      return;
    }
    unawaited(AppSoundService.shared.playMessageNotification());

    if (appIsForeground) {
      _showIncomingMessageBanner(
        notice,
        hidePreview: !_notificationPreviewEnabled,
      );
      return;
    }

    final notificationTitle = notice.mentionedCurrentUser
        ? '${notice.senderName} 提到了你'
        : notice.senderName;
    unawaited(
      _notificationService.showMessage(
        senderName: notificationTitle,
        preview: notice.preview,
        conversationId: notice.conversationId,
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
        senderUserId: notice.senderUserId,
      ),
    );
  }

  void _handleRelationshipNotice(RelationshipNotice notice) {
    if (!mounted) return;
    setState(() => _contactsRefreshRequestToken++);
    if (_lifecycleState == AppLifecycleState.resumed) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(notice.message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    unawaited(
      _notificationService.showMessage(
        senderName: 'DD',
        preview: notice.message,
        conversationId: 'relationship:${notice.peerUserId}',
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
        senderUserId: notice.peerUserId.isEmpty ? null : notice.peerUserId,
      ),
    );
  }

  void _showIncomingMessageBanner(
    IncomingMessageNotice notice, {
    required bool hidePreview,
  }) {
    if (!mounted) return;
    _messageBannerTimer?.cancel();
    _messageBanner?.remove();
    final overlay = Overlay.of(context);
    final topInset = MediaQuery.paddingOf(context).top;
    final preview = hidePreview
        ? '你收到了一条新消息'
        : notice.preview.trim().isEmpty
        ? '新消息'
        : notice.preview.trim();
    final title = hidePreview
        ? 'DD'
        : notice.mentionedCurrentUser
        ? '${notice.senderName} 提到了你'
        : notice.senderName;
    _messageBanner = OverlayEntry(
      builder: (overlayContext) => Positioned(
        left: 12,
        right: 12,
        top: topInset + 8,
        child: SafeArea(
          top: false,
          child: Material(
            color: Colors.transparent,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: -18, end: 0),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              builder: (context, offset, child) =>
                  Transform.translate(offset: Offset(0, offset), child: child),
              child: Material(
                elevation: 7,
                shadowColor: Colors.black26,
                borderRadius: BorderRadius.circular(DdRadii.surface),
                color: Theme.of(overlayContext).colorScheme.surface,
                child: InkWell(
                  borderRadius: BorderRadius.circular(DdRadii.surface),
                  onTap: () {
                    _messageBannerTimer?.cancel();
                    _messageBanner?.remove();
                    _messageBanner = null;
                    if (mounted) setState(() => _index = 0);
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      children: [
                        ProfileAvatar(
                          origin: widget.origin,
                          accessToken: widget.session.tokens.accessToken,
                          userId: notice.senderUserId,
                          displayName: notice.senderName,
                          size: 42,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: DdColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_messageBanner!);
    _messageBannerTimer = Timer(const Duration(seconds: 3), () {
      _messageBanner?.remove();
      _messageBanner = null;
    });
  }

  void _handleCallState() {
    if (!mounted) return;
    final call = _callController.currentCall;
    if (call == null) return;

    if (!call.isIncomingFor(widget.session.user.id) || _callRouteOpen) return;
    scheduleMicrotask(() {
      if (!mounted || _callRouteOpen) return;
      unawaited(_openCallPage(call.callerName));
    });
  }

  Future<void> _refreshGroupDirectory() =>
      _messagingCoordinator.refreshConversations();

  Future<void> _openGroupDirectory() async {
    try {
      await _refreshGroupDirectory();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => GroupChatsPage(
            origin: widget.origin,
            accessToken: widget.session.tokens.accessToken,
            conversations: _messagingCoordinator.conversations,
            onOpenConversation: (conversation) async {
              if (!mounted) return;
              Navigator.of(context).pop();
              setState(() => _index = 0);
              _conversationsController.openConversation(conversation.id);
            },
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('群聊列表加载失败：$error')));
    }
  }

  Future<void> _openDirectChatFromContacts(
    String peerId,
    String peerName,
  ) async {
    try {
      final conversation = await _messagingCoordinator.ensureDirectConversation(
        peerId,
      );
      if (!mounted) return;
      setState(() => _index = 0);
      _conversationsController.openConversation(conversation.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开与 $peerName 的会话：$error')));
    }
  }

  Future<void> _openMoments() async {
    unawaited(_momentActivityController.markRead());
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MomentsFeedPage(
          origin: widget.origin,
          accessToken: widget.session.tokens.accessToken,
          currentUserId: widget.session.user.id,
          currentUserDisplayName: widget.session.user.displayName,
          currentUserAvatarRevision: _avatarRevision,
          onUnauthorized: widget.onRefreshSession,
        ),
      ),
    );
  }

  Future<void> _openPeerMoments(String userId, String displayName) async {
    final normalized = userId.trim();
    if (normalized.isEmpty || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MomentsFeedPage(
          origin: widget.origin,
          accessToken: widget.session.tokens.accessToken,
          currentUserId: widget.session.user.id,
          currentUserDisplayName: widget.session.user.displayName,
          authorId: normalized,
          authorDisplayName: displayName,
          onUnauthorized: widget.onRefreshSession,
        ),
      ),
    );
  }

  Future<void> _openPeerMomentPrivacy(String userId, String displayName) async {
    final normalized = userId.trim();
    if (normalized.isEmpty || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MomentContactPrivacyPage(
          origin: widget.origin,
          accessToken: widget.session.tokens.accessToken,
          targetUserId: normalized,
          targetDisplayName: displayName,
          onUnauthorized: widget.onRefreshSession,
        ),
      ),
    );
  }

  Future<void> _openMyQr() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MyQrPage(
          origin: widget.origin,
          accessToken: widget.session.tokens.accessToken,
          userId: widget.session.user.id,
          displayName: widget.session.user.displayName,
          handle: widget.session.user.handle,
          avatarRevision: _avatarRevision,
          onUnauthorized: widget.onRefreshSession,
        ),
      ),
    );
  }

  Future<void> _openQrScanner() async {
    final result = await Navigator.of(context).push<QrScanResult>(
      MaterialPageRoute<QrScanResult>(
        fullscreenDialog: true,
        builder: (_) => QrScannerPage(
          origin: widget.origin,
          accessToken: widget.session.tokens.accessToken,
          onUnauthorized: widget.onRefreshSession,
        ),
      ),
    );
    if (!mounted || result == null) return;
    switch (result.kind) {
      case QrScanResultKind.user:
        final userId = result.userId;
        if (userId != null) await _openScannedUser(userId);
      case QrScanResultKind.group:
        final group = result.group;
        if (group == null) return;
        await _messagingCoordinator.refreshConversations();
        if (!mounted) return;
        setState(() => _index = 0);
        _conversationsController.openConversation(group.id);
      case QrScanResultKind.loginApproved:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已确认新设备登录。')));
    }
  }

  Future<void> _openScannedUser(String userId) async {
    final client = ContactsApiClient();
    try {
      var token = widget.session.tokens.accessToken;
      ContactSearchResult result;
      try {
        result = await client.getUserById(
          origin: widget.origin,
          accessToken: token,
          userId: userId,
        );
      } on ContactsApiException catch (error) {
        if (error.statusCode != 401) rethrow;
        final refreshed = await widget.onRefreshSession();
        if (refreshed == null || refreshed.isEmpty) rethrow;
        token = refreshed;
        result = await client.getUserById(
          origin: widget.origin,
          accessToken: token,
          userId: userId,
        );
      }
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => PeerProfilePage(
            origin: widget.origin,
            accessToken: token,
            userId: result.user.id,
            handle: result.user.handle,
            displayName: result.user.displayName,
            onContactUpdated: _messagingCoordinator.refreshConversations,
            onOpenMoments: result.relationship == 'CONTACT'
                ? () =>
                      _openPeerMoments(result.user.id, result.user.displayName)
                : null,
            onOpenMomentPrivacy: result.relationship == 'CONTACT'
                ? () => _openPeerMomentPrivacy(
                    result.user.id,
                    result.user.displayName,
                  )
                : null,
            onMessage: result.user.id == widget.session.user.id
                ? null
                : () => _openDirectChatFromContacts(
                    result.user.id,
                    result.user.displayName,
                  ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法打开二维码用户资料：$error')));
    } finally {
      client.close();
    }
  }

  Future<void> _openSavedMessagesFromMe() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SavedMessagesPage(
          coordinator: _messagingCoordinator,
          onOpenMessage: (message) async {
            final conversation = await _messagingCoordinator
                .resolveConversation(message.conversationId);
            if (!mounted || conversation == null) return;
            await Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => TextChatPage(
                  coordinator: _messagingCoordinator,
                  conversation: conversation,
                  currentUserId: widget.session.user.id,
                  currentUserDisplayName: widget.session.user.displayName,
                  currentUserAvatarRevision: _avatarRevision,
                  onStartCall: _startCall,
                  initialMessageId: message.id,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _startCall(String peerId, String peerName, CallKind kind) async {
    final ready = await _callStartup;
    if (!mounted) return;
    if (!ready || !_callController.signalingConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_callController.errorMessage ?? '通话服务尚未连接，请稍后再试。'),
        ),
      );
      return;
    }
    if (_callController.currentCall?.isActive == true) {
      await _openCallPage(peerName);
      return;
    }
    await _callController.placeCall(calleeIdentity: peerId, kind: kind);
    if (!mounted) return;
    if (_callController.currentCall == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_callController.errorMessage ?? '无法发起通话。')),
      );
      return;
    }
    await _openCallPage(peerName);
  }

  Future<void> _openCallPage(String peerName) async {
    if (_callRouteOpen || !mounted) return;
    _callRouteOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => ChatCallPage(
            controller: _callController,
            mediaController: _callMediaController,
            peerName: peerName,
            peerId: _callController.peerIdentity,
            origin: widget.origin,
            accessToken: widget.session.tokens.accessToken,
          ),
        ),
      );
    } finally {
      _callRouteOpen = false;
    }
  }

  Future<void> _changeAvatar() async {
    if (_avatarBusy) return;
    XFile? file;
    try {
      file = await pickProfileAvatarImage();
    } on PlatformException catch (error) {
      if (!mounted) return;
      if (error.code == 'PHOTO_LIBRARY_PERMISSION_DENIED') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('没有照片权限，请在系统设置中允许 DD 访问照片。'),
            action: SnackBarAction(
              label: '去设置',
              onPressed: () => unawaited(openProfileAvatarPickerSettings()),
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择头像失败：${error.message ?? error.code}')),
        );
      }
      return;
    }
    if (file == null || !mounted) return;
    final sourceLength = await file.length();
    if (!mounted) return;
    if (sourceLength > maxAvatarSourceBytes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('源图片超过 64 MiB，为避免设备内存耗尽暂不处理。')),
      );
      return;
    }
    setState(() => _avatarBusy = true);
    try {
      final source = await file.readAsBytes();
      final preview = await prepareAvatarCropPreview(source);
      if (!mounted) return;
      final crop = await Navigator.of(context).push<AvatarCropSelection>(
        MaterialPageRoute<AvatarCropSelection>(
          fullscreenDialog: true,
          builder: (_) => AvatarCropPage(preview: preview),
        ),
      );
      if (crop == null || !mounted) return;
      final processed = await processAvatarImage(source, crop: crop);
      final updatedAt = await widget.authGateway.uploadProfileAvatar(
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
        bytes: processed.bytes,
        contentType: processed.contentType,
      );
      ProfileAvatar.evict(widget.origin, widget.session.user.id);
      if (!mounted) return;
      setState(() => _avatarRevision = updatedAt.microsecondsSinceEpoch);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('头像已更新')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('头像更新失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _viewAvatar() async {
    if (!mounted) return;
    final avatarUrl = widget.origin.resolve(
      '/api/v1/avatars/${widget.session.user.id}',
    );
    final client = http.Client();
    try {
      Future<http.Response> fetch(String token) => client.get(
        avatarUrl,
        headers: <String, String>{
          'Accept': 'image/avif,image/webp,image/png,image/jpeg,*/*',
          'Authorization': 'Bearer $token',
        },
      );

      var response = await fetch(widget.session.tokens.accessToken);
      if (response.statusCode == 401) {
        final refreshed = await widget.onRefreshSession();
        if (refreshed != null && refreshed.isNotEmpty) {
          response = await fetch(refreshed);
        }
      }
      if (!mounted) return;
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂无可查看的头像。')));
        return;
      }
      final mimeType = (response.headers['content-type'] ?? 'image/jpeg')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      final extension = switch (mimeType) {
        'image/png' => 'png',
        'image/webp' => 'webp',
        'image/avif' => 'avif',
        _ => 'jpg',
      };
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => ImageViewerPage(
            bytes: response.bodyBytes,
            mimeType: mimeType,
            suggestedName: 'DD-avatar-${widget.session.user.handle}.$extension',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('头像加载失败，请稍后重试。')));
      }
    } finally {
      client.close();
    }
  }

  Future<void> _removeAvatar() async {
    if (_avatarBusy) return;
    setState(() => _avatarBusy = true);
    try {
      await widget.authGateway.deleteProfileAvatar(
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
      );
      ProfileAvatar.evict(widget.origin, widget.session.user.id);
      if (!mounted) return;
      setState(() => _avatarRevision = DateTime.now().microsecondsSinceEpoch);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('头像已移除')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移除头像失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _openPersonalProfile() async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PersonalProfilePage(
          gateway: widget.authGateway,
          origin: widget.origin,
          session: widget.session,
          avatarRevision: _avatarRevision,
          onViewAvatar: _viewAvatar,
          onChangeAvatar: _changeAvatar,
          onRemoveAvatar: _removeAvatar,
          onProfileChanged: (me) => widget.onProfileChanged(me.profile),
          onOpenMyQr: _openMyQr,
        ),
      ),
    );
  }

  Future<void> _openAppearance() async {
    final store = AppThemeModeStore.shared;
    unawaited(store.load());
    final selected = await showModalBottomSheet<ThemeMode>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '外观',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          for (final option in const <(ThemeMode, String, IconData)>[
            (ThemeMode.system, '跟随系统', Icons.brightness_auto_outlined),
            (ThemeMode.light, '浅色', Icons.light_mode_outlined),
            (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
          ])
            ListTile(
              key: Key('theme-mode-${option.$1.name}'),
              leading: Icon(option.$3),
              title: Text(option.$2),
              trailing: store.mode == option.$1
                  ? const Icon(Icons.check_rounded, color: DdColors.green)
                  : null,
              onTap: () => Navigator.pop(sheetContext, option.$1),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
    if (selected == null || selected == store.mode) return;
    try {
      await store.setMode(selected);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('外观设置保存失败，请重试。')),
      );
    }
  }

  Future<void> _openChatBackgroundSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatBackgroundSettingsPage(
          store: ChatAppearanceStore.shared(widget.session.user.id),
        ),
      ),
    );
  }

  Future<void> _openMediaStorageSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MediaStorageSettingsPage(userId: widget.session.user.id),
      ),
    );
  }

  Future<void> _openPerformanceSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PerformanceSettingsPage(store: AppPerformanceStore.shared),
      ),
    );
  }

  Future<void> _openTransferCenter() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TransferCenterPage(
          controller: _messagingCoordinator.mediaTransfers,
        ),
      ),
    );
  }

  Future<Uint8List> _stickerMediaBytes(String mediaId) async {
    final mediaApi = _messagingCoordinator.transferMediaApi;
    final grant = await _messagingCoordinator.withAuthorizedToken(
      (token) => mediaApi.createDownloadUrl(
        origin: widget.origin,
        accessToken: token,
        mediaId: mediaId,
      ),
    );
    return mediaApi.downloadMedia(url: grant.url);
  }

  Future<Uri> _stickerMediaUrl(String mediaId, int expectedSizeBytes) async {
    final grant = await _messagingCoordinator.withAuthorizedToken(
      (token) => _messagingCoordinator.transferMediaApi.createDownloadUrl(
        origin: widget.origin,
        accessToken: token,
        mediaId: mediaId,
      ),
    );
    return grant.url;
  }

  Future<void> _openStickerManagement() async {
    await showModalBottomSheet<StickerPanelResult>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => StickerLibrarySheet(
        origin: widget.origin,
        accessToken: _messagingCoordinator.accessToken,
        emoji: EmojiCatalog.all,
        emojiCategories: EmojiCatalog.categories,
        recentEmoji: _messagingCoordinator.recentEmoji,
        mediaBytesLoader: _stickerMediaBytes,
        mediaUrlResolver: _stickerMediaUrl,
        onAddCustomSticker: (_) async => null,
        allowCustomStickerCreation: false,
        initialTabKey: 'custom',
        onTabChanged: (tabKey) =>
            unawaited(_messagingCoordinator.rememberStickerPanelTab(tabKey)),
      ),
    );
  }

  Future<void> _refreshNotificationPreviewPreference() async {
    try {
      final me = await widget.authGateway.getMe(
        origin: widget.origin,
        accessToken: widget.session.tokens.accessToken,
      );
      if (!mounted) return;
      setState(
        () => _notificationPreviewEnabled =
            me.privacy.notificationPreviewEnabled,
      );
    } catch (_) {
      // Keep the last known/default privacy value. The authenticated settings
      // screen and the next successful refresh will reconcile it.
    }
  }

  Future<void> _openAccountManagement() async {
    final logout = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => AccountManagementPage(
          gateway: widget.authGateway,
          origin: widget.origin,
          session: widget.session,
          onPushPreferencesChanged:
              _pushRegistrationService.handlePreferencesChanged,
          onCurrentDeviceAuthoritativelyRevoked: _pushRegistrationService
              .abandonCurrentEndpointLeaseAfterAuthoritativeRevocation,
        ),
      ),
    );
    if (logout == true && mounted) {
      await widget.onLogout();
      return;
    }
    await _refreshNotificationPreviewPreference();
  }
}

class _DesktopRail extends StatelessWidget {
  const _DesktopRail({
    required this.origin,
    required this.session,
    required this.avatarRevision,
    required this.unreadCount,
    required this.momentActivityController,
    required this.selectedIndex,
    required this.onSelected,
    required this.onSettings,
  });

  final Uri origin;
  final AuthSession session;
  final int avatarRevision;
  final int unreadCount;
  final MomentActivityController momentActivityController;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Material(
      color: DdDesktopTokens.navigationSurface(brightness),
      child: SizedBox(
        key: const Key('shell-desktop-rail'),
        width: DdDesktopTokens.navigationWidth,
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 16),
              Tooltip(
                message: session.user.displayName,
                child: _RailAvatar(
                  origin: origin,
                  accessToken: session.tokens.accessToken,
                  userId: session.user.id,
                  name: session.user.displayName,
                  revision: avatarRevision,
                ),
              ),
              const SizedBox(height: 22),
              _RailButton(
                key: const Key('shell-rail-messages'),
                icon: Icons.chat_bubble_outline_rounded,
                selectedIcon: Icons.chat_bubble_rounded,
                label: '消息',
                badgeCount: unreadCount,
                selected: selectedIndex == 0,
                onTap: () => onSelected(0),
              ),
              _RailButton(
                key: const Key('shell-rail-contacts'),
                icon: Icons.people_outline_rounded,
                selectedIcon: Icons.people_rounded,
                label: '联系人',
                selected: selectedIndex == 1,
                onTap: () => onSelected(1),
              ),
              AnimatedBuilder(
                animation: momentActivityController,
                builder: (context, _) => _RailButton(
                  key: const Key('shell-rail-discovery'),
                  icon: Icons.explore_outlined,
                  selectedIcon: Icons.explore_rounded,
                  label: '发现',
                  badgeCount: momentActivityController.unreadCount,
                  selected: selectedIndex == 2,
                  onTap: () => onSelected(2),
                ),
              ),
              const Spacer(),
              _RailButton(
                key: const Key('shell-rail-me'),
                icon: Icons.person_outline_rounded,
                selectedIcon: Icons.person_rounded,
                label: '我的',
                selected: selectedIndex == 3,
                onTap: () => onSelected(3),
              ),
              _RailButton(
                key: const Key('shell-rail-settings'),
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings_rounded,
                label: '设置',
                selected: false,
                onTap: onSettings,
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadNavigationIcon extends StatelessWidget {
  const _UnreadNavigationIcon({required this.coordinator, required this.icon});

  final MessagingCoordinator coordinator;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: coordinator,
      builder: (context, _) => Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon),
          if (coordinator.totalUnreadCount > 0)
            Positioned(
              right: -9,
              top: -7,
              child: _UnreadBadge(count: coordinator.totalUnreadCount),
            ),
        ],
      ),
    );
  }
}

class _MomentActivityNavigationIcon extends StatelessWidget {
  const _MomentActivityNavigationIcon({
    required this.controller,
    required this.icon,
  });

  final MomentActivityController controller;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon),
          if (controller.unreadCount > 0)
            Positioned(
              right: -9,
              top: -7,
              child: _UnreadBadge(count: controller.unreadCount),
            ),
        ],
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final text = count > 99 ? '99+' : '$count';
    final diameter = text.length >= 3 ? 24.0 : (text.length == 2 ? 20.0 : 16.0);
    return SizedBox.square(
      dimension: diameter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: DdColors.danger,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white,
              fontSize: text.length >= 3 ? 8 : 9,
              height: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    super.key,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badgeCount = 0,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int badgeCount;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final foreground = selected
        ? DdColors.greenPressed
        : DdDesktopTokens.navigationIcon(brightness);
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 450),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 8),
        child: Material(
          color: selected
              ? DdDesktopTokens.selectedSurface(brightness)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            hoverColor: DdDesktopTokens.hoverSurface(brightness),
            splashColor: Colors.transparent,
            highlightColor: DdDesktopTokens.hoverSurface(brightness),
            child: SizedBox(
              key: Key('shell-rail-item-$label'),
              width: DdDesktopTokens.navigationItemExtent,
              height: DdDesktopTokens.navigationItemExtent,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 120),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    child: Icon(
                      selected ? selectedIcon : icon,
                      key: ValueKey<bool>(selected),
                      size: 23,
                      color: foreground,
                    ),
                  ),
                  if (selected)
                    Positioned(
                      left: 0,
                      child: Container(
                        width: 3,
                        height: 18,
                        decoration: BoxDecoration(
                          color: DdDesktopTokens.activeIndicator(brightness),
                          borderRadius: BorderRadius.circular(DdRadii.pill),
                        ),
                      ),
                    ),
                  if (badgeCount > 0)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: _UnreadBadge(count: badgeCount),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailAvatar extends StatelessWidget {
  const _RailAvatar({
    required this.origin,
    required this.accessToken,
    required this.userId,
    required this.name,
    this.revision = 0,
    this.size = 38,
  });

  final Uri origin;
  final String accessToken;
  final String userId;
  final String name;
  final int revision;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ProfileAvatar(
      origin: origin,
      accessToken: accessToken,
      userId: userId,
      displayName: name,
      revision: revision,
      size: size,
      fallbackColor: const Color(0xFF6EBB5A),
    );
  }
}

class _DiscoveryPage extends StatelessWidget {
  const _DiscoveryPage({
    required this.activityController,
    required this.onOpenMoments,
    required this.onOpenScanner,
    required this.onOpenStickers,
  });

  final MomentActivityController activityController;
  final Future<void> Function() onOpenMoments;
  final Future<void> Function() onOpenScanner;
  final Future<void> Function() onOpenStickers;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          _SimpleHeader(title: '发现'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 10),
              children: [
                _FeatureRow(
                  key: const Key('discovery-moments'),
                  icon: Icons.camera_alt_outlined,
                  label: '朋友圈',
                  trailing: '',
                  trailingWidget: AnimatedBuilder(
                    animation: activityController,
                    builder: (context, _) => activityController.unreadCount > 0
                        ? _UnreadBadge(count: activityController.unreadCount)
                        : const SizedBox.shrink(),
                  ),
                  onTap: () => unawaited(onOpenMoments()),
                ),
                const SizedBox(height: 8),
                _FeatureRow(
                  key: const Key('discovery-qr-scanner'),
                  icon: Icons.qr_code_scanner_rounded,
                  label: '扫一扫',
                  trailing: '',
                  onTap: () => unawaited(onOpenScanner()),
                ),
                const SizedBox(height: 8),
                _FeatureRow(
                  key: const Key('discovery-stickers'),
                  icon: Icons.emoji_emotions_outlined,
                  label: '表情',
                  trailing: '',
                  onTap: () => unawaited(onOpenStickers()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    super.key,
    required this.icon,
    required this.label,
    required this.trailing,
    this.trailingWidget,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String trailing;
  final Widget? trailingWidget;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 58,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(icon, color: DdColors.greenPressed, size: 23),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 15)),
                ),
                if (trailingWidget != null)
                  trailingWidget!
                else if (trailing.isNotEmpty)
                  Text(
                    trailing,
                    style: const TextStyle(
                      fontSize: 11,
                      color: DdColors.textTertiary,
                    ),
                  ),
                const SizedBox(width: 5),
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
}

class _MePage extends StatelessWidget {
  const _MePage({
    required this.origin,
    required this.session,
    required this.avatarRevision,
    required this.avatarBusy,
    required this.onOpenProfile,
    required this.onOpenSaved,
    required this.onOpenMyQr,
    required this.onManageAccounts,
    required this.onOpenPrivacyAndDevices,
    required this.onOpenAppearance,
    required this.onOpenChatBackground,
    required this.onOpenMediaAndCache,
    required this.onOpenPerformance,
    required this.onOpenTransferCenter,
    required this.onLogout,
  });

  final Uri origin;
  final AuthSession session;
  final int avatarRevision;
  final bool avatarBusy;
  final Future<void> Function() onOpenProfile;
  final Future<void> Function() onOpenSaved;
  final Future<void> Function() onOpenMyQr;
  final Future<void> Function() onManageAccounts;
  final VoidCallback onOpenPrivacyAndDevices;
  final Future<void> Function() onOpenAppearance;
  final Future<void> Function() onOpenChatBackground;
  final Future<void> Function() onOpenMediaAndCache;
  final Future<void> Function() onOpenPerformance;
  final Future<void> Function() onOpenTransferCenter;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          const _SimpleHeader(title: '我的'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 10, bottom: 18),
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: InkWell(
                    key: const Key('shell-open-profile'),
                    onTap: avatarBusy ? null : () => unawaited(onOpenProfile()),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 22, 14, 22),
                      child: Row(
                        children: [
                          Stack(
                            alignment: Alignment.center,
                            children: [
                              _RailAvatar(
                                origin: origin,
                                accessToken: session.tokens.accessToken,
                                userId: session.user.id,
                                name: session.user.displayName,
                                revision: avatarRevision,
                                size: 58,
                              ),
                              if (avatarBusy)
                                Container(
                                  width: 58,
                                  height: 58,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.38),
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  session.user.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  'DDID：${session.user.handle}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: DdColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            key: const Key('shell-open-my-qr'),
                            tooltip: '我的二维码',
                            onPressed: () => unawaited(onOpenMyQr()),
                            icon: const Icon(
                              Icons.qr_code_2_rounded,
                              size: 22,
                              color: DdColors.textSecondary,
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
                const SizedBox(height: 8),
                _SettingsRow(
                  key: const Key('shell-saved-messages'),
                  icon: Icons.bookmark_rounded,
                  label: '我的收藏',
                  onTap: () => onOpenSaved(),
                ),
                const SizedBox(height: 8),
                _SettingsRow(
                  key: const Key('shell-account-management'),
                  icon: Icons.manage_accounts_outlined,
                  label: '账号管理',
                  onTap: () => onManageAccounts(),
                ),
                _SettingsRow(
                  key: const Key('shell-privacy-devices'),
                  icon: Icons.privacy_tip_outlined,
                  label: '隐私与设备',
                  onTap: onOpenPrivacyAndDevices,
                ),
                const SizedBox(height: 8),
                _SettingsRow(
                  key: const Key('shell-appearance'),
                  icon: Icons.brightness_6_outlined,
                  label: '外观',
                  onTap: () => onOpenAppearance(),
                ),
                _SettingsRow(
                  key: const Key('shell-chat-background'),
                  icon: Icons.wallpaper_rounded,
                  label: '聊天背景',
                  onTap: () => onOpenChatBackground(),
                ),
                _SettingsRow(
                  key: const Key('shell-media-cache'),
                  icon: Icons.storage_rounded,
                  label: '媒体与缓存',
                  onTap: () => onOpenMediaAndCache(),
                ),
                _SettingsRow(
                  key: const Key('shell-performance'),
                  icon: Icons.speed_rounded,
                  label: '性能',
                  onTap: () => onOpenPerformance(),
                ),
                _SettingsRow(
                  key: const Key('shell-transfer-center'),
                  icon: Icons.swap_vert_circle_outlined,
                  label: '传输中心',
                  onTap: () => onOpenTransferCenter(),
                ),
                const SizedBox(height: 8),
                _SettingsRow(
                  key: const Key('shell-logout'),
                  icon: Icons.logout_rounded,
                  label: '退出登录',
                  destructive: true,
                  onTap: () => onLogout(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: destructive ? DdColors.danger : DdColors.greenPressed,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      color: destructive ? DdColors.danger : null,
                    ),
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
}

class _SimpleHeader extends StatelessWidget {
  const _SimpleHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}
