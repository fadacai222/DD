CREATE TABLE conversations (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    type varchar(16) NOT NULL,
    direct_pair_key varchar(80) UNIQUE,
    last_sequence bigint NOT NULL DEFAULT 0,
    last_message_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT conversations_type_valid CHECK (type IN ('DIRECT', 'GROUP')),
    CONSTRAINT conversations_direct_pair_consistent CHECK ((type = 'DIRECT') = (direct_pair_key IS NOT NULL)),
    CONSTRAINT conversations_sequence_nonnegative CHECK (last_sequence >= 0)
);

CREATE TABLE conversation_members (
    conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role varchar(16) NOT NULL DEFAULT 'MEMBER',
    status varchar(16) NOT NULL DEFAULT 'ACTIVE',
    joined_at timestamptz NOT NULL DEFAULT now(),
    left_at timestamptz,
    last_read_sequence bigint NOT NULL DEFAULT 0,
    muted_until timestamptz,
    is_pinned boolean NOT NULL DEFAULT false,
    PRIMARY KEY (conversation_id, user_id),
    CONSTRAINT conversation_members_role_valid CHECK (role IN ('MEMBER', 'ADMIN', 'OWNER')),
    CONSTRAINT conversation_members_status_valid CHECK (status IN ('ACTIVE', 'LEFT', 'REMOVED')),
    CONSTRAINT conversation_members_read_nonnegative CHECK (last_read_sequence >= 0),
    CONSTRAINT conversation_members_left_consistent CHECK ((status = 'ACTIVE' AND left_at IS NULL) OR (status <> 'ACTIVE' AND left_at IS NOT NULL))
);
CREATE INDEX conversation_members_user_idx ON conversation_members(user_id, status, joined_at DESC);

CREATE TABLE contact_requests (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    sender_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    receiver_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message varchar(200) NOT NULL DEFAULT '',
    status varchar(16) NOT NULL DEFAULT 'PENDING',
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    resolved_at timestamptz,
    CONSTRAINT contact_requests_not_self CHECK (sender_user_id <> receiver_user_id),
    CONSTRAINT contact_requests_status_valid CHECK (status IN ('PENDING', 'ACCEPTED', 'REJECTED', 'CANCELLED', 'EXPIRED')),
    CONSTRAINT contact_requests_expiry_after_create CHECK (expires_at > created_at),
    CONSTRAINT contact_requests_resolution_consistent CHECK ((status = 'PENDING' AND resolved_at IS NULL) OR (status <> 'PENDING' AND resolved_at IS NOT NULL))
);
CREATE UNIQUE INDEX contact_requests_pending_pair_idx
    ON contact_requests (LEAST(sender_user_id, receiver_user_id), GREATEST(sender_user_id, receiver_user_id))
    WHERE status = 'PENDING';
CREATE INDEX contact_requests_receiver_idx ON contact_requests(receiver_user_id, status, created_at DESC);
CREATE INDEX contact_requests_sender_idx ON contact_requests(sender_user_id, status, created_at DESC);

CREATE TABLE contacts (
    owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    contact_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    remark varchar(80) NOT NULL DEFAULT '',
    is_starred boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_user_id, contact_user_id),
    CONSTRAINT contacts_not_self CHECK (owner_user_id <> contact_user_id),
    CONSTRAINT contacts_remark_trimmed CHECK (char_length(remark) <= 80)
);
CREATE INDEX contacts_owner_created_idx ON contacts(owner_user_id, created_at DESC, contact_user_id);

CREATE TABLE contact_tags (
    owner_user_id uuid NOT NULL,
    contact_user_id uuid NOT NULL,
    tag_normalized varchar(40) NOT NULL,
    tag_name varchar(40) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_user_id, contact_user_id, tag_normalized),
    FOREIGN KEY (owner_user_id, contact_user_id) REFERENCES contacts(owner_user_id, contact_user_id) ON DELETE CASCADE,
    CONSTRAINT contact_tags_name_nonempty CHECK (char_length(btrim(tag_name)) BETWEEN 1 AND 40),
    CONSTRAINT contact_tags_normalized_nonempty CHECK (char_length(tag_normalized) BETWEEN 1 AND 40)
);

CREATE TABLE blocks (
    owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (owner_user_id, blocked_user_id),
    CONSTRAINT blocks_not_self CHECK (owner_user_id <> blocked_user_id)
);
CREATE INDEX blocks_blocked_user_idx ON blocks(blocked_user_id, owner_user_id);

CREATE TABLE relationship_rate_events (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    scope varchar(32) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT relationship_rate_scope_valid CHECK (scope IN ('HANDLE_SEARCH', 'CONTACT_REQUEST'))
);
CREATE INDEX relationship_rate_events_lookup_idx ON relationship_rate_events(user_id, scope, created_at DESC);
