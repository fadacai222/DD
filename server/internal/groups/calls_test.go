package groups

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"example.com/selfhosted-im/server/internal/auth/account"
	"github.com/google/uuid"
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
	if video["roomJoin"] != true || video["room"] != "dd-group-room" || video["canPublish"] != true || video["canSubscribe"] != true || video["canPublishData"] != true {
		t.Fatalf("video claims=%v", video)
	}
	for _, forbidden := range []string{"roomAdmin", "roomCreate", "roomList", "roomRecord"} {
		if _, exists := video[forbidden]; exists {
			t.Fatalf("unexpected broad permission %q in video claims=%v", forbidden, video)
		}
	}
}

func TestGroupCallParticipantLimitUsesSafeDefaultAndConfiguredBoundsFromConfig(t *testing.T) {
	if got := normalizeGroupCallParticipantLimit(0); got != 32 {
		t.Fatalf("default participant limit=%d want 32", got)
	}
	if got := normalizeGroupCallParticipantLimit(12); got != 12 {
		t.Fatalf("configured participant limit=%d want 12", got)
	}
	for _, invalid := range []int{1, MaximumGroupMembers + 1} {
		if got := normalizeGroupCallParticipantLimit(invalid); got != 32 {
			t.Fatalf("invalid %d limit=%d want safe default 32", invalid, got)
		}
	}
}

func TestGroupCallServiceFailsClosedWhenMediaConfigIsMissing(t *testing.T) {
	service := &Service{groupCall: newGroupCallConfig("", "", "", 0)}
	principal := account.Principal{UserID: uuid.New(), DeviceID: uuid.New()}
	groupID := uuid.New()
	callID := uuid.New()

	if _, _, err := service.StartGroupCall(context.Background(), principal, groupID, "AUDIO"); !errors.Is(err, ErrGroupCallUnavailable) {
		t.Fatalf("StartGroupCall() error = %v, want ErrGroupCallUnavailable", err)
	}
	if _, _, err := service.JoinGroupCall(context.Background(), principal, groupID, callID); !errors.Is(err, ErrGroupCallUnavailable) {
		t.Fatalf("JoinGroupCall() error = %v, want ErrGroupCallUnavailable", err)
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
