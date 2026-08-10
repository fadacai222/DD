final class CustomStickerItem {
  const CustomStickerItem({
    required this.id,
    required this.mediaId,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.sizeBytes,
    required this.sortOrder,
    required this.createdAt,
  });

  factory CustomStickerItem.fromJson(Map<String, dynamic> json) {
    return CustomStickerItem(
      id: json['id'] as String,
      mediaId: json['mediaId'] as String,
      mimeType: json['mimeType'] as String,
      width: json['width'] as int,
      height: json['height'] as int,
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      sortOrder: json['sortOrder'] as int,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    );
  }

  final String id;
  final String mediaId;
  final String mimeType;
  final int width;
  final int height;
  final int sizeBytes;
  final int sortOrder;
  final DateTime createdAt;

  StickerAsset get asset => StickerAsset(
    mediaId: mediaId,
    mimeType: mimeType,
    width: width,
    height: height,
    sizeBytes: sizeBytes,
  );
}

final class StickerPackItem {
  const StickerPackItem({
    required this.id,
    required this.mediaId,
    required this.emoji,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.sizeBytes,
    required this.sortOrder,
  });

  factory StickerPackItem.fromJson(Map<String, dynamic> json) {
    return StickerPackItem(
      id: json['id'] as String,
      mediaId: json['mediaId'] as String,
      emoji: (json['emoji'] as String?) ?? '',
      mimeType: json['mimeType'] as String,
      width: json['width'] as int,
      height: json['height'] as int,
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      sortOrder: json['sortOrder'] as int,
    );
  }

  final String id;
  final String mediaId;
  final String emoji;
  final String mimeType;
  final int width;
  final int height;
  final int sizeBytes;
  final int sortOrder;

  StickerAsset get asset => StickerAsset(
    mediaId: mediaId,
    mimeType: mimeType,
    width: width,
    height: height,
    sizeBytes: sizeBytes,
  );
}

final class StickerPackItemGroup {
  const StickerPackItemGroup({
    required this.id,
    required this.setName,
    required this.title,
    required this.coverMediaId,
    required this.supportedStickerCount,
    required this.unsupportedStickerCount,
    required this.sortOrder,
    required this.items,
    required this.updatedAt,
  });

  factory StickerPackItemGroup.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return StickerPackItemGroup(
      id: json['id'] as String,
      setName: json['setName'] as String,
      title: json['title'] as String,
      coverMediaId: (json['coverMediaId'] as String?) ?? '',
      supportedStickerCount: json['supportedStickerCount'] as int,
      unsupportedStickerCount: json['unsupportedStickerCount'] as int,
      sortOrder: json['sortOrder'] as int,
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => StickerPackItem.fromJson(
                    item.map((key, value) => MapEntry(key.toString(), value)),
                  ),
                )
                .toList(growable: false)
          : const <StickerPackItem>[],
      updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
    );
  }

  final String id;
  final String setName;
  final String title;
  final String coverMediaId;
  final int supportedStickerCount;
  final int unsupportedStickerCount;
  final int sortOrder;
  final List<StickerPackItem> items;
  final DateTime updatedAt;
}

final class StickerAsset {
  const StickerAsset({
    required this.mediaId,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.sizeBytes,
  });

  final String mediaId;
  final String mimeType;
  final int width;
  final int height;
  final int sizeBytes;
}

sealed class StickerPanelResult {
  const StickerPanelResult();
}

final class EmojiPanelResult extends StickerPanelResult {
  const EmojiPanelResult(this.emoji);
  final String emoji;
}

final class StickerAssetPanelResult extends StickerPanelResult {
  const StickerAssetPanelResult(this.asset);
  final StickerAsset asset;
}
