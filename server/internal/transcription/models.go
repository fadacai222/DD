package transcription

import (
	"context"
	"errors"
	"time"
)

var (
	ErrUnavailable  = errors.New("voice transcription unavailable")
	ErrInvalidInput = errors.New("invalid voice transcription input")
	ErrNotFound     = errors.New("voice transcription message not found")
	ErrNotVoice     = errors.New("message is not a voice message")
	ErrProviderTemp = errors.New("temporary transcription provider failure")
	ErrProviderPerm = errors.New("permanent transcription provider failure")
)

const (
	StatusPending   = "PENDING"
	StatusRunning   = "RUNNING"
	StatusCompleted = "COMPLETED"
	StatusFailed    = "FAILED"
)

type Transcription struct {
	ID            string     `json:"id"`
	MessageID     string     `json:"messageId"`
	Status        string     `json:"status"`
	Transcript    string     `json:"transcript,omitempty"`
	Language      string     `json:"language,omitempty"`
	Model         string     `json:"model,omitempty"`
	ErrorCategory string     `json:"errorCategory,omitempty"`
	Retryable     bool       `json:"retryable"`
	Attempts      int        `json:"attempts"`
	CreatedAt     time.Time  `json:"createdAt"`
	UpdatedAt     time.Time  `json:"updatedAt"`
	StartedAt     *time.Time `json:"startedAt,omitempty"`
	CompletedAt   *time.Time `json:"completedAt,omitempty"`
}

type Preferences struct {
	AutoTranscribeEnabled bool `json:"autoTranscribeEnabled"`
	ProviderAvailable     bool `json:"providerAvailable"`
}

type UpdatePreferencesInput struct {
	AutoTranscribeEnabled bool `json:"autoTranscribeEnabled"`
}

type ProviderInput struct {
	FileName string
	MIMEType string
	Audio    []byte
}

type ProviderResult struct {
	Transcript string
	Language   string
	Model      string
}

type Provider interface {
	Transcribe(ctx context.Context, input ProviderInput) (ProviderResult, error)
}
