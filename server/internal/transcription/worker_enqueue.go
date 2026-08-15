package transcription

import (
	"context"
	"fmt"
)

func (service *Service) EnqueueEligibleAuto(ctx context.Context, limit int) (int, error) {
	if !service.ProviderAvailable() { return 0, nil }
	if limit <= 0 || limit > 500 { limit = 100 }
	now := service.now().UTC()
	tag, err := service.pool.Exec(ctx, `
		WITH candidates AS (
			SELECT m.id AS message_id, eligible.user_id AS requested_by_user_id
			FROM messages m
			JOIN LATERAL (
				SELECT cm.user_id
				FROM conversation_members cm
				JOIN voice_transcription_preferences p ON p.user_id=cm.user_id
				LEFT JOIN message_local_deletions ld ON ld.message_id=m.id AND ld.user_id=cm.user_id
				WHERE cm.conversation_id=m.conversation_id AND cm.status='ACTIVE'
				  AND cm.user_id<>m.sender_user_id
				  AND p.auto_transcribe_enabled=true AND p.enabled_at IS NOT NULL
				  AND m.created_at>=p.enabled_at AND m.created_at>=cm.joined_at AND ld.message_id IS NULL
				ORDER BY cm.user_id LIMIT 1
			) eligible ON true
			LEFT JOIN voice_transcriptions existing ON existing.message_id=m.id
			WHERE m.type='VOICE' AND m.deleted_at IS NULL AND m.recalled_at IS NULL AND existing.id IS NULL
			ORDER BY m.created_at,m.id LIMIT $1
		)
		INSERT INTO voice_transcriptions(message_id,requested_by_user_id,status,available_at,created_at,updated_at)
		SELECT message_id,requested_by_user_id,'PENDING',$2,$2,$2 FROM candidates
		ON CONFLICT(message_id) DO NOTHING
	`, limit, now)
	if err != nil { return 0, fmt.Errorf("enqueue automatic voice transcriptions: %w", err) }
	return int(tag.RowsAffected()), nil
}
