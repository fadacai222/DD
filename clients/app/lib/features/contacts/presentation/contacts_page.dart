import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../moments/presentation/moment_contact_privacy_page.dart';
import '../../moments/presentation/moments_feed_page.dart';
import '../data/contacts_api_client.dart';
import '../domain/contact_models.dart';
import 'contact_tags_page.dart';
import 'peer_profile_page.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.currentUserId,
    this.gateway,
    this.embedded = false,
    this.rootRequestToken = 0,
    this.addFriendRequestToken = 0,
    this.refreshRequestToken = 0,
    this.onUnauthorized,
    this.onOpenDirectChat,
    this.onOpenGroups,
    this.onRefreshGroups,
    this.desktopGroupsContent,
    this.onStartAudioCall,
    this.onStartVideoCall,
  });

  final Uri origin;
  final String accessToken;
  final String currentUserId;
  final ContactsGateway? gateway;
  final bool embedded;
  final int rootRequestToken;
  final int addFriendRequestToken;
  final int refreshRequestToken;
  final Future<String?> Function()? onUnauthorized;
  final Future<void> Function(String peerId, String peerName)? onOpenDirectChat;
  final Future<void> Function()? onOpenGroups;
  final Future<void> Function()? onRefreshGroups;
  final Widget? desktopGroupsContent;
  final Future<void> Function(String peerId, String peerName)? onStartAudioCall;
  final Future<void> Function(String peerId, String peerName)? onStartVideoCall;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage>
    with SingleTickerProviderStateMixin {
  late final ContactsGateway _gateway;
  late final bool _ownsGateway;
  late final TabController _tabs;
  late final TextEditingController _searchHandle;
  late final TextEditingController _directorySearch;

  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  ContactSearchResult? _searchResult;
  List<ContactItem> _contacts = const [];
  List<BlockedUserItem> _blocks = const [];
  String _directoryQuery = '';
  String _desktopSection = 'contacts';
  String? _selectedContactId;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? ContactsApiClient();
    // Mobile should land on the actual address book. Adding a contact is an
    // optional local address-book action, not a prerequisite for chatting.
    _tabs = TabController(length: 3, initialIndex: 1, vsync: this);
    _searchHandle = TextEditingController();
    _directorySearch = TextEditingController();
    _loadAll();
  }

  @override
  void didUpdateWidget(covariant ContactsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootRequestToken != widget.rootRequestToken) {
      _openContactsRoot();
    } else if (oldWidget.addFriendRequestToken !=
        widget.addFriendRequestToken) {
      _openAddFriend();
    } else if (oldWidget.refreshRequestToken != widget.refreshRequestToken) {
      unawaited(_loadAll());
    }
  }

  void _openContactsRoot() {
    _tabs.index = 1;
    _desktopSection = 'contacts';
    _selectedContactId = null;
    if (mounted) setState(() {});
    unawaited(_loadAll());
  }

  void _openAddFriend() {
    _tabs.index = 0;
    _desktopSection = 'add';
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchHandle.dispose();
    _directorySearch.dispose();
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = _pageBody();
    if (widget.embedded) {
      return LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 680) return _desktopContacts();
          return ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Column(
              children: [
                _embeddedHeader(),
                Expanded(child: _mobileEmbeddedBody()),
              ],
            ),
          );
        },
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('联系人'),
        bottom: _tabBar(),
        actions: [
          IconButton(
            key: const Key('contacts-refresh'),
            tooltip: '刷新',
            onPressed: _busy ? null : _loadAll,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }

  Widget _desktopContacts() {
    return Row(
      children: [
        SizedBox(
          key: const Key('desktop-contacts-sidebar'),
          width: DdDesktopTokens.sidebarWidth,
          child: ColoredBox(
            color: DdDesktopTokens.sidebarSurface(
              Theme.of(context).brightness,
            ),
            child: Column(
              children: [
                _desktopDirectoryHeader(),
                const Divider(height: 1, thickness: 0.5),
                Expanded(child: _desktopDirectoryList()),
              ],
            ),
          ),
        ),
        VerticalDivider(
          width: 1,
          thickness: 0.5,
          color: DdDesktopTokens.borderSubtle(Theme.of(context).brightness),
        ),
        Expanded(
          child: ColoredBox(
            color: DdDesktopTokens.contentSurface(Theme.of(context).brightness),
            child: _desktopContactContent(),
          ),
        ),
      ],
    );
  }

  Widget _desktopDirectoryHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: DdDesktopTokens.compactControlHeight,
              child: TextField(
                key: const Key('contacts-directory-search'),
                controller: _directorySearch,
                onChanged: (value) => setState(
                  () => _directoryQuery = value.trim().toLowerCase(),
                ),
                decoration: const InputDecoration(
                  hintText: '搜索',
                  prefixIcon: Icon(Icons.search_rounded, size: 18),
                  prefixIconConstraints: BoxConstraints(minWidth: 34),
                  contentPadding: EdgeInsets.symmetric(vertical: 7),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            tooltip: '添加',
            offset: const Offset(0, 36),
            onSelected: (value) {
              if (value == 'friend') {
                setState(() => _desktopSection = 'add');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                enabled: false,
                value: 'group',
                child: Row(
                  children: [
                    Icon(Icons.chat_bubble_outline_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('发起群聊'),
                    Spacer(),
                    Text(
                      '开发中',
                      style: TextStyle(
                        fontSize: 10,
                        color: DdColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'friend',
                child: Row(
                  children: [
                    Icon(Icons.person_add_alt_1_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('添加联系人'),
                  ],
                ),
              ),
            ],
            child: Container(
              width: DdDesktopTokens.compactControlHeight,
              height: DdDesktopTokens.compactControlHeight,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: DdDesktopTokens.hoverSurface(
                  Theme.of(context).brightness,
                ),
                borderRadius: BorderRadius.circular(DdRadii.control),
              ),
              child: const Icon(Icons.add_rounded, size: 21),
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktopDirectoryList() {
    final contacts = _contacts
        .where((contact) {
          if (_directoryQuery.isEmpty) return true;
          final display = contact.remark.isEmpty
              ? contact.user.displayName
              : contact.remark;
          return display.toLowerCase().contains(_directoryQuery) ||
              contact.user.handle.toLowerCase().contains(_directoryQuery);
        })
        .toList(growable: false);
    final starred = contacts
        .where((item) => item.isStarred)
        .toList(growable: false);

    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        _DirectoryAction(
          key: const Key('desktop-groups-directory'),
          icon: Icons.group_rounded,
          label: '群聊',
          selected: _desktopSection == 'groups',
          onTap: _openDesktopGroups,
        ),
        _DirectoryAction(
          icon: Icons.manage_accounts_outlined,
          label: '通讯录管理',
          selected: _desktopSection == 'manage',
          onTap: () => setState(() => _desktopSection = 'manage'),
        ),
        const SizedBox(height: 6),
        _DirectoryAction(
          icon: Icons.block_outlined,
          label: '黑名单',
          count: _blocks.length,
          selected: _desktopSection == 'blocks',
          onTap: () => setState(() => _desktopSection = 'blocks'),
        ),
        if (starred.isNotEmpty) ...[
          const _DirectoryLabel('星标朋友'),
          for (final contact in starred) _desktopContactRow(contact),
        ],
        const _DirectoryLabel('联系人'),
        if (contacts.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 12, 8),
            child: Text(
              '暂无匹配联系人',
              style: TextStyle(fontSize: 12, color: DdColors.textTertiary),
            ),
          )
        else
          for (final contact in contacts) _desktopContactRow(contact),
      ],
    );
  }

  Widget _desktopContactRow(ContactItem contact) {
    final selected =
        _desktopSection == 'contact' && _selectedContactId == contact.user.id;
    final title = contact.remark.isEmpty
        ? contact.user.displayName
        : contact.remark;
    final brightness = Theme.of(context).brightness;
    return Material(
      color: selected
          ? DdDesktopTokens.selectedSurface(brightness)
          : Colors.transparent,
      child: InkWell(
        hoverColor: DdDesktopTokens.hoverSurface(brightness),
        splashColor: Colors.transparent,
        key: Key('desktop-contact-${contact.user.id}'),
        onTap: () => setState(() {
          _desktopSection = 'contact';
          _selectedContactId = contact.user.id;
        }),
        child: SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11),
            child: Row(
              children: [
                _contactAvatar(contact.user, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopContactContent() {
    return switch (_desktopSection) {
      'add' => _desktopPane('添加联系人', _buildSearchTab()),
      'blocks' => _desktopPane('黑名单', _buildBlocksTab()),
      'manage' => _desktopPane('通讯录管理', _buildContactsTab()),
      'groups' => _desktopPane(
        '群聊',
        widget.desktopGroupsContent ?? _desktopEmptyGroups(),
      ),
      'contact' => _selectedContactDetail(),
      _ => _desktopEmptyContact(),
    };
  }

  void _openDesktopGroups() {
    setState(() {
      _desktopSection = 'groups';
      _selectedContactId = null;
    });
    final refreshGroups = widget.onRefreshGroups;
    if (refreshGroups == null) return;
    unawaited(_refreshDesktopGroups(refreshGroups));
  }

  Future<void> _refreshDesktopGroups(Future<void> Function() refreshGroups) async {
    try {
      await refreshGroups();
    } catch (error) {
      if (!mounted || _desktopSection != 'groups') return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('群聊列表加载失败：$error')),
      );
    }
  }

  Widget _desktopEmptyGroups() => const Center(
    child: Text(
      '暂无群聊',
      style: TextStyle(color: DdColors.textTertiary),
    ),
  );

  Widget _desktopPane(String title, Widget child) {
    return Column(
      children: [
        SizedBox(
          height: 50,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, thickness: 0.5),
        if (_message != null) _buildMessageBar(),
        Expanded(child: child),
      ],
    );
  }

  Widget _selectedContactDetail() {
    ContactItem? selected;
    for (final contact in _contacts) {
      if (contact.user.id == _selectedContactId) {
        selected = contact;
        break;
      }
    }
    if (selected == null) return _desktopEmptyContact();

    final contact = selected;
    final title = contact.remark.isEmpty
        ? contact.user.displayName
        : contact.remark;
    final nickname = contact.user.displayName.trim();
    final handle = contact.user.handle.trim();
    final brightness = Theme.of(context).brightness;
    final surface = Theme.of(context).colorScheme.surface;
    final divider = DdDesktopTokens.borderSubtle(brightness);

    return ColoredBox(
      key: const Key('desktop-contact-detail'),
      color: surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(46, 46, 46, 34),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 470),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _contactAvatar(contact.user, size: 72),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 20,
                                      height: 1.2,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (contact.isStarred) ...[
                                  const SizedBox(width: 6),
                                  const Icon(
                                    Icons.star_rounded,
                                    size: 16,
                                    color: Color(0xFFFFA928),
                                  ),
                                ],
                              ],
                            ),
                            if (contact.remark.isNotEmpty &&
                                nickname.isNotEmpty &&
                                nickname != title) ...[
                              const SizedBox(height: 7),
                              Text(
                                '昵称：$nickname',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: DdColors.textSecondary,
                                ),
                              ),
                            ],
                            const SizedBox(height: 5),
                            Text(
                              handle.isEmpty ? 'DDID：暂不可用' : 'DDID：$handle',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: DdColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    PopupMenuButton<String>(
                      key: const Key('desktop-contact-more'),
                      enabled: !_busy,
                      tooltip: '更多联系人操作',
                      offset: const Offset(0, 34),
                      icon: const Icon(Icons.more_horiz_rounded, size: 22),
                      onSelected: (value) {
                        if (value == 'moment-privacy') {
                          unawaited(_openDesktopMomentPrivacy(contact));
                          return;
                        }
                        unawaited(_contactAction(contact, value));
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'edit',
                          child: Text('备注与标签'),
                        ),
                        PopupMenuItem(
                          value: 'moment-privacy',
                          child: Text('朋友圈权限'),
                        ),
                        PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(
                            '删除联系人',
                            style: TextStyle(color: DdColors.danger),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'block',
                          child: Text(
                            '拉黑',
                            style: TextStyle(color: DdColors.danger),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                Divider(height: 1, thickness: 0.5, color: divider),
                const SizedBox(height: 23),
                const Text(
                  '朋友资料',
                  style: TextStyle(
                    fontSize: 13,
                    color: DdColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                _desktopProfileInfoRow(
                  label: '备注',
                  value: contact.remark.isEmpty ? '未设置' : contact.remark,
                ),
                if (contact.tags.isNotEmpty) ...[
                  const SizedBox(height: 15),
                  _desktopProfileInfoRow(
                    label: '标签',
                    value: contact.tags.join(' · '),
                  ),
                ],
                const SizedBox(height: 24),
                Divider(height: 1, thickness: 0.5, color: divider),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const Key('desktop-contact-moments'),
                    hoverColor: DdDesktopTokens.hoverSurface(brightness),
                    splashColor: Colors.transparent,
                    onTap: _busy
                        ? null
                        : () => unawaited(_openDesktopMoments(contact)),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 19),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 92,
                            child: Text(
                              '朋友圈',
                              style: TextStyle(fontSize: 13.5),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              '查看',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: DdColors.textSecondary,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 19,
                            color: DdColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Divider(height: 1, thickness: 0.5, color: divider),
                const SizedBox(height: 23),
                const Text(
                  '更多信息',
                  style: TextStyle(
                    fontSize: 13,
                    color: DdColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                _desktopProfileInfoRow(
                  label: '个性签名',
                  value: contact.user.bio.trim().isEmpty
                      ? '未设置'
                      : contact.user.bio.trim(),
                ),
                const SizedBox(height: 15),
                _desktopProfileInfoRow(
                  label: '添加时间',
                  value: _formatContactDate(contact.createdAt),
                ),
                if (widget.onOpenDirectChat != null ||
                    widget.onStartAudioCall != null ||
                    widget.onStartVideoCall != null) ...[
                  const SizedBox(height: 32),
                  Divider(height: 1, thickness: 0.5, color: divider),
                  const SizedBox(height: 18),
                  Row(
                    key: const Key('desktop-contact-actions'),
                    children: [
                      if (widget.onOpenDirectChat != null)
                        Expanded(
                          child: _DesktopContactQuickAction(
                            key: const Key('desktop-contact-message'),
                            icon: Icons.chat_bubble_outline_rounded,
                            label: '发消息',
                            onTap: _busy
                                ? null
                                : () => unawaited(
                                    widget.onOpenDirectChat!(
                                      contact.user.id,
                                      title,
                                    ),
                                  ),
                          ),
                        ),
                      if (widget.onStartAudioCall != null)
                        Expanded(
                          child: _DesktopContactQuickAction(
                            key: const Key('desktop-contact-audio'),
                            icon: Icons.call_outlined,
                            label: '语音聊天',
                            onTap: _busy
                                ? null
                                : () => unawaited(
                                    widget.onStartAudioCall!(
                                      contact.user.id,
                                      title,
                                    ),
                                  ),
                          ),
                        ),
                      if (widget.onStartVideoCall != null)
                        Expanded(
                          child: _DesktopContactQuickAction(
                            key: const Key('desktop-contact-video'),
                            icon: Icons.videocam_outlined,
                            label: '视频聊天',
                            onTap: _busy
                                ? null
                                : () => unawaited(
                                    widget.onStartVideoCall!(
                                      contact.user.id,
                                      title,
                                    ),
                                  ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopProfileInfoRow({
    required String label,
    required String value,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13.5,
              color: DdColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, height: 1.35),
          ),
        ),
      ],
    );
  }

  Future<void> _openDesktopMoments(ContactItem contact) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MomentsFeedPage(
          origin: widget.origin,
          accessToken: widget.accessToken,
          currentUserId: widget.currentUserId,
          currentUserDisplayName: '',
          authorId: contact.user.id,
          authorDisplayName: contact.remark.isEmpty
              ? contact.user.displayName
              : contact.remark,
          onUnauthorized: widget.onUnauthorized ?? () async => null,
        ),
      ),
    );
  }

  Future<void> _openDesktopMomentPrivacy(ContactItem contact) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MomentContactPrivacyPage(
          origin: widget.origin,
          accessToken: widget.accessToken,
          targetUserId: contact.user.id,
          targetDisplayName: contact.remark.isEmpty
              ? contact.user.displayName
              : contact.remark,
          onUnauthorized: widget.onUnauthorized ?? () async => null,
        ),
      ),
    );
  }

  static String _formatContactDate(DateTime value) {
    final local = value.toLocal();
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)}';
  }

  Widget _desktopEmptyContact() {
    return const Center(
      child: Opacity(opacity: 0.18, child: Icon(Icons.forum_rounded, size: 78)),
    );
  }

  Widget _embeddedHeader() {
    final root = _tabs.index == 1;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              switch (_tabs.index) {
                0 => '添加联系人',
                2 => '黑名单',
                _ => '联系人',
              },
              key: const Key('contacts-mobile-title'),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (!root)
              Positioned(
                left: 4,
                child: IconButton(
                  key: const Key('contacts-back-to-root'),
                  tooltip: '返回联系人',
                  onPressed: () => _selectMobileTab(1),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
                ),
              ),
            if (root)
              Positioned(
                right: 6,
                child: IconButton(
                  key: const Key('contacts-add-friend'),
                  tooltip: '添加联系人',
                  onPressed: () => _selectMobileTab(0),
                  icon: const Icon(Icons.add_rounded, size: 27),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _mobileEmbeddedBody() {
    if (_tabs.index == 1) return _mobileWechatContacts();
    final content = switch (_tabs.index) {
      0 => _buildSearchTab(),
      2 => _buildBlocksTab(),
      _ => _buildContactsTab(),
    };
    return Column(
      children: [
        if (_message != null) _buildMessageBar(),
        if (_busy) const LinearProgressIndicator(minHeight: 1),
        Expanded(child: content),
      ],
    );
  }

  Widget _mobileWechatContacts() {
    final contacts =
        _contacts
            .where((contact) {
              if (_directoryQuery.isEmpty) return true;
              final display = contact.remark.isEmpty
                  ? contact.user.displayName
                  : contact.remark;
              return display.toLowerCase().contains(_directoryQuery) ||
                  contact.user.handle.toLowerCase().contains(_directoryQuery);
            })
            .toList(growable: false)
          ..sort((a, b) {
            final left = a.remark.isEmpty ? a.user.displayName : a.remark;
            final right = b.remark.isEmpty ? b.user.displayName : b.remark;
            return left.toLowerCase().compareTo(right.toLowerCase());
          });
    final groupedContacts = <String, List<ContactItem>>{};
    for (final contact in contacts) {
      groupedContacts
          .putIfAbsent(_contactSectionKey(contact), () => <ContactItem>[])
          .add(contact);
    }
    final sectionKeys = groupedContacts.keys.toList(growable: false)
      ..sort((a, b) {
        if (a == '#') return 1;
        if (b == '#') return -1;
        return a.compareTo(b);
      });

    return Column(
      children: [
        if (_message != null) _buildMessageBar(),
        if (_busy) const LinearProgressIndicator(minHeight: 1),
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: SizedBox(
              height: 36,
              child: TextField(
                key: const Key('contacts-mobile-search'),
                controller: _directorySearch,
                textAlign: TextAlign.center,
                onChanged: (value) => setState(
                  () => _directoryQuery = value.trim().toLowerCase(),
                ),
                decoration: const InputDecoration(
                  hintText: '搜索',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: DdColors.textSecondary,
                  ),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: DdColors.textSecondary,
                  ),
                  prefixIconConstraints: BoxConstraints(minWidth: 36),
                  suffixIcon: SizedBox(width: 36),
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              _mobileDirectoryAction(
                icon: Icons.group_rounded,
                iconColor: const Color(0xFF07C160),
                label: '群聊',
                onTap: () => unawaited(widget.onOpenGroups?.call()),
              ),
              _mobileDirectoryAction(
                icon: Icons.sell_rounded,
                iconColor: const Color(0xFF2787F5),
                label: '标签',
                onTap: _openContactTags,
              ),
              _mobileDirectoryAction(
                icon: Icons.shield_outlined,
                iconColor: const Color(0xFF576B95),
                label: '黑名单',
                onTap: () => _selectMobileTab(2),
              ),
              Container(
                height: 28,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                color: Theme.of(context).scaffoldBackgroundColor,
                child: const Text(
                  '联系人',
                  style: TextStyle(fontSize: 12, color: DdColors.textSecondary),
                ),
              ),
              if (contacts.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 42),
                  child: Center(
                    child: Text(
                      '暂无联系人',
                      style: TextStyle(color: DdColors.textTertiary),
                    ),
                  ),
                )
              else
                for (final section in sectionKeys) ...[
                  Container(
                    key: Key('contact-section-$section'),
                    height: 24,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: Text(
                      section,
                      style: const TextStyle(
                        fontSize: 11,
                        color: DdColors.textSecondary,
                      ),
                    ),
                  ),
                  for (final contact in groupedContacts[section]!)
                    _mobileContactRow(contact),
                ],
              if (contacts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text(
                      '${contacts.length} 位联系人',
                      style: const TextStyle(
                        fontSize: 12,
                        color: DdColors.textTertiary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _mobileDirectoryAction({
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onTap,
    int count = 0,
  }) {
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
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: iconColor,
                    borderRadius: BorderRadius.circular(DdRadii.control),
                  ),
                  child: Icon(icon, size: 23, color: Colors.white),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 16)),
                ),
                if (count > 0)
                  Container(
                    key: Key('directory-badge-$label'),
                    height: 20,
                    constraints: const BoxConstraints(minWidth: 20),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: DdColors.danger,
                      borderRadius: BorderRadius.circular(DdRadii.pill),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _contactSectionKey(ContactItem contact) {
    final display =
        (contact.remark.isEmpty ? contact.user.displayName : contact.remark)
            .trim();
    if (display.isEmpty) return '#';
    final first = display.characters.first.toUpperCase();
    return RegExp(r'^[A-Z]$').hasMatch(first) ? first : '#';
  }

  Widget _mobileContactRow(ContactItem contact) {
    final title = contact.remark.isEmpty
        ? contact.user.displayName
        : contact.remark;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        key: Key('contact-${contact.user.id}'),
        onTap: () => _openMobileContact(contact),
        child: SizedBox(
          height: 58,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 0, 0),
            child: Row(
              children: [
                _contactAvatar(contact.user, size: 36),
                const SizedBox(width: 13),
                Expanded(
                  child: Container(
                    height: 58,
                    alignment: Alignment.centerLeft,
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: DdColors.divider, width: 0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        if (contact.isStarred) ...[
                          const Icon(
                            Icons.star_rounded,
                            size: 15,
                            color: Color(0xFFFFA928),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _selectMobileTab(int index) {
    _tabs.index = index;
    if (mounted) setState(() {});
  }

  Future<void> _openContactTags() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ContactTagsPage(
          origin: widget.origin,
          accessToken: widget.accessToken,
          contacts: _contacts,
          onOpenContact: _openMobileContact,
        ),
      ),
    );
  }

  Future<void> _openMobileContact(ContactItem contact) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PeerProfilePage(
          origin: widget.origin,
          accessToken: widget.accessToken,
          userId: contact.user.id,
          handle: contact.user.handle,
          displayName: contact.remark.isEmpty
              ? contact.user.displayName
              : contact.remark,
          contact: contact,
          onOpenMoments: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => MomentsFeedPage(
                origin: widget.origin,
                accessToken: widget.accessToken,
                currentUserId: widget.currentUserId,
                currentUserDisplayName: '',
                authorId: contact.user.id,
                authorDisplayName: contact.remark.isEmpty
                    ? contact.user.displayName
                    : contact.remark,
                onUnauthorized: widget.onUnauthorized ?? () async => null,
              ),
            ),
          ),
          onOpenMomentPrivacy: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => MomentContactPrivacyPage(
                origin: widget.origin,
                accessToken: widget.accessToken,
                targetUserId: contact.user.id,
                targetDisplayName: contact.remark.isEmpty
                    ? contact.user.displayName
                    : contact.remark,
                onUnauthorized: widget.onUnauthorized ?? () async => null,
              ),
            ),
          ),
          onMessage: widget.onOpenDirectChat == null
              ? null
              : () async {
                  final navigator = Navigator.of(context);
                  if (navigator.canPop()) navigator.pop();
                  await widget.onOpenDirectChat!(
                    contact.user.id,
                    contact.remark.isEmpty
                        ? contact.user.displayName
                        : contact.remark,
                  );
                },
          onAudioCall: widget.onStartAudioCall == null
              ? null
              : () => widget.onStartAudioCall!(
                  contact.user.id,
                  contact.remark.isEmpty
                      ? contact.user.displayName
                      : contact.remark,
                ),
          onVideoCall: widget.onStartVideoCall == null
              ? null
              : () => widget.onStartVideoCall!(
                  contact.user.id,
                  contact.remark.isEmpty
                      ? contact.user.displayName
                      : contact.remark,
                ),
        ),
      ),
    );
    if (mounted) await _loadAll();
  }

  TabBar _tabBar() {
    return TabBar(
      controller: _tabs,
      isScrollable: true,
      dividerColor: DdColors.divider,
      indicatorColor: DdColors.green,
      labelColor: DdColors.greenPressed,
      unselectedLabelColor: DdColors.textSecondary,
      tabAlignment: TabAlignment.start,
      tabs: const [
        Tab(text: '添加联系人'),
        Tab(text: '联系人'),
        Tab(text: '黑名单'),
      ],
    );
  }

  Widget _pageBody() {
    return Column(
      children: [
        if (_message != null) _buildMessageBar(),
        if (_busy) const LinearProgressIndicator(minHeight: 1),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _buildSearchTab(),
              _buildContactsTab(),
              _buildBlocksTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageBar() {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: _messageIsError
          ? colors.errorContainer
          : colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              _messageIsError
                  ? Icons.error_outline_rounded
                  : Icons.info_outline,
              color: _messageIsError
                  ? colors.onErrorContainer
                  : colors.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _message!,
                style: TextStyle(
                  color: _messageIsError
                      ? colors.onErrorContainer
                      : colors.onSecondaryContainer,
                ),
              ),
            ),
            IconButton(
              tooltip: '关闭提示',
              onPressed: () => setState(() => _message = null),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchTab() {
    final result = _searchResult;
    return _scrollBody(
      children: [
        TextField(
          key: const Key('contacts-search-handle'),
          controller: _searchHandle,
          enabled: !_busy,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            labelText: 'DDID',
            hintText: '例如 alice_01',
            prefixIcon: const Icon(Icons.alternate_email_rounded),
            suffixIcon: IconButton(
              key: const Key('contacts-search-button'),
              tooltip: '搜索',
              onPressed: _busy ? null : _search,
              icon: const Icon(Icons.search_rounded),
            ),
            filled: true,
            fillColor: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF2F2F2F)
                : const Color(0xFFF1F1F1),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DdRadii.input),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DdRadii.input),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DdRadii.input),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (result == null)
          const _EmptyState(
            icon: Icons.person_search_rounded,
            title: '输入完整 DDID 搜索',
            description: '这里不做无上限昵称模糊搜索，也不会暴露邮箱。',
          )
        else
          _UserCard(
            user: result.user,
            leading: _contactAvatar(result.user),
            subtitle: _relationshipText(result.relationship),
            trailing: _searchAction(result),
          ),
      ],
    );
  }

  Widget? _searchAction(ContactSearchResult result) {
    switch (result.relationship) {
      case 'NONE':
      case 'PENDING_INCOMING':
      case 'PENDING_OUTGOING':
        return FilledButton.icon(
          key: const Key('contacts-add-contact'),
          onPressed: _busy ? null : () => _addContact(result),
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('添加到联系人'),
        );
      case 'BLOCKED_BY_PEER':
        return const Text(
          '您无法添加',
          style: TextStyle(color: DdColors.textSecondary),
        );
      case 'BLOCKED_BY_ME':
        return const Text('已拉黑', style: TextStyle(color: DdColors.danger));
      default:
        return null;
    }
  }

  Widget _buildContactsTab() {
    return _scrollBody(
      children: [
        _SectionTitle(title: '联系人', count: _contacts.length),
        if (_contacts.isEmpty)
          const _EmptyState(
            icon: Icons.people_outline_rounded,
            title: '还没有联系人',
            description: '搜索 DDID 后可以直接聊天，也可以一键添加到自己的联系人。',
          )
        else
          for (final contact in _contacts) ...[
            Card(
              child: ListTile(
                key: Key('contact-${contact.user.id}'),
                leading: _contactAvatar(contact.user),
                title: Row(
                  children: [
                    if (contact.isStarred) ...[
                      const Icon(Icons.star_rounded, size: 18),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        contact.remark.isEmpty
                            ? contact.user.displayName
                            : contact.remark,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                subtitle: Text(
                  '@${contact.user.handle}'
                  '${contact.tags.isEmpty ? '' : ' · ${contact.tags.join(' / ')}'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) => _contactAction(contact, value),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('备注 / 标签 / 星标')),
                    PopupMenuItem(value: 'delete', child: Text('删除联系人')),
                    PopupMenuItem(value: 'block', child: Text('拉黑')),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  Widget _buildBlocksTab() {
    return _scrollBody(
      children: [
        _SectionTitle(title: '黑名单', count: _blocks.length),
        if (_blocks.isEmpty)
          const _EmptyState(
            icon: Icons.shield_outlined,
            title: '黑名单为空',
            description: '拉黑后双方不能继续发送消息；解除拉黑后即可恢复聊天。',
          )
        else
          for (final blocked in _blocks) ...[
            _UserCard(
              user: blocked.user,
              leading: _contactAvatar(blocked.user),
              subtitle: '已拉黑',
              trailing: OutlinedButton(
                onPressed: _busy ? null : () => _unblock(blocked),
                child: const Text('解除'),
              ),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  Widget _contactAvatar(ContactUser user, {double size = 40}) {
    return ProfileAvatar(
      origin: widget.origin,
      accessToken: widget.accessToken,
      userId: user.id,
      displayName: user.displayName,
      size: size,
    );
  }

  Widget _scrollBody({required List<Widget> children}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = constraints.maxWidth < 480 ? 12.0 : 22.0;
        return SingleChildScrollView(
          padding: EdgeInsets.all(padding),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadAll() => _run(() async {
    final results = await Future.wait([
      _gateway.listContacts(
        origin: widget.origin,
        accessToken: widget.accessToken,
      ),
      _gateway.listBlocks(
        origin: widget.origin,
        accessToken: widget.accessToken,
      ),
    ]);
    if (!mounted) return;
    setState(() {
      _contacts = (results[0] as RelationshipPage<ContactItem>).items;
      _blocks = (results[1] as RelationshipPage<BlockedUserItem>).items;
    });
  }, showSuccess: false);

  Future<void> _search() => _run(() async {
    final handle = _searchHandle.text.trim();
    if (handle.isEmpty) throw const FormatException('请输入完整 DDID。');
    final result = await _gateway.searchByHandle(
      origin: widget.origin,
      accessToken: widget.accessToken,
      handle: handle,
    );
    if (!mounted) return;
    setState(() => _searchResult = result);
  }, success: '搜索完成。');

  Future<void> _addContact(ContactSearchResult result) => _run(() async {
    await _gateway.addContact(
      origin: widget.origin,
      accessToken: widget.accessToken,
      userId: result.user.id,
    );
    final contacts = await _gateway.listContacts(
      origin: widget.origin,
      accessToken: widget.accessToken,
    );
    if (!mounted) return;
    setState(() {
      _contacts = contacts.items;
      _searchResult = ContactSearchResult(
        user: result.user,
        relationship: 'CONTACT',
      );
    });
  }, success: '已添加到联系人。');

  Future<void> _contactAction(ContactItem contact, String action) async {
    switch (action) {
      case 'edit':
        await _editContact(contact);
      case 'delete':
        if (await _confirm(
          title: '删除联系人？',
          content: '只从你的通讯录中移除，不会删除历史聊天，也不会阻止对方继续给你发消息。',
          confirmLabel: '删除',
        )) {
          await _run(() async {
            await _gateway.deleteContact(
              origin: widget.origin,
              accessToken: widget.accessToken,
              userId: contact.user.id,
            );
            final contacts = await _gateway.listContacts(
              origin: widget.origin,
              accessToken: widget.accessToken,
            );
            if (mounted) setState(() => _contacts = contacts.items);
          }, success: '已从联系人中删除，历史聊天仍保留。');
        }
      case 'block':
        if (await _confirm(
          title: '拉黑这个用户？',
          content: '拉黑后双方不能继续发送消息，同时会从联系人中移除。',
          confirmLabel: '拉黑',
        )) {
          await _run(() async {
            await _gateway.blockUser(
              origin: widget.origin,
              accessToken: widget.accessToken,
              userId: contact.user.id,
            );
            await _loadListsAfterBlockChange();
          }, success: '已拉黑。');
        }
    }
  }

  Future<void> _editContact(ContactItem contact) async {
    final remark = TextEditingController(text: contact.remark);
    final tags = TextEditingController(text: contact.tags.join(', '));
    var starred = contact.isStarred;
    final result = await showDialog<_ContactEditResult>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('编辑 ${contact.user.displayName}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('contact-edit-remark'),
                  controller: remark,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: '备注'),
                ),
                TextField(
                  key: const Key('contact-edit-tags'),
                  controller: tags,
                  decoration: const InputDecoration(
                    labelText: '标签',
                    helperText: '用英文逗号分隔，最多 20 个。',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: starred,
                  onChanged: (value) => setDialogState(() => starred = value),
                  title: const Text('星标联系人'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('contact-edit-save'),
              onPressed: () => Navigator.pop(
                dialogContext,
                _ContactEditResult(
                  remark: remark.text.trim(),
                  isStarred: starred,
                  tags: tags.text
                      .split(',')
                      .map((value) => value.trim())
                      .where((value) => value.isNotEmpty)
                      .toList(growable: false),
                ),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    remark.dispose();
    tags.dispose();
    if (result == null) return;
    await _run(() async {
      await _gateway.updateContact(
        origin: widget.origin,
        accessToken: widget.accessToken,
        userId: contact.user.id,
        remark: result.remark,
        isStarred: result.isStarred,
        tags: result.tags,
      );
      final contacts = await _gateway.listContacts(
        origin: widget.origin,
        accessToken: widget.accessToken,
      );
      if (mounted) setState(() => _contacts = contacts.items);
    }, success: '联系人资料已更新。');
  }

  Future<void> _unblock(BlockedUserItem blocked) => _run(() async {
    await _gateway.unblockUser(
      origin: widget.origin,
      accessToken: widget.accessToken,
      userId: blocked.user.id,
    );
    await _loadListsAfterBlockChange();
  }, success: '已解除拉黑。');

  Future<void> _loadListsAfterBlockChange() async {
    final contacts = await _gateway.listContacts(
      origin: widget.origin,
      accessToken: widget.accessToken,
    );
    final blocks = await _gateway.listBlocks(
      origin: widget.origin,
      accessToken: widget.accessToken,
    );
    if (!mounted) return;
    setState(() {
      _contacts = contacts.items;
      _blocks = blocks.items;
    });
  }

  Future<bool> _confirm({
    required String title,
    required String content,
    required String confirmLabel,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _run(
    Future<void> Function() action, {
    String? success,
    bool showSuccess = true,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      try {
        await action();
      } on ContactsApiException catch (error) {
        if (error.statusCode != 401 || widget.onUnauthorized == null) rethrow;
        final refreshedToken = await widget.onUnauthorized!.call();
        if (refreshedToken == null ||
            refreshedToken.trim().isEmpty ||
            !mounted) {
          rethrow;
        }
        // MainShell keeps this ContactsPage state alive across token rotation,
        // so widget.accessToken is refreshed before the retry runs.
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        await action();
      }
      if (showSuccess && success != null) _setMessage(success);
    } catch (error) {
      _setMessage(_friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setMessage(String value, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = value;
      _messageIsError = error;
    });
  }

  static String _relationshipText(String relationship) =>
      switch (relationship) {
        'SELF' => '这是你自己',
        'CONTACT' => '已在联系人中',
        'BLOCKED_BY_ME' => '你已将对方拉黑',
        'BLOCKED_BY_PEER' => '对方已将你拉黑',
        'PENDING_OUTGOING' || 'PENDING_INCOMING' => '可直接聊天，也可以添加到联系人',
        _ => '可直接聊天',
      };

  static String _friendlyError(Object error) {
    if (error is ContactsApiException) {
      return switch (error.code) {
        'NOT_FOUND' => '没有找到这个用户，或当前关系不可见。',
        'ALREADY_CONTACT' => '已经在联系人中。',
        'BLOCKED' => '您无法添加。',
        'RELATIONSHIP_UNAVAILABLE' => '您无法添加。',
        'RELATIONSHIP_STATE_CONFLICT' => '联系人状态已变化，请刷新。',
        'CONTACTS_RATE_LIMITED' => '操作过于频繁，请稍后再试。',
        'UNAUTHORIZED' => '登录会话已失效，请重新登录。',
        'FORBIDDEN' => '你没有权限操作这条关系记录。',
        _ =>
          '${error.message}${error.requestId == null ? '' : ' · ${error.requestId}'}',
      };
    }
    if (error is FormatException || error is ArgumentError) {
      return error.toString().replaceFirst(
        RegExp(r'^(FormatException|Invalid argument[^:]*):\s*'),
        '',
      );
    }
    return '请求失败：$error';
  }
}

class _DesktopContactQuickAction extends StatelessWidget {
  const _DesktopContactQuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const actionColor = Color(0xFF576B95);
    final enabled = onTap != null;
    final color = enabled ? actionColor : DdColors.textTertiary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(DdRadii.control),
          hoverColor: DdDesktopTokens.hoverSurface(
            Theme.of(context).brightness,
          ),
          splashColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 23, color: color),
                const SizedBox(height: 7),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: color,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _ContactEditResult {
  const _ContactEditResult({
    required this.remark,
    required this.isStarred,
    required this.tags,
  });

  final String remark;
  final bool isStarred;
  final List<String> tags;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        '$title（$count）',
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _DirectoryAction extends StatelessWidget {
  const _DirectoryAction({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count = 0,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected
            ? DdDesktopTokens.selectedSurface(brightness)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(DdRadii.control),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: DdDesktopTokens.hoverSurface(brightness),
          splashColor: Colors.transparent,
          child: SizedBox(
            height: 42,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(icon, size: 18, color: DdColors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 13)),
                ),
                if (count > 0)
                  Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: 11,
                      color: DdColors.textTertiary,
                    ),
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

class _DirectoryLabel extends StatelessWidget {
  const _DirectoryLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 12, 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: 11, color: DdColors.textTertiary),
    ),
  );
}

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.user,
    required this.leading,
    required this.subtitle,
    this.trailing,
  });

  final ContactUser user;
  final Widget leading;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: leading,
        title: Text(user.displayName),
        subtitle: Text('@${user.handle} · $subtitle'),
        trailing: trailing,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 12),
      child: Column(
        children: [
          Icon(icon, size: 46, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(description, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
