ALTER TABLE telegram_sticker_items
    DROP CONSTRAINT IF EXISTS telegram_sticker_items_mime_supported;

ALTER TABLE telegram_sticker_items
    ADD CONSTRAINT telegram_sticker_items_mime_supported
    CHECK (mime_type = 'image/webp');

ALTER TABLE custom_stickers
    DROP CONSTRAINT IF EXISTS custom_stickers_mime_supported;

ALTER TABLE custom_stickers
    ADD CONSTRAINT custom_stickers_mime_supported
    CHECK (mime_type IN ('image/png','image/webp','image/gif','video/mp4','video/webm'));
