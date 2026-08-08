package realtimev1

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

const ProtocolVersion = 1

type Type string

const (
	TypeHello          Type = "HELLO"
	TypeHelloAck       Type = "HELLO_ACK"
	TypeEventAvailable Type = "EVENT_AVAILABLE"
	TypePing           Type = "PING"
	TypePong           Type = "PONG"
	TypeError          Type = "ERROR"
)

type Envelope struct {
	Type            Type    `json:"type"`
	ProtocolVersion int     `json:"protocolVersion,omitempty"`
	DeviceID        string  `json:"deviceId,omitempty"`
	LastCursor      *string `json:"lastCursor,omitempty"`
	ConnectionID    string  `json:"connectionId,omitempty"`
	ServerTime      string  `json:"serverTime,omitempty"`
	EventID         string  `json:"eventId,omitempty"`
	Cursor          string  `json:"cursor,omitempty"`
	Timestamp       int64   `json:"timestamp,omitempty"`
	Code            string  `json:"code,omitempty"`
	Message         string  `json:"message,omitempty"`
	RequestID       *string `json:"requestId,omitempty"`
}

func (envelope Envelope) Validate() error {
	switch envelope.Type {
	case TypeHello:
		if envelope.ProtocolVersion != ProtocolVersion {
			return fmt.Errorf("protocolVersion must be %d", ProtocolVersion)
		}
		if !isDeviceID(envelope.DeviceID) {
			return errors.New("deviceId is invalid")
		}
		if envelope.LastCursor != nil && len(*envelope.LastCursor) > 256 {
			return errors.New("lastCursor is too long")
		}
	case TypeHelloAck:
		if envelope.ProtocolVersion != ProtocolVersion {
			return fmt.Errorf("protocolVersion must be %d", ProtocolVersion)
		}
		if len(envelope.ConnectionID) < 8 || len(envelope.ConnectionID) > 128 {
			return errors.New("connectionId is invalid")
		}
		if _, err := time.Parse(time.RFC3339Nano, envelope.ServerTime); err != nil {
			return errors.New("serverTime must be RFC3339")
		}
	case TypeEventAvailable:
		if strings.TrimSpace(envelope.EventID) == "" || len(envelope.EventID) > 128 {
			return errors.New("eventId is invalid")
		}
		if strings.TrimSpace(envelope.Cursor) == "" || len(envelope.Cursor) > 256 {
			return errors.New("cursor is invalid")
		}
	case TypePing, TypePong:
		if envelope.Timestamp < 0 {
			return errors.New("timestamp must be non-negative")
		}
	case TypeError:
		if !isErrorCode(envelope.Code) {
			return errors.New("code is invalid")
		}
		if strings.TrimSpace(envelope.Message) == "" || len(envelope.Message) > 300 {
			return errors.New("message is invalid")
		}
	default:
		return fmt.Errorf("unsupported realtime type %q", envelope.Type)
	}
	return nil
}

func isDeviceID(value string) bool {
	if !strings.HasPrefix(value, "dev_") || len(value) < 12 || len(value) > 132 {
		return false
	}
	for _, character := range value[4:] {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || character == '_' || character == '-' {
			continue
		}
		return false
	}
	return true
}

func isErrorCode(value string) bool {
	if value == "" || value[0] < 'A' || value[0] > 'Z' {
		return false
	}
	for _, character := range value {
		if (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '_' {
			continue
		}
		return false
	}
	return true
}
