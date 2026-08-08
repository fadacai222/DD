package protocol

import "encoding/json"

const Version = "1"

const (
	TypeHello          = "hello"
	TypeHelloAck       = "hello_ack"
	TypeServerReady    = "server_ready"
	TypePing           = "ping"
	TypePong           = "pong"
	TypeError          = "error"
	TypeEventAvailable = "event_available"
	TypeCallIncoming   = "call.incoming"
	TypeCallUpdated    = "call.updated"
)

type InboundEnvelope struct {
	Type      string          `json:"type"`
	RequestID string          `json:"requestId,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
}

type OutboundEnvelope struct {
	Type      string    `json:"type"`
	RequestID string    `json:"requestId,omitempty"`
	EventID   int64     `json:"eventId,omitempty"`
	Payload   any       `json:"payload,omitempty"`
	Error     *APIError `json:"error,omitempty"`
}

type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type HelloPayload struct {
	ClientID        string `json:"clientId"`
	LastEventID     int64  `json:"lastEventId"`
	AccessToken     string `json:"accessToken,omitempty"`
	ProtocolVersion string `json:"protocolVersion,omitempty"`
}

type HelloAckPayload struct {
	ConnectionID    string `json:"connectionId"`
	ProtocolVersion string `json:"protocolVersion"`
}

type ServerReadyPayload struct {
	ServerTime string `json:"serverTime"`
}

type EventAvailablePayload struct {
	Reason string `json:"reason"`
}
