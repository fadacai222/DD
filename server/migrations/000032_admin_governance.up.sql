CREATE TABLE user_reports (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    reporter_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category varchar(32) NOT NULL,
    reason varchar(1000) NOT NULL,
    status varchar(24) NOT NULL DEFAULT 'PENDING',
    assigned_admin_id uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    resolution_reason varchar(1000),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    CONSTRAINT user_reports_not_self CHECK (reporter_user_id <> target_user_id),
    CONSTRAINT user_reports_category_valid CHECK (category IN ('SPAM', 'HARASSMENT', 'IMPERSONATION', 'SCAM', 'OTHER')),
    CONSTRAINT user_reports_reason_nonempty CHECK (char_length(btrim(reason)) BETWEEN 3 AND 1000),
    CONSTRAINT user_reports_status_valid CHECK (status IN ('PENDING', 'IN_REVIEW', 'RESOLVED', 'DISMISSED')),
    CONSTRAINT user_reports_resolution_consistent CHECK (
        (status IN ('PENDING', 'IN_REVIEW') AND resolved_at IS NULL) OR
        (status IN ('RESOLVED', 'DISMISSED') AND resolved_at IS NOT NULL AND resolution_reason IS NOT NULL)
    )
);
CREATE UNIQUE INDEX user_reports_open_duplicate_idx
    ON user_reports(reporter_user_id, target_user_id)
    WHERE status IN ('PENDING', 'IN_REVIEW');
CREATE INDEX user_reports_queue_idx ON user_reports(status, created_at ASC);
CREATE INDEX user_reports_reporter_idx ON user_reports(reporter_user_id, created_at DESC);
CREATE INDEX user_reports_target_idx ON user_reports(target_user_id, created_at DESC);

CREATE TABLE user_moderation_actions (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    target_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    actor_admin_id uuid NOT NULL REFERENCES admin_accounts(id) ON DELETE RESTRICT,
    action varchar(24) NOT NULL,
    reason varchar(1000) NOT NULL,
    previous_status varchar(24) NOT NULL,
    new_status varchar(24) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT user_moderation_actions_action_valid CHECK (action IN ('SUSPEND', 'UNSUSPEND')),
    CONSTRAINT user_moderation_actions_reason_nonempty CHECK (char_length(btrim(reason)) BETWEEN 3 AND 1000),
    CONSTRAINT user_moderation_actions_previous_status_valid CHECK (previous_status IN ('ACTIVE', 'SUSPENDED')),
    CONSTRAINT user_moderation_actions_new_status_valid CHECK (new_status IN ('ACTIVE', 'SUSPENDED'))
);
CREATE INDEX user_moderation_actions_target_idx ON user_moderation_actions(target_user_id, created_at DESC);
CREATE INDEX user_moderation_actions_actor_idx ON user_moderation_actions(actor_admin_id, created_at DESC);
