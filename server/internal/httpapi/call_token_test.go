package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/httpapi"
	"github.com/livekit/protocol/auth"
)

func TestCallTokenEndpoint(t *testing.T) {
	fixedNow := time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC)
	handler := httpapi.NewHandler(httpapi.Config{
		Version:          "0.2.0-poc",
		LiveKitURL:       "ws://127.0.0.1:7880",
		LiveKitAPIKey:    "devkey",
		LiveKitAPISecret: "secret",
		CallTokenTTL:     15 * time.Minute,
		Now:              func() time.Time { return fixedNow },
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	t.Run("issues a scoped short-lived join token", func(t *testing.T) {
		requestBody := map[string]string{
			"room_name":            "room-alpha",
			"participant_identity": "user-001",
			"participant_name":     "测试用户",
		}
		encoded, err := json.Marshal(requestBody)
		if err != nil {
			t.Fatalf("marshal request: %v", err)
		}

		request, err := http.NewRequest(http.MethodPost, server.URL+"/api/calls/token", bytes.NewReader(encoded))
		if err != nil {
			t.Fatalf("create request: %v", err)
		}
		request.Header.Set("Content-Type", "application/json")

		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatalf("POST /api/calls/token: %v", err)
		}
		defer response.Body.Close()

		if response.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusOK)
		}

		var body struct {
			ServerURL        string    `json:"server_url"`
			ParticipantToken string    `json:"participant_token"`
			ExpiresAt        time.Time `json:"expires_at"`
		}
		if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
			t.Fatalf("decode response: %v", err)
		}
		if body.ServerURL != "ws://127.0.0.1:7880" {
			t.Fatalf("server_url = %q", body.ServerURL)
		}
		if body.ParticipantToken == "" {
			t.Fatal("participant_token must be populated")
		}
		if want := fixedNow.Add(15 * time.Minute); !body.ExpiresAt.Equal(want) {
			t.Fatalf("expires_at = %s, want %s", body.ExpiresAt, want)
		}

		verifier, err := auth.ParseAPIToken(body.ParticipantToken)
		if err != nil {
			t.Fatalf("parse token: %v", err)
		}
		claims, grants, err := verifier.Verify("secret")
		if err != nil {
			t.Fatalf("verify token: %v", err)
		}
		if claims.Subject != "user-001" {
			t.Fatalf("subject = %q, want user-001", claims.Subject)
		}
		if grants.Name != "测试用户" {
			t.Fatalf("name = %q", grants.Name)
		}
		if grants.Video == nil || !grants.Video.RoomJoin || grants.Video.Room != "room-alpha" {
			t.Fatalf("video grant = %#v", grants.Video)
		}
		if !grants.Video.GetCanPublish() || !grants.Video.GetCanSubscribe() {
			t.Fatalf("publish/subscribe grant = %#v", grants.Video)
		}
	})

	t.Run("rejects malformed input", func(t *testing.T) {
		requestBody := []byte(`{"room_name":"../bad","participant_identity":"user 1","participant_name":""}`)
		request, err := http.NewRequest(http.MethodPost, server.URL+"/api/calls/token", bytes.NewReader(requestBody))
		if err != nil {
			t.Fatalf("create request: %v", err)
		}
		request.Header.Set("Content-Type", "application/json")

		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatalf("POST invalid token request: %v", err)
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusBadRequest {
			t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusBadRequest)
		}
	})

	t.Run("requires json", func(t *testing.T) {
		response, err := http.Post(server.URL+"/api/calls/token", "text/plain", bytes.NewBufferString("{}"))
		if err != nil {
			t.Fatalf("POST text request: %v", err)
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusUnsupportedMediaType {
			t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusUnsupportedMediaType)
		}
	})
}

func TestCallTokenEndpointUnavailableWithoutCredentials(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{})
	server := httptest.NewServer(handler)
	defer server.Close()

	request, err := http.NewRequest(http.MethodPost, server.URL+"/api/calls/token", bytes.NewBufferString(`{"room_name":"room-alpha","participant_identity":"user-001","participant_name":"User"}`))
	if err != nil {
		t.Fatalf("create request: %v", err)
	}
	request.Header.Set("Content-Type", "application/json")

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("POST /api/calls/token: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusServiceUnavailable)
	}
}
