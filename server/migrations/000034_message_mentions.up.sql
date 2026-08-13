-- durable group mention index
CREATE TABLE message_mentions (
    message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sequence bigint NOT NULL,
    mentioned_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    mention_all boolean NOT NULL DEFAULT false,
    PRIMARY KEY (message_id, mentioned_user_id),
    CONSTRAINT message_mentions_sequence_positive CHECK (sequence > 0)
);

CREATE INDEX message_mentions_viewer_unread_idx
    ON message_mentions(mentioned_user_id, conversation_id, sequence DESC, message_id);

-- Backfill direct mentions from server-authored entities. Sender self-mentions are
-- intentionally excluded from unread mention summaries.
INSERT INTO message_mentions(message_id, conversation_id, sequence, mentioned_user_id, mention_all)
SELECT DISTINCT
    m.id,
    m.conversation_id,
    m.sequence,
    mention.mentioned_user_id,
    false
FROM messages m
JOIN groups g ON g.conversation_id=m.conversation_id
CROSS JOIN LATERAL (
    SELECT CASE
        WHEN entity.value->>'type'='MENTION'
         AND COALESCE(entity.value->>'userId','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        THEN (entity.value->>'userId')::uuid
    END AS mentioned_user_id
    FROM jsonb_array_elements(
        CASE
            WHEN jsonb_typeof(m.content_json->'entities')='array' THEN m.content_json->'entities'
            ELSE '[]'::jsonb
        END
    ) AS entity(value)
) mention
JOIN conversation_members cm
  ON cm.conversation_id=m.conversation_id
 AND cm.user_id=mention.mentioned_user_id
 AND cm.status='ACTIVE'
WHERE m.type='TEXT'
  AND m.recalled_at IS NULL
  AND m.deleted_at IS NULL
  AND mention.mentioned_user_id IS NOT NULL
  AND mention.mentioned_user_id <> m.sender_user_id
ON CONFLICT (message_id, mentioned_user_id) DO NOTHING;

-- Historical @all is materialized only for members already joined by the
-- message timestamp and still active when this migration runs.
INSERT INTO message_mentions(message_id, conversation_id, sequence, mentioned_user_id, mention_all)
SELECT DISTINCT
    m.id,
    m.conversation_id,
    m.sequence,
    cm.user_id,
    true
FROM messages m
JOIN groups g ON g.conversation_id=m.conversation_id
CROSS JOIN LATERAL jsonb_array_elements(
    CASE
        WHEN jsonb_typeof(m.content_json->'entities')='array' THEN m.content_json->'entities'
        ELSE '[]'::jsonb
    END
) AS entity(value)
JOIN conversation_members cm
  ON cm.conversation_id=m.conversation_id
 AND cm.status='ACTIVE'
 AND cm.user_id<>m.sender_user_id
 AND cm.joined_at<=m.created_at
WHERE m.type='TEXT'
  AND m.recalled_at IS NULL
  AND m.deleted_at IS NULL
  AND entity.value->>'type'='MENTION_ALL'
ON CONFLICT (message_id, mentioned_user_id)
DO UPDATE SET mention_all=message_mentions.mention_all OR EXCLUDED.mention_all;
