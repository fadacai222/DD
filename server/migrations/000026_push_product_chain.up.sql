ALTER TABLE outbox_events DROP CONSTRAINT IF EXISTS outbox_aggregate_type_valid;
ALTER TABLE outbox_events
    ADD CONSTRAINT outbox_aggregate_type_valid
    CHECK (aggregate_type IN ('MESSAGE', 'CONVERSATION', 'RELATIONSHIP', 'GROUP', 'MOMENT', 'CALL'));

CREATE INDEX IF NOT EXISTS push_jobs_recipient_pending_idx
    ON push_jobs(recipient_user_id,available_at,created_at,id)
    WHERE status='PENDING';
