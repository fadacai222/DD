package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"example.com/selfhosted-im/server/internal/protocol"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

const (
	serviceName       = "im-realtime-poc"
	maxWebSocketBytes = 16 * 1024
	writeTimeout      = 5 * time.Second
)

type Config struct {
	Version        string
	AllowedOrigins []string
	Now            func() time.Time
}

type server struct {
	version        string
	allowedOrigins []string
	now            func() time.Time
	eventSequence  atomic.Int64
}

func NewHandler(config Config) http.Handler {
	version := strings.TrimSpace(config.Version)
	if version == "" {
		version = "dev"
	}

	now := config.Now
	if now == nil {
		now = time.Now
	}

	s := &server{
		version:        version,
		allowedOrigins: append([]string(nil), config.AllowedOrigins...),
		now:            now,
	}
	s.eventSequence.Store(now().UTC().UnixMicro())

	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/version", s.handleVersion)
	mux.HandleFunc("/ws", s.handleWebSocket)

	return securityHeaders(mux)
}

func (s *server) handleHealth(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}

	writeJSON(response, http.StatusOK, map[string]any{
		"status":  "ok",
		"service": serviceName,
		"time":    s.now().UTC(),
	})
}

func (s *server) handleVersion(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}

	writeJSON(response, http.StatusOK, map[string]string{
		"version":         s.version,
		"protocolVersion": protocol.Version,
	})
}

func (s *server) handleWebSocket(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		methodNotAllowed(response, http.MethodGet)
		return
	}

	connectionID, err := newConnectionID()
	if err != nil {
		writeJSON(response, http.StatusInternalServerError, map[string]any{
			"error": map[string]string{
				"code":    "CONNECTION_INIT_FAILED",
				"message": "Unable to initialize connection",
			},
		})
		return
	}

	var options *websocket.AcceptOptions
	if len(s.allowedOrigins) > 0 {
		options = &websocket.AcceptOptions{
			OriginPatterns: s.allowedOrigins,
		}
	}

	connection, err := websocket.Accept(response, request, options)
	if err != nil {
		return
	}
	defer connection.CloseNow()
	connection.SetReadLimit(maxWebSocketBytes)

	ctx := context.Background()
	nextEventID := s.nextEventID

	hasHello := false
	for {
		var incoming protocol.InboundEnvelope
		if err := wsjson.Read(ctx, connection, &incoming); err != nil {
			return
		}

		incoming.Type = strings.TrimSpace(incoming.Type)
		incoming.RequestID = strings.TrimSpace(incoming.RequestID)

		if !hasHello && incoming.Type != protocol.TypeHello {
			_ = writeSocket(ctx, connection, protocol.OutboundEnvelope{
				Type:      protocol.TypeError,
				RequestID: incoming.RequestID,
				EventID:   nextEventID(),
				Error: &protocol.APIError{
					Code:    "HELLO_REQUIRED",
					Message: "The first message must be hello",
				},
			})
			_ = connection.Close(websocket.StatusPolicyViolation, "hello required")
			return
		}

		switch incoming.Type {
		case protocol.TypeHello:
			if hasHello {
				if err := writeSocket(ctx, connection, protocol.OutboundEnvelope{
					Type:      protocol.TypeError,
					RequestID: incoming.RequestID,
					EventID:   nextEventID(),
					Error: &protocol.APIError{
						Code:    "HELLO_ALREADY_COMPLETED",
						Message: "hello may only be sent once per connection",
					},
				}); err != nil {
					return
				}
				continue
			}

			var hello protocol.HelloPayload
			if len(incoming.Payload) == 0 || json.Unmarshal(incoming.Payload, &hello) != nil || strings.TrimSpace(hello.ClientID) == "" {
				_ = writeSocket(ctx, connection, protocol.OutboundEnvelope{
					Type:      protocol.TypeError,
					RequestID: incoming.RequestID,
					EventID:   nextEventID(),
					Error: &protocol.APIError{
						Code:    "INVALID_HELLO",
						Message: "hello requires a non-empty clientId",
					},
				})
				_ = connection.Close(websocket.StatusPolicyViolation, "invalid hello")
				return
			}

			hasHello = true
			if err := writeSocket(ctx, connection, protocol.OutboundEnvelope{
				Type:      protocol.TypeHelloAck,
				RequestID: incoming.RequestID,
				EventID:   nextEventID(),
				Payload: protocol.HelloAckPayload{
					ConnectionID:   connectionID,
					ProtocolVersion: protocol.Version,
				},
			}); err != nil {
				return
			}

			if err := writeSocket(ctx, connection, protocol.OutboundEnvelope{
				Type:    protocol.TypeServerReady,
				EventID: nextEventID(),
				Payload: protocol.ServerReadyPayload{
					ServerTime: s.now().UTC().Format(time.RFC3339Nano),
				},
			}); err != nil {
				return
			}

		case protocol.TypePing:
			if err := writeSocket(ctx, connection, protocol.OutboundEnvelope{
				Type:      protocol.TypePong,
				RequestID: incoming.RequestID,
				EventID:   nextEventID(),
				Payload: map[string]string{
					"serverTime": s.now().UTC().Format(time.RFC3339Nano),
				},
			}); err != nil {
				return
			}

		default:
			if err := writeSocket(ctx, connection, protocol.OutboundEnvelope{
				Type:      protocol.TypeError,
				RequestID: incoming.RequestID,
				EventID:   nextEventID(),
				Error: &protocol.APIError{
					Code:    "UNKNOWN_EVENT_TYPE",
					Message: "Unsupported WebSocket event type",
				},
			}); err != nil {
				return
			}
		}
	}
}

func (s *server) nextEventID() int64 {
	return s.eventSequence.Add(1)
}

func writeSocket(parent context.Context, connection *websocket.Conn, message protocol.OutboundEnvelope) error {
	ctx, cancel := context.WithTimeout(parent, writeTimeout)
	defer cancel()
	return wsjson.Write(ctx, connection, message)
}

func newConnectionID() (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

func methodNotAllowed(response http.ResponseWriter, allowedMethod string) {
	response.Header().Set("Allow", allowedMethod)
	writeJSON(response, http.StatusMethodNotAllowed, map[string]any{
		"error": map[string]string{
			"code":    "METHOD_NOT_ALLOWED",
			"message": "Method not allowed",
		},
	})
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.Header().Set("Cache-Control", "no-store")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.Header().Set("X-Content-Type-Options", "nosniff")
		response.Header().Set("X-Frame-Options", "DENY")
		response.Header().Set("Referrer-Policy", "no-referrer")
		response.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		next.ServeHTTP(response, request)
	})
}
