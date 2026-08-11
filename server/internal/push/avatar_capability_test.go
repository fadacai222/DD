package push

import (
	"net/url"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestPushAvatarCapabilityRoundTripRejectsTamperAndExpiry(t *testing.T) {
	userID := uuid.MustParse("11111111-2222-3333-4444-555555555555")
	now := time.Date(2026, 8, 12, 4, 0, 0, 0, time.UTC)
	secret := "0123456789abcdef0123456789abcdef"

	raw := SignedAvatarURL("https://chat.example.com", secret, userID, now.Add(24*time.Hour))
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Path != "/push-assets/avatars/"+userID.String() {
		t.Fatalf("path=%q", parsed.Path)
	}
	expiresAt, err := time.Parse(time.RFC3339, parsed.Query().Get("expires"))
	if err != nil {
		t.Fatalf("expires=%q err=%v", parsed.Query().Get("expires"), err)
	}
	signature := parsed.Query().Get("sig")
	if !VerifyAvatarCapability(secret, userID, expiresAt, signature, now) {
		t.Fatal("valid avatar capability was rejected")
	}
	if VerifyAvatarCapability(secret, uuid.New(), expiresAt, signature, now) {
		t.Fatal("signature was accepted for another user")
	}
	if VerifyAvatarCapability(secret, userID, expiresAt, signature+"00", now) {
		t.Fatal("tampered signature was accepted")
	}
	if VerifyAvatarCapability(secret, userID, expiresAt, signature, expiresAt.Add(time.Second)) {
		t.Fatal("expired avatar capability was accepted")
	}
}

func TestSignedAvatarURLRequiresHTTPSExceptPrivateDevelopmentOrigin(t *testing.T) {
	userID := uuid.New()
	expiresAt := time.Date(2026, 8, 13, 4, 0, 0, 0, time.UTC)
	secret := "0123456789abcdef0123456789abcdef"

	if got := SignedAvatarURL("http://chat.example.com", secret, userID, expiresAt); got != "" {
		t.Fatalf("public http capability=%q want empty", got)
	}
	if got := SignedAvatarURL("http://192.168.1.20:18473", secret, userID, expiresAt); got == "" {
		t.Fatal("private LAN development origin should be allowed")
	}
	if got := SignedAvatarURL("https://chat.example.com/prefix", secret, userID, expiresAt); got != "" {
		t.Fatalf("pathful origin capability=%q want empty", got)
	}
	if got := SignedAvatarURL("https://chat.example.com", "", userID, expiresAt); got != "" {
		t.Fatalf("empty-secret capability=%q want empty", got)
	}
}
