ALTER TABLE calls ADD COLUMN conversation_id uuid REFERENCES conversations(id) ON DELETE RESTRICT;

INSERT INTO conversations(type,direct_pair_key,created_at,updated_at)
SELECT 'DIRECT', pair_key, MIN(created_at), MIN(created_at)
FROM (
    SELECT created_at, CASE
        WHEN caller_user_id::text < callee_user_id::text
        THEN caller_user_id::text || ':' || callee_user_id::text
        ELSE callee_user_id::text || ':' || caller_user_id::text
    END AS pair_key
    FROM calls
) historical_pairs
GROUP BY pair_key
ON CONFLICT (direct_pair_key) DO NOTHING;

UPDATE calls call
SET conversation_id = conversation.id
FROM conversations conversation
WHERE conversation.type='DIRECT'
  AND conversation.direct_pair_key = CASE
      WHEN call.caller_user_id::text < call.callee_user_id::text
      THEN call.caller_user_id::text || ':' || call.callee_user_id::text
      ELSE call.callee_user_id::text || ':' || call.caller_user_id::text
  END;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM calls WHERE conversation_id IS NULL) THEN
        RAISE EXCEPTION 'cannot backfill calls.conversation_id: direct conversation missing';
    END IF;
END $$;

ALTER TABLE calls ALTER COLUMN conversation_id SET NOT NULL;
CREATE INDEX calls_conversation_time_idx ON calls(conversation_id, created_at DESC, id DESC);
