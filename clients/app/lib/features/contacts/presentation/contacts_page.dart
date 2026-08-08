import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../data/contacts_api_client.dart';
import '../domain/contact_models.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.currentUserId,
    this.gateway,
    this.embedded = false,
  });

  final Uri origin;
  final String accessToken;
  final String currentUserId;
  final ContactsGateway? gateway;
  final bool embedded;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage>
    with SingleTickerProviderStateMixin {
  late final ContactsGateway _gateway;
  late final bool _ownsGateway;
  late final TabController _tabs;
  late final TextEditingController _searchHandle;
  late final TextEditingController _requestMessage;
  late final TextEditingController _directorySearch;

  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  ContactSearchResult? _searchResult;
  List<ContactRequestItem> _incoming = const [];
  List<ContactRequestItem> _outgoing = const [];
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
    _tabs = TabController(length: 4, vsync: this);
    _searchHandle = TextEditingController();
    _requestMessage = TextEditingController();
    _directorySearch = TextEditingController();
    _loadAll();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchHandle.dispose();
    _requestMessage.dispose();
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
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: _tabBar(),
                ),
                Expanded(child: body),
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
          width: 248,
          child: ColoredBox(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF262626)
                : const Color(0xFFF4F4F4),
            child: Column(
              children: [
                _desktopDirectoryHeader(),
                const Divider(height: 1, thickness: 0.5),
                Expanded(child: _desktopDirectoryList()),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1, thickness: 0.5),
        Expanded(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
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
              height: 34,
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
                    Text('添加朋友'),
                  ],
                ),
              ),
            ],
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF333333)
                    : const Color(0xFFE4E4E4),
                borderRadius: BorderRadius.circular(5),
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
          icon: Icons.manage_accounts_outlined,
          label: '通讯录管理',
          selected: _desktopSection == 'manage',
          onTap: () => setState(() => _desktopSection = 'manage'),
        ),
        const SizedBox(height: 6),
        _DirectoryAction(
          icon: Icons.person_add_alt_1_outlined,
          label: '新的朋友',
          count: _incoming.where((item) => item.status == 'PENDING').length,
          selected: _desktopSection == 'requests',
          onTap: () => setState(() => _desktopSection = 'requests'),
        ),
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
    return Material(
      color: selected
          ? (Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF363636)
                : const Color(0xFFE1E1E1))
          : Colors.transparent,
      child: InkWell(
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
      'add' => _desktopPane('添加朋友', _buildSearchTab()),
      'requests' => _desktopPane('新的朋友', _buildRequestsTab()),
      'blocks' => _desktopPane('黑名单', _buildBlocksTab()),
      'manage' => _desktopPane('通讯录管理', _buildContactsTab()),
      'contact' => _selectedContactDetail(),
      _ => _desktopEmptyContact(),
    };
  }

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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _contactAvatar(contact.user, size: 72),
              const SizedBox(height: 14),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '@${contact.user.handle}',
                style: const TextStyle(color: DdColors.textSecondary),
              ),
              if (contact.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  contact.tags.join(' · '),
                  style: const TextStyle(
                    fontSize: 12,
                    color: DdColors.textTertiary,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _editContact(contact),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('备注与标签'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _contactAction(contact, 'block'),
                    icon: const Icon(Icons.block_outlined, size: 18),
                    label: const Text('拉黑'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _desktopEmptyContact() {
    return const Center(
      child: Opacity(opacity: 0.18, child: Icon(Icons.forum_rounded, size: 78)),
    );
  }

  Widget _embeddedHeader() {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '联系人',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                key: const Key('contacts-refresh'),
                tooltip: '刷新',
                onPressed: _busy ? null : _loadAll,
                icon: const Icon(Icons.refresh_rounded, size: 21),
              ),
            ],
          ),
        ),
      ),
    );
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
        Tab(text: '添加朋友'),
        Tab(text: '新的朋友'),
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
              _buildRequestsTab(),
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
            labelText: '精确账号短号',
            hintText: 'alice_01',
            prefixIcon: const Icon(Icons.alternate_email_rounded),
            suffixIcon: IconButton(
              key: const Key('contacts-search-button'),
              tooltip: '搜索',
              onPressed: _busy ? null : _search,
              icon: const Icon(Icons.search_rounded),
            ),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('contacts-request-message'),
          controller: _requestMessage,
          enabled: !_busy,
          maxLength: 200,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: '申请理由（可选）',
            hintText: '你好，我是……',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        if (result == null)
          const _EmptyState(
            icon: Icons.person_search_rounded,
            title: '输入完整账号短号搜索',
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
        return FilledButton.icon(
          key: const Key('contacts-send-request'),
          onPressed: _busy ? null : _sendRequest,
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: const Text('加好友'),
        );
      case 'PENDING_INCOMING':
        return FilledButton.tonal(
          onPressed: () {
            _tabs.animateTo(1);
          },
          child: const Text('去处理'),
        );
      default:
        return null;
    }
  }

  Widget _buildRequestsTab() {
    return _scrollBody(
      children: [
        _SectionTitle(title: '收到的申请', count: _incoming.length),
        if (_incoming.isEmpty)
          const _EmptyLine(text: '暂无收到的申请')
        else
          for (final request in _incoming) ...[
            _RequestCard(
              request: request,
              incoming: true,
              leading: _contactAvatar(request.sender),
              busy: _busy,
              onAccept: request.status == 'PENDING'
                  ? () => _accept(request)
                  : null,
              onReject: request.status == 'PENDING'
                  ? () => _reject(request)
                  : null,
            ),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 20),
        _SectionTitle(title: '发出的申请', count: _outgoing.length),
        if (_outgoing.isEmpty)
          const _EmptyLine(text: '暂无发出的申请')
        else
          for (final request in _outgoing) ...[
            _RequestCard(
              request: request,
              incoming: false,
              leading: _contactAvatar(request.receiver),
              busy: _busy,
              onCancel: request.status == 'PENDING'
                  ? () => _cancel(request)
                  : null,
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _buildContactsTab() {
    return _scrollBody(
      children: [
        _SectionTitle(title: '联系人', count: _contacts.length),
        if (_contacts.isEmpty)
          const _EmptyState(
            icon: Icons.people_outline_rounded,
            title: '还没有好友',
            description: '从“搜索”页按账号短号添加好友。',
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
                    PopupMenuItem(value: 'delete', child: Text('删除好友')),
                    PopupMenuItem(value: 'block', child: Text('拉黑并删除好友')),
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
            description: '拉黑会立即删除双方好友关系并取消待处理申请。',
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
      _gateway.listRequests(
        origin: widget.origin,
        accessToken: widget.accessToken,
        direction: 'incoming',
      ),
      _gateway.listRequests(
        origin: widget.origin,
        accessToken: widget.accessToken,
        direction: 'outgoing',
      ),
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
      _incoming = (results[0] as RelationshipPage<ContactRequestItem>).items;
      _outgoing = (results[1] as RelationshipPage<ContactRequestItem>).items;
      _contacts = (results[2] as RelationshipPage<ContactItem>).items;
      _blocks = (results[3] as RelationshipPage<BlockedUserItem>).items;
    });
  }, showSuccess: false);

  Future<void> _search() => _run(() async {
    final handle = _searchHandle.text.trim();
    if (handle.isEmpty) throw const FormatException('请输入完整账号短号。');
    final result = await _gateway.searchByHandle(
      origin: widget.origin,
      accessToken: widget.accessToken,
      handle: handle,
    );
    if (!mounted) return;
    setState(() => _searchResult = result);
  }, success: '搜索完成。');

  Future<void> _sendRequest() => _run(() async {
    final result = await _gateway.sendRequest(
      origin: widget.origin,
      accessToken: widget.accessToken,
      targetHandle: _searchHandle.text.trim(),
      message: _requestMessage.text,
    );
    _requestMessage.clear();
    await _reloadRelationshipLists();
    if (!mounted) return;
    setState(() {
      final current = _searchResult;
      if (current != null) {
        _searchResult = ContactSearchResult(
          user: current.user,
          relationship: result.status == 'ACCEPTED'
              ? 'CONTACT'
              : 'PENDING_OUTGOING',
        );
      }
    });
  }, success: '好友申请已处理。');

  Future<void> _accept(ContactRequestItem request) => _run(() async {
    await _gateway.acceptRequest(
      origin: widget.origin,
      accessToken: widget.accessToken,
      requestId: request.id,
    );
    await _reloadRelationshipLists();
  }, success: '已接受好友申请。');

  Future<void> _reject(ContactRequestItem request) => _run(() async {
    await _gateway.rejectRequest(
      origin: widget.origin,
      accessToken: widget.accessToken,
      requestId: request.id,
    );
    await _reloadRelationshipLists();
  }, success: '已拒绝好友申请。');

  Future<void> _cancel(ContactRequestItem request) => _run(() async {
    await _gateway.cancelRequest(
      origin: widget.origin,
      accessToken: widget.accessToken,
      requestId: request.id,
    );
    await _reloadRelationshipLists();
  }, success: '已撤销好友申请。');

  Future<void> _reloadRelationshipLists() async {
    final incoming = await _gateway.listRequests(
      origin: widget.origin,
      accessToken: widget.accessToken,
      direction: 'incoming',
    );
    final outgoing = await _gateway.listRequests(
      origin: widget.origin,
      accessToken: widget.accessToken,
      direction: 'outgoing',
    );
    final contacts = await _gateway.listContacts(
      origin: widget.origin,
      accessToken: widget.accessToken,
    );
    if (!mounted) return;
    setState(() {
      _incoming = incoming.items;
      _outgoing = outgoing.items;
      _contacts = contacts.items;
    });
  }

  Future<void> _contactAction(ContactItem contact, String action) async {
    switch (action) {
      case 'edit':
        await _editContact(contact);
      case 'delete':
        if (await _confirm(
          title: '删除好友？',
          content: '会删除双方好友关系，但保留历史会话数据。',
          confirmLabel: '删除',
        )) {
          await _run(() async {
            await _gateway.deleteContact(
              origin: widget.origin,
              accessToken: widget.accessToken,
              userId: contact.user.id,
            );
            await _reloadRelationshipLists();
          }, success: '好友关系已删除。');
        }
      case 'block':
        if (await _confirm(
          title: '拉黑这个用户？',
          content: '拉黑会立即删除双方好友关系，并取消双方尚未处理的好友申请。',
          confirmLabel: '拉黑',
        )) {
          await _run(() async {
            await _gateway.blockUser(
              origin: widget.origin,
              accessToken: widget.accessToken,
              userId: contact.user.id,
            );
            await _loadListsAfterBlockChange();
          }, success: '已拉黑并删除好友关系。');
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
                  title: const Text('星标好友'),
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
    final incoming = await _gateway.listRequests(
      origin: widget.origin,
      accessToken: widget.accessToken,
      direction: 'incoming',
    );
    final outgoing = await _gateway.listRequests(
      origin: widget.origin,
      accessToken: widget.accessToken,
      direction: 'outgoing',
    );
    if (!mounted) return;
    setState(() {
      _contacts = contacts.items;
      _blocks = blocks.items;
      _incoming = incoming.items;
      _outgoing = outgoing.items;
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
      await action();
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
        'CONTACT' => '已经是好友',
        'PENDING_OUTGOING' => '好友申请已发送',
        'PENDING_INCOMING' => '对方已经向你发送好友申请',
        _ => '尚未添加好友',
      };

  static String _friendlyError(Object error) {
    if (error is ContactsApiException) {
      return switch (error.code) {
        'NOT_FOUND' => '没有找到这个用户，或当前关系不可见。',
        'ALREADY_CONTACT' => '你们已经是好友。',
        'RELATIONSHIP_UNAVAILABLE' => '当前关系状态不允许执行这个操作。',
        'RELATIONSHIP_STATE_CONFLICT' => '这个好友申请已经被处理或状态已变化，请刷新。',
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
    return Material(
      color: selected
          ? (Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF363636)
                : const Color(0xFFE1E1E1))
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
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

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.incoming,
    required this.leading,
    required this.busy,
    this.onAccept,
    this.onReject,
    this.onCancel,
  });

  final ContactRequestItem request;
  final bool incoming;
  final Widget leading;
  final bool busy;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final user = incoming ? request.sender : request.receiver;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text('@${user.handle} · ${request.status}'),
                    ],
                  ),
                ),
              ],
            ),
            if (request.message.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(request.message),
            ],
            if (onAccept != null || onReject != null || onCancel != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onAccept != null)
                    FilledButton(
                      onPressed: busy ? null : onAccept,
                      child: const Text('接受'),
                    ),
                  if (onReject != null)
                    OutlinedButton(
                      onPressed: busy ? null : onReject,
                      child: const Text('拒绝'),
                    ),
                  if (onCancel != null)
                    OutlinedButton(
                      onPressed: busy ? null : onCancel,
                      child: const Text('撤销申请'),
                    ),
                ],
              ),
            ],
          ],
        ),
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

class _EmptyLine extends StatelessWidget {
  const _EmptyLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}
