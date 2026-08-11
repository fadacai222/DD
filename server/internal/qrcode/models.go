package qrcode

import (
	"errors"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"example.com/selfhosted-im/server/internal/groups"
)

var (
	ErrUnavailable = errors.New("qr service unavailable")
	ErrInvalid     = errors.New("invalid qr request")
	ErrNotFound    = errors.New("qr resource not found")
	ErrForbidden   = errors.New("qr operation forbidden")
	ErrConflict    = errors.New("qr state conflict")
	ErrExpired     = errors.New("qr credential expired")
	ErrConsumed    = errors.New("qr credential already consumed")
	ErrRejected    = errors.New("qr login rejected")
)

type Payload struct {
	Type      string     `json:"type"`
	Value     string     `json:"value"`
	ExpiresAt *time.Time `json:"expiresAt,omitempty"`
}

type GroupInvite struct {
	ID        string     `json:"id"`
	GroupID   string     `json:"groupId"`
	Payload   string     `json:"payload"`
	CreatedAt time.Time  `json:"createdAt"`
	ExpiresAt time.Time  `json:"expiresAt"`
	RevokedAt *time.Time `json:"revokedAt,omitempty"`
	UseCount  int        `json:"useCount"`
	MaxUses   *int       `json:"maxUses,omitempty"`
}

type CreateGroupInviteInput struct {
	ExpiresInSeconds int  `json:"expiresInSeconds"`
	MaxUses          *int `json:"maxUses,omitempty"`
}

type GroupRedeemResult struct {
	Group groups.Group `json:"group"`
}

type LoginSession struct {
	Status      string      `json:"status"`
	Nonce       string      `json:"nonce,omitempty"`
	Payload     string      `json:"payload,omitempty"`
	Device      DeviceInput `json:"device"`
	ExpiresAt   time.Time   `json:"expiresAt"`
	ScannedAt   *time.Time  `json:"scannedAt,omitempty"`
	ConfirmedAt *time.Time  `json:"confirmedAt,omitempty"`
}

type CreateLoginInput struct {
	Device DeviceInput `json:"device"`
}

type DeviceInput struct {
	Name       string `json:"name"`
	Platform   string `json:"platform"`
	AppVersion string `json:"appVersion,omitempty"`
}

type ConfirmLoginInput struct {
	Approved bool `json:"approved"`
}

type ConsumeLoginResult struct {
	Session account.AuthSession `json:"session"`
}
