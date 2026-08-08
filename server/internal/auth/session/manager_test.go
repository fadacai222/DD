package session

import (
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestManagerIssuesAndParsesAccessToken(t *testing.T) {
	now := time.Date(2026, 8, 8, 1, 0, 0, 0, time.UTC)
	manager, err := NewManager(Config{
		Secret: strings.Repeat("s", 32),
		Now:    func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}
	userID := uuid.New()
	deviceID := uuid.New()

	issued, err := manager.NewAccessToken(userID, deviceID)
	if err != nil {
		t.Fatal(err)
	}
	claims, err := manager.ParseAccessToken(issued.Raw)
	if err != nil {
		t.Fatal(err)
	}
	if claims.Subject != userID.String() || claims.DeviceID != deviceID.String() {
		t.Fatalf("claims = %#v", claims)
	}
	if !issued.ExpiresAt.Equal(now.Add(15 * time.Minute)) {
		t.Fatalf("expiresAt = %s", issued.ExpiresAt)
	}
}

func TestRefreshTokenHashAndFamily(t *testing.T) {
	now := time.Date(2026, 8, 8, 1, 0, 0, 0, time.UTC)
	manager, err := NewManager(Config{
		Secret: strings.Repeat("s", 32),
		Now:    func() time.Time { return now },
	})
	if err != nil {
		t.Fatal(err)
	}
	familyID := uuid.New()
	issued, err := manager.NewRefreshToken(familyID)
	if err != nil {
		t.Fatal(err)
	}
	hash, err := HashRefreshToken(issued.Raw)
	if err != nil {
		t.Fatal(err)
	}
	if string(hash) != string(issued.Hash) {
		t.Fatal("refresh token hash mismatch")
	}
	if issued.FamilyID != familyID {
		t.Fatalf("familyID = %s", issued.FamilyID)
	}
	if !issued.ExpiresAt.Equal(now.Add(30 * 24 * time.Hour)) {
		t.Fatalf("expiresAt = %s", issued.ExpiresAt)
	}
}

func TestManagerRejectsWeakSecretAndMalformedRefresh(t *testing.T) {
	if _, err := NewManager(Config{Secret: "too-short"}); err == nil {
		t.Fatal("expected weak secret rejection")
	}
	if _, err := HashRefreshToken("not-a-valid-token"); err == nil {
		t.Fatal("expected malformed refresh token rejection")
	}
}
