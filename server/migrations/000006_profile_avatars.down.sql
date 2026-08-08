UPDATE users SET avatar_media_id = NULL WHERE avatar_media_id IS NOT NULL;
DROP TABLE IF EXISTS profile_avatars;
