package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/calls"
)

func TestWriteFormalCallsErrorDistinguishesMissingContact(t *testing.T) {
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/calls", nil)

	(&server{}).writeFormalCallsError(recorder, request, calls.ErrContactRequired)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("status=%d want %d", recorder.Code, http.StatusForbidden)
	}
	if body := recorder.Body.String(); !strings.Contains(body, `"code":"CALL_CONTACT_REQUIRED"`) {
		t.Fatalf("body=%s does not contain CALL_CONTACT_REQUIRED", body)
	}
}

func TestIssueFormalCallTokenMatchesContract(t *testing.T) {
	s := &server{
		liveKitURL:       "wss://rtc.example.invalid",
		liveKitAPIKey:    "devkey",
		liveKitAPISecret: "secret",
		callTokenTTL:     5 * time.Minute,
		now: func() time.Time {
			return time.Date(2026, 8, 14, 0, 0, 0, 0, time.UTC)
		},
	}
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "https://api.example.invalid/api/v1/calls/call-1/token", nil)

	s.issueFormalCallToken(recorder, request, "dd-call-room", "018f0000-0000-7000-8000-000000000001", "Alice")

	if recorder.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"server_url", "token", "room_name", "participant_identity", "expires_in_seconds"} {
		if _, ok := body[key]; !ok {
			t.Fatalf("missing field %q: %v", key, body)
		}
	}
	if body["room_name"] != "dd-call-room" || body["participant_identity"] != "018f0000-0000-7000-8000-000000000001" || body["expires_in_seconds"] != float64(300) {
		t.Fatalf("unexpected formal token response: %v", body)
	}
	if _, ok := body["participant_token"]; ok {
		t.Fatalf("legacy participant_token present: %v", body)
	}
	if _, ok := body["expires_at"]; ok {
		t.Fatalf("legacy expires_at present: %v", body)
	}
}
