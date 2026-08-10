import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../theme/app_theme.dart';

class DdQrCodeCard extends StatelessWidget {
  const DdQrCodeCard({
    super.key,
    required this.payload,
    required this.title,
    required this.subtitle,
    this.footer,
  });

  final String payload;
  final String title;
  final String subtitle;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(maxWidth: 390),
      padding: const EdgeInsets.fromLTRB(26, 24, 26, 20),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF2A2A2A) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.3 : 0.1),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              height: 1.45,
              color: DdColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            color: Colors.white,
            child: QrImageView(
              key: const Key('dd-qr-image'),
              data: payload,
              version: QrVersions.auto,
              size: 238,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
            ),
          ),
          if (footer case final text? when text.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                color: DdColors.textTertiary,
              ),
            ),
          ],
          const SizedBox(height: 10),
          TextButton.icon(
            key: const Key('dd-qr-copy-payload'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: payload));
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('二维码内容已复制')));
            },
            icon: const Icon(Icons.copy_rounded, size: 17),
            label: const Text('复制二维码内容'),
          ),
        ],
      ),
    );
  }
}
