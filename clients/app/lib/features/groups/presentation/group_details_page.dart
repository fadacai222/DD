import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/media/avatar_crop_page.dart';
import '../../../core/media/avatar_image_processor.dart';
import '../../../core/media/camera_capture_service.dart';

import '../../../core/widgets/dd_action_sheet.dart';
import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../contacts/data/contacts_api_client.dart';
import '../../contacts/domain/contact_models.dart';
import '../../messaging/application/messaging_coordinator.dart';
import '../../messaging/data/media_api_client.dart';
import '../../messaging/domain/messaging_models.dart';
import '../../messaging/presentation/widgets/group_avatar.dart';
import '../data/groups_api_client.dart';
import '../domain/group_models.dart';

final class GroupDetailsResult {
  const GroupDetailsResult({this.membershipEnded = false});

  final bool membershipEnded;
}

class GroupDetailsPage extends StatefulWidget {
  const GroupDetailsPage({
    super.key,
    required this.coordinator,
    required this.groupId,
    required this.currentUserId,
    this.gateway,
    this.contactsGateway,
    this.mediaApi,
    this.cameraCapture,
    this.embedded = false,
    this.onResult,
  });

  final MessagingCoordinator coordinator;
  final String groupId;
  final String currentUserId;
  final GroupsGateway? gateway;
  final ContactsGateway? contactsGateway;
  final MediaApiClient? mediaApi;
  final CameraCaptureGateway? cameraCapture;
  final bool embedded;
  final ValueChanged<GroupDetailsResult>? onResult;

  @override
  State<GroupDetailsPage> createState() => _GroupDetailsPageState();
}

class _GroupDetailsPageState extends State<GroupDetailsPage> {
  late final GroupsGateway _gateway;
  late final ContactsGateway _contacts;
  late final bool _ownsGateway;
  late final bool _ownsContacts;
  late final MediaApiClient _mediaApi;
  late final bool _ownsMediaApi;
  late final CameraCaptureGateway _cameraCapture;
  GroupInfo? _group;
  List<GroupMemberItem> _members = const [];
  List<GroupJoinRequestItem> _requests = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _ownsContacts = widget.contactsGateway == null;
    _gateway = widget.gateway ?? GroupsApiClient();
    _contacts = widget.contactsGateway ?? ContactsApiClient();
    _ownsMediaApi = widget.mediaApi == null;
    _mediaApi = widget.mediaApi ?? MediaApiClient();
    _cameraCapture = widget.cameraCapture ?? CameraCaptureService();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsGateway) _gateway.close();
    if (_ownsContacts) _contacts.close();
    if (_ownsMediaApi) _mediaApi.close();
    super.dispose();
  }

  Future<T> _authorized<T>(Future<T> Function(String token) action) =>
      widget.coordinator.withAuthorizedToken(action);

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final group = await _authorized(
        (token) => _gateway.getGroup(
          origin: widget.coordinator.origin,
          accessToken: token,
          groupId: widget.groupId,
        ),
      );
      final members = await _authorized(
        (token) => _gateway.listMembers(
          origin: widget.coordinator.origin,
          accessToken: token,
          groupId: widget.groupId,
        ),
      );
      var requests = const <GroupJoinRequestItem>[];
      if (group.canManage) {
        requests = await _authorized(
          (token) => _gateway.listJoinRequests(
            origin: widget.coordinator.origin,
            accessToken: token,
            groupId: widget.groupId,
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _group = group;
        _members = members;
        _requests = requests;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '群聊资料加载失败：$error';
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    final page = Scaffold(
      appBar: AppBar(
        title: const Text('群聊信息'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _busy ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading && group == null
          ? const Center(child: CircularProgressIndicator())
          : group == null
          ? _failedState()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  if (_busy) const LinearProgressIndicator(minHeight: 2),
                  if (_error != null) _errorBanner(),
                  _header(group),
                  const SizedBox(height: 10),
                  _section([
                    _row(
                      key: const Key('group-details-name'),
                      icon: Icons.group_outlined,
                      title: '群聊名称',
                      value: group.name,
                      onTap: group.canManage && !_busy
                          ? () => unawaited(_editName(group))
                          : null,
                    ),
                    _row(
                      key: const Key('group-details-announcement'),
                      icon: Icons.campaign_outlined,
                      title: '群公告',
                      value: group.announcement.trim().isEmpty
                          ? '未设置'
                          : group.announcement,
                      onTap: group.canManage && !_busy
                          ? () => unawaited(_editAnnouncement(group))
                          : null,
                    ),
                    _row(
                      key: const Key('group-details-join-mode'),
                      icon: Icons.how_to_reg_outlined,
                      title: '入群方式',
                      value: group.joinMode == 'APPROVAL' ? '需要管理员审批' : '仅管理员邀请',
                      onTap: group.canManage && !_busy
                          ? () => unawaited(_chooseJoinMode(group))
                          : null,
                    ),
                    _row(
                      key: const Key('group-details-nickname'),
                      icon: Icons.badge_outlined,
                      title: '我在本群的昵称',
                      value: group.myNickname.trim().isEmpty
                          ? '未设置'
                          : group.myNickname,
                      onTap: _busy ? null : () => unawaited(_editMyNickname(group)),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  _memberSection(group),
                  if (group.canManage && _requests.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _requestSection(group),
                  ],
                  const SizedBox(height: 10),
                  _section([
                    if (group.isOwner)
                      _row(
                        key: const Key('group-details-dissolve'),
                        icon: Icons.delete_forever_outlined,
                        title: '解散群聊',
                        destructive: true,
                        onTap: _busy ? null : () => unawaited(_confirmDissolve(group)),
                      )
                    else
                      _row(
                        key: const Key('group-details-leave'),
                        icon: Icons.logout_rounded,
                        title: '退出群聊',
                        destructive: true,
                        onTap: _busy ? null : () => unawaited(_confirmLeave(group)),
                      ),
                  ]),
                ],
              ),
            ),
    );
    return widget.embedded ? page.body! : page;
  }

  Widget _failedState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.group_off_outlined, size: 46, color: DdColors.textTertiary),
          const SizedBox(height: 12),
          Text(_error ?? '群聊当前不可用', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    ),
  );

  Widget _header(GroupInfo group) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('group-details-avatar'),
              customBorder: const CircleBorder(),
              onTap: group.canManage && !_busy
                  ? () => unawaited(_editGroupAvatar(group))
                  : null,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  GroupAvatar(
                    origin: widget.coordinator.origin,
                    accessToken: widget.coordinator.accessToken,
                    groupId: group.id,
                    groupName: group.name,
                    avatarMediaId: group.avatarMediaId,
                    avatarRevision: group.avatarRevision,
                    members: _members
                        .map(
                          (item) => MessagingUserPreview(
                            id: item.user.id,
                            handle: item.user.handle,
                            displayName: item.user.displayName,
                          ),
                        )
                        .toList(growable: false),
                    size: 78,
                  ),
                  if (group.canManage)
                    const Positioned(
                      right: -2,
                      bottom: -2,
                      child: CircleAvatar(
                        radius: 13,
                        backgroundColor: DdColors.green,
                        child: Icon(
                          Icons.camera_alt_rounded,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(group.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            '${group.memberCount} 位成员 · ${_roleLabel(group.myRole)}',
            style: const TextStyle(fontSize: 12, color: DdColors.textSecondary),
          ),
        ],
      ),
    ),
  );

  Widget _memberSection(GroupInfo group) {
    return _section([
      ListTile(
        title: Text('群成员（${_members.length}）', style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: group.canManage
            ? TextButton.icon(
                key: const Key('group-details-invite'),
                onPressed: _busy ? null : () => unawaited(_inviteMembers(group)),
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                label: const Text('邀请'),
              )
            : null,
      ),
      ..._members.map((member) => _memberTile(group, member)),
    ]);
  }

  Widget _memberTile(GroupInfo group, GroupMemberItem member) {
    final canOpenActions = !_busy &&
        member.user.id != widget.currentUserId &&
        (group.isOwner || (group.myRole == 'ADMIN' && member.role == 'MEMBER'));
    return ListTile(
      key: Key('group-member-${member.user.id}'),
      leading: ProfileAvatar(
        origin: widget.coordinator.origin,
        accessToken: widget.coordinator.accessToken,
        userId: member.user.id,
        displayName: member.effectiveName,
        size: 42,
      ),
      title: Text(member.effectiveName),
      subtitle: Text('@${member.user.handle}${member.role == 'MEMBER' ? '' : ' · ${_roleLabel(member.role)}'}'),
      trailing: canOpenActions ? const Icon(Icons.more_horiz_rounded) : null,
      onTap: canOpenActions ? () => unawaited(_memberActions(group, member)) : null,
    );
  }

  Widget _requestSection(GroupInfo group) => _section([
    const ListTile(
      leading: Icon(Icons.mark_email_unread_outlined),
      title: Text('待处理入群申请', style: TextStyle(fontWeight: FontWeight.w600)),
    ),
    ..._requests.map(
      (request) => ListTile(
        key: Key('group-join-request-${request.id}'),
        title: Text(request.requester.displayName),
        subtitle: Text(request.message.trim().isEmpty ? '@${request.requester.handle}' : request.message),
        trailing: Wrap(
          spacing: 4,
          children: [
            TextButton(
              onPressed: _busy ? null : () => unawaited(_resolveRequest(request, false)),
              child: const Text('拒绝'),
            ),
            FilledButton(
              onPressed: _busy ? null : () => unawaited(_resolveRequest(request, true)),
              child: const Text('通过'),
            ),
          ],
        ),
      ),
    ),
  ]);

  Widget _section(List<Widget> children) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Column(children: children),
  );

  Widget _row({
    Key? key,
    required IconData icon,
    required String title,
    String? value,
    VoidCallback? onTap,
    bool destructive = false,
  }) {
    final color = destructive ? DdColors.danger : null;
    return ListTile(
      key: key,
      leading: Icon(icon, color: color ?? DdColors.textSecondary),
      title: Text(title, style: TextStyle(color: color)),
      subtitle: value == null ? null : Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right_rounded, color: DdColors.textTertiary),
      onTap: onTap,
    );
  }

  Widget _errorBanner() => Material(
    color: const Color(0xFFFFE8E8),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: DdColors.danger, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(_error!, style: const TextStyle(fontSize: 12, color: Color(0xFF9D2323)))),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _error = null),
            icon: const Icon(Icons.close_rounded, size: 17),
          ),
        ],
      ),
    ),
  );

  Future<String?> _textDialog({
    required String title,
    required String initial,
    required int maxLength,
    required String hint,
    bool multiline = false,
  }) async {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          maxLength: maxLength,
          maxLines: multiline ? 6 : 1,
          minLines: multiline ? 3 : 1,
          decoration: InputDecoration(hintText: hint),
          onChanged: (next) => value = next,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, value),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _editGroupAvatar(GroupInfo group) async {
    if (!group.canManage || _busy) return;
    final actions = <DdActionSheetItem<String>>[
      const DdActionSheetItem(
        value: 'album',
        icon: Icons.photo_library_outlined,
        label: '从相册选择',
      ),
      if (_cameraCapture.isSupported)
        const DdActionSheetItem(
          value: 'camera',
          icon: Icons.photo_camera_outlined,
          label: '拍摄',
        ),
      if (group.avatarMediaId.isNotEmpty)
        const DdActionSheetItem(
          value: 'remove',
          icon: Icons.delete_outline_rounded,
          label: '移除群头像',
          destructive: true,
        ),
    ];
    final action = await showDdActionSheet<String>(context, items: actions);
    if (!mounted || action == null) return;
    if (action == 'remove') {
      await _run(() async {
        final updated = await _authorized(
          (token) => _gateway.updateGroup(
            origin: widget.coordinator.origin,
            accessToken: token,
            groupId: group.id,
            avatarMediaId: '',
          ),
        );
        if (!mounted) return;
        setState(() => _group = updated);
        await widget.coordinator.refreshConversations();
      });
      return;
    }

    XFile? file;
    try {
      if (action == 'camera') {
        file = await _cameraCapture.capturePhoto();
      } else {
        file = await openFile(
          acceptedTypeGroups: const <XTypeGroup>[
            XTypeGroup(
              label: '图片',
              extensions: <String>['jpg', 'jpeg', 'png', 'webp'],
              mimeTypes: <String>[
                'image/jpeg',
                'image/png',
                'image/webp',
              ],
            ),
          ],
        );
      }
      if (file == null || !mounted) return;
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
      await _run(() async {
        final media = await _authorized(
          (token) => _mediaApi.uploadMedia(
            origin: widget.coordinator.origin,
            accessToken: token,
            bytes: processed.bytes,
            fileName: 'group-avatar-${group.id}.jpg',
            mimeType: processed.contentType,
            purpose: 'GROUP_AVATAR',
          ),
        );
        final updated = await _authorized(
          (token) => _gateway.updateGroup(
            origin: widget.coordinator.origin,
            accessToken: token,
            groupId: group.id,
            avatarMediaId: media.mediaId,
          ),
        );
        if (!mounted) return;
        setState(() => _group = updated);
        await widget.coordinator.refreshConversations();
      });
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? '群头像操作失败。');
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '群头像更新失败：$error');
    }
  }

  Future<void> _editName(GroupInfo group) async {
    final value = await _textDialog(title: '修改群聊名称', initial: group.name, maxLength: 80, hint: '群聊名称');
    if (value == null || value.trim().isEmpty || !mounted) return;
    await _run(() async {
      await _authorized((token) => _gateway.updateGroup(origin: widget.coordinator.origin, accessToken: token, groupId: group.id, name: value.trim()));
      await widget.coordinator.refreshConversations();
      await _load();
    });
  }

  Future<void> _editAnnouncement(GroupInfo group) async {
    final value = await _textDialog(title: '修改群公告', initial: group.announcement, maxLength: 1000, hint: '群公告', multiline: true);
    if (value == null || !mounted) return;
    await _run(() async {
      await _authorized((token) => _gateway.updateGroup(origin: widget.coordinator.origin, accessToken: token, groupId: group.id, announcement: value.trim()));
      await _load();
    });
  }

  Future<void> _chooseJoinMode(GroupInfo group) async {
    final value = await showDdActionSheet<String>(
      context,
      items: const [
        DdActionSheetItem(value: 'INVITE_ONLY', icon: Icons.person_add_alt_1_rounded, label: '仅管理员邀请'),
        DdActionSheetItem(value: 'APPROVAL', icon: Icons.how_to_reg_rounded, label: '需要管理员审批'),
      ],
    );
    if (value == null || value == group.joinMode || !mounted) return;
    await _run(() async {
      await _authorized((token) => _gateway.updateGroup(origin: widget.coordinator.origin, accessToken: token, groupId: group.id, joinMode: value));
      await _load();
    });
  }

  Future<void> _editMyNickname(GroupInfo group) async {
    final value = await _textDialog(title: '我在本群的昵称', initial: group.myNickname, maxLength: 80, hint: '留空则显示原昵称');
    if (value == null || !mounted) return;
    await _run(() async {
      await _authorized((token) => _gateway.updateMember(
        origin: widget.coordinator.origin,
        accessToken: token,
        groupId: group.id,
        userId: widget.currentUserId,
        nickname: value.trim(),
      ));
      await _load();
    });
  }

  Future<void> _inviteMembers(GroupInfo group) async {
    final contactsPage = await _authorized(
      (token) => _contacts.listContacts(origin: widget.coordinator.origin, accessToken: token),
    );
    if (!mounted) return;
    final existing = _members.map((item) => item.user.id).toSet();
    final available = contactsPage.items.where((item) => !existing.contains(item.user.id)).toList(growable: false);
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有可继续邀请的联系人。')));
      return;
    }
    final selected = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute<List<String>>(
        builder: (_) => _GroupInvitePicker(
          origin: widget.coordinator.origin,
          accessToken: widget.coordinator.accessToken,
          contacts: available,
        ),
      ),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    await _run(() async {
      await _authorized((token) => _gateway.inviteMembers(
        origin: widget.coordinator.origin,
        accessToken: token,
        groupId: group.id,
        userIds: selected,
      ));
      await widget.coordinator.refreshConversations();
      await _load();
    });
  }

  Future<void> _memberActions(GroupInfo group, GroupMemberItem member) async {
    final items = <DdActionSheetItem<String>>[];
    if (group.isOwner && member.role != 'OWNER') {
      items.add(
        DdActionSheetItem(
          value: member.role == 'ADMIN' ? 'demote' : 'promote',
          icon: Icons.admin_panel_settings_outlined,
          label: member.role == 'ADMIN' ? '取消管理员' : '设为管理员',
        ),
      );
      items.add(const DdActionSheetItem(value: 'transfer', icon: Icons.swap_horiz_rounded, label: '转让群主'));
    }
    if (member.role == 'MEMBER' || group.isOwner) {
      items.add(const DdActionSheetItem(value: 'remove', icon: Icons.person_remove_outlined, label: '移出群聊', destructive: true));
    }
    if (items.isEmpty) return;
    final action = await showDdActionSheet<String>(context, items: items);
    if (action == null || !mounted) return;
    if (action == 'promote' || action == 'demote') {
      await _run(() async {
        await _authorized((token) => _gateway.updateMember(
          origin: widget.coordinator.origin,
          accessToken: token,
          groupId: group.id,
          userId: member.user.id,
          role: action == 'promote' ? 'ADMIN' : 'MEMBER',
        ));
        await _load();
      });
      return;
    }
    if (action == 'transfer') {
      final confirmed = await _confirm('转让群主？', '转让后你将变为普通成员，${member.effectiveName} 成为新的群主。', danger: true);
      if (!confirmed || !mounted) return;
      await _run(() async {
        await _authorized((token) => _gateway.transferOwnership(
          origin: widget.coordinator.origin,
          accessToken: token,
          groupId: group.id,
          userId: member.user.id,
        ));
        await _load();
      });
      return;
    }
    if (action == 'remove') {
      final confirmed = await _confirm('移出群聊？', '移出后 ${member.effectiveName} 将不能继续读取或发送该群的新消息。', danger: true);
      if (!confirmed || !mounted) return;
      await _run(() async {
        await _authorized((token) => _gateway.removeMember(
          origin: widget.coordinator.origin,
          accessToken: token,
          groupId: group.id,
          userId: member.user.id,
        ));
        await _load();
      });
    }
  }

  Future<void> _resolveRequest(GroupJoinRequestItem request, bool approve) async {
    await _run(() async {
      await _authorized((token) => _gateway.resolveJoinRequest(
        origin: widget.coordinator.origin,
        accessToken: token,
        groupId: request.groupId,
        requestId: request.id,
        approve: approve,
      ));
      await widget.coordinator.refreshConversations();
      await _load();
    });
  }

  Future<bool> _confirm(String title, String content, {bool danger = false}) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
            FilledButton(
              style: danger ? FilledButton.styleFrom(backgroundColor: DdColors.danger) : null,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _confirmLeave(GroupInfo group) async {
    final confirmed = await _confirm('退出群聊？', '退出后将无法继续读取或发送该群的新消息。', danger: true);
    if (!confirmed || !mounted) return;
    await _run(() async {
      await _authorized((token) => _gateway.leaveGroup(origin: widget.coordinator.origin, accessToken: token, groupId: group.id));
      await widget.coordinator.syncNow();
      if (mounted) _complete(const GroupDetailsResult(membershipEnded: true));
    });
  }

  Future<void> _confirmDissolve(GroupInfo group) async {
    final confirmed = await _confirm('解散群聊？', '所有成员都会立即失去群聊访问权。此操作不可恢复。', danger: true);
    if (!confirmed || !mounted) return;
    await _run(() async {
      await _authorized((token) => _gateway.dissolveGroup(origin: widget.coordinator.origin, accessToken: token, groupId: group.id));
      await widget.coordinator.syncNow();
      if (mounted) _complete(const GroupDetailsResult(membershipEnded: true));
    });
  }

  void _complete(GroupDetailsResult result) {
    final callback = widget.onResult;
    if (callback != null) {
      callback(result);
      return;
    }
    Navigator.of(context).pop(result);
  }

  String _roleLabel(String role) => switch (role) {
    'OWNER' => '群主',
    'ADMIN' => '管理员',
    _ => '成员',
  };
}

class _GroupInvitePicker extends StatefulWidget {
  const _GroupInvitePicker({
    required this.origin,
    required this.accessToken,
    required this.contacts,
  });

  final Uri origin;
  final String accessToken;
  final List<ContactItem> contacts;

  @override
  State<_GroupInvitePicker> createState() => _GroupInvitePickerState();
}

class _GroupInvitePickerState extends State<_GroupInvitePicker> {
  final Set<String> _selected = <String>{};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final visible = widget.contacts.where((item) {
      if (query.isEmpty) return true;
      return item.user.displayName.toLowerCase().contains(query) ||
          item.user.handle.toLowerCase().contains(query) ||
          item.remark.toLowerCase().contains(query);
    }).toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: const Text('邀请群成员'),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected.toList(growable: false)),
            child: Text('邀请${_selected.isEmpty ? '' : '(${_selected.length})'}'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: '搜索联系人'),
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final item = visible[index];
                final selected = _selected.contains(item.user.id);
                final name = item.remark.trim().isEmpty ? item.user.displayName : item.remark.trim();
                return CheckboxListTile(
                  value: selected,
                  onChanged: (_) => setState(() {
                    if (selected) {
                      _selected.remove(item.user.id);
                    } else if (_selected.length < 100) {
                      _selected.add(item.user.id);
                    }
                  }),
                  secondary: ProfileAvatar(
                    origin: widget.origin,
                    accessToken: widget.accessToken,
                    userId: item.user.id,
                    displayName: name,
                    size: 40,
                  ),
                  title: Text(name),
                  subtitle: Text('@${item.user.handle}'),
                  controlAffinity: ListTileControlAffinity.trailing,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
