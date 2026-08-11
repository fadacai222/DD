import 'package:flutter/material.dart';

import '../../../../theme/app_theme.dart';
import '../../data/link_preview_api_client.dart';

class MessageLinkPreview extends StatefulWidget {
  const MessageLinkPreview({
    super.key,
    required this.url,
    required this.loader,
    required this.onOpen,
  });

  final Uri url;
  final Future<LinkPreviewData> Function(Uri url) loader;
  final ValueChanged<Uri> onOpen;

  @override
  State<MessageLinkPreview> createState() => _MessageLinkPreviewState();
}

class _MessageLinkPreviewState extends State<MessageLinkPreview> {
  late Future<LinkPreviewData> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader(widget.url);
  }

  @override
  void didUpdateWidget(covariant MessageLinkPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _future = widget.loader(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LinkPreviewData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(top: 8),
            child: SizedBox(
              key: Key('message-link-preview-loading'),
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
          );
        }
        final preview = snapshot.data;
        if (preview == null || preview.title.isEmpty) {
          return const SizedBox.shrink();
        }
        final colors = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Material(
            key: const Key('message-link-preview'),
            color: colors.surfaceContainerHighest.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(DdRadii.control),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => widget.onOpen(preview.url),
              child: Container(
                constraints: const BoxConstraints(minWidth: 180, maxWidth: 380),
                decoration: const BoxDecoration(
                  border: Border(
                    left: BorderSide(color: DdColors.greenPressed, width: 3),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(10, 9, 11, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (preview.siteName.isNotEmpty)
                      Text(
                        preview.siteName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: DdColors.textSecondary,
                        ),
                      ),
                    if (preview.siteName.isNotEmpty) const SizedBox(height: 3),
                    Text(
                      preview.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (preview.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        preview.description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.3,
                          color: DdColors.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      preview.url.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: ddLinkPreviewColor(Theme.of(context).brightness),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

Color ddLinkPreviewColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFF65B5FF)
    : const Color(0xFF1677FF);
