DELETE FROM custom_stickers
WHERE mime_type IN ('video/mp4','video/webm');

ALTER TABLE custom_stickers
    DROP CONSTRAINT IF EXISTS custom_stickers_mime_supported;

ALTER TABLE custom_stickers
    ADD CONSTRAINT custom_stickers_mime_supported
    CHECK (mime_type IN ('image/png','image/webp','image/gif'));
