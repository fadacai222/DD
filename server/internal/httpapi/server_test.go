package httpapi_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
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

func TestVersionedInstanceDiscovery(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{
		Version:          "0.4.0-dev",
		PublicBaseURL:    "https://chat.example.com",
		InstanceName:     "DD",
		RegistrationMode: "open",
		LiveKitURL:       "wss://media.example.com",
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	response, err := http.Get(server.URL + "/api/v1/instance")
	if err != nil {
		t.Fatalf("GET /api/v1/instance: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", response.StatusCode)
	}

	var body struct {
		Data struct {
			Name        string `json:"name"`
			APIVersion  string `json:"apiVersion"`
			APIBaseURL  string `json:"apiBaseUrl"`
			RealtimeURL string `json:"realtimeUrl"`
			LiveKitURL  string `json:"liveKitUrl"`
			Features    struct {
				Calls            bool   `json:"calls"`
				RegistrationMode string `json:"registrationMode"`
			} `json:"features"`
		} `json:"data"`
		RequestID string `json:"requestId"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatalf("decode instance response: %v", err)
	}
	if body.Data.Name != "DD" || body.Data.APIVersion != "v1" {
		t.Fatalf("instance identity = %#v", body.Data)
	}
	if body.Data.APIBaseURL != "https://chat.example.com/api/v1" {
		t.Fatalf("apiBaseUrl = %q", body.Data.APIBaseURL)
	}
	if body.Data.RealtimeURL != "wss://chat.example.com/api/v1/realtime" {
		t.Fatalf("realtimeUrl = %q", body.Data.RealtimeURL)
	}
	if body.Data.LiveKitURL != "wss://media.example.com" || !body.Data.Features.Calls || body.Data.Features.RegistrationMode != "open" {
		t.Fatalf("media/features = %#v", body.Data)
	}
	if body.RequestID == "" || body.RequestID != response.Header.Get("X-Request-ID") {
		t.Fatalf("requestId body=%q header=%q", body.RequestID, response.Header.Get("X-Request-ID"))
	}
}

func TestWellKnownDiscoveryUsesDevelopmentRequestHostOnlyWhenPublicURLMissing(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{Version: "dev", InstanceName: "DD", LiveKitURL: "auto", LiveKitPublicPort: 7880})
	server := httptest.NewServer(handler)
	defer server.Close()

	request, err := http.NewRequest(http.MethodGet, server.URL+"/.well-known/openimx/client", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("GET well-known: %v", err)
	}
	defer response.Body.Close()

	var body struct {
		APIBaseURL  string `json:"apiBaseUrl"`
		RealtimeURL string `json:"realtimeUrl"`
		LiveKitURL  string `json:"liveKitUrl"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatalf("decode well-known: %v", err)
	}
	if !strings.HasPrefix(body.APIBaseURL, "http://127.0.0.1:") {
		t.Fatalf("apiBaseUrl = %q", body.APIBaseURL)
	}
	if !strings.HasPrefix(body.RealtimeURL, "ws://127.0.0.1:") {
		t.Fatalf("realtimeUrl = %q", body.RealtimeURL)
	}
	if !strings.HasPrefix(body.LiveKitURL, "ws://127.0.0.1:") {
		t.Fatalf("liveKitUrl = %q", body.LiveKitURL)
	}
}

func TestRequestIDAndStructuredAccessLog(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logs, nil))
	handler := httpapi.NewHandler(httpapi.Config{Version: "0.1.0-poc", Logger: logger})
	server := httptest.NewServer(handler)
	defer server.Close()

	request, err := http.NewRequest(http.MethodGet, server.URL+"/version?token=query-secret", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer header-secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("GET /version: %v", err)
	}
	defer response.Body.Close()

	requestID := response.Header.Get("X-Request-ID")
	if !strings.HasPrefix(requestID, "req_") {
		t.Fatalf("X-Request-ID = %q, want req_ prefix", requestID)
	}
	logOutput := logs.String()
	for _, want := range []string{requestID, `"method":"GET"`, `"path":"/version"`, `"status":200`} {
		if !strings.Contains(logOutput, want) {
			t.Fatalf("access log missing %q: %s", want, logOutput)
		}
	}
	for _, secret := range []string{"header-secret", "query-secret", "Authorization", "token="} {
		if strings.Contains(logOutput, secret) {
			t.Fatalf("access log leaked %q: %s", secret, logOutput)
		}
	}
}

func TestReadinessFailureDoesNotBreakLiveness(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{
		Version: "0.1.0-poc",
		ReadinessChecks: map[string]httpapi.ReadinessCheck{
			"postgres": func(context.Context) error { return errors.New("password=must-not-leak") },
		},
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	for _, path := range []string{"/live", "/api/v1/system/live"} {
		response, err := http.Get(server.URL + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Fatalf("GET %s status = %d, want 200", path, response.StatusCode)
		}
	}

	response, err := http.Get(server.URL + "/ready")
	if err != nil {
		t.Fatalf("GET /ready: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("GET /ready status = %d, want 503", response.StatusCode)
	}
	var body struct {
		Status string            `json:"status"`
		Checks map[string]string `json:"checks"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatalf("decode readiness: %v", err)
	}
	if body.Status != "not_ready" || body.Checks["postgres"] != "failed" {
		t.Fatalf("readiness body = %#v", body)
	}
}

func TestHTTPErrorIncludesGeneratedRequestID(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{Version: "0.1.0-poc"})
	server := httptest.NewServer(handler)
	defer server.Close()

	response, err := http.Post(server.URL+"/version", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatalf("POST /version: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", response.StatusCode)
	}
	var body struct {
		Error struct {
			Code      string `json:"code"`
			RequestID string `json:"requestId"`
		} `json:"error"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if body.Error.Code != "METHOD_NOT_ALLOWED" {
		t.Fatalf("error code = %q", body.Error.Code)
	}
	if body.Error.RequestID == "" || body.Error.RequestID != response.Header.Get("X-Request-ID") {
		t.Fatalf("requestId body=%q header=%q", body.Error.RequestID, response.Header.Get("X-Request-ID"))
	}
}

func TestVersionedRealtimeRequiresAuthentication(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{Version: "0.4.0-dev"})
	server := httptest.NewServer(handler)
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/api/v1/realtime"
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	connection, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial versioned websocket: %v", err)
	}
	defer connection.CloseNow()

	if err := wsjson.Write(ctx, connection, envelope{
		Type:      "hello",
		RequestID: "versioned-request",
		Payload: map[string]any{
			"clientId":        "versioned-test-client",
			"lastEventId":     float64(0),
			"protocolVersion": "1",
		},
	}); err != nil {
		t.Fatalf("write hello: %v", err)
	}

	var response envelope
	if err := wsjson.Read(ctx, connection, &response); err != nil {
		t.Fatalf("read authentication error: %v", err)
	}
	if response.Type != "error" || response.Error == nil || response.Error.Code != "UNAUTHORIZED" {
		t.Fatalf("response = %#v", response)
	}
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
