DELETE FROM message_media WHERE role='MOTION';
ALTER TABLE message_media DROP CONSTRAINT message_media_role_valid;
ALTER TABLE message_media
    ADD CONSTRAINT message_media_role_valid CHECK (role IN ('PRIMARY','THUMBNAIL'));
