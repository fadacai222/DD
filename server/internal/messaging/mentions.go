package messaging

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type mentionCandidate struct {
	Offset int
	Length int
	Handle string
}

type mentionUser struct {
	ID     string
	Handle string
}

func scanMentionCandidates(text string) ([]mentionCandidate, error) {
	candidates := make([]mentionCandidate, 0, 4)
	unique := make(map[string]struct{}, 4)
	utf16Offset := 0
	var previousRune rune
	previousRuneSet := false

	for byteIndex := 0; byteIndex < len(text); {
		r, width := utf8.DecodeRuneInString(text[byteIndex:])
		if r == utf8.RuneError && width == 0 {
			break
		}
		if r != '@' {
			utf16Offset += utf16UnitsForRune(r)
			previousRune = r
			previousRuneSet = true
			byteIndex += width
			continue
		}

		mentionStartUTF16 := utf16Offset
		byteIndex += width
		utf16Offset++

		if previousRuneSet && (previousRune == '@' || isASCIIHandleRune(previousRune)) {
			previousRune = '@'
			previousRuneSet = true
			continue
		}
		if byteIndex >= len(text) || !isASCIILetter(text[byteIndex]) {
			previousRune = '@'
			previousRuneSet = true
			continue
		}

		handleStart := byteIndex
		for byteIndex < len(text) && isASCIIHandleByte(text[byteIndex]) {
			byteIndex++
			utf16Offset++
		}
		handle := text[handleStart:byteIndex]
		if len(handle) < 3 || len(handle) > 32 {
			previousRune = rune(text[byteIndex-1])
			previousRuneSet = true
			continue
		}
		normalized := strings.ToLower(handle)
		candidate := mentionCandidate{
			Offset: mentionStartUTF16,
			Length: utf16Offset - mentionStartUTF16,
			Handle: normalized,
		}
		candidates = append(candidates, candidate)
		if len(candidates) > MaximumMentionEntities {
			return nil, ErrTooManyMentions
		}
		unique[normalized] = struct{}{}
		if len(unique) > MaximumMentionUsers {
			return nil, ErrTooManyMentions
		}

		previousRune = rune(text[byteIndex-1])
		previousRuneSet = true
	}
	return candidates, nil
}

func utf16UnitsForRune(r rune) int {
	if r > 0xFFFF {
		return 2
	}
	return 1
}

func isASCIILetter(value byte) bool {
	return value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z'
}

func isASCIIHandleByte(value byte) bool {
	return isASCIILetter(value) || value >= '0' && value <= '9' || value == '_'
}

func isASCIIHandleRune(value rune) bool {
	if value > 0x7F {
		return false
	}
	return isASCIIHandleByte(byte(value))
}

func resolveMentionEntitiesTx(
	ctx context.Context,
	tx pgx.Tx,
	text string,
	conversationType string,
	conversationID uuid.UUID,
	senderUserID uuid.UUID,
) ([]MessageEntity, error) {
	candidates, err := scanMentionCandidates(text)
	if err != nil || len(candidates) == 0 {
		return nil, err
	}

	allowMentionAll := false
	if conversationType == "GROUP" {
		var role string
		if err := tx.QueryRow(ctx, `
			SELECT role
			FROM conversation_members
			WHERE conversation_id=$1 AND user_id=$2 AND status='ACTIVE'
		`, conversationID, senderUserID).Scan(&role); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, ErrNotFound
			}
			return nil, fmt.Errorf("load mention-all permission: %w", err)
		}
		allowMentionAll = canMentionAllRole(role)
	}

	handles := make([]string, 0, len(candidates))
	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		if candidate.Handle == "all" && conversationType == "GROUP" {
			continue
		}
		if _, exists := seen[candidate.Handle]; exists {
			continue
		}
		seen[candidate.Handle] = struct{}{}
		handles = append(handles, candidate.Handle)
	}

	users := make(map[string]mentionUser, len(handles))
	if len(handles) > 0 {
		query := `
			SELECT id::text,handle_normalized
			FROM users
			WHERE status='ACTIVE' AND handle_normalized = ANY($1::text[])
		`
		args := []any{handles}
		if conversationType == "GROUP" {
			// A group mention may only bind an active group member. Resolving an
			// arbitrary public handle would create notifications/links to users
			// who are not participants in this group.
			query = `
				SELECT u.id::text,u.handle_normalized
				FROM users u
				JOIN conversation_members cm
				  ON cm.user_id=u.id AND cm.conversation_id=$2 AND cm.status='ACTIVE'
				WHERE u.status='ACTIVE' AND u.handle_normalized = ANY($1::text[])
			`
			args = append(args, conversationID)
		}
		rows, err := tx.Query(ctx, query, args...)
		if err != nil {
			return nil, fmt.Errorf("resolve mention users: %w", err)
		}
		defer rows.Close()
		for rows.Next() {
			var user mentionUser
			if err := rows.Scan(&user.ID, &user.Handle); err != nil {
				return nil, fmt.Errorf("scan mention user: %w", err)
			}
			users[strings.ToLower(user.Handle)] = user
		}
		if err := rows.Err(); err != nil {
			return nil, fmt.Errorf("iterate mention users: %w", err)
		}
	}

	entities := make([]MessageEntity, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.Handle == "all" && conversationType == "GROUP" {
			if allowMentionAll {
				entities = append(entities, MessageEntity{
					Type:   "MENTION_ALL",
					Offset: candidate.Offset,
					Length: candidate.Length,
					Handle: "all",
				})
			}
			continue
		}
		user, exists := users[candidate.Handle]
		if !exists {
			continue
		}
		entities = append(entities, MessageEntity{
			Type:   "MENTION",
			Offset: candidate.Offset,
			Length: candidate.Length,
			UserID: user.ID,
			Handle: user.Handle,
		})
	}
	return entities, nil
}

func canMentionAllRole(role string) bool {
	return role == "OWNER" || role == "ADMIN"
}

func cloneMessageEntities(entities []MessageEntity) []MessageEntity {
	if len(entities) == 0 {
		return nil
	}
	result := make([]MessageEntity, len(entities))
	copy(result, entities)
	return result
}
