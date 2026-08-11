package groups

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestIssueLiveKitRoomTokenScopesParticipantToSingleRoom(t *testing.T) {
	now := time.Date(2026, 8, 11, 1, 0, 0, 0, time.UTC)
	token, err := issueLiveKitRoomToken(
		"api-key",
		"secret",
		"user:device",
		"Alice",
		"dd-group-room",
		now,
	)
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("jwt parts=%d", len(parts))
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err := json.Unmarshal(payload, &claims); err != nil {
		t.Fatal(err)
	}
	if claims["iss"] != "api-key" || claims["sub"] != "user:device" || claims["name"] != "Alice" {
		t.Fatalf("claims=%v", claims)
	}
	video, ok := claims["video"].(map[string]any)
	if !ok {
		t.Fatalf("video claims=%T %#v", claims["video"], claims["video"])
	}
	if video["roomJoin"] != true || video["room"] != "dd-group-room" || video["canPublish"] != true || video["canSubscribe"] != true {
		t.Fatalf("video claims=%v", video)
	}
}

func TestGroupCallParticipantLimitUsesSafeDefaultAndConfiguredBounds(t *testing.T) {
	t.Setenv("DD_GROUP_CALL_MAX_PARTICIPANTS", "")
	if got := groupCallParticipantLimit(); got != 32 {
		t.Fatalf("default participant limit=%d want 32", got)
	}
	t.Setenv("DD_GROUP_CALL_MAX_PARTICIPANTS", "12")
	if got := groupCallParticipantLimit(); got != 12 {
		t.Fatalf("configured participant limit=%d want 12", got)
	}
	for _, invalid := range []string{"1", "501", "oops"} {
		t.Setenv("DD_GROUP_CALL_MAX_PARTICIPANTS", invalid)
		if got := groupCallParticipantLimit(); got != 32 {
			t.Fatalf("invalid %q limit=%d want safe default 32", invalid, got)
		}
	}
}

func TestIssueLiveKitRoomTokenRejectsMissingConfiguration(t *testing.T) {
	if _, err := issueLiveKitRoomToken("", "secret", "u:d", "User", "room", time.Now()); err == nil {
		t.Fatal("expected missing api key to fail")
	}
	if _, err := issueLiveKitRoomToken("key", "", "u:d", "User", "room", time.Now()); err == nil {
		t.Fatal("expected missing api secret to fail")
	}
	if _, err := issueLiveKitRoomToken("key", "secret", "", "User", "room", time.Now()); err == nil {
		t.Fatal("expected missing identity to fail")
	}
}
