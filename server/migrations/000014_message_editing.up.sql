ALTER TABLE messages
    ADD COLUMN edited_at timestamptz,
    ADD COLUMN edit_version integer NOT NULL DEFAULT 0;

ALTER TABLE messages
    ADD CONSTRAINT messages_edit_state_valid
    CHECK (
        (edit_version = 0 AND edited_at IS NULL)
        OR
        (edit_version > 0 AND edited_at IS NOT NULL)
    );
