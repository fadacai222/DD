ALTER TABLE custom_stickers
    DROP CONSTRAINT IF EXISTS custom_stickers_mime_supported;

ALTER TABLE custom_stickers
    ADD CONSTRAINT custom_stickers_mime_supported
    CHECK (mime_type IN (
        'image/png',
        'image/webp',
        'image/gif',
        'video/mp4',
        'video/webm',
        'application/x-tgsticker'
    ));

ALTER TABLE telegram_sticker_items
    DROP CONSTRAINT IF EXISTS telegram_sticker_items_mime_supported;

ALTER TABLE telegram_sticker_items
    ADD CONSTRAINT telegram_sticker_items_mime_supported
    CHECK (mime_type IN (
        'image/png',
        'image/webp',
        'application/x-tgsticker',
        'video/webm'
    ));

-- Packs imported by older DD versions may contain only their static subset.
-- Force those partial caches to refresh the next time a user imports/opens the pack.
UPDATE telegram_sticker_packs
SET cache_refreshed_at = LEAST(cache_refreshed_at, now() - interval '25 hours')
WHERE unsupported_sticker_count > 0;
