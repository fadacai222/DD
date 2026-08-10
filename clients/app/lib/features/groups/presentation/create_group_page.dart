import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../../contacts/data/contacts_api_client.dart';
import '../../contacts/domain/contact_models.dart';
import '../data/groups_api_client.dart';
import '../domain/group_models.dart';

class CreateGroupPage extends StatefulWidget {
  const CreateGroupPage({
    super.key,
    required this.origin,
    required this.accessToken,
    this.groupsGateway,
    this.contactsGateway,
  });

  final Uri origin;
  final String accessToken;
  final GroupsGateway? groupsGateway;
  final ContactsGateway? contactsGateway;

  @override
  State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  late final GroupsGateway _groups;
  late final ContactsGateway _contacts;
  late final bool _ownsGroups;
  late final bool _ownsContacts;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selected = <String>{};
  List<ContactItem> _items = const [];
  bool _loading = true;
  bool _creating = false;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _ownsGroups = widget.groupsGateway == null;
    _ownsContacts = widget.contactsGateway == null;
    _groups = widget.groupsGateway ?? GroupsApiClient();
    _contacts = widget.contactsGateway ?? ContactsApiClient();
    unawaited(_load());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    if (_ownsGroups) _groups.close();
    if (_ownsContacts) _contacts.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final page = await _contacts.listContacts(
        origin: widget.origin,
        accessToken: widget.accessToken,
      );
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '联系人加载失败：$error';
      });
    }
  }

  Future<void> _create() async {
    if (_creating) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入群聊名称。');
      return;
    }
    if (_selected.isEmpty) {
      setState(() => _error = '至少选择 1 位联系人。');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final group = await _groups.createGroup(
        origin: widget.origin,
        accessToken: widget.accessToken,
        name: name,
        memberIds: _selected.toList(growable: false),
      );
      if (!mounted) return;
      Navigator.of(context).pop<GroupInfo>(group);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '创建群聊失败：$error');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _items.where((item) {
      if (_query.isEmpty) return true;
      final value = _query.toLowerCase();
      return item.user.displayName.toLowerCase().contains(value) ||
          item.user.handle.toLowerCase().contains(value) ||
          item.remark.toLowerCase().contains(value);
    }).toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: const Text('发起群聊'),
        actions: [
          TextButton(
            key: const Key('create-group-submit'),
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    '创建${_selected.isEmpty ? '' : '(${_selected.length})'}',
                    style: const TextStyle(color: DdColors.greenPressed),
                  ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    key: const Key('create-group-name'),
                    controller: _nameController,
                    maxLength: 80,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: '群聊名称',
                      hintText: '例如：项目讨论组',
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerLow,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(DdRadii.surface),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    key: const Key('create-group-search'),
                    controller: _searchController,
                    onChanged: (value) =>
                        setState(() => _query = value.trim()),
                    decoration: InputDecoration(
                      hintText: '搜索联系人',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerLow,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(DdRadii.surface),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : visible.isEmpty
                      ? const Center(child: Text('没有可选择的联系人'))
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final item = visible[index];
                            final selected = _selected.contains(item.user.id);
                            final title = item.remark.trim().isEmpty
                                ? item.user.displayName
                                : item.remark.trim();
                            return CheckboxListTile(
                              key: Key('create-group-contact-${item.user.id}'),
                              value: selected,
                              onChanged: (_) => setState(() {
                                if (selected) {
                                  _selected.remove(item.user.id);
                                } else if (_selected.length < 99) {
                                  _selected.add(item.user.id);
                                }
                              }),
                              secondary: ProfileAvatar(
                                origin: widget.origin,
                                accessToken: widget.accessToken,
                                userId: item.user.id,
                                displayName: title,
                                size: 42,
                              ),
                              title: Text(title),
                              subtitle: Text('DDID：${item.user.handle}'),
                              controlAffinity: ListTileControlAffinity.trailing,
                            );
                          },
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
