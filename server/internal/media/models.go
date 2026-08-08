package media

import (
	"errors"
	"time"
)

var (
	ErrUnavailable   = errors.New("media service unavailable")
	ErrInvalidInput  = errors.New("invalid media input")
	ErrNotFound      = errors.New("media not found")
	ErrForbidden     = errors.New("media forbidden")
	ErrConflict      = errors.New("media conflict")
	ErrQuotaExceeded = errors.New("media quota exceeded")
	ErrUploadExpired = errors.New("media upload expired")
	ErrObjectMismatch = errors.New("uploaded object does not match reservation")
)

type Purpose string

const (
	PurposeChatImage Purpose = "CHAT_IMAGE"
	PurposeChatFile  Purpose = "CHAT_FILE"
	PurposeChatVoice Purpose = "CHAT_VOICE"
	PurposeSticker   Purpose = "STICKER"
	PurposeGIF       Purpose = "GIF"
)

type Status string

const (
	StatusUploading   Status = "UPLOADING"
	StatusReady       Status = "READY"
	StatusQuarantined Status = "QUARANTINED"
	StatusFailed      Status = "FAILED"
	StatusDeleted     Status = "DELETED"
)

type CreateUploadInput struct {
	FileName string  `json:"fileName"`
	Size     int64   `json:"size"`
	MIMEType string  `json:"mimeType"`
	SHA256   string  `json:"sha256"`
	Purpose  Purpose `json:"purpose"`
}

type UploadGrant struct {
	UploadID       string            `json:"uploadId"`
	MediaID        string            `json:"mediaId"`
	UploadURL      string            `json:"uploadUrl"`
	ExpiresAt      time.Time         `json:"expiresAt"`
	RequiredHeaders map[string]string `json:"requiredHeaders"`
}

type MediaObject struct {
	ID             string     `json:"id"`
	OwnerUserID    string     `json:"ownerUserId,omitempty"`
	OriginalName   string     `json:"originalName"`
	MIMEType       string     `json:"mimeType"`
	SizeBytes      int64      `json:"sizeBytes"`
	SHA256         string     `json:"sha256"`
	Purpose        Purpose    `json:"purpose"`
	Status         Status     `json:"status"`
	EncryptionMode string     `json:"encryptionMode"`
	CreatedAt      time.Time  `json:"createdAt"`
	ReadyAt        *time.Time `json:"readyAt,omitempty"`
}

type CompleteUploadResult struct {
	Media MediaObject `json:"media"`
}

type ObjectInfo struct {
	Size        int64
	ContentType string
	SHA256      string
	ETag        string
}
