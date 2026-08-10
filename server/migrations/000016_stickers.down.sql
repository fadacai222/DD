DROP TABLE IF EXISTS sticker_rate_events;
DROP TABLE IF EXISTS user_sticker_packs;
DROP TABLE IF EXISTS telegram_sticker_items;
DROP TABLE IF EXISTS telegram_sticker_packs;
DROP TABLE IF EXISTS custom_stickers;

DELETE FROM media_objects WHERE owner_user_id IS NULL AND purpose='STICKER';

ALTER TABLE media_objects DROP CONSTRAINT media_objects_owner_user_id_fkey;
ALTER TABLE media_objects ALTER COLUMN owner_user_id SET NOT NULL;
ALTER TABLE media_objects
    ADD CONSTRAINT media_objects_owner_user_id_fkey
    FOREIGN KEY (owner_user_id) REFERENCES users(id) ON DELETE CASCADE;
