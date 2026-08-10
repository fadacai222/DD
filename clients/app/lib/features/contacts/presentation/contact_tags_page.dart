import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import '../../auth/presentation/widgets/profile_avatar.dart';
import '../domain/contact_models.dart';

class ContactTagsPage extends StatefulWidget {
  const ContactTagsPage({
    super.key,
    required this.origin,
    required this.accessToken,
    required this.contacts,
    required this.onOpenContact,
  });

  final Uri origin;
  final String accessToken;
  final List<ContactItem> contacts;
  final Future<void> Function(ContactItem contact) onOpenContact;

  @override
  State<ContactTagsPage> createState() => _ContactTagsPageState();
}

class _ContactTagsPageState extends State<ContactTagsPage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupContacts(widget.contacts);
    final tags =
        grouped.keys
            .where(
              (tag) => _query.isEmpty || tag.toLowerCase().contains(_query),
            )
            .toList(growable: false)
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: const Text('标签')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: TextField(
                key: const Key('contact-tags-search'),
                controller: _search,
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                decoration: InputDecoration(
                  hintText: '搜索标签',
                  prefixIcon: const Icon(Icons.search_rounded, size: 19),
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DdRadii.pill),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DdRadii.pill),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DdRadii.pill),
                    borderSide: const BorderSide(
                      color: DdColors.green,
                      width: 1.2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            Expanded(
              child: tags.isEmpty
                  ? _EmptyTags(filtered: _query.isNotEmpty)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                      itemCount: tags.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final tag = tags[index];
                        final members = grouped[tag]!
                          ..sort(
                            (a, b) => _displayName(a).toLowerCase().compareTo(
                              _displayName(b).toLowerCase(),
                            ),
                          );
                        return _TagTile(
                          tag: tag,
                          members: members,
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => _ContactTagDetailPage(
                                tag: tag,
                                members: members,
                                origin: widget.origin,
                                accessToken: widget.accessToken,
                                onOpenContact: widget.onOpenContact,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

Map<String, List<ContactItem>> _groupContacts(List<ContactItem> contacts) {
  final grouped = <String, List<ContactItem>>{};
  for (final contact in contacts) {
    for (final rawTag in contact.tags) {
      final tag = rawTag.trim();
      if (tag.isEmpty) continue;
      grouped.putIfAbsent(tag, () => <ContactItem>[]).add(contact);
    }
  }
  return grouped;
}

String _displayName(ContactItem contact) => contact.remark.trim().isEmpty
    ? contact.user.displayName
    : contact.remark.trim();

class _TagTile extends StatelessWidget {
  const _TagTile({
    required this.tag,
    required this.members,
    required this.onTap,
  });

  final String tag;
  final List<ContactItem> members;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = members.take(3).map(_displayName).join('、');
    return Material(
      key: Key('contact-tag-$tag'),
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(DdRadii.surface),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F4FF),
                  borderRadius: BorderRadius.circular(DdRadii.control),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.sell_rounded,
                  color: Color(0xFF4E9BEA),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tag,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${members.length} 位联系人${preview.isEmpty ? '' : ' · $preview'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: DdColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: DdColors.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContactTagDetailPage extends StatelessWidget {
  const _ContactTagDetailPage({
    required this.tag,
    required this.members,
    required this.origin,
    required this.accessToken,
    required this.onOpenContact,
  });

  final String tag;
  final List<ContactItem> members;
  final Uri origin;
  final String accessToken;
  final Future<void> Function(ContactItem contact) onOpenContact;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: Text(tag)),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: members.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final contact = members[index];
          return Material(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(DdRadii.surface),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              key: Key('tag-contact-${contact.user.id}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 3,
              ),
              leading: ProfileAvatar(
                origin: origin,
                accessToken: accessToken,
                userId: contact.user.id,
                displayName: _displayName(contact),
                size: 40,
              ),
              title: Text(_displayName(contact)),
              subtitle: Text('DDID：${contact.user.handle}'),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                color: DdColors.textTertiary,
              ),
              onTap: () => onOpenContact(contact),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyTags extends StatelessWidget {
  const _EmptyTags({required this.filtered});

  final bool filtered;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.sell_outlined,
              size: 44,
              color: DdColors.textTertiary,
            ),
            const SizedBox(height: 12),
            Text(filtered ? '没有匹配的标签' : '还没有联系人标签'),
            const SizedBox(height: 6),
            if (!filtered)
              const Text(
                '可在联系人资料的“备注与标签”中整理联系人。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: DdColors.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}
