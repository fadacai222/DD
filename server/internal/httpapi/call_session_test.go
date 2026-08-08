package httpapi_test

import (
	"bytes"
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

type callView struct {
	ID             string     `json:"id"`
	RoomName       string     `json:"room_name"`
	CallerIdentity string     `json:"caller_identity"`
	CallerName     string     `json:"caller_name"`
	CalleeIdentity string     `json:"callee_identity"`
	Kind           string     `json:"kind"`
	Status         string     `json:"status"`
	CreatedAt      time.Time  `json:"created_at"`
	ExpiresAt      time.Time  `json:"expires_at"`
	AcceptedAt     *time.Time `json:"accepted_at,omitempty"`
	EndedAt        *time.Time `json:"ended_at,omitempty"`
	EndReason      string     `json:"end_reason,omitempty"`
}

func TestTwoPartyCallSignalingAndScopedToken(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{
		Version:          "0.3.0-poc",
		LiveKitURL:       "ws://127.0.0.1:7880",
		LiveKitAPIKey:    "devkey",
		LiveKitAPISecret: "secret",
		CallTokenTTL:     10 * time.Minute,
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	caller := dialIdentity(t, server.URL, "alice")
	defer caller.CloseNow()
	callee := dialIdentity(t, server.URL, "bob")
	defer callee.CloseNow()

	createdResponse := postJSON(t, server.URL+"/api/calls", map[string]any{
		"caller_identity": "alice",
		"caller_name":     "Alice",
		"callee_identity": "bob",
		"kind":            "video",
	})
	defer createdResponse.Body.Close()
	if createdResponse.StatusCode != http.StatusCreated {
		t.Fatalf("create status = %d, want %d", createdResponse.StatusCode, http.StatusCreated)
	}

	var created callView
	decodeJSON(t, createdResponse, &created)
	if created.ID == "" || created.RoomName == "" || created.ExpiresAt.IsZero() {
		t.Fatalf("created call missing identifiers or expiry: %#v", created)
	}
	if created.Status != "ringing" || created.Kind != "video" {
		t.Fatalf("created call = %#v", created)
	}

	incoming := readEnvelope(t, callee)
	if incoming.Type != "call.incoming" {
		t.Fatalf("callee event type = %q, want call.incoming", incoming.Type)
	}
	if incoming.Payload["id"] != created.ID || incoming.Payload["caller_identity"] != "alice" {
		t.Fatalf("incoming payload = %#v", incoming.Payload)
	}

	acceptedResponse := postJSON(t, server.URL+"/api/calls/"+created.ID+"/actions", map[string]any{
		"participant_identity": "bob",
		"action":               "accept",
	})
	defer acceptedResponse.Body.Close()
	if acceptedResponse.StatusCode != http.StatusOK {
		t.Fatalf("accept status = %d, want %d", acceptedResponse.StatusCode, http.StatusOK)
	}

	var accepted callView
	decodeJSON(t, acceptedResponse, &accepted)
	if accepted.Status != "accepted" || accepted.AcceptedAt == nil {
		t.Fatalf("accepted call = %#v", accepted)
	}

	callerUpdate := readEnvelope(t, caller)
	calleeUpdate := readEnvelope(t, callee)
	if callerUpdate.Type != "call.updated" || calleeUpdate.Type != "call.updated" {
		t.Fatalf("update events = %q / %q", callerUpdate.Type, calleeUpdate.Type)
	}
	if callerUpdate.Payload["status"] != "accepted" || calleeUpdate.Payload["status"] != "accepted" {
		t.Fatalf("update payloads = %#v / %#v", callerUpdate.Payload, calleeUpdate.Payload)
	}

	tokenResponse := postJSON(t, server.URL+"/api/calls/"+created.ID+"/token", map[string]any{
		"participant_identity": "alice",
		"participant_name":     "Alice",
	})
	defer tokenResponse.Body.Close()
	if tokenResponse.StatusCode != http.StatusOK {
		t.Fatalf("token status = %d, want %d", tokenResponse.StatusCode, http.StatusOK)
	}
	var tokenBody struct {
		ServerURL        string    `json:"server_url"`
		ParticipantToken string    `json:"participant_token"`
		ExpiresAt        time.Time `json:"expires_at"`
	}
	decodeJSON(t, tokenResponse, &tokenBody)
	if tokenBody.ServerURL == "" || tokenBody.ParticipantToken == "" || tokenBody.ExpiresAt.IsZero() {
		t.Fatalf("token response = %#v", tokenBody)
	}
}

func TestRingingCallTimesOutAndReleasesBusyState(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{
		Version:         "0.3.0-poc",
		CallRingTimeout: 40 * time.Millisecond,
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	caller := dialIdentity(t, server.URL, "alice")
	defer caller.CloseNow()
	callee := dialIdentity(t, server.URL, "bob")
	defer callee.CloseNow()

	createdResponse := postJSON(t, server.URL+"/api/calls", map[string]any{
		"caller_identity": "alice",
		"caller_name":     "Alice",
		"callee_identity": "bob",
		"kind":            "audio",
	})
	defer createdResponse.Body.Close()
	if createdResponse.StatusCode != http.StatusCreated {
		t.Fatalf("create status = %d, want %d", createdResponse.StatusCode, http.StatusCreated)
	}
	var created callView
	decodeJSON(t, createdResponse, &created)

	if incoming := readEnvelope(t, callee); incoming.Type != "call.incoming" {
		t.Fatalf("callee event type = %q, want call.incoming", incoming.Type)
	}

	callerTimeout := readEnvelope(t, caller)
	calleeTimeout := readEnvelope(t, callee)
	if callerTimeout.Type != "call.updated" || calleeTimeout.Type != "call.updated" {
		t.Fatalf("timeout events = %q / %q", callerTimeout.Type, calleeTimeout.Type)
	}
	if callerTimeout.Payload["status"] != "ended" || callerTimeout.Payload["end_reason"] != "timeout" {
		t.Fatalf("caller timeout payload = %#v", callerTimeout.Payload)
	}
	if calleeTimeout.Payload["status"] != "ended" || calleeTimeout.Payload["end_reason"] != "timeout" {
		t.Fatalf("callee timeout payload = %#v", calleeTimeout.Payload)
	}

	retry := postJSON(t, server.URL+"/api/calls", map[string]any{
		"caller_identity": "charlie",
		"caller_name":     "Charlie",
		"callee_identity": "bob",
		"kind":            "video",
	})
	defer retry.Body.Close()
	if retry.StatusCode != http.StatusCreated {
		t.Fatalf("retry create status = %d, want %d after timeout", retry.StatusCode, http.StatusCreated)
	}
}

func TestBrowserOriginCanReceiveAndAcceptCall(t *testing.T) {
	const browserOrigin = "http://localhost:54321"
	handler := httpapi.NewHandler(httpapi.Config{
		Version:            "0.3.1-poc",
		AllowedOrigins:     []string{"localhost:*", "127.0.0.1:*"},
		AllowedHTTPOrigins: []string{"http://localhost:*", "http://127.0.0.1:*"},
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	caller := dialIdentity(t, server.URL, "alice")
	defer caller.CloseNow()
	callee := dialIdentityWithOrigin(t, server.URL, "bob", browserOrigin)
	defer callee.CloseNow()

	createdResponse := postJSON(t, server.URL+"/api/calls", map[string]any{
		"caller_identity": "alice",
		"caller_name":     "Alice",
		"callee_identity": "bob",
		"kind":            "audio",
	})
	defer createdResponse.Body.Close()
	if createdResponse.StatusCode != http.StatusCreated {
		t.Fatalf("create status = %d, want %d", createdResponse.StatusCode, http.StatusCreated)
	}
	var created callView
	decodeJSON(t, createdResponse, &created)

	incoming := readEnvelope(t, callee)
	if incoming.Type != "call.incoming" || incoming.Payload["id"] != created.ID {
		t.Fatalf("browser incoming event = %#v", incoming)
	}

	acceptedResponse := postJSONWithOrigin(t, server.URL+"/api/calls/"+created.ID+"/actions", browserOrigin, map[string]any{
		"participant_identity": "bob",
		"action":               "accept",
	})
	defer acceptedResponse.Body.Close()
	if acceptedResponse.StatusCode != http.StatusOK {
		t.Fatalf("browser accept status = %d, want %d", acceptedResponse.StatusCode, http.StatusOK)
	}
	if got := acceptedResponse.Header.Get("Access-Control-Allow-Origin"); got != browserOrigin {
		t.Fatalf("browser accept allow-origin = %q, want %q", got, browserOrigin)
	}

	callerUpdate := readEnvelope(t, caller)
	calleeUpdate := readEnvelope(t, callee)
	if callerUpdate.Payload["status"] != "accepted" || calleeUpdate.Payload["status"] != "accepted" {
		t.Fatalf("browser accept updates = %#v / %#v", callerUpdate.Payload, calleeUpdate.Payload)
	}
}

func TestCallRejectsBusyParticipantAndUnauthorizedActions(t *testing.T) {
	handler := httpapi.NewHandler(httpapi.Config{Version: "0.3.0-poc"})
	server := httptest.NewServer(handler)
	defer server.Close()

	first := postJSON(t, server.URL+"/api/calls", map[string]any{
		"caller_identity": "alice",
		"caller_name":     "Alice",
		"callee_identity": "bob",
		"kind":            "audio",
	})
	defer first.Body.Close()
	if first.StatusCode != http.StatusCreated {
		t.Fatalf("first create status = %d", first.StatusCode)
	}
	var call callView
	decodeJSON(t, first, &call)

	busy := postJSON(t, server.URL+"/api/calls", map[string]any{
		"caller_identity": "charlie",
		"caller_name":     "Charlie",
		"callee_identity": "bob",
		"kind":            "video",
	})
	defer busy.Body.Close()
	if busy.StatusCode != http.StatusConflict {
		t.Fatalf("busy create status = %d, want %d", busy.StatusCode, http.StatusConflict)
	}

	unauthorized := postJSON(t, server.URL+"/api/calls/"+call.ID+"/actions", map[string]any{
		"participant_identity": "mallory",
		"action":               "hangup",
	})
	defer unauthorized.Body.Close()
	if unauthorized.StatusCode != http.StatusForbidden {
		t.Fatalf("unauthorized status = %d, want %d", unauthorized.StatusCode, http.StatusForbidden)
	}
}

func dialIdentity(t *testing.T, baseURL, identity string) *websocket.Conn {
	t.Helper()
	return dialIdentityWithOrigin(t, baseURL, identity, "")
}

func dialIdentityWithOrigin(t *testing.T, baseURL, identity, origin string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	t.Cleanup(cancel)

	wsURL := "ws" + strings.TrimPrefix(baseURL, "http") + "/ws"
	var options *websocket.DialOptions
	if origin != "" {
		options = &websocket.DialOptions{HTTPHeader: http.Header{"Origin": []string{origin}}}
	}
	connection, _, err := websocket.Dial(ctx, wsURL, options)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	if err := wsjson.Write(ctx, connection, envelope{
		Type:      "hello",
		RequestID: "hello-" + identity,
		Payload: map[string]any{
			"clientId":    identity,
			"lastEventId": float64(0),
		},
	}); err != nil {
		connection.CloseNow()
		t.Fatalf("write hello: %v", err)
	}
	if ack := readEnvelope(t, connection); ack.Type != "hello_ack" {
		connection.CloseNow()
		t.Fatalf("first event = %q, want hello_ack", ack.Type)
	}
	if ready := readEnvelope(t, connection); ready.Type != "server_ready" {
		connection.CloseNow()
		t.Fatalf("second event = %q, want server_ready", ready.Type)
	}
	return connection
}

func readEnvelope(t *testing.T, connection *websocket.Conn) envelope {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var result envelope
	if err := wsjson.Read(ctx, connection, &result); err != nil {
		t.Fatalf("read websocket envelope: %v", err)
	}
	return result
}

func postJSON(t *testing.T, url string, body any) *http.Response {
	t.Helper()
	return postJSONWithOrigin(t, url, "", body)
}

func postJSONWithOrigin(t *testing.T, url, origin string, body any) *http.Response {
	t.Helper()
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	request, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(encoded))
	if err != nil {
		t.Fatalf("create POST %s: %v", url, err)
	}
	request.Header.Set("Content-Type", "application/json")
	if origin != "" {
		request.Header.Set("Origin", origin)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("POST %s: %v", url, err)
	}
	return response
}

func decodeJSON(t *testing.T, response *http.Response, destination any) {
	t.Helper()
	if err := json.NewDecoder(response.Body).Decode(destination); err != nil {
		t.Fatalf("decode response: %v", err)
	}
}
