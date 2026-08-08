package messaging

import (
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

var (
	ErrUnavailable       = errors.New("messaging service unavailable")
	ErrNotFound          = errors.New("messaging resource not found")
	ErrForbidden         = errors.New("messaging operation forbidden")
	ErrBlocked           = errors.New("messaging blocked by relationship")
	ErrConflict          = errors.New("messaging state conflict")
	ErrInvalidInput      = errors.New("invalid messaging input")
	ErrUnsupportedType   = errors.New("unsupported message type")
	ErrOutboxUnavailable = errors.New("outbox unavailable")
)

const (
	DefaultHistoryLimit = 50
	MaximumHistoryLimit = 100
	DefaultSyncLimit    = 200
	MaximumSyncLimit    = 500
	MaximumTextRunes    = 4000
)

var clientMessageIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{7,79}$`)

type UserPreview struct {
	ID          string `json:"id"`
	Handle      string `json:"handle"`
	DisplayName string `json:"displayName"`
}

type TextContent struct {
	Text string `json:"text"`
}

type Message struct {
	ID               string       `json:"id"`
	ConversationID   string       `json:"conversationId"`
	Sequence         int64        `json:"sequence"`
	SenderUserID     string       `json:"senderUserId"`
	SenderDeviceID   string       `json:"senderDeviceId"`
	ClientMessageID  string       `json:"clientMessageId"`
	Type             string       `json:"type"`
	Content          *TextContent `json:"content,omitempty"`
	ReplyToMessageID *string      `json:"replyToMessageId,omitempty"`
	CreatedAt        time.Time    `json:"createdAt"`
	RecalledAt       *time.Time   `json:"recalledAt,omitempty"`
}

type SendMessageInput struct {
	ClientMessageID  string       `json:"clientMessageId"`
	Type             string       `json:"type"`
	Content          *TextContent `json:"content"`
	ReplyToMessageID *string      `json:"replyToMessageId"`
}

type MessagePage struct {
	Items              []Message `json:"items"`
	NextBeforeSequence *int64    `json:"nextBeforeSequence,omitempty"`
	HasMore            bool      `json:"hasMore"`
}

type ConversationPreferences struct {
	IsPinned   bool       `json:"isPinned"`
	MutedUntil *time.Time `json:"mutedUntil,omitempty"`
}

type Conversation struct {
	ID               string                  `json:"id"`
	Type             string                  `json:"type"`
	Peer             *UserPreview            `json:"peer,omitempty"`
	LastSequence     int64                   `json:"lastSequence"`
	LastReadSequence     int64                   `json:"lastReadSequence"`
	PeerLastReadSequence *int64                  `json:"peerLastReadSequence,omitempty"`
	UnreadCount          int64                   `json:"unreadCount"`
	LastMessage      *Message                `json:"lastMessage,omitempty"`
	Preferences      ConversationPreferences `json:"preferences"`
	CreatedAt        time.Time               `json:"createdAt"`
	UpdatedAt        time.Time               `json:"updatedAt"`
}

type DirectConversationInput struct {
	UserID string `json:"userId"`
}

type UpdatePreferencesInput struct {
	IsPinned   *bool      `json:"isPinned"`
	MutedUntil *time.Time `json:"mutedUntil"`
	ClearMute  bool       `json:"clearMute"`
}

type MarkReadInput struct {
	Sequence int64 `json:"sequence"`
}

type MarkReadResult struct {
	ConversationID   string `json:"conversationId"`
	LastReadSequence int64  `json:"lastReadSequence"`
}

type SyncEvent struct {
	ID             string          `json:"eventId"`
	Cursor         int64           `json:"cursor"`
	Type           string          `json:"type"`
	ResourceID     *string         `json:"resourceId,omitempty"`
	ConversationID *string         `json:"conversationId,omitempty"`
	Sequence       *int64          `json:"sequence,omitempty"`
	Payload        json.RawMessage `json:"payload"`
	OccurredAt     time.Time       `json:"occurredAt"`
}

type SyncPage struct {
	Items      []SyncEvent `json:"items"`
	NextCursor int64       `json:"nextCursor"`
	HasMore    bool        `json:"hasMore"`
}

type SendResult struct {
	Message       Message
	NotifyUserIDs []uuid.UUID
}

func normalizeSendInput(input SendMessageInput) (SendMessageInput, error) {
	input.ClientMessageID = strings.TrimSpace(input.ClientMessageID)
	input.Type = strings.ToUpper(strings.TrimSpace(input.Type))
	if !clientMessageIDPattern.MatchString(input.ClientMessageID) {
		return SendMessageInput{}, ErrInvalidInput
	}
	if input.Type == "" {
		input.Type = "TEXT"
	}
	if input.Type != "TEXT" {
		return SendMessageInput{}, ErrUnsupportedType
	}
	if input.Content == nil {
		return SendMessageInput{}, ErrInvalidInput
	}
	if strings.TrimSpace(input.Content.Text) == "" || utf8.RuneCountInString(input.Content.Text) > MaximumTextRunes {
		return SendMessageInput{}, ErrInvalidInput
	}
	if strings.ContainsRune(input.Content.Text, '\x00') {
		return SendMessageInput{}, ErrInvalidInput
	}
	if input.ReplyToMessageID != nil {
		value := strings.TrimSpace(*input.ReplyToMessageID)
		if _, err := uuid.Parse(value); err != nil {
			return SendMessageInput{}, ErrInvalidInput
		}
		input.ReplyToMessageID = &value
	}
	return input, nil
}

func normalizeHistoryLimit(limit int) (int, error) {
	if limit == 0 {
		return DefaultHistoryLimit, nil
	}
	if limit < 1 || limit > MaximumHistoryLimit {
		return 0, ErrInvalidInput
	}
	return limit, nil
}

func normalizeSyncLimit(limit int) (int, error) {
	if limit == 0 {
		return DefaultSyncLimit, nil
	}
	if limit < 1 || limit > MaximumSyncLimit {
		return 0, ErrInvalidInput
	}
	return limit, nil
}
