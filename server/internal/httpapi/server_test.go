package httpapi_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/httpapi"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

type envelope struct {
	Type      string         `json:"type"`
	RequestID string         `json:"requestId,omitempty"`
	EventID   int64          `json:"eventId,omitempty"`
	Payload   map[string]any `json:"payload,omitempty"`
	Error     *apiError      `json:"error,omitempty"`
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func TestHealthAndVersionEndpoints(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{Version: "0.1.0-poc"})
	server := httptest.NewServer(handler)
	defer server.Close()

	t.Run("health", func(t *testing.T) {
		response, err := http.Get(server.URL + "/health")
		if err != nil {
			t.Fatalf("GET /health: %v", err)
		}
		defer response.Body.Close()

		if response.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusOK)
		}

		var body struct {
			Status  string    `json:"status"`
			Service string    `json:"service"`
			Time    time.Time `json:"time"`
		}
		if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
			t.Fatalf("decode health response: %v", err)
		}
		if body.Status != "ok" {
			t.Fatalf("status = %q, want ok", body.Status)
		}
		if body.Service != "im-realtime-poc" {
			t.Fatalf("service = %q, want im-realtime-poc", body.Service)
		}
		if body.Time.IsZero() {
			t.Fatal("time must be populated")
		}
	})

	t.Run("version", func(t *testing.T) {
		response, err := http.Get(server.URL + "/version")
		if err != nil {
			t.Fatalf("GET /version: %v", err)
		}
		defer response.Body.Close()

		var body struct {
			Version         string `json:"version"`
			ProtocolVersion string `json:"protocolVersion"`
		}
		if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
			t.Fatalf("decode version response: %v", err)
		}
		if body.Version != "0.1.0-poc" {
			t.Fatalf("version = %q, want 0.1.0-poc", body.Version)
		}
		if body.ProtocolVersion != "1" {
			t.Fatalf("protocolVersion = %q, want 1", body.ProtocolVersion)
		}
	})
}

func TestWebSocketHelloAndServerPush(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{Version: "0.1.0-poc"})
	server := httptest.NewServer(handler)
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/ws"
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	connection, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	defer connection.CloseNow()

	hello := envelope{
		Type:      "hello",
		RequestID: "request-1",
		Payload: map[string]any{
			"clientId":    "test-client",
			"lastEventId": float64(0),
		},
	}
	if err := wsjson.Write(ctx, connection, hello); err != nil {
		t.Fatalf("write hello: %v", err)
	}

	var ack envelope
	if err := wsjson.Read(ctx, connection, &ack); err != nil {
		t.Fatalf("read hello_ack: %v", err)
	}
	if ack.Type != "hello_ack" {
		t.Fatalf("type = %q, want hello_ack", ack.Type)
	}
	if ack.RequestID != hello.RequestID {
		t.Fatalf("requestId = %q, want %q", ack.RequestID, hello.RequestID)
	}
	if ack.EventID <= 0 {
		t.Fatalf("eventId = %d, want positive", ack.EventID)
	}
	if ack.Payload["protocolVersion"] != "1" {
		t.Fatalf("protocolVersion = %#v, want 1", ack.Payload["protocolVersion"])
	}
	if ack.Payload["connectionId"] == "" {
		t.Fatal("connectionId must be populated")
	}

	var pushed envelope
	if err := wsjson.Read(ctx, connection, &pushed); err != nil {
		t.Fatalf("read server_ready: %v", err)
	}
	if pushed.Type != "server_ready" {
		t.Fatalf("type = %q, want server_ready", pushed.Type)
	}
	if pushed.EventID <= ack.EventID {
		t.Fatalf("server_ready eventId = %d, want greater than ack %d", pushed.EventID, ack.EventID)
	}

	if err := wsjson.Write(ctx, connection, envelope{Type: "ping", RequestID: "request-2"}); err != nil {
		t.Fatalf("write ping: %v", err)
	}
	var pong envelope
	if err := wsjson.Read(ctx, connection, &pong); err != nil {
		t.Fatalf("read pong: %v", err)
	}
	if pong.Type != "pong" || pong.RequestID != "request-2" {
		t.Fatalf("pong = %#v", pong)
	}

	if err := connection.Close(websocket.StatusNormalClosure, "reconnect test"); err != nil {
		t.Fatalf("close first websocket: %v", err)
	}

	secondCtx, secondCancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer secondCancel()
	secondConnection, _, err := websocket.Dial(secondCtx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial second websocket: %v", err)
	}
	defer secondConnection.CloseNow()

	if err := wsjson.Write(secondCtx, secondConnection, envelope{
		Type:      "hello",
		RequestID: "request-3",
		Payload: map[string]any{
			"clientId":    "test-client",
			"lastEventId": float64(pong.EventID),
		},
	}); err != nil {
		t.Fatalf("write second hello: %v", err)
	}

	var secondAck envelope
	if err := wsjson.Read(secondCtx, secondConnection, &secondAck); err != nil {
		t.Fatalf("read second hello_ack: %v", err)
	}
	if secondAck.EventID <= pong.EventID {
		t.Fatalf("second connection eventId = %d, want greater than %d", secondAck.EventID, pong.EventID)
	}
}
