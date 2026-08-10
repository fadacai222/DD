import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/logging/client_log.dart';
import '../../../core/widgets/dd_profile_edit_field.dart';
import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../data/contacts_api_client.dart';
import '../domain/contact_models.dart';

class PeerProfilePage extends StatefulWidget {
  const PeerProfilePage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.userId,
    required this.handle,
    required this.displayName,
    this.onMessage,
    this.onAudioCall,
    this.onVideoCall,
    this.onOpenMoments,
    this.onOpenMomentPrivacy,
    this.contact,
    this.gateway,
  });

  final Uri origin;
  final String accessToken;
  final String userId;
  final String handle;
  final String displayName;
  final Future<void> Function()? onMessage;
  final Future<void> Function()? onAudioCall;
  final Future<void> Function()? onVideoCall;
  final Future<void> Function()? onOpenMoments;
  final Future<void> Function()? onOpenMomentPrivacy;
  final ContactItem? contact;
  final ContactsGateway? gateway;

  @override
  State<PeerProfilePage> createState() => _PeerProfilePageState();
}

class _PeerProfilePageState extends State<PeerProfilePage> {
  late final ContactsGateway _client;
  late final bool _ownsClient;
  ContactSearchResult? _result;
  ContactItem? _contact;
  ContactRequestItem? _pendingIncomingRequest;
  Object? _error;
  bool _unavailable = false;
  bool _contactBusy = false;
  bool _managementBusy = false;

  @override
  void initState() {
    super.initState();
    _ownsClient = widget.gateway == null;
    _client = widget.gateway ?? ContactsApiClient();
    _contact = widget.contact;
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await _loadRelationship();
      ContactItem? contact = _contact;
      ContactRequestItem? incomingRequest;
      if (result.relationship == 'CONTACT' && contact == null) {
        final page = await _client.listContacts(
          origin: widget.origin,
          accessToken: widget.accessToken,
        );
        for (final item in page.items) {
          if (item.user.id == widget.userId) {
            contact = item;
            break;
          }
        }
      } else if (result.relationship == 'PENDING_INCOMING') {
        contact = null;
        try {
          final requests = await _client.listRequests(
            origin: widget.origin,
            accessToken: widget.accessToken,
            direction: 'incoming',
          );
          for (final request in requests.items) {
            if (request.sender.id == widget.userId) {
              incomingRequest = request;
              break;
            }
          }
        } catch (_) {}
      } else if (result.relationship != 'CONTACT') {
        contact = null;
      }
      if (!mounted) return;
      setState(() {
        _result = result;
        _contact = contact;
        _pendingIncomingRequest = incomingRequest;
        _error = null;
        _unavailable = false;
      });
    } catch (error) {
      if (!mounted) return;
      final unavailable =
          error is ContactsApiException && error.statusCode == 404;
      setState(() {
        _error = error;
        _unavailable = unavailable;
        if (unavailable) {
          _result = null;
          _contact = null;
          _pendingIncomingRequest = null;
        }
      });
    }
  }

  Future<ContactSearchResult> _loadRelationship() async {
    try {
      return await _client.getUserById(
        origin: widget.origin,
        accessToken: widget.accessToken,
        userId: widget.userId,
      );
    } on ContactsApiException catch (error, stackTrace) {
      if (error.statusCode != 404) rethrow;

      // Older development servers did not expose the stable-id profile route.
      // Recover only when another authenticated relationship endpoint proves
      // that the exact same user still exists. A real block still remains 404
      // because blocking removes the contact pair and handle lookup is hidden.
      final handle = widget.handle.trim();
      if (handle.isNotEmpty) {
        try {
          final fallback = await _client.searchByHandle(
            origin: widget.origin,
            accessToken: widget.accessToken,
            handle: handle,
          );
          if (fallback.user.id == widget.userId) {
            unawaited(
              ClientLog.info(
                'peer-profile stable-id lookup returned 404; recovered via exact handle userId=${widget.userId}',
              ),
            );
            return fallback;
          }
        } catch (fallbackError, fallbackStackTrace) {
          unawaited(
            ClientLog.error(
              'peer-profile exact-handle fallback failed userId=${widget.userId}',
              error: fallbackError,
              stackTrace: fallbackStackTrace,
            ),
          );
        }
      }

      try {
        final page = await _client.listContacts(
          origin: widget.origin,
          accessToken: widget.accessToken,
        );
        for (final item in page.items) {
          if (item.user.id == widget.userId) {
            unawaited(
              ClientLog.info(
                'peer-profile stable-id lookup returned 404; recovered from contact list userId=${widget.userId}',
              ),
            );
            return ContactSearchResult(
              user: item.user,
              relationship: 'CONTACT',
            );
          }
        }
      } catch (fallbackError, fallbackStackTrace) {
        unawaited(
          ClientLog.error(
            'peer-profile contact-list fallback failed userId=${widget.userId}',
            error: fallbackError,
            stackTrace: fallbackStackTrace,
          ),
        );
      }

      unawaited(
        ClientLog.error(
          'peer-profile stable-id lookup unavailable userId=${widget.userId} code=${error.code} status=${error.statusCode}',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }
  }

  Future<void> _openAvatarViewer(String displayName) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfileAvatarViewerPage(
          origin: widget.origin,
          accessToken: widget.accessToken,
          userId: widget.userId,
          displayName: displayName,
        ),
      ),
    );
  }

  Future<void> _addContact() async {
    if (_contactBusy) return;
    setState(() => _contactBusy = true);
    try {
      final contact = await _client.addContact(
        origin: widget.origin,
        accessToken: widget.accessToken,
        userId: widget.userId,
      );
      if (!mounted) return;
      setState(() {
        _contact = contact;
        final user = _result?.user;
        if (user != null) {
          _result = ContactSearchResult(user: user, relationship: 'CONTACT');
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已添加到联系人')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('添加联系人失败：$error')));
    } finally {
      if (mounted) setState(() => _contactBusy = false);
    }
  }

  Future<void> _acceptIncomingRequest() async {
    final request = _pendingIncomingRequest;
    if (_contactBusy || request == null) return;
    setState(() => _contactBusy = true);
    try {
      await _client.acceptRequest(
        origin: widget.origin,
        accessToken: widget.accessToken,
        requestId: request.id,
      );
      if (!mounted) return;
      setState(() {
        _pendingIncomingRequest = null;
        final user = _result?.user;
        if (user != null) {
          _result = ContactSearchResult(user: user, relationship: 'CONTACT');
        }
      });
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已通过好友申请')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('通过好友申请失败：$error')));
    } finally {
      if (mounted) setState(() => _contactBusy = false);
    }
  }

  bool get _isContact => _result?.relationship == 'CONTACT' || _contact != null;
  bool get _blockedByMe => _result?.relationship == 'BLOCKED_BY_ME';
  bool get _blockedByPeer => _result?.relationship == 'BLOCKED_BY_PEER';
  bool get _canCommunicate =>
      !_unavailable &&
      _result?.relationship != 'SELF' &&
      !_blockedByMe &&
      !_blockedByPeer;

  Future<void> _handleManagementAction(String action) async {
    if (_managementBusy) return;
    switch (action) {
      case 'edit':
        await _editContact();
      case 'delete':
        await _deleteContact();
      case 'block':
        await _blockContact();
      case 'unblock':
        await _unblockContact();
    }
  }

  Future<void> _editContact() async {
    final contact = _contact;
    if (contact == null) return;
    final draft = await showDialog<_ContactEditDraft>(
      context: context,
      builder: (_) => _ContactEditDialog(contact: contact),
    );
    if (draft == null || !mounted) return;
    setState(() => _managementBusy = true);
    try {
      final updated = await _client.updateContact(
        origin: widget.origin,
        accessToken: widget.accessToken,
        userId: widget.userId,
        remark: draft.remark,
        isStarred: draft.isStarred,
        tags: draft.tags,
      );
      if (!mounted) return;
      setState(() => _contact = updated);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('联系人资料已更新')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新联系人失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _managementBusy = false);
    }
  }

  Future<void> _deleteContact() async {
    final confirmed = await _confirmDanger(
      title: '删除联系人？',
      content: '只从你的通讯录中移除，不会删除历史聊天，也不会阻止双方继续发消息。',
      confirmLabel: '删除',
    );
    if (!confirmed || !mounted) return;
    setState(() => _managementBusy = true);
    try {
      await _client.deleteContact(
        origin: widget.origin,
        accessToken: widget.accessToken,
        userId: widget.userId,
      );
      if (!mounted) return;
      final user = _result?.user;
      setState(() {
        _contact = null;
        if (user != null) {
          _result = ContactSearchResult(user: user, relationship: 'NONE');
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已从联系人中删除')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除联系人失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _managementBusy = false);
    }
  }

  Future<void> _blockContact() async {
    final confirmed = await _confirmDanger(
      title: '拉黑这个用户？',
      content: '拉黑后双方不能继续发送消息，并会从你的联系人中移除。',
      confirmLabel: '拉黑',
    );
    if (!confirmed || !mounted) return;
    setState(() => _managementBusy = true);
    try {
      await _client.blockUser(
        origin: widget.origin,
        accessToken: widget.accessToken,
        userId: widget.userId,
      );
      if (!mounted) return;
      final user = _result?.user;
      setState(() {
        _contact = null;
        if (user != null) {
          _result = ContactSearchResult(
            user: user,
            relationship: 'BLOCKED_BY_ME',
          );
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已拉黑')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('拉黑失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _managementBusy = false);
    }
  }

  Future<void> _unblockContact() async {
    if (_managementBusy) return;
    setState(() => _managementBusy = true);
    try {
      await _client.unblockUser(
        origin: widget.origin,
        accessToken: widget.accessToken,
        userId: widget.userId,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已解除拉黑')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('解除拉黑失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _managementBusy = false);
    }
  }

  Future<bool> _confirmDanger({
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
                style: FilledButton.styleFrom(backgroundColor: DdColors.danger),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final user = _result?.user;
    final remark = _contact?.remark.trim() ?? '';
    final displayName = remark.isNotEmpty
        ? remark
        : (user?.displayName ?? widget.displayName);
    final handle = user?.handle ?? widget.handle;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final horizontalPadding = viewportWidth >= 720
        ? (viewportWidth - 680) / 2
        : 12.0;
    final pageBackground = dark
        ? const Color(0xFF151515)
        : const Color(0xFFF4F5F7);
    return Scaffold(
      backgroundColor: pageBackground,
      appBar: AppBar(
        backgroundColor: pageBackground,
        surfaceTintColor: Colors.transparent,
        title: const Text('详细资料'),
        actions: [
          if (!_unavailable &&
              _result?.relationship != null &&
              _result?.relationship != 'SELF')
            PopupMenuButton<String>(
              key: const Key('peer-profile-more'),
              enabled: !_managementBusy,
              tooltip: '联系人管理',
              onSelected: _handleManagementAction,
              itemBuilder: (_) => [
                if (_isContact)
                  const PopupMenuItem<String>(
                    value: 'edit',
                    child: Text('备注与标签'),
                  ),
                if (_isContact)
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Text(
                      '删除联系人',
                      style: TextStyle(color: DdColors.danger),
                    ),
                  ),
                if (!_blockedByMe && !_blockedByPeer)
                  const PopupMenuItem<String>(
                    value: 'block',
                    child: Text('拉黑', style: TextStyle(color: DdColors.danger)),
                  ),
                if (_blockedByMe)
                  const PopupMenuItem<String>(
                    value: 'unblock',
                    child: Text('解除拉黑'),
                  ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('peer-profile-scroll'),
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            12,
            horizontalPadding,
            24,
          ),
          children: [
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(DdRadii.surface),
              ),
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
              child: Column(
                children: [
                  GestureDetector(
                    key: const Key('peer-profile-avatar'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openAvatarViewer(displayName),
                    child: Hero(
                      tag: 'peer-profile-avatar-${widget.userId}',
                      child: ProfileAvatar(
                        origin: widget.origin,
                        accessToken: widget.accessToken,
                        userId: widget.userId,
                        displayName: displayName,
                        size: viewportWidth >= 720 ? 108 : 96,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    displayName,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 23,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    handle.trim().isEmpty ? 'DDID 暂不可用' : 'DDID：$handle',
                    key: const Key('peer-profile-handle'),
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: DdColors.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    key: const Key('peer-profile-relationship-chip'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _relationshipChipColor(
                        _result?.relationship,
                        dark: dark,
                      ),
                      borderRadius: BorderRadius.circular(DdRadii.pill),
                    ),
                    child: Text(
                      _unavailable
                          ? '用户不可用'
                          : _relationshipLabel(_result?.relationship),
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.1,
                        color: _relationshipChipForeground(
                          _result?.relationship,
                          dark: dark,
                        ),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (remark.isNotEmpty &&
                      user != null &&
                      user.displayName.trim() != remark) ...[
                    const SizedBox(height: 10),
                    Text(
                      '昵称：${user.displayName}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: DdColors.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              key: const Key('peer-profile-info-card'),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(DdRadii.surface),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  _ProfileLine(
                    label: 'DDID',
                    value: handle.trim().isEmpty ? '暂不可用' : handle,
                  ),
                  const Divider(height: 1, indent: 102),
                  _ProfileLine(
                    label: remark.isNotEmpty ? '备注' : '昵称',
                    value: displayName,
                  ),
                  const Divider(height: 1, indent: 102),
                  _ProfileLine(
                    label: '个性签名',
                    value: _unavailable
                        ? '该用户当前不可用'
                        : user == null
                        ? (_error == null ? '正在加载…' : '暂时无法加载资料')
                        : (user.bio.trim().isEmpty ? '暂无简介' : user.bio.trim()),
                  ),
                  const Divider(height: 1, indent: 102),
                  _ProfileLine(
                    label: '关系',
                    value: _unavailable
                        ? '用户不可用'
                        : _relationshipLabel(_result?.relationship),
                  ),
                  if ((_contact?.tags ?? const <String>[]).isNotEmpty) ...[
                    const Divider(height: 1, indent: 102),
                    _ProfileLine(
                      label: '标签',
                      value: _contact!.tags.join(' · '),
                    ),
                  ],
                ],
              ),
            ),
            if (_isContact && widget.onOpenMoments != null) ...[
              const SizedBox(height: 8),
              Material(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(DdRadii.surface),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const Key('peer-profile-moments'),
                  onTap: _managementBusy
                      ? null
                      : () => unawaited(widget.onOpenMoments!()),
                  child: const SizedBox(
                    height: 56,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(
                            Icons.photo_library_outlined,
                            size: 21,
                            color: Color(0xFF576B95),
                          ),
                          SizedBox(width: 13),
                          Expanded(
                            child: Text(
                              '朋友圈',
                              style: TextStyle(fontSize: 15),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: DdColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (_isContact && widget.onOpenMomentPrivacy != null) ...[
              const SizedBox(height: 8),
              Material(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(DdRadii.surface),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: const Key('peer-profile-moment-privacy'),
                  onTap: _managementBusy
                      ? null
                      : () => unawaited(widget.onOpenMomentPrivacy!()),
                  child: const SizedBox(
                    height: 56,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(
                            Icons.visibility_outlined,
                            size: 21,
                            color: Color(0xFF576B95),
                          ),
                          SizedBox(width: 13),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '朋友圈权限',
                                  style: TextStyle(fontSize: 15),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  '不看他的朋友圈 / 不让他看我的朋友圈',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: DdColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: DdColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (_canCommunicate &&
                (widget.onMessage != null ||
                    widget.onAudioCall != null ||
                    widget.onVideoCall != null)) ...[
              const SizedBox(height: 8),
              Material(
                key: const Key('peer-profile-quick-actions'),
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(DdRadii.surface),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  height: 88,
                  child: Row(
                    children: [
                      if (widget.onMessage != null)
                        Expanded(
                          child: _ProfileAction(
                            key: const Key('peer-profile-message'),
                            icon: Icons.chat_bubble_outline_rounded,
                            label: '发消息',
                            onTap: widget.onMessage!,
                          ),
                        ),
                      if (widget.onMessage != null &&
                          (widget.onAudioCall != null ||
                              widget.onVideoCall != null))
                        const VerticalDivider(
                          width: 1,
                          indent: 14,
                          endIndent: 14,
                        ),
                      if (widget.onAudioCall != null)
                        Expanded(
                          child: _ProfileAction(
                            key: const Key('peer-profile-audio-call'),
                            icon: Icons.call_outlined,
                            label: '语音',
                            onTap: widget.onAudioCall!,
                          ),
                        ),
                      if (widget.onAudioCall != null &&
                          widget.onVideoCall != null)
                        const VerticalDivider(
                          width: 1,
                          indent: 14,
                          endIndent: 14,
                        ),
                      if (widget.onVideoCall != null)
                        Expanded(
                          child: _ProfileAction(
                            key: const Key('peer-profile-video-call'),
                            icon: Icons.videocam_outlined,
                            label: '视频',
                            onTap: widget.onVideoCall!,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            if (!_isContact &&
                _canCommunicate &&
                _result?.relationship == 'NONE') ...[
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(DdRadii.surface),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: FilledButton(
                  key: const Key('peer-profile-add-contact'),
                  onPressed: _contactBusy ? null : _addContact,
                  style: FilledButton.styleFrom(
                    backgroundColor: DdColors.green,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: Text(_contactBusy ? '正在添加…' : '添加到联系人'),
                ),
              ),
            ],
            if (!_isContact &&
                _canCommunicate &&
                _result?.relationship == 'PENDING_INCOMING') ...[
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(DdRadii.surface),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: FilledButton(
                  key: const Key('peer-profile-accept-request'),
                  onPressed: _contactBusy || _pendingIncomingRequest == null
                      ? null
                      : _acceptIncomingRequest,
                  style: FilledButton.styleFrom(
                    backgroundColor: DdColors.green,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: Text(
                    _contactBusy
                        ? '正在通过…'
                        : _pendingIncomingRequest == null
                        ? '请在新的朋友中处理'
                        : '通过好友申请',
                  ),
                ),
              ),
            ],
            if (!_isContact &&
                _canCommunicate &&
                _result?.relationship == 'PENDING_OUTGOING') ...[
              const SizedBox(height: 8),
              _relationshipNotice('好友申请已发送', '等待对方通过后会自动更新联系人状态。'),
            ],
            if (_blockedByPeer) ...[
              const SizedBox(height: 8),
              _relationshipNotice('对方已将你拉黑', '您无法添加，也无法继续发送消息。'),
            ],
            if (_blockedByMe) ...[
              const SizedBox(height: 8),
              _relationshipNotice('你已将对方拉黑', '解除拉黑后即可恢复聊天。'),
            ],
            if (_unavailable) ...[
              const SizedBox(height: 8),
              _relationshipNotice('该用户当前不可用', '账号可能已停用、删除，或当前关系不允许查看其资料。'),
            ],
            if (_error != null && !_unavailable) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: OutlinedButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新加载'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _relationshipNotice(String title, String detail) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(DdRadii.surface),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            detail,
            style: const TextStyle(fontSize: 13, color: DdColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Color _relationshipChipColor(String? relationship, {required bool dark}) {
    if (_unavailable ||
        relationship == 'BLOCKED_BY_ME' ||
        relationship == 'BLOCKED_BY_PEER') {
      return dark ? const Color(0xFF402424) : const Color(0xFFFFE8E8);
    }
    if (relationship == 'CONTACT') {
      return dark ? const Color(0xFF173824) : const Color(0xFFE4F6EA);
    }
    if (relationship == 'PENDING_OUTGOING' ||
        relationship == 'PENDING_INCOMING') {
      return dark ? const Color(0xFF3D3521) : const Color(0xFFFFF3D7);
    }
    return dark ? const Color(0xFF2D2D2D) : const Color(0xFFF0F1F3);
  }

  Color _relationshipChipForeground(
    String? relationship, {
    required bool dark,
  }) {
    if (_unavailable ||
        relationship == 'BLOCKED_BY_ME' ||
        relationship == 'BLOCKED_BY_PEER') {
      return dark ? const Color(0xFFFF9898) : const Color(0xFFC83E3E);
    }
    if (relationship == 'CONTACT') return DdColors.greenPressed;
    if (relationship == 'PENDING_OUTGOING' ||
        relationship == 'PENDING_INCOMING') {
      return dark ? const Color(0xFFFFCC72) : const Color(0xFF996515);
    }
    return dark ? const Color(0xFFBDBDBD) : DdColors.textSecondary;
  }

  String _relationshipLabel(String? relationship) => switch (relationship) {
    'CONTACT' => '已在联系人中',
    'PENDING_OUTGOING' => '好友申请待通过',
    'PENDING_INCOMING' => '对方请求添加你',
    'SELF' => '自己',
    'BLOCKED_BY_ME' => '你已将对方拉黑',
    'BLOCKED_BY_PEER' => '对方已将你拉黑',
    null => '正在确认…',
    _ => '可直接聊天',
  };
}

class _ProfileAction extends StatelessWidget {
  const _ProfileAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(DdRadii.surface),
      onTap: () => onTap(),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF173824) : const Color(0xFFE4F6EA),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: DdColors.greenPressed, size: 20),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: DdColors.greenPressed,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

final class _ContactEditDraft {
  const _ContactEditDraft({
    required this.remark,
    required this.isStarred,
    required this.tags,
  });

  final String remark;
  final bool isStarred;
  final List<String> tags;
}

class _ContactEditDialog extends StatefulWidget {
  const _ContactEditDialog({required this.contact});

  final ContactItem contact;

  @override
  State<_ContactEditDialog> createState() => _ContactEditDialogState();
}

class _ContactEditDialogState extends State<_ContactEditDialog> {
  late final TextEditingController _remark;
  late final TextEditingController _tags;
  late bool _starred;

  @override
  void initState() {
    super.initState();
    _remark = TextEditingController(text: widget.contact.remark);
    _tags = TextEditingController(text: widget.contact.tags.join('，'));
    _starred = widget.contact.isStarred;
  }

  @override
  void dispose() {
    _remark.dispose();
    _tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('备注与标签'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DdProfileEditField(
              fieldKey: const Key('peer-profile-edit-remark'),
              controller: _remark,
              maxLength: 64,
              label: '备注',
            ),
            DdProfileEditField(
              fieldKey: const Key('peer-profile-edit-tags'),
              controller: _tags,
              label: '标签',
              hint: '多个标签用逗号分隔',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('星标朋友'),
              value: _starred,
              onChanged: (value) => setState(() => _starred = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('peer-profile-save-contact'),
          onPressed: () {
            final parsedTags = _tags.text
                .split(RegExp(r'[,，]'))
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toSet()
                .take(20)
                .toList(growable: false);
            Navigator.pop(
              context,
              _ContactEditDraft(
                remark: _remark.text.trim(),
                isStarred: _starred,
                tags: parsedTags,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _ProfileLine extends StatelessWidget {
  const _ProfileLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: DdColors.textSecondary,
              ),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }
}
