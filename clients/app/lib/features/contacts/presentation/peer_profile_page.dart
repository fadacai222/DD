import 'dart:async';

import 'package:flutter/material.dart';

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
  });

  final Uri origin;
  final String accessToken;
  final String userId;
  final String handle;
  final String displayName;

  @override
  State<PeerProfilePage> createState() => _PeerProfilePageState();
}

class _PeerProfilePageState extends State<PeerProfilePage> {
  late final ContactsApiClient _client;
  ContactSearchResult? _result;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _client = ContactsApiClient();
    unawaited(_load());
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await _client.searchByHandle(
        origin: widget.origin,
        accessToken: widget.accessToken,
        handle: widget.handle,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _result?.user;
    final displayName = user?.displayName ?? widget.displayName;
    final handle = user?.handle ?? widget.handle;
    return Scaffold(
      appBar: AppBar(title: const Text('个人资料')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
          children: [
            Center(
              child: ProfileAvatar(
                origin: widget.origin,
                accessToken: widget.accessToken,
                userId: widget.userId,
                displayName: displayName,
                size: 84,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                displayName,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 5),
            Center(
              child: Text(
                '@$handle',
                style: const TextStyle(
                  fontSize: 13,
                  color: DdColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: 28),
            _ProfileLine(
              label: '个人简介',
              value: user == null
                  ? (_error == null ? '正在加载…' : '暂时无法加载资料')
                  : (user.bio.trim().isEmpty ? '暂无简介' : user.bio.trim()),
            ),
            const Divider(height: 1),
            _ProfileLine(
              label: '关系',
              value: _relationshipLabel(_result?.relationship),
            ),
            if (_error != null) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新加载'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _relationshipLabel(String? relationship) => switch (relationship) {
    'CONTACT' => '好友',
    'PENDING_INCOMING' => '对方向你发送了好友申请',
    'PENDING_OUTGOING' => '好友申请已发送',
    'SELF' => '自己',
    null => '正在确认…',
    _ => '非好友',
  };
}

class _ProfileLine extends StatelessWidget {
  const _ProfileLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
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
