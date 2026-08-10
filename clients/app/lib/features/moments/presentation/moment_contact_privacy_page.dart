import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../data/moments_api_client.dart';
import '../domain/moment_models.dart';

class MomentContactPrivacyPage extends StatefulWidget {
  const MomentContactPrivacyPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.targetUserId,
    required this.targetDisplayName,
    required this.onUnauthorized,
    this.gateway,
  });

  final Uri origin;
  final String accessToken;
  final String targetUserId;
  final String targetDisplayName;
  final Future<String?> Function() onUnauthorized;
  final MomentsGateway? gateway;

  @override
  State<MomentContactPrivacyPage> createState() =>
      _MomentContactPrivacyPageState();
}

class _MomentContactPrivacyPageState extends State<MomentContactPrivacyPage> {
  late final MomentsGateway _gateway;
  late final bool _ownsGateway;
  MomentPreference? _preference;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  late String _accessToken;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _gateway = widget.gateway ?? MomentsApiClient();
    _accessToken = widget.accessToken;
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsGateway) _gateway.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final targetName = widget.targetDisplayName.trim().isEmpty
        ? '该联系人'
        : widget.targetDisplayName.trim();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '朋友圈权限',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.only(top: 10, bottom: 28),
              children: [
                if (_error != null)
                  Material(
                    color: const Color(0xFFFFE8E8),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 9, 10, 9),
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
                              _error!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: DdColors.danger,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _saving ? null : () => unawaited(_load()),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Text(
                    targetName,
                    style: const TextStyle(
                      fontSize: 13,
                      color: DdColors.textSecondary,
                    ),
                  ),
                ),
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: Column(
                    children: [
                      SwitchListTile(
                        key: const Key('moment-contact-hide-target'),
                        title: const Text('不看他的朋友圈'),
                        subtitle: const Text('对方的朋友圈不再出现在我的朋友圈中'),
                        value: _preference?.hideTarget ?? false,
                        onChanged: _saving
                            ? null
                            : (value) => unawaited(
                                _save(hideTarget: value),
                              ),
                      ),
                      const Divider(height: 1, indent: 16),
                      SwitchListTile(
                        key: const Key('moment-contact-hide-from-target'),
                        title: const Text('不让他看我的朋友圈'),
                        subtitle: const Text('我的朋友圈将不再对这个联系人可见'),
                        value: _preference?.hideFromTarget ?? false,
                        onChanged: _saving
                            ? null
                            : (value) => unawaited(
                                _save(hideFromTarget: value),
                              ),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Text(
                    '这是长期联系人权限；单条朋友圈的“部分可见 / 不给谁看”仍在发表时单独选择。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: DdColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final preferences = await _authorized(
        (token) => _gateway.listPreferences(
          origin: widget.origin,
          accessToken: token,
        ),
      );
      MomentPreference? current;
      for (final item in preferences) {
        if (item.target.id == widget.targetUserId) {
          current = item;
          break;
        }
      }
      if (!mounted) return;
      setState(() => _preference = current);
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save({bool? hideTarget, bool? hideFromTarget}) async {
    final nextHideTarget = hideTarget ?? _preference?.hideTarget ?? false;
    final nextHideFromTarget =
        hideFromTarget ?? _preference?.hideFromTarget ?? false;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await _authorized(
        (token) => _gateway.setPreference(
          origin: widget.origin,
          accessToken: token,
          userId: widget.targetUserId,
          hideTarget: nextHideTarget,
          hideFromTarget: nextHideFromTarget,
        ),
      );
      if (!mounted) return;
      setState(() {
        _preference = !nextHideTarget && !nextHideFromTarget ? null : result;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<T> _authorized<T>(Future<T> Function(String token) action) async {
    try {
      return await action(_accessToken);
    } on MomentsApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      final token = await widget.onUnauthorized();
      if (token == null || token.trim().isEmpty) rethrow;
      _accessToken = token.trim();
      return action(_accessToken);
    }
  }

  String _friendlyError(Object error) {
    if (error is MomentsApiException) return error.message;
    return error.toString().replaceFirst('FormatException: ', '');
  }
}
