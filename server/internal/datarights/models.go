package datarights

import "time"

const (
	ExportQueued     = "QUEUED"
	ExportProcessing = "PROCESSING"
	ExportCompleted  = "COMPLETED"
	ExportFailed     = "FAILED"
	ExportExpired    = "EXPIRED"

	DeletionRequested  = "REQUESTED"
	DeletionCoolingOff = "COOLING_OFF"
	DeletionExecuting  = "EXECUTING"
	DeletionCompleted  = "COMPLETED"
	DeletionCancelled  = "CANCELLED"
	DeletionFailed     = "FAILED"
)

type ExportRequest struct {
	ID          string     `json:"id"`
	Status      string     `json:"status"`
	RequestedAt time.Time  `json:"requestedAt"`
	StartedAt   *time.Time `json:"startedAt,omitempty"`
	CompletedAt *time.Time `json:"completedAt,omitempty"`
	ExpiresAt   *time.Time `json:"expiresAt,omitempty"`
	SizeBytes   *int64     `json:"sizeBytes,omitempty"`
	SHA256      string     `json:"sha256,omitempty"`
	Retryable   bool       `json:"retryable"`
}

type ExportDownload struct {
	DownloadURL string    `json:"downloadUrl"`
	ExpiresAt   time.Time `json:"expiresAt"`
	FileName    string    `json:"fileName"`
	SHA256      string    `json:"sha256"`
	SizeBytes   int64     `json:"sizeBytes"`
}

type DeletionRequest struct {
	ID               string     `json:"id"`
	Status           string     `json:"status"`
	RequestedAt      time.Time  `json:"requestedAt"`
	CoolingOffUntil  time.Time  `json:"coolingOffUntil"`
	ExecutionStarted *time.Time `json:"executionStartedAt,omitempty"`
	CompletedAt      *time.Time `json:"completedAt,omitempty"`
	CancelledAt      *time.Time `json:"cancelledAt,omitempty"`
	FailedAt         *time.Time `json:"failedAt,omitempty"`
	Retryable        bool       `json:"retryable"`
}

type RequestDeletionInput struct {
	CurrentPassword string `json:"currentPassword"`
}
