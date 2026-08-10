import 'package:flutter/material.dart';

import '../../../core/widgets/dd_profile_edit_field.dart';
import '../../../theme/app_theme.dart';
import '../data/auth_api_client.dart';
import '../domain/account_management.dart';
import '../domain/auth_session.dart';
import 'widgets/profile_avatar.dart';

class PersonalProfilePage extends StatefulWidget {
  const PersonalProfilePage({
    super.key,
    required this.gateway,
    required this.origin,
    required this.session,
    required this.avatarRevision,
    required this.onViewAvatar,
    required this.onChangeAvatar,
    required this.onRemoveAvatar,
    required this.onProfileChanged,
    this.onOpenMyQr,
  });

  final AuthGateway gateway;
  final Uri origin;
  final AuthSession session;
  final int avatarRevision;
  final Future<void> Function() onViewAvatar;
  final Future<void> Function() onChangeAvatar;
  final Future<void> Function() onRemoveAvatar;
  final Future<void> Function(AccountMe me) onProfileChanged;
  final Future<void> Function()? onOpenMyQr;

  @override
  State<PersonalProfilePage> createState() => _PersonalProfilePageState();
}

class _PersonalProfilePageState extends State<PersonalProfilePage> {
  AccountMe? _me;
  late int _avatarRevision;
  bool _loading = true;
  bool _avatarBusy = false;
  bool _profileBusy = false;
  String? _error;

  String get _accessToken => widget.session.tokens.accessToken;

  @override
  void initState() {
    super.initState();
    _avatarRevision = widget.avatarRevision;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '个人信息',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: _loading && me == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.only(top: 10, bottom: 24),
              children: [
                if (_error != null)
                  Material(
                    color: const Color(0xFFFFE8E8),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 9, 8, 9),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: DdColors.danger,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF9D2323),
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: () => setState(() => _error = null),
                            icon: const Icon(Icons.close_rounded, size: 17),
                          ),
                        ],
                      ),
                    ),
                  ),
                _avatarRow(me),
                _profileLine(
                  key: const Key('profile-edit-display-name'),
                  label: '昵称',
                  value:
                      me?.profile.displayName ??
                      widget.session.user.displayName,
                  onTap: me == null
                      ? null
                      : () => _editTextField(_ProfileField.displayName),
                ),
                _profileLine(
                  key: const Key('profile-edit-ddid'),
                  label: 'DDID',
                  value: me?.profile.handle ?? widget.session.user.handle,
                  onTap: me == null
                      ? null
                      : () => _editTextField(_ProfileField.ddid),
                ),
                _profileLine(
                  key: const Key('profile-edit-email'),
                  label: '邮箱',
                  value: me?.profile.email ?? widget.session.user.email,
                  onTap: me == null ? null : _editEmail,
                ),
                const SizedBox(height: 10),
                _profileLine(
                  key: const Key('profile-my-qr'),
                  label: '二维码',
                  value: '我的二维码',
                  trailingIcon: Icons.qr_code_2_rounded,
                  onTap: widget.onOpenMyQr == null
                      ? null
                      : () => widget.onOpenMyQr!(),
                ),
                _profileLine(
                  key: const Key('profile-edit-bio'),
                  label: '个性签名',
                  value: me == null
                      ? '加载中…'
                      : (me.profile.bio.trim().isEmpty
                            ? '未设置'
                            : me.profile.bio),
                  onTap: me == null
                      ? null
                      : () => _editTextField(_ProfileField.bio),
                ),
              ],
            ),
    );
  }

  Widget _avatarRow(AccountMe? me) {
    final displayName =
        me?.profile.displayName ?? widget.session.user.displayName;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        key: const Key('profile-avatar-row'),
        onTap: _avatarBusy ? null : _avatarActions,
        child: SizedBox(
          height: 92,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text('头像', style: TextStyle(fontSize: 16)),
                const Spacer(),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipOval(
                      child: ProfileAvatar(
                        origin: widget.origin,
                        accessToken: _accessToken,
                        userId: widget.session.user.id,
                        displayName: displayName,
                        revision: _avatarRevision,
                        size: 64,
                      ),
                    ),
                    if (_avatarBusy)
                      Container(
                        width: 64,
                        height: 64,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.36),
                          shape: BoxShape.circle,
                        ),
                        child: const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                const Text(
                  '查看或更换',
                  style: TextStyle(fontSize: 12, color: DdColors.textSecondary),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: DdColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _profileLine({
    Key? key,
    required String label,
    required String value,
    IconData? trailingIcon,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        key: key,
        onTap: _profileBusy ? null : onTap,
        child: SizedBox(
          height: 58,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                SizedBox(
                  width: 82,
                  child: Text(label, style: const TextStyle(fontSize: 16)),
                ),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 14,
                      color: DdColors.textSecondary,
                    ),
                  ),
                ),
                if (trailingIcon != null) ...[
                  const SizedBox(width: 8),
                  Icon(trailingIcon, size: 21, color: DdColors.textSecondary),
                ],
                if (onTap != null) ...[
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 19,
                    color: DdColors.textTertiary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _load() async {
    try {
      final me = await widget.gateway.getMe(
        origin: widget.origin,
        accessToken: _accessToken,
      );
      if (!mounted) return;
      setState(() {
        _me = me;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '个人资料加载失败，请稍后重试。';
      });
    }
  }

  Future<void> _editTextField(_ProfileField field) async {
    final current = _me;
    if (current == null || _profileBusy) return;
    final initial = switch (field) {
      _ProfileField.displayName => current.profile.displayName,
      _ProfileField.ddid => current.profile.handle,
      _ProfileField.bio => current.profile.bio,
    };
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(field.title),
        content: DdProfileEditField(
          fieldKey: const Key('profile-edit-field'),
          controller: controller,
          autofocus: true,
          maxLength: field == _ProfileField.bio ? 500 : null,
          minLines: field == _ProfileField.bio ? 2 : 1,
          maxLines: field == _ProfileField.bio ? 5 : 1,
          autocorrect: field != _ProfileField.ddid,
          enableSuggestions: field != _ProfileField.ddid,
          hint: field.hint,
          onSubmitted: (_) =>
              Navigator.pop(dialogContext, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('profile-edit-save'),
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 250), controller.dispose);
    if (value == null || !mounted || value == initial) return;
    if (field != _ProfileField.bio && value.isEmpty) {
      _showError('${field.title}不能为空。');
      return;
    }
    await _saveProfileField(field, value);
  }

  Future<void> _saveProfileField(_ProfileField field, String value) async {
    final current = _me;
    if (current == null || _profileBusy) return;
    setState(() {
      _profileBusy = true;
      _error = null;
    });
    try {
      final me = await widget.gateway.updateMe(
        origin: widget.origin,
        accessToken: _accessToken,
        handle: field == _ProfileField.ddid ? value : current.profile.handle,
        displayName: field == _ProfileField.displayName
            ? value
            : current.profile.displayName,
        bio: field == _ProfileField.bio ? value : current.profile.bio,
        privacy: current.privacy,
      );
      await _applyMe(me);
      if (mounted) _showSuccess('已更新');
    } catch (error) {
      if (mounted) _showError('保存失败：$error');
    } finally {
      if (mounted) setState(() => _profileBusy = false);
    }
  }

  Future<void> _editEmail() async {
    final current = _me;
    if (current == null || _profileBusy) return;
    final emailController = TextEditingController(text: current.profile.email);
    final codeController = TextEditingController();
    var codeSent = false;
    var busy = false;
    String? localError;

    final updated = await showDialog<AccountMe>(
      context: context,
      barrierDismissible: !busy,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> sendCode() async {
            final email = emailController.text.trim();
            if (email.isEmpty || email == current.profile.email) {
              setDialogState(() => localError = '请输入新的邮箱地址。');
              return;
            }
            setDialogState(() {
              busy = true;
              localError = null;
            });
            try {
              await widget.gateway.sendEmailChangeCode(
                origin: widget.origin,
                accessToken: _accessToken,
                email: email,
              );
              if (!dialogContext.mounted) return;
              setDialogState(() => codeSent = true);
            } catch (error) {
              if (!dialogContext.mounted) return;
              setDialogState(() => localError = '验证码发送失败：$error');
            } finally {
              if (dialogContext.mounted) setDialogState(() => busy = false);
            }
          }

          Future<void> confirm() async {
            final email = emailController.text.trim();
            final code = codeController.text.trim();
            if (!codeSent || code.length != 6) {
              setDialogState(() => localError = '请输入 6 位新邮箱验证码。');
              return;
            }
            setDialogState(() {
              busy = true;
              localError = null;
            });
            try {
              final me = await widget.gateway.changeEmail(
                origin: widget.origin,
                accessToken: _accessToken,
                email: email,
                code: code,
              );
              if (dialogContext.mounted) Navigator.pop(dialogContext, me);
            } catch (error) {
              if (!dialogContext.mounted) return;
              setDialogState(() {
                busy = false;
                localError = '邮箱修改失败：$error';
              });
            }
          }

          return AlertDialog(
            title: const Text('修改邮箱'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DdProfileEditField(
                    fieldKey: const Key('profile-email-field'),
                    controller: emailController,
                    enabled: !busy,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    label: '新邮箱',
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      key: const Key('profile-email-send-code'),
                      onPressed: busy ? null : sendCode,
                      child: Text(codeSent ? '重新发送验证码' : '发送验证码'),
                    ),
                  ),
                  if (codeSent) ...[
                    const SizedBox(height: 10),
                    DdProfileEditField(
                      fieldKey: const Key('profile-email-code-field'),
                      controller: codeController,
                      enabled: !busy,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      label: '验证码',
                      counterText: '',
                    ),
                  ],
                  if (localError != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        localError!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: DdColors.danger,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('profile-email-confirm'),
                onPressed: busy || !codeSent ? null : confirm,
                child: Text(busy ? '处理中…' : '确认改绑'),
              ),
            ],
          );
        },
      ),
    );
    Future<void>.delayed(
      const Duration(milliseconds: 250),
      emailController.dispose,
    );
    Future<void>.delayed(
      const Duration(milliseconds: 250),
      codeController.dispose,
    );
    if (updated == null || !mounted) return;
    await _applyMe(updated);
    if (mounted) _showSuccess('邮箱已更新');
  }

  Future<void> _applyMe(AccountMe me) async {
    if (!mounted) return;
    setState(() => _me = me);
    await widget.onProfileChanged(me);
  }

  Future<void> _avatarActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('查看头像'),
              onTap: () => Navigator.pop(sheetContext, 'view'),
            ),
            ListTile(
              key: const Key('profile-change-avatar'),
              leading: const Icon(Icons.crop_rounded),
              title: const Text('更换并裁剪头像'),
              subtitle: const Text('拖动并双指缩放，裁剪圆形头像'),
              onTap: () => Navigator.pop(sheetContext, 'change'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text(
                '移除头像',
                style: TextStyle(color: DdColors.danger),
              ),
              onTap: () => Navigator.pop(sheetContext, 'remove'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'view') {
      await widget.onViewAvatar();
      return;
    }
    setState(() => _avatarBusy = true);
    try {
      if (action == 'change') {
        await widget.onChangeAvatar();
      } else if (action == 'remove') {
        await widget.onRemoveAvatar();
      }
      if (mounted) {
        setState(() => _avatarRevision = DateTime.now().microsecondsSinceEpoch);
      }
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  void _showSuccess(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(String message) {
    setState(() => _error = message);
  }
}

enum _ProfileField {
  displayName('修改昵称', '请输入昵称'),
  ddid('修改 DDID', '3–32 位，以字母开头，仅小写字母、数字和下划线'),
  bio('修改个性签名', '请输入个性签名');

  const _ProfileField(this.title, this.hint);
  final String title;
  final String hint;
}
