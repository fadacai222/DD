import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../data/qr_api_client.dart';
import 'qr_code_card.dart';

class GroupQrPage extends StatefulWidget {
  const GroupQrPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.groupId,
    required this.groupName,
    required this.onUnauthorized,
    this.gateway,
  });

  final Uri origin;
  final String accessToken;
  final String groupId;
  final String groupName;
  final Future<String?> Function() onUnauthorized;
  final QrGateway? gateway;

  @override
  State<GroupQrPage> createState() => _GroupQrPageState();
}

class _GroupQrPageState extends State<GroupQrPage> {
  late final QrGateway _gateway;
  late final bool _ownsGateway;
  GroupQrInviteData? _invite;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? QrApiClient();
    unawaited(_create());
  }

  @override
  void dispose() {
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '群二维码',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: _invite == null
              ? _error == null
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: DdColors.danger,
                            size: 36,
                          ),
                          const SizedBox(height: 10),
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: _busy ? null : () => unawaited(_create()),
                            child: const Text('重新生成'),
                          ),
                        ],
                      )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DdQrCodeCard(
                      payload: _invite!.payload,
                      title: widget.groupName,
                      subtitle: '扫码加入群聊',
                      footer:
                          '有效期至 ${_formatTime(_invite!.expiresAt)} · 二维码可由群主/管理员随时撤销',
                    ),
                    const SizedBox(height: 14),
                    TextButton.icon(
                      key: const Key('group-qr-revoke'),
                      onPressed: _busy ? null : () => unawaited(_revoke()),
                      icon: const Icon(
                        Icons.link_off_rounded,
                        color: DdColors.danger,
                      ),
                      label: const Text(
                        '停用这个二维码',
                        style: TextStyle(color: DdColors.danger),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _invite = null;
    });
    try {
      final invite = await _authorized(
        (token) => _gateway.createGroupInvite(
          origin: widget.origin,
          accessToken: token,
          groupId: widget.groupId,
        ),
      );
      if (!mounted) return;
      setState(() => _invite = invite);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke() async {
    final invite = _invite;
    if (invite == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('停用群二维码？'),
        content: const Text('停用后，已经保存这个二维码的人也不能再用它加入群聊。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              '停用',
              style: TextStyle(color: DdColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _authorized(
        (token) => _gateway.revokeGroupInvite(
          origin: widget.origin,
          accessToken: token,
          inviteId: invite.id,
        ),
      );
      if (!mounted) return;
      setState(() {
        _invite = null;
        _error = '这个群二维码已停用。需要时可以重新生成新的二维码。';
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<T> _authorized<T>(Future<T> Function(String token) action) async {
    try {
      return await action(widget.accessToken);
    } on QrApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      final token = await widget.onUnauthorized();
      if (token == null || token.isEmpty) rethrow;
      return action(token);
    }
  }

  String _friendlyError(Object error) {
    if (error is QrApiException) return error.message;
    return error.toString().replaceFirst('FormatException: ', '');
  }

  String _formatTime(DateTime utc) {
    final local = utc.toLocal();
    return '${local.month}月${local.day}日 '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
