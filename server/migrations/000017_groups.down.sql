DROP INDEX IF EXISTS group_join_requests_group_status_time_idx;
DROP INDEX IF EXISTS group_join_requests_pending_user_idx;
DROP TABLE IF EXISTS group_join_requests;
DROP TABLE IF EXISTS group_member_profiles;
DROP INDEX IF EXISTS groups_active_updated_idx;
DROP TABLE IF EXISTS groups;

ALTER TABLE outbox_events DROP CONSTRAINT IF EXISTS outbox_aggregate_type_valid;
ALTER TABLE outbox_events
    ADD CONSTRAINT outbox_aggregate_type_valid
    CHECK (aggregate_type IN ('MESSAGE', 'CONVERSATION', 'RELATIONSHIP'));
