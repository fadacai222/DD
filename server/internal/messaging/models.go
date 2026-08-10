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
	ErrPinnedLimit       = errors.New("pinned conversation limit reached")
	ErrEditForbidden     = errors.New("message edit forbidden")
	ErrEditUnsupported   = errors.New("message edit unsupported")
	ErrEditConflict      = errors.New("message edit version conflict")
	ErrTooManyMentions   = errors.New("too many mentions")
)

const (
	DefaultHistoryLimit    = 50
	MaximumHistoryLimit    = 100
	DefaultSyncLimit       = 200
	MaximumSyncLimit       = 500
	MaximumTextRunes       = 4000
	MaximumPinnedChats     = 10
	MaximumMentionEntities = 64
	MaximumMentionUsers    = 32
)

var clientMessageIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{7,79}$`)

type UserPreview struct {
	ID          string `json:"id"`
	Handle      string `json:"handle"`
	DisplayName string `json:"displayName"`
}

type MessageEntity struct {
	Type   string `json:"type"`
	Offset int    `json:"offset"`
	Length int    `json:"length"`
	UserID string `json:"userId,omitempty"`
	Handle string `json:"handle,omitempty"`
}

type TextContent struct {
	Text          string          `json:"text,omitempty"`
	Entities      []MessageEntity `json:"entities,omitempty"`
	MediaID       string          `json:"mediaId,omitempty"`
	PosterMediaID string          `json:"posterMediaId,omitempty"`
	Width         int             `json:"width,omitempty"`
	Height        int             `json:"height,omitempty"`
	FileName      string          `json:"fileName,omitempty"`
	MIMEType      string          `json:"mimeType,omitempty"`
	SizeBytes     int64           `json:"sizeBytes,omitempty"`
	DurationMS    int             `json:"durationMs,omitempty"`
}

type Message struct {
	ID                     string       `json:"id"`
	ConversationID         string       `json:"conversationId"`
	Sequence               int64        `json:"sequence"`
	SenderUserID           string       `json:"senderUserId"`
	SenderDeviceID         string       `json:"senderDeviceId"`
	ClientMessageID        string       `json:"clientMessageId"`
	Type                   string       `json:"type"`
	Content                *TextContent `json:"content,omitempty"`
	ReplyToMessageID       *string      `json:"replyToMessageId,omitempty"`
	ForwardedFromMessageID *string      `json:"forwardedFromMessageId,omitempty"`
	CreatedAt              time.Time    `json:"createdAt"`
	EditedAt               *time.Time   `json:"editedAt,omitempty"`
	EditVersion            int          `json:"editVersion"`
	RecalledAt             *time.Time   `json:"recalledAt,omitempty"`
}

type SendMessageInput struct {
	ClientMessageID  string       `json:"clientMessageId"`
	Type             string       `json:"type"`
	Content          *TextContent `json:"content"`
	ReplyToMessageID *string      `json:"replyToMessageId"`
	forwardSourceID  *uuid.UUID
	trustedEntities  []MessageEntity
}

type EditMessageInput struct {
	Text                string `json:"text"`
	ExpectedEditVersion int    `json:"expectedEditVersion"`
}

type MessagePage struct {
	Items              []Message `json:"items"`
	NextBeforeSequence *int64    `json:"nextBeforeSequence,omitempty"`
	HasMore            bool      `json:"hasMore"`
}

type SavedMessage struct {
	Message Message   `json:"message"`
	SavedAt time.Time `json:"savedAt"`
}

type PinnedMessage struct {
	Message        Message   `json:"message"`
	PinnedByUserID string    `json:"pinnedByUserId"`
	PinnedAt       time.Time `json:"pinnedAt"`
}

type MessageSearchHit struct {
	Message Message `json:"message"`
}

type ForwardMessageInput struct {
	TargetConversationID string `json:"targetConversationId"`
	ClientMessageID      string `json:"clientMessageId"`
}

type ConversationPreferences struct {
	IsPinned   bool       `json:"isPinned"`
	MutedUntil *time.Time `json:"mutedUntil,omitempty"`
	ArchivedAt *time.Time `json:"archivedAt,omitempty"`
}

type GroupPreview struct {
	ID            string        `json:"id"`
	Name          string        `json:"name"`
	MemberCount   int           `json:"memberCount"`
	AvatarMembers []UserPreview `json:"avatarMembers"`
}

type Conversation struct {
	ID                   string                  `json:"id"`
	Type                 string                  `json:"type"`
	Peer                 *UserPreview            `json:"peer,omitempty"`
	Group                *GroupPreview           `json:"group,omitempty"`
	CanWrite             bool                    `json:"canWrite"`
	LastSequence         int64                   `json:"lastSequence"`
	LastReadSequence     int64                   `json:"lastReadSequence"`
	PeerLastReadSequence *int64                  `json:"peerLastReadSequence,omitempty"`
	UnreadCount          int64                   `json:"unreadCount"`
	LastMessage          *Message                `json:"lastMessage,omitempty"`
	Preferences          ConversationPreferences `json:"preferences"`
	CreatedAt            time.Time               `json:"createdAt"`
	UpdatedAt            time.Time               `json:"updatedAt"`
}

type DirectConversationInput struct {
	UserID string `json:"userId"`
}

type UpdatePreferencesInput struct {
	IsPinned   *bool      `json:"isPinned"`
	MutedUntil *time.Time `json:"mutedUntil"`
	ClearMute  bool       `json:"clearMute"`
	IsArchived *bool      `json:"isArchived"`
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

func normalizeEditMessageInput(input EditMessageInput) (EditMessageInput, error) {
	if input.ExpectedEditVersion < 0 ||
		strings.TrimSpace(input.Text) == "" ||
		utf8.RuneCountInString(input.Text) > MaximumTextRunes ||
		strings.ContainsRune(input.Text, '\x00') {
		return EditMessageInput{}, ErrInvalidInput
	}
	return input, nil
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
	switch input.Type {
	case "TEXT", "IMAGE", "GIF", "STICKER", "FILE", "VOICE", "VIDEO":
	default:
		return SendMessageInput{}, ErrUnsupportedType
	}
	if input.Content == nil {
		return SendMessageInput{}, ErrInvalidInput
	}
	contentCopy := *input.Content
	input.Content = &contentCopy
	// Message entities are server-authoritative. Any entity supplied by a
	// normal client is discarded here; trusted forward paths carry their
	// preserved binding through the private trustedEntities field instead.
	input.Content.Entities = nil
	switch input.Type {
	case "TEXT":
		if strings.TrimSpace(input.Content.Text) == "" || utf8.RuneCountInString(input.Content.Text) > MaximumTextRunes {
			return SendMessageInput{}, ErrInvalidInput
		}
		if strings.ContainsRune(input.Content.Text, '\x00') || hasMediaFields(input.Content) {
			return SendMessageInput{}, ErrInvalidInput
		}
	case "IMAGE", "GIF", "STICKER":
		mediaID, err := normalizeMediaID(input.Content.MediaID)
		if err != nil {
			return SendMessageInput{}, err
		}
		if input.Content.Width < 1 || input.Content.Width > 20000 || input.Content.Height < 1 || input.Content.Height > 20000 {
			return SendMessageInput{}, ErrInvalidInput
		}
		if input.Content.Text != "" || input.Content.FileName != "" || input.Content.MIMEType != "" || input.Content.SizeBytes != 0 || input.Content.DurationMS != 0 {
			return SendMessageInput{}, ErrInvalidInput
		}
		input.Content.MediaID = mediaID
	case "FILE":
		mediaID, err := normalizeMediaID(input.Content.MediaID)
		if err != nil {
			return SendMessageInput{}, err
		}
		if input.Content.Text != "" || input.Content.Width != 0 || input.Content.Height != 0 || input.Content.FileName != "" || input.Content.MIMEType != "" || input.Content.SizeBytes != 0 || input.Content.DurationMS != 0 {
			return SendMessageInput{}, ErrInvalidInput
		}
		input.Content.MediaID = mediaID
	case "VOICE":
		mediaID, err := normalizeMediaID(input.Content.MediaID)
		if err != nil {
			return SendMessageInput{}, err
		}
		if input.Content.DurationMS < 250 || input.Content.DurationMS > 10*60*1000 || input.Content.Text != "" || input.Content.Width != 0 || input.Content.Height != 0 || input.Content.FileName != "" || input.Content.MIMEType != "" || input.Content.SizeBytes != 0 || input.Content.PosterMediaID != "" {
			return SendMessageInput{}, ErrInvalidInput
		}
		input.Content.MediaID = mediaID
	case "VIDEO":
		mediaID, err := normalizeMediaID(input.Content.MediaID)
		if err != nil {
			return SendMessageInput{}, err
		}
		posterID, err := normalizeMediaID(input.Content.PosterMediaID)
		if err != nil || posterID == mediaID {
			return SendMessageInput{}, ErrInvalidInput
		}
		if input.Content.Width < 1 || input.Content.Width > 20000 ||
			input.Content.Height < 1 || input.Content.Height > 20000 ||
			input.Content.DurationMS < 1 || input.Content.DurationMS > 24*60*60*1000 ||
			input.Content.Text != "" || input.Content.FileName != "" ||
			input.Content.MIMEType != "" || input.Content.SizeBytes != 0 {
			return SendMessageInput{}, ErrInvalidInput
		}
		input.Content.MediaID = mediaID
		input.Content.PosterMediaID = posterID
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

func hasMediaFields(content *TextContent) bool {
	return content.MediaID != "" || content.PosterMediaID != "" || content.Width != 0 || content.Height != 0 || content.FileName != "" || content.MIMEType != "" || content.SizeBytes != 0 || content.DurationMS != 0
}

func normalizeMediaID(raw string) (string, error) {
	mediaID := strings.TrimSpace(raw)
	if _, err := uuid.Parse(mediaID); err != nil {
		return "", ErrInvalidInput
	}
	return mediaID, nil
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
