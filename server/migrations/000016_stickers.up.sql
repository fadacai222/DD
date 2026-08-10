ALTER TABLE media_objects DROP CONSTRAINT media_objects_owner_user_id_fkey;
ALTER TABLE media_objects ALTER COLUMN owner_user_id DROP NOT NULL;
ALTER TABLE media_objects
    ADD CONSTRAINT media_objects_owner_user_id_fkey
    FOREIGN KEY (owner_user_id) REFERENCES users(id) ON DELETE SET NULL;

CREATE TABLE custom_stickers (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    media_id uuid NOT NULL REFERENCES media_objects(id) ON DELETE CASCADE,
    mime_type varchar(120) NOT NULL,
    width integer NOT NULL,
    height integer NOT NULL,
    size_bytes bigint NOT NULL,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CONSTRAINT custom_stickers_dimensions_positive CHECK (width > 0 AND height > 0),
    CONSTRAINT custom_stickers_size_positive CHECK (size_bytes > 0),
    CONSTRAINT custom_stickers_sort_nonnegative CHECK (sort_order >= 0),
    CONSTRAINT custom_stickers_mime_supported CHECK (mime_type IN ('image/png','image/webp','image/gif')),
    UNIQUE(owner_user_id, media_id)
);
CREATE INDEX custom_stickers_owner_order_idx
    ON custom_stickers(owner_user_id, sort_order, created_at, id)
    WHERE deleted_at IS NULL;

CREATE TABLE telegram_sticker_packs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    set_name varchar(64) NOT NULL UNIQUE,
    title varchar(128) NOT NULL,
    source_identifier varchar(128) NOT NULL,
    cover_media_id uuid REFERENCES media_objects(id) ON DELETE SET NULL,
    supported_sticker_count integer NOT NULL DEFAULT 0,
    unsupported_sticker_count integer NOT NULL DEFAULT 0,
    source_updated_at timestamptz NOT NULL DEFAULT now(),
    cache_refreshed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT telegram_sticker_packs_set_name_valid CHECK (set_name ~ '^[A-Za-z0-9_]{1,64}$'),
    CONSTRAINT telegram_sticker_packs_title_nonempty CHECK (char_length(btrim(title)) BETWEEN 1 AND 128),
    CONSTRAINT telegram_sticker_packs_counts_nonnegative CHECK (supported_sticker_count >= 0 AND unsupported_sticker_count >= 0)
);

CREATE TABLE telegram_sticker_items (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    pack_id uuid NOT NULL REFERENCES telegram_sticker_packs(id) ON DELETE CASCADE,
    source_file_id text NOT NULL,
    source_file_unique_id varchar(160) NOT NULL,
    media_id uuid NOT NULL REFERENCES media_objects(id) ON DELETE RESTRICT,
    emoji varchar(32) NOT NULL DEFAULT '',
    mime_type varchar(120) NOT NULL,
    width integer NOT NULL,
    height integer NOT NULL,
    size_bytes bigint NOT NULL,
    sort_order integer NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT telegram_sticker_items_dimensions_positive CHECK (width > 0 AND height > 0),
    CONSTRAINT telegram_sticker_items_size_positive CHECK (size_bytes > 0),
    CONSTRAINT telegram_sticker_items_sort_nonnegative CHECK (sort_order >= 0),
    CONSTRAINT telegram_sticker_items_mime_supported CHECK (mime_type = 'image/webp'),
    UNIQUE(pack_id, sort_order),
    UNIQUE(pack_id, source_file_unique_id)
);
CREATE INDEX telegram_sticker_items_source_unique_idx
    ON telegram_sticker_items(source_file_unique_id, created_at DESC);
CREATE INDEX telegram_sticker_items_pack_order_idx
    ON telegram_sticker_items(pack_id, sort_order, id);

CREATE TABLE user_sticker_packs (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pack_id uuid NOT NULL REFERENCES telegram_sticker_packs(id) ON DELETE CASCADE,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, pack_id),
    CONSTRAINT user_sticker_packs_sort_nonnegative CHECK (sort_order >= 0)
);
CREATE INDEX user_sticker_packs_user_order_idx
    ON user_sticker_packs(user_id, sort_order, created_at, pack_id);

CREATE TABLE sticker_rate_events (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    scope varchar(32) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sticker_rate_scope_valid CHECK (scope IN ('TELEGRAM_IMPORT'))
);
CREATE INDEX sticker_rate_events_lookup_idx
    ON sticker_rate_events(user_id, scope, created_at DESC);
