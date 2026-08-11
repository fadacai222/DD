package push

import "time"

const (
	ProviderFCM         = "FCM"
	ProviderAPNS        = "APNS"
	ProviderUnifiedPush = "UNIFIEDPUSH"

	PreviewFull       = "FULL"
	PreviewSenderOnly = "SENDER_ONLY"
	PreviewHidden     = "HIDDEN"
)

type Preferences struct {
	PushEnabled bool      `json:"pushEnabled"`
	PreviewMode string    `json:"previewMode"`
	UpdatedAt   time.Time `json:"updatedAt"`
}

type UpdatePreferencesInput struct {
	PushEnabled bool   `json:"pushEnabled"`
	PreviewMode string `json:"previewMode"`
}

type RegisterEndpointInput struct {
	Provider    string `json:"provider"`
	Endpoint    string `json:"endpoint"`
	AppID       string `json:"appId"`
	Environment string `json:"environment"`
}

type Endpoint struct {
	ID              string     `json:"id"`
	Provider        string     `json:"provider"`
	AppID           string     `json:"appId"`
	Environment     string     `json:"environment"`
	Status          string     `json:"status"`
	FailureCount    int        `json:"failureCount"`
	LastSuccessAt   *time.Time `json:"lastSuccessAt,omitempty"`
	LastFailureAt   *time.Time `json:"lastFailureAt,omitempty"`
	LastFailureCode string     `json:"lastFailureCode,omitempty"`
	UpdatedAt       time.Time  `json:"updatedAt"`
}

type Delivery struct {
	EndpointID     string
	Provider       string
	Endpoint       string
	AppID          string
	Environment    string
	EventType      string
	ResourceID     string
	ConversationID string
	Title          string
	Body           string
	Data           map[string]string
	CollapseKey    string
	HighPriority   bool
}

type ProviderResult struct {
	MessageID    string
	InvalidToken bool
}
