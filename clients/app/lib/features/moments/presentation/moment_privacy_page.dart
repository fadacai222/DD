import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../contacts/data/contacts_api_client.dart';
import '../../contacts/domain/contact_models.dart';
import '../data/moments_api_client.dart';
import '../domain/moment_models.dart';

class MomentPrivacyPage extends StatefulWidget {
  const MomentPrivacyPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.onUnauthorized,
    this.gateway,
    this.contactsGateway,
  });

  final Uri origin;
  final String accessToken;
  final Future<String?> Function() onUnauthorized;
  final MomentsGateway? gateway;
  final ContactsGateway? contactsGateway;

  @override
  State<MomentPrivacyPage> createState() => _MomentPrivacyPageState();
}

class _MomentPrivacyPageState extends State<MomentPrivacyPage> {
  late final MomentsGateway _gateway;
  late final ContactsGateway _contacts;
  late final bool _ownsGateway;
  late final bool _ownsContacts;
  List<ContactItem> _items = const [];
  Map<String, MomentPreference> _preferences = const {};
  final Set<String> _saving = <String>{};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ownsGateway = widget.gateway == null;
    _ownsContacts = widget.contactsGateway == null;
    _gateway = widget.gateway ?? MomentsApiClient();
    _contacts = widget.contactsGateway ?? ContactsApiClient();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsGateway) _gateway.close();
    if (_ownsContacts) _contacts.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('朋友圈权限', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 10, bottom: 30),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                      child: Material(
                        color: const Color(0xFFFFE8E8),
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(_error!, style: const TextStyle(color: DdColors.danger, fontSize: 12)),
                        ),
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 10),
                    child: Text(
                      '这里是长期关系设置。单条朋友圈的“部分可见 / 不给谁看”在发表时单独选择。',
                      style: TextStyle(fontSize: 12, height: 1.5, color: DdColors.textSecondary),
                    ),
                  ),
                  for (final item in _items) _contactCard(item),
                  if (_items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('暂无联系人', style: TextStyle(color: DdColors.textSecondary))),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _contactCard(ContactItem contact) {
    final userId = contact.user.id;
    final current = _preferences[userId];
    final saving = _saving.contains(userId);
    final name = contact.remark.isEmpty ? contact.user.displayName : contact.remark;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          ListTile(
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('@${contact.user.handle}'),
            trailing: saving
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
          ),
          const Divider(height: 1, indent: 16),
          SwitchListTile(
            key: Key('moment-privacy-hide-target-$userId'),
            title: const Text('不看他'),
            subtitle: const Text('他的朋友圈不会出现在我的朋友圈'),
            value: current?.hideTarget ?? false,
            onChanged: saving ? null : (value) => _save(contact, hideTarget: value),
          ),
          SwitchListTile(
            key: Key('moment-privacy-hide-from-$userId'),
            title: const Text('不让他看'),
            subtitle: const Text('我的朋友圈不会对这个联系人可见'),
            value: current?.hideFromTarget ?? false,
            onChanged: saving ? null : (value) => _save(contact, hideFromTarget: value),
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
      final values = await Future.wait<Object>([
        _authorized((token) => _contacts.listContacts(origin: widget.origin, accessToken: token)),
        _authorized((token) => _gateway.listPreferences(origin: widget.origin, accessToken: token)),
      ]);
      if (!mounted) return;
      final contacts = values[0] as RelationshipPage<ContactItem>;
      final preferences = values[1] as List<MomentPreference>;
      setState(() {
        _items = contacts.items;
        _preferences = {for (final item in preferences) item.target.id: item};
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(
    ContactItem contact, {
    bool? hideTarget,
    bool? hideFromTarget,
  }) async {
    final userId = contact.user.id;
    final current = _preferences[userId];
    final nextHideTarget = hideTarget ?? current?.hideTarget ?? false;
    final nextHideFrom = hideFromTarget ?? current?.hideFromTarget ?? false;
    setState(() {
      _saving.add(userId);
      _error = null;
    });
    try {
      final result = await _authorized(
        (token) => _gateway.setPreference(
          origin: widget.origin,
          accessToken: token,
          userId: userId,
          hideTarget: nextHideTarget,
          hideFromTarget: nextHideFrom,
        ),
      );
      if (!mounted) return;
      setState(() {
        final next = Map<String, MomentPreference>.from(_preferences);
        if (!nextHideTarget && !nextHideFrom) {
          next.remove(userId);
        } else {
          next[userId] = result;
        }
        _preferences = next;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _saving.remove(userId));
    }
  }

  Future<T> _authorized<T>(Future<T> Function(String token) action) async {
    try {
      return await action(widget.accessToken);
    } on MomentsApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      final token = await widget.onUnauthorized();
      if (token == null || token.isEmpty) rethrow;
      return action(token);
    } on ContactsApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      final token = await widget.onUnauthorized();
      if (token == null || token.isEmpty) rethrow;
      return action(token);
    }
  }

  String _friendlyError(Object error) {
    if (error is MomentsApiException) return error.message;
    if (error is ContactsApiException) return error.message;
    return error.toString().replaceFirst('FormatException: ', '');
  }
}
