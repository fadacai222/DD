ALTER TABLE conversation_members
    ADD COLUMN hidden_through_sequence bigint
    CHECK (hidden_through_sequence IS NULL OR hidden_through_sequence >= 0);

CREATE INDEX conversation_members_user_visible_idx
    ON conversation_members(user_id, status, hidden_through_sequence, is_pinned DESC, joined_at DESC);
