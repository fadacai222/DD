package calls

import (
	"errors"
	"time"
)

var (
	ErrUnavailable     = errors.New("calls service unavailable")
	ErrInvalidInput    = errors.New("invalid call input")
	ErrNotFound        = errors.New("call not found")
	ErrForbidden       = errors.New("call operation forbidden")
	ErrContactRequired = errors.New("call requires contact relationship")
	ErrBusy            = errors.New("participant already has an active call")
	ErrConflict        = errors.New("call state conflict")
	ErrBlocked         = errors.New("call blocked by relationship")
)

const (
	StatusRinging  = "ringing"
	StatusAccepted = "accepted"
	StatusRejected = "rejected"
	StatusEnded    = "ended"

	KindAudio = "audio"
	KindVideo = "video"
)

type Call struct {
	ID                string     `json:"id"`
	RoomName          string     `json:"room_name"`
	CallerIdentity    string     `json:"caller_identity"`
	CallerName        string     `json:"caller_name"`
	CalleeIdentity    string     `json:"callee_identity"`
	CalleeName        string     `json:"callee_name"`
	Kind              string     `json:"kind"`
	Status            string     `json:"status"`
	CreatedAt         time.Time  `json:"created_at"`
	AcceptedAt        *time.Time `json:"accepted_at,omitempty"`
	EndedAt           *time.Time `json:"ended_at,omitempty"`
	EndReason         string     `json:"end_reason,omitempty"`
	RingTimeoutSecond int        `json:"ring_timeout_seconds"`
}

type CreateInput struct {
	CalleeUserID string `json:"calleeUserId"`
	Kind         string `json:"kind"`
}

type ActionInput struct {
	Action string `json:"action"`
}

type TokenAuthorization struct {
	Call            Call
	RoomName        string
	ParticipantID   string
	ParticipantName string
}
