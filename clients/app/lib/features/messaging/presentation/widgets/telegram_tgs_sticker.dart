import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

bool isTelegramTgsMime(String? mimeType) =>
    (mimeType ?? '').split(';').first.trim().toLowerCase() ==
    'application/x-tgsticker';

class TelegramTgsSticker extends StatelessWidget {
  const TelegramTgsSticker({
    super.key,
    required this.bytes,
    this.fit = BoxFit.contain,
    this.animate = true,
  });

  final Uint8List bytes;
  final BoxFit fit;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Lottie.memory(
      bytes,
      decoder: LottieComposition.decodeGZip,
      fit: fit,
      frameRate: FrameRate.composition,
      repeat: true,
      animate: animate && !MediaQuery.disableAnimationsOf(context),
      errorBuilder: (context, error, stackTrace) => const Center(
        child: Icon(Icons.broken_image_outlined, color: Color(0xFF9B9B9B)),
      ),
    );
  }
}
