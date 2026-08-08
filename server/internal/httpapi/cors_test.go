package httpapi_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"example.com/selfhosted-im/server/internal/httpapi"
)

func TestLocalWebCORSAndAutoLiveKitURL(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{
		AllowedHTTPOrigins: []string{"http://127.0.0.1:*", "http://localhost:*"},
		LiveKitURL:         "auto",
		LiveKitPublicPort:  7880,
		LiveKitAPIKey:      "devkey",
		LiveKitAPISecret:   "secret",
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	preflight, err := http.NewRequest(http.MethodOptions, server.URL+"/api/calls/token", nil)
	if err != nil {
		t.Fatalf("create preflight: %v", err)
	}
	preflight.Header.Set("Origin", "http://127.0.0.1:51000")
	preflight.Header.Set("Access-Control-Request-Method", http.MethodPost)
	preflightResponse, err := http.DefaultClient.Do(preflight)
	if err != nil {
		t.Fatalf("preflight request: %v", err)
	}
	defer preflightResponse.Body.Close()
	if preflightResponse.StatusCode != http.StatusNoContent {
		t.Fatalf("preflight status = %d", preflightResponse.StatusCode)
	}
	if got := preflightResponse.Header.Get("Access-Control-Allow-Origin"); got != "http://127.0.0.1:51000" {
		t.Fatalf("allow origin = %q", got)
	}
	allowedMethods := preflightResponse.Header.Get("Access-Control-Allow-Methods")
	for _, method := range []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete, http.MethodOptions} {
		if !strings.Contains(allowedMethods, method) {
			t.Fatalf("allow methods = %q, missing %s", allowedMethods, method)
		}
	}

	encoded, err := json.Marshal(map[string]string{
		"room_name":            "room-alpha",
		"participant_identity": "user-001",
		"participant_name":     "User",
	})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	request, err := http.NewRequest(http.MethodPost, server.URL+"/api/calls/token", bytes.NewReader(encoded))
	if err != nil {
		t.Fatalf("create request: %v", err)
	}
	request.Host = "10.0.2.2:18473"
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", "http://127.0.0.1:51000")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("token request: %v", err)
	}
	defer response.Body.Close()

	var body struct {
		ServerURL string `json:"server_url"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if body.ServerURL != "ws://10.0.2.2:7880" {
		t.Fatalf("server_url = %q", body.ServerURL)
	}
}

func TestCORSRejectsUntrustedOriginBeforeHandler(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{
		AllowedHTTPOrigins: []string{"http://127.0.0.1:*", "http://localhost:*"},
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	encoded, err := json.Marshal(map[string]string{
		"caller_identity": "alice",
		"caller_name":     "Alice",
		"callee_identity": "bob",
		"kind":            "audio",
	})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	request, err := http.NewRequest(http.MethodPost, server.URL+"/api/calls", bytes.NewReader(encoded))
	if err != nil {
		t.Fatalf("create request: %v", err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", "https://attacker.example")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("call request: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusForbidden {
		t.Fatalf("untrusted origin status = %d, want %d", response.StatusCode, http.StatusForbidden)
	}
	if got := response.Header.Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("unexpected allow origin %q", got)
	}

	activeResponse, err := http.Get(server.URL + "/api/calls/active?participant_identity=alice")
	if err != nil {
		t.Fatalf("active call request: %v", err)
	}
	defer activeResponse.Body.Close()
	if activeResponse.StatusCode != http.StatusNoContent {
		t.Fatalf("untrusted request reached handler; active status = %d", activeResponse.StatusCode)
	}
}
